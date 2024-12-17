#!/bin/bash
# Proxmox Backup Script
# Description: This script backs up PVE config data and key scripts to the backup directory.
# Author: sendmebits
# License: MIT

# Set the folder where you want the backup to go
BACKUP_DIR="/mnt/pve/backup/pve_backup"

# Sets a unique timestamp for the backup file name
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Load script environment variables, ensure this file contains EMAIL or other needed environment variables
source /root/scripts/script_env

# Ensure the backup directory exists
mkdir -p "$BACKUP_DIR"

# Define directories/files to include in the backup
INCLUDE=(
    "/etc/pve"          # Proxmox configuration
    /root/*.sh        # Custom scripts in the root folder
    "/root/scripts"     # Monitoring scripts directory to back up
)

# Backup command with validation
tar -czf "$BACKUP_DIR/proxmox_backup_$TIMESTAMP.tar.gz" "${INCLUDE[@]}" 2> /dev/null

# Check if the tar command succeeded
if [[ $? -eq 0 ]]; then
    echo "ProxmoxVE backup successful: $BACKUP_DIR/proxmox_backup_$TIMESTAMP.tar.gz" | mail -s "Proxmox Backup Successful" $EMAIL
else
        echo "ProxmoxVE backup failed. Check the logs or permissions." | mail -s "Proxmox Backup Failed" $EMAIL
        exit 1
fi
