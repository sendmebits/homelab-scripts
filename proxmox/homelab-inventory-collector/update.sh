#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${SCRIPT_DIR}/update-inventory.sh"
SOURCE_URL="https://raw.githubusercontent.com/sendmebits/homelab-scripts/main/proxmox/homelab-inventory-collector/update-inventory.sh"

if ! command -v curl >/dev/null 2>&1; then
  echo "Required command not found: curl" >&2
  exit 1
fi

# Do not replace the collector while a run is in progress.
exec 9>"${SCRIPT_DIR}/.inventory.lock"
if ! flock -n 9; then
  echo "Inventory update is already running; try again when it finishes." >&2
  exit 1
fi

TEMP_FILE="$(mktemp "${SCRIPT_DIR}/.update-inventory.XXXXXX")"
trap 'rm -f -- "${TEMP_FILE}"' EXIT

curl --silent --show-error --fail --location \
  --retry 3 --retry-all-errors --connect-timeout 15 --max-time 60 \
  --output "${TEMP_FILE}" \
  "${SOURCE_URL}"

if ! grep -q '^#!/usr/bin/env bash' "${TEMP_FILE}"; then
  echo "Downloaded file does not look like the collector script." >&2
  exit 1
fi

chmod 700 "${TEMP_FILE}"
mv -f -- "${TEMP_FILE}" "${TARGET}"
trap - EXIT

echo "Updated ${TARGET}"
