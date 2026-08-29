#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
OUTPUT_FILE="${SCRIPT_DIR}/inventory.json"

if [[ ! -r "${ENV_FILE}" ]]; then
  echo "Missing ${ENV_FILE}" >&2
  exit 1
fi

# shellcheck disable=SC1090
source "${ENV_FILE}"

: "${WRITE_TOKEN:?WRITE_TOKEN is missing from .env}"
: "${WORKER_BASE_URL:?WORKER_BASE_URL is missing from .env}"
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

# Maps dpkg names, npm names, and community-scripts slugs to inventory metadata.
APP_CATALOG="$(cat <<'CATALOG'
adguardhome|AdGuard Home|app:adguardhome|https://github.com/AdguardTeam/AdGuardHome
adguard|AdGuard Home|app:adguardhome|https://github.com/AdguardTeam/AdGuardHome
audiobookshelf|Audiobookshelf|app:audiobookshelf|https://www.audiobookshelf.org/
authentik|Authentik|app:authentik|https://goauthentik.io/
bazarr|Bazarr|app:bazarr|https://www.bazarr.media/
bookstack|BookStack|app:bookstack|https://www.bookstackapp.com/
caddy|Caddy|deb:caddy|https://caddyserver.com/
changedetection|Changedetection.io|app:changedetection|https://changedetection.io/
containerd.io|containerd|deb:containerd.io|https://containerd.io/
crowdsec|CrowdSec|deb:crowdsec|https://www.crowdsec.net/
dashy|Dashy|app:dashy|https://dashy.to/
docker-ce|Docker Engine|deb:docker-ce|https://docs.docker.com/engine/
emby-server|Emby Server|deb:emby-server|https://emby.media/
emby|Emby Server|deb:emby-server|https://emby.media/
esphome|ESPHome|app:esphome|https://esphome.io/
fail2ban|Fail2ban|deb:fail2ban|https://www.fail2ban.org/
filebrowser|File Browser|app:filebrowser|https://filebrowser.org/
forgejo|Forgejo|app:forgejo|https://forgejo.org/
frigate|Frigate|app:frigate|https://frigate.video/
freshrss|FreshRSS|app:freshrss|https://freshrss.org/
gitea|Gitea|app:gitea|https://about.gitea.com/
gotify|Gotify|app:gotify|https://gotify.net/
grafana|Grafana|deb:grafana|https://grafana.com/
grocy|Grocy|app:grocy|https://grocy.info/
homeassistant|Home Assistant|app:homeassistant|https://www.home-assistant.io/
homebridge|Homebridge|deb:homebridge|https://homebridge.io/
homebox|HomeBox|app:homebox|https://homebox.software/
homepage|Homepage|app:homepage|https://gethomepage.dev/
immich|Immich|app:immich|https://immich.app/
influxdb|InfluxDB|deb:influxdb|https://www.influxdata.com/
influxdb2|InfluxDB|deb:influxdb2|https://www.influxdata.com/
jellyfin|Jellyfin|deb:jellyfin|https://jellyfin.org/
komga|Komga|app:komga|https://komga.org/
lidarr|Lidarr|app:lidarr|https://lidarr.audio/
mealie|Mealie|app:mealie|https://mealie.io/
meshcentral|MeshCentral|app:meshcentral|https://meshcentral.com/
mosquitto|Eclipse Mosquitto|deb:mosquitto|https://mosquitto.org/
navidrome|Navidrome|app:navidrome|https://www.navidrome.org/
nextcloud|Nextcloud|app:nextcloud|https://nextcloud.com/
nginx|Nginx|deb:nginx|https://nginx.org/
nginx-proxy-manager|Nginx Proxy Manager|app:nginx-proxy-manager|https://nginxproxymanager.com/
nginxproxymanager|Nginx Proxy Manager|app:nginx-proxy-manager|https://nginxproxymanager.com/
node-red|Node-RED|app:node-red|https://nodered.org/
nodered|Node-RED|app:node-red|https://nodered.org/
ntfy|ntfy|app:ntfy|https://ntfy.sh/
nzbget|NZBGet|app:nzbget|https://nzbget.com/
omada|Omada Controller|app:omada|https://www.tp-link.com/omada/
openresty|OpenResty|app:openresty|https://openresty.org/
overseerr|Overseerr|app:overseerr|https://overseerr.dev/
paperless-ngx|Paperless-ngx|app:paperless-ngx|https://docs.paperless-ngx.com/
paperless|Paperless-ngx|app:paperless-ngx|https://docs.paperless-ngx.com/
photoprism|PhotoPrism|app:photoprism|https://www.photoprism.app/
pihole|Pi-hole|app:pihole|https://pi-hole.net/
plex|Plex Media Server|deb:plexmediaserver|https://www.plex.tv/media-server-downloads/
plexmediaserver|Plex Media Server|deb:plexmediaserver|https://www.plex.tv/media-server-downloads/
portainer|Portainer|app:portainer|https://www.portainer.io/
prometheus|Prometheus|deb:prometheus|https://prometheus.io/
prowlarr|Prowlarr|app:prowlarr|https://prowlarr.com/
qbittorrent-nox|qBittorrent|deb:qbittorrent-nox|https://www.qbittorrent.org/
radarr|Radarr|app:radarr|https://radarr.video/
sabnzbdplus|SABnzbd|deb:sabnzbdplus|https://sabnzbd.org/
sonarr|Sonarr|app:sonarr|https://sonarr.tv/
stirling-pdf|Stirling PDF|app:stirling-pdf|https://www.stirlingpdf.com/
syncthing|Syncthing|deb:syncthing|https://syncthing.net/
tautulli|Tautulli|app:tautulli|https://tautulli.com/
telegraf|Telegraf|deb:telegraf|https://www.influxdata.com/time-series-platform/telegraf/
traefik|Traefik|app:traefik|https://traefik.io/
transmission-daemon|Transmission|deb:transmission-daemon|https://transmissionbt.com/
unifi|UniFi Network Application|deb:unifi|https://ui.com/download/releases/network-server
uptime-kuma|Uptime Kuma|app:uptime-kuma|https://github.com/louislam/uptime-kuma
uptimekuma|Uptime Kuma|app:uptime-kuma|https://github.com/louislam/uptime-kuma
vaultwarden|Vaultwarden|app:vaultwarden|https://github.com/dani-garcia/vaultwarden
wikijs|Wiki.js|app:wikijs|https://js.wiki/
wireguard|WireGuard|deb:wireguard|https://www.wireguard.com/
zigbee2mqtt|Zigbee2MQTT|app:zigbee2mqtt|https://www.zigbee2mqtt.io/
CATALOG
)"

catalog_line() {
  awk -F'|' -v k="$(lowercase "$1")" 'tolower($1) == k { print; exit }' <<<"${APP_CATALOG}"
}

pretty_slug() {
  local slug="${1##*/}"
  slug="${slug//[-_]/ }"
  awk '{for (i = 1; i <= NF; i++) { $i = toupper(substr($i, 1, 1)) tolower(substr($i, 2)) } print}' <<<"${slug}"
}

# Sets RESOLVED_PRODUCT, RESOLVED_ID, RESOLVED_SOURCE from a package/slug name.
resolve_app() {
  local key last line
  key="$(lowercase "$1")"
  key="${key#@}"
  last="${key##*/}"

  line="$(catalog_line "${key}")"
  if [[ -z "${line}" && "${last}" != "${key}" ]]; then
    line="$(catalog_line "${last}")"
  fi

  if [[ -n "${line}" ]]; then
    IFS='|' read -r _ RESOLVED_PRODUCT RESOLVED_ID RESOLVED_SOURCE <<<"${line}"
    return
  fi

  RESOLVED_PRODUCT="$(pretty_slug "${last}")"
  RESOLVED_ID="app:${last}"
  RESOLVED_SOURCE=""
}

is_version_string() {
  local value="$1"
  [[ "${#value}" -ge 1 && "${#value}" -le 80 ]] || return 1
  [[ "${value}" =~ ^[vV]?[0-9] ]] || return 1
  [[ "${value}" != *'|'* && "${value}" != *' '* ]]
}

append_guest_app() {
  local key="$1"
  local version="$2"
  local fallback_source="${3:-}"

  [[ -n "${key}" && -n "${version}" ]] || return 0
  is_version_string "${version}" || return 0

  resolve_app "${key}"
  [[ -n "${RESOLVED_SOURCE}" ]] || RESOLVED_SOURCE="$(sanitize_source_url "${fallback_source}")"
  append_component \
    "${RESOLVED_PRODUCT}" "${version}" "stable" "${DEFAULT_EXPOSURE}" \
    "application" "${RESOLVED_ID}" "${RESOLVED_SOURCE}"
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

collect_lxc_guest_apps() {
  local ctid="$1"
  local facts line kind field_a field_b field_c token
  local seen="|"

  facts="$(timeout 30s pct exec "${ctid}" -- sh -c "$(cat <<'PROBE'
if [ -r /etc/os-release ]; then
  . /etc/os-release
  printf 'os|%s|%s|%s\n' "${ID:-linux}" "${NAME:-Linux}" "${VERSION_ID:-unknown}"
fi

if command -v dpkg-query >/dev/null 2>&1; then
  dpkg-query -W -f='${db:Status-Status}\t${Package}\t${Version}\n' 2>/dev/null \
    | awk -F '\t' '$1 == "installed" { printf "deb|%s|%s\n", $2, $3 }'
fi

for f in /var/cache/app-versions/*_version.txt /opt/*_version.txt; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  app=${base%_version.txt}
  ver=$(head -n 1 "$f" | tr -d '\r\n')
  [ -n "$app" ] && [ -n "$ver" ] && printf 'csver|%s|%s\n' "$app" "$ver"
done

for f in /root/.[!.]*; do
  [ -f "$f" ] || continue
  base=$(basename "$f")
  case "$base" in
    .bashrc|.profile|.bash_history|.bash_logout|.wget-hsts|.selected_editor|.viminfo|.lesshst|.python_history|.sudo_as_admin_successful|.cloud-locale-test.skip|.motd_shown|.openvino|.intel_version)
      continue
      ;;
  esac
  size=$(wc -c < "$f" | tr -d ' ')
  [ "$size" -lt 128 ] 2>/dev/null || continue
  ver=$(head -n 1 "$f" | tr -d '\r\n')
  app=${base#.}
  [ -n "$app" ] && [ -n "$ver" ] && printf 'csver|%s|%s\n' "$app" "$ver"
done

if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
  py=python3
  command -v python3 >/dev/null 2>&1 || py=python
  "$py" - <<'PY'
import json, os, glob
generic = {"frontend", "backend", "server", "web", "app", "www"}
paths = glob.glob("/opt/*/package.json") + glob.glob("/opt/*/backend/package.json") + glob.glob("/app/package.json")
for path in paths:
    if "node_modules" in path.split(os.sep):
        continue
    try:
        with open(path) as handle:
            data = json.load(handle)
    except Exception:
        continue
    if not isinstance(data, dict):
        continue
    name = str(data.get("name") or "").strip().replace("|", "/")
    version = str(data.get("version") or "").strip().replace("|", ".")
    repo = data.get("repository") or ""
    if isinstance(repo, dict):
        repo = str(repo.get("url") or "")
    else:
        repo = str(repo)
    parent = os.path.basename(os.path.dirname(path))
    if parent in {"backend", "frontend"}:
        parent = os.path.basename(os.path.dirname(os.path.dirname(path)))
    short = name.rsplit("/", 1)[-1].lstrip("@")
    if not name or short.lower() in generic:
        name = parent
    repo = repo.replace("git+", "").replace("git://", "https://").replace("|", "")
    if repo.endswith(".git"):
        repo = repo[:-4]
    if name and version:
        print("pkgjson|{}|{}|{}".format(name, version, repo))
PY
fi
PROBE
)" 2>/dev/null || true)"

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    IFS='|' read -r kind field_a field_b field_c <<<"${line}"
    case "${kind}" in
      os)
        append_component \
          "${field_b} (LXC guest ${ctid})" "${field_c}" "stable" "${DEFAULT_EXPOSURE}" \
          "operating-system" "os:${field_a}"
        ;;
      deb)
        [[ -n "$(catalog_line "${field_a}")" ]] || continue
        resolve_app "${field_a}"
        token="${RESOLVED_ID}|${field_b}"
        [[ "${seen}" == *"|${token}|"* ]] && continue
        seen="${seen}${token}|"
        append_guest_app "${field_a}" "${field_b}"
        ;;
      csver|pkgjson)
        resolve_app "${field_a}"
        token="${RESOLVED_ID}|${field_b}"
        [[ "${seen}" == *"|${token}|"* ]] && continue
        seen="${seen}${token}|"
        append_guest_app "${field_a}" "${field_b}" "${field_c:-}"
        ;;
    esac
  done <<<"${facts}"
}

collect_lxc_guest_docker() {
  local ctid="$1"
  local image_ref image_json title version source digest
  local -a image_refs

  timeout 10s pct exec "${ctid}" -- docker version >/dev/null 2>&1 || return 0

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
}

collect_lxc_guests() {
  local ctid
  local -a ctids

  mapfile -t ctids < <(pct list 2>/dev/null | awk 'NR > 1 && $2 == "running" {print $1}')

  for ctid in "${ctids[@]}"; do
    # CTID labels guest OS rows; hostnames, names, IPs, and workload mapping are omitted.
    collect_lxc_guest_apps "${ctid}"
    collect_lxc_guest_docker "${ctid}"
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

# Combine identical deployments without disclosing which guest runs app/container workloads.
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
