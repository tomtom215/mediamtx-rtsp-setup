#!/bin/bash

# FFmpeg Audio Diagnostics
# A standalone diagnostic tool for audio devices on Linux systems

# Check if running with sudo/root
if [[ $EUID -ne 0 ]]; then
   echo "This script requires elevated privileges to access all system information."
   echo "Please run with sudo:"
   echo "sudo $0"
   exit 1
fi

echo "Audio Device Diagnostics Tool"
echo "============================"
echo "Scanning system for audio devices and potential issues..."
echo ""

# System Information
echo "SYSTEM INFORMATION:"
echo "------------------"
echo "Date: $(date)"
echo "Hostname: $(hostname)"
echo "Linux Kernel: $(uname -r)"
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    echo "Distribution: $PRETTY_NAME"
fi
echo "ALSA Version: $(cat /proc/asound/version 2>/dev/null || echo "Unknown")"
echo ""

# Audio Devices
echo "AUDIO DEVICES:"
echo "-------------"
echo "Capture Devices (Microphones):"
arecord -l || echo "No capture devices detected or arecord not available"
echo ""
echo "Playback Devices (Speakers):"
aplay -l || echo "No playback devices detected or aplay not available"
echo ""

# USB Information
echo "USB TOPOLOGY:"
echo "------------"
if command -v lsusb &> /dev/null; then
    echo "USB Device Tree:"
    lsusb -t || echo "Unable to retrieve USB device tree"
    echo ""
    echo "USB Audio Devices:"
    lsusb | grep -i "audio\|microphone" || echo "No USB audio devices detected"
else
    echo "lsusb not available - please install usbutils package"
fi
echo ""

# Audio Hardware Details
echo "AUDIO HARDWARE DETAILS:"
echo "---------------------"
echo "ALSA Cards:"
cat /proc/asound/cards || echo "Unable to retrieve ALSA card information"
echo ""

# Audio Processes
echo "AUDIO PROCESSES:"
echo "--------------"
echo "Processes using audio devices:"
if command -v fuser &> /dev/null; then
    fuser -v /dev/snd/* 2>/dev/null || echo "No processes currently using audio devices"
else
    echo "fuser command not available - please install psmisc package"
fi
echo ""

# Check for potential issues
echo "ISSUE DETECTION:"
echo "--------------"

# Check for USB bandwidth issues
if command -v lsusb &> /dev/null; then
    AUDIO_DEVICE_COUNT=$(lsusb | grep -i "audio\|microphone" | wc -l)
    echo "USB Audio Device Count: $AUDIO_DEVICE_COUNT"
    if [[ $AUDIO_DEVICE_COUNT -gt 4 ]]; then
        echo "WARNING: Large number of audio devices detected. USB bandwidth may be constrained."
        echo "         Consider distributing devices across different USB controllers."
    fi
    
    # Check for USB hub overloading
    usb_hubs=$(lsusb | grep -i "hub")
    if [[ -n "$usb_hubs" ]]; then
        echo "USB Hubs:"
        echo "$usb_hubs"
        echo ""
        echo "Checking for hub overloading..."
        
        while read -r hub_line; do
            if [[ "$hub_line" =~ Bus\ ([0-9]+)\ Device\ ([0-9]+): ]]; then
                hub_bus="${BASH_REMATCH[1]}"
                hub_device="${BASH_REMATCH[2]}"
                hub_path=$(find /sys/bus/usb/devices -name "$hub_bus-$hub_device" -o -name "$hub_bus-$hub_device.*" | head -1)
                
                if [[ -n "$hub_path" ]]; then
                    # Count devices on this hub
                    devices_on_hub=$(find "$hub_path" -type d -name "$hub_bus-*" | wc -l)
                    echo "Hub on Bus $hub_bus Device $hub_device has approximately $devices_on_hub devices connected"
                    
                    if [[ $devices_on_hub -gt 3 ]]; then
                        echo "WARNING: Hub on Bus $hub_bus Device $hub_device may be overloaded with devices."
                    fi
                fi
            fi
        done <<< "$usb_hubs"
    fi
fi

# Check for ALSA configuration issues
if ! command -v alsactl &>/dev/null; then
    echo "WARNING: alsactl not found. ALSA may not be properly installed."
else
    alsactl_version=$(alsactl -v 2>&1)
    if [[ $? -ne 0 ]]; then
        echo "WARNING: ALSA control interface not working properly."
    else
        echo "ALSA Control: $alsactl_version"
    fi
fi

# Check for IRQ conflicts
if [[ -f /proc/interrupts ]]; then
    echo ""
    echo "Audio IRQ Assignments:"
    grep -i "snd\|audio" /proc/interrupts || echo "No audio-specific IRQs found"
fi

# Kernel USB and Audio module status
echo ""
echo "KERNEL MODULES:"
echo "--------------"
lsmod | grep -E "snd|audio|usb" | sort || echo "Unable to retrieve module information"

echo ""
echo "RECOMMENDATIONS:"
echo "--------------"
echo "Based on the diagnostic scan:"

if [[ $AUDIO_DEVICE_COUNT -gt 3 ]]; then
    echo "1. For multiple USB audio devices, distribute them across different USB controllers or ports"
    echo "2. Use powered USB hubs for better stability"
    echo "3. Consider standard sample rates (48000 Hz) and bit depths (16-bit) for better compatibility"
    echo "4. Implement staged initialization with delays between devices"
    echo "5. Use fallback mechanisms for error recovery"
else
    echo "1. Your setup appears to have a standard number of audio devices"
    echo "2. For optimal quality, test various sample rates and bit depths"
    echo "3. Ensure your FFmpeg builds include support for all required codecs"
fi

echo ""
echo "For FFmpeg streaming recommendations for specific devices, run:"
echo "./ffmpeg-audio-recommender.sh [device_id]"
echo ""

echo "Diagnostics complete."
echo "===================="

exit 0
