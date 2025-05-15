#!/bin/bash
# Enhanced MediaMTX RTSP Audio Platform Installer
#
# https://raw.githubusercontent.com/tomtom215/mediamtx-rtsp-setup/refs/heads/main/mediamtx-rtsp-audio-installer.sh
#
# Version: 3.0.6
# Date: 2025-05-15
#
# This script orchestrates the installation of the MediaMTX RTSP audio streaming platform
# by coordinating the execution of dedicated component scripts rather than reimplementing
# their functionality. This maintains a clear separation of responsibilities while
# providing an enhanced unified installer experience.
#
# Changes in v3.0.6:
# - Implemented dynamic checksum verification with "trust on first use" model
# - Eliminated need for manual checksum updates when component scripts change
# - Added persistent storage of trusted script checksums
# - Improved script update workflow with user notification and approval
# - Enhanced security checks with smart fallbacks
#
# Changes in v3.0.5:
# - Updated component checksums to match current repository versions
# - Enhanced signal handling with more debugging information
# - Improved DNS resolution failure handling
# - Added more robust verification for downloaded scripts
# - Improved error handling for network connectivity checks
#
# Changes in v3.0.4:
# - Fixed critical bug causing script to terminate itself during reinstall
# - Improved process management with enhanced kill_process_safely function
# - Added better error handling for process termination with graceful fallback
# - Enhanced trap handling for more reliable cleanup
# - Improved pattern matching for process identification
# - Added wait times after process termination signals
# - Enhanced debug logging during process cleanup
#
# Changes in v3.0.3:
# - Implemented transaction-like installation with rollback capability
# - Added comprehensive pre-flight checks for installation requirements
# - Enhanced script validation and secure execution
# - Improved error detection and recovery
# - Added script verification with checksums
# - Fixed component script execution and dependency handling
# - Improved error handling and validation for downloaded scripts
# - Enhanced working directory management for component dependencies
# - Fixed verification of downloaded scripts before execution
# - Added more detailed debug logging for troubleshooting

# Set strict error handling
set -o pipefail

# Define script version
SCRIPT_VERSION="3.0.6"

# Default configuration
CONFIG_DIR="/etc/audio-rtsp"
CONFIG_FILE="${CONFIG_DIR}/config"
LOG_DIR="/var/log/audio-rtsp"
TEMP_DIR="/tmp/mediamtx-install-$(date +%s)-${RANDOM}"
BACKUP_DIR="${CONFIG_DIR}/backups/$(date +%Y%m%d%H%M%S)"
LOG_FILE="${LOG_DIR}/installer.log"
LOCK_FILE="/var/lock/mediamtx-installer.lock"
INSTANCE_ID="$$-$(date +%s)"
SCRIPT_NAME=$(basename "$0")
CHECKSUMS_DIR="${CONFIG_DIR}/checksums"

# Default values for MediaMTX
MEDIAMTX_VERSION="v1.12.2"
RTSP_PORT="18554"
RTMP_PORT="11935"
HLS_PORT="18888"
WEBRTC_PORT="18889"
METRICS_PORT="19999"

# Flags
DEBUG_MODE=false
QUIET_MODE=false
AUTO_YES=false
FORCE_MODE=false

# ANSI color codes for better visibility
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ======================================================================
# Utility Functions
# ======================================================================

# Display banner with script information
display_banner() {
    if [ "$QUIET_MODE" = true ]; then
        return 0
    fi
    
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${BLUE}   Enhanced MediaMTX RTSP Audio Platform Installer   ${NC}"
    echo -e "${BLUE}==============================================${NC}"
    echo -e "${GREEN}Version: ${SCRIPT_VERSION}${NC}"
    echo -e "${GREEN}Date: $(date +%Y-%m-%d)${NC}"
    echo
}

# Print usage help
show_help() {
    display_banner
    cat << EOF
Usage: $0 [OPTIONS] [COMMAND]

If no command is specified, an interactive menu will be displayed.

COMMANDS:
  install      Install MediaMTX and audio streaming platform
  uninstall    Remove all installed components
  update       Update to the latest version while preserving config
  reinstall    Completely remove and reinstall
  status       Show status of all components
  troubleshoot Run diagnostics and fix common issues
  logs         View or manage logs

OPTIONS:
  -v, --version VERSION    Specify MediaMTX version (default: $MEDIAMTX_VERSION)
  -p, --rtsp-port PORT     Specify RTSP port (default: $RTSP_PORT)
  --rtmp-port PORT         Specify RTMP port (default: $RTMP_PORT)
  --hls-port PORT          Specify HLS port (default: $HLS_PORT)
  --webrtc-port PORT       Specify WebRTC port (default: $WEBRTC_PORT)
  --metrics-port PORT      Specify metrics port (default: $METRICS_PORT)
  -d, --debug              Enable debug mode
  -q, --quiet              Minimal output
  -y, --yes                Answer yes to all prompts
  -f, --force              Force operation
  -h, --help               Show this help message

Example:
  $0 install
  $0 --rtsp-port 8554 install
  $0 uninstall
  $0 troubleshoot
EOF
}

# Enhanced logging function
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local log_line="[$timestamp] [${level}] $message"
    
    # Ensure log directory exists
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null
    
    # Write to log file
    echo "$log_line" >> "$LOG_FILE" 2>/dev/null || true
    
    # Print to console if not in quiet mode
    if [ "$QUIET_MODE" != true ] || [ "$level" = "ERROR" ]; then
        case "$level" in
            "DEBUG")
                [ "$DEBUG_MODE" = true ] && echo -e "${CYAN}[DEBUG]${NC} $message"
                ;;
            "INFO")
                echo -e "${GREEN}[INFO]${NC} $message"
                ;;
            "WARNING")
                echo -e "${YELLOW}[WARNING]${NC} $message"
                ;;
            "ERROR")
                echo -e "${RED}[ERROR]${NC} $message"
                ;;
            "SUCCESS")
                echo -e "${GREEN}${BOLD}[SUCCESS]${NC} $message"
                ;;
            *)
                echo -e "[$level] $message"
                ;;
        esac
    fi
}

# Debug function - prints only when debug mode is active
debug() {
    if [ "$DEBUG_MODE" = true ]; then
        log "DEBUG" "$@"
    fi
}

# Error function - logs error and exits if exit_code is provided
error() {
    local message="$1"
    local exit_code="$2"
    
    log "ERROR" "$message"
    
    if [ -n "$exit_code" ]; then
        cleanup
        exit "$exit_code"
    fi
}

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Function to validate a port number
validate_port() {
    local port="$1"
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        error "Invalid port number: $port. Must be between 1 and 65535." 1
    fi
}

# Check if running as root
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        error "This script must be run as root or with sudo privileges." 1
    fi
}

# Function to ask a yes/no question
ask_yes_no() {
    local question="$1"
    local default="$2"
    local result
    
    if [ "$AUTO_YES" = true ]; then
        return 0  # Auto-yes is enabled, always return true
    fi
    
    while true; do
        if [ "$default" = "y" ]; then
            echo -n -e "${YELLOW}${question} [Y/n]${NC} "
        else
            echo -n -e "${YELLOW}${question} [y/N]${NC} "
        fi
        
        read -r result
        
        case "$result" in
            [Yy]*)
                return 0
                ;;
            [Nn]*)
                return 1
                ;;
            "")
                if [ "$default" = "y" ]; then
                    return 0
                else
                    return 1
                fi
                ;;
            *)
                echo "Please answer yes or no."
                ;;
        esac
    done
}

# Present a menu of choices and return the result
show_menu() {
    local prompt="$1"
    shift
    local options=("$@")
    local choice
    
    echo -e "${BLUE}$prompt${NC}"
    for i in "${!options[@]}"; do
        echo -e "$((i+1)). ${options[i]}"
    done
    
    while true; do
        echo -n -e "${YELLOW}Enter your choice [1-${#options[@]}]: ${NC}"
        read -r choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#options[@]} ]; then
            return $((choice-1))
        else
            echo -e "${RED}Invalid choice. Please select 1-${#options[@]}.${NC}"
        fi
    done
}

# Function to ensure a directory exists with proper permissions
ensure_directory() {
    local dir="$1"
    local perm="${2:-755}"
    
    if [ ! -d "$dir" ]; then
        debug "Creating directory: $dir with permissions $perm"
        if ! mkdir -p "$dir" 2>/dev/null; then
            error "Failed to create directory: $dir" 1
        fi
        chmod "$perm" "$dir" 2>/dev/null || true
    else
        debug "Directory already exists: $dir"
    fi
}

# Function to check for exclusive lock - ensure only one instance is running
acquire_lock() {
    ensure_directory "$(dirname "$LOCK_FILE")"
    
    # Check if lock file exists and process is running
    if [ -f "$LOCK_FILE" ]; then
        local pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "0")
        if [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" -gt 0 ] && kill -0 "$pid" 2>/dev/null; then
            error "Another instance of this script is already running (PID: $pid)." 1
        else
            log "WARNING" "Found stale lock file. Overriding."
            rm -f "$LOCK_FILE"
        fi
    fi
    
    # Create lock file with our PID
    echo "$$" > "$LOCK_FILE" || error "Failed to create lock file." 1
}

# Function to release lock
release_lock() {
    if [ -f "$LOCK_FILE" ]; then
        # Only delete if it contains our PID
        local pid=$(cat "$LOCK_FILE" 2>/dev/null || echo "0")
        if [ "$pid" = "$$" ]; then
            rm -f "$LOCK_FILE"
        fi
    fi
}

# Detect system architecture
detect_architecture() {
    log "INFO" "Detecting system architecture..."
    
    local arch=$(uname -m)
    
    case "$arch" in
        x86_64|amd64)  
            ARCH="amd64" 
            ;;
        aarch64|arm64) 
            ARCH="arm64" 
            ;;
        armv7*|armhf)  
            ARCH="armv7" 
            ;;
        armv6*|armel)  
            ARCH="armv6" 
            ;;
        *)
            log "WARNING" "Architecture '$arch' not directly recognized."
            
            # Try to determine architecture through additional methods
            if command_exists dpkg; then
                local dpkg_arch=$(dpkg --print-architecture 2>/dev/null)
                case "$dpkg_arch" in
                    amd64)          ARCH="amd64" ;;
                    arm64)          ARCH="arm64" ;;
                    armhf)          ARCH="armv7" ;;
                    armel)          ARCH="armv6" ;;
                    *)              ARCH="unknown" ;;
                esac
            else
                ARCH="unknown"
            fi
            ;;
    esac
    
    if [ "$ARCH" = "unknown" ]; then
        error "Unsupported architecture: $arch" 1
    else
        log "INFO" "Detected architecture: $ARCH"
    fi
}

# Clean up function for exit
cleanup() {
    log "INFO" "Cleaning up resources..."
    
    # Release lock
    release_lock
    
    # Remove temporary directory
    if [ -d "$TEMP_DIR" ]; then
        if [ "$DEBUG_MODE" = true ]; then
            debug "Keeping temporary directory for debugging: $TEMP_DIR"
        else
            rm -rf "$TEMP_DIR"
        fi
    fi
    
    log "INFO" "Cleanup completed"
}

# Check for required commands
check_dependencies() {
    log "INFO" "Checking for required dependencies..."
    
    local missing_deps=()
    local deps=("bash" "systemctl" "curl" "wget" "tar" "grep" "awk" "sed")
    
    for dep in "${deps[@]}"; do
        if ! command_exists "$dep"; then
            missing_deps+=("$dep")
        fi
    done
    
    if [ ${#missing_deps[@]} -gt 0 ]; then
        log "WARNING" "Missing dependencies: ${missing_deps[*]}"
        
        if [ "$AUTO_YES" != true ]; then
            if ! ask_yes_no "Attempt to install missing dependencies?" "y"; then
                error "Cannot continue without required dependencies." 1
            fi
        fi
        
        log "INFO" "Installing missing dependencies..."
        
        # Try to determine the package manager
        if command_exists apt-get; then
            log "INFO" "Using apt package manager"
            apt-get update -qq
            apt-get install -y "${missing_deps[@]}"
        elif command_exists yum; then
            log "INFO" "Using yum package manager"
            yum install -y "${missing_deps[@]}"
        elif command_exists dnf; then
            log "INFO" "Using dnf package manager"
            dnf install -y "${missing_deps[@]}"
        else
            error "Could not determine package manager. Please install dependencies manually: ${missing_deps[*]}" 1
        fi
        
        # Verify dependencies installed
        for dep in "${missing_deps[@]}"; do
            if ! command_exists "$dep"; then
                error "Failed to install dependency: $dep. Please install it manually." 1
            fi
        done
        
        log "SUCCESS" "All dependencies installed successfully"
    else
        log "INFO" "All required dependencies are already installed"
    fi
}

# Check for internet connectivity with improved error handling
check_internet() {
    log "INFO" "Checking internet connectivity..."
    
    local connected=false
    local error_details=""
    
    # Try multiple methods
    if ping -c 1 -W 5 github.com >/dev/null 2>&1; then
        debug "Internet connectivity verified via ping"
        connected=true
    else
        error_details="ping failed"
    fi
    
    if [ "$connected" != true ]; then
        if wget --spider --quiet --timeout=10 https://github.com 2>/dev/null; then
            debug "Internet connectivity verified via wget"
            connected=true
        else
            error_details="$error_details, wget failed"
        fi
    fi
    
    if [ "$connected" != true ]; then
        if curl --head --silent --fail --connect-timeout 10 https://github.com >/dev/null 2>&1; then
            debug "Internet connectivity verified via curl"
            connected=true
        else
            error_details="$error_details, curl failed"
        fi
    fi
    
    if [ "$connected" != true ]; then
        error "No internet connectivity. Details: $error_details. Cannot proceed with installation." 1
    fi
    
    log "INFO" "Internet connectivity verified"
    return 0
}

# Function to safely download a file to specified directory
download_file() {
    local url="$1"
    local output_dir="$2"
    local filename="$3"
    local output_path="${output_dir}/${filename}"
    
    ensure_directory "$output_dir"
    
    log "INFO" "Downloading ${filename} from: ${url}"
    
    if command_exists curl; then
        if [ "$QUIET_MODE" = true ]; then
            if ! curl -s -L -o "$output_path" "$url"; then
                error "Failed to download ${filename} using curl" 1
            fi
        else
            if ! curl -L --progress-bar -o "$output_path" "$url"; then
                error "Failed to download ${filename} using curl" 1
            fi
        fi
    elif command_exists wget; then
        if [ "$QUIET_MODE" = true ]; then
            if ! wget -q -O "$output_path" "$url"; then
                error "Failed to download ${filename} using wget" 1
            fi
        else
            if ! wget --progress=bar:force:noscroll -O "$output_path" "$url"; then
                error "Failed to download ${filename} using wget" 1
            fi
        fi
    else
        error "Neither curl nor wget is available. Cannot download files." 1
    fi
    
    # Check if download was successful
    if [ ! -s "$output_path" ]; then
        error "Downloaded file is empty: ${output_path}" 1
    fi
    
    log "SUCCESS" "Successfully downloaded ${filename}"
    echo "$output_path"
}

# Wait for user to press Enter
press_enter_to_continue() {
    echo -e "\n${YELLOW}Press Enter to continue...${NC}"
    read -r
}

# Enhanced process management function
kill_process_safely() {
    local pattern="$1"
    local exclude_pattern="${2:-}"
    local signal="${3:-TERM}"
    local force_kill="${4:-true}"
    local wait_time="${5:-1}"
    
    debug "Attempting to kill processes matching: '$pattern'"
    debug "Excluding patterns: '$exclude_pattern'"
    debug "Using signal: $signal with force kill: $force_kill"
    
    # Get our own process info
    local our_pid=$$
    local our_ppid=$PPID
    local our_script=$(basename "$0")
    
    # Find matching processes
    local ps_cmd="ps -eo pid,cmd"
    local grep_cmd="grep -E \"$pattern\""
    
    if [ -n "$exclude_pattern" ]; then
        grep_cmd="$grep_cmd | grep -v \"$exclude_pattern\""
    fi
    
    # Always exclude grep itself and our script name
    grep_cmd="$grep_cmd | grep -v grep | grep -v \"$our_script\""
    local awk_cmd="awk '{print \$1}'"
    
    local cmd="$ps_cmd | $grep_cmd | $awk_cmd"
    debug "Process search command: $cmd"
    
    # Execute the command to find PIDs
    local pids
    pids=$(eval "$cmd" 2>/dev/null)
    
    if [ -z "$pids" ]; then
        debug "No processes found matching pattern: '$pattern'"
        return 0
    fi
    
    debug "Found matching PIDs: $pids"
    
    # Kill each process
    for pid in $pids; do
        if [ "$pid" != "$our_pid" ] && [ "$pid" != "$our_ppid" ]; then
            debug "Sending signal $signal to PID $pid"
            kill -s "$signal" "$pid" 2>/dev/null
            
            if [ "$force_kill" = true ] && [ "$signal" != "KILL" ]; then
                # Wait briefly for process to terminate
                sleep "$wait_time"
                
                # Check if process is still running and force kill if needed
                if kill -0 "$pid" 2>/dev/null; then
                    log "WARNING" "Process $pid did not terminate with $signal, sending SIGKILL"
                    kill -s KILL "$pid" 2>/dev/null || true
                    
                    # Check if the process still exists
                    sleep 0.5
                    if kill -0 "$pid" 2>/dev/null; then
                        log "ERROR" "Failed to kill process $pid even with SIGKILL"
                    else
                        debug "Process $pid terminated after SIGKILL"
                    fi
                else
                    debug "Process $pid terminated after $signal"
                fi
            fi
        else
            debug "Skipping our own process: $pid"
        fi
    done
    
    return 0
}

# Function to check internet connectivity with multiple methods
check_internet_connectivity() {
    log "INFO" "Checking internet connectivity..."
    
    local connectivity_status=false
    local dns_ok=false
    local ping_ok=false
    local http_ok=false
    
    # Check DNS resolution first
    if host github.com >/dev/null 2>&1; then
        debug "DNS resolution successful for github.com"
        dns_ok=true
    else
        log "WARNING" "DNS resolution failed for github.com (will try alternative methods)"
    fi
    
    # Try ping method
    if ping -c 1 -W 5 github.com >/dev/null 2>&1; then
        debug "Ping test successful to github.com"
        ping_ok=true
        connectivity_status=true
    else
        debug "Ping test failed"
    fi
    
    # Try HTTP method if ping failed
    if [ "$connectivity_status" != true ]; then
        if wget --spider --quiet --timeout=10 https://github.com 2>/dev/null; then
            debug "HTTP connectivity verified via wget"
            http_ok=true
            connectivity_status=true
        elif curl --head --silent --fail --connect-timeout 10 https://github.com >/dev/null 2>&1; then
            debug "HTTP connectivity verified via curl"
            http_ok=true
            connectivity_status=true
        else
            debug "HTTP connectivity tests failed"
        fi
    fi
    
    # Log detailed connectivity status if in debug mode
    if [ "$DEBUG_MODE" = true ]; then
        debug "Connectivity status summary:"
        debug "- DNS resolution: $([ "$dns_ok" = true ] && echo "OK" || echo "Failed")"
        debug "- Ping test: $([ "$ping_ok" = true ] && echo "OK" || echo "Failed")"
        debug "- HTTP test: $([ "$http_ok" = true ] && echo "OK" || echo "Failed")"
    fi
    
    if [ "$connectivity_status" = true ]; then
        log "INFO" "Internet connectivity verified"
        return 0
    else
        log "ERROR" "All internet connectivity tests failed"
        return 1
    fi
}

# Function to dynamically manage script checksums
verify_component_script() {
    local script_path="$1"
    local script_name="$(basename "$script_path")"
    local checksum_file="${CHECKSUMS_DIR}/${script_name}.sha256"
    local current_checksum=""
    
    # Ensure checksums directory exists
    ensure_directory "$CHECKSUMS_DIR" "700"
    
    # Basic script validation
    if [ ! -f "$script_path" ] || [ ! -s "$script_path" ]; then
        log "ERROR" "Script file is missing or empty: $script_path"
        return 1
    fi
    
    # Syntax check
    if ! bash -n "$script_path"; then
        log "ERROR" "Script $script_name contains syntax errors"
        return 1
    fi
    
    # Calculate current checksum
    if command_exists sha256sum; then
        current_checksum=$(sha256sum "$script_path" | awk '{print $1}')
        
        # If no stored checksum exists, store current and return success
        if [ ! -f "$checksum_file" ]; then
            log "INFO" "First use of $script_name - storing checksum for future verification"
            echo "$current_checksum" > "$checksum_file"
            return 0
        fi
        
        # Compare with stored checksum
        local stored_checksum=$(cat "$checksum_file")
        if [ "$current_checksum" != "$stored_checksum" ]; then
            log "WARNING" "Script $script_name has changed since last verified use"
            log "WARNING" "Previous: $stored_checksum"
            log "WARNING" "Current:  $current_checksum"
            
            # Handle checksum mismatch based on settings
            if [ "$FORCE_MODE" = true ] || [ "$AUTO_YES" = true ]; then
                log "INFO" "Force/auto mode active, accepting new version and updating stored checksum"
                echo "$current_checksum" > "$checksum_file"
                return 0
            else
                log "WARNING" "Script has changed - this could indicate tampering or legitimate updates"
                if ask_yes_no "Accept new version of $script_name and update stored checksum?" "n"; then
                    echo "$current_checksum" > "$checksum_file"
                    log "INFO" "Checksum updated for $script_name"
                    return 0
                else
                    log "ERROR" "Script verification failed. Use --force to override or accept the new version."
                    return 1
                fi
            fi
        else
            debug "Checksum verification passed for $script_name"
            return 0
        fi
    else
        log "WARNING" "sha256sum not available, skipping checksum verification"
        # Fallback to basic validation only
        return 0
    fi
}

# ======================================================================
# Rollback and Installation Transaction Functions
# ======================================================================

# Variables for rollback
rollback_dir=""
rollback_registry=""

# Function to perform pre-flight checks before installation
perform_preflight_checks() {
    log "INFO" "Performing pre-flight checks before installation..."
    
    # Check disk space
    local required_space=100000  # 100MB minimum
    local available_space
    available_space=$(df -k /usr/local | awk 'NR==2 {print $4}')
    
    if [ "$available_space" -lt "$required_space" ]; then
        error "Not enough disk space. Required: ${required_space}KB, Available: ${available_space}KB" 1
    fi
    
    # Verify existence of critical directories and write permissions
    for dir in "/usr/local/bin" "/etc" "/var/log"; do
        if [ ! -d "$dir" ]; then
            error "Critical system directory missing: $dir" 1
        fi
        
        if [ ! -w "$dir" ]; then
            error "No write permission for directory: $dir" 1
        fi
    fi
    
    # Verify network connectivity before downloading anything
    if ! check_internet_connectivity; then
        error "Internet connectivity check failed. Cannot proceed with installation." 1
    fi
    
    # Check required ports availability
    for port in "$RTSP_PORT" "$RTMP_PORT" "$HLS_PORT" "$WEBRTC_PORT" "$METRICS_PORT"; do
        if command_exists netstat && netstat -tuln | grep -q ":$port "; then
            error "Port $port is already in use. Please specify different ports." 1
        elif command_exists ss && ss -tuln | grep -q ":$port "; then
            error "Port $port is already in use. Please specify different ports." 1
        fi
    done
    
    # Verify component dependencies are met
    check_dependencies
    
    # Create installation record
    ensure_directory "${CONFIG_DIR}"
    echo "Preflight checks completed successfully at $(date)" > "${CONFIG_DIR}/install_status.txt"
    
    log "SUCCESS" "Pre-flight checks completed successfully"
    return 0
}

# Function to initialize rollback registry
init_rollback() {
    log "INFO" "Initializing installation rollback registry..."
    
    # Create rollback directory
    rollback_dir="${TEMP_DIR}/rollback"
    mkdir -p "$rollback_dir"
    
    # Create registry file
    rollback_registry="${rollback_dir}/registry.txt"
    > "$rollback_registry"
    
    # Record original state
    echo "STARTED:$(date +%s)" >> "$rollback_registry"
    
    # Record existing services
    if systemctl list-unit-files mediamtx.service >/dev/null 2>&1; then
        echo "SERVICE:mediamtx:EXISTED" >> "$rollback_registry"
    else
        echo "SERVICE:mediamtx:NEW" >> "$rollback_registry"
    fi
    
    if systemctl list-unit-files audio-rtsp.service >/dev/null 2>&1; then
        echo "SERVICE:audio-rtsp:EXISTED" >> "$rollback_registry"
    else
        echo "SERVICE:audio-rtsp:NEW" >> "$rollback_registry"
    fi
    
    if systemctl list-unit-files mediamtx-monitor.service >/dev/null 2>&1; then
        echo "SERVICE:mediamtx-monitor:EXISTED" >> "$rollback_registry"
    else
        echo "SERVICE:mediamtx-monitor:NEW" >> "$rollback_registry"
    fi
    
    # Record existing binaries
    for bin in "/usr/local/bin/startmic.sh" "/usr/local/bin/mediamtx-monitor.sh" "/usr/local/mediamtx/mediamtx"; do
        if [ -f "$bin" ]; then
            echo "BINARY:${bin}:EXISTED" >> "$rollback_registry"
            # Create backup of existing binary
            mkdir -p "${rollback_dir}/bin"
            cp "$bin" "${rollback_dir}/bin/$(basename "$bin").backup" 2>/dev/null || true
        else
            echo "BINARY:${bin}:NEW" >> "$rollback_registry"
        fi
    done
    
    # Record existing config files
    for conf in "${CONFIG_DIR}/config" "/etc/mediamtx/mediamtx.yml"; do
        if [ -f "$conf" ]; then
            echo "CONFIG:${conf}:EXISTED" >> "$rollback_registry"
            # Create backup of existing config
            mkdir -p "${rollback_dir}/conf"
            cp "$conf" "${rollback_dir}/conf/$(basename "$conf").backup" 2>/dev/null || true
        else
            echo "CONFIG:${conf}:NEW" >> "$rollback_registry"
        fi
    done
    
    log "INFO" "Rollback registry initialized"
    return 0
}

# Function to record installation steps
record_install_step() {
    local step="$1"
    local status="$2"
    
    echo "STEP:${step}:${status}:$(date +%s)" >> "$rollback_registry"
    echo "${status}:${step}" >> "${CONFIG_DIR}/install_status.txt"
    
    log "INFO" "Recorded installation step: $step - $status"
    return 0
}

# Function to perform rollback if installation fails
rollback_installation() {
    local reason="$1"
    
    log "ERROR" "Installation failed: $reason"
    log "INFO" "Initiating rollback..."
    
    # Update installation status
    echo "ROLLBACK:STARTED:$(date +%s):$reason" >> "${CONFIG_DIR}/install_status.txt"
    
    # Read registry to determine what to roll back
    if [ ! -f "$rollback_registry" ]; then
        log "ERROR" "Rollback registry not found, cannot perform rollback"
        return 1
    fi
    
    # Stop services
    log "INFO" "Stopping services..."
    systemctl stop mediamtx-monitor.service 2>/dev/null || true
    systemctl stop audio-rtsp.service 2>/dev/null || true
    systemctl stop mediamtx.service 2>/dev/null || true
    
    # Process registry entries in reverse order
    local lines
    lines=$(wc -l < "$rollback_registry")
    for ((i=lines; i>=1; i--)); do
        local line
        line=$(sed -n "${i}p" "$rollback_registry")
        
        if [[ "$line" == STEP:* ]]; then
            local step status timestamp
            IFS=':' read -r _ step status timestamp <<< "$line"
            
            log "INFO" "Rolling back step: $step (was $status)"
            
            case "$step" in
                "mediamtx-service")
                    if [ "$status" = "SUCCESS" ]; then
                        if grep -q "SERVICE:mediamtx:NEW" "$rollback_registry"; then
                            log "INFO" "Removing newly created mediamtx service"
                            systemctl disable mediamtx.service 2>/dev/null || true
                            rm -f /etc/systemd/system/mediamtx.service
                        else
                            log "INFO" "Restoring original mediamtx service"
                            if [ -f "${rollback_dir}/conf/mediamtx.service.backup" ]; then
                                cp "${rollback_dir}/conf/mediamtx.service.backup" /etc/systemd/system/mediamtx.service
                            fi
                        fi
                    fi
                    ;;
                "audio-rtsp-service")
                    if [ "$status" = "SUCCESS" ]; then
                        if grep -q "SERVICE:audio-rtsp:NEW" "$rollback_registry"; then
                            log "INFO" "Removing newly created audio-rtsp service"
                            systemctl disable audio-rtsp.service 2>/dev/null || true
                            rm -f /etc/systemd/system/audio-rtsp.service
                        else
                            log "INFO" "Restoring original audio-rtsp service"
                            if [ -f "${rollback_dir}/conf/audio-rtsp.service.backup" ]; then
                                cp "${rollback_dir}/conf/audio-rtsp.service.backup" /etc/systemd/system/audio-rtsp.service
                            fi
                        fi
                    fi
                    ;;
                "mediamtx-monitor-service")
                    if [ "$status" = "SUCCESS" ]; then
                        if grep -q "SERVICE:mediamtx-monitor:NEW" "$rollback_registry"; then
                            log "INFO" "Removing newly created mediamtx-monitor service"
                            systemctl disable mediamtx-monitor.service 2>/dev/null || true
                            rm -f /etc/systemd/system/mediamtx-monitor.service
                        else
                            log "INFO" "Restoring original mediamtx-monitor service"
                            if [ -f "${rollback_dir}/conf/mediamtx-monitor.service.backup" ]; then
                                cp "${rollback_dir}/conf/mediamtx-monitor.service.backup" /etc/systemd/system/mediamtx-monitor.service
                            fi
                        fi
                    fi
                    ;;
                "mediamtx-binary")
                    if [ "$status" = "SUCCESS" ]; then
                        if grep -q "BINARY:/usr/local/mediamtx/mediamtx:NEW" "$rollback_registry"; then
                            log "INFO" "Removing newly installed mediamtx binary"
                            rm -f /usr/local/mediamtx/mediamtx
                        else
                            log "INFO" "Restoring original mediamtx binary"
                            if [ -f "${rollback_dir}/bin/mediamtx.backup" ]; then
                                cp "${rollback_dir}/bin/mediamtx.backup" /usr/local/mediamtx/mediamtx
                                chmod +x /usr/local/mediamtx/mediamtx
                            fi
                        fi
                    fi
                    ;;
                "startmic-script")
                    if [ "$status" = "SUCCESS" ]; then
                        if grep -q "BINARY:/usr/local/bin/startmic.sh:NEW" "$rollback_registry"; then
                            log "INFO" "Removing newly installed startmic.sh script"
                            rm -f /usr/local/bin/startmic.sh
                        else
                            log "INFO" "Restoring original startmic.sh script"
                            if [ -f "${rollback_dir}/bin/startmic.sh.backup" ]; then
                                cp "${rollback_dir}/bin/startmic.sh.backup" /usr/local/bin/startmic.sh
                                chmod +x /usr/local/bin/startmic.sh
                            fi
                        fi
                    fi
                    ;;
                "mediamtx-monitor-script")
                    if [ "$status" = "SUCCESS" ]; then
                        if grep -q "BINARY:/usr/local/bin/mediamtx-monitor.sh:NEW" "$rollback_registry"; then
                            log "INFO" "Removing newly installed mediamtx-monitor.sh script"
                            rm -f /usr/local/bin/mediamtx-monitor.sh
                        else
                            log "INFO" "Restoring original mediamtx-monitor.sh script"
                            if [ -f "${rollback_dir}/bin/mediamtx-monitor.sh.backup" ]; then
                                cp "${rollback_dir}/bin/mediamtx-monitor.sh.backup" /usr/local/bin/mediamtx-monitor.sh
                                chmod +x /usr/local/bin/mediamtx-monitor.sh
                            fi
                        fi
                    fi
                    ;;
            esac
        fi
    done
    
    # Reload systemd
    systemctl daemon-reload
    
    # Update installation status
    echo "ROLLBACK:COMPLETED:$(date +%s)" >> "${CONFIG_DIR}/install_status.txt"
    
    log "INFO" "Rollback completed"
    return 0
}

# ======================================================================
# Component Script Operations
# ======================================================================

# Pre-download required scripts for a specific component
predownload_dependency_scripts() {
    local component="$1"
    local working_dir="$2"
    
    case "$component" in
        "setup-monitor-script.sh")
            log "INFO" "Pre-downloading dependencies for monitoring setup..."
            
            # Download mediamtx-monitor.sh which is required by setup-monitor-script.sh
            local monitor_url="https://raw.githubusercontent.com/tomtom215/mediamtx-rtsp-setup/refs/heads/main/mediamtx-monitor.sh"
            local monitor_script="${working_dir}/mediamtx-monitor.sh"
            
            if [ ! -f "$monitor_script" ]; then
                download_file "$monitor_url" "$working_dir" "mediamtx-monitor.sh" > /dev/null
                chmod +x "$monitor_script"
                
                # Verify the script was downloaded correctly
                if [ -f "$monitor_script" ] && [ -s "$monitor_script" ]; then
                    log "INFO" "Downloaded mediamtx-monitor.sh dependency"
                    # Also ensure the main script is downloaded
                    local setup_url="https://raw.githubusercontent.com/tomtom215/mediamtx-rtsp-setup/refs/heads/main/setup-monitor-script.sh"
                    local setup_script="${working_dir}/setup-monitor-script.sh"
                    download_file "$setup_url" "$working_dir" "setup-monitor-script.sh" > /dev/null
                    chmod +x "$setup_script"
                    
                    if [ ! -f "$setup_script" ] || [ ! -s "$setup_script" ]; then
                        log "ERROR" "Failed to download or verify setup-monitor-script.sh"
                        return 1
                    else
                        log "INFO" "Downloaded and verified setup-monitor-script.sh"
                    fi
                else
                    log "ERROR" "Failed to download or verify mediamtx-monitor.sh dependency"
                    return 1
                fi
            else
                log "INFO" "mediamtx-monitor.sh dependency already exists"
            fi
            ;;
            
        "setup_audio_rtsp.sh")
            log "INFO" "Pre-downloading dependencies for audio RTSP setup..."
            
            # Download startmic.sh which is required by setup_audio_rtsp.sh
            local startmic_url="https://raw.githubusercontent.com/tomtom215/mediamtx-rtsp-setup/refs/heads/main/startmic.sh"
            local startmic_script="${working_dir}/startmic.sh"
            
            if [ ! -f "$startmic_script" ]; then
                download_file "$startmic_url" "$working_dir" "startmic.sh" > /dev/null
                chmod +x "$startmic_script"
                
                # Verify the script was downloaded correctly
                if [ -f "$startmic_script" ] && [ -s "$startmic_script" ]; then
                    log "INFO" "Downloaded startmic.sh dependency"
                else
                    log "ERROR" "Failed to download or verify startmic.sh dependency"
                    return 1
                fi
            else
                log "INFO" "startmic.sh dependency already exists"
            fi
            
            # Ensure setup_audio_rtsp.sh is also downloaded
            local setup_url="https://raw.githubusercontent.com/tomtom215/mediamtx-rtsp-setup/refs/heads/main/setup_audio_rtsp.sh"
            local setup_script="${working_dir}/setup_audio_rtsp.sh"
            
            if [ ! -f "$setup_script" ]; then
                log "INFO" "Downloading main script setup_audio_rtsp.sh..."
                download_file "$setup_url" "$working_dir" "setup_audio_rtsp.sh" > /dev/null
                chmod +x "$setup_script"
                
                # Verify the script was downloaded correctly
                if [ -f "$setup_script" ] && [ -s "$setup_script" ]; then
                    log "INFO" "Downloaded setup_audio_rtsp.sh successfully"
                else
                    log "ERROR" "Failed to download or verify setup_audio_rtsp.sh"
                    return 1
                fi
            else
                log "INFO" "setup_audio_rtsp.sh already exists"
            fi
            ;;
    esac
    
    return 0
}

# Execute a component script with appropriate options and validation
execute_component_script() {
    local script_name="$1"
    shift
    local script_args=("$@")
    local working_dir
    local script_path=""
    local download_success=false
    
    # Validate script name
    if [[ ! "$script_name" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
        log "ERROR" "Invalid script name: $script_name"
        return 1
    fi
    
    # Determine where to run the script from
    if [[ "$script_name" == "setup-monitor-script.sh" || "$script_name" == "setup_audio_rtsp.sh" ]]; then
        # For scripts with dependencies, we need a working directory
        working_dir="${TEMP_DIR}/component_scripts/${script_name%.sh}"
        ensure_directory "$working_dir"
        
        # Pre-download any required dependencies
        if ! predownload_dependency_scripts "$script_name" "$working_dir"; then
            log "ERROR" "Failed to download dependencies for $script_name"
            return 1
        fi
    else
        # For other scripts, we can run from the original directory
        working_dir="$TEMP_DIR"
        ensure_directory "$working_dir"
    fi
    
    log "INFO" "Checking for script: ${script_name}"
    
    # First check if the script exists in the current directory
    if [ -f "./${script_name}" ]; then
        script_path="./${script_name}"
        log "INFO" "Found ${script_name} in current directory"
        download_success=true
    # Then check in standard locations
    elif [ -f "/usr/local/bin/${script_name}" ]; then
        script_path="/usr/local/bin/${script_name}"
        log "INFO" "Found ${script_name} in /usr/local/bin"
        download_success=true
    # Finally, try to download it if not found
    else
        log "INFO" "Script ${script_name} not found locally, downloading it..."
        local download_url="https://raw.githubusercontent.com/tomtom215/mediamtx-rtsp-setup/refs/heads/main/${script_name}"
        
        # Use working directory for download location
        script_path="${working_dir}/${script_name}"
        
        # Ensure clean download by removing any existing file
        rm -f "$script_path" 2>/dev/null
        
        # Download with progress feedback and validation
        log "INFO" "Downloading from $download_url to $script_path"
        
        local download_errors=""
        local download_status=1
        
        # Try wget first
        if command_exists wget; then
            if [ "$QUIET_MODE" = true ]; then
                wget -q --tries=3 --timeout=15 "$download_url" -O "$script_path" 2>/dev/null
                download_status=$?
            else
                wget --progress=bar:force:noscroll --tries=3 --timeout=15 "$download_url" -O "$script_path" 2>&1 | tee -a "$LOG_FILE"
                download_status=${PIPESTATUS[0]}
            fi
            
            if [ $download_status -eq 0 ] && [ -s "$script_path" ]; then
                download_success=true
            else
                download_errors="wget failed with status $download_status"
            fi
        fi
        
        # Try curl if wget failed or isn't available
        if [ "$download_success" != true ] && command_exists curl; then
            log "INFO" "Trying curl as fallback..."
            
            if [ "$QUIET_MODE" = true ]; then
                curl -s -L --retry 3 --connect-timeout 15 "$download_url" -o "$script_path" 2>/dev/null
                download_status=$?
            else
                curl -L --retry 3 --connect-timeout 15 --progress-bar "$download_url" -o "$script_path" 2>&1 | tee -a "$LOG_FILE"
                download_status=$?
            fi
            
            if [ $download_status -eq 0 ] && [ -s "$script_path" ]; then
                download_success=true
            else
                download_errors="$download_errors, curl failed with status $download_status"
            fi
        fi
        
        # Check if download was successful
        if [ "$download_success" != true ]; then
            log "ERROR" "All download methods failed: $download_errors"
            return 1
        fi
        
        # Validate downloaded script
        if [ -f "$script_path" ]; then
            # Check file size
            local file_size
            file_size=$(stat -c %s "$script_path" 2>/dev/null || echo "0")
            if [ "$file_size" -lt 100 ]; then
                log "ERROR" "Downloaded file is too small (${file_size} bytes): $script_path"
                return 1
            fi
            
            # Check for bash shebang
            if ! head -n 1 "$script_path" | grep -q "^#!/bin/bash"; then
                log "WARNING" "Script does not start with proper shebang: $script_path"
                # Adding shebang for safety
                sed -i '1s/^/#!\/bin\/bash\n/' "$script_path"
            fi
            
            # Verify script using our new dynamic verification function
            if ! verify_component_script "$script_path"; then
                log "ERROR" "Script verification failed for $script_name"
                return 1
            fi
            
            log "INFO" "Downloaded and verified $script_name"
        else
            log "ERROR" "Script file not found after download: $script_path"
            return 1
        fi
    fi
    
    # Verify script exists after all checks
    if [ ! -f "$script_path" ]; then
        log "ERROR" "Script file not found: $script_path"
        return 1
    fi
    
    # Verify locally found scripts as well
    if [ "$download_success" = true ] && [ -f "$script_path" ]; then
        if ! verify_component_script "$script_path"; then
            log "ERROR" "Script verification failed for found script: $script_name"
            return 1
        fi
    fi
    
    # Make sure the script is executable
    chmod +x "$script_path" || {
        log "ERROR" "Failed to make ${script_name} executable"
        return 1
    }
    
    log "INFO" "Executing ${script_name} with arguments: ${script_args[*]}"
    
    # Save current directory
    local current_dir
    current_dir="$(pwd)"
    
    # Change to the appropriate working directory
    cd "$working_dir" || {
        log "ERROR" "Failed to change to working directory: $working_dir"
        return 1
    }
    
    # Create a wrapper script for better error handling
    local wrapper_script="${working_dir}/wrapper_${script_name}"
    cat > "$wrapper_script" << EOF
#!/bin/bash
# Wrapper script for better error handling
set -o pipefail

# Execute the target script with arguments
"$script_path" $(printf '%q ' "${script_args[@]}")
exit \$?
EOF
    chmod +x "$wrapper_script"
    
    # Run the wrapper script and capture both output and exit code
    local script_output="${working_dir}/output_${script_name}.log"
    local exit_code=0
    
    if [ "$QUIET_MODE" = true ]; then
        "$wrapper_script" > "$script_output" 2>&1
        exit_code=$?
    else
        # Show output but also capture it
        "$wrapper_script" 2>&1 | tee "$script_output"
        exit_code=${PIPESTATUS[0]}
    fi
    
    # Change back to original directory
    cd "$current_dir" || log "WARNING" "Failed to change back to original directory"
    
    # Check execution status
    if [ $exit_code -eq 0 ]; then
        log "SUCCESS" "${script_name} executed successfully"
        return 0
    else
        log "ERROR" "${script_name} failed with exit code ${exit_code}"
        log "ERROR" "Last 10 lines of output:"
        tail -n 10 "$script_output" | while read -r line; do
            log "ERROR" "  $line"
        done
        return $exit_code
    fi
}

# ======================================================================
# Main Command Functions
# ======================================================================

# Install MediaMTX platform
install_command() {
    log "INFO" "Starting MediaMTX platform installation..."
    
    # Check for existing installation
    if [ -f "/usr/local/mediamtx/mediamtx" ] && [ -f "$CONFIG_FILE" ] && [ "$FORCE_MODE" != true ]; then
        log "WARNING" "MediaMTX appears to be already installed"
        
        if ! ask_yes_no "Do you want to proceed with installation anyway?" "n"; then
            log "INFO" "Installation cancelled by user"
            error "Installation cancelled. Use update command instead or use --force to override." 1
        fi
    fi
    
    # Perform preflight checks
    if ! perform_preflight_checks; then
        error "Pre-flight checks failed. Cannot proceed with installation." 1
    fi
    
    # Initialize rollback capability
    init_rollback
    
    # Ensure temp directory exists
    ensure_directory "$TEMP_DIR"
    
    # Step 1: Install MediaMTX using install_mediamtx.sh
    local mediamtx_args=(
        "-v" "$MEDIAMTX_VERSION"
        "-p" "$RTSP_PORT"
        "--rtmp-port" "$RTMP_PORT"
        "--hls-port" "$HLS_PORT" 
        "--webrtc-port" "$WEBRTC_PORT"
        "--metrics-port" "$METRICS_PORT"
    )
    
    if [ "$FORCE_MODE" = true ]; then
        mediamtx_args+=("--force-install")
    fi
    
    if [ "$DEBUG_MODE" = true ]; then
        mediamtx_args+=("--debug")
    fi
    
    log "INFO" "Installing MediaMTX..."
    if execute_component_script "install_mediamtx.sh" "${mediamtx_args[@]}"; then
        record_install_step "mediamtx-binary" "SUCCESS"
        record_install_step "mediamtx-service" "SUCCESS"
    else
        log "ERROR" "MediaMTX installation failed"
        rollback_installation "MediaMTX installation failed"
        error "Installation failed during MediaMTX component. Check logs for details." 1
    fi
    
    # Step 2: Setup audio RTSP using setup_audio_rtsp.sh
    # First create a backup of any existing config file
    if [ -f "$CONFIG_FILE" ]; then
        ensure_directory "$BACKUP_DIR"
        log "INFO" "Backing up existing audio-rtsp configuration"
        cp "$CONFIG_FILE" "${BACKUP_DIR}/config.backup"
    fi
    
    log "INFO" "Setting up audio RTSP service..."
    if execute_component_script "setup_audio_rtsp.sh"; then
        record_install_step "startmic-script" "SUCCESS"
        record_install_step "audio-rtsp-service" "SUCCESS"
    else
        log "ERROR" "Audio RTSP setup failed"
        rollback_installation "Audio RTSP setup failed"
        error "Installation failed during audio RTSP setup. Check logs for details." 1
    fi
    
    # Step 3: Setup monitoring using setup-monitor-script.sh
    log "INFO" "Setting up monitoring service..."
    if execute_component_script "setup-monitor-script.sh"; then
        record_install_step "mediamtx-monitor-script" "SUCCESS"
        record_install_step "mediamtx-monitor-service" "SUCCESS"
    else
        log "ERROR" "Monitor setup failed"
        rollback_installation "Monitoring service setup failed"
        error "Installation failed during monitor setup. Check logs for details." 1
    fi
    
    # Record installation success
    echo "INSTALLATION:COMPLETED:$(date +%s)" >> "${CONFIG_DIR}/install_status.txt"
    
    # Print installation summary
    log "SUCCESS" "MediaMTX platform has been successfully installed!"
    
    if [ "$QUIET_MODE" != true ]; then
        echo
        echo -e "${GREEN}==============================================${NC}"
        echo -e "${GREEN}   MediaMTX Platform installed successfully!   ${NC}"
        echo -e "${GREEN}==============================================${NC}"
        echo
        echo -e "Installation directory: ${BLUE}/usr/local/mediamtx${NC}"
        echo -e "Configuration: ${BLUE}$CONFIG_DIR/config${NC}"
        echo -e "Log directory: ${BLUE}$LOG_DIR${NC}"
        echo -e "Services installed:"
        echo -e "  - ${GREEN}mediamtx.service${NC}"
        echo -e "  - ${GREEN}audio-rtsp.service${NC}"
        echo -e "  - ${GREEN}mediamtx-monitor.service${NC}"
        echo
        echo -e "Commands available:"
        echo -e "  - ${YELLOW}check-audio-rtsp.sh${NC} - Check audio streaming status"
        echo -e "  - ${YELLOW}check-mediamtx-monitor.sh${NC} - Check monitoring status"
        echo
        echo -e "To check streaming status:"
        echo -e "  ${BLUE}sudo check-audio-rtsp.sh${NC}"
        echo
    fi
    
    return 0
}

# Uninstall MediaMTX platform
uninstall_command() {
    log "INFO" "Starting MediaMTX platform uninstallation..."
    
    # Confirm uninstallation
    if [ "$AUTO_YES" != true ]; then
        if ! ask_yes_no "Are you sure you want to uninstall MediaMTX platform?" "n"; then
            log "INFO" "Uninstallation cancelled by user"
            error "Uninstallation cancelled." 1
        fi
    fi
    
    # Step 1: Stop and disable all services in reverse dependency order
    log "INFO" "Stopping and disabling services..."
    systemctl stop mediamtx-monitor.service 2>/dev/null || true
    systemctl stop audio-rtsp.service 2>/dev/null || true
    systemctl stop mediamtx.service 2>/dev/null || true
    
    systemctl disable mediamtx-monitor.service 2>/dev/null || true
    systemctl disable audio-rtsp.service 2>/dev/null || true
    systemctl disable mediamtx.service 2>/dev/null || true
    
    # Step 2: Kill any remaining processes
    log "INFO" "Cleaning up processes..."
    kill_process_safely "mediamtx-monitor" "$SCRIPT_NAME" "TERM" true 1
    kill_process_safely "startmic\\.sh" "$SCRIPT_NAME" "TERM" true 1
    kill_process_safely "ffmpeg.*rtsp" "$SCRIPT_NAME" "TERM" true 1
    kill_process_safely "/mediamtx$|/mediamtx " "$SCRIPT_NAME" "TERM" true 1
    
    # Step 3: Remove service files
    log "INFO" "Removing service files..."
    rm -f /etc/systemd/system/mediamtx-monitor.service
    rm -f /etc/systemd/system/audio-rtsp.service
    rm -f /etc/systemd/system/mediamtx.service
    systemctl daemon-reload
    
    # Step 4: Remove installed scripts
    log "INFO" "Removing scripts..."
    rm -f /usr/local/bin/startmic.sh
    rm -f /usr/local/bin/mediamtx-monitor.sh
    rm -f /usr/local/bin/check-audio-rtsp.sh
    rm -f /usr/local/bin/check-mediamtx-monitor.sh
    
    # Step 5: Ask if user wants to keep configuration and logs
    local keep_config=false
    local keep_logs=false
    
    if [ "$AUTO_YES" != true ]; then
        if ask_yes_no "Do you want to keep configuration files?" "y"; then
            keep_config=true
        fi
        
        if ask_yes_no "Do you want to keep log files?" "y"; then
            keep_logs=true
        fi
    fi
    
    # Step 6: Remove MediaMTX installation
    log "INFO" "Removing MediaMTX binary..."
    rm -rf /usr/local/mediamtx
    
    # Step 7: Remove configuration if requested
    if [ "$keep_config" != true ]; then
        log "INFO" "Removing configuration files..."
        rm -rf "$CONFIG_DIR"
        rm -rf /etc/mediamtx
    else
        log "INFO" "Keeping configuration files as requested"
    fi
    
    # Step 8: Remove logs if requested
    if [ "$keep_logs" != true ]; then
        log "INFO" "Removing log files..."
        rm -rf "$LOG_DIR"
        rm -rf /var/log/mediamtx
    else
        log "INFO" "Keeping log files as requested"
    fi
    
    # Step 9: Remove log rotation configuration
    log "INFO" "Removing log rotation configuration..."
    rm -f /etc/logrotate.d/audio-rtsp
    
    log "SUCCESS" "MediaMTX platform has been successfully uninstalled!"
    
    if [ "$QUIET_MODE" != true ]; then
        echo
        echo -e "${GREEN}==============================================${NC}"
        echo -e "${GREEN}   MediaMTX Platform uninstalled successfully!   ${NC}"
        echo -e "${GREEN}==============================================${NC}"
        echo
        if [ "$keep_config" = true ]; then
            echo -e "Configuration files have been preserved at: ${BLUE}$CONFIG_DIR${NC}"
        fi
        if [ "$keep_logs" = true ]; then
            echo -e "Log files have been preserved at: ${BLUE}$LOG_DIR${NC}"
        fi
        echo
    fi
    
    return 0
}

# Update MediaMTX platform
update_command() {
    log "INFO" "Starting MediaMTX platform update..."
    
    # Check if MediaMTX is installed
    if [ ! -f "/usr/local/mediamtx/mediamtx" ]; then
        log "ERROR" "MediaMTX doesn't appear to be installed"
        if ask_yes_no "Do you want to perform a fresh installation instead?" "y"; then
            install_command
            return $?
        else
            error "Update cancelled." 1
        fi
    fi
    
    # Get currently installed version
    local current_version
    current_version=$(/usr/local/mediamtx/mediamtx --version 2>&1 | head -n1 | grep -o "v[0-9]\+\.[0-9]\+\.[0-9]\+" || echo "unknown")
    
    log "INFO" "Current version: $current_version, Target version: $MEDIAMTX_VERSION"
    
    # Check if same version and not forcing update
    if [ "$current_version" = "$MEDIAMTX_VERSION" ] && [ "$FORCE_MODE" != true ]; then
        log "INFO" "MediaMTX is already at version $current_version"
        
        if ! ask_yes_no "Do you want to proceed with update anyway?" "n"; then
            log "INFO" "Update cancelled by user"
            error "Update cancelled. Use --force to override." 1
        fi
    fi
    
    # Initialize rollback for update
    init_rollback
    
    # Update MediaMTX using install_mediamtx.sh with --config-only option
    local mediamtx_args=(
        "-v" "$MEDIAMTX_VERSION"
        "-p" "$RTSP_PORT"
        "--rtmp-port" "$RTMP_PORT"
        "--hls-port" "$HLS_PORT" 
        "--webrtc-port" "$WEBRTC_PORT"
        "--metrics-port" "$METRICS_PORT"
        "--config-only"
    )
    
    if [ "$FORCE_MODE" = true ]; then
        mediamtx_args=("${mediamtx_args[@]:0:12}")  # Remove --config-only to force full reinstall
        mediamtx_args+=("--force-install")
    fi
    
    if [ "$DEBUG_MODE" = true ]; then
        mediamtx_args+=("--debug")
    fi
    
    # First create a backup of the existing configuration
    ensure_directory "$BACKUP_DIR"
    if [ -f "/etc/mediamtx/mediamtx.yml" ]; then
        log "INFO" "Backing up existing MediaMTX configuration"
        cp "/etc/mediamtx/mediamtx.yml" "${BACKUP_DIR}/mediamtx.yml.backup"
    fi
    
    # Execute the update
    log "INFO" "Updating MediaMTX..."
    if execute_component_script "install_mediamtx.sh" "${mediamtx_args[@]}"; then
        record_install_step "mediamtx-binary" "SUCCESS"
        record_install_step "mediamtx-service" "SUCCESS"
    else
        log "ERROR" "MediaMTX update failed"
        rollback_installation "MediaMTX update failed"
        error "Update failed during MediaMTX component. Check logs for details." 1
    fi
    
    # Restart services
    log "INFO" "Restarting services..."
    systemctl restart mediamtx.service
    systemctl restart audio-rtsp.service
    systemctl restart mediamtx-monitor.service
    
    # Print update summary
    log "SUCCESS" "MediaMTX platform has been successfully updated to version $MEDIAMTX_VERSION!"
    
    if [ "$QUIET_MODE" != true ]; then
        echo
        echo -e "${GREEN}==============================================${NC}"
        echo -e "${GREEN}   MediaMTX Platform updated successfully!   ${NC}"
        echo -e "${GREEN}==============================================${NC}"
        echo -e "Updated from version ${YELLOW}$current_version${NC} to ${GREEN}$MEDIAMTX_VERSION${NC}"
        echo
        echo -e "To check streaming status:"
        echo -e "  ${BLUE}sudo check-audio-rtsp.sh${NC}"
        echo
    fi
    
    return 0
}

# Reinstall MediaMTX platform
reinstall_command() {
    log "INFO" "Starting MediaMTX platform reinstallation..."
    
    # Confirm reinstallation
    if [ "$AUTO_YES" != true ]; then
        if ! ask_yes_no "This will completely remove and reinstall MediaMTX platform. Continue?" "n"; then
            log "INFO" "Reinstallation cancelled by user"
            error "Reinstallation cancelled." 1
        fi
    fi
    
    # First stop services
    log "INFO" "Stopping services before reinstall..."
    systemctl stop mediamtx-monitor.service 2>/dev/null || true
    systemctl stop audio-rtsp.service 2>/dev/null || true
    systemctl stop mediamtx.service 2>/dev/null || true
    
    log "INFO" "Services stopped successfully"
    
    # Add more debug output in debug mode
    if [ "$DEBUG_MODE" = true ]; then
        log "DEBUG" "Current process information:"
        log "DEBUG" "Script name: $SCRIPT_NAME"
        log "DEBUG" "PID: $$"
        log "DEBUG" "PPID: $PPID"
        log "DEBUG" "Process tree:"
        ps -ef | grep -E "$SCRIPT_NAME|mediamtx" | grep -v grep
    fi
    
    # Carefully clean up processes, making sure not to kill ourselves
    log "INFO" "Cleaning up processes..."
    
    # Use enhanced process management for process cleanup
    kill_process_safely "mediamtx-monitor" "$SCRIPT_NAME" "TERM" true 1
    kill_process_safely "startmic\\.sh" "$SCRIPT_NAME" "TERM" true 1
    kill_process_safely "ffmpeg.*rtsp" "$SCRIPT_NAME" "TERM" true 1
    kill_process_safely "/mediamtx$|/mediamtx " "$SCRIPT_NAME" "TERM" true 1
    
    # Add a short pause to ensure all processes have terminated
    sleep 2
    log "INFO" "Process cleanup completed"
    
    # Save current force mode state
    local old_force_mode=$FORCE_MODE
    
    # Set force mode for installation
    FORCE_MODE=true
    
    log "INFO" "Starting fresh installation with force mode..."
    
    # Run installation command
    install_command
    local install_result=$?
    
    # Restore original force mode
    FORCE_MODE=$old_force_mode
    
    if [ $install_result -eq 0 ]; then
        log "SUCCESS" "MediaMTX platform has been successfully reinstalled!"
    else
        error "Reinstallation failed with status $install_result. Check logs for details." $install_result
    fi
    
    return 0
}

# Show system status
status_command() {
    log "INFO" "Checking MediaMTX platform status..."
    
    if [ -x "/usr/local/bin/check-audio-rtsp.sh" ]; then
        /usr/local/bin/check-audio-rtsp.sh
    else
        # If status script doesn't exist, show basic status
        log "WARNING" "Status check script not found, showing basic status"
        echo -e "${YELLOW}MediaMTX Platform Status:${NC}"
        if systemctl is-active --quiet mediamtx.service; then
            echo -e "${GREEN}MediaMTX service is running${NC}"
        else
            echo -e "${RED}MediaMTX service is NOT running${NC}"
        fi
        
        if systemctl is-active --quiet audio-rtsp.service; then
            echo -e "${GREEN}Audio RTSP service is running${NC}"
        else
            echo -e "${RED}Audio RTSP service is NOT running${NC}"
        fi
        
        if systemctl is-active --quiet mediamtx-monitor.service; then
            echo -e "${GREEN}MediaMTX Monitor service is running${NC}"
        else
            echo -e "${RED}MediaMTX Monitor service is NOT running${NC}"
        fi
    fi
    
    return 0
}

# Run troubleshooting
troubleshoot_command() {
    log "INFO" "Running MediaMTX platform troubleshooting..."
    
    if [ -x "/usr/local/bin/check-mediamtx-monitor.sh" ]; then
        /usr/local/bin/check-mediamtx-monitor.sh
    else
        log "WARNING" "Monitor status script not found"
    fi
    
    # Perform some basic troubleshooting
    echo
    echo -e "${YELLOW}Troubleshooting MediaMTX Platform...${NC}"
    
    # Check if services are running
    echo -e "\n${YELLOW}Checking services status:${NC}"
    systemctl status mediamtx.service --no-pager -n 3
    systemctl status audio-rtsp.service --no-pager -n 3
    systemctl status mediamtx-monitor.service --no-pager -n 3
    
    # Check for ffmpeg processes
    echo -e "\n${YELLOW}Checking for active streams:${NC}"
    local STREAMS
    STREAMS=$(ps aux | grep "[f]fmpeg.*rtsp" | wc -l)
    if [ "$STREAMS" -gt 0 ]; then
        echo -e "${GREEN}Found $STREAMS active streaming processes${NC}"
    else
        echo -e "${RED}No active streaming processes found${NC}"
    fi
    
    # Check for available sound cards
    echo -e "\n${YELLOW}Checking available sound cards:${NC}"
    if [ -f "/proc/asound/cards" ]; then
        cat /proc/asound/cards
    else
        echo -e "${RED}Unable to access sound card information${NC}"
    fi
    
    # Check checksums directory
    echo -e "\n${YELLOW}Checking component script verification:${NC}"
    if [ -d "$CHECKSUMS_DIR" ]; then
        echo -e "${GREEN}Checksums directory exists at: $CHECKSUMS_DIR${NC}"
        echo -e "Stored checksums:"
        find "$CHECKSUMS_DIR" -type f -name "*.sha256" | while read -r checksum_file; do
            local script_name=$(basename "$checksum_file" .sha256)
            local stored_checksum=$(cat "$checksum_file" 2>/dev/null || echo "Not readable")
            echo -e "  - ${BLUE}$script_name${NC}: $stored_checksum"
        done
    else
        echo -e "${YELLOW}No checksums directory found - scripts will be verified on first use${NC}"
    fi
    
    # Offer to restart services
    echo
    if ask_yes_no "Would you like to restart all services?" "n"; then
        echo -e "${YELLOW}Restarting services...${NC}"
        systemctl restart mediamtx.service
        systemctl restart audio-rtsp.service
        systemctl restart mediamtx-monitor.service
        echo -e "${GREEN}Services restarted.${NC}"
    fi
    
    return 0
}

# View or manage logs
logs_command() {
    log "INFO" "Managing MediaMTX platform logs..."
    
    # Check if log directory exists
    if [ ! -d "$LOG_DIR" ]; then
        error "Log directory not found: $LOG_DIR" 1
    fi
    
    # Show available log files
    echo -e "${YELLOW}Available Log Files:${NC}"
    local log_files=()
    local i=1
    
    while IFS= read -r file; do
        log_files+=("$file")
        echo -e "$i. $(basename "$file")"
        i=$((i+1))
    done < <(find "$LOG_DIR" -type f -name "*.log" | sort)
    
    if [ ${#log_files[@]} -eq 0 ]; then
        error "No log files found in $LOG_DIR" 1
    fi
    
    # Let user select a log to view
    echo -n -e "${YELLOW}Enter log number to view [1-$((i-1))]: ${NC}"
    read -r log_choice
    
    if [[ "$log_choice" =~ ^[0-9]+$ ]] && [ "$log_choice" -ge 1 ] && [ "$log_choice" -le $((i-1)) ]; then
        local selected_log="${log_files[$((log_choice-1))]}"
        
        # View the log
        if command_exists less; then
            less "$selected_log"
        else
            # Fallback if less is not available
            cat "$selected_log" | more
        fi
    else
        error "Invalid choice" 1
    fi
    
    return 0
}

# ======================================================================
# Interactive Menu Functions
# ======================================================================

# Display interactive menu and handle user choice
interactive_menu() {
    display_banner
    
    log "INFO" "Starting interactive mode"
    
    local options=(
        "Install MediaMTX Platform"
        "Update MediaMTX Platform"
        "Reinstall MediaMTX Platform"
        "Uninstall MediaMTX Platform"
        "Check System Status"
        "Run Troubleshooting"
        "Manage Logs"
        "Exit"
    )
    
    show_menu "MediaMTX Platform Management" "${options[@]}"
    local result=$?
    
    case $result in
        0) 
            COMMAND="install"
            install_command 
            ;;
        1) 
            COMMAND="update"
            update_command 
            ;;
        2) 
            COMMAND="reinstall"
            reinstall_command 
            ;;
        3) 
            COMMAND="uninstall"
            uninstall_command 
            ;;
        4) 
            COMMAND="status"
            status_command 
            ;;
        5) 
            COMMAND="troubleshoot"
            troubleshoot_command 
            ;;
        6) 
            COMMAND="logs"
            logs_command 
            ;;
        7) 
            log "INFO" "Exiting"
            exit 0
            ;;
    esac
    
    # Return to menu after command completes
    press_enter_to_continue
    # Reset command to blank before showing menu again
    COMMAND=""
    interactive_menu
}

# ======================================================================
# Main Function
# ======================================================================

# Parse command line arguments
parse_arguments() {
    COMMAND=""
    
    # Check for options and command
    while [ $# -gt 0 ]; do
        case "$1" in
            -v|--version)
                if [ -n "$2" ] && [[ "$2" != -* ]]; then
                    MEDIAMTX_VERSION="$2"
                    shift
                else
                    error "Option --version requires an argument" 1
                fi
                ;;
            -p|--rtsp-port)
                if [ -n "$2" ] && [[ "$2" != -* ]]; then
                    RTSP_PORT="$2"
                    validate_port "$RTSP_PORT"
                    shift
                else
                    error "Option --rtsp-port requires an argument" 1
                fi
                ;;
            --rtmp-port)
                if [ -n "$2" ] && [[ "$2" != -* ]]; then
                    RTMP_PORT="$2"
                    validate_port "$RTMP_PORT"
                    shift
                else
                    error "Option --rtmp-port requires an argument" 1
                fi
                ;;
            --hls-port)
                if [ -n "$2" ] && [[ "$2" != -* ]]; then
                    HLS_PORT="$2"
                    validate_port "$HLS_PORT"
                    shift
                else
                    error "Option --hls-port requires an argument" 1
                fi
                ;;
            --webrtc-port)
                if [ -n "$2" ] && [[ "$2" != -* ]]; then
                    WEBRTC_PORT="$2"
                    validate_port "$WEBRTC_PORT"
                    shift
                else
                    error "Option --webrtc-port requires an argument" 1
                fi
                ;;
            --metrics-port)
                if [ -n "$2" ] && [[ "$2" != -* ]]; then
                    METRICS_PORT="$2"
                    validate_port "$METRICS_PORT"
                    shift
                else
                    error "Option --metrics-port requires an argument" 1
                fi
                ;;
            -d|--debug)
                DEBUG_MODE=true
                ;;
            -q|--quiet)
                QUIET_MODE=true
                ;;
            -y|--yes)
                AUTO_YES=true
                ;;
            -f|--force)
                FORCE_MODE=true
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            install|uninstall|update|reinstall|status|troubleshoot|logs)
                COMMAND="$1"
                ;;
            *)
                error "Unknown option: $1. Use --help for usage information." 1
                ;;
        esac
        shift
    done
}

# Set more robust trap for catching signals
trap 'log "WARNING" "Caught interrupt signal - PID: $$, PPID: $PPID, CMD: $0"; if [ "$COMMAND" != "reinstall" ]; then cleanup; fi; exit 1' INT
trap 'log "WARNING" "Caught termination signal - PID: $$, PPID: $PPID, CMD: $0"; if [ "$COMMAND" != "reinstall" ]; then cleanup; fi; exit 1' TERM
trap 'if [ "$COMMAND" != "reinstall" ]; then cleanup; fi' EXIT

# Main function
main() {
    # Display banner
    display_banner
    
    # Check if running as root
    check_root
    
    # Acquire lock to ensure only one instance is running
    acquire_lock
    
    # Set up trap for catching errors, but don't interfere with reinstall operation
    # Store command in a variable for later comparison
    CURRENT_COMMAND="$COMMAND"
    
    # Create temporary directory
    ensure_directory "$TEMP_DIR"
    
    # Check dependencies
    check_dependencies
    
    # Detect architecture
    detect_architecture
    
    # Run in interactive mode if no command specified
    if [ -z "$COMMAND" ]; then
        interactive_menu
        return 0
    fi
    
    # Check internet connectivity for commands that need it
    if [[ "$COMMAND" == "install" || "$COMMAND" == "update" || "$COMMAND" == "reinstall" ]]; then
        check_internet
    fi
    
    # Run the requested command
    case "$COMMAND" in
        install)
            install_command
            ;;
        uninstall)
            uninstall_command
            ;;
        update)
            update_command
            ;;
        reinstall)
            reinstall_command
            ;;
        status)
            status_command
            ;;
        troubleshoot)
            troubleshoot_command
            ;;
        logs)
            logs_command
            ;;
        *)
            error "No command specified. Use --help for usage information." 1
            ;;
    esac
    
    # Exit with success
    return 0
}

# Parse command line arguments
parse_arguments "$@"

# Run main function
main
