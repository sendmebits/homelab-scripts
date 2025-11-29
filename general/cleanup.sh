#!/bin/bash
#
# General Linux cleanup script for Debian/Ubuntu
# Performs comprehensive system cleanup with safety checks
#

set -e  # Exit on error
set -u  # Exit on undefined variable

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root or with sudo"
   exit 1
fi

log_info "Starting system cleanup..."
echo ""

# Get initial disk usage
INITIAL_USAGE=$(df / | awk 'NR==2 {print $3}')

# ============================================================================
# APT Package Manager Cleanup
# ============================================================================
log_info "Updating package lists..."
apt-get update -qq

log_info "Removing unnecessary packages (autoremove)..."
apt-get -y autoremove --purge

log_info "Cleaning apt cache..."
apt-get -y clean

log_info "Removing outdated cached packages..."
apt-get -y autoclean

log_info "Purging packages in 'rc' state (removed but config remains)..."
RC_PACKAGES=$(dpkg -l | awk '/^rc/ {print $2}')
if [[ -n "$RC_PACKAGES" ]]; then
    echo "$RC_PACKAGES" | xargs apt-get -y purge
    log_success "Purged residual config packages"
else
    log_info "No residual config packages found"
fi

log_info "Clearing downloaded package list files..."
rm -rf /var/lib/apt/lists/*

if [ -f /var/run/reboot-required ]; then
    log_warning "A system reboot is required! Newly installed kernels might not be active yet."
fi

# ============================================================================
# Systemd Journal Cleanup
# ============================================================================
log_info "Truncating systemd journal logs (keeping last 7 days)..."
journalctl --vacuum-time=7d

log_info "Limiting journal size to 100MB..."
journalctl --vacuum-size=100M

# ============================================================================
# Log Files Cleanup
# ============================================================================
log_info "Removing old rotated log files..."
find /var/log -type f -name "*.gz" -delete 2>/dev/null || true
find /var/log -type f -name "*.1" -delete 2>/dev/null || true
find /var/log -type f -name "*.old" -delete 2>/dev/null || true
log_success "Removed old rotated logs"

# ============================================================================
# Systemd Coredumps Cleanup
# ============================================================================
if [[ -d /var/lib/systemd/coredump ]]; then
    log_info "Removing systemd coredumps..."
    rm -rf /var/lib/systemd/coredump/*
    log_success "Removed coredumps"
fi

# ============================================================================
# Man Page Cache Cleanup
# ============================================================================
if [[ -d /var/cache/man ]]; then
    log_info "Clearing man page cache..."
    rm -rf /var/cache/man/*
    log_success "Cleared man page cache"
fi

# ============================================================================
# Trash/Recycle Bin Cleanup
# ============================================================================
log_info "Emptying trash for all users..."
TRASH_CLEANED=0
for user_home in /home/*; do
    if [[ -d "$user_home/.local/share/Trash" ]]; then
        rm -rf "$user_home/.local/share/Trash"/* 2>/dev/null || true
        ((TRASH_CLEANED++))
    fi
done

# Clear root's trash
if [[ -d /root/.local/share/Trash ]]; then
    rm -rf /root/.local/share/Trash/* 2>/dev/null || true
fi

if [[ $TRASH_CLEANED -gt 0 ]]; then
    log_success "Emptied trash for $TRASH_CLEANED user(s)"
else
    log_info "No trash to clean"
fi

# ============================================================================
# Crash Reports Cleanup
# ============================================================================
if [[ -d /var/crash ]]; then
    log_info "Removing old crash reports..."
    CRASH_COUNT=$(find /var/crash -type f 2>/dev/null | wc -l)
    if [[ $CRASH_COUNT -gt 0 ]]; then
        rm -rf /var/crash/* 2>/dev/null || true
        log_success "Removed $CRASH_COUNT crash report(s)"
    else
        log_info "No crash reports to remove"
    fi
fi

# ============================================================================
# APT Partial Downloads Cleanup
# ============================================================================
if [[ -d /var/cache/apt/archives/partial ]]; then
    log_info "Clearing partial APT downloads..."
    rm -rf /var/cache/apt/archives/partial/* 2>/dev/null || true
    log_success "Cleared partial downloads"
fi

# ============================================================================
# Python Pip Cache Cleanup
# ============================================================================
if command -v pip3 &> /dev/null; then
    log_info "Clearing pip3 cache..."
    pip3 cache purge 2>/dev/null || log_warning "Pip cache cleanup had issues"
    log_success "Pip3 cache cleared"
fi

if command -v pip &> /dev/null; then
    log_info "Clearing pip cache..."
    pip cache purge 2>/dev/null || log_warning "Pip cache cleanup had issues"
    log_success "Pip cache cleared"
fi

# ============================================================================
# NPM Cache Cleanup (if Node.js is installed)
# ============================================================================
if command -v npm &> /dev/null; then
    log_info "Clearing npm cache..."
    npm cache clean --force 2>/dev/null || log_warning "NPM cache cleanup had issues"
    log_success "NPM cache cleared"
fi

# ============================================================================
# Reset Failed Systemd Units
# ============================================================================
log_info "Resetting failed systemd units..."
FAILED_COUNT=$(systemctl list-units --state=failed --no-legend 2>/dev/null | wc -l)
if [[ $FAILED_COUNT -gt 0 ]]; then
    systemctl reset-failed 2>/dev/null || true
    log_success "Reset $FAILED_COUNT failed systemd unit(s)"
else
    log_info "No failed systemd units to reset"
fi

# ============================================================================
# Docker Cleanup (if installed)
# ============================================================================
if command -v docker &> /dev/null; then
    log_info "Docker detected - cleaning up unused containers and dangling images..."
    # CHANGED: Removed -a (all images) and --volumes for safety.
    # Only removes stopped containers and dangling images.
    log_warning "This will remove all STOPPED containers. Running containers are safe."
    docker system prune -f 2>/dev/null || log_warning "Docker cleanup had issues"
    log_success "Docker cleanup completed"
else
    log_info "Docker not installed, skipping Docker cleanup"
fi

# ============================================================================
# Snap Cleanup (if installed - common on Ubuntu)
# ============================================================================
if command -v snap &> /dev/null; then
    log_info "Snap detected - removing old snap revisions..."
    SNAP_COUNT=0
    # This loop removes disabled snaps (old versions)
    # Using process substitution to avoid subshell and maintain counter
    while read -r snapname revision; do
        if snap remove "$snapname" --revision="$revision" 2>/dev/null; then
            ((SNAP_COUNT++))
        fi
    done < <(snap list --all | awk '/disabled/{print $1, $3}')
    
    if [[ $SNAP_COUNT -gt 0 ]]; then
        log_success "Removed $SNAP_COUNT old snap revision(s)"
    else
        log_info "No old snap revisions to remove"
    fi
else
    log_info "Snap not installed, skipping snap cleanup"
fi

# ============================================================================
# Flatpak Cleanup (if installed)
# ============================================================================
if command -v flatpak &> /dev/null; then
    log_info "Flatpak detected - removing unused runtimes..."
    flatpak uninstall --unused -y 2>/dev/null || log_warning "Flatpak cleanup had issues"
    log_success "Flatpak cleanup completed"
else
    log_info "Flatpak not installed, skipping flatpak cleanup"
fi

# ============================================================================
# Temporary Files Cleanup
# ============================================================================
log_info "Cleaning old temporary files (older than 7 days)..."
find /tmp -type f -atime +7 -delete 2>/dev/null || true
find /tmp -type d -empty -delete 2>/dev/null || true
log_success "Cleaned old temporary files"

# Clean /var/tmp as well
log_info "Cleaning old /var/tmp files (older than 7 days)..."
find /var/tmp -type f -atime +7 -delete 2>/dev/null || true
find /var/tmp -type d -empty -delete 2>/dev/null || true
log_success "Cleaned old /var/tmp files"

# ============================================================================
# Locale Purge (Optional)
# ============================================================================
if command -v localepurge &> /dev/null; then
    log_info "localepurge detected - removing unused locales..."
    localepurge 2>/dev/null || true
    log_success "Unused locales removed"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
log_info "Cleanup completed!"

# Sync filesystem to ensure changes are written
sync

# Calculate space freed
FINAL_USAGE=$(df / | awk 'NR==2 {print $3}')
SPACE_FREED=$((INITIAL_USAGE - FINAL_USAGE))

if [[ $SPACE_FREED -gt 0 ]]; then
    SPACE_FREED_MB=$((SPACE_FREED / 1024))
    log_success "Freed approximately ${SPACE_FREED_MB}MB of disk space"
else
    log_info "Disk usage calculation: minimal or no space freed (this is normal if system was already clean)"
fi

# Show current disk usage
echo ""
log_info "Current disk usage:"
df -h / | awk 'NR==1 {print $0} NR==2 {printf "  Used: %s / %s (%s)\n", $3, $2, $5}'

echo ""
log_success "All cleanup tasks completed successfully!"