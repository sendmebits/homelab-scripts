#!/bin/bash
# This is a post install script for Proxmox LXC's to automatically apply customizations after deployment
# Author: sendmebits
# License: MIT

function header_info {
clear
cat <<"EOF"
  _____          _     _____           _        _ _
 |  __ \        | |   |_   _|         | |      | | |
 | |__) |__  ___| |_    | |  _ __  ___| |_ __ _| | |
 |  ___/ _ \/ __| __|   | | | '_ \/ __| __/ _` | | |
 | |  | (_) \__ \ |_   _| |_| | | \__ \ || (_| | | |
 |_|   \___/|___/\__| |_____|_| |_|___/\__\__,_|_|_|

EOF
}
###############################################################
#          Add shell "export LS_OPTIONS"
###############################################################
function shell_colour {

# Check if the line exists and is commented
if grep -q "^# export LS_OPTIONS='--color=auto'" "$HOME/.bashrc"; then
    # Uncomment the line by removing the leading #
    sed -i "s/^# export LS_OPTIONS='--color=auto'/export LS_OPTIONS='--color=auto'/" "$HOME/.bashrc"
    echo "Uncommented \"export LS_OPTIONS\" in $HOME/.bashrc"
else
    echo "\"export LS_OPTIONS\" is already uncommented or doesn't exist in $HOME/.bashrc"
fi
}

###############################################################
#          Customize the shell ls to my liking
###############################################################
function shell_ls_settings {

# The exact aliases we want
ALIAS_LL="alias ll='ls \$LS_OPTIONS -al'"
ALIAS_L="alias l='ls \$LS_OPTIONS -og'"

# Function to check if an exact alias exists
check_alias_exists() {
    local alias_to_check="$1"
    grep -Fx "$alias_to_check" "$HOME/.bashrc" >/dev/null
    return $?
}

# Check if both aliases already exist as expected
if check_alias_exists "$ALIAS_LL" && check_alias_exists "$ALIAS_L"; then
    echo "Both ls aliases already exist with the expected values. No changes needed."
    return 0
fi

# If we get here, at least one alias needs to be updated
echo "Updating aliases..."

# Backup the original file
cp "$HOME/.bashrc" "$HOME/.bashrc.backup"

# Comment out existing ll and l aliases
sed -i.bak '/^alias ll=/s/^/# /' "$HOME/.bashrc"
sed -i.bak '/^alias l=/s/^/# /' "$HOME/.bashrc"

# Add new aliases at the end of the file
echo "" >> "$BASHRC"
echo "# Custom aliases" >> "$BASHRC"
echo "$ALIAS_LL" >> "$BASHRC"
echo "$ALIAS_L" >> "$BASHRC"

echo "Aliases have been updated in $BASHRC"
echo "A backup has been created at $BASHRC.backup"
echo "Please run 'source ~/.bashrc' or start a new terminal session to apply changes"
}

###############################################################
#          Fix vim.tiny so arrow keys work
###############################################################
function vi_settings {
VIM_SETTING="set nocompatible"

# Check if the line exists
if [ ! -f "$HOME/.vimrc" ] || ! grep -qF "$VIM_SETTING" "$HOME/.vimrc"; then
        echo $VIM_SETTING > $HOME/.vimrc
        echo "vim.tiny arrow key fix applied"
else
        echo "vi already configured correctly, no updates needed."
fi
}

# Run all the things
header_info
shell_colour
shell_ls_settings
vi_settings
