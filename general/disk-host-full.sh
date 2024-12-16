#!/bin/bash

# This script checks if your disks are reaching a specified usage threshold 
# and sends an email alert if any disks are critically full.

# Set the percent-full threshold for triggering an alert (default: 99%)
THRESHOLD=99

# Load environment variables, such as EMAIL, from an external file
# Ensure /root/scripts/script_env is secure (permissions 600) and contains:
# EMAIL="your-email@example.com"
source /root/scripts/script_env

# Get disk usage information, excluding certain types (e.g., tmpfs, cdrom)
# Parse output to identify filesystems exceeding the threshold
dusage=$(df -Ph | grep -vE '^tmpfs|cdrom' | sed 's/%//g' | awk -v THRESHOLD=$THRESHOLD '{ if ($5 >= THRESHOLD) print $0; }')

# Count the number of filesystems exceeding the threshold
fscount=$(echo "$dusage" | wc -l)

# If at least one filesystem exceeds the threshold, send an email alert
if [ $fscount -gt 1 ]; then
    # Send email with disk usage details
    echo "$dusage" | mail -s "Disk Space Alert on $(hostname) at $(date)" $EMAIL
fi
