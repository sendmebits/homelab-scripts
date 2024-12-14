#!/bin/bash
# This script checks the health of specified disks using SMART data
# It logs errors and optionally sends email alerts if issues are detected.

# Load script environment variables, ensure this file contains EMAIL or other needed environment variables
source /root/scripts/script_env

# Define a friendly name for this machine
mname="Proxmox"

# Temporary directory for storing the error log
logloc="/root/scripts"

mkdir -p "$logloc"  # Ensure the directory exists

# Default: Do not send emails unless errors are found
sendm="0"

# List of disks to check, customize as needed
disks="/dev/sda
/dev/sdb
/dev/sdc
/dev/sdd"

# Ensure required commands are accessible
PATH="$PATH:/usr/bin:/usr/sbin"

# Commands required for this script to run
needed_commands="smartctl awk mail"

# Check if all required programs are installed
for command in $needed_commands; do
  if ! command -v "$command" > /dev/null 2>&1; then
    echo "Error: Required command '$command' not found. Please install it." >&2
    exit 1
  fi
done

# Check the health of each disk
for disk in $disks; do
  # Extract SMART attributes: Reallocated Sector Count and Seek Error Rate
  declare -a status=($(smartctl -a -d ata "$disk" | awk '/Reallocated_Sector_Ct|Seek_Error_Rate/ { print $2" "$NF }'))

  # Check if Reallocated Sector Count is non-zero
  if [ "${status[1]}" -ne 0 ]; then
    # Log the error details
    echo "$mname Warning: Disk $disk has errors! ${status[0]} ${status[1]} ${status[2]} ${status[3]}. Full SMART output follows:" >> "$logloc/diskerror.log"
    smartctl -a -d ata "$disk" >> "$logloc/diskerror.log"
    failed+=("$disk")  # Track failed disks
    sendm="1"          # Trigger email alert
  fi
done

# Send email alert if any disk failed
if [ "$sendm" == "1" ]; then
  fdisks="${failed[*]}"
  mail -s "$mname Alert: Disk(s) $fdisks may fail!" "$EMAIL" < "$logloc/diskerror.log"
  rm -f "$logloc/diskerror.log"  # Clean up log file
fi
