#!/bin/bash
# Description: This is a post install script for Proxmox LXC's to automatically apply customizations after deployment
# Usage: To run that latest version use: 
#     bash -c "$(wget -qLO - https://raw.githubusercontent.com/sendmebits/homelab-scripts/refs/heads/main/lxc/lxc-post-install.sh)"
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
    # Ensure .bashrc exists, create it if not
    if [ ! -f "$HOME/.bashrc" ]; then
        touch "$HOME/.bashrc"
        echo "Created $HOME/.bashrc"
    fi
    
    # Check if the line exists and is commented
    if grep -q "^# export LS_OPTIONS='--color=auto'" "$HOME/.bashrc"; then
        # Uncomment the line by removing the leading #
        sed -i "s/^# export LS_OPTIONS='--color=auto'/export LS_OPTIONS='--color=auto'/" "$HOME/.bashrc"
        echo "Uncommented \"export LS_OPTIONS\" in $HOME/.bashrc"
    
    # Check if the line exists and is already uncommented
    elif grep -q "export LS_OPTIONS='--color=auto'" "$HOME/.bashrc"; then
        echo "\"export LS_OPTIONS\" is already set in $HOME/.bashrc"

    # If the line doesn't exist at all, add it
    else
        echo "export LS_OPTIONS='--color=auto'" >> "$HOME/.bashrc"
        echo "Added \"export LS_OPTIONS\" to $HOME/.bashrc"
    fi
}

###############################################################
#          Customize the shell listings to my liking
###############################################################
function shell_ls_settings {
    # The exact aliases we want
    ALIAS_LL="alias ll='ls \$LS_OPTIONS -al'"
    ALIAS_L="alias l='ls \$LS_OPTIONS -og'"
    
    # Function to check if an exact alias exists, ignoring leading whitespace
    check_alias_exists() {
        local alias_to_check="$1"
        # Print the alias for debugging
        echo "Checking alias: $alias_to_check"
        
        # Use grep to match
        grep -Pq "$alias_to_check" "$HOME/.bashrc" >/dev/null
        return $?
    }
  
    # Function to check and handle 'll' alias
    handle_ll_alias() {
        # Check if 'll' alias exists, allowing leading whitespace
        if grep -Pq '\s*alias ll=' "$HOME/.bashrc"; then
            # Check if it's exactly the desired alias
            if grep -Pq "alias ll='ls \\$LS_OPTIONS -al'" "$HOME/.bashrc"; then
                # Alias already exists exactly as desired
                return 0
            fi

            # If not an exact match, comment out and add new
            sed -i.bak '/^\s*alias ll=.*/s/^/# /' "$HOME/.bashrc"
            
            # Add new 'll' alias at the end
            echo "" >> "$HOME/.bashrc"
            echo "# Custom ll alias" >> "$HOME/.bashrc"
            echo "$ALIAS_LL" >> "$HOME/.bashrc"
            
            echo "Commented old instance and added 'll' alias in $HOME/.bashrc"
            return 1
        else
            # 'll' alias doesn't exist, add it
            echo "" >> "$HOME/.bashrc"
            echo "# Custom ll alias" >> "$HOME/.bashrc"
            echo "$ALIAS_LL" >> "$HOME/.bashrc"
            
            echo "Added 'll' alias in $HOME/.bashrc"
            return 1
        fi
    }
    
    # Function to check and handle 'l' alias
    handle_l_alias() {
        # Check if 'l' alias exists, allowing leading whitespace
        if grep -Pq '\s*alias l=' "$HOME/.bashrc"; then
            # Check if it's exactly the desired alias
            if grep -Pq "alias l='ls \\$LS_OPTIONS -og'" "$HOME/.bashrc"; then
                # Alias already exists exactly as desired
                return 0
            fi

            # If not an exact match, comment out and add new
            sed -i.bak '/^\s*alias l=.*/s/^/# /' "$HOME/.bashrc"
            
            # Add new 'l' alias at the end
            echo "" >> "$HOME/.bashrc"
            echo "# Custom l alias" >> "$HOME/.bashrc"
            echo "$ALIAS_L" >> "$HOME/.bashrc"
            
            echo "Commented old instance and added 'l' alias in $HOME/.bashrc"
            return 1
        else
            # 'l' alias doesn't exist, add it
            echo "" >> "$HOME/.bashrc"
            echo "# Custom l' alias" >> "$HOME/.bashrc"
            echo "$ALIAS_L" >> "$HOME/.bashrc"
            
            echo "Added 'l' alias in $HOME/.bashrc"
            return 1
        fi
    }
    
    # Backup the original file before making changes
    cp "$HOME/.bashrc" "$HOME/.bashrc.backup"
    
    # Track if any changes were made
    changes_made=0
    
    # Handle 'll' alias
    handle_ll_alias
    changes_made=$((changes_made + $?))
    
    # Handle 'l' alias
    handle_l_alias
    changes_made=$((changes_made + $?))
    
    # Provide final summary
    if [ $changes_made -gt 0 ]; then
        echo "Aliases have been updated in $HOME/.bashrc"
        echo "A backup has been created at $HOME/.bashrc.backup"
        echo "Please run 'source ~/.bashrc' or start a new terminal session to apply changes"
    else
        echo "Both 'll' and 'l' aliases already exist with the expected values. No changes needed."
    fi
}

###############################################################
#          Fix vim.tiny so arrow keys work
###############################################################
function vi_settings {
    VIM_SETTING="set nocompatible"
    
    # Ensure the .vimrc file exists, creating it if necessary
    if [ ! -f "$HOME/.vimrc" ]; then
        touch "$HOME/.vimrc"
    fi
    
    # Check if the line exists in the .vimrc file
    if ! grep -qF "$VIM_SETTING" "$HOME/.vimrc"; then
        echo "$VIM_SETTING" >> "$HOME/.vimrc"
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
