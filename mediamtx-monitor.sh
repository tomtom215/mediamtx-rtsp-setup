#!/bin/bash
# MediaMTX Resource Monitor with Enhanced Reliability
#
# https://raw.githubusercontent.com/tomtom215/mediamtx-rtsp-setup/refs/heads/main/mediamtx-monitor.sh
#
# Version: 1.2.0
# Date: 2025-05-15
# Description: Monitors MediaMTX health and resources with progressive recovery strategies
#              Handles CPU, memory, file descriptors and network monitoring
#              Includes recovery levels and trend analysis
#              Added enhanced reliability features for 24/7 operation
# Changes in v1.1.0:
#   - Added enhanced lock file recovery to prevent file descriptor leaks
#   - Implemented disk space monitoring with emergency cleanup
#   - Added deadman switch to prevent reboot loops
#   - Added self-limiting resource usage for the monitor itself
#   - Enhanced process uniqueness verification
#   - Improved cleanup handler with comprehensive resource release
# Changes in v1.2.0:
#   - Fixed lock file race conditions with robust flock-based implementation
#   - Improved self-limiting resource constraints
#   - Enhanced resource trend analysis with statistical smoothing
#   - Strengthened deadman switch with persistent state tracking
#   - Improved atomic file operations for state management
#   - Added more resilient error recovery for critical subsystems

# ======================================================================
# Configuration and Setup
# ======================================================================

# Exit on pipe failures to catch errors in piped commands
set -o pipefail

# Set script version
SCRIPT_VERSION="1.2.0"

# Create unique ID for this instance
INSTANCE_ID="$$-$(date +%s)"

# Default configuration values (overridden by config file)
CONFIG_DIR="/etc/audio-rtsp"
CONFIG_FILE="${CONFIG_DIR}/config"
MEDIAMTX_PATH="/usr/local/mediamtx/mediamtx"
MEDIAMTX_NAME="mediamtx"
MEDIAMTX_SERVICE="mediamtx.service"
RTSP_PORT="18554"
LOG_DIR="/var/log/audio-rtsp"
MONITOR_LOG="${LOG_DIR}/mediamtx-monitor.log"
RECOVERY_LOG="${LOG_DIR}/recovery-actions.log"
STATE_DIR="${LOG_DIR}/state"
STATS_DIR="${LOG_DIR}/stats"
TEMP_DIR="/tmp/mediamtx-monitor-${INSTANCE_ID}"

# Resource thresholds
CPU_THRESHOLD=80
CPU_WARNING_THRESHOLD=70
CPU_SUSTAINED_PERIODS=3
CPU_TREND_PERIODS=10
CPU_CHECK_INTERVAL=60
MEMORY_THRESHOLD=15
MEMORY_WARNING_THRESHOLD=12
MAX_UPTIME=86400
MAX_RESTART_ATTEMPTS=5
RESTART_COOLDOWN=300
REBOOT_THRESHOLD=3
ENABLE_AUTO_REBOOT=false
REBOOT_COOLDOWN=1800
EMERGENCY_CPU_THRESHOLD=95
EMERGENCY_MEMORY_THRESHOLD=20
FILE_DESCRIPTOR_THRESHOLD=1000
COMBINED_CPU_THRESHOLD=200
COMBINED_CPU_WARNING=150

# Disk space monitoring thresholds
DISK_WARNING_THRESHOLD=80  # Warning at 80% disk usage
DISK_CRITICAL_THRESHOLD=90 # Critical at 90% disk usage
DISK_CHECK_INTERVAL=300    # Check disk space every 5 minutes

# Deadman switch settings
MAX_REBOOTS_IN_DAY=5       # Maximum allowed reboots in 24 hours
REBOOT_HISTORY_FILE=""     # Will be set after STATE_DIR is finalized
DEADMAN_LOCKOUT_FILE=""    # Will be set during init_deadman_switch

# Lock file settings 
LOCK_FILE="${TEMP_DIR}/monitor.lock"
LOCK_FD=9                  # File descriptor for lock file
PID_FILE="${TEMP_DIR}/monitor.pid"

# Color codes for terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# State tracking variables
recovery_level=0
last_restart_time=0
restart_attempts_count=0
last_reboot_time=0
last_resource_warning=0
consecutive_failed_restarts=0
uses_systemd=false

# ======================================================================
# Self-Limiting Resource Usage
# ======================================================================

# Set resource limits for the monitor itself to avoid becoming part of the problem
set_resource_limits() {
    if command -v ulimit >/dev/null 2>&1; then
        # Set file descriptor limits (lower than the monitoring threshold)
        local fd_limit=$((FILE_DESCRIPTOR_THRESHOLD / 2))
        ulimit -n $fd_limit 2>/dev/null || true
        
        # Set virtual memory limit (512MB should be plenty for a monitoring script)
        ulimit -v 524288 2>/dev/null || true
        
        # Limit CPU time (not supported on all systems)
        ulimit -t 3600 2>/dev/null || true
        
        log "INFO" "Set self-limiting resource caps: $fd_limit file descriptors, 512MB virtual memory"
    else
        log "WARNING" "ulimit command not available, unable to set resource limits"
    fi
}

# ======================================================================
# Process Uniqueness Verification
# ======================================================================

# Verify this is the only instance of the monitor running
verify_unique_instance() {
    log "INFO" "Verifying monitor uniqueness"
    
    # Method 1: Check PID file
    if [ -f "$PID_FILE" ]; then
        local old_pid=$(cat "$PID_FILE" 2>/dev/null || echo "0")
        if [[ -n "$old_pid" && "$old_pid" != "0" ]]; then
            # Check if process still exists
            if kill -0 "$old_pid" 2>/dev/null; then
                # Process exists, check if it's actually our monitor
                if ps -p "$old_pid" -o cmd= 2>/dev/null | grep -q "mediamtx-monitor"; then
                    log "ERROR" "Another monitor instance is already running (PID: $old_pid)"
                    return 1
                else
                    log "WARNING" "PID file exists but process is not a monitor. Cleaning up."
                    rm -f "$PID_FILE"
                fi
            else
                log "WARNING" "Found stale PID file. Cleaning up."
                rm -f "$PID_FILE"
            fi
        fi
    fi
    
    # Method 2: Look for other instances by command name
    local script_name=$(basename "$0")
    local other_instances=$(pgrep -f "$script_name" | grep -v "^$$\$" || true)
    
    if [ -n "$other_instances" ]; then
        # Verify these are actually monitor processes, not just similarly named
        local actual_monitors=0
        for pid in $other_instances; do
            if ps -p "$pid" -o cmd= 2>/dev/null | grep -q "mediamtx-monitor"; then
                actual_monitors=$((actual_monitors + 1))
                log "ERROR" "Found another monitor instance: PID $pid"
            fi
        done
        
        if [ "$actual_monitors" -gt 0 ]; then
            log "ERROR" "Total of $actual_monitors other monitor instances detected"
            return 1
        fi
    fi
    
    # Method 3: Check for system lock file (extra safety)
    if [ -f "/var/run/mediamtx-monitor.lock" ]; then
        local lock_pid=$(cat "/var/run/mediamtx-monitor.lock" 2>/dev/null || echo "0")
        if [[ -n "$lock_pid" && "$lock_pid" != "0" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            log "ERROR" "System-wide lock file indicates another instance (PID: $lock_pid)"
            return 1
        else
            log "WARNING" "Found stale system lock file. Cleaning up."
            rm -f "/var/run/mediamtx-monitor.lock"
        fi
    fi
    
    # We appear to be unique - create the system lock file
    mkdir -p "/var/run" 2>/dev/null || true
    if echo "$$" > "/var/run/mediamtx-monitor.lock" 2>/dev/null; then
        log "INFO" "Created system-wide lock file"
    else
        log "WARNING" "Could not create system-wide lock file. Continuing anyway."
    fi
    
    log "INFO" "Monitor verified as unique instance"
    return 0
}

# ======================================================================
# Helper Functions
# ======================================================================

# Function for handling script errors
handle_error() {
    local line_number=$1
    local error_code=$2
    echo "[$line_number] [ERROR] Error at line ${line_number}: Command exited with status ${error_code}" >> "$MONITOR_LOG"
    
    # Check for open file descriptors and clean them up
    if [ -e "/proc/$$/fd/$LOCK_FD" ]; then
        echo "[$line_number] [WARNING] Detected open lock file descriptor in error handler" >> "$MONITOR_LOG"
        eval "exec $LOCK_FD>&-" 2>/dev/null
    fi
}

# Trap for error handling
trap 'handle_error $LINENO $?' ERR

# Function for logging with timestamps and levels
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    # Create log directories if they don't exist
    mkdir -p "$(dirname "$MONITOR_LOG")" "$(dirname "$RECOVERY_LOG")" 2>/dev/null
    
    # Create a temp file for atomic writes to avoid partial messages
    local temp_log_file="${TEMP_DIR}/log.${level}.${INSTANCE_ID}.tmp"
    
    # Ensure temp directory exists
    mkdir -p "${TEMP_DIR}" 2>/dev/null
    
    # Write message to temp file
    echo "[$timestamp] [$level] $message" > "$temp_log_file"
    
    # Atomically append to log file
    cat "$temp_log_file" >> "$MONITOR_LOG"
    
    # If it's a recovery action, also log to the recovery log
    if [[ "$level" == "RECOVERY" || "$level" == "REBOOT" || "$level" == "FATAL" ]]; then
        cat "$temp_log_file" >> "$RECOVERY_LOG"
    fi
    
    # If running in terminal, also output to stdout with colors
    if [ -t 1 ]; then
        case "$level" in
            "INFO")
                echo -e "${GREEN}[$timestamp] [$level]${NC} $message"
                ;;
            "WARNING")
                echo -e "${YELLOW}[$timestamp] [$level]${NC} $message"
                ;;
            "ERROR"|"FATAL")
                echo -e "${RED}[$timestamp] [$level]${NC} $message"
                ;;
            "RECOVERY")
                echo -e "${BLUE}[$timestamp] [$level]${NC} $message"
                ;;
            "REBOOT")
                echo -e "${RED}[$timestamp] [$level]${NC} $message"
                ;;
            *)
                echo -e "[$timestamp] [$level] $message"
                ;;
        esac
    fi
    
    # Clean up temp file
    rm -f "$temp_log_file"
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Atomic file write to avoid race conditions
atomic_write() {
    local file="$1"
    local content="$2"
    
    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$file")" 2>/dev/null
    
    # Create temp file with unique name
    local temp_file="${TEMP_DIR}/atomic_write.${INSTANCE_ID}.tmp"
    
    # Write content to temp file
    echo "$content" > "$temp_file"
    
    # Move temp file to destination with atomic rename operation
    if ! mv -f "$temp_file" "$file"; then
        log "ERROR" "Failed to atomically write to $file"
        return 1
    fi
    
    return 0
}

# Atomic append to file (read current content, append, write atomically)
atomic_append() {
    local file="$1"
    local content="$2"
    
    # Create directory if it doesn't exist
    mkdir -p "$(dirname "$file")" 2>/dev/null
    
    # Create temp file with unique name
    local temp_file="${TEMP_DIR}/atomic_append.${INSTANCE_ID}.tmp"
    
    # Read existing content if file exists
    if [ -f "$file" ]; then
        cat "$file" > "$temp_file" 2>/dev/null
    else
        # Ensure temp file exists even if original doesn't
        touch "$temp_file"
    fi
    
    # Append new content to temp file
    echo "$content" >> "$temp_file"
    
    # Move temp file to destination with atomic rename operation
    if ! mv -f "$temp_file" "$file"; then
        log "ERROR" "Failed to atomically append to $file"
        return 1
    fi
    
    return 0
}

# ======================================================================
# Disk Space Monitoring
# ======================================================================

# Function to check disk space and take action if needed
check_disk_space() {
    local log_dir=$(dirname "$MONITOR_LOG")
    
    # Get disk usage percentage for the log directory
    local disk_usage
    if command_exists df; then
        disk_usage=$(df -P "$log_dir" 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
        
        # If df failed or returned non-numeric, try an alternative approach
        if [[ ! "$disk_usage" =~ ^[0-9]+$ ]]; then
            log "WARNING" "Failed to get disk usage with df, trying alternative method"
            disk_usage=$(df -P "$log_dir" 2>/dev/null | tail -1 | awk '{print int($3*100/$2)}')
        fi
        
        # If still failed, set to unknown
        if [[ ! "$disk_usage" =~ ^[0-9]+$ ]]; then
            log "ERROR" "Failed to determine disk usage"
            return 1
        fi
        
        # Record disk usage for trend analysis
        atomic_write "${STATE_DIR}/disk_usage" "$disk_usage"
        
        # Take action based on thresholds
        if [ "$disk_usage" -ge "$DISK_CRITICAL_THRESHOLD" ]; then
            log "ERROR" "Disk space critical: ${disk_usage}% used on log partition"
            
            # Emergency cleanup
            log "RECOVERY" "Performing emergency log cleanup"
            
            # 1. Rotate logs immediately
            if command_exists logrotate && [ -f "/etc/logrotate.d/audio-rtsp" ]; then
                logrotate -f /etc/logrotate.d/audio-rtsp
                log "INFO" "Forced log rotation"
            fi
            
            # 2. Remove old rotated logs
            find "$LOG_DIR" -name "*.gz" -type f -delete
            log "INFO" "Removed compressed log archives"
            
            # 3. Truncate large logs
            find "$LOG_DIR" -name "*.log" -type f -size +10M -exec truncate -s 5M {} \;
            log "INFO" "Truncated oversized log files"
            
            # 4. Remove old state files
            find "${STATE_DIR}" -type f -mtime +7 -delete
            log "INFO" "Cleaned up old state files"
            
            # Check disk space again after cleanup
            local new_usage=$(df -P "$log_dir" 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
            log "INFO" "Disk usage after cleanup: ${new_usage}% (was ${disk_usage}%)"
            
            # If still critical, take more drastic measures
            if [ "$new_usage" -ge "$DISK_CRITICAL_THRESHOLD" ]; then
                log "ERROR" "Disk space still critical after cleanup"
                
                # Find and remove the largest files in the log directory
                find "$LOG_DIR" -type f -not -path "*/state/*" | xargs du -h 2>/dev/null | sort -hr | head -10 | while read -r size file; do
                    log "WARNING" "Removing large file: $file ($size)"
                    rm -f "$file"
                done
                
                # If we're being super aggressive, truncate ALL logs
                find "$LOG_DIR" -name "*.log" -type f -exec truncate -s 0 {} \;
                
                # Add marker to avoid repeated aggressive cleanup
                atomic_write "${STATE_DIR}/emergency_cleanup_performed" "$(date +%s)"
            fi
            
            return 1
        elif [ "$disk_usage" -ge "$DISK_WARNING_THRESHOLD" ]; then
            log "WARNING" "Disk space warning: ${disk_usage}% used on log partition"
            
            # Perform lighter cleanup
            log "INFO" "Performing preventative log cleanup"
            
            # 1. Remove old logs (older than 30 days)
            find "$LOG_DIR" -name "*.log.*" -type f -mtime +30 -delete
            
            # 2. Compress large logs
            find "$LOG_DIR" -name "*.log" -type f -size +50M -exec gzip -f {} \; 2>/dev/null || true
            
            return 0
        else
            # Normal disk usage
            return 0
        fi
    else
        log "WARNING" "df command not available to check disk space"
        return 1
    fi
}

# ======================================================================
# Enhanced Lock File Recovery
# ======================================================================

# Acquire lock with enhanced error handling - IMPROVED IMPLEMENTATION
acquire_lock() {
    local lock_file="$1"
    local lock_fd="$2"
    local timeout="${3:-10}"  # Default timeout of 10 seconds
    
    log "DEBUG" "Attempting to acquire lock: $lock_file (FD: $lock_fd, timeout: ${timeout}s)"
    
    # Check if file descriptor is already in use
    if [ -e "/proc/$$/fd/$lock_fd" ]; then
        log "WARNING" "File descriptor $lock_fd is already in use, closing it first"
        eval "exec $lock_fd>&-" 2>/dev/null
    fi
    
    # Make sure the directory exists
    mkdir -p "$(dirname "$lock_file")" 2>/dev/null
    
    # Open the file descriptor
    eval "exec $lock_fd>\"$lock_file\"" || {
        log "ERROR" "Failed to open lock file: $lock_file"
        return 1
    }
    
    # Try to acquire the lock with timeout using flock
    if command_exists flock; then
        if ! flock -w "$timeout" -n "$lock_fd"; then
            log "ERROR" "Failed to acquire lock within ${timeout}s timeout"
            eval "exec $lock_fd>&-" 2>/dev/null
            return 1
        fi
    else
        # Fallback if flock is not available
        log "WARNING" "flock command not available, using basic file locking"
        
        # Simple PID-based locking
        if [ -s "$lock_file" ]; then
            local pid_in_lock=$(cat "$lock_file" 2>/dev/null)
            if [ -n "$pid_in_lock" ] && kill -0 "$pid_in_lock" 2>/dev/null; then
                log "ERROR" "Process $pid_in_lock already holds the lock"
                eval "exec $lock_fd>&-" 2>/dev/null
                return 1
            else
                log "WARNING" "Stale lock found, overriding"
            fi
        fi
    fi
    
    # Store our PID in the lock file
    echo "$$" >&$lock_fd
    
    log "DEBUG" "Successfully acquired lock: $lock_file"
    return 0
}

# Release lock with enhanced verification - IMPROVED IMPLEMENTATION
release_lock() {
    local lock_fd="$1"
    
    log "DEBUG" "Releasing lock on file descriptor $lock_fd"
    
    # Verify the file descriptor exists before trying to close
    if [ -e "/proc/$$/fd/$lock_fd" ]; then
        # Close the file descriptor to release the lock
        eval "exec $lock_fd>&-" 2>/dev/null
        log "DEBUG" "Lock file descriptor closed"
    else
        log "WARNING" "File descriptor $lock_fd not found or already closed"
    fi
}

# ======================================================================
# Deadman Switch for Reboot Protection
# ======================================================================

# Initialize the deadman switch - IMPROVED IMPLEMENTATION
init_deadman_switch() {
    REBOOT_HISTORY_FILE="${STATE_DIR}/reboot_history.txt"
    DEADMAN_LOCKOUT_FILE="${STATE_DIR}/deadman_lockout"
    
    # Check for emergency override file
    if [ -f "${CONFIG_DIR}/emergency_disable_reboot" ]; then
        log "WARNING" "Found emergency reboot disable flag, auto-reboot will be disabled"
        ENABLE_AUTO_REBOOT=false
        
        # Ensure we have a record of why this happened
        if [ ! -f "${STATE_DIR}/disable_reason.txt" ]; then
            echo "Emergency disable triggered at $(date)" > "${STATE_DIR}/disable_reason.txt"
        fi
    fi
    
    # Create reboot history file if it doesn't exist
    if [ ! -f "$REBOOT_HISTORY_FILE" ]; then
        log "INFO" "Initializing reboot history tracking"
        mkdir -p "$(dirname "$REBOOT_HISTORY_FILE")" 2>/dev/null
        touch "$REBOOT_HISTORY_FILE"
    fi
    
    # Clean up old entries (keep only last 30 days)
    if [ -f "$REBOOT_HISTORY_FILE" ]; then
        local current_time=$(date +%s)
        local thirty_days_ago=$((current_time - 2592000))
        
        # Create a temporary file with only recent entries
        local temp_file="${TEMP_DIR}/reboot_history.tmp"
        touch "$temp_file"
        
        # Filter to keep only entries from the last 30 days
        while read -r timestamp; do
            if [[ "$timestamp" =~ ^[0-9]+$ ]] && [ "$timestamp" -gt "$thirty_days_ago" ]; then
                echo "$timestamp" >> "$temp_file"
            fi
        done < "$REBOOT_HISTORY_FILE"
        
        # Replace the original file
        mv "$temp_file" "$REBOOT_HISTORY_FILE"
    fi
    
    # Check for deadman lockout in effect
    if [ -f "$DEADMAN_LOCKOUT_FILE" ]; then
        local lockout_time=$(cat "$DEADMAN_LOCKOUT_FILE" 2>/dev/null || echo "0")
        local current_time=$(date +%s)
        
        # If lockout was within the last 24 hours, prevent reboots
        if [ "$lockout_time" -gt $((current_time - 86400)) ]; then
            log "FATAL" "Deadman switch lockout is in effect until $(date -d @$((lockout_time + 86400)))"
            ENABLE_AUTO_REBOOT=false
            
            # Notify all logged-in users about the lockout
            if command_exists wall; then
                wall "CRITICAL: MediaMTX monitor deadman switch has locked out automatic reboots due to excessive failures. Manual intervention required."
            fi
        else
            # Lockout has expired
            log "WARNING" "Previous deadman switch lockout has expired, resetting"
            rm -f "$DEADMAN_LOCKOUT_FILE"
        fi
    fi
    
    log "INFO" "Deadman switch initialized"
}

# Check if we've exceeded the reboot limit
check_reboot_limit() {
    # If auto-reboot is disabled, no need to check
    if [ "$ENABLE_AUTO_REBOOT" != true ]; then
        return 1
    fi
    
    if [ ! -f "$REBOOT_HISTORY_FILE" ]; then
        log "WARNING" "Reboot history file not found"
        return 0
    fi
    
    local current_time=$(date +%s)
    local day_ago=$((current_time - 86400))
    local recent_reboots=0
    
    # Count reboots in the last 24 hours
    while read -r timestamp; do
        if [[ "$timestamp" =~ ^[0-9]+$ ]] && [ "$timestamp" -gt "$day_ago" ]; then
            recent_reboots=$((recent_reboots + 1))
        fi
    done < "$REBOOT_HISTORY_FILE"
    
    log "INFO" "Found $recent_reboots reboots in the last 24 hours"
    
    # Update the counter in state
    atomic_write "${STATE_DIR}/recent_reboots" "$recent_reboots"
    
    # Check if we've exceeded the limit
    if [ "$recent_reboots" -ge "$MAX_REBOOTS_IN_DAY" ]; then
        log "FATAL" "Too many reboots in 24 hours ($recent_reboots), disabling auto-reboot"
        
        # Create emergency disable file
        atomic_write "${CONFIG_DIR}/emergency_disable_reboot" "1"
        
        # Set deadman lockout
        atomic_write "$DEADMAN_LOCKOUT_FILE" "$current_time"
        
        # Disable auto-reboot for this session
        ENABLE_AUTO_REBOOT=false
        
        # Send alert if possible
        if command_exists wall; then
            echo "ALERT: MediaMTX monitor has detected $recent_reboots reboots in 24 hours and has disabled auto-reboot." | wall
        fi
        
        return 1
    fi
    
    return 0
}

# Record a reboot in the history
record_reboot() {
    local current_time=$(date +%s)
    
    # Append the current timestamp to the history file
    atomic_append "$REBOOT_HISTORY_FILE" "$current_time"
    
    # Also log the reboot
    log "REBOOT" "Recorded reboot at $(date)"
}

# ======================================================================
# Initialization Functions
# ======================================================================

# Load configuration from config file
load_config() {
    log "INFO" "Initializing MediaMTX Monitor v${SCRIPT_VERSION}"
    
    # Load configuration file if it exists
    if [ -f "$CONFIG_FILE" ]; then
        log "INFO" "Loading configuration from $CONFIG_FILE"
        
        # Source the config file in a safe way
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
        
        log "INFO" "Configuration loaded: CPU threshold: ${CPU_THRESHOLD}%, Memory threshold: ${MEMORY_THRESHOLD}%"
    else
        log "WARNING" "Configuration file not found at $CONFIG_FILE, using defaults"
    fi
    
    # Create required directories
    mkdir -p "$TEMP_DIR" "$STATE_DIR" "$STATS_DIR" 2>/dev/null || {
        log "ERROR" "Failed to create required directories"
        # Try alternate locations if primary ones fail
        TEMP_DIR="/tmp/mediamtx-monitor-${INSTANCE_ID}"
        STATE_DIR="/tmp/mediamtx-monitor-state"
        STATS_DIR="/tmp/mediamtx-monitor-stats"
        mkdir -p "$TEMP_DIR" "$STATE_DIR" "$STATS_DIR" 2>/dev/null || {
            log "ERROR" "Failed to create even fallback directories. Cannot continue."
            exit 1
        }
    }
    
    # Set appropriate permissions
    chmod 755 "$STATE_DIR" "$STATS_DIR" 2>/dev/null || 
        log "WARNING" "Failed to set permissions on state directories"
    
    # Update lock file location after finalizing directories
    LOCK_FILE="${TEMP_DIR}/monitor.lock"
    PID_FILE="${TEMP_DIR}/monitor.pid"
    
    # Check if we can use systemctl to manage MediaMTX
    uses_systemd=false
    if command_exists systemctl; then
        if systemctl list-unit-files | grep -q "$MEDIAMTX_SERVICE"; then
            uses_systemd=true
            log "INFO" "Using systemd to manage MediaMTX service ($MEDIAMTX_SERVICE)"
        else
            log "WARNING" "MediaMTX service not found in systemd ($MEDIAMTX_SERVICE), falling back to process management"
        fi
    else
        log "WARNING" "systemd not available, using direct process management"
    fi
    
    # Initialize deadman switch
    init_deadman_switch
    
    # Set self-imposed resource limits
    set_resource_limits
    
    # Verify this is the only instance running
    if ! verify_unique_instance; then
        log "FATAL" "Another instance of the monitor is already running, exiting"
        exit 1
    fi
    
    # Load previous state if available
    load_previous_state
    
    # Set up traps for cleanup
    trap cleanup_handler SIGINT SIGTERM HUP
}

# Load previous state from state files
load_previous_state() {
    local current_time=$(date +%s)
    
    # Handle last_restart_time
    if [ -f "${STATE_DIR}/last_restart_time" ]; then
        last_restart_time=$(cat "${STATE_DIR}/last_restart_time" 2>/dev/null || echo "0")
        # Validate timestamp is not zero or empty
        if [ -z "$last_restart_time" ] || [ "$last_restart_time" = "0" ] || ! [[ "$last_restart_time" =~ ^[0-9]+$ ]]; then
            log "WARNING" "Invalid last restart time found, initializing to current time"
            last_restart_time=$current_time
            atomic_write "${STATE_DIR}/last_restart_time" "$last_restart_time"
        fi
    else
        # Initialize with current time if file doesn't exist
        last_restart_time=$current_time
        atomic_write "${STATE_DIR}/last_restart_time" "$last_restart_time"
        log "INFO" "Initialized last restart time to current time"
    fi
    
    # Format and log the time in human-readable format
    local formatted_restart_time=$(date -d "@$last_restart_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$last_restart_time")
    log "INFO" "Loaded last restart time: $formatted_restart_time"
    
    # Handle last_reboot_time
    if [ -f "${STATE_DIR}/last_reboot_time" ]; then
        last_reboot_time=$(cat "${STATE_DIR}/last_reboot_time" 2>/dev/null || echo "0")
        # Validate timestamp is not zero or empty
        if [ -z "$last_reboot_time" ] || [ "$last_reboot_time" = "0" ] || ! [[ "$last_reboot_time" =~ ^[0-9]+$ ]]; then
            log "WARNING" "Invalid last reboot time found, initializing to current time"
            last_reboot_time=$current_time
            atomic_write "${STATE_DIR}/last_reboot_time" "$last_reboot_time"
        fi
    else
        # Initialize with current time if file doesn't exist
        last_reboot_time=$current_time
        atomic_write "${STATE_DIR}/last_reboot_time" "$last_reboot_time"
        log "INFO" "Initialized last reboot time to current time"
    fi
    
    # Format and log the time in human-readable format
    local formatted_reboot_time=$(date -d "@$last_reboot_time" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$last_reboot_time")
    log "INFO" "Loaded last reboot time: $formatted_reboot_time"
    
    # Handle consecutive_failed_restarts
    if [ -f "${STATE_DIR}/consecutive_failed_restarts" ]; then
        consecutive_failed_restarts=$(cat "${STATE_DIR}/consecutive_failed_restarts" 2>/dev/null || echo "0")
        # Validate number is not empty and is numeric
        if [ -z "$consecutive_failed_restarts" ] || ! [[ "$consecutive_failed_restarts" =~ ^[0-9]+$ ]]; then
            log "WARNING" "Invalid consecutive failed restarts count found, resetting to 0"
            consecutive_failed_restarts=0
            atomic_write "${STATE_DIR}/consecutive_failed_restarts" "0"
        fi
    else
        # Initialize with 0 if file doesn't exist
        consecutive_failed_restarts=0
        atomic_write "${STATE_DIR}/consecutive_failed_restarts" "0"
        log "INFO" "Initialized consecutive failed restarts to 0"
    fi
    
    log "INFO" "Loaded consecutive failed restarts: $consecutive_failed_restarts"
}

# Clean up function for exit - ENHANCED with lock and resource handling
cleanup_handler() {
    log "INFO" "Received shutdown signal, performing cleanup"
    
    # Extra context for debugging exit conditions
    log "DEBUG" "Exit details: PID=$$, PPID=$PPID, Signal=$1"
    
    # Save current state
    atomic_write "${STATE_DIR}/last_restart_time" "$last_restart_time"
    atomic_write "${STATE_DIR}/last_reboot_time" "$last_reboot_time"
    atomic_write "${STATE_DIR}/consecutive_failed_restarts" "$consecutive_failed_restarts"
    
    # Enhanced lock file recovery - check for any lingering lock
    if [ -e "/proc/$$/fd/$LOCK_FD" ]; then
        log "WARNING" "Detected lingering lock file descriptor on exit, forcing closure"
        release_lock "$LOCK_FD"
    fi
    
    # Remove our PID file if it contains our PID
    if [ -f "$PID_FILE" ]; then
        local pid_contents=$(cat "$PID_FILE" 2>/dev/null || echo "")
        if [ "$pid_contents" = "$$" ]; then
            rm -f "$PID_FILE" 2>/dev/null || log "WARNING" "Failed to remove PID file on exit"
        fi
    fi
    
    # Remove system-wide lock if it contains our PID
    if [ -f "/var/run/mediamtx-monitor.lock" ]; then
        local lock_pid=$(cat "/var/run/mediamtx-monitor.lock" 2>/dev/null || echo "")
        if [ "$lock_pid" = "$$" ]; then
            rm -f "/var/run/mediamtx-monitor.lock" 2>/dev/null || log "WARNING" "Failed to remove system lock file"
        fi
    fi
    
    # Clean up temporary files
    if [ -d "${TEMP_DIR}" ]; then
        rm -rf "${TEMP_DIR}" 2>/dev/null || log "WARNING" "Failed to remove temp directory"
    fi
    
    log "INFO" "Cleanup completed, exiting"
    exit 0
}

# ======================================================================
# Process Monitoring Functions
# ======================================================================

# Check if MediaMTX is running
is_mediamtx_running() {
    if [ "$uses_systemd" = true ]; then
        if systemctl is-active --quiet "$MEDIAMTX_SERVICE"; then
            return 0  # Service is running
        else
            return 1  # Service is not running
        fi
    else
        # Fallback - check for process
        if pgrep -f "$MEDIAMTX_NAME" >/dev/null 2>&1; then
            return 0  # Process is running
        else
            return 1  # Process is not running
        fi
    fi
}

# Check if audio-rtsp service is running
is_audio_rtsp_running() {
    if [ "$uses_systemd" = true ]; then
        if systemctl is-active --quiet audio-rtsp.service; then
            return 0  # Service is running
        else
            return 1  # Service is not running
        fi
    else
        # Fallback method - check for startmic.sh
        if pgrep -f "startmic.sh" >/dev/null 2>&1; then
            return 0  # Process is running
        else
            return 1  # Process is not running
        fi
    fi
}

# Get MediaMTX process ID
get_mediamtx_pid() {
    local pid=""
    
    # Try different methods to get MediaMTX PID
    if [ "$uses_systemd" = true ]; then
        # First try to get PID from systemd
        pid=$(systemctl show -p MainPID --value "$MEDIAMTX_SERVICE" 2>/dev/null)
        if [[ -n "$pid" && "$pid" != "0" ]]; then
            echo "$pid"
            return 0
        fi
    fi
    
    # Fall back to pgrep
    pid=$(pgrep -f "$MEDIAMTX_NAME" | head -n1)
    if [[ -n "$pid" ]]; then
        echo "$pid"
        return 0
    fi
    
    # No PID found
    echo ""
    return 1
}

# Get MediaMTX uptime in seconds
get_mediamtx_uptime() {
    local pid=$1
    if [ -z "$pid" ] || ! ps -p "$pid" >/dev/null 2>&1; then
        echo "0"
        return
    fi
    
    local start_time
    local elapsed_seconds=0
    
    # Try method 1: Using /proc/PID/stat
    if [ -f "/proc/$pid/stat" ]; then
        local proc_stat_data
        local btime
        local uptime_seconds
        
        proc_stat_data=$(cat "/proc/$pid/stat" 2>/dev/null)
        if [ $? -eq 0 ]; then
            # Extract the start time (in clock ticks since boot)
            local starttime
            starttime=$(echo "$proc_stat_data" | awk '{print $22}')
            
            # Get boot time
            btime=$(grep btime /proc/stat 2>/dev/null | awk '{print $2}')
            
            # Get system uptime in seconds
            uptime_seconds=$(cat /proc/uptime 2>/dev/null | awk '{print $1}' | cut -d. -f1)
            
            if [[ -n "$starttime" && -n "$btime" && -n "$uptime_seconds" ]]; then
                # Calculate process uptime in seconds
                local clk_tck
                clk_tck=$(getconf CLK_TCK 2>/dev/null || echo 100)  # Default to 100 if getconf fails
                elapsed_seconds=$((uptime_seconds - (starttime / clk_tck)))
            fi
        fi
    fi
    
    # Method 2: Using ps command
    if [ "$elapsed_seconds" -eq 0 ]; then
        local ps_start_time
        ps_start_time=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
        if [[ -n "$ps_start_time" && "$ps_start_time" =~ ^[0-9]+$ ]]; then
            elapsed_seconds=$ps_start_time
        fi
    fi
    
    # Method 3: Use state file if both above methods fail
    if [ "$elapsed_seconds" -eq 0 ]; then
        local state_file="${STATE_DIR}/mediamtx_start_time"
        if [ -f "$state_file" ]; then
            local stored_start_time
            stored_start_time=$(cat "$state_file" 2>/dev/null)
            local current_time
            current_time=$(date +%s)
            if [[ -n "$stored_start_time" && "$stored_start_time" =~ ^[0-9]+$ ]]; then
                elapsed_seconds=$((current_time - stored_start_time))
            fi
        fi
    fi
    
    echo "$elapsed_seconds"
}

# Get MediaMTX CPU usage percentage
get_mediamtx_cpu() {
    local pid=$1
    local cpu_usage=0
    
    if [ -z "$pid" ] || ! ps -p "$pid" >/dev/null 2>&1; then
        echo "0"
        return
    fi
    
    # Method 1: Use top for more accurate measurement
    if command_exists top; then
        local top_output
        top_output=$(COLUMNS=512 top -b -n 2 -d 0.2 -p "$pid" 2>/dev/null | tail -1)
        if [ $? -eq 0 ]; then
            cpu_usage=$(echo "$top_output" | awk '{print $9}')
            # Remove decimal places if present
            cpu_usage=${cpu_usage%%.*}
        fi
    fi
    
    # Method 2: Fall back to ps if top fails
    if [[ -z "$cpu_usage" || ! "$cpu_usage" =~ ^[0-9]+$ ]]; then
        cpu_usage=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')
        # Remove decimal places if present
        cpu_usage=${cpu_usage%%.*}
    fi
    
    # Ensure we have a valid number
    if [[ ! "$cpu_usage" =~ ^[0-9]+$ ]]; then
        cpu_usage=0
    fi
    
    echo "$cpu_usage"
}

# Get MediaMTX memory usage percentage
get_mediamtx_memory() {
    local pid=$1
    local memory_percentage=0
    
    if [ -z "$pid" ] || ! ps -p "$pid" >/dev/null 2>&1; then
        echo "0"
        return
    fi
    
    # Method 1: Use ps for memory percentage
    memory_percentage=$(ps -p "$pid" -o %mem= 2>/dev/null | tr -d ' ')
    
    # Method 2: Calculate manually if ps fails
    if [[ -z "$memory_percentage" || ! "$memory_percentage" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        if [ -f "/proc/$pid/status" ]; then
            # Get VmRSS (Resident Set Size) from proc
            local vm_rss
            vm_rss=$(grep VmRSS /proc/"$pid"/status 2>/dev/null | awk '{print $2}')
            
            # Get total system memory
            local total_mem
            total_mem=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
            
            if [[ -n "$vm_rss" && -n "$total_mem" && "$total_mem" -gt 0 ]]; then
                # Calculate percentage
                memory_percentage=$(echo "scale=2; ($vm_rss / $total_mem) * 100" | bc)
                # Get just the integer part
                memory_percentage=${memory_percentage%%.*}
            fi
        fi
    fi
    
    # Remove decimal places if present
    memory_percentage=${memory_percentage%%.*}
    
    # Ensure we have a valid number
    if [[ ! "$memory_percentage" =~ ^[0-9]+$ ]]; then
        memory_percentage=0
    fi
    
    echo "$memory_percentage"
}

# Get number of open file descriptors
get_mediamtx_file_descriptors() {
    local pid=$1
    local fd_count=0
    
    if [ -z "$pid" ] || ! ps -p "$pid" >/dev/null 2>&1; then
        echo "0"
        return
    fi
    
    # Count open files in /proc/PID/fd if available
    if [ -d "/proc/$pid/fd" ]; then
        fd_count=$(ls -la /proc/"$pid"/fd 2>/dev/null | wc -l)
        # Subtract 3 to account for ., .., and the count command itself
        fd_count=$((fd_count - 3))
        if [ "$fd_count" -lt 0 ]; then
            fd_count=0
        fi
    fi
    
    # Fallback: use lsof if /proc method fails
    if [ "$fd_count" -eq 0 ] && command_exists lsof; then
        fd_count=$(lsof -p "$pid" 2>/dev/null | wc -l)
        # Subtract 1 to account for the header line
        fd_count=$((fd_count - 1))
        if [ "$fd_count" -lt 0 ]; then
            fd_count=0
        fi
    fi
    
    echo "$fd_count"
}

# Get combined CPU usage of MediaMTX and related processes
get_combined_cpu_usage() {
    local mediamtx_pid=$1
    local total_cpu=0
    local mediamtx_cpu=0
    local ffmpeg_cpu=0
    
    # Get MediaMTX CPU usage
    if [ -n "$mediamtx_pid" ] && ps -p "$mediamtx_pid" >/dev/null 2>&1; then
        mediamtx_cpu=$(get_mediamtx_cpu "$mediamtx_pid")
        total_cpu=$mediamtx_cpu
    fi
    
    # Get all ffmpeg processes streaming to RTSP
    local ffmpeg_pids
    ffmpeg_pids=$(pgrep -f "ffmpeg.*rtsp://localhost:$RTSP_PORT" 2>/dev/null)
    
    if [ -n "$ffmpeg_pids" ]; then
        # Count the number of ffmpeg processes
        local ffmpeg_count
        ffmpeg_count=$(echo "$ffmpeg_pids" | wc -l)
        
        # Use top to get CPU usage for all ffmpeg processes in one call
        if command_exists top; then
            local top_output
            top_output=$(COLUMNS=512 top -b -n 2 -d 0.2 | grep -E "ffmpeg.*rtsp" | awk '{sum+=$9} END {print sum}')
            
            if [ -n "$top_output" ] && [[ "$top_output" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                ffmpeg_cpu=${top_output%%.*}
                total_cpu=$((total_cpu + ffmpeg_cpu))
            else
                # Fallback: iterate through each process and sum CPU usage
                for pid in $ffmpeg_pids; do
                    local proc_cpu
                    proc_cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')
                    proc_cpu=${proc_cpu%%.*}
                    
                    if [[ "$proc_cpu" =~ ^[0-9]+$ ]]; then
                        ffmpeg_cpu=$((ffmpeg_cpu + proc_cpu))
                    fi
                done
                total_cpu=$((total_cpu + ffmpeg_cpu))
            fi
        else
            # Fallback if top isn't available
            for pid in $ffmpeg_pids; do
                local proc_cpu
                proc_cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null | tr -d ' ')
                proc_cpu=${proc_cpu%%.*}
                
                if [[ "$proc_cpu" =~ ^[0-9]+$ ]]; then
                    ffmpeg_cpu=$((ffmpeg_cpu + proc_cpu))
                fi
            done
            total_cpu=$((total_cpu + ffmpeg_cpu))
        fi
        
        # Store the component values for reference - FIXED: Using atomic_write
        atomic_write "${STATE_DIR}/mediamtx_cpu" "$mediamtx_cpu"
        atomic_write "${STATE_DIR}/ffmpeg_cpu" "$ffmpeg_cpu"
        atomic_write "${STATE_DIR}/ffmpeg_count" "$ffmpeg_count"
    fi
    
    echo "$total_cpu"
}

# ======================================================================
# Network and Health Checking Functions
# ======================================================================

# Check network health
check_network_health() {
    # Check if RTSP port is accessible using different methods
    local port_accessible=0
    
    # Method 1: Use netcat if available
    if command_exists nc; then
        if nc -z localhost "$RTSP_PORT" >/dev/null 2>&1; then
            port_accessible=1
        fi
    # Method 2: Use /dev/tcp if netcat not available
    elif bash -c "echo > /dev/tcp/localhost/$RTSP_PORT" >/dev/null 2>&1; then
        port_accessible=1
    # Method 3: Use netstat or ss as last resort
    elif command_exists netstat || command_exists ss; then
        if command_exists netstat; then
            if netstat -tuln | grep -q ":$RTSP_PORT\s"; then
                port_accessible=1
            fi
        elif command_exists ss; then
            if ss -tuln | grep -q ":$RTSP_PORT\s"; then
                port_accessible=1
            fi
        fi
    fi
    
    # Return failure if port not accessible
    if [ $port_accessible -eq 0 ]; then
        log "WARNING" "RTSP port $RTSP_PORT is not accessible"
        return 1
    fi
    
    # Check for established connections to MediaMTX
    local established_count=0
    
    if command_exists netstat; then
        established_count=$(netstat -tn 2>/dev/null | grep ":$RTSP_PORT" | grep ESTABLISHED | wc -l)
    elif command_exists ss; then
        established_count=$(ss -tn 2>/dev/null | grep ":$RTSP_PORT" | grep ESTAB | wc -l)
    fi
    
    # If there are many connections but no recent activity, it might be an issue
    if [ "$established_count" -gt 20 ]; then
        log "WARNING" "High number of established connections ($established_count) to RTSP port"
    fi
    
    # Check if MediaMTX is responding to basic requests (if curl is available)
    if command_exists curl; then
        if ! curl -s -I -X OPTIONS "rtsp://localhost:$RTSP_PORT" >/dev/null 2>&1; then
            log "WARNING" "MediaMTX not responding properly to RTSP requests"
            return 1
        fi
    fi
    
    return 0
}

# Analyze resource usage trends - IMPROVED IMPLEMENTATION
analyze_trends() {
    local cpu_file="${STATS_DIR}/cpu_history.txt"
    local mem_file="${STATS_DIR}/mem_history.txt"
    local current_cpu=$1
    local current_mem=$2
    
    # Create files if they don't exist
    touch "$cpu_file" "$mem_file"
    
    # Add current values to history files atomically
    atomic_append "$cpu_file" "$current_cpu"
    atomic_append "$mem_file" "$current_mem"
    
    # Trim history files to keep only the last CPU_TREND_PERIODS values
    if [ "$(wc -l < "$cpu_file")" -gt "$CPU_TREND_PERIODS" ]; then
        # Using temp file for atomic operation
        local temp_cpu_file="${TEMP_DIR}/cpu_history.tmp"
        tail -n "$CPU_TREND_PERIODS" "$cpu_file" > "$temp_cpu_file" && mv "$temp_cpu_file" "$cpu_file"
    fi
    
    if [ "$(wc -l < "$mem_file")" -gt "$CPU_TREND_PERIODS" ]; then
        # Using temp file for atomic operation
        local temp_mem_file="${TEMP_DIR}/mem_history.tmp"
        tail -n "$CPU_TREND_PERIODS" "$mem_file" > "$temp_mem_file" && mv "$temp_mem_file" "$mem_file"
    fi
    
    # Analyze CPU trend with better statistical approach
    if [ "$(wc -l < "$cpu_file")" -ge 5 ]; then
        # Use last 5 samples for better trend analysis
        local values=()
        local i=0
        while read -r value && [ "$i" -lt 5 ]; do
            values[$i]=$value
            i=$((i+1))
        done < <(tail -n 5 "$cpu_file")
        
        # Calculate moving average
        local sum=0
        for v in "${values[@]}"; do
            sum=$((sum + v))
        done
        local avg=$((sum / 5))
        
        # Calculate trend slope using simplified approach that's more resistant to outliers
        local slope=0
        local samples_count=${#values[@]}
        
        if [ "$samples_count" -ge 3 ]; then
            # Split samples into first half and second half
            local first_half=0
            local second_half=0
            local mid_point=$((samples_count / 2))
            
            # First half average
            for ((i=0; i<mid_point; i++)); do
                first_half=$((first_half + values[i]))
            done
            first_half=$((first_half / mid_point))
            
            # Second half average
            for ((i=mid_point; i<samples_count; i++)); do
                second_half=$((second_half + values[i]))
            done
            second_half=$((second_half / (samples_count - mid_point)))
            
            # Calculate trend (positive = rising, negative = falling)
            slope=$((second_half - first_half))
            
            # Store trend info for monitoring
            atomic_write "${STATE_DIR}/cpu_avg" "$avg"
            atomic_write "${STATE_DIR}/cpu_trend" "$slope"
            
            # Log significant trends
            if [ "$slope" -gt 5 ]; then
                log "WARNING" "CPU usage is trending upward significantly: +${slope}% (avg: ${avg}%)"
                
                # Only consider alarming if average is also approaching threshold
                if [ "$avg" -gt $((CPU_WARNING_THRESHOLD - 10)) ]; then
                    return 1  # Indicate concerning trend
                fi
            elif [ "$slope" -lt -5 ]; then
                log "INFO" "CPU usage is trending downward: ${slope}% (avg: ${avg}%)"
            fi
        fi
    fi
    
    # Perform similar analysis for memory if needed
    # Currently only focused on CPU trends, but similar approach could be applied
    
    return 0  # Default to no concerning trend
}

# ======================================================================
# Recovery Functions
# ======================================================================

# Cleanup before restart
cleanup_before_restart() {
    local pid=$1
    local force_kill=$2
    local stale_procs=()
    local cleanup_status=0
    
    log "INFO" "Cleaning up before MediaMTX restart..."
    
    # Find all child processes of the MediaMTX process
    if [ -n "$pid" ] && ps -p "$pid" >/dev/null 2>&1; then
        # Get all child process IDs using multiple methods for reliability
        local child_pids=""
        
        # Method 1: pstree if available
        if command_exists pstree; then
            child_pids=$(pstree -p "$pid" 2>/dev/null | grep -o '([0-9]\+)' | tr -d '()')
        fi
        
        # Method 2: ps with ppid filter if pstree fails
        if [ -z "$child_pids" ] && command_exists ps; then
            child_pids=$(ps -o pid --no-headers --ppid "$pid" 2>/dev/null)
        fi
        
        if [ -n "$child_pids" ]; then
            log "INFO" "Found child processes of MediaMTX: $child_pids"
            
            # Gracefully terminate child processes first
            for child_pid in $child_pids; do
                if [ "$child_pid" != "$pid" ] && ps -p "$child_pid" >/dev/null 2>&1; then
                    log "INFO" "Sending SIGTERM to child process $child_pid"
                    kill -15 "$child_pid" >/dev/null 2>&1
                    stale_procs+=("$child_pid")
                fi
            done
        fi
    fi
    
    # Terminate any processes accessing the MediaMTX files (like lsof)
    if command_exists lsof && [ -x "$MEDIAMTX_PATH" ]; then
        local locking_pids
        locking_pids=$(lsof "$MEDIAMTX_PATH" 2>/dev/null | grep -v "^COMMAND" | awk '{print $2}' | sort -u)
        
        if [ -n "$locking_pids" ]; then
            log "INFO" "Found processes locking MediaMTX executable: $locking_pids"
            
            for lock_pid in $locking_pids; do
                if [ "$lock_pid" != "$$" ] && ps -p "$lock_pid" >/dev/null 2>&1; then
                    log "INFO" "Sending SIGTERM to locking process $lock_pid"
                    kill -15 "$lock_pid" >/dev/null 2>&1
                    stale_procs+=("$lock_pid")
                fi
            done
        fi
    fi
    
    # Find and terminate any zombie or defunct processes related to MediaMTX
    local zombie_pids
    zombie_pids=$(ps aux | grep "$MEDIAMTX_NAME" | grep "<defunct>" | awk '{print $2}')
    
    if [ -n "$zombie_pids" ]; then
        log "INFO" "Found zombie MediaMTX processes: $zombie_pids"
        
        for zombie_pid in $zombie_pids; do
            if ps -p "$zombie_pid" >/dev/null 2>&1; then
                log "INFO" "Sending SIGKILL to zombie process $zombie_pid"
                kill -9 "$zombie_pid" >/dev/null 2>&1
            fi
        done
    fi
    
    # Wait for a short time to allow processes to terminate
    sleep 2
    
    # Force kill any remaining stale processes if needed
    if [ "$force_kill" = true ] && [ ${#stale_procs[@]} -gt 0 ]; then
        for stale_pid in "${stale_procs[@]}"; do
            if ps -p "$stale_pid" >/dev/null 2>&1; then
                log "WARNING" "Process $stale_pid still running, sending SIGKILL"
                kill -9 "$stale_pid" >/dev/null 2>&1
                
                # Check if the kill was successful
                if ps -p "$stale_pid" >/dev/null 2>&1; then
                    log "ERROR" "Failed to kill process $stale_pid"
                    cleanup_status=1
                fi
            fi
        done
    fi
    
    # Clean up any leftover socket files that might prevent restart
    local rtsp_sockets
    rtsp_sockets=$(find /tmp -type s -name "*rtsp*" 2>/dev/null)
    if [ -n "$rtsp_sockets" ]; then
        log "INFO" "Cleaning up RTSP socket files: $rtsp_sockets"
        # shellcheck disable=SC2086
        rm -f $rtsp_sockets 2>/dev/null
    fi
    
    return $cleanup_status
}

# Verify MediaMTX health after restart
verify_mediamtx_health() {
    local pid=$1
    local start_time
    start_time=$(date +%s)
    local max_wait=30  # Maximum time to wait in seconds
    local success=false
    
    if [ -z "$pid" ]; then
        pid=$(get_mediamtx_pid)
    fi
    
    if [ -z "$pid" ]; then
        log "ERROR" "MediaMTX process not found after restart"
        return 1
    fi
    
    log "INFO" "Verifying MediaMTX health after restart (PID: $pid)..."
    
    # Wait for the RTSP port to become accessible
    local port_check_count=0
    while [ $port_check_count -lt 10 ]; do
        if check_network_health; then
            log "INFO" "RTSP port $RTSP_PORT is now accessible"
            success=true
            break
        fi
        
        port_check_count=$((port_check_count + 1))
        
        # Check if we've waited too long
        local current_time
        current_time=$(date +%s)
        if [ $((current_time - start_time)) -gt "$max_wait" ]; then
            log "ERROR" "Timeout waiting for RTSP port to become accessible"
            break
        fi
        
        sleep 1
    done
    
    # Verify the process is stable (not consuming too much CPU right away)
    local initial_cpu
    initial_cpu=$(get_mediamtx_cpu "$pid")
    
    # Store the start time for future uptime calculations
    atomic_write "${STATE_DIR}/mediamtx_start_time" "$(date +%s)"
    
    if [ "$success" = true ] && [ "$initial_cpu" -lt "$CPU_WARNING_THRESHOLD" ]; then
        log "INFO" "MediaMTX appears to be healthy after restart"
        return 0
    else
        log "ERROR" "MediaMTX health check failed after restart"
        return 1
    fi
}

# Restart ffmpeg processes
restart_ffmpeg_processes() {
    # Only do this if the audio-rtsp service is running
    if is_audio_rtsp_running; then
        log "INFO" "Restarting ffmpeg processes for RTSP streams..."
        
        # Restart the audio-rtsp service to recreate all streams
        if [ "$uses_systemd" = true ]; then
            log "INFO" "Restarting audio-rtsp service"
            systemctl restart audio-rtsp.service
            local restart_status=$?
            
            if [ $restart_status -eq 0 ]; then
                log "INFO" "Successfully restarted audio-rtsp service"
                return 0
            else
                log "ERROR" "Failed to restart audio-rtsp service (exit code: $restart_status)"
                return 1
            fi
        else
            # Non-systemd restart approach - use more reliable method with pidfile
            log "INFO" "Using non-systemd approach to restart audio processes"
            
            # Find the startmic.sh process
            local startmic_pid
            startmic_pid=$(pgrep -f "startmic.sh" | head -1)
            
            if [ -n "$startmic_pid" ]; then
                log "INFO" "Found startmic.sh process (PID: $startmic_pid), sending restart signal"
                # Send SIGHUP for graceful restart if supported
                kill -1 "$startmic_pid" >/dev/null 2>&1
                
                # Wait a moment for restart
                sleep 3
                
                # Check if process is still running
                if kill -0 "$startmic_pid" 2>/dev/null; then
                    log "INFO" "startmic.sh process restarted successfully"
                    return 0
                else
                    log "WARNING" "startmic.sh process not found after restart signal"
                    # Try to start it again
                    if [ -x "/usr/local/bin/startmic.sh" ]; then
                        nohup /usr/local/bin/startmic.sh >/dev/null 2>&1 &
                        log "INFO" "Started new startmic.sh process"
                        return 0
                    else
                        log "ERROR" "Could not find startmic.sh to restart"
                        return 1
                    fi
                fi
            else
                log "ERROR" "No startmic.sh process found to restart"
                return 1
            fi
        fi
    else
        log "INFO" "Audio-RTSP service is not running, no streams to restart"
        return 0
    fi
}

# Progressive recovery with multiple levels - ENHANCED with deadman switch
recover_mediamtx() {
    local reason="$1"
    local current_time
    current_time=$(date +%s)
    local force_restart=false
    
    # Check if we're in cooldown period after a recent restart
    if [ $((current_time - last_restart_time)) -lt "$RESTART_COOLDOWN" ]; then
        # Only allow force restarts to bypass cooldown
        if [ "$reason" != "FORCE" ] && [ "$reason" != "EMERGENCY" ]; then
            log "INFO" "In cooldown period, skipping restart"
            return 1
        else
            force_restart=true
            log "WARNING" "Force restart requested, bypassing cooldown"
        fi
    fi
    
    # Update restart attempt tracking
    if [ $((current_time - last_restart_time)) -gt "$RESTART_COOLDOWN" ]; then
        # Reset counter if we're outside the cooldown window
        restart_attempts_count=0
    fi
    restart_attempts_count=$((restart_attempts_count + 1))
    
    # Determine recovery level based on restart attempts
    if [ "$reason" = "EMERGENCY" ]; then
        # Emergency recovery jumps straight to level 3
        recovery_level=3
    elif [ "$force_restart" = true ]; then
        # Force restart uses level 2
        recovery_level=2
    elif [ "$restart_attempts_count" -ge "$MAX_RESTART_ATTEMPTS" ]; then
        # Max restart attempts reached, escalate to reboot consideration
        recovery_level=4
    else
        # Progressive escalation based on previous attempt
        recovery_level=$((recovery_level + 1))
        if [ "$recovery_level" -gt 3 ]; then
            recovery_level=3
        fi
    fi
    
    log "RECOVERY" "Initiating level $recovery_level recovery due to: $reason"
    
    # Get MediaMTX PID
    local mediamtx_pid
    mediamtx_pid=$(get_mediamtx_pid)
    
    # Store system state for debugging
    if [ -n "$mediamtx_pid" ]; then
        local state_file="${STATE_DIR}/state_before_restart_$(date +%Y%m%d%H%M%S).txt"
        {
            echo "Recovery Level: $recovery_level"
            echo "Reason: $reason"
            echo "Time: $(date)"
            echo "MediaMTX PID: $mediamtx_pid"
            echo "CPU Usage: $(get_mediamtx_cpu "$mediamtx_pid")%"
            echo "Memory Usage: $(get_mediamtx_memory "$mediamtx_pid")%"
            echo "Open Files: $(get_mediamtx_file_descriptors "$mediamtx_pid")"
            echo "Uptime: $(get_mediamtx_uptime "$mediamtx_pid") seconds"
            echo "System Load: $(cat /proc/loadavg 2>/dev/null || echo "N/A")"
            echo "---"
            echo "Process List:"
            ps aux | grep -E "$MEDIAMTX_NAME|ffmpeg.*rtsp" || echo "No processes found"
            echo "---"
            echo "Network Connections:"
            netstat -tnp 2>/dev/null | grep -E "$RTSP_PORT|$mediamtx_pid" || echo "No connections found"
        } > "$state_file" 2>&1
        log "INFO" "System state saved to $state_file"
    fi
    
    # Implement different recovery strategies based on level
    case $recovery_level in
        1)
            # Level 1: Basic restart through systemd (gentlest method)
            log "RECOVERY" "Level 1: Performing standard systemd restart"
            
            if [ "$uses_systemd" = true ]; then
                log "INFO" "Using systemd to restart MediaMTX service"
                systemctl restart "$MEDIAMTX_SERVICE"
                local restart_status=$?
                
                if [ $restart_status -eq 0 ]; then
                    log "INFO" "Standard restart completed successfully"
                else
                    log "ERROR" "Standard restart failed with exit code $restart_status"
                    consecutive_failed_restarts=$((consecutive_failed_restarts + 1))
                    atomic_write "${STATE_DIR}/consecutive_failed_restarts" "$consecutive_failed_restarts"
                    return 1
                fi
            else
                # Fallback for non-systemd systems
                log "WARNING" "Systemd not detected, using fallback restart method"
                
                if [ -n "$mediamtx_pid" ]; then
                    kill -15 "$mediamtx_pid" 2>/dev/null
                    sleep 2
                    
                    # Check if process stopped
                    if ps -p "$mediamtx_pid" >/dev/null 2>&1; then
                        log "WARNING" "Process did not stop with SIGTERM, using SIGKILL"
                        kill -9 "$mediamtx_pid" 2>/dev/null
                        sleep 1
                    fi
                fi
                
                # Start MediaMTX
                if [ -x "$MEDIAMTX_PATH" ]; then
                    log "INFO" "Starting MediaMTX from $MEDIAMTX_PATH"
                    nohup "$MEDIAMTX_PATH" >/dev/null 2>&1 &
                else
                    log "ERROR" "MediaMTX executable not found or not executable: $MEDIAMTX_PATH"
                    consecutive_failed_restarts=$((consecutive_failed_restarts + 1))
                    atomic_write "${STATE_DIR}/consecutive_failed_restarts" "$consecutive_failed_restarts"
                    return 1
                fi
            fi
            ;;
            
        2)
            # Level 2: Thorough restart with cleanup and verification
            log "RECOVERY" "Level 2: Performing thorough restart with cleanup"
            
            # Stop any ffmpeg RTSP processes first
            log "INFO" "Stopping ffmpeg RTSP processes"
            pkill -f "ffmpeg.*rtsp://localhost:$RTSP_PORT" 2>/dev/null || true
            sleep 2
            
            # Clean up MediaMTX and related processes
            cleanup_before_restart "$mediamtx_pid" false
            
            # Restart the service
            if [ "$uses_systemd" = true ]; then
                log "INFO" "Using systemd to restart MediaMTX service"
                systemctl stop "$MEDIAMTX_SERVICE"
                sleep 2
                systemctl start "$MEDIAMTX_SERVICE"
                local restart_status=$?
                
                if [ $restart_status -ne 0 ]; then
                    log "ERROR" "Thorough restart failed with exit code $restart_status"
                    consecutive_failed_restarts=$((consecutive_failed_restarts + 1))
                    atomic_write "${STATE_DIR}/consecutive_failed_restarts" "$consecutive_failed_restarts"
                    return 1
                fi
            else
                # Fallback for non-systemd systems
                log "WARNING" "Systemd not detected, using fallback restart method"
                
                if [ -n "$mediamtx_pid" ]; then
                    kill -15 "$mediamtx_pid" 2>/dev/null
                    sleep 3
                    
                    # Check if process stopped
                    if ps -p "$mediamtx_pid" >/dev/null 2>&1; then
                        log "WARNING" "Process did not stop with SIGTERM, using SIGKILL"
                        kill -9 "$mediamtx_pid" 2>/dev/null
                        sleep 2
                    fi
                fi
                
                # Start MediaMTX
                if [ -x "$MEDIAMTX_PATH" ]; then
                    log "INFO" "Starting MediaMTX from $MEDIAMTX_PATH"
                    nohup "$MEDIAMTX_PATH" >/dev/null 2>&1 &
                else
                    log "ERROR" "MediaMTX executable not found or not executable: $MEDIAMTX_PATH"
                    consecutive_failed_restarts=$((consecutive_failed_restarts + 1))
                    atomic_write "${STATE_DIR}/consecutive_failed_restarts" "$consecutive_failed_restarts"
                    return 1
                fi
            fi
            
            # Wait for MediaMTX to initialize
            sleep 5
            
            # Get the new PID
            local new_pid
            new_pid=$(get_mediamtx_pid)
            
            # Verify MediaMTX is running properly
            if ! verify_mediamtx_health "$new_pid"; then
                log "ERROR" "MediaMTX failed health check after thorough restart"
                consecutive_failed_restarts=$((consecutive_failed_restarts + 1))
                atomic_write "${STATE_DIR}/consecutive_failed_restarts" "$consecutive_failed_restarts"
                return 1
            fi
            ;;
            
        3)
            # Level 3: Aggressive restart with force cleanup and service chain restart
            log "RECOVERY" "Level 3: Performing aggressive recovery with force cleanup"
            
            # Stop all related services
            if [ "$uses_systemd" = true ]; then
                # Stop audio-rtsp first if it's running
                if systemctl is-active --quiet audio-rtsp.service; then
                    log "INFO" "Stopping audio-rtsp service first"
                    systemctl stop audio-rtsp.service
                fi
                
                # Stop MediaMTX service
                log "INFO" "Stopping MediaMTX service"
                systemctl stop "$MEDIAMTX_SERVICE"
            else
                # Non-systemd approach
                log "INFO" "Stopping all related processes"
                pkill -f "ffmpeg.*rtsp://localhost:$RTSP_PORT" 2>/dev/null || true
                if [ -n "$mediamtx_pid" ]; then
                    kill -15 "$mediamtx_pid" 2>/dev/null
                fi
            fi
            
            # Wait to ensure services have stopped
            sleep 5
            
            # Force kill any remaining processes
            log "INFO" "Force killing any remaining MediaMTX processes"
            pkill -9 -f "$MEDIAMTX_NAME" 2>/dev/null || true
            
            # Aggressive cleanup
            cleanup_before_restart "$mediamtx_pid" true
            
            # Extra cleanup: clear shared memory, temp files, etc.
            log "INFO" "Cleaning up system resources"
            
            # Remove any MediaMTX lock files
            find /tmp -name "*$MEDIAMTX_NAME*" -type f -delete 2>/dev/null || true
            
            # Clear any stale socket files
            find /tmp -name "*.sock" -type s -delete 2>/dev/null || true
            
            # Wait for cleanup to complete
            sleep 3
            
            # Start MediaMTX
            if [ "$uses_systemd" = true ]; then
                log "INFO" "Starting MediaMTX service"
                systemctl start "$MEDIAMTX_SERVICE"
                local restart_status=$?
                
                if [ $restart_status -ne 0 ]; then
                    log "ERROR" "Aggressive restart failed with exit code $restart_status"
                    consecutive_failed_restarts=$((consecutive_failed_restarts + 1))
                    atomic_write "${STATE_DIR}/consecutive_failed_restarts" "$consecutive_failed_restarts"
                    return 1
                fi
            else
                # Non-systemd start
                if [ -x "$MEDIAMTX_PATH" ]; then
                    log "INFO" "Starting MediaMTX from $MEDIAMTX_PATH"
                    nohup "$MEDIAMTX_PATH" >/dev/null 2>&1 &
                else
                    log "ERROR" "MediaMTX executable not found or not executable: $MEDIAMTX_PATH"
                    consecutive_failed_restarts=$((consecutive_failed_restarts + 1))
                    atomic_write "${STATE_DIR}/consecutive_failed_restarts" "$consecutive_failed_restarts"
                    return 1
                fi
            fi
            
            # Wait longer for MediaMTX to initialize after aggressive restart
            sleep 10
            
            # Get the new PID
            local new_pid
            new_pid=$(get_mediamtx_pid)
            
            # Verify MediaMTX is running properly
            if ! verify_mediamtx_health "$new_pid"; then
                log "ERROR" "MediaMTX failed health check after aggressive restart"
                consecutive_failed_restarts=$((consecutive_failed_restarts + 1))
                atomic_write "${STATE_DIR}/consecutive_failed_restarts" "$consecutive_failed_restarts"
                return 1
            fi
            
            # Restart audio streams if MediaMTX is healthy
            log "INFO" "MediaMTX is healthy, restarting audio streams"
            if [ "$uses_systemd" = true ] && systemctl is-enabled --quiet audio-rtsp.service; then
                log "INFO" "Starting audio-rtsp service"
                systemctl start audio-rtsp.service
            fi
            ;;
            
        4)
            # Level 4: System reboot consideration - ENHANCED WITH DEADMAN SWITCH
            log "RECOVERY" "Level 4: Considering system reboot after multiple failed recoveries"
            
            # Check if auto reboot is enabled
            if [ "$ENABLE_AUTO_REBOOT" = true ]; then
                # First, check with the deadman switch
                if ! check_reboot_limit; then
                    log "WARNING" "Deadman switch has disabled auto-reboot due to too many recent reboots"
                    log "WARNING" "Attempting one more aggressive recovery instead"
                    
                    # Fall back to level 3 recovery when reboot is disabled
                    recovery_level=3
                    recover_mediamtx "EMERGENCY"
                    return $?
                fi
                
                # Check if we're within cooldown after recent reboot
                if [ $((current_time - last_reboot_time)) -lt "$REBOOT_COOLDOWN" ]; then
                    log "WARNING" "In reboot cooldown period, attempting one more aggressive recovery"
                    # Fall back to level 3 recovery during reboot cooldown
                    recovery_level=3
                    recover_mediamtx "EMERGENCY"
                    return $?
                fi
                
                # Check if failed restarts exceed threshold
                if [ "$consecutive_failed_restarts" -ge "$REBOOT_THRESHOLD" ]; then
                    # Perform last-chance aggressive recovery in case something changed
                    log "RECOVERY" "Final attempt at aggressive recovery before reboot"
                    recovery_level=3
                    if recover_mediamtx "FINAL_ATTEMPT"; then
                        log "INFO" "Final recovery attempt succeeded, cancelling reboot"
                        consecutive_failed_restarts=0
                        atomic_write "${STATE_DIR}/consecutive_failed_restarts" "0"
                        return 0
                    fi
                    
                    # If we got here, the final attempt failed
                    log "REBOOT" "Initiating system reboot after $consecutive_failed_restarts failed recoveries"
                    
                    # Record reboot in state file and in deadman switch
                    atomic_write "${STATE_DIR}/last_reboot_time" "$(date +%s)"
                    last_reboot_time=$(date +%s)
                    record_reboot
                    
                    # Write a detailed report before reboot
                    local reboot_file="${STATE_DIR}/reboot_reason_$(date +%Y%m%d%H%M%S).txt"
                    {
                        echo "Reboot Reason: $consecutive_failed_restarts consecutive failed recoveries"
                        echo "Last Recovery Level: $recovery_level"
                        echo "Original Issue: $reason"
                        echo "Time: $(date)"
                        echo "---"
                        echo "System State:"
                        free -h
                        echo "---"
                        echo "Disk Space:"
                        df -h
                        echo "---"
                        echo "Process List:"
                        ps aux
                        echo "---"
                        echo "Last 20 log entries:"
                        tail -n 20 "$MONITOR_LOG"
                    } > "$reboot_file" 2>&1
                    
                    # Sync disks before reboot
                    sync
                    
                    # Actual reboot command
                    log "REBOOT" "Executing reboot now"
                    reboot
                    return 0
                else
                    log "WARNING" "Reboot threshold not met yet ($consecutive_failed_restarts/$REBOOT_THRESHOLD)"
                    # Try level 3 recovery as a fallback
                    recovery_level=3
                    recover_mediamtx "EMERGENCY"
                    return $?
                fi
            else
                log "WARNING" "Auto reboot is disabled, attempting aggressive recovery instead"
                # Fall back to level 3 recovery when auto reboot is disabled
                recovery_level=3
                recover_mediamtx "EMERGENCY"
                return $?
            fi
            ;;
    esac
    
    # Wait for MediaMTX to stabilize
    sleep 5
    
    # Update last restart time and save state atomically
    last_restart_time=$(date +%s)
    atomic_write "${STATE_DIR}/last_restart_time" "$last_restart_time"
    
    # Restart ffmpeg processes if needed
    if [ "$recovery_level" -ge 2 ]; then
        restart_ffmpeg_processes
    fi
    
    # Reset consecutive failed restarts counter on success
    consecutive_failed_restarts=0
    atomic_write "${STATE_DIR}/consecutive_failed_restarts" "0"
    
    log "RECOVERY" "Recovery level $recovery_level completed successfully"
    return 0
}

# ======================================================================
# Main Monitoring Loop
# ======================================================================

main() {
    # Initialize the monitor
    load_config
    
    # Track resource usage over time
    consecutive_high_cpu=0
    consecutive_high_memory=0
    previous_cpu=0
    previous_memory=0
    last_disk_check=0
    
    log "INFO" "Starting main monitoring loop with ${CPU_CHECK_INTERVAL}s interval"
    
    # Main monitoring loop
    while true; do
        # Check if MediaMTX is running
        if ! is_mediamtx_running; then
            log "WARNING" "MediaMTX is not running! Attempting to start..."
            recover_mediamtx "process not running"
            sleep 10
            continue
        fi
        
        # Get MediaMTX PID
        mediamtx_pid=$(get_mediamtx_pid)
        if [ -z "$mediamtx_pid" ]; then
            log "WARNING" "Could not determine MediaMTX PID"
            sleep 10
            continue
        fi
        
        # Get resource usage
        cpu_usage=$(get_mediamtx_cpu "$mediamtx_pid")
        combined_cpu_usage=$(get_combined_cpu_usage "$mediamtx_pid")
        memory_usage=$(get_mediamtx_memory "$mediamtx_pid")
        uptime=$(get_mediamtx_uptime "$mediamtx_pid")
        file_descriptors=$(get_mediamtx_file_descriptors "$mediamtx_pid")
        
        # Record current state atomically
        atomic_write "${STATE_DIR}/current_cpu" "$cpu_usage"
        atomic_write "${STATE_DIR}/combined_cpu" "$combined_cpu_usage"
        atomic_write "${STATE_DIR}/current_memory" "$memory_usage"
        atomic_write "${STATE_DIR}/current_uptime" "$uptime"
        atomic_write "${STATE_DIR}/current_fd" "$file_descriptors"
        
        # Periodically check disk space
        current_time=$(date +%s)
        if [ $((current_time - last_disk_check)) -ge "$DISK_CHECK_INTERVAL" ]; then
            check_disk_space
            last_disk_check=$current_time
        fi
        
        # Log current status at a regular interval (every 5 minutes)
        if (( current_time % 300 < CPU_CHECK_INTERVAL )); then
            log "INFO" "STATUS: MediaMTX (PID: $mediamtx_pid) - CPU: ${cpu_usage}%, Combined CPU: ${combined_cpu_usage}%, Memory: ${memory_usage}%, FDs: $file_descriptors, Uptime: ${uptime}s"
        fi
        
        # Check for emergency conditions (immediate action required)
        if [ "$combined_cpu_usage" -ge "$COMBINED_CPU_THRESHOLD" ]; then
            log "ERROR" "EMERGENCY: Combined CPU usage critical: ${combined_cpu_usage}% (threshold: ${COMBINED_CPU_THRESHOLD}%)"
            recover_mediamtx "EMERGENCY combined CPU (${combined_cpu_usage}%)"
            sleep 15  # Longer wait after emergency action
            continue
        fi
        
        if [ "$cpu_usage" -ge "$EMERGENCY_CPU_THRESHOLD" ]; then
            log "ERROR" "EMERGENCY: MediaMTX CPU usage critical: ${cpu_usage}% (threshold: ${EMERGENCY_CPU_THRESHOLD}%)"
            recover_mediamtx "EMERGENCY CPU (${cpu_usage}%)"
            sleep 15  # Longer wait after emergency action
            continue
        fi
        
        if [ "$memory_usage" -ge "$EMERGENCY_MEMORY_THRESHOLD" ]; then
            log "ERROR" "EMERGENCY: MediaMTX memory usage critical: ${memory_usage}% (threshold: ${EMERGENCY_MEMORY_THRESHOLD}%)"
            recover_mediamtx "EMERGENCY memory (${memory_usage}%)"
            sleep 15  # Longer wait after emergency action
            continue
        fi
        
        if [ "$file_descriptors" -ge "$FILE_DESCRIPTOR_THRESHOLD" ]; then
            log "ERROR" "EMERGENCY: Too many open file descriptors: $file_descriptors (threshold: ${FILE_DESCRIPTOR_THRESHOLD})"
            recover_mediamtx "EMERGENCY file descriptors ($file_descriptors)"
            sleep 15  # Longer wait after emergency action
            continue
        fi
        
        # Analyze trends to detect gradual resource creep
        analyze_trends "$cpu_usage" "$memory_usage"
        trend_status=$?
        
        # Take action on concerning trends
        if [ $trend_status -ne 0 ]; then
            # Only act on trends if we're outside of cooldown
            if [ $((current_time - last_resource_warning)) -gt 600 ]; then  # 10 minute cooldown for trend warnings
                log "WARNING" "Resource trend analysis indicates potential issue, scheduling preventive restart"
                last_resource_warning=$current_time
                atomic_write "${STATE_DIR}/last_resource_warning" "$last_resource_warning"
                
                # If the previous restart was very recent, wait a bit
                if [ $((current_time - last_restart_time)) -lt 300 ]; then
                    log "INFO" "Recent restart detected, scheduling preventive restart in 5 minutes"
                    sleep 300
                fi
                
                recover_mediamtx "preventive maintenance (trend analysis)"
                sleep 15  # Longer wait after trend-based restart
                continue
            fi
        fi
        
        # Check CPU threshold
        if [ "$cpu_usage" -ge "$CPU_THRESHOLD" ]; then
            consecutive_high_cpu=$((consecutive_high_cpu + 1))
            log "WARNING" "MediaMTX CPU usage is high: ${cpu_usage}% (threshold: ${CPU_THRESHOLD}%, consecutive periods: ${consecutive_high_cpu}/${CPU_SUSTAINED_PERIODS})"
            
            # If CPU has been high for consecutive periods, restart
            if [ "$consecutive_high_cpu" -ge "$CPU_SUSTAINED_PERIODS" ]; then
                recover_mediamtx "sustained high CPU usage (${cpu_usage}%)"
                consecutive_high_cpu=0
                # FIXED: Using atomic_write to store state
                atomic_write "${STATE_DIR}/consecutive_high_cpu" "0"
                sleep 10
                continue
            else
                # FIXED: Store the updated counter atomically
                atomic_write "${STATE_DIR}/consecutive_high_cpu" "$consecutive_high_cpu"
            fi
        else
            # Reset counter if CPU is normal
            if [ "$consecutive_high_cpu" -gt 0 ]; then
                if [ "$previous_cpu" -ge "$CPU_THRESHOLD" ] && [ "$cpu_usage" -lt "$previous_cpu" ]; then
                    log "INFO" "MediaMTX CPU usage normalized: ${cpu_usage}% (down from ${previous_cpu}%)"
                fi
                consecutive_high_cpu=0
                atomic_write "${STATE_DIR}/consecutive_high_cpu" "0"
            fi
        fi
        
        # Check for combined CPU warning level
        if [ "$combined_cpu_usage" -ge "$COMBINED_CPU_WARNING" ] && [ "$combined_cpu_usage" -lt "$COMBINED_CPU_THRESHOLD" ]; then
            # Only log warnings occasionally to avoid log spam
            if [ $((current_time - last_resource_warning)) -gt 300 ]; then  # 5 minute cooldown for warnings
                log "WARNING" "Combined CPU usage approaching threshold: ${combined_cpu_usage}% (warning: ${COMBINED_CPU_WARNING}%, critical: ${COMBINED_CPU_THRESHOLD}%)"
                last_resource_warning=$current_time
                atomic_write "${STATE_DIR}/last_resource_warning" "$last_resource_warning"
            fi
        fi
        
        # Check memory threshold
        if [ "$memory_usage" -ge "$MEMORY_THRESHOLD" ]; then
            consecutive_high_memory=$((consecutive_high_memory + 1))
            log "WARNING" "MediaMTX memory usage is high: ${memory_usage}% (threshold: ${MEMORY_THRESHOLD}%, consecutive periods: ${consecutive_high_memory}/2)"
            
            # Store the updated counter atomically
            atomic_write "${STATE_DIR}/consecutive_high_memory" "$consecutive_high_memory"
            
            # If memory has been high for consecutive periods, restart
            if [ "$consecutive_high_memory" -ge 2 ]; then
                recover_mediamtx "high memory usage (${memory_usage}%)"
                consecutive_high_memory=0
                atomic_write "${STATE_DIR}/consecutive_high_memory" "0"
                sleep 10
                continue
            fi
        else
            # Reset counter if memory is normal
            if [ "$consecutive_high_memory" -gt 0 ]; then
                log "INFO" "MediaMTX memory usage normalized: ${memory_usage}%"
                consecutive_high_memory=0
                atomic_write "${STATE_DIR}/consecutive_high_memory" "0"
            fi
        fi
        
        # Check for warning thresholds to provide early alerts
        if [ "$cpu_usage" -ge "$CPU_WARNING_THRESHOLD" ] && [ "$cpu_usage" -lt "$CPU_THRESHOLD" ]; then
            # Only log warnings occasionally to avoid log spam
            if [ $((current_time - last_resource_warning)) -gt 300 ]; then  # 5 minute cooldown for warnings
                log "WARNING" "MediaMTX CPU usage approaching threshold: ${cpu_usage}% (warning: ${CPU_WARNING_THRESHOLD}%, critical: ${CPU_THRESHOLD}%)"
                last_resource_warning=$current_time
                atomic_write "${STATE_DIR}/last_resource_warning" "$last_resource_warning"
            fi
        fi
        
        # Check uptime - force restart after MAX_UPTIME for preventive maintenance
        if [ "$uptime" -ge "$MAX_UPTIME" ]; then
            log "INFO" "MediaMTX has reached maximum uptime of ${MAX_UPTIME}s, performing preventive restart"
            recover_mediamtx "scheduled restart after ${MAX_UPTIME}s uptime"
            sleep 10
            continue
        fi
        
        # Store previous values for comparison
        previous_cpu=$cpu_usage
        previous_memory=$memory_usage
        
        # Sleep before next check
        sleep "$CPU_CHECK_INTERVAL"
    done
}

# Start the monitoring process
main
