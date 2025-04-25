#!/bin/bash

# Exit on error
set -e

# Script name for logging
SCRIPT_NAME=$(basename "$0")

# Parse command line options
DEBUG=false
EXIT_ON_ERROR=true
RTSP_PORT=18554
PROBE_TIMEOUT=3  # Timeout for audio probing commands in seconds

for arg in "$@"; do
    case $arg in
        --debug)
            DEBUG=true
            set -x
            ;;
        --no-exit-on-error)
            EXIT_ON_ERROR=false
            set +e
            ;;
        --rtsp-port=*)
            RTSP_PORT="${arg#*=}"
            ;;
        --probe-timeout=*)
            PROBE_TIMEOUT="${arg#*=}"
            ;;
        --help)
            echo "Usage: $SCRIPT_NAME [OPTIONS]"
            echo "Options:"
            echo "  --debug              Enable debug mode with verbose output"
            echo "  --no-exit-on-error   Continue script execution on errors"
            echo "  --rtsp-port=PORT     Specify custom RTSP port (default: 18554)"
            echo "  --probe-timeout=SECS Set timeout for audio device probing (default: 3)"
            echo "  --help               Show this help message"
            exit 0
            ;;
    esac
done

# Log directory - create if it doesn't exist
LOG_DIR="/var/log/audio-rtsp"
if ! mkdir -p "$LOG_DIR" 2>/dev/null; then
    # If we can't create the standard log directory, use /tmp
    LOG_DIR="/tmp/audio-rtsp"
    mkdir -p "$LOG_DIR"
fi

LOG_FILE="$LOG_DIR/audio-stream-$(date +%Y%m%d-%H%M%S).log"
LATEST_LOG_LINK="$LOG_DIR/latest.log"

# Create symbolic link to the latest log
ln -sf "$LOG_FILE" "$LATEST_LOG_LINK" 2>/dev/null || true

# Maximum number of log files to keep (log rotation)
MAX_LOGS=10

# Function to log messages - sends to log file and console but not stdout
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    
    # Write to log file
    echo "[$timestamp] [$level] $message" >> "$LOG_FILE"
    
    # Write to stderr for console display, not stdout
    case "$level" in
        "ERROR")
            echo -e "\e[31m[$timestamp] [$level] $message\e[0m" >&2 ;;  # Red for errors
        "WARNING")
            echo -e "\e[33m[$timestamp] [$level] $message\e[0m" >&2 ;;  # Yellow for warnings
        "SUCCESS")
            echo -e "\e[32m[$timestamp] [$level] $message\e[0m" >&2 ;;  # Green for success
        *)
            echo "[$timestamp] [$level] $message" >&2 ;;
    esac
}

# Function to perform log rotation
rotate_logs() {
    # Get list of log files sorted by modification time (oldest first)
    local log_files=($(ls -t "$LOG_DIR"/audio-stream-*.log 2>/dev/null || echo ""))
    
    # If we have more logs than the maximum allowed, remove the oldest ones
    if [ ${#log_files[@]} -gt $MAX_LOGS ]; then
        local excess=$((${#log_files[@]} - $MAX_LOGS))
        for ((i=${#log_files[@]}-1; i>=${#log_files[@]}-$excess; i--)); do
            rm -f "${log_files[$i]}" 2>/dev/null || true
        done
    fi
}

# Check if timeout command is available
have_timeout_cmd=false
if command -v timeout >/dev/null 2>&1; then
    have_timeout_cmd=true
fi

# Wrapper for commands that might hang
safe_exec() {
    local cmd="$1"
    local timeout_secs="${2:-$PROBE_TIMEOUT}"
    local fallback="$3"
    
    if [ "$have_timeout_cmd" = true ]; then
        # Use timeout command
        timeout "$timeout_secs" bash -c "$cmd" 2>/dev/null || echo "$fallback"
    else
        # Fallback if timeout command isn't available
        # Start command in background with a kill timer
        local tmp_file=$(mktemp)
        (eval "$cmd" > "$tmp_file" 2>&1) & local pid=$!
        
        # Wait for command to finish or timeout
        local count=0
        while [ $count -lt "$timeout_secs" ] && kill -0 $pid 2>/dev/null; do
            sleep 1
            count=$((count + 1))
        done
        
        # If still running after timeout, kill it
        if kill -0 $pid 2>/dev/null; then
            kill -9 $pid 2>/dev/null || true
            echo "$fallback"
        else
            cat "$tmp_file"
        fi
        
        rm -f "$tmp_file"
    fi
}

# Perform log rotation
rotate_logs

log "INFO" "Starting audio streaming service ($SCRIPT_NAME)"
log "INFO" "Log file: $LOG_FILE"

# Function to handle errors
handle_error() {
    local exit_code=$1
    local line_number=$2
    local error_message=$3
    
    log "ERROR" "Error occurred at line $line_number: $error_message (Exit code: $exit_code)"
    
    if [ "$EXIT_ON_ERROR" = true ]; then
        log "ERROR" "Exiting due to error"
        exit $exit_code
    else
        log "WARNING" "Continuing despite error (--no-exit-on-error flag is set)"
    fi
}

# Set up error trap if exit-on-error is enabled
if [ "$EXIT_ON_ERROR" = true ]; then
    trap 'handle_error $? $LINENO "$BASH_COMMAND"' ERR
fi

# Check for required commands
check_command() {
    local cmd=$1
    local install_suggestion=$2
    local required=$3
    
    if ! command -v "$cmd" >/dev/null 2>&1; then
        if [ "$required" = "true" ]; then
            log "WARNING" "$cmd is not installed. $install_suggestion"
            return 1
        else
            log "INFO" "Optional command $cmd is not installed. Some features may be limited."
            return 2
        fi
    fi
    return 0
}

missing_commands=false

# Check for required commands with installation suggestions
check_command "ffmpeg" "Install it with: apt-get install ffmpeg" true || missing_commands=true
check_command "arecord" "Install it with: apt-get install alsa-utils" true || missing_commands=true
# Netcat is optional - we'll use alternative methods if it's not available
check_command "nc" "Install it with: apt-get install netcat" false

# Check for MediaMTX
mediamtx_found=false
for mediamtx_path in "/usr/local/mediamtx/mediamtx" "/usr/bin/mediamtx" "/usr/local/bin/mediamtx"; do
    if [ -x "$mediamtx_path" ]; then
        mediamtx_found=true
        MEDIAMTX_PATH="$mediamtx_path"
        break
    fi
done

if ! $mediamtx_found; then
    MEDIAMTX_PATH=$(which mediamtx 2>/dev/null || echo "")
    if [ -n "$MEDIAMTX_PATH" ]; then
        mediamtx_found=true
    else
        log "WARNING" "MediaMTX not found. RTSP server functionality may not work."
        log "INFO" "You can install MediaMTX from https://github.com/bluenviron/mediamtx"
    fi
fi

if [ "$missing_commands" = true ] && [ "$EXIT_ON_ERROR" = true ]; then
    log "ERROR" "Required commands are missing. Please install them and try again."
    exit 1
fi

# Check if MediaMTX config exists and validate RTSP port
MEDIAMTX_CONFIG=""
for config_path in "/etc/mediamtx/mediamtx.yml" "/usr/local/mediamtx/mediamtx.yml"; do
    if [ -f "$config_path" ]; then
        MEDIAMTX_CONFIG="$config_path"
        log "INFO" "Found MediaMTX config at $MEDIAMTX_CONFIG"
        
        # Check if the config file specifies a different RTSP port
        if command -v grep >/dev/null 2>&1 && grep -q "rtspAddress:" "$MEDIAMTX_CONFIG"; then
            config_port=$(grep "rtspAddress:" "$MEDIAMTX_CONFIG" | grep -o ":[0-9]\+" | cut -d':' -f2 | tr -d '[:space:]')
            if [ -n "$config_port" ] && [ "$config_port" != "$RTSP_PORT" ]; then
                log "WARNING" "MediaMTX config specifies RTSP port $config_port but script is using port $RTSP_PORT"
                log "INFO" "Updating script to use port $config_port from MediaMTX config"
                RTSP_PORT="$config_port"
            fi
        fi
        break
    fi
done

log "INFO" "Starting MediaMTX RTSP server..."

# Check if MediaMTX is already running
if pgrep mediamtx > /dev/null 2>&1; then
    log "INFO" "MediaMTX is already running."
else
    # Start MediaMTX if found
    if [ "$mediamtx_found" = true ]; then
        log "INFO" "Starting MediaMTX from $MEDIAMTX_PATH"
        "$MEDIAMTX_PATH" &
        MEDIAMTX_PID=$!
        log "INFO" "Waiting for MediaMTX to initialize..."
        sleep 5  # Allow MediaMTX time to start properly
        
        # Verify MediaMTX started correctly
        if ! pgrep mediamtx > /dev/null 2>&1; then
            log "WARNING" "MediaMTX may have failed to start. Check MediaMTX logs."
        else
            log "SUCCESS" "MediaMTX started successfully (PID: $(pgrep mediamtx | head -1))."
        fi
    else
        log "WARNING" "Skipping MediaMTX startup as it was not found."
    fi
fi

# Verify RTSP server is accessible
verify_rtsp_server() {
    local host="localhost"
    local port="$RTSP_PORT"
    local max_attempts=5  # Reduced number of attempts for faster startup
    local attempt=1
    local rtsp_server_ready=false
    
    log "INFO" "Verifying RTSP server is accessible on $host:$port..."
    
    while [ $attempt -le $max_attempts ] && [ "$rtsp_server_ready" = false ]; do
        log "INFO" "RTSP server verification attempt $attempt of $max_attempts"
        
        # Method 1: Try using netcat to check port (if available)
        if command -v nc >/dev/null 2>&1; then
            if nc -z "$host" "$port" 2>/dev/null; then
                log "SUCCESS" "RTSP server is accessible on $host:$port (verified with netcat)"
                rtsp_server_ready=true
                break
            fi
        fi
        
        # Method 2: Try using curl to check RTSP URL (if available)
        if command -v curl >/dev/null 2>&1; then
            if curl -v "rtsp://$host:$port" 2>&1 | grep -q "RTSP/1.0"; then
                log "SUCCESS" "RTSP server is accessible on $host:$port (verified with curl)"
                rtsp_server_ready=true
                break
            fi
        fi
        
        # Method 3: Try using ffmpeg to check RTSP server
        if safe_exec "ffmpeg -hide_banner -loglevel error -timeout 2 -rtsp_transport tcp -i 'rtsp://$host:$port' -t 0.1 -f null - 2>&1" | grep -q "Input #0"; then
            log "SUCCESS" "RTSP server is accessible on $host:$port (verified with ffmpeg)"
            rtsp_server_ready=true
            break
        fi
        
        # Method 4: Check if mediamtx process is running as a basic verification
        if pgrep mediamtx >/dev/null 2>&1; then
            log "INFO" "MediaMTX process is running, proceeding with assumption that RTSP server is available"
            # Give MediaMTX a bit more time to fully initialize if it's running
            sleep 2
            rtsp_server_ready=true
            break
        fi
        
        log "INFO" "RTSP server not yet accessible on $host:$port. Waiting..."
        sleep 2
        attempt=$((attempt + 1))
    done
    
    if [ "$rtsp_server_ready" = false ]; then
        log "WARNING" "RTSP server is not accessible after $max_attempts attempts. Attempting to start/restart it..."
        
        # Check if systemd service for MediaMTX exists
        if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q mediamtx; then
            log "INFO" "Trying to start MediaMTX via systemd..."
            systemctl start mediamtx
            sleep 5
            
            # Check again after systemd start with available methods
            if (command -v nc >/dev/null 2>&1 && nc -z "$host" "$port" 2>/dev/null) || \
               (command -v curl >/dev/null 2>&1 && curl -v "rtsp://$host:$port" 2>&1 | grep -q "RTSP/1.0") || \
               pgrep mediamtx >/dev/null 2>&1; then
                log "SUCCESS" "MediaMTX started successfully via systemd"
                rtsp_server_ready=true
            else
                log "WARNING" "MediaMTX could not be started via systemd - will try direct launch"
            fi
        fi
        
        # Try to start MediaMTX directly as last resort
        if [ "$mediamtx_found" = true ]; then
            log "INFO" "Trying to start MediaMTX directly..."
            "$MEDIAMTX_PATH" &
            MEDIAMTX_PID=$!
            sleep 5
            
            if pgrep mediamtx >/dev/null 2>&1; then
                log "SUCCESS" "MediaMTX started successfully via direct launch"
                rtsp_server_ready=true
            else
                log "WARNING" "Failed to start MediaMTX directly"
            fi
        fi
        
        # Additional troubleshooting check
        if pgrep mediamtx > /dev/null 2>&1; then
            mediamtx_pid=$(pgrep mediamtx | head -1)
            log "INFO" "MediaMTX process is running (PID: $mediamtx_pid) but port may not be accessible"
            
            # Check if MediaMTX is listening on a different port
            if command -v ss >/dev/null 2>&1; then
                log "INFO" "Checking what ports MediaMTX is listening on..."
                ss -tulpn | grep mediamtx | while read -r line; do
                    log "INFO" "MediaMTX listening on: $line"
                done
            elif command -v netstat >/dev/null 2>&1; then
                log "INFO" "Checking what ports MediaMTX is listening on..."
                netstat -tulpn | grep mediamtx | while read -r line; do
                    log "INFO" "MediaMTX listening on: $line"
                done
            fi
            
            # Proceed anyway if MediaMTX is running
            log "INFO" "MediaMTX is running, will proceed with streaming despite verification issues"
            rtsp_server_ready=true
        else
            log "ERROR" "MediaMTX process is not running"
            
            if [ "$EXIT_ON_ERROR" = true ]; then
                log "ERROR" "Exiting due to MediaMTX not running"
                exit 1
            fi
        fi
    fi
    
    return 0
}

# Verify RTSP server is accessible
verify_rtsp_server

# Function to check if a sound card has a capture device (non-blocking)
has_capture_device() {
    local card=$1
    local card_id=$2
    
    # Try multiple methods to detect capture capability
    
    # Method 1: Use arecord -l with timeout (fastest and most reliable)
    local arecord_output=$(safe_exec "arecord -l 2>/dev/null" 2 "")
    if echo "$arecord_output" | grep -q "card $card"; then
        return 0  # Has capture device
    fi
    
    # Method 2: Check if the card has capture info in proc (very fast, non-blocking)
    if [ -f "/proc/asound/card$card/pcm0c/info" ]; then
        return 0  # Has capture device
    fi
    
    # Method 3: Try ffmpeg to probe the device with minimal output (with timeout)
    local ffmpeg_output=$(safe_exec "ffmpeg -hide_banner -loglevel error -f alsa -i 'hw:$card,0' -t 0.1 -f null -" 2 "")
    if echo "$ffmpeg_output" | grep -q "Input #0"; then
        return 0  # Has capture device
    fi
    
    return 1  # No capture device found with any method
}

# Function to get a sanitized name for the RTSP stream
get_stream_name() {
    local card_name=$1
    # Remove spaces, special characters and convert to lowercase
    # Use tr and sed to handle null bytes safely
    echo "$card_name" | LC_ALL=C tr -d '\000' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g'
}

# Fixed, safe, non-blocking audio capability detection that doesn't mix stdout/stderr
detect_audio_capabilities() {
    local card=$1
    local card_id=$2
    
    # Log to stderr only, not stdout
    log "INFO" "Detecting capabilities for card $card [$card_id]" >&2
    
    # Initialize with default values
    local channels=1  # Default to mono if detection fails
    local rate=44100  # Default sample rate
    local format="S16_LE"  # Default format
    local stereo_detected=false
    
    # Method 1: Look at arecord -l output for quick detection
    local arecord_list=$(safe_exec "arecord -l 2>/dev/null" 2 "")
    local card_line=$(echo "$arecord_list" | grep -E "card $card.*:.*$card_id" | head -1)
    
    # Check for stereo in arecord output
    if echo "$card_line" | grep -i -E '(stereo|2 channel)' >/dev/null; then
        channels=2
        stereo_detected=true
        log "INFO" "Detected stereo device from arecord listing" >&2
    fi
    
    # Method 2: Check device PCM info directly (non-blocking)
    if [ -f "/proc/asound/card$card/pcm0c/info" ]; then
        local pcm_info=$(cat "/proc/asound/card$card/pcm0c/info" 2>/dev/null | LC_ALL=C tr -d '\000' || echo "")
        
        if echo "$pcm_info" | grep -q "channels: 2"; then
            channels=2
            stereo_detected=true
            log "INFO" "PCM info indicates stereo device" >&2
        fi
    fi
    
    # Method 3: Quick test with ffmpeg to detect channels
    if [ "$stereo_detected" = false ]; then
        log "INFO" "Testing channels with ffmpeg" >&2
        
        # First try to detect with stereo setting
        local ff_test_stereo=$(safe_exec "ffmpeg -hide_banner -loglevel warning -f alsa -ac 2 -i hw:$card,0 -t 0.1 -f null - 2>&1" 2 "")
        
        if ! echo "$ff_test_stereo" | grep -i -E '(invalid|error|failed)' >/dev/null; then
            channels=2
            log "INFO" "Device appears to support stereo based on ffmpeg test" >&2
        fi
    fi
    
    # Method 4: Quick test recording to see actual capabilities
    log "INFO" "Running quick test recording to check capabilities" >&2
    local test_file="/tmp/test_audio_$card_id.wav"
    local record_cmd="ffmpeg -hide_banner -loglevel error -f alsa -ac $channels -ar 44100 -i hw:$card,0 -t 0.5 $test_file"
    
    if safe_exec "$record_cmd >/dev/null 2>&1 && echo 'success'" 2 | grep -q "success"; then
        # Check the recorded file properties
        local file_info=$(ffprobe -v error -show_streams "$test_file" 2>/dev/null || echo "")
        
        # Extract actual channels from the recorded file
        local actual_channels=$(echo "$file_info" | grep -E '^channels=' | head -1 | cut -d= -f2)
        local actual_rate=$(echo "$file_info" | grep -E '^sample_rate=' | head -1 | cut -d= -f2)
        
        if [ -n "$actual_channels" ]; then
            channels=$actual_channels
            log "SUCCESS" "Confirmed channels through test recording: $channels" >&2
        fi
        
        if [ -n "$actual_rate" ]; then
            rate=$actual_rate
            log "SUCCESS" "Confirmed sample rate through test recording: $rate Hz" >&2
        fi
    else
        log "WARNING" "Test recording failed, using default values" >&2
    fi
    
    # Clean up test file
    rm -f "$test_file" 2>/dev/null || true
    
    # For USB microphones, common rates are 44100 or 48000, check if we can detect
    for test_rate in 48000 44100; do
        # If we already have a detected rate, use it
        [ -n "$rate" ] && [ "$rate" != "44100" ] && break
        
        if safe_exec "ffmpeg -hide_banner -loglevel error -f alsa -ar $test_rate -i hw:$card,0 -t 0.1 -f null - 2>&1" 2 | grep -v "Invalid" >/dev/null; then
            rate=$test_rate
            log "INFO" "Device appears to support sample rate: $rate Hz" >&2
            break
        fi
    done
    
    log "INFO" "Final detected capabilities: channels=$channels, rate=$rate, format=$format" >&2
    
    # Return capabilities as a clean, space-separated string to stdout only
    # This is the key fix - ensure only the actual values go to stdout
    printf "%s %s %s\n" "$channels" "$rate" "$format"
}

# Calculate optimal bitrate based on audio quality settings
calculate_bitrate() {
    local channels=$1
    local rate=$2
    local format=$3
    
    # Base bitrate calculation on channels and sample rate
    local bits_per_sample=16  # Assume 16 bits for most formats
    
    case $format in
        S32_LE) bits_per_sample=32 ;;
        S24_LE) bits_per_sample=24 ;;
        S16_LE) bits_per_sample=16 ;;
        U8)     bits_per_sample=8 ;;
    esac
    
    # Calculate theoretical maximum bitrate (channels * sample_rate * bits_per_sample)
    local max_bitrate=$((channels * rate * bits_per_sample))
    
    # Convert to kbps and apply compression factor (MP3 can compress well)
    local compression_factor=8  # Conservative compression estimate for MP3
    local optimal_bitrate=$((max_bitrate / compression_factor / 1000))
    
    # Clamp to reasonable MP3 values
    if [ $optimal_bitrate -lt 64 ]; then
        optimal_bitrate=64  # Minimum bitrate
    elif [ $optimal_bitrate -gt 320 ]; then
        optimal_bitrate=320  # Maximum MP3 bitrate
    fi
    
    # Round to common values: 64, 96, 128, 192, 256, 320
    for std_rate in 64 96 128 192 256 320; do
        if [ $optimal_bitrate -le $std_rate ]; then
            optimal_bitrate=$std_rate
            break
        fi
    done
    
    echo "$optimal_bitrate"
}

# Kill any existing ffmpeg processes that might be streaming
log "INFO" "Stopping any existing ffmpeg streams..."
if command -v pkill >/dev/null 2>&1; then
    pkill -f "ffmpeg.*rtsp" 2>/dev/null || true
else
    # Alternative if pkill is not available
    for pid in $(ps aux | grep "ffmpeg.*rtsp" | grep -v grep | awk '{print $2}'); do
        kill -9 $pid 2>/dev/null || true
    done
fi
sleep 2  # Give more time for processes to terminate

# Create a temporary directory to store stream details
TEMP_DIR=$(mktemp -d)
STREAM_DETAILS_FILE="$TEMP_DIR/stream_details"
touch "$STREAM_DETAILS_FILE"
RUNNING_STREAMS_FILE="$TEMP_DIR/running_streams"
touch "$RUNNING_STREAMS_FILE"

# Trap for cleanup
trap 'exit_code=$?; log "INFO" "Script terminated with exit code $exit_code, cleaning up..."; rm -rf "$TEMP_DIR"; if command -v pkill >/dev/null 2>&1; then pkill -f "ffmpeg.*rtsp" 2>/dev/null || true; else for pid in $(ps aux | grep "ffmpeg.*rtsp" | grep -v grep | awk '"'"'{print $2}'"'"'); do kill -9 $pid 2>/dev/null || true; done; fi; log "INFO" "Cleanup complete."; exit $exit_code' EXIT INT TERM

# Function to check if the system is a Raspberry Pi
is_raspberry_pi() {
    if [ -f /proc/device-tree/model ] && grep -q "Raspberry Pi" /proc/device-tree/model; then
        return 0
    fi
    return 1
}

# Get list of sound cards using multiple methods
log "INFO" "Detecting sound cards with capture capabilities..."

# Method 1: Read from /proc/asound/cards
SOUND_CARDS=""
if [ -f "/proc/asound/cards" ]; then
    SOUND_CARDS=$(cat /proc/asound/cards 2>/dev/null | LC_ALL=C tr -d '\000' || echo "")
fi

# Method 2: If Method 1 failed, try using arecord -l
if [ -z "$SOUND_CARDS" ]; then
    log "INFO" "Failed to read from /proc/asound/cards, trying arecord -l..."
    
    ARECORD_OUTPUT=$(safe_exec "arecord -l 2>/dev/null" 2 "")
    
    if [ -n "$ARECORD_OUTPUT" ]; then
        # Convert arecord output to a format similar to /proc/asound/cards
        SOUND_CARDS=$(echo "$ARECORD_OUTPUT" | grep -E "card [0-9]+" | \
                       sed -E 's/card ([0-9]+): ([^,]+).*/\1 [\2]: /' || echo "")
    fi
fi

# Method 3: As a last resort, try to enumerate ALSA devices with ffmpeg
if [ -z "$SOUND_CARDS" ]; then
    log "INFO" "No sound cards detected with standard methods, trying ffmpeg enumeration..."
    
    FF_DEVICES=$(safe_exec "ffmpeg -hide_banner -sources device -f alsa 2>&1" 2 "")
    
    if [ -n "$FF_DEVICES" ]; then
        # Convert ffmpeg output to a format similar to /proc/asound/cards
        SOUND_CARDS=$(echo "$FF_DEVICES" | grep -oP '\[.*?\]' | \
                       awk '{print NR-1 " " $0 ": ALSA Device"}' || echo "")
    fi
fi

if [ -z "$SOUND_CARDS" ]; then
    log "ERROR" "No sound cards could be detected with any method."
    log "INFO" "Please check your audio hardware and ALSA configuration."
    exit 1
fi

log "INFO" "Found sound cards:"
echo "$SOUND_CARDS" | while read -r line; do
    [ -n "$line" ] && log "INFO" "  $line"
done

# Determine the system-specific sound devices to skip
SKIP_DEVICES="bcm2835_headpho|vc4-hdmi|HDMI|hdmi|sysdefault|default|pulse|pipewire"

# Add Raspberry Pi specific devices to skip list
if is_raspberry_pi; then
    log "INFO" "Running on Raspberry Pi, adding Pi-specific devices to skip list"
    SKIP_DEVICES="$SKIP_DEVICES|bcm2835|vc4|headphones"
fi

# Function to start an ffmpeg stream with multiple fallback options
start_ffmpeg_stream() {
    local card_num=$1
    local card_id=$2
    local channels=$3
    local sample_rate=$4
    local format=$5
    local bitrate=$6
    local rtsp_url=$7
    local stream_name=$8
    
    log "INFO" "Starting RTSP stream for card $card_num [$card_id] with $channels channels at ${bitrate}k: $rtsp_url"
    
    # Set ffmpeg log level based on debug mode
    local log_level="error"
    local stats_opt="-nostats"
    if [ "$DEBUG" = true ]; then
        log_level="info"
        stats_opt=""
    fi
    
    # Create a unique stream ID to identify this stream
    local stream_id="stream_${card_id}_${stream_name}"
    
    # Try multiple approaches for maximum compatibility
    local success=false
    local attempt=1
    local max_attempts=5
    local ffmpeg_pid=""
    local ffmpeg_log="$LOG_DIR/ffmpeg_${stream_name}.log"
    
    # Store original parameters for reporting
    local orig_channels=$channels
    local orig_bitrate=$bitrate
    
    while [ $attempt -le $max_attempts ] && [ "$success" = false ]; do
        log "INFO" "Stream start attempt #$attempt for $card_id"
        
        case $attempt in
            1)
                # First attempt: Use plughw with all detected parameters
                log "INFO" "Trying plughw with detected parameters"
                ffmpeg -nostdin $stats_opt -loglevel $log_level \
                      -f alsa -sample_rate "$sample_rate" -ac "$channels" \
                      -i "plughw:CARD=$card_id,DEV=0" \
                      -acodec libmp3lame -b:a "${bitrate}k" -ac "$channels" \
                      -content_type 'audio/mpeg' \
                      -f rtsp "rtsp://localhost:$RTSP_PORT/$stream_name" -rtsp_transport tcp > "$ffmpeg_log" 2>&1 &
                ffmpeg_pid=$!
                ;;
            2)
                # Second attempt: Use hw instead of plughw (direct hardware access)
                log "INFO" "Trying hw device instead of plughw"
                ffmpeg -nostdin $stats_opt -loglevel $log_level \
                      -f alsa -sample_rate "$sample_rate" -ac "$channels" \
                      -i "hw:$card_num,0" \
                      -acodec libmp3lame -b:a "${bitrate}k" -ac "$channels" \
                      -content_type 'audio/mpeg' \
                      -f rtsp "rtsp://localhost:$RTSP_PORT/$stream_name" -rtsp_transport tcp > "$ffmpeg_log" 2>&1 &
                ffmpeg_pid=$!
                ;;
            3)
                # Third attempt: Use default device with card specification
                log "INFO" "Trying default device with card specification"
                ffmpeg -nostdin $stats_opt -loglevel $log_level \
                      -f alsa -ac "$channels" \
                      -i "default:CARD=$card_id" \
                      -acodec libmp3lame -b:a "${bitrate}k" -ac "$channels" \
                      -content_type 'audio/mpeg' \
                      -f rtsp "rtsp://localhost:$RTSP_PORT/$stream_name" -rtsp_transport tcp > "$ffmpeg_log" 2>&1 &
                ffmpeg_pid=$!
                ;;
            4)
                # Fourth attempt: Fall back to conservative settings (mono)
                log "INFO" "Falling back to conservative settings (mono)"
                channels=1
                bitrate=128
                ffmpeg -nostdin $stats_opt -loglevel $log_level \
                      -f alsa -ac 1 \
                      -i "hw:$card_num,0" \
                      -acodec libmp3lame -b:a "128k" -ac 1 \
                      -content_type 'audio/mpeg' \
                      -f rtsp "rtsp://localhost:$RTSP_PORT/$stream_name" -rtsp_transport tcp > "$ffmpeg_log" 2>&1 &
                ffmpeg_pid=$!
                ;;
            5)
                # Fifth attempt: Last resort, most basic settings
                log "INFO" "Last resort: using most basic settings"
                channels=1
                bitrate=64
                ffmpeg -nostdin $stats_opt -loglevel $log_level \
                      -f alsa -ac 1 \
                      -i "default" \
                      -acodec libmp3lame -b:a "64k" -ac 1 \
                      -content_type 'audio/mpeg' \
                      -f rtsp "rtsp://localhost:$RTSP_PORT/$stream_name" -rtsp_transport tcp > "$ffmpeg_log" 2>&1 &
                ffmpeg_pid=$!
                ;;
        esac
        
        # Check if ffmpeg started successfully
        sleep 2
        if kill -0 $ffmpeg_pid 2>/dev/null; then
            # Check if ffmpeg still running after a short wait (to catch quick failures)
            sleep 3
            if kill -0 $ffmpeg_pid 2>/dev/null; then
                log "SUCCESS" "Successfully started ffmpeg (PID: $ffmpeg_pid) on attempt #$attempt"
                success=true
                
                # If we had to change parameters, log the changes
                if [ "$channels" != "$orig_channels" ] || [ "$bitrate" != "$orig_bitrate" ]; then
                    log "INFO" "Note: Original parameters (ch:$orig_channels, br:${orig_bitrate}k) were changed to (ch:$channels, br:${bitrate}k)"
                fi
                
                # Store the PID and stream info for watchdog
                echo "$ffmpeg_pid|$card_num|$card_id|$channels|$bitrate|rtsp://localhost:$RTSP_PORT/$stream_name|$stream_name|$attempt" >> "$RUNNING_STREAMS_FILE"
            else
                log "WARNING" "Ffmpeg process died shortly after starting (attempt #$attempt)"
                # Check the ffmpeg log for error details
                if [ -f "$ffmpeg_log" ]; then
                    local error_msg=$(tail -n 10 "$ffmpeg_log" | grep -i "error" | head -1 || echo "No specific error found")
                    log "WARNING" "FFmpeg error: $error_msg"
                fi
            fi
        else
            log "WARNING" "Failed to start ffmpeg (attempt #$attempt)"
        fi
        
        attempt=$((attempt + 1))
    done
    
    if [ "$success" = false ]; then
        log "ERROR" "All attempts to start stream for card $card_id failed"
        return 1
    fi
    
    return 0
}

# Parse sound cards and start ffmpeg for each one with capture capability
echo "$SOUND_CARDS" | while read -r line; do
    # First format: standard /proc/asound/cards format
    if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]*\[([^]]+)\][[:space:]]*:[[:space:]]*(.*) ]]; then
        CARD_NUM=${BASH_REMATCH[1]}
        CARD_ID=${BASH_REMATCH[2]}
        CARD_DESC=${BASH_REMATCH[3]}
    # Alternative format for parsing arecord output
    elif [[ "$line" =~ card[[:space:]]+([0-9]+):[[:space:]]+([^,]+) ]]; then
        CARD_NUM=${BASH_REMATCH[1]}
        CARD_ID=${BASH_REMATCH[2]}
        CARD_DESC=""
    else
        # Skip lines that don't match expected formats
        continue
    fi
    
    # Remove leading/trailing whitespace from card ID
    CARD_ID=$(echo "$CARD_ID" | xargs)
    
    # Skip empty card IDs
    if [ -z "$CARD_ID" ]; then
        continue
    fi
    
    # Extract USB device info if available
    USB_INFO=""
    if [[ "$CARD_DESC" =~ USB-Audio ]]; then
        USB_INFO=$(echo "$CARD_DESC" | sed -n 's/.*USB-Audio - \(.*\)/\1/p')
    fi
    
    # Exclude known system sound devices that shouldn't be used for capture
    if [[ "$CARD_ID" =~ $SKIP_DEVICES ]]; then
        log "INFO" "Skipping system audio device: $CARD_ID"
        continue
    fi
    
    # Check if this card has capture capabilities
    if has_capture_device "$CARD_NUM" "$CARD_ID"; then
        log "INFO" "Found capture device on card $CARD_NUM [$CARD_ID]"
        
        # Detect audio capabilities with clean, fixed function - output won't mix with logs
        # Capture the output directly into variables in a way that won't mix with logs
        read -r ch rate fmt < <(detect_audio_capabilities "$CARD_NUM" "$CARD_ID")
        
        # Validate returned values and use defaults if needed
        channels=${ch:-1}  # Default to mono if detection fails
        sample_rate=${rate:-44100}  # Default to 44.1kHz if detection fails
        audio_format=${fmt:-"S16_LE"}  # Default format
        
        # Log the detected values for debugging
        log "INFO" "Using detected values: channels=$channels rate=$sample_rate format=$audio_format"
        
        # Calculate optimal bitrate based on detected capabilities
        bitrate=$(calculate_bitrate "$channels" "$sample_rate" "$audio_format")
        log "INFO" "Calculated optimal bitrate: ${bitrate}k for card $CARD_ID"
        
        # Generate stream name based on card ID
        STREAM_NAME=$(get_stream_name "$CARD_ID")
        RTSP_URL="rtsp://localhost:$RTSP_PORT/$STREAM_NAME"
        
        # Save the details to our temporary file
        echo "$CARD_NUM|$CARD_ID|$USB_INFO|$channels|${bitrate}k|$RTSP_URL" >> "$STREAM_DETAILS_FILE"
        
        # Start ffmpeg with the appropriate sound card and detected capabilities
        start_ffmpeg_stream "$CARD_NUM" "$CARD_ID" "$channels" "$sample_rate" "$audio_format" "$bitrate" "$RTSP_URL" "$STREAM_NAME"
        
        # Add delay to stagger the ffmpeg starts and avoid race conditions
        sleep 2
    else
        log "INFO" "Skipping card $CARD_NUM [$CARD_ID] - no capture device found"
    fi
done

# Check if any streams were created
if [ -s "$STREAM_DETAILS_FILE" ]; then
    log "SUCCESS" "Successfully created audio streams"
    echo ""
    echo "================================================================="
    echo "                  ACTIVE AUDIO RTSP STREAMS                      "
    echo "================================================================="
    printf "%-4s | %-15s | %-30s | %-8s | %-7s | %s\n" "Card" "Card ID" "USB Device" "Channels" "Bitrate" "RTSP URL"
    echo "-----------------------------------------------------------------"
    
    # Print a formatted table of the streams
    while IFS="|" read -r card_num card_id usb_info channels bitrate rtsp_url; do
        printf "%-4s | %-15s | %-30s | %-8s | %-7s | %s\n" "$card_num" "$card_id" "$usb_info" "$channels" "$bitrate" "$rtsp_url"
    done < "$STREAM_DETAILS_FILE"
    
    echo "================================================================="
    echo ""
    
    # Get the IP address of the machine for external access using multiple methods
    IP_ADDR=$(hostname -I 2>/dev/null | awk '{print $1}' || ip addr show 2>/dev/null | grep -oP 'inet \K[\d.]+' | grep -v '127.0.0.1' | head -1 || echo "unknown")
    if [ -n "$IP_ADDR" ] && [ "$IP_ADDR" != "unknown" ]; then
        echo "To access these streams from other devices on the network, replace"
        echo "'localhost' with '$IP_ADDR' in the RTSP URLs"
        echo ""
    fi
else
    log "WARNING" "No audio streams were created. Check if you have audio capture devices connected."
fi

# Define a watchdog function to monitor and restart failed streams
watchdog_monitor() {
    log "INFO" "Starting stream watchdog monitor"
    
    # Run until interrupted
    while true; do
        # Verify RTSP server is still running using available methods
        rtsp_server_running=false
        
        # Method 1: Check if the MediaMTX process is running
        if pgrep mediamtx >/dev/null 2>&1; then
            rtsp_server_running=true
        fi
        
        # Method 2: Try netcat if available
        if ! $rtsp_server_running && command -v nc >/dev/null 2>&1; then
            if nc -z localhost $RTSP_PORT 2>/dev/null; then
                rtsp_server_running=true
            fi
        fi
        
        # Method 3: Try curl if available
        if ! $rtsp_server_running && command -v curl >/dev/null 2>&1; then
            curl_output=$(safe_exec "curl -s 'rtsp://localhost:$RTSP_PORT' 2>&1" 2 "")
            if echo "$curl_output" | grep -q "RTSP"; then
                rtsp_server_running=true
            fi
        fi
        
        # Method 4: Try ffmpeg
        if ! $rtsp_server_running; then
            ffmpeg_output=$(safe_exec "ffmpeg -hide_banner -loglevel error -timeout 1 -rtsp_transport tcp -i 'rtsp://localhost:$RTSP_PORT' -t 0.1 -f null -" 2 "")
            if [ -n "$ffmpeg_output" ]; then
                rtsp_server_running=true
            fi
        fi
        
        if ! $rtsp_server_running; then
            log "WARNING" "RTSP server appears to be down, attempting to restart"
            
            # Try to restart MediaMTX
            if [ "$mediamtx_found" = true ]; then
                log "INFO" "Restarting MediaMTX from $MEDIAMTX_PATH"
                "$MEDIAMTX_PATH" &
                sleep 5
            elif command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files | grep -q mediamtx; then
                log "INFO" "Restarting MediaMTX via systemd"
                systemctl restart mediamtx
                sleep 5
            fi
            
            # Check if restart was successful using any available method
            if pgrep mediamtx >/dev/null 2>&1 || \
               (command -v nc >/dev/null 2>&1 && nc -z localhost $RTSP_PORT 2>/dev/null) || \
               (command -v curl >/dev/null 2>&1 && curl -s "rtsp://localhost:$RTSP_PORT" 2>&1 | grep -q "RTSP"); then
                log "SUCCESS" "MediaMTX restarted successfully"
                
                # Restart all streams
                log "INFO" "Restarting all streams due to RTSP server restart"
                
                # Kill all existing ffmpeg processes
                if command -v pkill >/dev/null 2>&1; then
                    pkill -f "ffmpeg.*rtsp" 2>/dev/null || true
                else
                    for pid in $(ps aux | grep "ffmpeg.*rtsp" | grep -v grep | awk '{print $2}'); do
                        kill -9 $pid 2>/dev/null || true
                    done
                fi
                
                # Wait for processes to terminate
                sleep 2
                
                # Clear running streams file
                > "$RUNNING_STREAMS_FILE"
                
                # Restart each stream
                if [ -f "$STREAM_DETAILS_FILE" ]; then
                    while IFS="|" read -r card_num card_id usb_info channels bitrate rtsp_url; do
                        # Skip empty lines
                        [ -z "$card_num" ] && continue
                        
                        # Extract bitrate value (remove 'k' suffix)
                        bitrate_val=$(echo "$bitrate" | sed 's/k$//')
                        
                        # Generate stream name
                        stream_name=$(get_stream_name "$card_id")
                        
                        # Detect current capabilities with fixed function
                        read -r restart_channels restart_sample_rate restart_audio_format < <(detect_audio_capabilities "$card_num" "$card_id")
                        restart_channels=${restart_channels:-$channels}
                        restart_sample_rate=${restart_sample_rate:-44100}
                        restart_audio_format=${restart_audio_format:-"S16_LE"}
                        
                        # Start the stream again
                        start_ffmpeg_stream "$card_num" "$card_id" "$restart_channels" "$restart_sample_rate" \
                                           "$restart_audio_format" "$bitrate_val" "$rtsp_url" "$stream_name"
                        
                        # Add delay between starts
                        sleep 2
                    done < "$STREAM_DETAILS_FILE"
                fi
            else
                log "ERROR" "Failed to restart MediaMTX"
            fi
        fi
        
        # Check each running stream
        if [ -f "$RUNNING_STREAMS_FILE" ]; then
            while IFS="|" read -r pid card_num card_id channels bitrate rtsp_url stream_name attempt; do
                # Skip empty lines
                [ -z "$pid" ] && continue
                
                # Check if process is still running
                if ! kill -0 "$pid" 2>/dev/null; then
                    log "WARNING" "Detected failed stream for card $card_id (PID: $pid)"
                    
                    # Only attempt restart if we haven't reached maximum attempts
                    if [ "$attempt" -lt 5 ]; then
                        log "INFO" "Attempting to restart stream for card $card_id"
                        
                        # Get latest capabilities
                        read -r restart_channels restart_sample_rate restart_audio_format < <(detect_audio_capabilities "$card_num" "$card_id")
                        restart_channels=${restart_channels:-$channels}
                        restart_sample_rate=${restart_sample_rate:-44100}
                        restart_audio_format=${restart_audio_format:-"S16_LE"}
                        
                        # Start the stream again
                        start_ffmpeg_stream "$card_num" "$card_id" "$restart_channels" "$restart_sample_rate" \
                                           "$restart_audio_format" "$bitrate" "$rtsp_url" "$stream_name"
                        
                        log "INFO" "Stream restart attempt completed for $card_id"
                    else
                        log "ERROR" "Maximum restart attempts reached for stream $card_id, giving up"
                    fi
                    
                    # Remove this entry from the running streams file
                    sed -i "/^$pid|/d" "$RUNNING_STREAMS_FILE" 2>/dev/null || true
                fi
            done < "$RUNNING_STREAMS_FILE"
        fi
        
        # Sleep before next check
        sleep 10
    done
}

# Count active streams
ACTIVE_STREAMS=$(wc -l < "$RUNNING_STREAMS_FILE" 2>/dev/null || echo "0")
log "INFO" "Total active streams: $ACTIVE_STREAMS"

# Verify streams are actually running
if [ "$ACTIVE_STREAMS" -gt 0 ]; then
    log "SUCCESS" "Audio streams are now running"
else
    log "WARNING" "No streams are running. Check logs for errors."
    
    # Additional diagnostic info
    log "INFO" "--- System Diagnostic Information ---"
    
    # Check system load
    if [ -f /proc/loadavg ]; then
        LOAD=$(cat /proc/loadavg)
        log "INFO" "System load: $LOAD"
    fi
    
    # Check memory usage
    if command -v free >/dev/null 2>&1; then
        MEM=$(free -h | grep Mem)
        log "INFO" "Memory usage: $MEM"
    fi
    
    # Check running processes
    log "INFO" "Running audio processes:"
    ps aux | grep -E "(ffmpeg|mediamtx|arecord)" | grep -v grep | while read -r line; do
        log "INFO" "Process: $line"
    done
fi

# Start the watchdog in the background
watchdog_monitor &
WATCHDOG_PID=$!

# Log active processes
log "INFO" "Started watchdog monitor with PID: $WATCHDOG_PID"
log "INFO" "All streams started successfully"

# Keep script running to maintain the background processes
echo "Press Ctrl+C to stop all streams and exit"
wait $WATCHDOG_PID
