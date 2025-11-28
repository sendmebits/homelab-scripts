#!/bin/bash
#
# Shell script to clean up npm, yarn, and pnpm caches
# and display the space saved.

# npm-specific directories to clean
CACHE_DIRS=(
  "$HOME/.npm"
  "$HOME/.npm/_logs"
  "$HOME/.yarn/cache"
  "$HOME/.pnpm-store"
  "$HOME/.local/share/pnpm/store"
  "$HOME/Library/Caches/yarn"
  "$HOME/Library/Caches/pnpm"
)

# Function to calculate directory size
calculate_size() {
  du -sh "$1" 2>/dev/null | awk '{print $1}'
}

# Initialize variables
declare -A BEFORE_SIZE
declare -A AFTER_SIZE

echo "Checking initial cache sizes..."

# Record initial sizes
for DIR in "${CACHE_DIRS[@]}"; do
  if [ -d "$DIR" ]; then
    BEFORE_SIZE["$DIR"]=$(calculate_size "$DIR")
  else
    BEFORE_SIZE["$DIR"]="0B (not found)"
  fi
done

# Clean up caches safely
echo "Cleaning caches..."

# npm cleanup (only if npm is installed)
if command -v npm &>/dev/null; then
  npm cache clean --force 2>/dev/null
  echo "✓ npm cache cleaned"
fi

# yarn cleanup (only if yarn is installed)
if command -v yarn &>/dev/null; then
  yarn cache clean 2>/dev/null
  echo "✓ yarn cache cleaned"
fi

# pnpm cleanup (only if pnpm is installed)
if command -v pnpm &>/dev/null; then
  pnpm store prune 2>/dev/null
  echo "✓ pnpm store pruned"
fi

# Clean npm-specific cache directories
for DIR in "${CACHE_DIRS[@]}"; do
  if [ -d "$DIR" ]; then
    rm -rf "$DIR" 2>/dev/null
  fi
done

echo "Rechecking cache sizes after cleanup..."

# Record final sizes
for DIR in "${CACHE_DIRS[@]}"; do
  if [ -d "$DIR" ]; then
    AFTER_SIZE["$DIR"]=$(calculate_size "$DIR")
  else
    AFTER_SIZE["$DIR"]="0B (not found)"
  fi
done

# Display results
echo -e "\nCache cleanup results:"
for DIR in "${CACHE_DIRS[@]}"; do
  echo -e "Directory: $DIR"
  echo -e "  Before: ${BEFORE_SIZE["$DIR"]}"
  echo -e "  After:  ${AFTER_SIZE["$DIR"]}"
done

echo -e "\nCache cleanup completed!"