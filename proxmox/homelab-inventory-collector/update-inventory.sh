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
EXPOSURE_MAP_FILE="${SCRIPT_DIR}/exposure.map"
DETECTED_EXPOSURE='{}'
# Unpublished CT addressing used only to map reverse-proxy backends.
ADDR_TO_CT=""
PORT_BINDINGS=""

# Native app ports used when a public proxy forwards to an LXC IP:port.
KNOWN_PORTS="$(cat <<'PORTS'
32400|deb:plexmediaserver
5055|app:seerr
5055|app:overseerr
8989|app:sonarr
7878|app:radarr
9696|app:prowlarr
8181|app:tautulli
8080|app:sabnzbd-org
8080|deb:sabnzbdplus
8096|deb:jellyfin
8096|app:jellyfin
8443|deb:unifi
8581|deb:homebridge
3000|app:homepage
3000|app:uptime-kuma
3001|app:uptime-kuma
2283|app:immich
5006|app:actual-sync
5006|app:actual
8123|app:homeassistant
8384|deb:syncthing
8686|app:lidarr
6767|app:bazarr
9117|app:jackett
6789|app:nzbget
9091|deb:transmission-daemon
8085|app:changedetection
5000|app:changedetection
PORTS
)"

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

# True for a real public DNS name. IPs, short names, and internal TLDs are not.
is_public_hostname() {
  ! is_internal_host "$1"
}

append_addr_map() {
  local addr ctid
  addr="$(lowercase "$1")"
  ctid="$2"
  [[ -n "${addr}" && -n "${ctid}" ]] || return 0
  ADDR_TO_CT+="${addr}|${ctid}"$'\n'
}

append_port_binding() {
  local ctid="$1" port="$2" identifier="$3"
  [[ -n "${ctid}" && -n "${port}" && -n "${identifier}" ]] || return 0
  [[ "${port}" =~ ^[0-9]+$ ]] || return 0
  PORT_BINDINGS+="${ctid}|${port}|${identifier}"$'\n'
}

lookup_ctid() {
  local addr
  addr="$(lowercase "$(host_without_port "$1")")"
  [[ -n "${addr}" ]] || return 0
  awk -F'|' -v a="${addr}" '$1 == a { print $2; exit }' <<<"${ADDR_TO_CT}"
}

ct_has_identifier() {
  local ctid="$1" ident="$2"
  jq -e --arg suffix " (LXC guest ${ctid})" --arg id "${ident}" \
    'any(.[]; .identifier == $id and (.product | endswith($suffix)))' \
    >/dev/null 2>&1 <<<"${COMPONENTS}"
}

set_detected_exposure() {
  local ctid="$1" identifier="$2" exposure="$3"
  DETECTED_EXPOSURE="$(jq -c \
    --arg ctid "${ctid}" \
    --arg id "${identifier}" \
    --arg exp "${exposure}" '
      def rank($e):
        if $e == "internet" then 4
        elif $e == "Public" or $e == "internet-via-proxy" then 3
        elif $e != null and $e != "" and $e != "lan-only" and $e != "vpn-only" then 2
        elif $e == "vpn-only" then 1
        else 0 end;
      .[$ctid] |= (. // {})
      | if rank($exp) > rank(.[$ctid][$id]) then .[$ctid][$id] = $exp else . end
    ' <<<"${DETECTED_EXPOSURE}")"
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
seerr|Seerr|app:seerr|https://seerr.dev/
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
  local ctid="$1"
  local key="$2"
  local version="$3"
  local fallback_source="${4:-}"

  [[ -n "${key}" && -n "${version}" ]] || return 0
  is_version_string "${version}" || return 0

  resolve_app "${key}"
  [[ -n "${RESOLVED_SOURCE}" ]] || RESOLVED_SOURCE="$(sanitize_source_url "${fallback_source}")"
  append_component \
    "${RESOLVED_PRODUCT} (LXC guest ${ctid})" "${version}" "stable" "${DEFAULT_EXPOSURE}" \
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
        append_guest_app "${ctid}" "${field_a}" "${field_b}"
        ;;
      csver|pkgjson)
        resolve_app "${field_a}"
        token="${RESOLVED_ID}|${field_b}"
        [[ "${seen}" == *"|${token}|"* ]] && continue
        seen="${seen}${token}|"
        append_guest_app "${ctid}" "${field_a}" "${field_b}" "${field_c:-}"
        ;;
    esac
  done <<<"${facts}"
}

collect_lxc_guest_docker() {
  local ctid="$1"
  local image_ref image_json title version source digest row ports
  local -a image_refs container_rows

  timeout 10s pct exec "${ctid}" -- docker version >/dev/null 2>&1 || return 0

  mapfile -t container_rows < <(
    timeout 20s pct exec "${ctid}" -- docker ps --format '{{.Image}}|{{.Ports}}' 2>/dev/null
  )

  for row in "${container_rows[@]}"; do
    [[ -n "${row}" ]] || continue
    image_ref="${row%%|*}"
    ports="${row#*|}"
    [[ -n "${image_ref}" ]] || continue
    record_docker_published_ports "${ctid}" "${image_ref}" "${ports}"
  done

  mapfile -t image_refs < <(printf '%s\n' "${container_rows[@]}" | awk -F'|' 'NF { print $1 }' | sort -u)

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
      "${title} (LXC guest ${ctid})" "${version}" "stable" "${DEFAULT_EXPOSURE}" "container-image" \
      "${SANITIZED_IDENTIFIER}" "${SANITIZED_SOURCE}" "${SANITIZED_IMAGE}" "${SANITIZED_DIGEST}"
  done
}

record_docker_published_ports() {
  local ctid="$1" image_ref="$2" ports="$3" ident spec port
  sanitize_container_metadata "${image_ref}" "" ""
  ident="${SANITIZED_IDENTIFIER}"
  while IFS= read -r spec; do
    spec="${spec#"${spec%%[![:space:]]*}"}"
    [[ "${spec}" == *0.0.0.0:* || "${spec}" == *\[::\]:* || "${spec}" == *:::* ]] || continue
    port="$(sed -n 's/.*:\([0-9][0-9]*\)->.*/\1/p' <<<"${spec}")"
    append_port_binding "${ctid}" "${port}" "${ident}"
  done < <(tr ',' '\n' <<<"${ports}")
}

record_guest_addresses() {
  local ctid="$1" host ip

  host="$(timeout 10s pct exec "${ctid}" -- hostname -s 2>/dev/null | tr -d '\r\n' || true)"
  host="$(lowercase "${host}")"
  if [[ -n "${host}" ]]; then
    append_addr_map "${host}" "${ctid}"
    append_addr_map "${host}.lan" "${ctid}"
    append_addr_map "${host}.local" "${ctid}"
    append_addr_map "${host}.home" "${ctid}"
    append_addr_map "${host}.internal" "${ctid}"
    append_addr_map "${host}.home.arpa" "${ctid}"
    append_addr_map "${host}.homelab" "${ctid}"
  fi

  host="$(timeout 10s pct exec "${ctid}" -- hostname -f 2>/dev/null | tr -d '\r\n' || true)"
  host="$(lowercase "${host}")"
  [[ -n "${host}" ]] && append_addr_map "${host}" "${ctid}"

  host="$(pct config "${ctid}" 2>/dev/null | awk -F': ' '/^hostname:/ { print tolower($2); exit }')"
  [[ -n "${host}" ]] && append_addr_map "${host}" "${ctid}"

  while IFS= read -r ip; do
    ip="$(lowercase "$(tr -d '\r\n' <<<"${ip}")")"
    [[ -n "${ip}" ]] && append_addr_map "${ip}" "${ctid}"
  done < <(timeout 10s pct exec "${ctid}" -- hostname -I 2>/dev/null | tr ' ' '\n')

  while IFS= read -r ip; do
    [[ -n "${ip}" ]] && append_addr_map "${ip}" "${ctid}"
  done < <(pct config "${ctid}" 2>/dev/null | grep -oE 'ip=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | cut -d= -f2)
}

# Guest probe prints edge/backend/direct facts. Domain names are never printed.
exposure_probe_python() {
  cat <<'PY'
import glob, json, os, re, sys

INTERNAL_SUFFIXES = (
    ".local", ".internal", ".lan", ".home", ".corp", ".localdomain",
    ".intranet", ".private", ".homelab", ".home.arpa",
)

def host_without_port(host):
    host = (host or "").strip().strip('"').strip("'")
    if host.startswith("[") and "]" in host:
        end = host.find("]")
        return host[1:end]
    if host.count(":") == 1:
        return host.split(":", 1)[0]
    return host

def is_internal_host(host):
    host = host_without_port(host).lower().rstrip(".")
    if not host or host == "localhost" or host.startswith("localhost."):
        return True
    if re.match(r"^\d{1,3}(\.\d{1,3}){3}$", host):
        return True
    if ":" in host:
        return True
    for suffix in INTERNAL_SUFFIXES:
        if host.endswith(suffix):
            return True
    if "." not in host:
        return True
    return False

def any_public(names):
    for name in names:
        name = str(name or "").strip().lower().rstrip(".")
        if name.startswith("*."):
            name = name[2:]
        if name in ("_", "-", "localhost"):
            continue
        if name and not is_internal_host(name):
            return True
    return False

def clean_field(value, limit=120):
    return str(value or "").replace("|", "").replace("\r", "").replace("\n", "").strip()[:limit]

def emit(kind, *fields):
    fields = [clean_field(value) for value in fields]
    if not fields or not fields[0]:
        return
    sys.stdout.write("%s|%s\n" % (kind, "|".join(fields)))

def normalize_access_list_name(name):
    name = clean_field(name, 40)
    return name or "Public"

def parse_domain_names(raw):
    if not raw:
        return []
    try:
        data = json.loads(raw)
        if isinstance(data, list):
            return [str(x) for x in data]
        return [str(data)]
    except Exception:
        return [str(raw)]

def split_host_port(target):
    target = (target or "").strip().strip('"').strip("'")
    if target.startswith("["):
        if "]:" in target:
            host, port = target.rsplit("]:", 1)
            return host.strip("[]"), port
        return target.strip("[]"), ""
    if target.count(":") == 1:
        host, port = target.split(":", 1)
        return host, port
    return target, ""

NPM_SQLITE_HAS_PROXY_HOST = False

def scan_npm_sqlite():
    global NPM_SQLITE_HAS_PROXY_HOST
    found_public = False
    try:
        import sqlite3
    except Exception:
        return False
    for path in ("/data/database.sqlite", "/opt/nginxproxymanager/data/database.sqlite"):
        if not os.path.isfile(path):
            continue
        try:
            con = sqlite3.connect("file:%s?mode=ro&immutable=1" % path, uri=True)
            tables = {row[0] for row in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            if "proxy_host" not in tables:
                con.close()
                continue
            NPM_SQLITE_HAS_PROXY_HOST = True
            try:
                rows = con.execute(
                    "SELECT p.domain_names, p.forward_host, p.forward_port, a.name "
                    "FROM proxy_host p "
                    "LEFT JOIN access_list a ON a.id = p.access_list_id "
                    "WHERE IFNULL(p.enabled,1)=1 AND IFNULL(p.is_deleted,0)=0"
                )
            except Exception:
                rows = con.execute(
                    "SELECT domain_names, forward_host, forward_port, NULL FROM proxy_host "
                    "WHERE IFNULL(enabled,1)=1 AND IFNULL(is_deleted,0)=0"
                )
            for domains, fhost, fport, access_name in rows:
                if any_public(parse_domain_names(domains)):
                    found_public = True
                    if fhost:
                        emit("backend", host_without_port(str(fhost)), fport or "", normalize_access_list_name(access_name))
            con.close()
        except Exception:
            continue
    return found_public

def iter_server_blocks(text):
    idx = 0
    while True:
        match = re.search(r"\bserver\s*\{", text[idx:])
        if not match:
            return
        start = idx + match.end()
        depth = 1
        i = start
        while i < len(text) and depth:
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
            i += 1
        yield text[start:i - 1]
        idx = i

def parse_nginx_text(text):
    public = False
    backends = []
    for block in iter_server_blocks(text):
        names = []
        for match in re.finditer(r"\bserver_name\s+([^;]+);", block):
            names.extend(match.group(1).split())
        if not any_public(names):
            continue
        public = True
        match = re.search(r'set\s+\$server\s+"?([^";]+)"?\s*;', block)
        port_match = re.search(r"set\s+\$port\s+([0-9]+)\s*;", block)
        if match:
            backends.append((host_without_port(match.group(1).strip()), port_match.group(1) if port_match else ""))
        for match in re.finditer(r"proxy_pass\s+https?://([^/;\s]+)", block):
            host, port = split_host_port(match.group(1))
            if host:
                backends.append((host, port))
    return public, backends

def scan_nginx():
    public = False
    files = []
    for pat in (
        "/data/nginx/proxy_host/*.conf",
        "/etc/nginx/sites-enabled/*",
        "/etc/nginx/conf.d/*.conf",
        "/usr/local/openresty/nginx/conf/conf.d/*.conf",
    ):
        files.extend(glob.glob(pat))
    seen = set()
    for path in files:
        if path in seen or not os.path.isfile(path) or path.endswith(".err"):
            continue
        if NPM_SQLITE_HAS_PROXY_HOST and path.startswith("/data/nginx/proxy_host/"):
            continue
        seen.add(path)
        try:
            with open(path, "r", errors="ignore") as handle:
                text = handle.read()
        except Exception:
            continue
        is_pub, backends = parse_nginx_text(text)
        if is_pub:
            public = True
            for host, port in backends:
                if host:
                    emit("backend", host, port)
    return public

def scan_cloudflared():
    public = False
    paths = (
        "/etc/cloudflared/config.yml",
        "/etc/cloudflared/config.yaml",
        "/root/.cloudflared/config.yml",
        "/root/.cloudflared/config.yaml",
    )
    for path in paths:
        if not os.path.isfile(path):
            continue
        try:
            with open(path, "r", errors="ignore") as handle:
                lines = handle.readlines()
        except Exception:
            continue
        hostname = None
        for raw in lines:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            match = re.match(r"hostname:\s*[\"']?([^\"'\s]+)", line)
            if match:
                hostname = match.group(1)
                continue
            match = re.match(r"service:\s*[\"']?(https?://\S+)", line)
            if match and hostname:
                if any_public([hostname]):
                    public = True
                    host, port = split_host_port(re.sub(r"^https?://", "", re.sub(r"[\"']$", "", match.group(1))).split("/")[0])
                    emit("backend", host, port)
                hostname = None
    return public

def scan_plex():
    candidates = [
        "/var/lib/plexmediaserver/Library/Application Support/Plex Media Server/Preferences.xml",
    ]
    candidates.extend(glob.glob("/var/lib/plexmediaserver/**/Preferences.xml", recursive=True))
    seen = set()
    for path in candidates:
        if path in seen or not os.path.isfile(path):
            continue
        seen.add(path)
        try:
            import xml.etree.ElementTree as ET
            root = ET.parse(path).getroot()
        except Exception:
            continue
        attrs = root.attrib
        published = str(attrs.get("PublishServerOnPlexOnlineKey", "0")).lower()
        mapped = str(attrs.get("LastAutomaticMappedPort", "0"))
        manual = str(attrs.get("ManualPortMappingMode", "0")).lower()
        if published in ("1", "true") or manual in ("1", "true") or (mapped.isdigit() and int(mapped) > 0):
            emit("direct", "deb:plexmediaserver")
            return

npm_public = scan_npm_sqlite()
nginx_public = scan_nginx()
cf_public = scan_cloudflared()
npm_layout = os.path.isdir("/data/nginx/proxy_host") or os.path.isfile("/data/database.sqlite")
if npm_public or (nginx_public and npm_layout):
    emit("edge", "app:nginx-proxy-manager")
    emit("edge", "app:openresty")
elif nginx_public:
    emit("edge", "deb:nginx")
    emit("edge", "app:openresty")
if cf_public:
    emit("edge", "app:cloudflared")
scan_plex()
PY
}

process_exposure_facts() {
  local ctid="$1" line kind field_a field_b field_c backend_ctid port ident label matched

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    IFS='|' read -r kind field_a field_b field_c <<<"${line}"
    case "${kind}" in
      edge)
        set_detected_exposure "${ctid}" "${field_a}" "internet"
        ;;
      direct)
        set_detected_exposure "${ctid}" "${field_a}" "internet"
        ;;
      backend)
        backend_ctid="$(lookup_ctid "${field_a}")"
        [[ -n "${backend_ctid}" ]] || continue
        port="${field_b}"
        label="${field_c:-internet-via-proxy}"
        matched=0
        if [[ -n "${port}" ]]; then
          while IFS='|' read -r _ _ ident; do
            [[ -n "${ident}" ]] || continue
            set_detected_exposure "${backend_ctid}" "${ident}" "${label}"
            matched=1
          done < <(awk -F'|' -v c="${backend_ctid}" -v p="${port}" '$1 == c && $2 == p { print }' <<<"${PORT_BINDINGS}")
          while IFS='|' read -r _ ident; do
            [[ -n "${ident}" ]] || continue
            if ct_has_identifier "${backend_ctid}" "${ident}"; then
              set_detected_exposure "${backend_ctid}" "${ident}" "${label}"
              matched=1
            fi
          done < <(awk -F'|' -v p="${port}" '$1 == p { print }' <<<"${KNOWN_PORTS}")
        fi
        if [[ "${matched}" -eq 0 ]]; then
          set_detected_exposure "${backend_ctid}" "*" "${label}"
        fi
        ;;
    esac
  done
}

collect_lxc_guest_exposure() {
  local ctid="$1" facts
  timeout 10s pct exec "${ctid}" -- python3 -c 'print(1)' >/dev/null 2>&1 || return 0
  facts="$(timeout 30s pct exec "${ctid}" -- python3 -c "$(exposure_probe_python)" 2>/dev/null || true)"
  process_exposure_facts "${ctid}" <<<"${facts}"
}

apply_detected_exposure() {
  COMPONENTS="$(jq -c --argjson detected "${DETECTED_EXPOSURE}" '
    def rank($e):
      if $e == "internet" then 4
      elif $e == "Public" or $e == "internet-via-proxy" then 3
      elif $e != null and $e != "" and $e != "lan-only" and $e != "vpn-only" then 2
      elif $e == "vpn-only" then 1
      else 0 end;
    def ctid:
      ((.product | capture("LXC guest (?<id>[0-9]+)") | .id) // "");
    def infra:
      (.kind == "operating-system")
      or (.kind == "platform")
      or (.identifier | test("^(deb:docker-ce|deb:containerd\\.io|app:nodejs|app:uv|app:par2cmdline-turbo)$"))
      or (.identifier | test("\\.failed$"));
    map(
      . as $c
      | ctid as $id
      | ($detected[$id][$c.identifier] // (
          if ($id != "" and ($detected[$id]["*"] // null) != null and ($c | infra | not))
          then $detected[$id]["*"]
          else null end
        )) as $new
      | if $new != null and rank($new) > rank($c.exposure)
        then .exposure = $new
        else .
        end
    )
  ' <<<"${COMPONENTS}")"
}

apply_exposure_overrides() {
  local line key exp overrides
  [[ -r "${EXPOSURE_MAP_FILE}" ]] || return 0

  overrides='{}'
  while IFS= read -r line || [[ -n "${line}" ]]; do
    line="${line%%#*}"
    key="$(awk '{print $1}' <<<"${line}")"
    exp="$(awk '{$1=""; sub(/^[[:space:]]+/, ""); print}' <<<"${line}")"
    [[ -n "${key}" && -n "${exp}" ]] || continue
    overrides="$(jq -c --arg k "${key}" --arg e "${exp}" '.[$k] = $e' <<<"${overrides}")"
  done <"${EXPOSURE_MAP_FILE}"

  COMPONENTS="$(jq -c --argjson o "${overrides}" '
    def ctid:
      ((.product | capture("LXC guest (?<id>[0-9]+)") | .id) // "");
    map(
      ctid as $id
      | ($o[.identifier + "@" + $id] // $o[.identifier] // null) as $new
      | if $new != null then .exposure = $new else . end
    )
  ' <<<"${COMPONENTS}")"
}

collect_lxc_guests() {
  local ctid
  local -a ctids

  mapfile -t ctids < <(pct list 2>/dev/null | awk 'NR > 1 && $2 == "running" {print $1}')

  for ctid in "${ctids[@]}"; do
    # CTID labels guest rows; hostnames, names, IPs, and internal endpoints are omitted.
    record_guest_addresses "${ctid}"
    collect_lxc_guest_apps "${ctid}"
    collect_lxc_guest_docker "${ctid}"
  done

  for ctid in "${ctids[@]}"; do
    collect_lxc_guest_exposure "${ctid}"
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
apply_detected_exposure
apply_exposure_overrides

# Combine identical deployments after CTID labels separate guest-specific rows.
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
