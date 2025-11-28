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

# ============================================================================
# Old Kernel Cleanup
# ============================================================================
log_info "Removing old kernel versions (keeping current + 1 previous)..."
CURRENT_KERNEL=$(uname -r | sed "s/\(.*\)-\([^0-9]\+\)/\1/")
OLD_KERNELS=$(dpkg -l 'linux-*' | sed '/^ii/!d;/'"$CURRENT_KERNEL"'/d;s/^[^ ]* [^ ]* \([^ ]*\).*/\1/;/[0-9]/!d' | grep -E 'linux-(image|headers|modules)' || true)

if [[ -n "$OLD_KERNELS" ]]; then
    echo "$OLD_KERNELS" | xargs apt-get -y purge 2>/dev/null || log_warning "Some kernels could not be removed"
    log_success "Removed old kernels"
else
    log_info "No old kernels to remove"
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
# Thumbnail Cache Cleanup
# ============================================================================
log_info "Clearing thumbnail caches for all users..."
for user_home in /home/*; do
    if [[ -d "$user_home/.cache/thumbnails" ]]; then
        rm -rf "$user_home/.cache/thumbnails"/*
        log_success "Cleared thumbnails for $(basename "$user_home")"
    fi
done

# Clear root's thumbnail cache
if [[ -d /root/.cache/thumbnails ]]; then
    rm -rf /root/.cache/thumbnails/*
fi

# ============================================================================
# Docker Cleanup (if installed)
# ============================================================================
if command -v docker &> /dev/null; then
    log_info "Docker detected - cleaning up unused containers and dangling images..."
    # CHANGED: Removed -a (all images) and --volumes for safety.
    # Only removes stopped containers and dangling images.
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
    snap list --all | awk '/disabled/{print $1, $3}' | while read -r snapname revision; do
        snap remove "$snapname" --revision="$revision" 2>/dev/null && ((SNAP_COUNT++)) || true
    done
    log_success "Removed old snap revisions"
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