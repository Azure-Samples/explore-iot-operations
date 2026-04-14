#!/bin/bash

# ============================================================================
# Azure IoT Operations - Configuration Backup Tool
# ============================================================================
# This script backs up Azure IoT Operations installation files to USB/SD drive
# 
# Files backed up:
#   - linux_installer*.log (all installation logs)
#   - cluster_info.json
#   - aio_config.json
#
# Usage:
#   ./backup_aio_configs.sh
#
# Output:
#   Files saved to: <USB_DRIVE>/linux_aio/
#
# Author: Azure IoT Operations Team
# Date: January 2026
# Version: 1.0.0
# ============================================================================

set -e  # Exit on error

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo "=========================================="
echo "Azure IoT Operations Backup Tool"
echo "=========================================="
echo ""

# Configuration files to backup
CONFIG_FILE="aio_config.json"
CLUSTER_INFO="cluster_info.json"

echo "Looking for configuration files..."
echo ""

# Find the configuration files
CONFIG_PATH=""
CLUSTER_INFO_PATH=""
LOG_FILES=()

# Search in script directory and parent
SEARCH_DIRS=(
    "$SCRIPT_DIR/edge_configs"
    "$SCRIPT_DIR"
    "$SCRIPT_DIR/.."
    "$HOME/azure-iot-operations"
    "/opt/azure-iot-operations"
)

echo "Searching for cluster_info.json..."
for dir in "${SEARCH_DIRS[@]}"; do
    if [ -f "$dir/$CLUSTER_INFO" ]; then
        CLUSTER_INFO_PATH="$dir/$CLUSTER_INFO"
        echo "  ✓ Found: $CLUSTER_INFO_PATH"
        break
    fi
done

if [ -z "$CLUSTER_INFO_PATH" ]; then
    echo "  ✗ Not found in any search directory"
fi

echo ""
echo "Searching for aio_config.json..."
for dir in "${SEARCH_DIRS[@]}"; do
    if [ -f "$dir/$CONFIG_FILE" ]; then
        CONFIG_PATH="$dir/$CONFIG_FILE"
        echo "  ✓ Found: $CONFIG_PATH"
        break
    fi
done

if [ -z "$CONFIG_PATH" ]; then
    echo "  ✗ Not found in any search directory"
fi

echo ""
echo "Searching for installation logs (linux_installer*.log)..."
for dir in "${SEARCH_DIRS[@]}"; do
    if [ -d "$dir" ]; then
        while IFS= read -r -d '' log_file; do
            LOG_FILES+=("$log_file")
            echo "  ✓ Found: $log_file"
        done < <(find "$dir" -maxdepth 1 -name "linux_installer*.log" -print0 2>/dev/null)
    fi
done

if [ ${#LOG_FILES[@]} -eq 0 ]; then
    echo "  ✗ No log files found"
else
    echo "  ✓ Found ${#LOG_FILES[@]} log file(s)"
fi

echo ""

# Check if any files were found
if [ -z "$CLUSTER_INFO_PATH" ] && [ -z "$CONFIG_PATH" ] && [ ${#LOG_FILES[@]} -eq 0 ]; then
    echo -e "${RED}ERROR: No configuration files found!${NC}"
    echo ""
    echo "Please ensure you have run the installer and the following files exist:"
    echo "  - aio_config.json"
    echo "  - cluster_info.json"
    echo "  - linux_installer*.log"
    echo ""
    exit 1
fi

# Display warning if some files are missing
if [ -z "$CLUSTER_INFO_PATH" ]; then
    echo -e "${YELLOW}WARNING: cluster_info.json not found. This file may not have been created yet.${NC}"
fi

if [ -z "$CONFIG_PATH" ]; then
    echo -e "${YELLOW}WARNING: aio_config.json not found. Configuration may be using defaults.${NC}"
fi

if [ ${#LOG_FILES[@]} -eq 0 ]; then
    echo -e "${YELLOW}WARNING: No installation logs found. Logs may have been moved or deleted.${NC}"
fi

echo ""
echo "=========================================="
echo "Detecting USB/SD drives..."
echo "=========================================="
echo ""

# Detect removable drives (USB/SD)
DRIVES=()
DRIVE_LABELS=()

# Method 1: Using lsblk (most reliable on Linux)
if command -v lsblk &> /dev/null; then
    while IFS= read -r line; do
        # Parse lsblk output: NAME, SIZE, TYPE, MOUNTPOINT, LABEL
        name=$(echo "$line" | awk '{print $1}')
        size=$(echo "$line" | awk '{print $2}')
        mountpoint=$(echo "$line" | awk '{print $3}')
        label=$(echo "$line" | awk '{print $4}')
        
        if [ -n "$mountpoint" ] && [ "$mountpoint" != "MOUNTPOINT" ]; then
            DRIVES+=("$mountpoint")
            if [ -n "$label" ]; then
                DRIVE_LABELS+=("$label ($size) - $mountpoint")
            else
                DRIVE_LABELS+=("$name ($size) - $mountpoint")
            fi
        fi
    done < <(
        for disk in $(lsblk -dpno NAME | grep -E "sd[b-z]|mmcblk"); do
            lsblk -no NAME,SIZE,MOUNTPOINT,LABEL "$disk" | grep -E "part|disk" | grep -v "^$(basename "$disk") "
        done
    )
fi

# Method 2: Fallback - check common mount points
if [ ${#DRIVES[@]} -eq 0 ]; then
    echo "Using fallback method to detect drives..."
    for mount_point in /media/$USER/* /mnt/*; do
        if [ -d "$mount_point" ] && mountpoint -q "$mount_point" 2>/dev/null; then
            size=$(df -h "$mount_point" | tail -1 | awk '{print $2}')
            DRIVES+=("$mount_point")
            DRIVE_LABELS+=("$(basename "$mount_point") ($size) - $mount_point")
        fi
    done
fi

# Check if any drives were found
if [ ${#DRIVES[@]} -eq 0 ]; then
    echo -e "${RED}ERROR: No USB or SD drives detected!${NC}"
    echo ""
    echo "Would you like to mount a drive now? (y/n)"
    read -p "> " mount_choice
    
    if [ "$mount_choice" != "y" ] && [ "$mount_choice" != "Y" ]; then
        echo "Exiting. Please mount a drive and run this script again."
        exit 1
    fi
    
    echo ""
    echo "=========================================="
    echo "Manual Drive Mounting"
    echo "=========================================="
    echo ""
    
    # List all block devices
    echo "Available block devices:"
    lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,LABEL
    echo ""
    
    # Prompt for device to mount
    read -p "Enter device name to mount (e.g., sdb1): " device_name
    
    if [ ! -b "/dev/$device_name" ]; then
        echo -e "${RED}ERROR: Device /dev/$device_name not found!${NC}"
        exit 1
    fi
    
    # Create mount point
    mount_point="/mnt/backup_drive"
    sudo mkdir -p "$mount_point"
    
    # Mount the device
    echo "Mounting /dev/$device_name to $mount_point..."
    if sudo mount "/dev/$device_name" "$mount_point"; then
        echo -e "${GREEN}✓ Drive mounted successfully${NC}"
        DRIVES+=("$mount_point")
        DRIVE_LABELS+=("$device_name - $mount_point")
    else
        echo -e "${RED}ERROR: Failed to mount drive${NC}"
        exit 1
    fi
    
    echo ""
fi

# Display available drives
echo "Found ${#DRIVES[@]} drive(s):"
echo ""
for i in "${!DRIVES[@]}"; do
    echo "  $((i+1)). ${DRIVE_LABELS[$i]}"
done
echo ""

# Prompt user to select a drive
SELECTED_DRIVE=""
while true; do
    read -p "Select drive number (1-${#DRIVES[@]}): " selection
    
    if [ "$selection" -ge 1 ] && [ "$selection" -le "${#DRIVES[@]}" ]; then
        SELECTED_DRIVE="${DRIVES[$((selection-1))]}"
        break
    else
        echo "Invalid selection. Please enter a number between 1 and ${#DRIVES[@]}."
    fi
done

echo ""
echo "Selected drive: $SELECTED_DRIVE"
echo ""

# Create backup directory on the drive
BACKUP_DIR="$SELECTED_DRIVE/linux_aio"
TIMESTAMP=$(date +'%Y%m%d_%H%M%S')
BACKUP_SUBDIR="$BACKUP_DIR/backup_$TIMESTAMP"

echo "Saving to: $BACKUP_SUBDIR"
sudo mkdir -p "$BACKUP_SUBDIR"

# Copy configuration files
echo ""
echo "=========================================="
echo "Copying files to USB..."
echo "=========================================="
echo ""

SUCCESS_COUNT=0
FAIL_COUNT=0

# Copy cluster_info.json
if [ -n "$CLUSTER_INFO_PATH" ]; then
    echo "Copying $(basename "$CLUSTER_INFO_PATH")..."
    if sudo cp "$CLUSTER_INFO_PATH" "$BACKUP_SUBDIR/"; then
        echo "  ✓ Saved"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "  ✗ Failed"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
fi

# Copy aio_config.json
if [ -n "$CONFIG_PATH" ]; then
    echo "Copying $(basename "$CONFIG_PATH")..."
    if sudo cp "$CONFIG_PATH" "$BACKUP_SUBDIR/"; then
        echo "  ✓ Saved"
        SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
    else
        echo "  ✗ Failed"
        FAIL_COUNT=$((FAIL_COUNT + 1))
    fi
fi

# Copy all log files
if [ ${#LOG_FILES[@]} -gt 0 ]; then
    echo "Copying installation logs..."
    for log_file in "${LOG_FILES[@]}"; do
        echo "  - $(basename "$log_file")"
        if sudo cp "$log_file" "$BACKUP_SUBDIR/"; then
            echo "    ✓ Saved"
            SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
        else
            echo "    ✗ Failed"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi
    done
fi

# Create a README file with backup information
README_FILE="$BACKUP_SUBDIR/README.txt"
cat <<EOF | sudo tee "$README_FILE" > /dev/null
Azure IoT Operations - Backup Information
==========================================

Backup created: $(date)
Hostname: $(hostname)
User: $USER

Files in this backup:
EOF

if [ -n "$CLUSTER_INFO_PATH" ]; then
    echo "  - cluster_info.json (cluster connection information)" | sudo tee -a "$README_FILE" > /dev/null
fi

if [ -n "$CONFIG_PATH" ]; then
    echo "  - aio_config.json (installation configuration)" | sudo tee -a "$README_FILE" > /dev/null
fi

if [ ${#LOG_FILES[@]} -gt 0 ]; then
    echo "  - linux_installer*.log (installation logs)" | sudo tee -a "$README_FILE" > /dev/null
fi

cat <<EOF | sudo tee -a "$README_FILE" > /dev/null

To restore these files on another system:
1. Copy files to the linux_build directory
2. Run: ./external_configurator.sh --cluster-info cluster_info.json

For more information, see:
  linux_build/docs/backup_restore_guide.md
EOF

echo ""
echo "=========================================="
echo "Backup Summary"
echo "=========================================="
echo ""
echo -e "${GREEN}Successfully backed up: $SUCCESS_COUNT file(s)${NC}"

if [ $FAIL_COUNT -gt 0 ]; then
    echo -e "${RED}Failed to backup: $FAIL_COUNT file(s)${NC}"
fi

echo ""
echo "Backup location: $BACKUP_SUBDIR"
echo ""

# List all files in backup
echo "Files in backup:"
sudo ls -lh "$BACKUP_SUBDIR"

echo ""
echo "=========================================="
echo "Backup Complete!"
echo "=========================================="
echo ""

# Unmount the drive
echo "Unmounting drive..."
if sudo umount "$SELECTED_DRIVE"; then
    echo -e "${GREEN}✓ Drive unmounted successfully${NC}"
    echo ""
    echo "It is now safe to remove the USB/SD drive."
else
    echo -e "${YELLOW}WARNING: Failed to unmount drive${NC}"
    echo "The drive may be in use. Please manually unmount before removing:"
    echo "  sudo umount $SELECTED_DRIVE"
fi

echo ""

exit 0
