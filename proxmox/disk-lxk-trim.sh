#!/bin/bash

# This script performs a disk trim operation for all LXC containers on a Proxmox VE host.
# Disk trim helps reclaim unused space in thin-provisioned storage back to the storage pool.

# Usage:
# - Run this script as a weekly cronjob with requires administrative privileges as `pct` requires that.
# - For containers with frequent write and delete operations, consider running "pct fstrim ###" on just the LXC that requires it.

# The `pct list` command outputs a list of containers on the host and `awk` selects only the container IDs.
# Each container ID is passed to the `pct fstrim` command to perform the trim.

pct list | awk '/^[0-9]/ {print $1}' | while read ct; do
    # Perform disk trim on the current container
    pct fstrim "${ct}" || echo "Failed to trim container ID: ${ct}"
done
