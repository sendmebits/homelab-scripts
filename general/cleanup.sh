#!/bin/bash
#
# General Linux cleanup script for Debian/Ubuntu
# Performs comprehensive system cleanup with safety checks
#
# Usage: sudo ./cleanup.sh
# To update: sudo ./cleanup.sh --update
# Download: curl -fsSL https://raw.githubusercontent.com/sendmebits/homelab-scripts/refs/heads/main/general/cleanup.sh -o cleanup.sh && chmod +x cleanup.sh
#
# Author: sendmebits
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


# ============================================================================
# Self-Update Feature
# ============================================================================
SCRIPT_URL="https://raw.githubusercontent.com/sendmebits/homelab-scripts/refs/heads/main/general/cleanup.sh"
SCRIPT_PATH="$(readlink -f "$0")"
GITHUB_API_URL="https://api.github.com/repos/sendmebits/homelab-scripts/contents/general/cleanup.sh"

# Efficient version check using GitHub API (SHA comparison)
check_for_updates() {
    # Get remote SHA from GitHub API (lightweight JSON response)
    REMOTE_SHA=$(curl -fsSL --max-time 2 "$GITHUB_API_URL" 2>/dev/null | grep -o '"sha": "[^"]*"' | head -1 | cut -d'"' -f4)
    
    if [[ -n "$REMOTE_SHA" ]]; then
        # Calculate local file SHA using git blob format (same as GitHub)
        # Git blob SHA = sha1("blob " + filesize + "\0" + contents)
        LOCAL_SHA=$(printf "blob %s\0" "$(wc -c < "$SCRIPT_PATH")" | cat - "$SCRIPT_PATH" | sha1sum | awk '{print $1}')
        
        if [[ -n "$LOCAL_SHA" ]] && [[ "$REMOTE_SHA" != "$LOCAL_SHA" ]]; then
            log_warning "A newer version of this script is available!"
            log_warning "Run 'sudo $0 --update' to update to the latest version"
        fi
    fi
}

if [[ "${1:-}" == "--update" ]]; then
    log_info "Updating cleanup.sh from GitHub..."
    
    # Create a backup (overwrites previous backup if it exists)
    BACKUP_PATH="${SCRIPT_PATH}.backup"
    cp "$SCRIPT_PATH" "$BACKUP_PATH"
    log_info "Created backup at: $BACKUP_PATH"
    
    # Download the latest version
    if curl -fsSL "$SCRIPT_URL" -o "${SCRIPT_PATH}.tmp"; then
        # Verify the downloaded file is not empty and starts with shebang
        if [[ -s "${SCRIPT_PATH}.tmp" ]] && head -n1 "${SCRIPT_PATH}.tmp" | grep -q "^#!/bin/bash"; then
            mv "${SCRIPT_PATH}.tmp" "$SCRIPT_PATH"
            chmod +x "$SCRIPT_PATH"
            log_success "Script updated successfully!"
            log_info "Backup saved at: $BACKUP_PATH"
            exit 0
        else
            log_error "Downloaded file appears invalid"
            rm -f "${SCRIPT_PATH}.tmp"
            exit 1
        fi
    else
        log_error "Failed to download update from GitHub"
        rm -f "${SCRIPT_PATH}.tmp"
        exit 1
    fi
fi

# Run version check in background to avoid delaying script execution (only during normal cleanup)
check_for_updates &

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   log_error "This script must be run as root or with sudo"
   exit 1
fi

log_info "Starting system cleanup..."

# Get initial disk usage
INITIAL_USAGE=$(df / | awk 'NR==2 {print $3}')


# ============================================================================
# APT Package Manager Cleanup
# ============================================================================
log_info "Removing unnecessary packages (autoremove)..."
apt-get -y autoremove --purge > /dev/null 2>&1
log_success "Unnecessary packages removed"

log_info "Cleaning apt cache..."
apt-get -y clean
log_success "APT cache cleaned"

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
log_success "Package list files cleared"

if [ -f /var/run/reboot-required ]; then
    log_warning "A system reboot is required! Newly installed kernels might not be active yet."
fi

# ============================================================================
# Systemd Journal Cleanup
# ============================================================================
log_info "Truncating systemd journal logs (keeping last 7 days)..."
journalctl --vacuum-time=7d >/dev/null 2>&1
log_success "Journal logs truncated"

log_info "Limiting journal size to 100MB..."
journalctl --vacuum-size=100M >/dev/null 2>&1
log_success "Journal size limited"


# ============================================================================
# Log Files Cleanup
# ============================================================================
log_info "Removing old rotated log files..."
find /var/log -type f \( -name "*.gz" -o -name "*.1" -o -name "*.old" \) -delete 2>/dev/null || true
log_success "Removed old rotated logs"


# ============================================================================
# Systemd Coredumps Cleanup
# ============================================================================
if [[ -d /var/lib/systemd/coredump ]]; then
    log_info "Removing systemd coredumps..."
    rm -rf /var/lib/systemd/coredump/*
    log_success "Removed coredumps"
else
    log_info "No coredump directory found, skipping"
fi


# ============================================================================
# Man Page Cache Cleanup
# ============================================================================
if [[ -d /var/cache/man ]]; then
    log_info "Clearing man page cache..."
    rm -rf /var/cache/man/*
    log_success "Cleared man page cache"
else
    log_info "No man page cache found, skipping"
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
else
    log_info "No partial downloads directory found, skipping"
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
# NPM/Yarn/PNPM Cache Cleanup (if Node.js package managers are installed)
# ============================================================================
log_info "Checking for Node.js package manager caches..."

# Define npm-specific directories to clean
NPM_CACHE_DIRS=(
"$HOME/.npm"
"$HOME/.npm/_logs"
"$HOME/.yarn/cache"
"$HOME/.pnpm-store"
"$HOME/.local/share/pnpm/store"
"$HOME/Library/Caches/yarn"
"$HOME/Library/Caches/pnpm"
)

# Also check for all user home directories
for user_home in /home/*; do
    if [[ -d "$user_home" ]]; then
        NPM_CACHE_DIRS+=(
            "$user_home/.npm"
            "$user_home/.npm/_logs"
            "$user_home/.yarn/cache"
            "$user_home/.pnpm-store"
            "$user_home/.local/share/pnpm/store"
        )
    fi
done

# Function to calculate directory size in KB
calculate_size_kb() {
    if [[ -d "$1" ]]; then
        du -sk "$1" 2>/dev/null | awk '{print $1}'
    else
        echo "0"
    fi
}

# Track total space before cleanup
TOTAL_BEFORE=0
for DIR in "${NPM_CACHE_DIRS[@]}"; do
    SIZE=$(calculate_size_kb "$DIR")
    TOTAL_BEFORE=$((TOTAL_BEFORE + SIZE))
done

# Clean npm-specific cache directories manually
# (We use rm -rf because it is faster and more reliable than the package manager commands for cleanup)
log_info "Removing package manager cache directories..."
DIRS_REMOVED=0
for DIR in "${NPM_CACHE_DIRS[@]}"; do
    if [[ -d "$DIR" ]]; then
        rm -rf "$DIR" 2>/dev/null && ((DIRS_REMOVED++)) || true
    fi
done

if [[ $DIRS_REMOVED -gt 0 ]]; then
    log_success "Removed $DIRS_REMOVED cache director(ies)"
fi

# Track total space after cleanup
TOTAL_AFTER=0
for DIR in "${NPM_CACHE_DIRS[@]}"; do
    SIZE=$(calculate_size_kb "$DIR")
    TOTAL_AFTER=$((TOTAL_AFTER + SIZE))
done

# Calculate and display space freed
NPM_SPACE_FREED=$((TOTAL_BEFORE - TOTAL_AFTER))
if [[ $NPM_SPACE_FREED -gt 0 ]]; then
    NPM_SPACE_FREED_MB=$((NPM_SPACE_FREED / 1024))
    log_success "Package manager cache cleanup freed approximately ${NPM_SPACE_FREED_MB}MB"
else
    log_info "No significant space freed from package manager caches"
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
log_info "${BLUE}═══════════════════════════════════════════════════════${NC}"
log_info "                  Cleanup completed!"
log_info "${BLUE}═══════════════════════════════════════════════════════${NC}"

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
log_info "Current disk usage:"
df -h / | awk -v blue="$BLUE" -v nc="$NC" 'NR==2 {printf "%s[INFO]%s   Used: %s / %s (%s)\n", blue, nc, $3, $2, $5}'

log_success "All cleanup tasks completed successfully!"