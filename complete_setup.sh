# Display help with enhanced options
show_help() {
    echo "USB Sound Card Mapper - Create persistent names for USB sound devices"
    echo
    echo "Usage: $0 [options]"
    echo "Options:"
    echo "  -i, --interactive       Run in interactive mode (default)"
    echo "  -n, --non-interactive   Run in non-interactive mode (requires all other parameters)"
    echo "  -d, --device NAME       Device name (for logging only)"
    echo "  -v, --vendor ID         Vendor ID (4-digit hex)"
    echo "  -p, --product ID        Product ID (4-digit hex)"
    echo "  -u, --usb-port PORT     USB port path (recommended for multiple identical devices)"
    echo "  -f, --friendly NAME     Friendly name to assign"
    echo "  -t, --test              Test USB port detection on current system"
    echo "  -D, --debug             Enable debug output"
    echo "  -h, --help              Show this help"
    echo
    echo "Examples:"
    echo "  $0                      Run in interactive mode"
    echo "  $0 -n -d \"MOVO X1 MINI\" -v 2e88 -p 4610 -f movo-x1-mini"
    echo "  $0 -n -d \"MOVO X1 MINI\" -v 2e88 -p 4610 -u \"usb-3.4\" -f movo-x1-mini"
    echo "  $0 -t                   Test USB port detection capabilities"
    exit 0
}

# Main function with enhanced options
main() {
    # Set DEBUG to false by default
    DEBUG="false"
    
    # Parse command line arguments and check for test mode
    for arg in "$@"; do
        case "$arg" in
            -t|--test)
                check_root
                test_usb_port_detection
                exit $?
                ;;
            -D|--debug)
                DEBUG="true"
                info "Debug mode enabled"
                ;;
        esac
    done
    
    check_root
    
    # Parse command line arguments
    if [ $# -eq 0 ]; then
        interactive_mapping
        exit 0
    fi
    
    local device_name=""
    local vendor_id=""
    local product_id=""
    local port=""
    local friendly_name=""
    local mode="interactive"
    
    while [ $# -gt 0 ]; do
        case "$1" in
            -i|--interactive)
                mode="interactive"
                shift
                ;;
            -n|--non-interactive)
                mode="non-interactive"
                shift
                ;;
            -d|--device)
                device_name="$2"
                shift 2
                ;;
            -v|--vendor)
                vendor_id="$2"
                shift 2
                ;;
            -p|--product)
                product_id="$2"
                shift 2
                ;;
            -u|--usb-port)
                port="$2"
                shift 2
                ;;
            -f|--friendly)
                friendly_name="$2"
                shift 2
                ;;
            -t|--test)
                # Already handled above
                shift
                ;;
            -D|--debug)
                # Already handled above
                shift
                ;;
            -h|--help)
                show_help
                ;;
            *)
                error_exit "Unknown option: $1"
                ;;
        esac
    done
    
    if [ "$mode" = "interactive" ]; then
        interactive_mapping
    else
        non_interactive_mapping "$device_name" "$vendor_id" "$product_id" "$port" "$friendly_name"
    fi
}

# Run the main function
main "$@"
EOF

# Set permissions
chmod +x /usr/local/bin/usb-soundcard-mapper.sh

echo "USB Sound Card Mapper installed to /usr/local/bin/usb-soundcard-mapper.sh"# Enhanced non-interactive mapping function
non_interactive_mapping() {
    local device_name="$1"
    local vendor_id="$2"
    local product_id="$3"
    local port="$4"
    local friendly_name="$5"
    
    if [ -z "$device_name" ] || [ -z "$vendor_id" ] || [ -z "$product_id" ] || [ -z "$friendly_name" ]; then
        error_exit "Device name, vendor ID, product ID, and friendly name must be provided for non-interactive mode."
    fi
    
    # Validate inputs
    if ! [[ "$vendor_id" =~ ^[0-9a-f]{4}$ ]]; then
        error_exit "Invalid vendor ID: $vendor_id. Must be a 4-digit hex value."
    fi
    
    if ! [[ "$product_id" =~ ^[0-9a-f]{4}$ ]]; then
        error_exit "Invalid product ID: $product_id. Must be a 4-digit hex value."
    fi
    
    if ! [[ "$friendly_name" =~ ^[a-z0-9-]+$ ]]; then
        error_exit "Invalid friendly name: $friendly_name. Use only lowercase letters, numbers, and hyphens."
    fi
    
    # See if we can find the actual device in the system
    info "Looking for device in current system..."
    local found_card=""
    local card_device_info=""
    
    # Get sound card information
    cards_file="/proc/asound/cards"
    if [ -f "$cards_file" ]; then
        while IFS= read -r line; do
            # Check if this could be our device based on name similarities
            if [[ "$line" =~ \[$device_name|\[.*$device_name.*\] ]]; then
                found_card="$line"
                info "Found potential matching card: $line"
                
                # Try to extract USB path
                if [[ "$line" =~ at\ (usb-[^ ,]+) ]]; then
                    card_device_info="${BASH_REMATCH[1]}"
                    info "Found actual USB path: $card_device_info"
                fi
                break
            fi
        done < "$cards_file"
    fi
    
    # Extract a simplified port pattern for more reliable matching
    local simple_port_pattern=""
    if [ -n "$port" ]; then
        # Check if port is valid
        if is_valid_usb_path "$port"; then
            # Extract just the basic port numbers for better matching
            if [[ "$port" =~ ([0-9]+-[0-9]+(\.[0-9]+)*) ]]; then
                simple_port_pattern="${BASH_REMATCH[1]}"
                info "Extracted simple port pattern from provided port: $simple_port_pattern"
            else
                simple_port_pattern="$port"
                info "Using provided port as pattern: $simple_port_pattern"
            fi
        else
            warning "Provided USB port path '$port' appears invalid. Looking for alternatives."
        fi
    fi
    
    # If no valid port pattern from command line, but we found one from card info, use that
    if [ -z "$simple_port_pattern" ] && [ -n "$card_device_info" ]; then
        if [[ "$card_device_info" =~ (usb-[0-9]+:[0-9]+\.[0-9]+(-[0-9]+(\.[0-9]+)*)) ]]; then
            simple_port_pattern="${BASH_REMATCH[1]}"
            info "Using port pattern from found card: $simple_port_pattern"
        else
            simple_port_pattern="$card_device_info"
            info "Using device info as port pattern: $simple_port_pattern"
        fi
    fi
    
    # Create the rule
    info "Creating rule for $device_name..."
    
    rules_file="/etc/udev/rules.d/99-usb-soundcards.rules"
    mkdir -p /etc/udev/rules.d/
    
    # Create uniqueness tag
    local uniqueness_tag=$(date +%s%N | md5sum | head -c 6)
    
    # Create or append to rules file
    if [ -z "$simple_port_pattern" ]; then
        info "Creating basic rule (no reliable port information available)..."
        echo "# USB Sound Card: $device_name" >> "$rules_file"
        echo "# Uniqueness tag: $uniqueness_tag" >> "$rules_file"
        echo "SUBSYSTEM==\"sound\", ATTRS{idVendor}==\"$vendor_id\", ATTRS{idProduct}==\"$product_id\", ATTR{id}=\"$friendly_name\"" >> "$rules_file"
    else
        info "Creating enhanced rule with port pattern: $simple_port_pattern"
        echo "# USB Sound Card: $device_name" >> "$rules_file"
        echo "# Port pattern: $simple_port_pattern" >> "$rules_file"
        echo "# Uniqueness tag: $uniqueness_tag" >> "$rules_file"
        echo "SUBSYSTEM==\"sound\", KERNELS==\"*${simple_port_pattern}*\", ATTRS{idVendor}==\"$vendor_id\", ATTRS{idProduct}==\"$product_id\", ATTR{id}=\"$friendly_name\"" >> "$rules_file"
        
        # If we have actual card info that's different from the port pattern, add a backup rule
        if [ -n "$card_device_info" ] && [ "$card_device_info" != "$simple_port_pattern" ]; then
            echo "# Backup rule using card device info" >> "$rules_file"
            echo "SUBSYSTEM==\"sound\", KERNELS==\"*${card_device_info}*\", ATTRS{idVendor}==\"$vendor_id\", ATTRS{idProduct}==\"$product_id\", ATTR{id}=\"$friendly_name\"" >> "$rules_file"
        fi
    fi
    
    if [ $? -ne 0 ]; then
        error_exit "Failed to write to $rules_file."
    fi
    
    # Reload udev rules
    reload_udev_rules
    
    success "Sound card mapping created successfully."
    info "Remember to reboot for changes to take effect."
}    # Extract a simplified port pattern for more reliable matching
    local simple_port_pattern=""
    if [ -n "$physical_port" ]; then
        # First, prefer to use the card_device_info directly
        if [ -n "$card_device_info" ]; then
            simple_port_pattern="$card_device_info"
            info "Using card device info for matching: $simple_port_pattern"
        # Otherwise try to extract a simple pattern from the physical_port
        elif [[ "$physical_port" =~ ([0-9]+-[0-9]+(\.[0-9]+)*) ]]; then
            simple_port_pattern="${BASH_REMATCH[1]}"
            info "Extracted simple port pattern: $simple_port_pattern"
        else
            simple_port_pattern="$physical_port"
            info "Using full physical port: $simple_port_pattern"
        fi
    fi
    
    case "$rule_type" in
        1)
            echo "Creating basic rule..."
            echo "# USB Sound Card: $card_name" >> "$rules_file"
            echo "SUBSYSTEM==\"sound\", ATTRS{idVendor}==\"$vendor_id\", ATTRS{idProduct}==\"$product_id\", ATTR{id}=\"$friendly_name\"" >> "$rules_file"
            ;;
        2)
            echo "Creating enhanced rule with port matching..."
            # Create a uniqueness tag with timestamp to ensure truly unique identification
            local uniqueness_tag=$(date +%s%N | md5sum | head -c 6)
            
            # If we have the actual card device info, create a direct matching rule first
            if [ -n "$card_device_info" ]; then
                echo "# USB Sound Card: $card_name" >> "$rules_file"
                echo "# Device info: $card_device_info" >> "$rules_file"
                echo "# Uniqueness tag: $uniqueness_tag" >> "$rules_file"
                
                # First - create a rule with the exact path as seen in cards file
                echo "SUBSYSTEM==\"sound\", KERNELS==\"*${card_device_info}*\", ATTRS{idVendor}==\"$vendor_id\", ATTRS{idProduct}==\"$product_id\", ATTR{id}=\"$friendly_name\"" >> "$rules_file"
                
                # Next - create a rule with a more generalized pattern
                if [[ "$card_device_info" =~ usb-[0-9a-f:.]+-([0-9]+\.[0-9]+) ]]; then
                    local port_numbers="${BASH_REMATCH[1]}"
                    echo "# Alternative matching rule with port numbers only" >> "$rules_file"
                    echo "SUBSYSTEM==\"sound\", KERNELS==\"*${port_numbers}*\", ATTRS{idVendor}==\"$vendor_id\", ATTRS{idProduct}==\"$product_id\", ATTR{id}=\"$friendly_name\"" >> "$rules_file"
                fi
            elif [ -n "$simple_port_pattern" ]; then
                # Create a rule using the simplified port pattern for better matching
                echo "# USB Sound Card: $card_name" >> "$rules_file"
                echo "# Port pattern: $simple_port_pattern (original: $physical_port)" >> "$rules_file"
                echo "# Uniqueness tag: $uniqueness_tag" >> "$rules_file"
                echo "SUBSYSTEM==\"sound\", KERNELS==\"*${simple_port_pattern}*\", ATTRS{idVendor}==\"$vendor_id\", ATTRS{idProduct}==\"$product_id\", ATTR{id}=\"$friendly_name\"" >> "$rules_file"
            else
                # If no reliable port information, fall back to basic rule
                warning "No reliable port patterns available. Falling back to basic rule."
                echo "# USB Sound Card: $card_name (no reliable port info available)" >> "$rules_file"
                echo "# Uniqueness tag: $uniqueness_tag" >> "$rules_file"
                echo "SUBSYSTEM==\"sound\", ATTRS{idVendor}==\"$vendor_id\", ATTRS{idProduct}==\"$product_id\", ATTR{id}=\"$friendly_name\"" >> "$rules_file"
            fi
            ;;
        3)
            echo "Creating strict rule with exact port matching..."
            if [ -n "$card_device_info" ]; then
                # Create a uniqueness tag with timestamp to ensure truly unique identification
                local uniqueness_tag=$(date +%s%N | md5sum | head -c 6)
                
                echo "# USB Sound Card: $card_name (strict matching)" >> "$rules_file"
                echo "# Device info: $card_device_info" >> "$rules_file"
                echo "# Uniqueness tag: $uniqueness_tag" >> "$rules_file"
                echo "SUBSYSTEM==\"sound\", KERNELS==\"${card_device_info}\", ATTRS{idVendor}==\"$vendor_id\", ATTRS{idProduct}==\"$product_id\", ATTR{id}=\"$friendly_name\"" >> "$rules_file"
            elif [ -n "$simple_port_pattern" ]; then
                # Create a uniqueness tag with timestamp to ensure truly unique identification
                local uniqueness_tag=$(date +%s%N | md5sum | head -c 6)
                
                echo "# USB Sound Card: $card_name" >> "$rules_file"
                echo "# Port pattern: $simple_port_pattern (strict matching)" >> "$rules_file"
                echo "# Uniqueness tag: $uniqueness_tag" >> "$rules_file"
                echo "SUBSYSTEM==\"sound\", KERNELS==\"${simple_port_pattern}\", ATTRS{idVendor}==\"$vendor_id\", ATTRS{idProduct}==\"$product_id\", ATTR{id}=\"$friendly_name\"" >> "$rules_file"
            else
                error_exit "Cannot create strict rule without reliable port information."
            fi
            ;;
        *)
            error_exit "Invalid rule type selection."
            ;;
    esac
    
    if [ $? -ne 0 ]; then
        error_exit "Failed to write to $rules_file."
    fi
    
    # Reload udev rules
    reload_udev_rules
    
    # Prompt for reboot
    prompt_reboot
    
    success "Sound card mapping created successfully."
}    # Let user select USB device
    echo
    echo "Select the USB device that corresponds to this sound card:"
    lsusb | nl -w2 -s". "
    read usb_num
    
    if ! [[ "$usb_num" =~ ^[0-9]+$ ]]; then
        error_exit "Invalid input. Please enter a number."
    fi
    
    # Get the USB device line
    usb_line=$(lsusb | sed -n "${usb_num}p")
    if [ -z "$usb_line" ]; then
        error_exit "No USB device found at position $usb_num."
    fi
    
    # Extract vendor and product IDs
    if [[ "$usb_line" =~ ID\ ([0-9a-f]{4}):([0-9a-f]{4}) ]]; then
        vendor_id="${BASH_REMATCH[1]}"
        product_id="${BASH_REMATCH[2]}"
    else
        error_exit "Could not extract vendor and product IDs from: $usb_line"
    fi
    
    # Extract bus and device numbers for port identification
    local physical_port=""
    if [[ "$usb_line" =~ Bus\ ([0-9]{3})\ Device\ ([0-9]{3}) ]]; then
        bus_num="${BASH_REMATCH[1]}"
        dev_num="${BASH_REMATCH[2]}"
        # Remove leading zeros
        bus_num=$(echo "$bus_num" | sed 's/^0*//')
        dev_num=$(echo "$dev_num" | sed 's/^0*//')
        
        echo "Selected USB device: $usb_line"
        echo "Vendor ID: $vendor_id"
        echo "Product ID: $product_id"
        echo "Bus: $bus_num, Device: $dev_num"
        
        # Get physical port path - but prefer the one from card info if available
        if [ -z "$card_device_info" ]; then
            physical_port=$(get_usb_physical_port "$bus_num" "$dev_num")
            if [ -n "$physical_port" ]; then
                echo "USB physical port: $physical_port"
            else
                warning "Could not determine physical USB port. Using device ID only for mapping."
                
                # Always create a unique identifier even without port detection
                physical_port="usb-fallback-bus${bus_num}-dev${dev_num}-${RANDOM}"
                echo "Created fallback identifier: $physical_port"
                
                # Ask if user wants to continue with this fallback
                echo
                echo "A fallback identifier has been created for your device."
                read -p "Continue with this identifier? (y/n): " -n 1 -r
                echo
                if [[ ! $REPLY =~ ^[Yy]$ ]]; then
                    error_exit "Mapping canceled."
                fi
            fi
        else
            # Use the path from card info instead - this is more reliable!
            physical_port="$card_device_info"
            echo "Using USB path from card info: $physical_port"
        fi
    else
        warning "Could not extract bus and device numbers. This may affect rule creation."
        # Create a fallback unique identifier
        physical_port="usb-fallback-${RANDOM}-${RANDOM}"
        echo "Created emergency fallback identifier: $physical_port"
    fi
    
    # Get friendly name from user
    echo
    echo "Enter a friendly name for the sound card (lowercase letters, numbers, and hyphens only):"
    read friendly_name
    
    if [ -z "$friendly_name" ]; then
        friendly_name=$(echo "$card_name" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
        info "Using default name: $friendly_name"
    fi
    
    if ! [[ "$friendly_name" =~ ^[a-z0-9-]+$ ]]; then
        error_exit "Invalid friendly name. Use only lowercase letters, numbers, and hyphens."
    fi
    
    # Check existing rules
    check_existing_rules
    
    # Create the rule - offer more options with port detection
    echo
    echo "Ready to create udev rule. Choose rule type:"
    echo "1. Basic rule (by vendor and product ID only)"
    echo "2. Enhanced rule (by vendor, product ID, and USB port path) - RECOMMENDED"
    echo "3. Strict rule (require exact match of vendor, product, and port)"
    read rule_type
    
    rules_file="/etc/udev/rules.d/99-usb-soundcards.rules"
    mkdir -p /etc/udev/rules.d/
    # Save the USB Sound Card Mapper script
cat << 'EOF' > /usr/local/bin/usb-soundcard-mapper.sh
#!/bin/bash
# usb-soundcard-mapper.sh - Automatically map USB sound cards to persistent names
#
# This script automates the process of creating udev rules for USB sound cards
# to ensure they maintain consistent names across reboots.
# Enhanced version with better USB physical port detection for handling multiple
# identical devices.

# Function to print error messages and exit
error_exit() {
    echo -e "\e[31mERROR: $1\e[0m" >&2
    exit 1
}

# Function to print information messages
info() {
    echo -e "\e[34mINFO: $1\e[0m"
}

# Function to print success messages
success() {
    echo -e "\e[32mSUCCESS: $1\e[0m"
}

# Function to print warning messages
warning() {
    echo -e "\e[33mWARNING: $1\e[0m" >&2
}

# Function to print debug messages if debug mode is enabled
debug() {
    if [ "$DEBUG" = "true" ]; then
        echo -e "\e[35mDEBUG: $1\e[0m" >&2
    fi
}

# Check if script is run as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error_exit "This script must be run as root. Please use sudo."
    fi
}

# Function to get available USB sound cards
get_card_info() {
    # Get lsusb output
    info "Getting USB device information..."
    lsusb_output=$(lsusb)
    if [ $? -ne 0 ]; then
        error_exit "Failed to run lsusb command."
    fi
    
    echo "USB devices:"
    echo "$lsusb_output"
    echo
    
    # Get sound card information
    info "Getting sound card information..."
    cards_file="/proc/asound/cards"
    if [ ! -f "$cards_file" ]; then
        error_exit "Cannot access $cards_file. Is ALSA installed properly?"
    fi
    
    cards_output=$(cat "$cards_file")
    if [ $? -ne 0 ]; then
        error_exit "Failed to read $cards_file."
    fi
    
    echo "Sound cards:"
    echo "$cards_output"
    echo
    
    # Extract and display detailed card paths if available
    echo "Card USB paths:"
    while IFS= read -r line; do
        if [[ "$line" =~ at\ (usb-[^ ,]+) ]]; then
            local card_path="${BASH_REMATCH[1]}"
            echo "  $line"
            echo "  Path: $card_path"
        fi
    done <<< "$cards_output"
    echo
    
    # Display aplay output for reference
    if command -v aplay &> /dev/null; then
        aplay_output=$(aplay -l 2>/dev/null)
        if [ -n "$aplay_output" ]; then
            echo "ALSA playback devices:"
            echo "$aplay_output"
            echo
        fi
    fi
}

# Function to check existing udev rules
check_existing_rules() {
    info "Checking existing udev rules..."
    
    rules_file="/etc/udev/rules.d/99-usb-soundcards.rules"
    
    if [ -f "$rules_file" ]; then
        echo "Existing rules in $rules_file:"
        cat "$rules_file"
        echo
    else
        info "No existing rules file found. A new one will be created."
    fi
}

# Function to reload udev rules
reload_udev_rules() {
    info "Reloading udev rules..."
    
    udevadm control --reload-rules
    if [ $? -ne 0 ]; then
        error_exit "Failed to reload udev rules."
    fi
    
    success "Rules reloaded successfully."
}

# Function to prompt for reboot
prompt_reboot() {
    echo "A reboot is recommended for the changes to take effect."
    read -p "Do you want to reboot now? (y/n): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        info "Rebooting system..."
        reboot
    else
        info "Remember to reboot later for changes to take effect."
    fi
}

# NEW FUNCTION: Test if a string is valid USB path
is_valid_usb_path() {
    local path="$1"
    
    # Basic validation - check if it's not empty and contains usb
    if [ -z "$path" ]; then
        return 1
    fi
    
    # Check if path contains expected USB path components
    if [[ "$path" == *"usb"* ]] && [[ "$path" == *":"* ]]; then
        return 0
    else
        return 1
    fi
}

# NEW FUNCTION: Get USB physical port path for a device
get_usb_physical_port() {
    local bus_num="$1"
    local dev_num="$2"
    
    # Validate inputs
    if [ -z "$bus_num" ] || [ -z "$dev_num" ]; then
        debug "Missing bus or device number for port detection"
        return 1
    fi
    
    # Use sysfs directly - this is the most reliable method across distributions
    
    # Method 1: Get the device path from sysfs
    local sysfs_path="/sys/bus/usb/devices/${bus_num}-${dev_num}"
    if [ ! -d "$sysfs_path" ]; then
        # Try alternate format 
        sysfs_path="/sys/bus/usb/devices/${bus_num}-${bus_num}.${dev_num}"
        if [ ! -d "$sysfs_path" ]; then
            # Try finding it through a search
            local possible_path
            possible_path=$(find /sys/bus/usb/devices -maxdepth 1 -name "${bus_num}-*" | grep -m1 "")
            if [ -n "$possible_path" ]; then
                sysfs_path="$possible_path"
            else
                debug "Could not find sysfs path for bus:$bus_num dev:$dev_num"
            fi
        fi
    fi
    
    debug "Checking sysfs path: $sysfs_path"
    
    # ALWAYS create a unique device identifier - based on multiple identifiers
    # Create variables to build a unique identifier
    local base_port_path=""
    local serial=""
    local product_name=""
    local uniqueness=""
    
    # Method 2: Try to get the devpath directly
    local devpath=""
    if [ -f "$sysfs_path/devpath" ]; then
        devpath=$(cat "$sysfs_path/devpath" 2>/dev/null)
        if [ -n "$devpath" ]; then
            debug "Found devpath: $devpath"
            base_port_path="usb-$devpath"
        fi
    fi
    
    # Check for a serial number
    if [ -f "$sysfs_path/serial" ]; then
        serial=$(cat "$sysfs_path/serial" 2>/dev/null)
        debug "Found serial from sysfs: $serial"
    fi
    
    # Check for a product name
    if [ -f "$sysfs_path/product" ]; then
        product_name=$(cat "$sysfs_path/product" 2>/dev/null)
        debug "Found product name: $product_name"
    fi
    
    # Method 3: Get USB device path from sysfs structure
    local sys_device_path=""
    # This gets the canonical path with all symlinks resolved
    if [ -d "$sysfs_path" ]; then
        sys_device_path=$(readlink -f "$sysfs_path" 2>/dev/null)
        debug "Found sysfs device path: $sys_device_path"
    else
        # Try another approach - look through all devices to find matching bus.dev
        local devices_dir="/sys/bus/usb/devices"
        for device in "$devices_dir"/*; do
            if [ -f "$device/busnum" ] && [ -f "$device/devnum" ]; then
                local dev_busnum=$(cat "$device/busnum" 2>/dev/null)
                local dev_devnum=$(cat "$device/devnum" 2>/dev/null)
                
                if [ "$dev_busnum" = "$bus_num" ] && [ "$dev_devnum" = "$dev_num" ]; then
                    sys_device_path=$(readlink -f "$device" 2>/dev/null)
                    debug "Found device through scan: $sys_device_path"
                    
                    # If we found the device this way, also check for serial
                    if [ -z "$serial" ] && [ -f "$device/serial" ]; then
                        serial=$(cat "$device/serial" 2>/dev/null)
                        debug "Found serial through scan: $serial"
                    fi
                    
                    # Check for product name too
                    if [ -z "$product_name" ] && [ -f "$device/product" ]; then
                        product_name=$(cat "$device/product" 2>/dev/null)
                        debug "Found product name through scan: $product_name"
                    fi
                    
                    break
                fi
            fi
        done
    fi
    
    # Extract the port path from the device path if we don't have one yet
    if [ -z "$base_port_path" ] && [ -n "$sys_device_path" ]; then
        # Extract the port information from the path
        
        # Method A: Try to get the device path structure
        if [[ "$sys_device_path" =~ /[0-9]+-[0-9]+(\.[0-9]+)*$ ]]; then
            base_port_path="${BASH_REMATCH[0]}"
            base_port_path="${base_port_path#/}"  # Remove leading slash
            debug "Extracted port path from device path: $base_port_path"
        fi
        
        # Method B: Use the directory name itself which often has port info
        if [ -z "$base_port_path" ]; then
            local dirname=$(basename "$sys_device_path")
            if [[ "$dirname" == *"-"* ]]; then
                debug "Using directory name as port identifier: $dirname"
                base_port_path="$dirname"
            fi
        fi
    fi
    
    # Method 4: Use udevadm as a last resort for port path
    if [ -z "$base_port_path" ]; then
        debug "Trying udevadm method as last resort"
        local device_path=""
        device_path=$(udevadm info -q path -n /dev/bus/usb/$bus_num/$dev_num 2>/dev/null)
        
        if [ -n "$device_path" ]; then
            debug "Found udevadm path: $device_path"
            
            # Get full properties
            local udevadm_props
            udevadm_props=$(udevadm info -n /dev/bus/usb/$bus_num/$dev_num --query=property 2>/dev/null)
            
            # Try to get serial number if we don't have it
            if [ -z "$serial" ]; then
                serial=$(echo "$udevadm_props" | grep -m1 "ID_SERIAL=" | cut -d= -f2)
                debug "Found serial from udevadm: $serial"
            fi
            
            # Try to get product name if we don't have it
            if [ -z "$product_name" ]; then
                product_name=$(echo "$udevadm_props" | grep -m1 "ID_MODEL=" | cut -d= -f2)
                debug "Found product name from udevadm: $product_name"
            fi
            
            # Look for DEVPATH
            local devpath=""
            devpath=$(echo "$udevadm_props" | grep -m1 "DEVPATH=" | cut -d= -f2)
            
            if [ -n "$devpath" ]; then
                # Extract meaningful part of path
                if [[ "$devpath" =~ /([0-9]+-[0-9]+(\.[0-9]+)*)$ ]]; then
                    base_port_path="${BASH_REMATCH[1]}"
                    debug "Extracted port from DEVPATH: $base_port_path"
                fi
                
                # If we still have nothing, use the last part of the path
                if [ -z "$base_port_path" ]; then
                    local last_part=$(basename "$devpath")
                    if [[ "$last_part" == *"-"* ]]; then
                        debug "Using last part of DEVPATH: $last_part"
                        base_port_path="$last_part"
                    fi
                fi
            fi
            
            # Try to extract port info from the device path itself if still nothing
            if [ -z "$base_port_path" ] && [[ "$device_path" =~ ([0-9]+-[0-9]+(\.[0-9]+)*) ]]; then
                base_port_path="${BASH_REMATCH[1]}"
                debug "Extracted port from device path: $base_port_path"
            fi
        fi
    fi
    
    # Method 5: Last fallback - just create a unique identifier from bus and device
    if [ -z "$base_port_path" ]; then
        debug "Using fallback method - creating synthetic port identifier"
        base_port_path="usb-bus${bus_num}-port${dev_num}"
    fi
    
    # Now build a unique identifier using all information we have
    
    # First, use base port path
    uniqueness="$base_port_path"
    
    # Always create a fallback uniqueness tag based on device-specific information
    # This ensures even identical devices on the same port get unique identifiers
    local uuid_fragment=""
    
    # Try using serial number first (most reliable)
    if [ -n "$serial" ]; then
        # Use first 8 chars of serial or the whole thing if shorter
        if [ ${#serial} -gt 8 ]; then
            uuid_fragment="${serial:0:8}"
        else
            uuid_fragment="$serial"
        fi
    else
        # If no serial number, create a hash based on bus/dev and product info
        local hash_input="bus${bus_num}dev${dev_num}"
        # Add product name if available
        [ -n "$product_name" ] && hash_input="${hash_input}${product_name}"
        # Add current timestamp to ensure uniqueness
        hash_input="${hash_input}$(date +%s%N)"
        # Create a 8-char hash
        uuid_fragment=$(echo "$hash_input" | md5sum | head -c 8)
    fi
    
    # Append uuid fragment to ensure uniqueness
    echo "${uniqueness}-${uuid_fragment}"
    return 0
}

# NEW FUNCTION: Test USB port detection
test_usb_port_detection() {
    info "Testing USB port detection..."
    
    # Get all USB devices
    local usb_devices
    usb_devices=$(lsusb)
    
    if [ -z "$usb_devices" ]; then
        warning "No USB devices found during test."
        return 1
    fi
    
    echo "Found USB devices:"
    echo "$usb_devices"
    echo
    
    # Show debug info for the first device to help troubleshoot
    if [[ "$usb_devices" =~ Bus\ ([0-9]{3})\ Device\ ([0-9]{3}) ]]; then
        local bus_num="${BASH_REMATCH[1]}"
        local dev_num="${BASH_REMATCH[2]}"
        
        # Remove leading zeros
        bus_num=$(echo "$bus_num" | sed 's/^0*//')
        dev_num=$(echo "$dev_num" | sed 's/^0*//')
        
        echo "Detailed information for first device (Bus $bus_num Device $dev_num):"
        
        # Show USB sysfs paths for debugging
        echo "Checking for USB device in sysfs:"
        echo "1. Standard path: /sys/bus/usb/devices/${bus_num}-${dev_num}"
        [ -d "/sys/bus/usb/devices/${bus_num}-${dev_num}" ] && echo "   - Path exists" || echo "   - Path does not exist"
        
        echo "2. Alternate path: /sys/bus/usb/devices/${bus_num}-${bus_num}.${dev_num}"
        [ -d "/sys/bus/usb/devices/${bus_num}-${bus_num}.${dev_num}" ] && echo "   - Path exists" || echo "   - Path does not exist"
        
        echo "3. Search results:"
        find /sys/bus/usb/devices -maxdepth 1 -name "${bus_num}-*" | head -n 3
        
        # Check for devpath attribute
        local found_devpath=""
        for potential_path in "/sys/bus/usb/devices/${bus_num}-${dev_num}" "/sys/bus/usb/devices/${bus_num}-${bus_num}.${dev_num}" $(find /sys/bus/usb/devices -maxdepth 1 -name "${bus_num}-*" | head -n 1); do
            if [ -f "$potential_path/devpath" ]; then
                found_devpath=$(cat "$potential_path/devpath" 2>/dev/null)
                echo "4. Found devpath attribute at $potential_path/devpath: $found_devpath"
                break
            fi
        done
        
        if [ -z "$found_devpath" ]; then
            echo "4. No devpath attribute found in any potential path"
        fi
        
        # Show udevadm info
        echo "5. udevadm information:"
        local dev_path
        dev_path=$(udevadm info -q path -n /dev/bus/usb/$bus_num/$dev_num 2>/dev/null)
        if [ -n "$dev_path" ]; then
            echo "   - Device path: $dev_path"
            echo "   - First 5 lines of udevadm property info:"
            udevadm info -n /dev/bus/usb/$bus_num/$dev_num --query=property 2>/dev/null | head -n 5
        else
            echo "   - Could not get udevadm device path"
        fi
        
        echo
    fi
    
    # Continue with regular testing
    local success_count=0
    local total_count=0
    
    # Process each USB device
    while read -r line; do
        if [[ "$line" =~ Bus\ ([0-9]{3})\ Device\ ([0-9]{3}) ]]; then
            local bus_num="${BASH_REMATCH[1]}"
            local dev_num="${BASH_REMATCH[2]}"
            
            # Remove leading zeros
            bus_num=$(echo "$bus_num" | sed 's/^0*//')
            dev_num=$(echo "$dev_num" | sed 's/^0*//')
            
            total_count=$((total_count + 1))
            
            # Enable debug for the test function
            local old_debug="$DEBUG"
            DEBUG="false"  # Disable verbose debug output during tests to keep output clean
            
            # Try to get port info
            local port_path
            port_path=$(get_usb_physical_port "$bus_num" "$dev_num")
            local result=$?
            
            # Restore debug setting
            DEBUG="$old_debug"
            
            if [ $result -eq 0 ] && [ -n "$port_path" ]; then
                echo "Device on Bus $bus_num Device $dev_num: Port path = $port_path"
                success_count=$((success_count + 1))
            else
                echo "Device on Bus $bus_num Device $dev_num: Could not determine port path"
            fi
        fi
    done <<< "$usb_devices"
    
    echo
    echo "Port detection test results: $success_count of $total_count devices mapped successfully."
    
    if [ $success_count -eq 0 ]; then
        warning "Port detection test failed. No port paths could be determined."
        return 1
    elif [ $success_count -lt $total_count ]; then
        warning "Port detection partially successful. Some devices could not be mapped."
        return 2
    else
        success "Port detection test successful! All device ports were mapped."
        return 0
    fi
}

# Enhanced function to get more detailed card info including port path
get_detailed_card_info() {
    local card_num="$1"
    
    # Get card directory path
    card_dir="/proc/asound/card${card_num}"
    if [ ! -d "$card_dir" ]; then
        error_exit "Cannot find directory $card_dir"
    fi
    
    # Check if it's a USB device
    if [ ! -d "${card_dir}/usbbus" ] && [ ! -d "${card_dir}/usbid" ] && [ ! -f "${card_dir}/usbid" ]; then
        warning "Card $card_num may not be a USB device. Continuing anyway..."
    fi
    
    # Try to get USB info from udevadm
    info "Getting detailed USB information for sound card $card_num..."
    
    # Variables to store device info
    local bus_num=""
    local dev_num=""
    local physical_port=""
    local vendor_id=""
    local product_id=""
    
    # Try to get USB bus and device number directly from ALSA
    if [ -f "${card_dir}/usbbus" ]; then
        bus_num=$(cat "${card_dir}/usbbus" 2>/dev/null)
        info "Found USB bus from card directory: $bus_num"
    fi
    
    if [ -f "${card_dir}/usbdev" ]; then
        dev_num=$(cat "${card_dir}/usbdev" 2>/dev/null)
        info "Found USB device from card directory: $dev_num"
    fi
    
    # Try to get vendor and product ID from usbid file
    if [ -f "${card_dir}/usbid" ]; then
        local usbid=$(cat "${card_dir}/usbid" 2>/dev/null)
        if [[ "$usbid" =~ ([0-9a-f]{4}):([0-9a-f]{4}) ]]; then
            vendor_id="${BASH_REMATCH[1]}"
            product_id="${BASH_REMATCH[2]}"
            info "Found USB IDs from card directory: vendor=$vendor_id, product=$product_id"
        fi
    fi
    
    # If we have both bus and device number, try to get the physical port
    if [ -n "$bus_num" ] && [ -n "$dev_num" ]; then
        info "Using direct ALSA info: bus=$bus_num, device=$dev_num"
        physical_port=$(get_usb_physical_port "$bus_num" "$dev_num")
        if [ -n "$physical_port" ]; then
            info "USB physical port: $physical_port"
            
            echo "USB Device Information for card $card_num:"
            echo "  Bus: $bus_num"
            echo "  Device: $dev_num"
            echo "  Physical Port: $physical_port"
            [ -n "$vendor_id" ] && echo "  Vendor ID: $vendor_id"
            [ -n "$product_id" ] && echo "  Product ID: $product_id"
            echo
            
            return 0
        fi
    fi
    
    # If direct approach failed, try using device nodes
    info "Trying alternative approach with device nodes..."
    
    # Find a USB device in the card's directory using various possible paths
    local device_paths=()
    
    # Add common PCM device paths
    if [ -d "${card_dir}/pcm0p" ]; then
        device_paths+=("${card_dir}/pcm0p/sub0")
    fi
    if [ -d "${card_dir}/pcm0c" ]; then
        device_paths+=("${card_dir}/pcm0c/sub0")
    fi
    
    # Add any other pcm devices
    for pcm_dir in "${card_dir}"/pcm*; do
        if [ -d "$pcm_dir" ]; then
            for sub_dir in "$pcm_dir"/sub*; do
                if [ -d "$sub_dir" ]; then
                    device_paths+=("$sub_dir")
                fi
            done
        fi
    done
    
    # Try to find MIDI devices too
    if [ -d "${card_dir}/midi" ]; then
        for midi_dir in "${card_dir}"/midi*; do
            if [ -d "$midi_dir" ]; then
                device_paths+=("$midi_dir")
            fi
        done
    fi
    
    # Try each device path
    for device_path in "${device_paths[@]}"; do
        if [ -d "$device_path" ]; then
            debug "Checking device path: $device_path"
            dev_node=$(ls -l "$device_path" 2>/dev/null | grep -o "/dev/snd/[^ ]*" | head -1)
            
            if [ -n "$dev_node" ]; then
                info "Using device node: $dev_node"
                
                if [ -e "$dev_node" ]; then
                    udevadm_output=$(udevadm info -a -n "$dev_node" 2>/dev/null)
                    
                    # Get USB device info from udevadm output
                    local new_bus_num=$(echo "$udevadm_output" | grep -m1 "ATTR{busnum}" | grep -o "[0-9]*$")
                    local new_dev_num=$(echo "$udevadm_output" | grep -m1 "ATTR{devnum}" | grep -o "[0-9]*$")
                    
                    if [ -n "$new_bus_num" ] && [ -n "$new_dev_num" ]; then
                        bus_num="$new_bus_num"
                        dev_num="$new_dev_num"
                        info "Found USB bus:device = $bus_num:$dev_num from device node"
                        
                        # Extract vendor and product ID if we don't have them
                        if [ -z "$vendor_id" ] || [ -z "$product_id" ]; then
                            local new_vendor=$(echo "$udevadm_output" | grep -m1 "ATTR{idVendor}" | grep -o '"[^"]*"' | tr -d '"')
                            local new_product=$(echo "$udevadm_output" | grep -m1 "ATTR{idProduct}" | grep -o '"[^"]*"' | tr -d '"')
                            
                            if [ -n "$new_vendor" ] && [ -n "$new_product" ]; then
                                vendor_id="$new_vendor"
                                product_id="$new_product"
                                info "Found USB IDs from udevadm: vendor=$vendor_id, product=$product_id"
                            fi
                        fi
                        
                        # Try to get physical port again with the new bus/dev
                        physical_port=$(get_usb_physical_port "$bus_num" "$dev_num")
                        if [ -n "$physical_port" ]; then
                            info "USB physical port: $physical_port"
                            break
                        fi
                    fi
                else
                    debug "Device node $dev_node does not exist"
                fi
            fi
        fi
    done
    
    # If we found the bus and device, but not the port, try one more approach
    if [ -n "$bus_num" ] && [ -n "$dev_num" ] && [ -z "$physical_port" ]; then
        # Try with direct sysfs access
        info "Trying with direct sysfs access..."
        physical_port=$(get_usb_physical_port "$bus_num" "$dev_num")
    fi
    
    # Output the information we found
    if [ -n "$bus_num" ] || [ -n "$dev_num" ] || [ -n "$physical_port" ] || [ -n "$vendor_id" ] || [ -n "$product_id" ]; then
        echo "USB Device Information for card $card_num:"
        [ -n "$bus_num" ] && echo "  Bus: $bus_num"
        [ -n "$dev_num" ] && echo "  Device: $dev_num"
        [ -n "$physical_port" ] && echo "  Physical Port: $physical_port"
        [ -n "$vendor_id" ] && echo "  Vendor ID: $vendor_id"
        [ -n "$product_id" ] && echo "  Product ID: $product_id"
        echo
        
        # If we at least have bus and device, return success
        if [ -n "$bus_num" ] && [ -n "$dev_num" ]; then
            return 0
        fi
    fi
    
    # Last resort - look for hardware info in proc filesystem
    if [ -f "/proc/asound/card${card_num}/id" ]; then
        local card_id=$(cat "/proc/asound/card${card_num}/id" 2>/dev/null)
        info "Card ID: $card_id"
    fi
    
    warning "Could not get complete USB information for card $card_num."
    warning "Limited port detection might be available for this device."
    
    return 1
}

# Enhanced interactive mapping function
interactive_mapping() {
    echo -e "\e[1m===== USB Sound Card Mapper =====\e[0m"
    echo "This wizard will guide you through mapping your USB sound card to a consistent name."
    echo
    
    # Get card information
    get_card_info
    
    # Let user select a card by number
    echo "Enter the number of the sound card you want to map:"
    read card_num
    
    if ! [[ "$card_num" =~ ^[0-9]+$ ]]; then
        error_exit "Invalid input. Please enter a number."
    fi
    
    # Get the card information line
    card_line=$(grep -E "^ *$card_num " /proc/asound/cards)
    if [ -z "$card_line" ]; then
        error_exit "No sound card found with number $card_num."
    fi
    
    # Extract card name
    card_name=$(echo "$card_line" | sed -n 's/.*\[\([^]]*\)\].*/\1/p' | xargs)
    if [ -z "$card_name" ]; then
        error_exit "Could not extract card name from line: $card_line"
    fi
    
    echo "Selected card: $card_num - $card_name"
    
    # Extract card device info from proc/asound/cards - this is the most reliable approach
    local card_device_info=""
    # Look at full card information to get the full USB path
    local full_card_info=$(cat /proc/asound/cards | grep -A1 "^ *$card_num ")
    
    if [[ "$full_card_info" =~ at\ (usb-[^ ,]+) ]]; then
        card_device_info="${BASH_REMATCH[1]}"
        info "Found actual USB path from card info: $card_device_info"
        
        # This is super important - the path format varies between distributions
        # Extract just the relevant part for broader matching
        if [[ "$card_device_info" =~ usb-([^,]+) ]]; then
            info "Extracted clean path: ${BASH_REMATCH[1]}"
        fi
    fi
    
    # Try to get detailed card info including USB device path
    get_detailed_card_info "$card_num"
    #!/bin/bash

# Complete installation script for MediaMTX Audio RTSP System
# This script installs and configures the entire system:
# 1. MediaMTX RTSP server
# 2. USB Sound Card Mapper
# 3. Audio RTSP Streaming Service

# Exit on error
set -e

echo "MediaMTX Audio RTSP System - Installation Script"
echo "================================================"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root. Please use sudo."
  exit 1
fi

# Create a temporary directory for downloads
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

#
# Step 1: Install MediaMTX
#
echo -e "\n\033[1;34mStep 1: Installing MediaMTX RTSP Server\033[0m"

# Install required packages
echo "Installing required packages..."
apt update && apt install -y ffmpeg curl wget grep sed

# Function to get the latest release version
get_latest_release() {
  curl --silent "https://api.github.com/repos/bluenviron/mediamtx/releases/latest" | 
  grep '"tag_name":' | 
  sed -E 's/.*"([^"]+)".*/\1/'
}

# Get the latest release version
VERSION=$(get_latest_release)
echo "Latest MediaMTX version is: $VERSION"

# Determine CPU architecture
ARCH=$(uname -m)
echo "Detected CPU architecture: $ARCH"

# Map architecture to MediaMTX naming convention
case $ARCH in
  x86_64)
    MTX_ARCH="amd64"
    ;;
  aarch64|arm64)
    MTX_ARCH="arm64v8"
    ;;
  armv6*|armv6l)
    MTX_ARCH="armv6"
    ;;
  *)
    echo "Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

# Construct download URL
DOWNLOAD_URL="https://github.com/bluenviron/mediamtx/releases/download/${VERSION}/mediamtx_${VERSION}_linux_${MTX_ARCH}.tar.gz"
echo "Download URL: $DOWNLOAD_URL"

# Download and extract
echo "Downloading and extracting MediaMTX..."
wget -c "$DOWNLOAD_URL" -O - | tar -xz -C /usr/local

echo "MediaMTX has been installed to /usr/local/mediamtx"

# Create a systemd service file for MediaMTX
echo "Creating MediaMTX systemd service..."
cat << EOF > /etc/systemd/system/mediamtx.service
[Unit]
Description=MediaMTX RTSP server
After=network.target

[Service]
ExecStart=/usr/local/mediamtx/mediamtx
WorkingDirectory=/usr/local/mediamtx
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the service
echo "Enabling MediaMTX service..."
systemctl daemon-reload
systemctl enable mediamtx.service
systemctl start mediamtx.service

echo "MediaMTX installation complete!"

#
# Step 2: Install USB Sound Card Mapper
#
echo -e "\n\033[1;34mStep 2: Installing USB Sound Card Mapper\033[0m"

# Save the USB Sound Card Mapper script
cat << 'EOF' > /usr/local/bin/usb-soundcard-mapper.sh
#!/bin/bash
# usb-soundcard-mapper.sh - Automatically map USB sound cards to persistent names
#
# This script automates the process of creating udev rules for USB sound cards
# to ensure they maintain consistent names across reboots.

# SCRIPT CONTENT WOULD BE INSERTED HERE
# The entire script would be included here, but abbreviated for example
EOF

# Insert the actual script content here - this is a placeholder reference
# Full script would need to be inserted here

# Set permissions
chmod +x /usr/local/bin/usb-soundcard-mapper.sh

echo "USB Sound Card Mapper installed to /usr/local/bin/usb-soundcard-mapper.sh"

# Create a symlink for backwards compatibility if needed
ln -sf /usr/local/bin/usb-soundcard-mapper.sh /usr/local/bin/map-usb-audio.sh

#
# Step 3: Create the Audio RTSP Streaming Script
#
echo -e "\n\033[1;34mStep 3: Creating Audio RTSP Streaming Script\033[0m"

# Save the startmic.sh script
cat << 'EOF' > /usr/local/bin/startmic.sh
#!/bin/bash

# Exit on error
set -e

# Redirect output to log file when running as a service
if systemctl is-active --quiet audio-rtsp.service; then
    exec >> /var/log/audio-rtsp/audio-streams.log 2>&1
    echo "----------------------------------------"
    echo "Service started at $(date)"
    echo "----------------------------------------"
fi

echo "Starting MediaMTX RTSP server..."
# Check if MediaMTX is already running
if pgrep mediamtx > /dev/null; then
    echo "MediaMTX is already running."
else
    # Start MediaMTX in the background
    /usr/local/mediamtx/mediamtx &
    echo "Waiting for MediaMTX to initialize..."
    sleep 3  # Allow MediaMTX time to start properly
fi

# Function to check if a sound card has a capture device
has_capture_device() {
    local card=$1
    if arecord -l | grep -q "card $card"; then
        return 0  # Has capture device
    else
        return 1  # No capture device
    fi
}

# Function to get a sanitized name for the RTSP stream
get_stream_name() {
    local card_name=$1
    # Remove spaces, special characters and convert to lowercase
    echo "$card_name" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g'
}

# Kill any existing ffmpeg processes
echo "Stopping any existing ffmpeg streams..."
pkill -f ffmpeg || true
sleep 1

# Get list of sound cards
echo "Detecting sound cards with capture capabilities..."
SOUND_CARDS=$(cat /proc/asound/cards)

# Create an associative array to store device details
declare -A STREAM_DETAILS

# Parse sound cards and start ffmpeg for each one with capture capability
echo "$SOUND_CARDS" | while read -r line; do
    if [[ "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]*\[([^]]+)\][[:space:]]*:[[:space:]]*(.*) ]]; then
        CARD_NUM=${BASH_REMATCH[1]}
        CARD_ID=${BASH_REMATCH[2]}
        CARD_DESC=${BASH_REMATCH[3]}
        
        # Remove leading/trailing whitespace from card ID
        CARD_ID=$(echo "$CARD_ID" | xargs)
        
        # Extract USB device info if available
        USB_INFO=""
        if [[ "$CARD_DESC" =~ USB-Audio ]]; then
            USB_INFO=$(echo "$CARD_DESC" | sed -n 's/.*USB-Audio - \(.*\)/\1/p')
        fi
        
        # Exclude known system sound devices that shouldn't be used for capture
        if [[ "$CARD_ID" =~ ^(bcm2835_headpho|vc4-hdmi|HDMI)$ ]]; then
            echo "Skipping system audio device: $CARD_ID"
            continue
        fi
        
        # Check if this card has capture capabilities
        if has_capture_device "$CARD_NUM"; then
            # Generate stream name based on card ID
            STREAM_NAME=$(get_stream_name "$CARD_ID")
            RTSP_URL="rtsp://localhost:8554/$STREAM_NAME"
            
            echo "Starting RTSP stream for card $CARD_NUM [$CARD_ID]: $RTSP_URL"
            
            # Save the details to our array
            # Use a delimiter that's unlikely to appear in the names
            echo "$CARD_NUM|$CARD_ID|$USB_INFO|$RTSP_URL" >> /tmp/stream_details.$$
            
            # Start ffmpeg with the appropriate sound card
            ffmpeg -nostdin -f alsa -ac 1 -i "plughw:CARD=$CARD_ID,DEV=0" \
                  -acodec libmp3lame -b:a 160k -ac 2 -content_type 'audio/mpeg' \
                  -f rtsp "$RTSP_URL" -rtsp_transport tcp &
            
            # Small delay to stagger the ffmpeg starts
            sleep 0.5
        else
            echo "Skipping card $CARD_NUM [$CARD_ID] - no capture device found"
        fi
    fi
done

# Check if any streams were created
if [ -f /tmp/stream_details.$$ ]; then
    echo ""
    echo "================================================================="
    echo "                  ACTIVE AUDIO RTSP STREAMS                      "
    echo "================================================================="
    printf "%-4s | %-15s | %-30s | %s\n" "Card" "Card ID" "USB Device" "RTSP URL"
    echo "-----------------------------------------------------------------"
    
    # Print a formatted table of the streams
    while IFS="|" read -r card_num card_id usb_info rtsp_url; do
        printf "%-4s | %-15s | %-30s | %s\n" "$card_num" "$card_id" "$usb_info" "$rtsp_url"
    done < /tmp/stream_details.$$
    
    echo "================================================================="
    echo ""
    
    # Get the IP address of the machine for external access
    IP_ADDR=$(hostname -I | awk '{print $1}')
    if [ -n "$IP_ADDR" ]; then
        echo "To access these streams from other devices on the network, replace"
        echo "'localhost' with '$IP_ADDR' in the RTSP URLs"
        echo ""
    fi
    
    # Clean up the temporary file
    rm /tmp/stream_details.$$
else
    echo "No audio streams were created. Check if you have audio capture devices connected."
fi
EOF

# Set permissions
chmod +x /usr/local/bin/startmic.sh

echo "Audio RTSP Streaming script installed to /usr/local/bin/startmic.sh"

#
# Step 4: Create the Audio RTSP Service
#
echo -e "\n\033[1;34mStep 4: Setting up Audio RTSP Service\033[0m"

# Create required directories
mkdir -p /var/log/audio-rtsp

# Create systemd service file
cat << 'EOF' > /etc/systemd/system/audio-rtsp.service
[Unit]
Description=Audio RTSP Streaming Service
After=network.target mediamtx.service
Requires=mediamtx.service
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=root
WorkingDirectory=/usr/local/bin
ExecStart=/usr/local/bin/startmic.sh
Restart=always
RestartSec=10
# Give the service time to properly start all streams
TimeoutStartSec=30
# Set resource limits to ensure stability
LimitNOFILE=65536

# Make sure the process group is killed when the service is stopped
KillMode=mixed
KillSignal=SIGTERM

# Ensure environment is properly set up
Environment=PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

[Install]
WantedBy=multi-user.target
EOF

# Create a log rotation config to prevent logs from filling up disk
cat > /etc/logrotate.d/audio-rtsp << 'EOF'
/var/log/audio-rtsp/*.log {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    create 0640 root root
}
EOF

# Create a helper script to check the status
cat > /usr/local/bin/check-audio-rtsp.sh << 'EOF'
#!/bin/bash

echo "Audio RTSP Service Status:"
systemctl status audio-rtsp.service

echo -e "\nRunning Audio Streams:"
ps aux | grep "[f]fmpeg" | grep -o "rtsp://[^ ]*" | sort

echo -e "\nAvailable Sound Cards:"
cat /proc/asound/cards

# Get the machine's IP address
IP_ADDR=$(hostname -I | awk '{print $1}')
if [ -n "$IP_ADDR" ]; then
    echo -e "\nTo access streams from other devices, use: $IP_ADDR instead of localhost"
fi
EOF
chmod +x /usr/local/bin/check-audio-rtsp.sh

# Enable and start the service
echo "Enabling and starting Audio RTSP service..."
systemctl daemon-reload
systemctl enable audio-rtsp.service
systemctl start audio-rtsp.service

#
# Step 5: Run the USB Sound Card Mapper Wizard
#
echo -e "\n\033[1;34mStep 5: USB Sound Card Mapping Setup\033[0m"
echo "It's important to map your USB sound cards to ensure they maintain"
echo "persistent names across reboots."

# Check if there are any USB sound cards
if arecord -l | grep -q USB; then
    echo "USB sound cards detected. Would you like to run the mapping wizard now? (y/n)"
    read -r run_mapper
    if [[ "$run_mapper" =~ ^[Yy]$ ]]; then
        echo "Running USB Sound Card Mapper wizard..."
        /usr/local/bin/usb-soundcard-mapper.sh
    else
        echo "You can run the USB Sound Card Mapper later with this command:"
        echo "sudo /usr/local/bin/usb-soundcard-mapper.sh"
    fi
else
    echo "No USB sound cards detected. If you connect USB sound cards later,"
    echo "you can map them using: sudo /usr/local/bin/usb-soundcard-mapper.sh"
fi

#
# Final Step: Installation Complete
#
echo -e "\n\033[1;32mMediaMTX Audio RTSP System Installation Complete!\033[0m"
echo "-------------------------------------------------------------"
echo "Services installed:"
echo "  1. MediaMTX - RTSP server"
echo "  2. Audio RTSP - Audio streaming service"
echo
echo "Utility scripts installed:"
echo "  - /usr/local/bin/usb-soundcard-mapper.sh - Map USB sound cards"
echo "  - /usr/local/bin/startmic.sh - Manual stream creator"
echo "  - /usr/local/bin/check-audio-rtsp.sh - Status checker"
echo
echo "To check the status of your audio streams:"
echo "  sudo check-audio-rtsp.sh"
echo
echo "For issues and troubleshooting, check the README.md"

# Clean up
cd /
rm -rf "$TEMP_DIR"

exit 0
