# Homelab inventory collector

This collector runs on a Proxmox VE host, builds a sanitized software inventory,
and uploads it to the configured Cloudflare Worker.

It discovers:

- Proxmox VE and the host Debian release
- Linux distribution releases in running LXC guests
- Main applications in those guests: known Debian packages (UniFi,
  Homebridge, Grafana, and similar), community-scripts version
  markers, and Node apps under `/opt` (Uptime Kuma, Nginx Proxy Manager, Immich,
  and others). Display names and public source URLs are mapped from a catalog;
  unlisted apps still appear if a version file or `package.json` is found
- Public image metadata, tags, OCI versions, and digests for running Docker
  containers inside LXCs. Private registry hosts, IPs, and ports are stripped
  from `image`/`identifier`; digests are stored as `sha256:…` only; OCI
  `source` is kept only for public HTTPS URLs
- Optional components emitted by executable scripts in `collectors.d/`

`exposure` is a reachability label for the monitor, not a guarantee of a
current WAN path. Values are `internet`, `internet-via-proxy`, `vpn-only`,
and `lan-only`. Guests start as `DEFAULT_EXPOSURE` (usually `lan-only`).
Proxmox VE and the host OS stay `vpn-only` unless overridden.

The collector then upgrades guest apps when it can do so without publishing
hostnames or IPs:

- Nginx Proxy Manager SQLite (`/data/database.sqlite`) and generated proxy
  host configs: a public DNS name (not `.local` / `.lan` / an IP) marks the
  proxy as `internet` and the matched backend app as `internet-via-proxy`
- Other nginx/OpenResty `server_name` + `proxy_pass` configs, and
  `cloudflared` ingress hostnames, use the same rule
- Plex `Preferences.xml` remote-access flags
  (`PublishServerOnPlexOnlineKey`, a mapped port, or manual port mapping)
  mark Plex as `internet`

Backends are matched to LXC guests by unpublished IP/hostname, then by
published Docker ports or well-known app ports. Operating systems and helper
packages (Docker Engine, containerd, Node.js, and similar) stay `lan-only`.

This cannot see a router port-forward that never hits a reverse proxy, UniFi
cloud remote access, or whether a public NPM hostname is only used via split
DNS. Those cases need a manual tag.

Create `/root/scripts/inventory/exposure.map` to force a value. Overrides
always win, including downgrades:

```text
# identifier[@ctid]  exposure
deb:plexmediaserver internet
app:seerr internet-via-proxy
app:homepage@111 lan-only
```

Rows collected from LXC guests include numeric LXC IDs to distinguish otherwise
identical OS releases, applications, and container images. It deliberately does
not publish Proxmox node names, LXC names, container names, IP addresses, ports,
or internal domains. Identical components are aggregated with
`deployment_count`.

## Install

On the Proxmox host:

```bash
apt update
apt install -y jq curl
mkdir -p /root/scripts/inventory/collectors.d
```

Place `update-inventory.sh` in `/root/scripts/inventory/`, then:

```bash
chmod 700 /root/scripts/inventory/update-inventory.sh
```

The existing `/root/scripts/inventory/.env` should contain:

```text
WRITE_TOKEN=your_64_character_write_token
READ_TOKEN=your_64_character_read_token
WORKER_BASE_URL=https://your-worker.example.workers.dev
DEFAULT_EXPOSURE=lan-only
```

Keep it private:

```bash
chmod 600 /root/scripts/inventory/.env
```

Run and inspect the collector before scheduling it:

```bash
/root/scripts/inventory/update-inventory.sh
jq . /root/scripts/inventory/inventory.json
```

Install the systemd unit and timer:

```bash
cp homelab-inventory.service /etc/systemd/system/
cp homelab-inventory.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now homelab-inventory.timer
systemctl start homelab-inventory.service
```

Verify:

```bash
systemctl list-timers homelab-inventory.timer
journalctl -u homelab-inventory.service -n 50 --no-pager
```

The timer runs daily at 04:15 in the Proxmox host's local timezone, with up to
15 minutes of randomized delay. `Persistent=true` runs a missed update after the
host next starts.

## Optional collectors

Separate VMs and physical systems are intentionally not queried automatically.
To add one, create an executable script in
`/root/scripts/inventory/collectors.d/` that emits one compact JSON object per
line. For example:

```json
{"product":"Example App","version":"1.2.3","channel":"stable","exposure":"lan-only","kind":"application","source":"https://example.invalid/releases"}
```

Never emit credentials, IP addresses, hostnames, internal domains, ports, or
network topology.
