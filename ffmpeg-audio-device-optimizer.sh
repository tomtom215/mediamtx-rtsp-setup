#!/bin/bash
#
# Enhanced FFmpeg Command Generator
# - Detects native sample format for each device
# - Detects native sample rate for each device
# - Generates optimized FFmpeg commands

# Configure your devices and their channel modes here
declare -A DEVICE_CHANNELS
DEVICE_CHANNELS["hw:1,0"]=2  # Traxshot (stereo)
DEVICE_CHANNELS["hw:2,0"]=1  # minimic (mono)

# Default formats to try (in order of preference)
FORMATS_TO_TRY=("S32_LE" "S24_3LE" "S24_LE" "S16_LE" "S8")

# Default rates to try (in order of preference)
RATES_TO_TRY=(96000 48000 44100 32000 22050 16000)

# Function to map ALSA format to FFmpeg format
map_format_to_ffmpeg() {
    local alsa_format="$1"
    local ffmpeg_format=""
    
    case "$alsa_format" in
        S16_LE)  ffmpeg_format="s16le" ;;
        S24_LE)  ffmpeg_format="s24le" ;;
        S32_LE)  ffmpeg_format="s32le" ;;
        FLOAT_LE) ffmpeg_format="f32le" ;;
        S24_3LE) ffmpeg_format="s24le" ;;  # Special case
        U8)      ffmpeg_format="u8" ;;
        S8)      ffmpeg_format="s8" ;;
        S16_BE)  ffmpeg_format="s16be" ;;
        S24_BE)  ffmpeg_format="s24be" ;;
        S32_BE)  ffmpeg_format="s32be" ;;
        FLOAT_BE) ffmpeg_format="f32be" ;;
        U16_LE)  ffmpeg_format="u16le" ;;
        U16_BE)  ffmpeg_format="u16be" ;;
        U24_LE)  ffmpeg_format="u24le" ;;
        U24_BE)  ffmpeg_format="u24be" ;;
        U32_LE)  ffmpeg_format="u32le" ;;
        U32_BE)  ffmpeg_format="u32be" ;;
        *)       ffmpeg_format="s16le" ;;  # Default
    esac
    
    echo "$ffmpeg_format"
}

# Function to calculate appropriate bitrate based on rate and channels
calculate_bitrate() {
    local rate="$1"
    local channels="$2"
    local quality="$3"  # standard, high
    local base_bitrate=128
    
    # Adjust for quality
    if [[ "$quality" == "high" ]]; then
        base_bitrate=192
    fi
    
    # Adjust for sample rate
    if (( rate >= 96000 )); then
        if [[ "$quality" == "high" ]]; then
            base_bitrate=320
        else
            base_bitrate=$((base_bitrate * 3 / 2))
        fi
    elif (( rate >= 48000 )); then
        if [[ "$quality" == "high" ]]; then
            base_bitrate=256
        else
            base_bitrate=$((base_bitrate * 5 / 4))
        fi
    fi
    
    # Adjust for channels
    if (( channels > 1 )); then
        # For stereo, increase bitrate proportionally but with diminishing returns
        base_bitrate=$((base_bitrate * (channels + 1) / 2))
    fi
    
    # Ensure we have sensible limits
    if [[ "$quality" == "high" ]] && (( base_bitrate < 192 )); then
        base_bitrate=192
    elif (( base_bitrate > 320 )); then
        base_bitrate=320
    fi
    
    echo "${base_bitrate}k"
}

# Function to detect native sample rate for a device
detect_native_rate() {
    local device_id="$1"
    local channels="$2"
    local format="$3"
    
    # First check if hw params provides rate info
    local hw_params=$(arecord -D "$device_id" --dump-hw-params 2>/dev/null)
    if [[ -n "$hw_params" ]]; then
        # Look for rate ranges in the format
        local rates=$(echo "$hw_params" | grep -A20 "RATE" | grep -oP "(\d+)(?=Hz)" | tr '\n' ' ')
        if [[ -n "$rates" ]]; then
            # Check if hw_params indicates a specific native rate
            local rate_range=$(echo "$hw_params" | grep -A3 "RATE" | grep "range")
            if [[ "$rate_range" == *"range"* ]]; then
                # If we have a range with identical min/max, that's likely the native rate
                if [[ "$rate_range" =~ min\ =\ ([0-9]+)Hz,\ max\ =\ ([0-9]+)Hz ]]; then
                    local min_rate="${BASH_REMATCH[1]}"
                    local max_rate="${BASH_REMATCH[2]}"
                    if [[ "$min_rate" == "$max_rate" ]]; then
                        echo "Native rate (from hw params): $min_rate Hz"
                        return 0
                    fi
                fi
            fi
        fi
    fi
    
    # Try a recording test to see if device reports a native rate mismatch
    local test_output=$(arecord -D "$device_id" -d 0.1 -f "$format" -r 48000 -c "$channels" -v /dev/null 2>&1)
    if [[ "$test_output" == *"rate is not accurate"* && "$test_output" =~ got\ =\ ([0-9]+)Hz ]]; then
        local native_rate="${BASH_REMATCH[1]}"
        echo "Native rate (from mismatch detection): $native_rate Hz"
        return 0
    fi
    
    # If no native rate detected, try standard rates and see which one works
    for rate in "${RATES_TO_TRY[@]}"; do
        if arecord -D "$device_id" -d 0.1 -f "$format" -r "$rate" -c "$channels" -v /dev/null &>/dev/null; then
            echo "Compatible rate: $rate Hz"
            return 0
        fi
    done
    
    # If no rate detected, return default
    echo "Default rate: 48000 Hz"
    return 0
}

# Function to detect optimal sample format for a device
detect_optimal_format() {
    local device_id="$1"
    local channels="$2"
    
    # First check if hw params provides format info
    local hw_params=$(arecord -D "$device_id" --dump-hw-params 2>/dev/null)
    if [[ -n "$hw_params" ]]; then
        # Look for formats in the dump
        local formats=$(echo "$hw_params" | grep -A5 "FORMAT" | grep -oP "(?<=FORMAT \[).*(?=\])" | tr ',' ' ')
        if [[ -n "$formats" ]]; then
            echo "Available formats: $formats"
            
            # Try each format in our preferred order
            for fmt in "${FORMATS_TO_TRY[@]}"; do
                if [[ "$formats" == *"$fmt"* ]]; then
                    # Test if this format works
                    if arecord -D "$device_id" -d 0.1 -f "$fmt" -r 48000 -c "$channels" -v /dev/null &>/dev/null; then
                        echo "Selected format: $fmt"
                        return 0
                    fi
                fi
            done
        fi
    fi
    
    # If no format info from hw_params or none worked, try formats directly
    for fmt in "${FORMATS_TO_TRY[@]}"; do
        if arecord -D "$device_id" -d 0.1 -f "$fmt" -r 48000 -c "$channels" -v /dev/null &>/dev/null; then
            echo "Compatible format: $fmt"
            return 0
        fi
    done
    
    # If no format detected, return default
    echo "Default format: S16_LE"
    return 0
}

# Generate FFmpeg commands for a device with optimal settings
generate_commands() {
    local device_id="$1"
    local channels="${DEVICE_CHANNELS[$device_id]}"
    
    echo "Detecting optimal settings for $device_id (${channels} channels)..."
    
    # Detect optimal format (using S16_LE initially for detection tests)
    local format_result=$(detect_optimal_format "$device_id" "$channels")
    local format=$(echo "$format_result" | grep -o "Selected format: \S\+" | cut -d' ' -f3)
    
    # If no selected format found, look for compatible format
    if [[ -z "$format" ]]; then
        format=$(echo "$format_result" | grep -o "Compatible format: \S\+" | cut -d' ' -f3)
    fi
    
    # If still no format, use default
    if [[ -z "$format" ]]; then
        format="S16_LE"
    fi
    
    # Map ALSA format to FFmpeg format
    local ffmpeg_format=$(map_format_to_ffmpeg "$format")
    
    # Detect native sample rate (using detected format)
    local rate_result=$(detect_native_rate "$device_id" "$channels" "$format")
    local rate=$(echo "$rate_result" | grep -o "[0-9]\+ Hz" | cut -d' ' -f1)
    
    # If no rate found, use default
    if [[ -z "$rate" ]]; then
        rate=48000
    fi
    
    # Calculate appropriate bitrates
    local standard_bitrate=$(calculate_bitrate "$rate" "$channels" "standard")
    local high_bitrate=$(calculate_bitrate "$rate" "$channels" "high")
    
    echo -e "==============================================================
FFmpeg Commands for $device_id
==============================================================
Detected Settings:
- Channel Mode: $channels channel(s)
- Sample Format: $format (FFmpeg format: $ffmpeg_format)
- Sample Rate: $rate Hz
- Standard Bitrate: $standard_bitrate
- High Quality Bitrate: $high_bitrate

Standard quality streaming:
ffmpeg -f alsa -sample_fmt $ffmpeg_format -i $device_id -ar $rate -ac $channels -c:a aac -b:a $standard_bitrate -f rtsp rtsp://server:port/stream_name

High quality streaming:
ffmpeg -f alsa -sample_fmt $ffmpeg_format -i $device_id -ar $rate -ac $channels -c:a libopus -b:a $high_bitrate -vbr on -compression_level 10 -f rtsp rtsp://server:port/stream_name

High quality local recording:
ffmpeg -f alsa -sample_fmt $ffmpeg_format -i $device_id -ar $rate -ac $channels -c:a flac output_file.flac

Notes:
  - Replace 'server:port/stream_name' with your actual RTSP server details
  - For UDP streaming, replace '-f rtsp rtsp://...' with '-f rtp rtp://...'
  - For local testing, you can use '-f null -' instead of streaming
"
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            echo "Enhanced FFmpeg Command Generator"
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -h, --help        Show this help message"
            echo "  --device DEV_ID   Generate commands for specific device (e.g., hw:1,0)"
            echo "  --add-device DEV_ID:CHANNELS"
            echo "                    Add device with specified channel count (e.g., hw:3,0:2)"
            echo "  --list            List configured devices"
            exit 0
            ;;
        --device)
            SPECIFIC_DEVICE="$2"
            shift 2
            ;;
        --add-device)
            if [[ "$2" =~ ^([^:]+):([0-9]+)$ ]]; then
                NEW_DEVICE="${BASH_REMATCH[1]}"
                NEW_CHANNELS="${BASH_REMATCH[2]}"
                DEVICE_CHANNELS["$NEW_DEVICE"]=$NEW_CHANNELS
                echo "Added device $NEW_DEVICE with $NEW_CHANNELS channel(s)"
            else
                echo "Error: Invalid device format. Use --add-device hw:X,Y:N where N is channels"
                exit 1
            fi
            shift 2
            ;;
        --list)
            echo "Configured devices:"
            for dev in "${!DEVICE_CHANNELS[@]}"; do
                echo "  $dev: ${DEVICE_CHANNELS[$dev]} channel(s)"
            done
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Process devices based on command line arguments
if [[ -n "$SPECIFIC_DEVICE" ]]; then
    if [[ -n "${DEVICE_CHANNELS[$SPECIFIC_DEVICE]}" ]]; then
        generate_commands "$SPECIFIC_DEVICE"
    else
        echo "Error: Device $SPECIFIC_DEVICE not configured"
        echo "Configured devices:"
        for dev in "${!DEVICE_CHANNELS[@]}"; do
            echo "  $dev: ${DEVICE_CHANNELS[$dev]} channel(s)"
        done
        exit 1
    fi
else
    # Process all configured devices
    for device in "${!DEVICE_CHANNELS[@]}"; do
        generate_commands "$device"
        echo ""
    done
fi

exit 0
