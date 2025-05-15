#!/bin/bash
# Enhanced Audio RTSP Streaming Script
#
# Version: 6.5.7
# Date: 2025-05-15
# Description: Production-grade script for streaming audio from capture devices to RTSP
#              With improved device detection and robust privilege separation
#
# Changes in v6.5.7:
#  - Fixed critical systemd compatibility issues that prevented proper service startup
#  - Improved lock file handling to prevent false detection of running instances
#  - Enhanced startup sequence with better error recovery
#  - Fixed race conditions in initialization process
#  - Added more detailed diagnostic information for troubleshooting
#  - Fixed trap handler to prevent premature service termination
#  - Ensured script compatibility with frequent service restarts
#  - Improved service exit handling to prevent systemd start-limit-hit errors

# Exit on error with pipe commands
set -o pipefail

# Self-healing permission check - fix permissions if needed
if [ ! -x "$0" ]; then
    echo "Warning: Script is not executable. Attempting to fix permissions..."
    chmod +x "$0" 2>/dev/null || {
        echo "ERROR: Could not set executable permission on $0"
        echo "Please run: chmod +x $0"
        exit 203  # Return specific systemd exec error code
    }
fi

# Global configuration variables 
MEDIAMTX_PATH="/usr/local/mediamtx/mediamtx"
RTSP_PORT="18554"
RUNTIME_DIR="/run/audio-rtsp"
TEMP_DIR="${RUNTIME_DIR}/tmp"
LOCK_FILE="${RUNTIME_DIR}/startmic.lock"
PID_FILE="${RUNTIME_DIR}/startmic.pid"
CONFIG_DIR="/etc/audio-rtsp"
DEVICE_CONFIG_DIR="${CONFIG_DIR}/devices"
LOG_DIR="/var/log/audio-rtsp"
STATE_DIR="${RUNTIME_DIR}/state"
DEVICE_MAP_FILE="${CONFIG_DIR}/device_map.conf"
DEVICE_BLACKLIST_FILE="${CONFIG_DIR}/device_blacklist.conf"
CONFIG_FILE="${CONFIG_DIR}/config"

# Audio settings
AUDIO_BITRATE="192k"
AUDIO_CODEC="libmp3lame"
AUDIO_CHANNELS="1"
AUDIO_SAMPLE_RATE="44100"

# FFMPEG settings
FFMPEG_LOG_LEVEL="error"
FFMPEG_ADDITIONAL_OPTS=""

# Other settings
RESTART_DELAY=10
MAX_RESTART_ATTEMPTS=5
STREAM_CHECK_INTERVAL=30
LOG_LEVEL="info"  # Valid values: debug, info, warning, error
MAX_STREAMS=32    # Maximum number of streams to prevent resource exhaustion

# Privilege dropping settings
PRIVILEGE_DROP_USER="rtsp"
PRIVILEGE_DROP_GROUP="audio"
PRIVILEGE_DROP_ENABLED=false
SCRIPT_DIR="${TEMP_DIR}/scripts"
TEMP_SCRIPT_FILES=()

# Service state
STARTUP_COMPLETE=false
FORCE_EXIT=false
TIMEOUT_PID=""

# Create required directories with proper permissions
setup_directories() {
    local dirs=(
        "$RUNTIME_DIR"
        "$TEMP_DIR"
        "$LOG_DIR" 
        "$STATE_DIR"
        "$CONFIG_DIR"
        "$DEVICE_CONFIG_DIR"
        "${STATE_DIR}/streams"
        "$SCRIPT_DIR"
    )
    
    # First check if we can create the main runtime dir
    if ! mkdir -p "$RUNTIME_DIR" 2>/dev/null; then
        echo "ERROR: Failed to create main runtime directory: $RUNTIME_DIR"
        RUNTIME_DIR="/tmp/audio-rtsp"
        TEMP_DIR="${RUNTIME_DIR}/tmp"
        STATE_DIR="${RUNTIME_DIR}/state"
        SCRIPT_DIR="${TEMP_DIR}/scripts"
        echo "Falling back to temporary directory: $RUNTIME_DIR"
        
        # Try to create fallback directories
        if ! mkdir -p "$RUNTIME_DIR" "$TEMP_DIR" "$STATE_DIR" "$SCRIPT_DIR" 2>/dev/null; then
            echo "FATAL: Cannot create temporary directories. Exiting."
            exit 1
        fi
    fi
    
    # Now process all directories
    for dir in "${dirs[@]}"; do
        if ! mkdir -p "$dir" 2>/dev/null; then
            echo "ERROR: Failed to create directory: $dir"
            # Skip to next directory instead of exiting
            continue
        fi
        
        # Set correct permissions - world readable/executable but only owner writable
        chmod 755 "$dir" 2>/dev/null || true
    done
    
    # Create lock file directory
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || true
}

# Initialize directories early to avoid startup issues
setup_directories

# Define temporary files - create with safe fallbacks if main directories fail
TEMP_FILE="${TEMP_DIR}/stream_details.$$"
PIDS_FILE="${TEMP_DIR}/stream_pids.$$"
LOG_FILE="${LOG_DIR}/audio-streams.log"

# Fallback to /tmp if we can't create in standard locations
if ! touch "$TEMP_FILE" 2>/dev/null; then
    TEMP_FILE="/tmp/audio-rtsp-stream_details.$$"
    touch "$TEMP_FILE" 2>/dev/null || {
        echo "ERROR: Cannot create temporary files in fallback location"
    }
fi

if ! touch "$PIDS_FILE" 2>/dev/null; then
    PIDS_FILE="/tmp/audio-rtsp-stream_pids.$$"
    touch "$PIDS_FILE" 2>/dev/null || {
        echo "ERROR: Cannot create PID file in fallback location"
    }
fi

# Make sure log directory exists with appropriate fallbacks
mkdir -p "$LOG_DIR" 2>/dev/null || {
    LOG_DIR="/tmp/audio-rtsp-logs"
    mkdir -p "$LOG_DIR" 2>/dev/null || true
    LOG_FILE="${LOG_DIR}/audio-streams.log"
}

# Initialize log file - failsafe implementation
initialize_log() {
    # Create log file if it doesn't exist
    touch "$LOG_FILE" 2>/dev/null || {
        echo "WARNING: Cannot create log file: $LOG_FILE"
        LOG_FILE="/tmp/audio-rtsp-$$.log"
        touch "$LOG_FILE" 2>/dev/null || {
            LOG_FILE="/dev/null"
            echo "ERROR: Falling back to null logging"
            return 1
        }
        echo "Using alternative log file: $LOG_FILE"
    }
    
    # Test if we can actually write to the log
    if ! { echo "Test" >> "$LOG_FILE"; } 2>/dev/null; then
        echo "WARNING: Cannot write to log file: $LOG_FILE"
        LOG_FILE="/tmp/audio-rtsp-$$.log"
        touch "$LOG_FILE" 2>/dev/null || {
            LOG_FILE="/dev/null"
            echo "ERROR: Falling back to null logging"
            return 1
        }
        echo "Using alternative log file: $LOG_FILE"
    fi
    
    {
        echo "----------------------------------------"
        echo "Service started at $(date)"
        echo "PID: $$"
        echo "Version: 6.5.7"
        echo "----------------------------------------"
    } >> "$LOG_FILE" 2>/dev/null
    
    return 0
}

initialize_log

# Pre-log function for very early logging before the main log is initialized
pre_log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo "[$timestamp] [$level] $message" >&2
    
    # Try to write to log file if it exists
    if [ -w "$LOG_FILE" ]; then
        echo "[$timestamp] [$level] $message" >> "$LOG_FILE" 2>/dev/null
    fi
}

# Advanced logging function with proper log levels
log() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_line="[$timestamp] [$level] $message"
    
    # Determine if this message should be logged based on LOG_LEVEL
    local should_log=0
    case "$LOG_LEVEL" in
        debug)
            should_log=1 ;;
        info)
            if [[ "$level" != "DEBUG" ]]; then should_log=1; fi ;;
        warning)
            if [[ "$level" != "DEBUG" && "$level" != "INFO" ]]; then should_log=1; fi ;;
        error)
            if [[ "$level" == "ERROR" || "$level" == "FATAL" ]]; then should_log=1; fi ;;
    esac
    
    if [[ $should_log -eq 1 ]]; then
        # Write to log file - with fallback to stderr
        if ! { echo "$log_line" >> "$LOG_FILE"; } 2>/dev/null; then
            echo "$log_line" >&2
        fi
        
        # Print to console for ERROR and FATAL logs
        if [[ "$level" == "ERROR" || "$level" == "FATAL" ]]; then
            echo "$log_line" >&2
        fi
    fi
}

# Log rotation function to manage log file sizes
rotate_logs() {
    # Check log size
    if [ -f "$LOG_FILE" ]; then
        local log_size=0
        log_size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
        log_size=$(ensure_integer "$log_size" 0)
        
        # Rotate if over 50MB
        if [ "$log_size" -gt 52428800 ]; then
            log "INFO" "Rotating log file - size: $log_size bytes"
            
            # Create timestamp
            local timestamp=""
            timestamp=$(date '+%Y%m%d-%H%M%S')
            
            # Keep max 5 rotated logs
            find "$LOG_DIR" -name "audio-streams-*.log" -type f | sort -r | tail -n +5 | xargs rm -f 2>/dev/null
            
            # Rotate current log - keep trying with different approaches if needed
            local rotate_success=false
            
            # Try mv first
            if mv "$LOG_FILE" "${LOG_FILE%.*}-$timestamp.log" 2>/dev/null; then
                rotate_success=true
            else
                # Try cp and truncate approach
                if cp "$LOG_FILE" "${LOG_FILE%.*}-$timestamp.log" 2>/dev/null; then
                    echo "" > "$LOG_FILE" 2>/dev/null && rotate_success=true
                fi
            fi
            
            # Create new log file
            touch "$LOG_FILE" 2>/dev/null
            
            if [ "$rotate_success" = true ]; then
                log "INFO" "Log rotation completed successfully"
            else
                log "WARNING" "Log rotation failed, continuing with current log file"
            fi
        fi
    fi
}

# Completely rewritten function to ensure valid integers
# This is critical for avoiding comparison errors
ensure_integer() {
    # Input value to check and default if empty/invalid
    local input="$1"
    local default="${2:-0}"
    
    # If input is not set or is empty string, return default
    if [ -z "$input" ]; then
        echo "$default"
        return
    fi
    
    # Explicitly create a cleaned string with only digits
    local cleaned=""
    cleaned=$(echo "$input" | tr -cd '0-9')
    
    # Return default if cleaned is empty
    if [ -z "$cleaned" ]; then
        echo "$default"
    else
        echo "$cleaned"
    fi
}

# Function to ensure atomic writes to files
atomic_write() {
    local file="$1"
    local content="$2"
    
    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$file")" 2>/dev/null || true
    
    # Write to temp file first then move atomically
    local temp_file="${file}.tmp.$$"
    
    # Try to write content to temp file and catch errors
    if ! echo "$content" > "$temp_file" 2>/dev/null; then
        log "ERROR" "Failed to write to temporary file: $temp_file"
        # Try direct write as last resort
        echo "$content" > "$file" 2>/dev/null
        return 1
    fi
    
    # Check if temp file was successfully created
    if [ ! -f "$temp_file" ]; then
        log "ERROR" "Temp file was not created: $temp_file"
        # Try direct write as last resort
        echo "$content" > "$file" 2>/dev/null
        return 1
    fi
    
    # Move temp file to destination
    if ! mv -f "$temp_file" "$file" 2>/dev/null; then
        log "ERROR" "Failed to atomically write to $file"
        # Try direct write as last resort
        echo "$content" > "$file" 2>/dev/null
        rm -f "$temp_file" 2>/dev/null || true
        return 1
    fi
    
    return 0
}

# Self-diagnostic health status reporting
report_health_status() {
    local status_file="${STATE_DIR}/health_status.json"
    local uptime=$1
    local streams_count=$2
    local rtsp_streams=$3
    local root_streams=$4
    local memory_usage=$5
    
    # Create JSON structure with health metrics
    cat > "$status_file" << EOF
{
  "timestamp": "$(date -Iseconds)",
  "version": "6.5.7",
  "status": "running",
  "uptime_seconds": $uptime,
  "streams": {
    "total": $streams_count,
    "privileged": $rtsp_streams,
    "root": $root_streams
  },
  "memory_usage_percent": $memory_usage,
  "rtsp_server": $(check_mediamtx_status >/dev/null 2>&1 && echo "\"running\"" || echo "\"stopped\""),
  "pid": $$
}
EOF
    
    # Make readable by other processes
    chmod 644 "$status_file" 2>/dev/null || true
    
    log "DEBUG" "Updated health status report at $status_file"
}

# Load configuration if available
if [ -f "$CONFIG_FILE" ]; then
    log "INFO" "Loading configuration from $CONFIG_FILE"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE" 2>/dev/null || log "ERROR" "Failed to source config file"
else
    log "WARNING" "Configuration file not found: $CONFIG_FILE"
fi

# Function to clean up any existing streaming processes
clean_processes() {
    log "INFO" "Cleaning up existing audio streaming processes"
    
    # Kill any ffmpeg processes related to RTSP
    pkill -15 -f "ffmpeg.*rtsp" 2>/dev/null || true
    sleep 1
    pkill -9 -f "ffmpeg.*rtsp" 2>/dev/null || true
    
    # Also kill any hanging su/runuser/setpriv processes for the rtsp user
    pkill -15 -f "su.*$PRIVILEGE_DROP_USER" 2>/dev/null || true
    pkill -9 -f "su.*$PRIVILEGE_DROP_USER" 2>/dev/null || true
    pkill -15 -f "runuser.*$PRIVILEGE_DROP_USER" 2>/dev/null || true
    pkill -9 -f "runuser.*$PRIVILEGE_DROP_USER" 2>/dev/null || true
    pkill -15 -f "setpriv.*reuid=$PRIVILEGE_DROP_USER" 2>/dev/null || true
    pkill -9 -f "setpriv.*reuid=$PRIVILEGE_DROP_USER" 2>/dev/null || true
    
    # Clean up any PID files from previous runs
    if [ -d "${STATE_DIR}/streams" ]; then
        find "${STATE_DIR}/streams" -name "*.pid" -delete 2>/dev/null || true
    fi
    
    # Verify cleanup was successful - with safer process counting
    local remaining=0
    if ps -eo pid,cmd 2>/dev/null | grep -q "[f]fmpeg.*rtsp"; then
        remaining=$(ps -eo pid,cmd 2>/dev/null | grep "[f]fmpeg.*rtsp" | wc -l || echo "0")
        remaining=$(ensure_integer "$remaining" 0)
    fi
    
    if [ "$remaining" -gt 0 ]; then
        log "WARNING" "Failed to kill all ffmpeg processes, $remaining remain"
    else
        log "INFO" "Successfully cleaned up all ffmpeg processes"
    fi
}

# Set ownership and permissions properly for a directory
fix_directory_permissions() {
    local dir="$1"
    local mode="$2"
    local user="$3"
    local group="$4"
    
    if [ ! -d "$dir" ]; then
        log "DEBUG" "Directory does not exist: $dir"
        mkdir -p "$dir" 2>/dev/null || {
            log "ERROR" "Failed to create directory: $dir"
            return 1
        }
    fi
    
    # Fix permissions if specified
    if [ -n "$mode" ]; then
        chmod "$mode" "$dir" 2>/dev/null || {
            log "WARNING" "Failed to set mode $mode on directory: $dir"
        }
    fi
    
    # Fix ownership if specified
    if [ -n "$user" ] || [ -n "$group" ]; then
        if [ -n "$user" ] && [ -n "$group" ]; then
            chown "$user:$group" "$dir" 2>/dev/null || {
                log "WARNING" "Failed to set ownership $user:$group on directory: $dir"
            }
        elif [ -n "$user" ]; then
            chown "$user" "$dir" 2>/dev/null || {
                log "WARNING" "Failed to set owner $user on directory: $dir"
            }
        elif [ -n "$group" ]; then
            chgrp "$group" "$dir" 2>/dev/null || {
                log "WARNING" "Failed to set group $group on directory: $dir"
            }
        fi
    fi
    
    # Ensure the directory is accessible
    chmod +x "$dir" 2>/dev/null || {
        log "WARNING" "Failed to set execute permission on directory: $dir"
    }
    
    return 0
}

# Function to check if MediaMTX is running - improved with better diagnostics
check_mediamtx_status() {
    log "INFO" "Checking MediaMTX status..."
    
    # Check if we can connect to the RTSP port
    if command -v nc >/dev/null 2>&1; then
        if nc -z -w 2 localhost "$RTSP_PORT" >/dev/null 2>&1; then
            log "INFO" "MediaMTX is accessible on port $RTSP_PORT"
            return 0
        else
            log "WARNING" "MediaMTX not accessible on port $RTSP_PORT"
        fi
    else
        log "WARNING" "nc (netcat) command not found - cannot check RTSP port"
    fi
    
    # Check if the service is running using systemctl
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet mediamtx.service; then
            log "INFO" "MediaMTX service is running but port $RTSP_PORT is not accessible"
            
            # Check if it's using a different port
            if command -v grep >/dev/null 2>&1; then
                local mediamtx_config="/etc/mediamtx/mediamtx.yml"
                if [ -f "$mediamtx_config" ]; then
                    log "INFO" "Checking MediaMTX configuration file: $mediamtx_config"
                    
                    # Extract the configured port
                    local rtsp_address=""
                    local rtsp_port=""
                    # First try to find rtspAddress with port
                    rtsp_address=$(grep -E "rtspAddress:" "$mediamtx_config" 2>/dev/null | awk '{print $2}')
                    if [[ "$rtsp_address" == *":"* ]]; then
                        rtsp_port=$(echo "$rtsp_address" | grep -o ":[0-9]\+" | grep -o "[0-9]\+")
                        if [ -n "$rtsp_port" ]; then
                            log "INFO" "Found RTSP port $rtsp_port in rtspAddress setting"
                            RTSP_PORT="$rtsp_port"
                        fi
                    fi
                    
                    # Also check separate rtspPort setting
                    rtsp_port=$(grep -E "rtspPort:" "$mediamtx_config" 2>/dev/null | awk '{print $2}')
                    if [ -n "$rtsp_port" ]; then
                        log "INFO" "Found RTSP port $rtsp_port in rtspPort setting"
                        RTSP_PORT="$rtsp_port"
                    fi
                    
                    # Test the configured port
                    if [ -n "$rtsp_port" ]; then
                        if nc -z -w 2 localhost "$RTSP_PORT" >/dev/null 2>&1; then
                            log "INFO" "MediaMTX is accessible on port $RTSP_PORT"
                            return 0
                        else
                            log "WARNING" "MediaMTX not accessible on configured port $RTSP_PORT either"
                        fi
                    fi
                else
                    log "WARNING" "MediaMTX config file not found: $mediamtx_config"
                fi
            fi
            
            return 1
        else
            log "WARNING" "MediaMTX service is not running"
        fi
    else
        log "WARNING" "systemctl not found - cannot check MediaMTX service status"
    fi
    
    return 1
}

# Function to start MediaMTX - improved with better error handling
start_mediamtx() {
    log "INFO" "Attempting to start MediaMTX service..."
    
    # First, check if MediaMTX is already running
    if check_mediamtx_status; then
        log "INFO" "MediaMTX is already running"
        return 0
    fi
    
    # Enhanced recovery for MediaMTX
    if [ -f "/etc/mediamtx/mediamtx.yml" ] && command -v systemctl >/dev/null 2>&1; then
        # Reset MediaMTX configuration if needed
        log "INFO" "Checking MediaMTX configuration for issues"
        if grep -q "rtspPort:.*$RTSP_PORT" "/etc/mediamtx/mediamtx.yml" 2>/dev/null || 
           grep -q "rtspAddress:.*:$RTSP_PORT" "/etc/mediamtx/mediamtx.yml" 2>/dev/null; then
            # Configuration looks correct, try restarting the service
            log "INFO" "Attempting to restart MediaMTX service"
            systemctl restart mediamtx.service 2>/dev/null
            sleep 3
            
            # Check if restart worked
            if check_mediamtx_status; then
                log "INFO" "MediaMTX restarted successfully"
                return 0
            fi
        else
            log "WARNING" "MediaMTX configuration might not use port $RTSP_PORT"
        fi
    fi
    
    # Try using systemctl to start the service
    if command -v systemctl >/dev/null 2>&1; then
        # Check if the service exists
        if systemctl list-unit-files | grep -q mediamtx.service; then
            log "INFO" "Starting MediaMTX service with systemctl"
            if systemctl start mediamtx.service 2>/dev/null; then
                log "INFO" "MediaMTX service started successfully"
                # Wait for the service to fully initialize
                sleep 3
                
                # Verify the service is running
                if check_mediamtx_status; then
                    log "INFO" "MediaMTX is now accessible"
                    return 0
                else
                    log "ERROR" "MediaMTX service started but port $RTSP_PORT is not accessible"
                fi
            else
                log "ERROR" "Failed to start MediaMTX service with systemctl"
                
                # Try to get more detailed error information
                local status_output=""
                status_output=$(systemctl status mediamtx.service 2>&1 || echo "No status available")
                log "DEBUG" "MediaMTX service status: $status_output"
            fi
        else
            log "WARNING" "MediaMTX service not found in systemd"
        fi
    fi
    
    # If systemctl failed or isn't available, try starting MediaMTX directly
    if [ -x "$MEDIAMTX_PATH" ]; then
        log "INFO" "Attempting to start MediaMTX directly: $MEDIAMTX_PATH"
        
        # Create a detached process
        "$MEDIAMTX_PATH" >/dev/null 2>&1 &
        local mediamtx_pid=$!
        
        # Wait for it to initialize
        sleep 3
        
        # Check if it's running
        if kill -0 "$mediamtx_pid" 2>/dev/null; then
            log "INFO" "MediaMTX started with PID $mediamtx_pid"
            
            # Check if the port is accessible
            if command -v nc >/dev/null 2>&1 && nc -z -w 2 localhost "$RTSP_PORT" >/dev/null 2>&1; then
                log "INFO" "MediaMTX is now accessible on port $RTSP_PORT"
                return 0
            else
                log "WARNING" "MediaMTX is running but port $RTSP_PORT is not accessible"
                # Don't kill it - it might be using a different port
            fi
            
            return 0
        else
            log "ERROR" "Failed to start MediaMTX directly: process terminated"
        fi
    else
        # Try to find MediaMTX in common locations
        for path in /usr/bin/mediamtx /usr/local/bin/mediamtx /opt/mediamtx/mediamtx; do
            if [ -x "$path" ]; then
                log "INFO" "Found MediaMTX at $path, attempting to start"
                MEDIAMTX_PATH="$path"
                
                # Create a detached process
                "$MEDIAMTX_PATH" >/dev/null 2>&1 &
                local mediamtx_pid=$!
                
                # Wait for it to initialize
                sleep 3
                
                # Check if it's running
                if kill -0 "$mediamtx_pid" 2>/dev/null; then
                    log "INFO" "MediaMTX started with PID $mediamtx_pid"
                    
                    # Check if the port is accessible
                    if command -v nc >/dev/null 2>&1 && nc -z -w 2 localhost "$RTSP_PORT" >/dev/null 2>&1; then
                        log "INFO" "MediaMTX is now accessible on port $RTSP_PORT"
                        return 0
                    else
                        log "WARNING" "MediaMTX is running but port $RTSP_PORT is not accessible"
                    fi
                    
                    return 0
                else
                    log "ERROR" "Failed to start MediaMTX from $path: process terminated"
                fi
            fi
        done
        
        log "ERROR" "Could not find or start MediaMTX"
    fi
    
    # Continue even if MediaMTX cannot be started - we'll try to recover later
    return 1
}

# Function to check environment conditions and fix if possible
check_environment() {
    log "INFO" "Performing environment checks..."
    local status=0
    
    # Check if script is executable
    if [ ! -x "$0" ]; then
        log "ERROR" "Script is not executable. This may cause systemd startup issues."
        chmod +x "$0" 2>/dev/null || log "ERROR" "Failed to set executable permission on $0"
        status=1
    fi
    
    # Check directories
    for dir in "$RUNTIME_DIR" "$CONFIG_DIR" "$LOG_DIR" "$TEMP_DIR" "$STATE_DIR" "$SCRIPT_DIR"; do
        if [ ! -d "$dir" ]; then
            log "WARNING" "Directory does not exist: $dir"
            mkdir -p "$dir" 2>/dev/null || {
                log "ERROR" "Failed to create directory: $dir"
                status=1
            }
        fi
        
        if [ ! -w "$dir" ]; then
            log "ERROR" "Directory is not writable: $dir"
            chmod 755 "$dir" 2>/dev/null || {
                log "ERROR" "Failed to set permissions on $dir"
                status=1
            }
        fi
        
        # Ensure directory is executable (traversable)
        if [ ! -x "$dir" ]; then
            log "ERROR" "Directory is not executable: $dir"
            chmod +x "$dir" 2>/dev/null || {
                log "ERROR" "Failed to set executable permission on $dir"
                status=1
            }
        fi
    done
    
    # Check parent directories to ensure they're accessible
    for dir in "$RUNTIME_DIR" "$CONFIG_DIR" "$LOG_DIR"; do
        local parent_dir=""
        parent_dir="$(dirname "$dir")"
        if [ ! -x "$parent_dir" ]; then
            log "WARNING" "Parent directory is not executable: $parent_dir"
            chmod +x "$parent_dir" 2>/dev/null || {
                log "ERROR" "Failed to set executable permission on parent directory: $parent_dir"
                status=1
            }
        fi
    done
    
    # Make temporary directory world-writable with sticky bit (like /tmp)
    fix_directory_permissions "$TEMP_DIR" "1777" "root" "root"
    
    # Make log directory writable by rtsp group if it exists
    if getent group "$PRIVILEGE_DROP_GROUP" >/dev/null 2>&1; then
        fix_directory_permissions "$LOG_DIR" "775" "root" "$PRIVILEGE_DROP_GROUP"
    fi
    
    # Verify script directory permissions
    fix_directory_permissions "$SCRIPT_DIR" "755" "root" "$PRIVILEGE_DROP_GROUP"
    
    # Check critical dependencies
    for cmd in ffmpeg arecord; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log "ERROR" "Required command not found: $cmd"
            status=1
        fi
    done
    
    # Check if MediaMTX is accessible - using improved function
    # Failure to start MediaMTX is not fatal - we'll try to recover or operate without it
    if ! check_mediamtx_status; then
        log "WARNING" "MediaMTX is not accessible, attempting to start it"
        if ! start_mediamtx; then
            log "ERROR" "Could not start MediaMTX - streams will not work"
            # Set indicator file for this issue
            atomic_write "${RUNTIME_DIR}/mediamtx_failed" "$(date)"
            status=1
        fi
    fi
    
    # Check user and group requirements
    if ! getent group "audio" >/dev/null 2>&1; then
        log "WARNING" "Audio group does not exist - may cause issues with sound card access"
    fi
    
    # Check audio devices
    if ! arecord -l >/dev/null 2>&1; then
        log "WARNING" "No audio capture devices detected or permission issues with audio devices"
        # Check if user has access to audio devices
        if [ -e "/dev/snd" ]; then
            log "INFO" "Checking audio device permissions"
            ls -la /dev/snd/* 2>/dev/null | while read -r line; do
                log "DEBUG" "Audio device: $line"
            done
        fi
    fi
    
    return $status
}

# Function to check sound card order
fix_card_order() {
    # Address the changing card order issue
    log "INFO" "Checking sound card order"
    
    # Get current card order
    local sound_cards=""
    sound_cards=$(cat /proc/asound/cards 2>/dev/null)
    
    # Log the current card order for debugging
    if [ -n "$sound_cards" ]; then
        echo "$sound_cards" | while read -r line; do
            log "DEBUG" "Sound card: $line"
        done
    else
        log "WARNING" "No sound cards detected in /proc/asound/cards"
    fi
}

# -------------------------------------------------------------------------
# IMPROVED PRIVILEGE DROPPING IMPLEMENTATION
# Based on research report best practices for cross-distribution compatibility
# -------------------------------------------------------------------------

# Drop privileges using the best available method
# This function implements the tiered approach from the research document
drop_privileges() {
    local username="$1"
    local cmd="$2"
    local userid=""
    local groupid=""
    
    # Check if we need to drop privileges (already running as target user)
    if [ "$(id -un)" = "$username" ]; then
        log "DEBUG" "Already running as $username, no privilege drop needed"
        eval "$cmd"
        return $?
    fi
    
    # Check if we're running as root
    if [ "$(id -u)" -ne 0 ]; then
        log "WARNING" "Not running as root, cannot drop privileges to $username"
        # Try to run the command anyway
        eval "$cmd"
        return $?
    fi
    
    # Get numeric user and group IDs
    userid=$(id -u "$username" 2>/dev/null)
    if [ -z "$userid" ]; then
        log "ERROR" "User $username does not exist"
        return 1
    fi
    
    groupid=$(id -g "$username" 2>/dev/null)
    if [ -z "$groupid" ]; then
        log "ERROR" "Cannot determine primary group for $username"
        return 1
    fi
    
    log "DEBUG" "Dropping privileges to user=$username($userid) group=$groupid"
    
    # Try different methods in order of preference
    if command -v setpriv >/dev/null 2>&1; then
        log "DEBUG" "Using setpriv method for privilege dropping"
        setpriv --reuid="$userid" --regid="$groupid" --init-groups --reset-env bash -c "$cmd"
        return $?
    elif command -v runuser >/dev/null 2>&1; then
        log "DEBUG" "Using runuser method for privilege dropping"
        runuser -u "$username" -- bash -c "$cmd"
        return $?
    elif command -v sudo >/dev/null 2>&1; then
        log "DEBUG" "Using sudo method for privilege dropping"
        sudo -u "$username" bash -c "$cmd"
        return $?
    elif command -v capsh >/dev/null 2>&1; then
        # Alternative using capabilities
        log "DEBUG" "Using capsh method for privilege dropping"
        capsh --user="$username" -- -c "$cmd"
        return $?
    else
        log "DEBUG" "Using su method for privilege dropping (fallback)"
        su "$username" -s /bin/bash -c "$cmd"
        return $?
    fi
}

# Create and configure the service user with proper settings
create_service_user() {
    local username="$1"
    local groupname="$2"
    
    # Only proceed if running as root
    if [ "$(id -u)" -ne 0 ]; then
        log "INFO" "Not running as root, skipping service user creation"
        return 1
    fi
    
    log "INFO" "Setting up service user: $username"
    
    # Ensure audio group exists
    if ! getent group "$groupname" >/dev/null 2>&1; then
        log "INFO" "Creating $groupname group"
        groupadd -r "$groupname" 2>/dev/null || {
            log "WARNING" "Failed to create $groupname group"
            return 1
        }
    fi
    
    # Check if user already exists
    if id -u "$username" >/dev/null 2>&1; then
        log "INFO" "User $username already exists, updating settings"
        
        # Update shell for compatibility with privilege dropping
        usermod -s /bin/bash "$username" 2>/dev/null || 
            log "WARNING" "Failed to set shell for $username"
        
        # Ensure user is in audio group for hardware access
        if ! groups "$username" 2>/dev/null | grep -q "\b$groupname\b"; then
            log "INFO" "Adding $username to $groupname group"
            usermod -a -G "$groupname" "$username" 2>/dev/null || 
                log "WARNING" "Failed to add $username to $groupname group"
        fi
    else
        # Create new user with appropriate settings
        log "INFO" "Creating service user: $username"
        
        # Try distribution-specific approaches
        if grep -qi "debian\|ubuntu" /etc/os-release 2>/dev/null; then
            # Debian/Ubuntu
            useradd -r -g "$groupname" -G "$groupname" -s /bin/bash "$username" 2>/dev/null || {
                log "WARNING" "Failed to create user with Debian/Ubuntu settings"
                # Fallback to basic creation
                useradd -r -s /bin/bash "$username" 2>/dev/null || {
                    log "ERROR" "Failed to create $username user"
                    return 1
                }
                usermod -a -G "$groupname" "$username" 2>/dev/null || 
                    log "WARNING" "Failed to add $username to $groupname group"
            }
        elif grep -qi "centos\|rhel\|fedora" /etc/os-release 2>/dev/null; then
            # RHEL/CentOS/Fedora
            useradd -r -g "$groupname" -G "$groupname" -s /bin/bash "$username" 2>/dev/null || {
                log "WARNING" "Failed to create user with RHEL/CentOS settings"
                # Fallback to basic creation
                useradd -r -s /bin/bash "$username" 2>/dev/null || {
                    log "ERROR" "Failed to create $username user"
                    return 1
                }
                usermod -a -G "$groupname" "$username" 2>/dev/null || 
                    log "WARNING" "Failed to add $username to $groupname group"
            }
        else
            # Generic approach for other distributions
            useradd -r -s /bin/bash "$username" 2>/dev/null || {
                log "ERROR" "Failed to create $username user"
                return 1
            }
            usermod -a -G "$groupname" "$username" 2>/dev/null || 
                log "WARNING" "Failed to add $username to $groupname group"
        fi
    fi
    
    return 0
}

# Setup hardware access permissions for the service user
setup_hardware_access() {
    local username="$1"
    local groupname="$2"
    
    # Only proceed if running as root
    if [ "$(id -u)" -ne 0 ]; then
        log "INFO" "Not running as root, skipping hardware access setup"
        return 1
    fi
    
    log "INFO" "Setting up hardware access for $username"
    
    # Ensure directories exist with proper permissions
    mkdir -p "$RUNTIME_DIR" "$TEMP_DIR" "$LOG_DIR" "$STATE_DIR/streams" 2>/dev/null
    chmod 755 "$RUNTIME_DIR" "$LOG_DIR" "$STATE_DIR" 2>/dev/null
    chmod 1777 "$TEMP_DIR" 2>/dev/null
    chmod 777 "${STATE_DIR}/streams" 2>/dev/null
    
    # Make audio devices accessible
    if [ -d "/dev/snd" ]; then
        log "INFO" "Making audio devices accessible to $username"
        
        # First try using ACLs if available
        if command -v setfacl >/dev/null 2>&1; then
            log "DEBUG" "Using ACLs for audio device permissions"
            find /dev/snd -type c -exec setfacl -m "u:$username:rw" {} \; 2>/dev/null || {
                log "WARNING" "Failed to set ACLs on audio devices, falling back to chmod"
                chmod -R a+rX /dev/snd/ 2>/dev/null || 
                    log "ERROR" "Failed to set permissions on audio devices"
            }
        else
            # Fall back to chmod
            log "DEBUG" "Using chmod for audio device permissions"
            chmod -R a+rX /dev/snd/ 2>/dev/null || 
                log "ERROR" "Failed to set permissions on audio devices"
        fi
    else
        log "WARNING" "Audio device directory /dev/snd not found"
    fi
    
    # Make temp directory writable by service user
    chown :$groupname "$TEMP_DIR" 2>/dev/null || log "WARNING" "Failed to set group on $TEMP_DIR"
    chmod g+w "$TEMP_DIR" 2>/dev/null || log "WARNING" "Failed to set group write permission on $TEMP_DIR"
    
    # Make log directory writable by service user
    chown :$groupname "$LOG_DIR" 2>/dev/null || log "WARNING" "Failed to set group on $LOG_DIR"
    chmod g+w "$LOG_DIR" 2>/dev/null || log "WARNING" "Failed to set group write permission on $LOG_DIR"
    
    # Make state directory writable by service user
    chown :$groupname "$STATE_DIR/streams" 2>/dev/null || log "WARNING" "Failed to set group on $STATE_DIR/streams"
    chmod g+w "$STATE_DIR/streams" 2>/dev/null || log "WARNING" "Failed to set group write permission on $STATE_DIR/streams"
    
    return 0
}

# Comprehensive setup function for privilege dropping
setup_privilege_dropping() {
    # Only proceed if running as root
    if [ "$(id -u)" -ne 0 ]; then
        log "INFO" "Not running as root, skipping privilege dropping setup"
        PRIVILEGE_DROP_ENABLED=false
        return 1
    fi
    
    log "INFO" "Setting up privilege dropping"
    
    # Create and configure service user
    if create_service_user "$PRIVILEGE_DROP_USER" "$PRIVILEGE_DROP_GROUP"; then
        log "INFO" "Service user $PRIVILEGE_DROP_USER configured successfully"
    else
        log "ERROR" "Failed to configure service user $PRIVILEGE_DROP_USER"
        PRIVILEGE_DROP_ENABLED=false
        return 1
    fi
    
    # Setup hardware access permissions
    if setup_hardware_access "$PRIVILEGE_DROP_USER" "$PRIVILEGE_DROP_GROUP"; then
        log "INFO" "Hardware access configured successfully for $PRIVILEGE_DROP_USER"
    else
        log "WARNING" "Failed to configure hardware access for $PRIVILEGE_DROP_USER"
        # Continue anyway - might still work
    fi
    
    # Verify that the rtsp user can access audio devices
    if drop_privileges "$PRIVILEGE_DROP_USER" "test -r /dev/snd/controlC0 2>/dev/null || test -r /dev/snd/pcmC0D0c 2>/dev/null"; then
        log "INFO" "Verified $PRIVILEGE_DROP_USER can access audio devices"
    else
        log "WARNING" "$PRIVILEGE_DROP_USER cannot access audio devices, fixing permissions"
        
        # Fix permissions more aggressively for audio devices
        if [ -d "/dev/snd" ]; then
            find /dev/snd -type c -exec chmod a+rw {} \; 2>/dev/null || 
            find /dev/snd -type c -exec chmod 666 {} \; 2>/dev/null ||
            chmod -R a+rw /dev/snd/ 2>/dev/null || 
            log "ERROR" "Failed to set audio device permissions even with aggressive methods"
        fi
        
        # Verify again
        if drop_privileges "$PRIVILEGE_DROP_USER" "test -r /dev/snd/controlC0 2>/dev/null || test -r /dev/snd/pcmC0D0c 2>/dev/null"; then
            log "INFO" "Successfully fixed audio device permissions for $PRIVILEGE_DROP_USER"
        else
            log "WARNING" "Unable to grant $PRIVILEGE_DROP_USER access to audio devices"
            # Continue anyway - might still work with certain devices
        fi
    fi
    
    # Verify that we can actually run commands as the service user
    if drop_privileges "$PRIVILEGE_DROP_USER" "id -un"; then
        log "INFO" "Successfully verified privilege dropping functionality"
        PRIVILEGE_DROP_ENABLED=true
        return 0
    else
        log "ERROR" "Failed to verify privilege dropping functionality"
        PRIVILEGE_DROP_ENABLED=false
        return 1
    fi
}

# Start a stream with privilege dropping
start_stream_with_privilege_dropping() {
    local card_id="$1"
    local stream_name="$2"
    local rtsp_url="$3"
    local stream_log="$4"
    
    log "INFO" "Starting stream $stream_name with privilege dropping"
    
    # Ensure log file exists and is writable
    touch "$stream_log" 2>/dev/null || {
        stream_log="${TEMP_DIR}/${stream_name}_ffmpeg.log"
        touch "$stream_log" 2>/dev/null || {
            stream_log="/dev/null"
        }
    }
    chmod 666 "$stream_log" 2>/dev/null
    
    # Create PID file location
    local pid_file="${STATE_DIR}/streams/${stream_name}.pid"
    touch "$pid_file" 2>/dev/null && chmod 666 "$pid_file" 2>/dev/null
    
    # Prepare the ffmpeg command
    local ffmpeg_cmd="ffmpeg -nostdin -hide_banner -loglevel $FFMPEG_LOG_LEVEL \
        -f alsa -ac $AUDIO_CHANNELS -sample_rate $AUDIO_SAMPLE_RATE \
        -i plughw:CARD=$card_id,DEV=0 \
        -acodec $AUDIO_CODEC -b:a $AUDIO_BITRATE -ac $AUDIO_CHANNELS \
        -content_type 'audio/mpeg' ${FFMPEG_ADDITIONAL_OPTS:+"$FFMPEG_ADDITIONAL_OPTS"} \
        -f rtsp -rtsp_transport tcp $rtsp_url >> $stream_log 2>&1 & echo \$!"
    
    # Launch in a subshell to capture the PID
    log "DEBUG" "Executing ffmpeg as $PRIVILEGE_DROP_USER for $stream_name"
    
    # Get PID after privilege drop for ffmpeg process
    local pid=""
    pid=$(drop_privileges "$PRIVILEGE_DROP_USER" "$ffmpeg_cmd")
    
    # Clean and validate PID (fix for the integer comparison error)
    pid=$(ensure_integer "$pid" 0)
    
    # Check if we got a valid PID - use strict numeric comparison
    if [ "$pid" -eq 0 ]; then
        log "ERROR" "Failed to get valid PID for $stream_name"
        return 1
    fi
    
    # Verify the process is running
    if ! kill -0 "$pid" 2>/dev/null; then
        log "ERROR" "Process $pid for $stream_name is not running"
        return 1
    fi
    
    # Save PID to file
    echo "$pid" > "$pid_file" 2>/dev/null
    echo "$pid" >> "$PIDS_FILE"
    
    # Verify process ownership
    local process_user=""
    process_user=$(ps -o user= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    
    if [ "$process_user" = "$PRIVILEGE_DROP_USER" ]; then
        log "INFO" "Successfully started stream $stream_name with PID $pid as $PRIVILEGE_DROP_USER"
    else
        log "WARNING" "Stream $stream_name is running as $process_user, not $PRIVILEGE_DROP_USER"
    fi
    
    # Return the PID
    echo "$pid"
    return 0
}

# Reliable fallback function for starting streams as root
start_stream_as_root() {
    local card_id="$1"
    local stream_name="$2"
    local rtsp_url="$3"
    local stream_log="$4"
    
    log "INFO" "Starting stream $stream_name as root (fallback method)"
    
    # Ensure log file exists and is writable
    touch "$stream_log" 2>/dev/null || {
        log "ERROR" "Cannot create log file: $stream_log"
        stream_log="/dev/null"
    }
    
    local pid_file="${STATE_DIR}/streams/${stream_name}.pid"
    
    # Kill any existing processes for this stream to prevent duplicates
    pkill -f "ffmpeg.*$stream_name" 2>/dev/null || true
    sleep 1
    
    # Start FFMPEG directly as root - the simplest, most reliable method
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting stream $stream_name as root" >> "$stream_log"
    
    # Standard method, using background process
    ffmpeg -nostdin -hide_banner -loglevel "$FFMPEG_LOG_LEVEL" \
        -f alsa -ac "$AUDIO_CHANNELS" -sample_rate "$AUDIO_SAMPLE_RATE" \
        -i "plughw:CARD=${card_id},DEV=0" \
        -acodec "$AUDIO_CODEC" -b:a "$AUDIO_BITRATE" -ac "$AUDIO_CHANNELS" \
        -content_type 'audio/mpeg' ${FFMPEG_ADDITIONAL_OPTS:+"$FFMPEG_ADDITIONAL_OPTS"} \
        -f rtsp -rtsp_transport tcp "$rtsp_url" >> "$stream_log" 2>&1 &
    
    local pid=$!
    
    # Verify process started successfully
    if ! kill -0 "$pid" 2>/dev/null; then
        log "ERROR" "Failed to start ffmpeg process for $stream_name"
        return 1
    fi
    
    # Save PID to file for tracking
    echo "$pid" > "$pid_file" 2>/dev/null
    echo "$pid" >> "$PIDS_FILE"
    
    log "INFO" "Successfully started stream $stream_name as root (PID: $pid)"
    
    # Return the PID
    echo "$pid"
    return 0
}

# -------------------------------------------------------------------------
# END OF PRIVILEGE DROPPING IMPLEMENTATION
# -------------------------------------------------------------------------

# Clean up temporary script files
cleanup_temp_scripts() {
    log "DEBUG" "Cleaning up temporary script files"
    
    # Clean up any temporary script files that might have been created
    if [ -d "$SCRIPT_DIR" ]; then
        find "$SCRIPT_DIR" -name "*.sh" -type f -delete 2>/dev/null || true
    fi
    
    # Also check the main temp directory
    if [ -d "$TEMP_DIR" ]; then
        find "$TEMP_DIR" -name "*_cmd.sh" -type f -delete 2>/dev/null || true
    fi
}

# Further improved function to check running stream processes with strict integer handling
check_running_processes() {
    log "INFO" "Checking running stream processes"
    
    # Initialize counts with safe defaults
    local rtsp_procs=0
    local all_ffmpeg=0
    local root_procs=0
    
    # Get number of RTSP user processes - using single-step approach for better reliability
    if ps -u "$PRIVILEGE_DROP_USER" -o pid,cmd 2>/dev/null | grep -q "[f]fmpeg"; then
        # Store the output in a variable first to ensure proper handling
        local count_output=""
        count_output=$(ps -u "$PRIVILEGE_DROP_USER" -o pid,cmd 2>/dev/null | grep -c "[f]fmpeg" || echo "0")
        rtsp_procs=$(ensure_integer "$count_output" 0)
    fi
    
    # Get all ffmpeg processes - again using single-step approach
    if ps -eo pid,user,cmd 2>/dev/null | grep -q "[f]fmpeg.*rtsp"; then
        local count_output=""
        count_output=$(ps -eo pid,user,cmd 2>/dev/null | grep "[f]fmpeg.*rtsp" | wc -l || echo "0")
        all_ffmpeg=$(ensure_integer "$count_output" 0)
    fi
    
    # Calculate root processes with careful integer handling
    if [ "$all_ffmpeg" -gt "$rtsp_procs" ]; then
        root_procs=$((all_ffmpeg - rtsp_procs))
    fi
    
    log "INFO" "Current RTSP processes: $rtsp_procs as $PRIVILEGE_DROP_USER, $root_procs as root, $all_ffmpeg total"
    
    # If there are root processes, show details
    if [ "$root_procs" -gt 0 ]; then
        log "WARNING" "Found ffmpeg processes running as root:"
        ps -eo pid,user,cmd 2>/dev/null | grep "[f]fmpeg.*rtsp" | grep -v "$PRIVILEGE_DROP_USER" | while read -r line; do
            log "WARNING" "  $line"
        done
    fi
    
    # Return total count
    echo "$all_ffmpeg"
}

# Define default excluded devices
EXCLUDED_DEVICES=("bcm2835_headpho" "vc4-hdmi" "HDMI" "vc4hdmi0" "vc4hdmi1")

# Load custom blacklist if it exists
if [ -f "$DEVICE_BLACKLIST_FILE" ]; then
    log "INFO" "Loading custom blacklist from $DEVICE_BLACKLIST_FILE"
    while read -r line; do
        # Skip comments and empty lines
        if [[ "$line" =~ ^[[:space:]]*# || -z "$line" ]]; then
            continue
        fi
        # Extract device ID (remove trailing comments if any)
        device_id=${line%%#*}
        device_id=$(echo "$device_id" | tr -d '[:space:]')  # Trim whitespace
        if [ -n "$device_id" ]; then
            EXCLUDED_DEVICES+=("$device_id")
        fi
    done < "$DEVICE_BLACKLIST_FILE"
else
    # Create a default blacklist file if it doesn't exist
    log "INFO" "Creating default blacklist file"
    mkdir -p "$(dirname "$DEVICE_BLACKLIST_FILE")" 2>/dev/null || log "WARNING" "Failed to create blacklist directory"
    cat > "$DEVICE_BLACKLIST_FILE" << EOF || log "WARNING" "Failed to create default blacklist file"
# Audio Device Blacklist - Add devices you want to exclude from streaming
# One device ID per line. Comments start with #

# Default excluded devices
bcm2835_headpho  # Raspberry Pi onboard audio output (no capture)
vc4-hdmi         # Raspberry Pi HDMI audio output (no capture)
HDMI             # Generic HDMI audio output (no capture)
vc4hdmi0         # Raspberry Pi HDMI0 audio output (no capture)
vc4hdmi1         # Raspberry Pi HDMI1 audio output (no capture)

# Add your custom exclusions below
EOF
fi

log "INFO" "Excluded devices: ${EXCLUDED_DEVICES[*]}"

# Function to check if a sound card has a capture device
has_capture_device() {
    local card=$1
    if arecord -l 2>/dev/null | grep -q "card $card"; then
        return 0  # Has capture device
    else
        return 1  # No capture device
    fi
}

# Function to test if ffmpeg can capture from a device - with multiple retries
test_device_capture() {
    local card_id="$1"
    local max_retries=2
    local retry=0
    
    log "INFO" "Testing capture from card: $card_id"
    
    while [ "$retry" -le "$max_retries" ]; do
        # Try plughw first (safer and handles format conversion)
        if timeout 3 ffmpeg -nostdin -f alsa -ac "$AUDIO_CHANNELS" -i "plughw:CARD=${card_id},DEV=0" \
             -t 0.1 -f null - > /dev/null 2>&1; then
            log "INFO" "Successfully captured audio from card: $card_id using plughw"
            return 0
        fi
        
        # Try hw device directly
        if timeout 3 ffmpeg -nostdin -f alsa -ac "$AUDIO_CHANNELS" -i "hw:CARD=${card_id},DEV=0" \
             -t 0.1 -f null - > /dev/null 2>&1; then
            log "INFO" "Successfully captured audio from card: $card_id using hw"
            return 0
        fi
        
        # Try default device
        if timeout 3 ffmpeg -nostdin -f alsa -ac "$AUDIO_CHANNELS" -i "default:CARD=${card_id}" \
             -t 0.1 -f null - > /dev/null 2>&1; then
            log "INFO" "Successfully captured audio from card: $card_id using default device"
            return 0
        fi
        
        retry=$((retry + 1))
        log "WARNING" "Retry $retry/$max_retries for device $card_id"
        sleep 1
    done
    
    # Add additional recovery logic by enhancing error detection to prevent hanging
    if [ "$retry" -gt "$max_retries" ] && [ -e "/dev/snd" ]; then
        # Check if device permissions might be the issue
        log "DEBUG" "Checking audio device permissions after failure"
        ls -la /dev/snd/by-path/*${card_id}* 2>/dev/null || ls -la /dev/snd/* 2>/dev/null | while read -r line; do
            log "DEBUG" "Audio device: $line"
        done
        
        # Try to fix permissions as a last resort if running as root
        if [ "$(id -u)" -eq 0 ]; then
            log "INFO" "Attempting to fix audio device permissions as last resort"
            chmod -R a+rX /dev/snd/ 2>/dev/null || true
            return 1
        fi
    fi
    
    log "WARNING" "Could not capture from card $card_id after $max_retries retries"
    return 1
}

# Function to create a consistent unique identifier for a device
get_device_uuid() {
    local card_id="$1"
    local usb_info="$2"
    
    # For USB devices, use device-specific info to create a stable identifier
    if [ -n "$usb_info" ]; then
        # Extract vendor/product information if possible
        if [[ "$usb_info" =~ ([A-Za-z0-9]+:[A-Za-z0-9]+) ]]; then
            local vendor_product="${BASH_REMATCH[1]}"
            echo "${card_id}_${vendor_product}" | tr -d ' '
        else
            # Fall back to a hash of the full USB info for uniqueness
            local hash=""
            hash=$(echo "$usb_info" | md5sum | cut -c1-8)
            echo "${card_id}_${hash}" | tr -d ' '
        fi
    else
        # For non-USB devices, just use the card ID
        echo "$card_id" | tr -d ' '
    fi
}

# Function to get a user-friendly stream name
get_stream_name() {
    local card_id="$1"
    local device_uuid="$2"
    
    # First check if we have a mapped name for this device
    if [ -f "$DEVICE_MAP_FILE" ]; then
        local mapped_name=""
        mapped_name=$(grep "^$device_uuid=" "$DEVICE_MAP_FILE" 2>/dev/null | cut -d= -f2)
        if [ -n "$mapped_name" ]; then
            echo "$mapped_name"
            return
        fi
    fi
    
    # No mapping found, use sanitized card_id
    echo "$card_id" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g'
}

# Updated main start_stream function with improved error handling
start_stream() {
    local card_num="$1"
    local card_id="$2"
    local usb_info="$3"
    local device_uuid="$4"
    local stream_name="$5"
    local rtsp_url="rtsp://localhost:$RTSP_PORT/$stream_name"
    local stream_log="${LOG_DIR}/${stream_name}_ffmpeg.log"
    
    # Check if MediaMTX is running before attempting to start streams
    # Don't fail completely if MediaMTX is not running - we can continue and retry later
    if ! command -v nc >/dev/null 2>&1 || ! nc -z -w 2 localhost "$RTSP_PORT" >/dev/null 2>&1; then
        log "WARNING" "RTSP server is not accessible on port $RTSP_PORT"
        log "INFO" "Attempting to start MediaMTX..."
        
        start_mediamtx
        # Continue even if MediaMTX fails to start - streams will wait for server
    fi
    
    # Check for device-specific config
    local device_config="${DEVICE_CONFIG_DIR}/${stream_name}.conf"
    local using_device_config=false
    
    # Save global audio settings before potentially overriding them
    local global_audio_channels="$AUDIO_CHANNELS"
    local global_audio_sample_rate="$AUDIO_SAMPLE_RATE"
    local global_audio_bitrate="$AUDIO_BITRATE"
    local global_audio_codec="$AUDIO_CODEC"
    local global_ffmpeg_additional_opts="$FFMPEG_ADDITIONAL_OPTS"
    
    # Load device-specific config if available
    if [ -f "$device_config" ]; then
        log "INFO" "Loading device-specific config for $stream_name: $device_config"
        # shellcheck disable=SC1090
        source "$device_config" 2>/dev/null || log "WARNING" "Error loading device config"
        using_device_config=true
    else
        log "INFO" "No device-specific config found for $stream_name, using global settings"
    fi
    
    # Create fresh log file
    log "INFO" "Creating stream log file: $stream_log"
    > "$stream_log" 2>/dev/null || {
        log "WARNING" "Failed to create stream log file, will try again during stream start"
    }
    
    log "INFO" "Starting stream: $rtsp_url"
    
    # Try to start the stream with privilege dropping if enabled
    local pid=0
    
    if [ "$PRIVILEGE_DROP_ENABLED" = true ]; then
        log "INFO" "Attempting to start stream with privilege dropping"
        pid=$(start_stream_with_privilege_dropping "$card_id" "$stream_name" "$rtsp_url" "$stream_log")
        pid=$(ensure_integer "$pid" 0)
    fi
    
    # Fall back to running as root if privilege dropping fails or is disabled
    if [ "$pid" -eq 0 ]; then
        log "INFO" "Starting stream as root"
        pid=$(start_stream_as_root "$card_id" "$stream_name" "$rtsp_url" "$stream_log")
        pid=$(ensure_integer "$pid" 0)
    fi
    
    # Verify we got a valid PID
    if [ "$pid" -eq 0 ] || ! kill -0 "$pid" 2>/dev/null; then
        log "ERROR" "Failed to start stream for $stream_name"
        
        # Restore global settings
        AUDIO_CHANNELS="$global_audio_channels"
        AUDIO_SAMPLE_RATE="$global_audio_sample_rate"
        AUDIO_BITRATE="$global_audio_bitrate"
        AUDIO_CODEC="$global_audio_codec"
        FFMPEG_ADDITIONAL_OPTS="$global_ffmpeg_additional_opts"
        
        return 1
    fi
    
    # Get the actual user of the process one more time for verification
    local process_user=""
    process_user=$(ps -o user= -p "$pid" 2>/dev/null || echo "unknown")
    process_user=$(echo "$process_user" | tr -d '[:space:]')
    
    log "INFO" "Confirmed stream for card $card_num ($card_id) running with PID $pid as user $process_user"
    
    # Save PID to state directory for monitoring
    mkdir -p "${STATE_DIR}/streams" 2>/dev/null || log "WARNING" "Failed to create streams state directory"
    echo "$pid" > "${STATE_DIR}/streams/${stream_name}.pid" 2>/dev/null
    
    # Create example device config if it doesn't exist
    if [ "$using_device_config" = false ] && [ ! -f "$device_config" ] && [ ! -f "${device_config}.example" ]; then
        log "INFO" "Creating example device config for $stream_name"
        mkdir -p "$DEVICE_CONFIG_DIR" 2>/dev/null || log "WARNING" "Failed to create device config directory"
        cat > "${device_config}.example" << EOF || log "WARNING" "Failed to create example config file"
# Device-specific configuration for $stream_name
# Rename this file to $stream_name.conf (remove .example) to activate
# Created on $(date)

# Audio settings for this device
AUDIO_CHANNELS=$global_audio_channels
AUDIO_SAMPLE_RATE=$global_audio_sample_rate
AUDIO_BITRATE=$global_audio_bitrate
AUDIO_CODEC="$global_audio_codec"

# Advanced settings
# FFMPEG_ADDITIONAL_OPTS=""
EOF
    fi
    
    # Restore global settings for next device
    AUDIO_CHANNELS="$global_audio_channels"
    AUDIO_SAMPLE_RATE="$global_audio_sample_rate"
    AUDIO_BITRATE="$global_audio_bitrate"
    AUDIO_CODEC="$global_audio_codec"
    FFMPEG_ADDITIONAL_OPTS="$global_ffmpeg_additional_opts"
    
    return 0
}

# New lock file handling function with improved reliability
setup_lock_file() {
    log "INFO" "Setting up lock file"

    # Skip lock file if the force flag is set
    if [ -n "$1" ] && [ "$1" = "skip" ]; then
        log "INFO" "Skipping lock file check due to skip flag"
        return 0
    fi

    # Check if lock file already exists
    if [ -f "$LOCK_FILE" ]; then
        # Read PID from lock file
        local lock_pid=""
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "")
        
        # Ensure we have a valid integer
        lock_pid=$(ensure_integer "$lock_pid" 0)
        
        # Check if the process is still running - use numeric comparison
        if [ "$lock_pid" -gt 0 ] && kill -0 "$lock_pid" 2>/dev/null; then
            # Make sure it's actually our script
            if ps -p "$lock_pid" -o cmd= 2>/dev/null | grep -q "startmic\.sh"; then
                log "WARNING" "Another instance is already running with PID $lock_pid"
                
                # If the script receives FORCE_EXIT=true, it should exit
                if [ "$FORCE_EXIT" = true ]; then
                    log "ERROR" "Forced exit due to another instance running"
                    exit 15  # Standard systemd error code for 'service already running'
                else
                    # For startup diagnostics, we'll skip lock file checks
                    log "WARNING" "Continuing anyway for diagnostic purposes. Will exit if confirmed duplicate."
                fi
            else
                log "WARNING" "Found PID in lock file but it's not our script. Removing stale lock file."
                rm -f "$LOCK_FILE" 2>/dev/null
            fi
        else
            log "WARNING" "Stale lock file found, removing"
            rm -f "$LOCK_FILE" 2>/dev/null
        fi
    fi

    # Create lock file with atomic write
    atomic_write "$LOCK_FILE" "$$" || {
        log "ERROR" "Failed to create lock file: $LOCK_FILE"
        
        # Try direct write as last resort
        echo "$$" > "$LOCK_FILE" 2>/dev/null || {
            log "ERROR" "Failed to create lock file with direct write"
            
            # Try creating in /tmp as a last resort
            if echo "$$" > "/tmp/startmic.lock" 2>/dev/null; then
                LOCK_FILE="/tmp/startmic.lock"
                log "WARNING" "Using alternative lock file: $LOCK_FILE"
            else
                log "WARNING" "Cannot create lock file. Continuing without lock."
            fi
        }
    }

    log "INFO" "Lock file created successfully: $LOCK_FILE (PID: $$)"
    return 0
}

# Improved quick cleanup function for shutdown - focuses on speed
fast_cleanup() {
    log "INFO" "Performing fast cleanup for shutdown"
    
    # Set marker to indicate we're in cleanup mode
    FORCE_EXIT=true
    
    # Kill all ffmpeg processes immediately with SIGTERM
    pkill -15 -f "ffmpeg.*rtsp" 2>/dev/null || true
    
    # Kill any privilege dropping processes
    pkill -15 -f "su.*$PRIVILEGE_DROP_USER" 2>/dev/null || true
    pkill -15 -f "runuser.*$PRIVILEGE_DROP_USER" 2>/dev/null || true
    pkill -15 -f "setpriv.*reuid=$PRIVILEGE_DROP_USER" 2>/dev/null || true
    
    # Remove critical temp files
    rm -f "$PIDS_FILE" "$TEMP_FILE" "$LOCK_FILE" 2>/dev/null || true
    
    log "INFO" "Fast cleanup completed"
    exit 0
}

# Improved clean up function for graceful exit with better systemd compatibility
cleanup() {
    if [ "$FORCE_EXIT" = true ]; then
        log "INFO" "Cleanup already in progress, exiting immediately"
        exit 0
    fi
    
    # Prevent re-entry
    FORCE_EXIT=true
    
    log "INFO" "Starting cleanup process..."
    
    # Register a timeout for cleanup to ensure we don't hang
    # This ensures systemd doesn't need to SIGKILL our process
    (
        sleep 5
        if [ -e "/proc/$TIMEOUT_PID" ]; then
            log "WARNING" "Cleanup timeout reached - forcing immediate exit"
            fast_cleanup
        fi
    ) &
    TIMEOUT_PID=$!
    
    # Handle nested child processes
    pkill -P "$TIMEOUT_PID" 2>/dev/null || true
    
    # Find and kill all child processes of our script
    pkill -P $$ 2>/dev/null || true
    
    # Stop all ffmpeg processes we started
    if [ -f "$PIDS_FILE" ]; then
        log "INFO" "Stopping processes listed in PID file"
        
        # First try SIGTERM
        while read -r pid; do
            # Ensure pid is a clean integer
            pid=$(ensure_integer "$pid" 0)
            
            # Only try to kill valid PIDs
            if [ "$pid" -gt 0 ]; then
                # Check if process exists before attempting to kill
                if kill -0 "$pid" 2>/dev/null; then
                    log "DEBUG" "Sending SIGTERM to process $pid"
                    kill -15 "$pid" 2>/dev/null || true
                fi
            fi
        done < "$PIDS_FILE"
        
        # Wait briefly for processes to terminate
        sleep 1
        
        # Force kill any remaining processes after waiting
        for pid in $(cat "$PIDS_FILE" 2>/dev/null); do
            pid=$(ensure_integer "$pid" 0)
            if [ "$pid" -gt 0 ] && kill -0 "$pid" 2>/dev/null; then
                log "WARNING" "Process $pid still alive, sending SIGKILL"
                kill -9 "$pid" 2>/dev/null || true
            fi
        done
    fi
    
    # Find any orphaned ffmpeg processes - focus on speed with simple patterns
    pkill -15 -f "ffmpeg.*rtsp" 2>/dev/null || true
    
    # Kill any privilege dropping processes
    pkill -15 -f "su.*$PRIVILEGE_DROP_USER" 2>/dev/null || true
    pkill -15 -f "runuser.*$PRIVILEGE_DROP_USER" 2>/dev/null || true
    pkill -15 -f "setpriv.*reuid=$PRIVILEGE_DROP_USER" 2>/dev/null || true
    
    # Close all non-essential file descriptors
    for fd in $(ls /proc/$$/fd/ 2>/dev/null); do
        # Skip standard file descriptors (0, 1, 2) and those we need to keep open
        if [ "$fd" -gt 2 ] && [ "$fd" -ne 255 ]; then
            # Try to identify what the file descriptor is connected to
            fd_target=$(readlink /proc/$$/fd/$fd 2>/dev/null || echo "unknown")
            # Skip our critical files
            if [[ "$fd_target" != *"$LOCK_FILE"* ]] && 
               [[ "$fd_target" != *"$PID_FILE"* ]] && 
               [[ "$fd_target" != *"$LOG_FILE"* ]]; then
                log "DEBUG" "Closing file descriptor $fd -> $fd_target"
                eval "exec $fd>&-" 2>/dev/null || true
            fi
        fi
    done
    
    # Remove temporary files - only do the essential ones
    log "DEBUG" "Removing temporary files"
    rm -f "$PIDS_FILE" "$TEMP_FILE" "$LOCK_FILE" 2>/dev/null || true
    
    # Kill the timeout process since we've completed
    kill $TIMEOUT_PID 2>/dev/null || true
    
    log "INFO" "Cleanup completed"
    exit 0
}

# Set up trap for cleanup on exit with better systemd compatibility
trap cleanup EXIT
trap fast_cleanup INT TERM HUP

# Set up lock file first to prevent multiple instances
# Use skip parameter for initial run to prevent premature exits
setup_lock_file "skip"

# Clean up existing processes
clean_processes

# Check sound card order - don't touch, battle-tested
fix_card_order

# Run environment checks
check_environment

# Set up privilege dropping if running as root
if setup_privilege_dropping; then
    log "INFO" "Privilege dropping configured successfully"
else
    log "WARNING" "Privilege dropping could not be configured, will run as root"
    PRIVILEGE_DROP_ENABLED=false
fi

# Now set up the lock file properly
setup_lock_file

# Initialize PID file using atomic_write
atomic_write "$PIDS_FILE" ""

# Get list of sound cards
log "INFO" "Detecting sound cards..."
SOUND_CARDS=$(cat /proc/asound/cards 2>/dev/null)
if [ -z "$SOUND_CARDS" ]; then
    log "ERROR" "No sound cards detected"
    # Write success marker for systemd even though no cards found
    atomic_write "${RUNTIME_DIR}/startmic_success" "STARTED"
    # Set flag to indicate startup is complete - will prevent quick restart cycle
    STARTUP_COMPLETE=true
    exit 0
fi

# Make sure MediaMTX is running before starting streams
if ! check_mediamtx_status; then
    log "WARNING" "MediaMTX is not running - attempting to start it"
    if ! start_mediamtx; then
        log "ERROR" "Failed to start MediaMTX - streams may not work properly"
        # Set indicator file for this issue
        atomic_write "${RUNTIME_DIR}/mediamtx_failed" "$(date)"
        # Continue anyway - we'll try to recover later
    fi
fi

# Double-check after attempting to start
if ! check_mediamtx_status; then
    log "ERROR" "MediaMTX is still not running after startup attempts"
    log "WARNING" "Continuing anyway, but streams will likely fail to connect"
else
    log "INFO" "MediaMTX is running on port $RTSP_PORT"
fi

# Initialize streaming counter
STREAMS_CREATED=0

# Parse sound cards and create streams
# This is battle-tested - do not modify
while read -r line; do
    if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]*\[([^]]+)\][[:space:]]*:[[:space:]]*(.*) ]]; then
        CARD_NUM=${BASH_REMATCH[1]}
        CARD_ID=${BASH_REMATCH[2]}
        CARD_DESC=${BASH_REMATCH[3]}
        
        # Remove leading/trailing whitespace from card ID
        CARD_ID=$(echo "$CARD_ID" | tr -d '[:space:]')
        
        log "INFO" "Found sound card $CARD_NUM: $CARD_ID - $CARD_DESC"
        
        # Check if we've hit max streams limit
        if [ "$STREAMS_CREATED" -ge "$MAX_STREAMS" ]; then
            log "WARNING" "Maximum number of streams ($MAX_STREAMS) reached, skipping remaining devices"
            break
        fi
        
        # Check if this device should be excluded
        EXCLUDED=0
        for excluded in "${EXCLUDED_DEVICES[@]}"; do
            if [ "$CARD_ID" = "$excluded" ]; then
                log "INFO" "Skipping excluded device: $CARD_ID"
                EXCLUDED=1
                break
            fi
        done
        
        if [ $EXCLUDED -eq 1 ]; then
            continue
        fi
        
        # Check if this card has capture capabilities
        if has_capture_device "$CARD_NUM"; then
            # Test if we can open the device
            if ! test_device_capture "$CARD_ID"; then
                log "WARNING" "Skipping card $CARD_NUM [$CARD_ID] - failed capture test"
                continue
            fi
            
            # Extract USB device info if available
            USB_INFO=""
            if [[ "$CARD_DESC" =~ USB-Audio ]]; then
                USB_INFO=$(echo "$CARD_DESC" | sed -n 's/.*USB-Audio - \(.*\)/\1/p')
            fi
            
            # Generate a stable, unique identifier for this device
            DEVICE_UUID=$(get_device_uuid "$CARD_ID" "$USB_INFO")
            
            # Get a stable, human-readable stream name
            STREAM_NAME=$(get_stream_name "$CARD_ID" "$DEVICE_UUID")
            
            log "INFO" "Creating stream for card $CARD_NUM [$CARD_ID]: $STREAM_NAME"
            
            # Store the stream details for display
            echo "$CARD_NUM|$CARD_ID|$USB_INFO|rtsp://localhost:$RTSP_PORT/$STREAM_NAME|$DEVICE_UUID|$STREAM_NAME" >> "$TEMP_FILE"
            
            # Start stream with device-specific config if available
            if start_stream "$CARD_NUM" "$CARD_ID" "$USB_INFO" "$DEVICE_UUID" "$STREAM_NAME"; then
                STREAMS_CREATED=$((STREAMS_CREATED + 1))
            fi
            
            # Small delay to stagger the starts
            sleep 1
        else
            log "INFO" "Skipping card $CARD_NUM [$CARD_ID] - no capture device found"
        fi
    fi
done <<< "$SOUND_CARDS"

# Create or update the device map file
if [ "$STREAMS_CREATED" -gt 0 ] && [ -f "$TEMP_FILE" ]; then
    # Create the device map file if it doesn't exist
    if [ ! -f "$DEVICE_MAP_FILE" ]; then
        log "INFO" "Creating device map file: $DEVICE_MAP_FILE"
        mkdir -p "$(dirname "$DEVICE_MAP_FILE")" 2>/dev/null || log "WARNING" "Failed to create device map directory"
        
        cat > "$DEVICE_MAP_FILE" << EOF || log "WARNING" "Failed to create device map file"
# Audio Device Map - Edit this file to give devices persistent, friendly names
# Format: DEVICE_UUID=friendly_name
# Do not change the DEVICE_UUID values as they are used for consistent identification

EOF
        
        # Add initial entries for detected devices
        while IFS='|' read -r card_num card_id usb_info rtsp_url device_uuid stream_name; do
            # Use sanitized card ID as the default name
            sanitized=$(echo "$card_id" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')
            echo "$device_uuid=$sanitized" >> "$DEVICE_MAP_FILE"
        done < "$TEMP_FILE"
        
        log "INFO" "Created device map file: $DEVICE_MAP_FILE"
    else
        # Update existing map file with any new devices
        while IFS='|' read -r card_num card_id usb_info rtsp_url device_uuid stream_name; do
            # Check if this UUID is already in the file
            if ! grep -q "^$device_uuid=" "$DEVICE_MAP_FILE" 2>/dev/null; then
                # Add a sanitized default name
                sanitized=$(echo "$card_id" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g')
                echo "$device_uuid=$sanitized" >> "$DEVICE_MAP_FILE"
                log "INFO" "Added new device to map: $device_uuid=$sanitized"
            fi
        done < "$TEMP_FILE"
    fi
fi

# Verify that streams are actually running
sleep 2  # Give processes time to fully initialize

# Count running ffmpeg processes - completely rewritten approach to avoid bugs
ACTUAL_STREAMS=0

# Safe process count approach with proper scoping
if command -v pgrep >/dev/null 2>&1; then
    # Use pgrep which is safer
    proc_count=$(pgrep -c -f "ffmpeg.*rtsp://localhost:$RTSP_PORT" 2>/dev/null || echo "0")
    ACTUAL_STREAMS=$(ensure_integer "$proc_count" 0)
else
    # Fallback to grep/wc but with careful validation
    if ps -eo pid,cmd 2>/dev/null | grep -q "[f]fmpeg.*rtsp://localhost:$RTSP_PORT"; then
        proc_count=$(ps -eo pid,cmd 2>/dev/null | grep "[f]fmpeg.*rtsp://localhost:$RTSP_PORT" | wc -l || echo "0")
        ACTUAL_STREAMS=$(ensure_integer "$proc_count" 0)
    fi
fi

if [ "$ACTUAL_STREAMS" -gt 0 ]; then
    STREAMS_CREATED=$ACTUAL_STREAMS
    log "INFO" "Verified $STREAMS_CREATED running ffmpeg RTSP streams"
    
    # Count streams by user with proper integer handling
    rtsp_streams=0
    root_streams=0
    
    if [ "$PRIVILEGE_DROP_ENABLED" = true ]; then
        # Separate check to avoid empty grep results
        if ps -u "$PRIVILEGE_DROP_USER" -o cmd= 2>/dev/null | grep -q "ffmpeg.*rtsp://localhost:$RTSP_PORT"; then
            proc_count=$(ps -u "$PRIVILEGE_DROP_USER" -o cmd= 2>/dev/null | grep -c "ffmpeg.*rtsp://localhost:$RTSP_PORT" || echo "0")
            rtsp_streams=$(ensure_integer "$proc_count" 0)
        fi
        
        # Safe integer subtraction with validation
        if [ "$ACTUAL_STREAMS" -gt "$rtsp_streams" ]; then
            root_streams=$((ACTUAL_STREAMS - rtsp_streams))
        fi
        
        log "INFO" "Streams by user: $PRIVILEGE_DROP_USER=$rtsp_streams, root=$root_streams"
    fi
else
    log "WARNING" "No running RTSP streams detected"
    
    # Check if MediaMTX is running as that's a common cause of failures
    if ! check_mediamtx_status; then
        log "ERROR" "RTSP server is not accessible on port $RTSP_PORT"
        log "INFO" "Final attempt to start MediaMTX service..."
        start_mediamtx
    fi
    
    STREAMS_CREATED=0
    rtsp_streams=0
    root_streams=0
fi

# Completely rewritten table display to eliminate broken pipe errors
if [ -f "$TEMP_FILE" ] && [ "$STREAMS_CREATED" -gt 0 ]; then
    # Create a file with the table content (no pipes or subshells)
    TABLE_FILE="${TEMP_DIR}/stream_table.txt"
    
    # Write the header to the file
    {
        echo ""
        echo "================================================================="
        echo "                  ACTIVE AUDIO RTSP STREAMS                      "
        echo "================================================================="
        echo "Card | Card ID         | USB Device                      | RTSP URL"
        echo "-----------------------------------------------------------------"
    } > "$TABLE_FILE"
    
    # Process each line individually and append to the file
    while IFS='|' read -r card_num card_id usb_info rtsp_url device_uuid stream_name; do
        # Truncate long fields for better display
        if [ ${#card_id} -gt 15 ]; then
            card_id="${card_id:0:12}..."
        fi
        if [ ${#usb_info} -gt 30 ]; then
            usb_info="${usb_info:0:27}..."
        fi
        
        # Add padding to columns for consistent display
        padded_card_id="$card_id                "  # Add extra spaces
        padded_card_id="${padded_card_id:0:15}"    # Truncate to desired length
        
        padded_usb_info="$usb_info                                "  # Add extra spaces
        padded_usb_info="${padded_usb_info:0:30}"  # Truncate to desired length
        
        # Write the line to the file
        echo "$card_num   | $padded_card_id | $padded_usb_info | $rtsp_url" >> "$TABLE_FILE"
    done < "$TEMP_FILE"
    
    # Write the footer to the file
    {
        echo "================================================================="
        echo ""
    } >> "$TABLE_FILE"
    
    # Get IP information and append to file
    IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "localhost")
    if [ -n "$IP_ADDR" ] && [ "$IP_ADDR" != "localhost" ]; then
        echo "To access streams from other devices, replace 'localhost' with '$IP_ADDR'" >> "$TABLE_FILE"
        echo "" >> "$TABLE_FILE"
    fi
    
    # Add configuration information
    {
        echo "To customize stream names, edit: $DEVICE_MAP_FILE"
        echo "To configure per-device settings, edit files in: $DEVICE_CONFIG_DIR/"
        echo "To blacklist devices, edit: $DEVICE_BLACKLIST_FILE"
        echo ""
    } >> "$TABLE_FILE"
    
    # Add privilege dropping status
    if [ "$PRIVILEGE_DROP_ENABLED" = true ]; then
        # Safely count processes running as the rtsp user
        if [ "$rtsp_streams" -gt 0 ]; then
            echo "$rtsp_streams streams are running with reduced privileges (user: $PRIVILEGE_DROP_USER)" >> "$TABLE_FILE"
        else
            echo "Streams are running as root (privilege dropping didn't work)" >> "$TABLE_FILE"
        fi
    else
        echo "Streams are running as root (privilege dropping not available)" >> "$TABLE_FILE"
    fi
    echo "" >> "$TABLE_FILE"
    
    # Display the table only if it exists and has content
    if [ -f "$TABLE_FILE" ] && [ -s "$TABLE_FILE" ]; then
        # Use cat with no pipes to avoid broken pipe errors
        cat "$TABLE_FILE" 2>/dev/null
        # Clean up the temporary file
        rm -f "$TABLE_FILE" 2>/dev/null || true
    fi
    
    log "INFO" "Successfully started $STREAMS_CREATED audio streams"
else
    log "WARNING" "No audio streams were created. Check if you have audio capture devices connected."
    
    # Display a simple message without using pipes
    echo "" 
    echo "No audio streams were created. Check if you have audio capture devices connected."
    echo ""
fi

# Write success marker for systemd
atomic_write "${RUNTIME_DIR}/startmic_success" "STARTED"

# Mark startup as complete - critical to prevent fast exit cycles
STARTUP_COMPLETE=true

# Enhanced stream monitoring function without local variable declaration errors
monitor_streams() {
    log "INFO" "Starting monitor loop for child processes..."
    log "INFO" "Using RTSP port: $RTSP_PORT"
    
    # Initialize monitoring variables
    restart_attempts=0
    last_check_time=0
    current_time=0
    status_interval=300  # Log status every 5 minutes
    last_status_time=0
    
    # Initialize additional monitoring variables
    log_check_interval=3600  # Check logs every hour
    last_log_check=0
    memory_cleanup_interval=21600  # Memory optimization every 6 hours
    last_memory_cleanup=0
    hourly_scan_interval=3600  # Scan for new devices every hour
    last_device_scan=0
    stream_quality_interval=900  # Check stream quality every 15 minutes
    last_quality_check=0
    
    # Record start time
    service_start_time=$(date +%s)
    atomic_write "${STATE_DIR}/service_start_time" "$service_start_time"
    
    # Create monitor state directory
    mkdir -p "${STATE_DIR}/monitoring" 2>/dev/null || log "WARNING" "Failed to create monitoring state directory"
    
    # Keep the script running - critical for systemd
    while true; do
        # Check if force exit has been triggered
        if [ "$FORCE_EXIT" = true ]; then
            log "INFO" "Force exit triggered during monitoring, cleaning up and exiting"
            break
        fi
        
        # Get current time for checks
        current_time=$(date +%s)
        
        # Periodic status logging
        if [ $((current_time - last_status_time)) -ge "$status_interval" ]; then
            uptime=$((current_time - service_start_time))
            uptime_hours=$((uptime / 3600))
            uptime_minutes=$(( (uptime % 3600) / 60 ))
            
            # Log resource usage if available - use more robust methods
            memory_usage=0
            if command -v free > /dev/null 2>&1; then
                # Avoid piping and use multiple steps
                if free 2>/dev/null | grep -q "Mem:"; then
                    mem_total=$(free | grep "Mem:" | awk '{print $2}')
                    mem_used=$(free | grep "Mem:" | awk '{print $3}')
                    
                    # Validate numbers before calculation
                    mem_total=$(ensure_integer "$mem_total" 1)
                    mem_used=$(ensure_integer "$mem_used" 0)
                    
                    # Calculate percentage safely
                    if [ "$mem_total" -gt 0 ]; then
                        memory_usage=$((mem_used * 100 / mem_total))
                    fi
                fi
            fi
            
            log "INFO" "Service status: Running for ${uptime_hours}h ${uptime_minutes}m, memory usage: ${memory_usage}%"
            
            # Check running processes with simpler safer approach
            running_count=$(check_running_processes)
            log "DEBUG" "Found $running_count running stream processes"
            
            # Count streams by user to report correctly
            rtsp_streams=0
            root_streams=0
            
            if [ "$PRIVILEGE_DROP_ENABLED" = true ]; then
                # Separate check to avoid empty grep results
                if ps -u "$PRIVILEGE_DROP_USER" -o cmd= 2>/dev/null | grep -q "ffmpeg.*rtsp://localhost:$RTSP_PORT"; then
                    proc_count=$(ps -u "$PRIVILEGE_DROP_USER" -o cmd= 2>/dev/null | grep -c "ffmpeg.*rtsp://localhost:$RTSP_PORT" || echo "0")
                    rtsp_streams=$(ensure_integer "$proc_count" 0)
                fi
                
                # Calculate root processes safely
                if [ "$running_count" -gt "$rtsp_streams" ]; then
                    root_streams=$((running_count - rtsp_streams))
                fi
            fi
            
            # Generate health status report 
            report_health_status "$uptime" "$running_count" "$rtsp_streams" "$root_streams" "$memory_usage"
            
            # Check if MediaMTX is still running
            if ! check_mediamtx_status; then
                log "WARNING" "MediaMTX is not running, attempting to restart"
                if start_mediamtx; then
                    log "INFO" "Successfully restarted MediaMTX"
                else
                    log "ERROR" "Failed to restart MediaMTX"
                fi
            fi
            
            last_status_time=$current_time
        fi
        
        # Check log file size every hour
        if [ $((current_time - last_log_check)) -ge "$log_check_interval" ]; then
            last_log_check=$current_time
            rotate_logs
        fi
        
        # Perform memory optimization every 6 hours
        if [ $((current_time - last_memory_cleanup)) -ge "$memory_cleanup_interval" ]; then
            log "INFO" "Performing periodic memory optimization"
            last_memory_cleanup=$current_time
            
            # Clear large variable contents
            if [ -f "$TEMP_FILE" ]; then
                # Preserve TEMP_FILE by making a copy and then replacing
                cp "$TEMP_FILE" "${TEMP_FILE}.bak"
                cat "${TEMP_FILE}.bak" > "$TEMP_FILE"
                rm -f "${TEMP_FILE}.bak"
            fi
            
            # Force garbage collection in bash by clearing variables
            SOUND_CARDS=""
            cleanup_temp_scripts
            
            # Log memory usage after cleanup
            if command -v free >/dev/null 2>&1; then
                mem_used=$(free | grep "Mem:" | awk '{print $3}')
                mem_total=$(free | grep "Mem:" | awk '{print $2}')
                
                mem_used=$(ensure_integer "$mem_used" 0)
                mem_total=$(ensure_integer "$mem_total" 1)
                
                if [ "$mem_total" -gt 0 ]; then
                    memory_usage=$((mem_used * 100 / mem_total))
                    log "INFO" "Memory usage after optimization: ${memory_usage}%"
                fi
            fi
        fi
        
        # Check stream quality every 15 minutes
        if [ $((current_time - last_quality_check)) -ge "$stream_quality_interval" ]; then
            last_quality_check=$current_time
            log "INFO" "Checking stream quality"
            
            # Look through recent log entries for quality issues
            for stream_log in "$LOG_DIR"/*_ffmpeg.log; do
                if [ -f "$stream_log" ]; then
                    stream_name=$(basename "$stream_log" _ffmpeg.log)
                    
                    # Check for common errors indicating quality issues
                    error_count=0
                    if tail -n 500 "$stream_log" 2>/dev/null | grep -q "Error\|error\|failed\|underrun\|overrun"; then
                        error_count=$(tail -n 500 "$stream_log" 2>/dev/null | grep -c "Error\|error\|failed\|underrun\|overrun")
                        error_count=$(ensure_integer "$error_count" 0)
                        
                        if [ "$error_count" -gt 10 ]; then
                            log "WARNING" "Stream $stream_name has $error_count quality issues"
                            
                            # Find PID and check if still running
                            pid_file="${STATE_DIR}/streams/${stream_name}.pid"
                            if [ -f "$pid_file" ]; then
                                pid=$(cat "$pid_file" 2>/dev/null)
                                pid=$(ensure_integer "$pid" 0)
                                
                                if [ "$pid" -gt 0 ] && kill -0 "$pid" 2>/dev/null; then
                                    log "INFO" "Attempting to restart stream $stream_name due to quality issues"
                                    kill -15 "$pid" 2>/dev/null
                                    sleep 2
                                    
                                    # Look up stream info and restart
                                    if [ -f "$TEMP_FILE" ]; then
                                        stream_info=$(grep "|$stream_name\$" "$TEMP_FILE" || echo "")
                                        if [ -n "$stream_info" ]; then
                                            IFS='|' read -r card_num card_id usb_info rtsp_url device_uuid stream_name_conf <<< "$stream_info"
                                            start_stream "$card_num" "$card_id" "$usb_info" "$device_uuid" "$stream_name"
                                        fi
                                    fi
                                fi
                            fi
                        fi
                    fi
                fi
            done
        fi
        
        # Periodically check for new or reconnected devices (every hour)
        if [ $((current_time - last_device_scan)) -ge "$hourly_scan_interval" ]; then
            log "INFO" "Performing periodic device scan for new or reconnected devices"
            last_device_scan=$current_time
            
            # Get current sound cards
            NEW_SOUND_CARDS=$(cat /proc/asound/cards 2>/dev/null)
            
            # Look for new devices not already streaming
            while read -r line; do
                if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]*\[([^]]+)\][[:space:]]*:[[:space:]]*(.*) ]]; then
                    CARD_NUM=${BASH_REMATCH[1]}
                    CARD_ID=${BASH_REMATCH[2]}
                    CARD_DESC=${BASH_REMATCH[3]}
                    
                    # Remove leading/trailing whitespace from card ID
                    CARD_ID=$(echo "$CARD_ID" | tr -d '[:space:]')
                    
                    # Skip if already streaming this device
                    if [ -f "$TEMP_FILE" ] && grep -q "|$CARD_ID|" "$TEMP_FILE"; then
                        continue
                    fi
                    
                    # Check if it's excluded
                    EXCLUDED=0
                    for excluded in "${EXCLUDED_DEVICES[@]}"; do
                        if [ "$CARD_ID" = "$excluded" ]; then
                            EXCLUDED=1
                            break
                        fi
                    done
                    
                    if [ $EXCLUDED -eq 1 ]; then
                        continue
                    fi
                    
                    # Check if it has capture capability and try to set up a stream
                    if has_capture_device "$CARD_NUM" && test_device_capture "$CARD_ID"; then
                        log "INFO" "Found new/reconnected capture device: $CARD_ID"
                        
                        # Extract USB device info if available
                        USB_INFO=""
                        if [[ "$CARD_DESC" =~ USB-Audio ]]; then
                            USB_INFO=$(echo "$CARD_DESC" | sed -n 's/.*USB-Audio - \(.*\)/\1/p')
                        fi
                        
                        # Generate a stable, unique identifier for this device
                        DEVICE_UUID=$(get_device_uuid "$CARD_ID" "$USB_INFO")
                        
                        # Get a stable, human-readable stream name
                        STREAM_NAME=$(get_stream_name "$CARD_ID" "$DEVICE_UUID")
                        
                        log "INFO" "Setting up stream for newly detected card $CARD_NUM [$CARD_ID]: $STREAM_NAME"
                        
                        # Start stream with device-specific config if available
                        if start_stream "$CARD_NUM" "$CARD_ID" "$USB_INFO" "$DEVICE_UUID" "$STREAM_NAME"; then
                            # Add to temp file for future reference
                            echo "$CARD_NUM|$CARD_ID|$USB_INFO|rtsp://localhost:$RTSP_PORT/$STREAM_NAME|$DEVICE_UUID|$STREAM_NAME" >> "$TEMP_FILE"
                            log "INFO" "Successfully started stream for new device $CARD_ID"
                        fi
                    fi
                fi
            done <<< "$NEW_SOUND_CARDS"
        fi
        
        # Only check streams at specified interval
        if [ $((current_time - last_check_time)) -ge "$STREAM_CHECK_INTERVAL" ]; then
            last_check_time=$current_time
            
            # Check if any ffmpeg processes are still running - use safer approach
            running_processes=0
            # Split into two steps to avoid empty grep issues
            if ps -eo pid,cmd 2>/dev/null | grep -q "[f]fmpeg.*rtsp://localhost:$RTSP_PORT"; then
                proc_count=$(ps -eo pid,cmd 2>/dev/null | grep "[f]fmpeg.*rtsp://localhost:$RTSP_PORT" | wc -l || echo "0")
                running_processes=$(ensure_integer "$proc_count" 0)
            fi
            
            # Check individual streams by PID file
            if [ -d "${STATE_DIR}/streams" ] && [ "$running_processes" -gt 0 ]; then
                # Check each stream PID file
                for pid_file in "${STATE_DIR}/streams/"*.pid; do
                    if [ -f "$pid_file" ]; then
                        stream_name=$(basename "$pid_file" .pid)
                        pid=$(cat "$pid_file" 2>/dev/null || echo "0")
                        pid=$(ensure_integer "$pid" 0)
                        
                        # Check if process is running
                        if [ "$pid" -gt 0 ] && ! kill -0 "$pid" 2>/dev/null; then
                            log "WARNING" "Stream $stream_name (PID $pid) is not running"
                            
                            # Look up the card information from the temp file
                            if [ -f "$TEMP_FILE" ]; then
                                stream_info=$(grep "|$stream_name\$" "$TEMP_FILE" || echo "")
                                if [ -n "$stream_info" ]; then
                                    IFS='|' read -r card_num card_id usb_info rtsp_url device_uuid stream_name_conf <<< "$stream_info"
                                    log "INFO" "Attempting to restart stream $stream_name for card $card_id"
                                    
                                    # Attempt to restart the stream
                                    if start_stream "$card_num" "$card_id" "$usb_info" "$device_uuid" "$stream_name"; then
                                        log "INFO" "Successfully restarted stream $stream_name"
                                    else
                                        log "ERROR" "Failed to restart stream $stream_name"
                                    fi
                                fi
                            fi
                        fi
                    fi
                done
            fi
            
            if [ "$running_processes" -eq 0 ] && [ "$STREAMS_CREATED" -gt 0 ]; then
                # Increment restart attempts
                restart_attempts=$((restart_attempts + 1))
                
                log "WARNING" "No ffmpeg RTSP processes found. Attempt ${restart_attempts}/${MAX_RESTART_ATTEMPTS}"
                
                # Check RTSP server first
                if ! check_mediamtx_status; then
                    log "ERROR" "RTSP server is not accessible on port $RTSP_PORT"
                    
                    # Try to restart MediaMTX
                    log "INFO" "Attempting to restart MediaMTX"
                    if start_mediamtx; then
                        log "INFO" "Successfully restarted MediaMTX"
                    else
                        log "ERROR" "Failed to restart MediaMTX"
                    fi
                fi
                
                # Check if max attempts reached
                if [ "$restart_attempts" -ge "$MAX_RESTART_ATTEMPTS" ]; then
                    log "ERROR" "Maximum restart attempts ($MAX_RESTART_ATTEMPTS) reached."
                    log "ERROR" "Exiting monitoring to allow systemd to handle service restart"
                    atomic_write "${STATE_DIR}/restart_failures" "$restart_attempts"
                    break
                fi
                
                # Sleep before next check
                sleep "$RESTART_DELAY"
            else
                # Reset restart counter if we have processes running
                if [ "$restart_attempts" -gt 0 ] && [ "$running_processes" -gt 0 ]; then
                    log "INFO" "Streams are now running. Resetting restart counter."
                    restart_attempts=0
                    atomic_write "${STATE_DIR}/restart_attempts" "0"
                fi
            fi
        fi
        
        # Clean up any stale temp script files (older than 10 minutes)
        if [ -d "$SCRIPT_DIR" ]; then
            find "$SCRIPT_DIR" -name "*.sh" -type f -mmin +10 -delete 2>/dev/null || true
        fi
        
        # Sleep for a safe interval (5 seconds)
        sleep 5
    done
}

# If running as a systemd service, monitor streams
if [ -d "/run/systemd/system" ]; then
    log "INFO" "Running as a systemd service, monitoring streams"
    # Ensure startup is completely done before monitoring starts
    STARTUP_COMPLETE=true
    monitor_streams
else
    # If running as a regular script, just wait for termination
    log "INFO" "Press Ctrl+C to stop all streams and exit"
    # Ensure startup is completely done
    STARTUP_COMPLETE=true
    # Wait for any background processes to exit 
    wait
fi
