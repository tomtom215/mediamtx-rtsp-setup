#!/bin/bash
#
# MediaMTX Installer and RTSP Microphone Setup Script
#
# This script automates the installation of MediaMTX and sets up RTSP streams
# for attached USB sound cards with microphone inputs.
# It handles existing installations safely with backups and version checks.
#
# Usage: ./install_mediamtx.sh [options]
#
# Options:
#   --help, -h             Show this help message and exit
#   --version VERSION      Specify MediaMTX version to install (default: v1.11.3)
#   --no-upgrade           Skip system updates (useful for limited bandwidth)
#   --install-dir DIR      Custom installation directory (default: $HOME/mediamtx)
#   --skip-autostart       Don't set up crontab autostart entry
#
# Example:
#   ./install_mediamtx.sh --version v1.12.0 --install-dir /opt/mediamtx
#
# GitHub: [Your GitHub Repository URL]
# License: Apache 2.0

set -e                  # Exit on error
set -o pipefail         # Exit if any command in a pipe fails

# Default configuration
LOG_FILE="/tmp/mediamtx_install.log"
INSTALL_DIR="$HOME/mediamtx"
MEDIAMTX_VERSION="v1.11.3"  # Update this version as needed
DO_SYSTEM_UPGRADE=true
SETUP_AUTOSTART=true
OVERWRITE_EXISTING=false
UPGRADE_AVAILABLE=false
EXISTING_VERSION=""

# Process command line arguments
process_arguments() {
    while [[ $# -gt 0 ]]; do
        key="$1"
        case $key in
            --help|-h)
                show_help
                exit 0
                ;;
            --version)
                MEDIAMTX_VERSION="$2"
                shift 2
                ;;
            --no-upgrade)
                DO_SYSTEM_UPGRADE=false
                shift
                ;;
            --install-dir)
                INSTALL_DIR="$2"
                shift 2
                ;;
            --skip-autostart)
                SETUP_AUTOSTART=false
                shift
                ;;
            *)
                log "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done

    # Set dependent variables after processing arguments
    STARTMIC_SCRIPT="$INSTALL_DIR/startmic.sh"
    BACKUP_DIR="$INSTALL_DIR/backups/$(date +%Y%m%d%H%M%S)"
}

# Show help message
show_help() {
    cat << EOF
MediaMTX Installer and RTSP Microphone Setup Script

Usage: $0 [options]

Options:
  --help, -h             Show this help message and exit
  --version VERSION      Specify MediaMTX version to install (default: $MEDIAMTX_VERSION)
  --no-upgrade           Skip system updates (useful for limited bandwidth)
  --install-dir DIR      Custom installation directory (default: $INSTALL_DIR)
  --skip-autostart       Don't set up crontab autostart entry

Example:
  $0 --version v1.12.0 --install-dir /opt/mediamtx
EOF
}

# Function to log messages
log() {
    local message="$1"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
}

# Function to log errors and exit
error_exit() {
    log "ERROR: $1"
    exit 1
}

# Function to prompt for user confirmation
confirm() {
    local prompt="$1"
    local default="$2"
    
    while true; do
        read -p "$prompt [Y/n]: " choice
        choice=${choice:-$default}
        case "$choice" in
            [Yy]* ) return 0 ;;
            [Nn]* ) return 1 ;;
            * ) echo "Please answer yes or no." ;;
        esac
    done
}

# Function to detect CPU architecture and set download URL
detect_architecture() {
    local arch=$(uname -m)
    local mediamtx_arch=""
    
    case "$arch" in
        x86_64)
            mediamtx_arch="linux_amd64v3" ;;
        aarch64|arm64)
            mediamtx_arch="linux_arm64v8" ;;
        armv7l)
            mediamtx_arch="linux_armv7" ;;
        *)
            error_exit "Unsupported architecture: $arch" ;;
    esac
    
    log "Detected architecture: $arch, using MediaMTX architecture: $mediamtx_arch"
    DOWNLOAD_URL="https://github.com/bluenviron/mediamtx/releases/download/$MEDIAMTX_VERSION/mediamtx_${MEDIAMTX_VERSION}_${mediamtx_arch}.tar.gz"
}

# Function to check for existing installation and setup directories
setup_directories() {
    # Check if the path exists and determine if it's a directory
    if [ -e "$INSTALL_DIR" ]; then
        if [ -d "$INSTALL_DIR" ]; then
            log "Existing installation directory detected at $INSTALL_DIR"
            OVERWRITE_EXISTING=true
            
            # Check for the binary
            if [ -f "$INSTALL_DIR/mediamtx" ]; then
                log "Existing MediaMTX binary detected"
                
                # Try to detect existing version
                EXISTING_VERSION=$("$INSTALL_DIR/mediamtx" -version 2>/dev/null | grep -oP 'v\d+\.\d+\.\d+' || echo "unknown")
                if [ "$EXISTING_VERSION" != "unknown" ]; then
                    log "Existing MediaMTX version: $EXISTING_VERSION"
                    
                    # Compare versions (simple string comparison for vX.Y.Z format)
                    if [ "$EXISTING_VERSION" != "$MEDIAMTX_VERSION" ]; then
                        log "Different version detected. Current: $EXISTING_VERSION, New: $MEDIAMTX_VERSION"
                        UPGRADE_AVAILABLE=true
                    else
                        log "Same version already installed. Will skip MediaMTX binary update."
                    fi
                else
                    log "Could not determine existing MediaMTX version"
                    UPGRADE_AVAILABLE=true
                fi
            fi
            
            # Check for existing startmic.sh
            if [ -f "$STARTMIC_SCRIPT" ]; then
                log "Existing startmic.sh script detected"
            fi
            
            # Ask user for confirmation before proceeding
            if ! confirm "Existing MediaMTX installation found. Proceed with update/verification?" "Y"; then
                log "Update cancelled by user"
                exit 0
            fi
            
            # Create backup directory
            mkdir -p "$BACKUP_DIR" || error_exit "Failed to create backup directory"
            log "Created backup directory at $BACKUP_DIR"
            
            # Backup existing files
            if [ -f "$INSTALL_DIR/mediamtx" ]; then
                cp "$INSTALL_DIR/mediamtx" "$BACKUP_DIR/" || log "Warning: Failed to backup mediamtx binary"
            fi
            
            if [ -f "$STARTMIC_SCRIPT" ]; then
                cp "$STARTMIC_SCRIPT" "$BACKUP_DIR/" || log "Warning: Failed to backup startmic.sh script"
            fi
            
            if [ -f "$INSTALL_DIR/mediamtx.yml" ]; then
                cp "$INSTALL_DIR/mediamtx.yml" "$BACKUP_DIR/" || log "Warning: Failed to backup mediamtx.yml"
            fi
            
            log "Backed up existing files to $BACKUP_DIR"
        else
            # Path exists but is not a directory
            log "Path $INSTALL_DIR exists but is not a directory"
            if confirm "Remove existing file and create directory at $INSTALL_DIR?" "Y"; then
                rm -f "$INSTALL_DIR" || error_exit "Failed to remove existing file at $INSTALL_DIR"
                mkdir -p "$INSTALL_DIR" || error_exit "Failed to create installation directory"
                log "Created installation directory at $INSTALL_DIR"
            else
                error_exit "Installation cancelled - cannot proceed without a valid installation directory"
            fi
        fi
    else
        log "No existing MediaMTX installation detected"
        # Create the directory
        mkdir -p "$INSTALL_DIR" || error_exit "Failed to create installation directory"
        log "Created installation directory at $INSTALL_DIR"
    fi
    
    # Change to installation directory
    cd "$INSTALL_DIR" || error_exit "Failed to change to installation directory"
}

# Function to update system and install dependencies
update_system() {
    log "Installing required dependencies..."
    
    # Detect package manager
    if command -v apt &> /dev/null; then
        PKG_MANAGER="apt"
    elif command -v yum &> /dev/null; then
        PKG_MANAGER="yum"
    elif command -v dnf &> /dev/null; then
        PKG_MANAGER="dnf"
    elif command -v pacman &> /dev/null; then
        PKG_MANAGER="pacman"
    else
        log "Warning: Unable to detect package manager. You may need to install dependencies manually."
        log "Required packages: ffmpeg, alsa-utils"
        if confirm "Continue without automatic dependency installation?" "Y"; then
            return 0
        else
            error_exit "Cannot proceed without installing dependencies"
        fi
    fi
    
    # Update and install packages based on detected manager
    case $PKG_MANAGER in
        apt)
            if [ "$DO_SYSTEM_UPGRADE" = true ]; then
                log "Updating system packages with apt..."
                sudo apt update || error_exit "Failed to update package lists"
                sudo apt upgrade -y || error_exit "Failed to upgrade packages"
            fi
            sudo apt install -y ffmpeg alsa-utils || error_exit "Failed to install required packages"
            ;;
        yum)
            if [ "$DO_SYSTEM_UPGRADE" = true ]; then
                log "Updating system packages with yum..."
                sudo yum update -y || error_exit "Failed to update packages"
            fi
            sudo yum install -y ffmpeg alsa-utils || error_exit "Failed to install required packages"
            ;;
        dnf)
            if [ "$DO_SYSTEM_UPGRADE" = true ]; then
                log "Updating system packages with dnf..."
                sudo dnf update -y || error_exit "Failed to update packages"
            fi
            sudo dnf install -y ffmpeg alsa-utils || error_exit "Failed to install required packages"
            ;;
        pacman)
            if [ "$DO_SYSTEM_UPGRADE" = true ]; then
                log "Updating system packages with pacman..."
                sudo pacman -Syu --noconfirm || error_exit "Failed to update packages"
            fi
            sudo pacman -S --needed --noconfirm ffmpeg alsa-utils || error_exit "Failed to install required packages"
            ;;
    esac
    
    log "Dependencies installed successfully"
}

# Function to download and extract MediaMTX
download_mediamtx() {
    # Skip download if same version already installed
    if [ "$OVERWRITE_EXISTING" = true ] && [ "$UPGRADE_AVAILABLE" = false ]; then
        log "Skipping MediaMTX download as the same version is already installed"
        return 0
    fi
    
    log "Downloading MediaMTX from $DOWNLOAD_URL"
    wget -c "$DOWNLOAD_URL" -O - | tar -xz -C "$INSTALL_DIR" || error_exit "Failed to download or extract MediaMTX"
    log "MediaMTX downloaded and extracted successfully"
}

# Function to detect sound cards
detect_sound_cards() {
    log "Detecting sound cards..."
    if ! command -v arecord &> /dev/null; then
        error_exit "arecord command not found. Please install alsa-utils package."
    fi
    
    # Get list of sound cards with capture capability
    SOUND_CARDS=$(arecord -l | grep -i 'card' | awk '{print $2":"$3}' | sed 's/://' | sed 's/[,:]//g')
    
    if [ -z "$SOUND_CARDS" ]; then
        log "Warning: No sound cards with capture capability detected"
        return 1
    else
        log "Detected sound cards: $SOUND_CARDS"
        return 0
    fi
}

# Function to parse existing startmic.sh script to extract custom configurations
parse_existing_script() {
    if [ ! -f "$STARTMIC_SCRIPT" ]; then
        return 0
    fi
    
    log "Analyzing existing startmic.sh script for custom configurations..."
    
    # Extract custom ffmpeg commands
    CUSTOM_COMMANDS=$(grep -E "^ffmpeg.*rtsp://localhost:8554/" "$STARTMIC_SCRIPT" || echo "")
    
    # Store the number of custom streams
    NUM_CUSTOM_STREAMS=$(echo "$CUSTOM_COMMANDS" | wc -l)
    
    if [ -n "$CUSTOM_COMMANDS" ]; then
        log "Found $NUM_CUSTOM_STREAMS custom stream configuration(s) in existing script"
        return 0
    else
        log "No custom stream configurations found in existing script"
        return 1
    fi
}

# Function to create the startmic.sh script
create_startmic_script() {
    local use_existing_config=false
    local existing_script_backup=""
    
    # If startmic.sh already exists, check if we should preserve configurations
    if [ -f "$STARTMIC_SCRIPT" ]; then
        existing_script_backup="$BACKUP_DIR/startmic.sh"
        
        # Attempt to parse existing script for custom configurations
        if parse_existing_script; then
            if confirm "Preserve existing stream configurations?" "Y"; then
                use_existing_config=true
                log "Will preserve existing stream configurations"
            else
                log "Will create new stream configurations based on currently detected sound cards"
            fi
        fi
    fi
    
    log "Creating startmic.sh script..."
    
    # Create the script header
    cat > "$STARTMIC_SCRIPT" << EOF
#!/bin/bash

# MediaMTX RTSP audio streaming script
# Generated/Updated on: $(date)
# Installation path: $INSTALL_DIR

cd "\$(dirname "\$0")" || exit 1

# Start MediaMTX server
./mediamtx &
MEDIAMTX_PID=\$!
echo "Started MediaMTX with PID \$MEDIAMTX_PID"

# Allow MediaMTX time to start properly
sleep 3

# Function to handle script termination
cleanup() {
    echo "Stopping all ffmpeg processes..."
    pkill -f ffmpeg
    echo "Stopping MediaMTX..."
    kill \$MEDIAMTX_PID
    exit 0
}

# Register the cleanup function for script termination
trap cleanup SIGINT SIGTERM

EOF
    
    # Add ffmpeg commands based on user choice
    if [ "$use_existing_config" = true ] && [ -n "$CUSTOM_COMMANDS" ]; then
        # Use the existing custom configurations
        log "Using existing stream configurations"
        echo "$CUSTOM_COMMANDS" >> "$STARTMIC_SCRIPT"
        has_cards=true
    else
        # Create new ffmpeg commands for each detected sound card
        local card_number=0
        has_cards=false
        
        # Create an array of card names from the output of arecord -l
        mapfile -t CARD_INFO < <(arecord -l | grep -i 'card' | sed 's/[,:]//g')
        
        for card_info in "${CARD_INFO[@]}"; do
            # Extract card number and name from the line
            CARD_NUM=$(echo "$card_info" | awk '{print $2}')
            CARD_NAME=$(echo "$card_info" | awk '{$1=$2=$3=$4=""; print $0}' | xargs)
            
            # Sanitize card name for use in RTSP path
            SAFE_CARD_NAME=$(echo "$CARD_NAME" | tr -dc '[:alnum:]' | tr '[:upper:]' '[:lower:]')
            
            # Increment stream counter
            ((card_number++))
            has_cards=true
            
            cat >> "$STARTMIC_SCRIPT" << EOF
# Start stream for sound card $CARD_NUM ($CARD_NAME)
echo "Starting stream for sound card $CARD_NUM ($CARD_NAME) - rtsp://localhost:8554/mic$card_number"
ffmpeg -nostdin -f alsa -ac 1 -i plughw:$CARD_NUM,0 -acodec libmp3lame -b:a 160k -ac 2 -content_type 'audio/mpeg' -f rtsp rtsp://localhost:8554/mic$card_number -rtsp_transport tcp &

EOF
        done
        
        if [ "$has_cards" = false ]; then
            log "Warning: No sound cards detected. Creating a placeholder entry in the script."
            cat >> "$STARTMIC_SCRIPT" << EOF
# No sound cards were detected during installation
# Replace the line below with your actual sound card when available
# ffmpeg -nostdin -f alsa -ac 1 -i plughw:CARD=yourcard,DEV=0 -acodec libmp3lame -b:a 160k -ac 2 -content_type 'audio/mpeg' -f rtsp rtsp://localhost:8554/mic1 -rtsp_transport tcp &
echo "No sound cards detected. Please edit this script when you connect a microphone."
EOF
        fi
    fi
    
    # Add wait command to keep the script running
    cat >> "$STARTMIC_SCRIPT" << EOF

# Wait for all background processes
wait
EOF
    
    # Make the script executable
    chmod +x "$STARTMIC_SCRIPT" || error_exit "Failed to make startmic.sh executable"
    log "startmic.sh script created successfully"
    
    # Notify user about backup if we overwrote an existing script
    if [ -f "$existing_script_backup" ]; then
        log "Your original startmic.sh script has been backed up to $existing_script_backup"
    fi
}

# Function to set up autostart
setup_autostart() {
    if [ "$SETUP_AUTOSTART" = false ]; then
        log "Skipping autostart setup as requested"
        return 0
    fi
    
    log "Setting up autostart..."
    
    # Detect init system
    if command -v systemctl &> /dev/null; then
        # Setup using systemd
        log "Setting up autostart using systemd..."
        
        # Create systemd service file
        SYSTEMD_SERVICE_PATH="/etc/systemd/system/mediamtx.service"
        
        # Ask user for confirmation before creating systemd service
        if confirm "Create systemd service for autostart?" "Y"; then
            cat << EOF | sudo tee "$SYSTEMD_SERVICE_PATH" > /dev/null
[Unit]
Description=MediaMTX RTSP Server
After=network.target

[Service]
Type=simple
User=$(whoami)
ExecStart=$STARTMIC_SCRIPT
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
            
            # Enable and start the service
            sudo systemctl daemon-reload
            sudo systemctl enable mediamtx.service || log "Warning: Failed to enable systemd service"
            
            log "Systemd service created at $SYSTEMD_SERVICE_PATH"
            log "Service will start on next boot. To start now, run: sudo systemctl start mediamtx"
            return 0
        fi
    fi
    
    # Fall back to crontab if systemd not available or user declined
    log "Setting up autostart using crontab..."
    
    # Check if entry already exists
    if crontab -l 2>/dev/null | grep -q "$STARTMIC_SCRIPT"; then
        log "Autostart entry already exists in crontab"
    else
        # Add new crontab entry
        (crontab -l 2>/dev/null; echo "@reboot $STARTMIC_SCRIPT") | crontab - || error_exit "Failed to update crontab"
        log "Autostart entry added to crontab"
    fi
}

# Function to display information about available streams
display_stream_info() {
    local ip_address=$(hostname -I | awk '{print $1}')
    
    log "=============================================="
    log "MediaMTX Installation/Update Complete!"
    log "=============================================="
    
    if [ "$OVERWRITE_EXISTING" = true ]; then
        if [ "$UPGRADE_AVAILABLE" = true ]; then
            log "MediaMTX has been updated from $EXISTING_VERSION to $MEDIAMTX_VERSION"
        else
            log "MediaMTX version $MEDIAMTX_VERSION is already installed and up-to-date"
        fi
        
        if [ -d "$BACKUP_DIR" ]; then
            log "Backup of previous installation created at: $BACKUP_DIR"
        fi
    else
        log "MediaMTX version $MEDIAMTX_VERSION has been installed"
    fi
    
    log "RTSP streams will be available at:"
    
    # If we're using existing configuration or sound cards were detected
    if [ "$use_existing_config" = true ] || [ "$has_cards" = true ]; then
        if [ "$use_existing_config" = true ] && [ -n "$CUSTOM_COMMANDS" ]; then
            # Extract stream paths from the custom commands
            local streams=$(echo "$CUSTOM_COMMANDS" | grep -oE "rtsp://localhost:8554/[^ ]+" | sed "s/localhost/$ip_address/g")
            echo "$streams" | while read -r stream; do
                log "  - $stream"
            done
        else
            # List newly configured streams
            card_number=0
            for card_info in "${CARD_INFO[@]}"; do
                ((card_number++))
                CARD_NAME=$(echo "$card_info" | awk '{$1=$2=$3=$4=""; print $0}' | xargs)
                log "  - rtsp://$ip_address:8554/mic$card_number ($CARD_NAME)"
            done
        fi
    else
        log "  - No sound cards detected during installation"
        log "  - When you connect a microphone, edit $STARTMIC_SCRIPT"
        log "  - Streams will be available at rtsp://$ip_address:8554/mic1, etc."
    fi
    
    log "To stream manually, run: $STARTMIC_SCRIPT"
    log "The streams will start automatically on next reboot"
    log "To test, use VLC on another computer: rtsp://$ip_address:8554/mic1"
    log "=============================================="
}

# Check for root/sudo without being root
check_permissions() {
    # Check if script is being run as root (not recommended)
    if [ "$(id -u)" -eq 0 ]; then
        log "Warning: This script is running as root, which is not recommended."
        log "It's better to run as a regular user with sudo privileges."
        if ! confirm "Continue running as root?" "N"; then
            error_exit "Please run this script as a non-root user with sudo access"
        fi
    else
        # Check if user has sudo privileges
        if ! sudo -v &> /dev/null; then
            error_exit "This script requires sudo privileges. Please run with a user that has sudo access."
        fi
    fi
}

# Create an uninstall script
create_uninstall_script() {
    local UNINSTALL_SCRIPT="$INSTALL_DIR/uninstall_mediamtx.sh"
    
    log "Creating uninstall script at $UNINSTALL_SCRIPT..."
    
    cat > "$UNINSTALL_SCRIPT" << EOF
#!/bin/bash
#
# MediaMTX Uninstaller Script
# Created by MediaMTX Installer on $(date)
#

echo "MediaMTX Uninstaller"
echo "===================="

# Variables
INSTALL_DIR="$INSTALL_DIR"
SYSTEMD_SERVICE="mediamtx.service"

# Check if running with sudo/root
if [ "\$(id -u)" -ne 0 ]; then
    echo "This uninstaller should be run with sudo."
    echo "Please run: sudo $UNINSTALL_SCRIPT"
    exit 1
fi

# Confirm uninstallation
read -p "Are you sure you want to uninstall MediaMTX? [y/N]: " confirm
if [[ ! \$confirm =~ ^[Yy] ]]; then
    echo "Uninstallation cancelled."
    exit 0
fi

# Stop any running processes
echo "Stopping MediaMTX services..."
pkill -f mediamtx || true
pkill -f ffmpeg || true

# Remove systemd service if exists
if [ -f "/etc/systemd/system/\$SYSTEMD_SERVICE" ]; then
    echo "Removing systemd service..."
    systemctl stop \$SYSTEMD_SERVICE
    systemctl disable \$SYSTEMD_SERVICE
    rm -f "/etc/systemd/system/\$SYSTEMD_SERVICE"
    systemctl daemon-reload
fi

# Remove crontab entry
echo "Removing crontab entry..."
(crontab -l 2>/dev/null | grep -v "$STARTMIC_SCRIPT") | crontab -

# Ask if user wants to keep configuration files
read -p "Do you want to keep configuration files? [Y/n]: " keep_config
if [[ \$keep_config =~ ^[Nn] ]]; then
    echo "Removing all MediaMTX files..."
    rm -rf "\$INSTALL_DIR"
else
    echo "Keeping configuration files but removing binaries..."
    rm -f "\$INSTALL_DIR/mediamtx"
fi

echo "MediaMTX has been uninstalled."
exit 0
EOF

    # Make the script executable
    chmod +x "$UNINSTALL_SCRIPT"
    log "Uninstall script created successfully"
}

# Main script execution
main() {
    log "Starting MediaMTX installation and RTSP microphone setup..."
    
    # Process command line arguments
    process_arguments "$@"
    
    # Check for root/sudo
    check_permissions
    
    # Step 1: Check for existing installation and setup directories
    setup_directories
    
    # Step 2: Update system and install dependencies
    update_system
    
    # Step 3: Detect architecture and set download URL
    detect_architecture
    
    # Step 4: Download and extract MediaMTX
    download_mediamtx
    
    # Step 5: Detect sound cards
    detect_sound_cards
    has_cards=$?
    
    # Step 6: Create startmic.sh script
    create_startmic_script
    
    # Step 7: Set up autostart
    setup_autostart
    
    # Step 8: Create uninstall script
    create_uninstall_script
    
    # Step 9: Display information
    display_stream_info
    
    log "Installation/update completed successfully"
}

# Execute main function
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
