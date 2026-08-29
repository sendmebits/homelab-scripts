#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
OUTPUT_FILE="${SCRIPT_DIR}/inventory.json"
WORKER_BASE_URL_DEFAULT="https://green-wave-2311.chillcat.workers.dev"

if [[ ! -r "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

: "${WRITE_TOKEN:?WRITE_TOKEN is missing from .env}"
WORKER_BASE_URL="${WORKER_BASE_URL:-${WORKER_BASE_URL_DEFAULT}}"
DEFAULT_EXPOSURE="${DEFAULT_EXPOSURE:-lan-only}"
WORKER_BASE_URL="${WORKER_BASE_URL%/}"

for command_name in curl jq pct pveversion flock; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "Required command not found: ${command_name}" >&2
    exit 1
  fi
done

# Prevent a manual run and the timer from updating at the same time.
exec 9>"${SCRIPT_DIR}/.inventory.lock"
if ! flock -n 9; then
  echo "Another inventory update is already running." >&2
  exit 0
fi

COMPONENTS='[]'

lowercase() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

host_without_port() {
  local host="$1"
  if [[ "${host}" == \[*\]* ]]; then
    host="${host#\[}"
    printf '%s' "${host%%\]*}"
    return
  fi
  # name:port or dotted-IPv4:port (not IPv6)
  if [[ "${host}" == *:* && "${host}" != *:*:* ]]; then
    printf '%s' "${host%%:*}"
    return
  fi
  printf '%s' "${host}"
}

is_ipv4() {
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]
}

# True when a hostname/IP should never appear in the published inventory.
is_internal_host() {
  local host
  host="$(lowercase "$(host_without_port "$1")")"
  [[ -z "${host}" || "${host}" == "localhost" || "${host}" == localhost.* ]] && return 0
  is_ipv4 "${host}" && return 0
  [[ "${host}" == *:* ]] && return 0
  case "${host}" in
    *.local|*.internal|*.lan|*.home|*.corp|*.localdomain|*.intranet|*.private|*.homelab|*.home.arpa)
      return 0
      ;;
  esac
  [[ "${host}" != *.* ]] && return 0
  return 1
}

is_public_registry() {
  local host
  host="$(lowercase "$(host_without_port "$1")")"
  case "${host}" in
    docker.io|registry-1.docker.io|index.docker.io|ghcr.io|quay.io|mcr.microsoft.com|registry.k8s.io|public.ecr.aws|lscr.io|gcr.io)
      return 0
      ;;
  esac
  return 1
}

# Publish only algorithm:hex, never registry/repo@sha256:…
oci_digest_only() {
  local value="$1"
  if [[ "${value}" =~ sha256:[0-9a-fA-F]{64} ]]; then
    printf '%s' "${BASH_REMATCH[0]}"
    return
  fi
  printf ''
}

# Keep https URLs whose host is not an IP, port, or internal domain.
sanitize_source_url() {
  local url="$1" host
  if [[ ! "${url}" =~ ^https://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(/.*)?$ ]]; then
    printf ''
    return
  fi
  host="${url#https://}"
  host="${host%%/*}"
  if [[ "${host}" == *:* ]] || is_internal_host "${host}"; then
    printf ''
    return
  fi
  printf '%s' "${url}"
}

# Parse a docker image ref. Sets SANITIZED_IMAGE, SANITIZED_IDENTIFIER,
# SANITIZED_DIGEST, SANITIZED_SOURCE, IMAGE_TAG, IMAGE_REPO_NAME.
sanitize_container_metadata() {
  local raw_ref="$1"
  local raw_digest="$2"
  local raw_source="$3"
  local name first registry repo tag="" registry_host published

  SANITIZED_DIGEST="$(oci_digest_only "${raw_digest}")"
  SANITIZED_SOURCE="$(sanitize_source_url "${raw_source}")"

  name="${raw_ref%%@*}"
  first="${name%%/*}"
  if [[ "${name}" == */* ]] && { [[ "${first}" == *.* ]] || [[ "${first}" == *:* ]] || [[ "$(lowercase "${first}")" == "localhost" ]]; }; then
    registry="$(lowercase "${first}")"
    repo="${name#*/}"
  else
    registry="docker.io"
    if [[ "${name}" == */* ]]; then
      repo="${name}"
    else
      repo="library/${name}"
    fi
  fi

  if [[ "${repo}" == *:* ]]; then
    tag="${repo##*:}"
    repo="${repo%:*}"
  fi
  if [[ "${tag}" == sha256:* ]]; then
    tag=""
  fi

  registry_host="$(lowercase "$(host_without_port "${registry}")")"
  if [[ "${registry_host}" == "registry-1.docker.io" || "${registry_host}" == "index.docker.io" ]]; then
    registry_host="docker.io"
  fi

  if is_public_registry "${registry_host}" && ! is_internal_host "${registry_host}"; then
    published="${registry_host}/${repo}"
  else
    published="${repo}"
  fi
  [[ -n "${tag}" ]] && published="${published}:${tag}"

  SANITIZED_IMAGE="${published}"
  SANITIZED_IDENTIFIER="oci:${published}"
  IMAGE_TAG="${tag}"
  IMAGE_REPO_NAME="${repo##*/}"
}

append_component() {
  local product="$1"
  local version="$2"
  local channel="${3:-stable}"
  local exposure="${4:-${DEFAULT_EXPOSURE}}"
  local kind="${5:-application}"
  local identifier="${6:-}"
  local source="${7:-}"
  local image="${8:-}"
  local digest="${9:-}"
  local item

  [[ -n "${product}" && -n "${version}" ]] || return 0

  item="$(jq -nc \
    --arg product "${product}" \
    --arg version "${version}" \
    --arg channel "${channel}" \
    --arg exposure "${exposure}" \
    --arg kind "${kind}" \
    --arg identifier "${identifier}" \
    --arg source "${source}" \
    --arg image "${image}" \
    --arg digest "${digest}" \
    '{
      product: $product,
      version: $version,
      channel: $channel,
      exposure: $exposure,
      kind: $kind,
      identifier: $identifier,
      source: $source,
      image: $image,
      digest: $digest
    } | with_entries(select(.value != ""))')"

  COMPONENTS="$(jq -c --argjson item "${item}" '. + [$item]' <<<"${COMPONENTS}")"
}

collect_proxmox_host() {
  local pve_version host_os_name host_os_version

  pve_version="$(pveversion 2>/dev/null | awk -F/ 'NR == 1 {print $2}' | awk '{print $1}')"
  append_component \
    "Proxmox VE" "${pve_version}" "stable" "vpn-only" "platform" \
    "deb:pve-manager" "https://www.proxmox.com/en/downloads/proxmox-virtual-environment"

  if [[ -r /etc/os-release ]]; then
    host_os_name="$(. /etc/os-release; printf '%s' "${NAME:-Linux}")"
    host_os_version="$(. /etc/os-release; printf '%s' "${VERSION_ID:-unknown}")"
    append_component \
      "${host_os_name} (Proxmox host)" "${host_os_version}" "stable" "vpn-only" \
      "operating-system" "os:debian" "https://www.debian.org/releases/"
  fi
}

collect_lxc_guests() {
  local ctid os_info os_id os_name os_version unifi_version
  local image_ref image_json title version digest source
  local -a ctids image_refs

  mapfile -t ctids < <(pct list 2>/dev/null | awk 'NR > 1 && $2 == "running" {print $1}')

  for ctid in "${ctids[@]}"; do
    # Only distribution/version are retained. CTID, hostname, and IP are discarded.
    os_info="$(timeout 15s pct exec "${ctid}" -- sh -c \
      '. /etc/os-release 2>/dev/null || exit 1; printf "%s|%s|%s\n" "${ID:-linux}" "${NAME:-Linux}" "${VERSION_ID:-unknown}"' \
      2>/dev/null || true)"

    if [[ -n "${os_info}" ]]; then
      IFS='|' read -r os_id os_name os_version <<<"${os_info}"
      append_component \
        "${os_name} (LXC guest)" "${os_version}" "stable" "${DEFAULT_EXPOSURE}" \
        "operating-system" "os:${os_id}"
    fi

    # Detect a native UniFi Network Application package, if present.
    unifi_version="$(timeout 15s pct exec "${ctid}" -- \
      dpkg-query -W '-f=${Version}\n' unifi 2>/dev/null || true)"
    if [[ -n "${unifi_version}" ]]; then
      append_component \
        "UniFi Network Application" "${unifi_version}" "stable" "${DEFAULT_EXPOSURE}" \
        "application" "deb:unifi" "https://ui.com/download/releases/network-server"
    fi

    # Detect running Docker workloads. Only public image metadata is retained.
    if timeout 10s pct exec "${ctid}" -- docker version >/dev/null 2>&1; then
      mapfile -t image_refs < <(
        timeout 20s pct exec "${ctid}" -- docker ps --format '{{.Image}}' 2>/dev/null | sort -u
      )

      for image_ref in "${image_refs[@]}"; do
        [[ -n "${image_ref}" ]] || continue
        image_json="$(timeout 20s pct exec "${ctid}" -- docker image inspect "${image_ref}" 2>/dev/null || true)"

        if ! jq -e 'type == "array" and length > 0' >/dev/null 2>&1 <<<"${image_json}"; then
          continue
        fi

        title="$(jq -r '.[0].Config.Labels["org.opencontainers.image.title"] // empty' <<<"${image_json}")"
        version="$(jq -r '.[0].Config.Labels["org.opencontainers.image.version"] // empty' <<<"${image_json}")"
        source="$(jq -r '.[0].Config.Labels["org.opencontainers.image.source"] // empty' <<<"${image_json}")"
        digest="$(jq -r '.[0].RepoDigests[0] // empty' <<<"${image_json}")"

        sanitize_container_metadata "${image_ref}" "${digest}" "${source}"

        if [[ -z "${version}" && -n "${IMAGE_TAG}" ]]; then
          version="${IMAGE_TAG}"
        fi
        if [[ -z "${version}" && -n "${SANITIZED_DIGEST}" ]]; then
          version="digest-pinned"
        fi
        version="${version:-unknown}"

        if [[ -z "${title}" ]]; then
          title="${IMAGE_REPO_NAME}"
        fi

        append_component \
          "${title}" "${version}" "stable" "${DEFAULT_EXPOSURE}" "container-image" \
          "${SANITIZED_IDENTIFIER}" "${SANITIZED_SOURCE}" "${SANITIZED_IMAGE}" "${SANITIZED_DIGEST}"
      done
    fi
  done
}

collect_drop_ins() {
  local collector line
  shopt -s nullglob

  # Optional executable collectors can emit one JSON object per line. Required
  # fields are product and version. Do not emit internal hostnames or addresses.
  for collector in "${SCRIPT_DIR}"/collectors.d/*.sh; do
    [[ -x "${collector}" ]] || continue
    while IFS= read -r line; do
      if jq -e 'type == "object" and (.product | type == "string") and (.version | type == "string")' \
        >/dev/null 2>&1 <<<"${line}"; then
        COMPONENTS="$(jq -c --argjson item "${line}" '. + [$item]' <<<"${COMPONENTS}")"
      else
        echo "Ignoring invalid output from ${collector}" >&2
      fi
    done < <(timeout 30s "${collector}" || true)
  done
}

collect_proxmox_host
collect_lxc_guests
collect_drop_ins

# Combine identical deployments without disclosing which internal guest runs them.
COMPONENTS="$(jq -c '
  sort_by([.product, .version, .channel, .exposure, .kind, .identifier, .image, .digest])
  | group_by([.product, .version, .channel, .exposure, .kind, .identifier, .image, .digest])
  | map(.[0] + if length > 1 then {deployment_count: length} else {} end)
' <<<"${COMPONENTS}")"

TEMP_FILE="$(mktemp "${SCRIPT_DIR}/.inventory.XXXXXX")"
trap 'rm -f -- "${TEMP_FILE}"' EXIT

jq -n \
  --arg generated_at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --argjson components "${COMPONENTS}" \
  '{schema_version: 1, generated_at: $generated_at, components: $components}' \
  >"${TEMP_FILE}"

chmod 0644 "${TEMP_FILE}"
mv -f -- "${TEMP_FILE}" "${OUTPUT_FILE}"
trap - EXIT

response="$(curl --silent --show-error --fail-with-body \
  --retry 3 --retry-all-errors --connect-timeout 15 --max-time 60 \
  --request PUT "${WORKER_BASE_URL}/inventory" \
  --header "Authorization: Bearer ${WRITE_TOKEN}" \
  --header "Content-Type: application/json" \
  --data-binary "@${OUTPUT_FILE}")"

if ! jq -e '.ok == true' >/dev/null 2>&1 <<<"${response}"; then
  echo "Worker did not confirm the upload: ${response}" >&2
  exit 1
fi

echo "Inventory uploaded successfully: $(jq -c '{received_at, component_count}' <<<"${response}")"
