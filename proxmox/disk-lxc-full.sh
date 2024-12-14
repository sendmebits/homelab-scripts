#!/bin/bash

# This script checks all running LXC containers from a Proxmox host to ensure their disks aren't too full.
# Usage: Run this script hourly to check frequently for disks that are full and in trouble!

# Error handling
set -euo pipefail

# Threshold for disk usage alert
THRESHOLD=${THRESHOLD:-98}                

# Load script environment variables, ensure this file contains EMAIL or other needed environment variables
source /root/scripts/script_env

# Extract disk usage data for LXC containers
dusage=$(/usr/sbin/lvs --noheadings --units g -o lv_name,lv_size,data_percent |
    grep -vF 'root' | grep -vF 'swap' | grep -vF 'snap_vm' | 
    awk -v threshold="$THRESHOLD" '{ if($3 + 0 > threshold) print $1, $2, $3; }' |
    while read -r lvname lvsize datapercent; do
        lxcid=$(echo "$lvname" | awk -F'-' '{print $2}')
        lxcname=$(pct list | awk -v id="$lxcid" '$1 == id {print $3}')
        if [ -z "$lxcname" ]; then lxcname="Unknown"; fi
        echo "$lxcname | ID: $lxcid | Size: $lvsize | Usage: $datapercent"
    done)

fscount=$(echo "$dusage" | wc -l)

# If any container exceeds the threshold, send an email
if [ -n "$dusage" ]; then
    {
        echo "Warning: High disk usage detected on $fscount container(s):"
        echo
        echo "$dusage"
    } | mail -s "Disk Space Warning on $(hostname) - $fscount Container(s) Exceeding $THRESHOLD%" "$EMAIL"
fi
