#!/bin/bash

###############################################################
#          Customize the shell to my liking
###############################################################

#!/bin/bash

# Path to .bashrc
BASHRC="$HOME/.bashrc"

# The exact aliases we want
ALIAS_LL="alias ll='ls \$LS_OPTIONS -al'"
ALIAS_L="alias l='ls \$LS_OPTIONS -og'"

# Function to check if an exact alias exists
check_alias_exists() {
    local alias_to_check="$1"
    grep -Fx "$alias_to_check" "$BASHRC" >/dev/null
    return $?
}

# Check if both aliases already exist as expected
if check_alias_exists "$ALIAS_LL" && check_alias_exists "$ALIAS_L"; then
    echo "Both aliases already exist with the expected values. No changes needed."
    exit 0
fi

# If we get here, at least one alias needs to be updated
echo "Updating aliases..."

# Backup the original file
cp "$BASHRC" "$BASHRC.backup"

# Comment out existing ll and l aliases
sed -i.bak '/^alias ll=/s/^/# /' "$BASHRC"
sed -i.bak '/^alias l=/s/^/# /' "$BASHRC"

# Add new aliases at the end of the file
echo "" >> "$BASHRC"
echo "# Added new aliases" >> "$BASHRC"
echo "$ALIAS_LL" >> "$BASHRC"
echo "$ALIAS_L" >> "$BASHRC"

echo "Aliases have been updated in $BASHRC"
echo "A backup has been created at $BASHRC.backup"
echo "Please run 'source ~/.bashrc' or start a new terminal session to apply changes"

###############################################################
#          Fix vim.tiny so arrow keys work
###############################################################
echo "set nocompatible" > ~/.vimrc
echo "vim.tiny arrow key fix applied"
