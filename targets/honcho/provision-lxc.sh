#!/usr/bin/env bash
# Create or reconfigure a dedicated CPU-only Honcho LXC on the router's PVE host.
set -Eeuo pipefail
umask 077

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
source "$(dirname -- "${BASH_SOURCE[0]}")/pve-select.sh"
usage() {
  cat <<'USAGE'
Usage: CT_ID=285 ROUTER_CT_ID=280 TEMPLATE=local:vztmpl/debian-13-standard_..._amd64.tar.zst \
       STORAGE=local-lvm IP_CIDR=192.168.11.85/24 GATEWAY=192.168.11.1 \
       OPENWEBUI_ADMIN_TOKEN=... bash provision-lxc.sh [--dry-run|--reconfigure]

Creates an unprivileged Debian 13 LXC with native PostgreSQL/pgvector,
Honcho API and deriver services, and Honcho's Streamable HTTP MCP server. The
chat model uses the router; HONCHO_MODEL=fast by default. Set
HONCHO_EMBEDDING_MODEL and HONCHO_EMBEDDING_DIMENSIONS for an embedding model.
HONCHO_EMBEDDING_BASE_URL can point directly to its OpenAI-compatible /v1
endpoint; by default Honcho asks the router /v1/embeddings. HONCHO_REF may pin an upstream tag or
commit. HONCHO_CLIENT_IPS is a space-separated list of agent CT addresses to
allow through the Proxmox firewall. The router CT is always allowed.

This target registers the MCP server in Open WebUI. --reconfigure updates an
existing Honcho CT and the registration without deleting its PostgreSQL data.
USAGE
}
mode=create; dry_run=0
for arg in "$@"; do
  case $arg in
    --dry-run) dry_run=1 ;;
    --reconfigure) mode=reconfigure ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
done
CT_ID=${CT_ID:-}
ROUTER_CT_ID=${ROUTER_CT_ID:-${ROUTER:-}}
TEMPLATE=${TEMPLATE:-}
STORAGE=${STORAGE:-}
IP_CIDR=${IP_CIDR:-}
GATEWAY=${GATEWAY:-}
BRIDGE=${BRIDGE:-vmbr0}
NAMESERVER=${NAMESERVER:-}
VLAN_TAG=${VLAN_TAG:-}
CORES=${CORES:-4}
MEMORY_MB=${MEMORY_MB:-8192}
SWAP_MB=${SWAP_MB:-1024}
ROOTFS_GB=${ROOTFS_GB:-48}
ONBOOT=${ONBOOT:-1}
CT_HOSTNAME=${CT_HOSTNAME:-honcho-ai}
OPENWEBUI_PORT=${OPENWEBUI_PORT:-8080}
HONCHO_MODEL=${HONCHO_MODEL:-fast}
HONCHO_REF=${HONCHO_REF:-main}
HONCHO_EMBEDDING_MODEL=${HONCHO_EMBEDDING_MODEL:-}
HONCHO_EMBEDDING_DIMENSIONS=${HONCHO_EMBEDDING_DIMENSIONS:-}
HONCHO_EMBEDDING_BASE_URL=${HONCHO_EMBEDDING_BASE_URL:-}
HONCHO_EMBEDDING_DIMENSIONS_MODE=${HONCHO_EMBEDDING_DIMENSIONS_MODE:-never}
honcho_clients_explicit=${HONCHO_CLIENT_IPS+x}
HONCHO_CLIENT_IPS=${HONCHO_CLIENT_IPS:-}
[[ $CT_ID =~ ^[1-9][0-9]{2,8}$ && $ROUTER_CT_ID =~ ^[1-9][0-9]{2,8}$ ]] ||
  die 'Set valid CT_ID and ROUTER_CT_ID (both >=100).'
if [[ $mode == reconfigure && -z $IP_CIDR && $dry_run == 0 ]]; then
  IP_CIDR=$(pct config "$CT_ID" 2>/dev/null |
    sed -n 's/^net0:.*ip=\([^,]*\).*/\1/p' | head -n1)
fi
if [[ $mode == create ]]; then
  pve_select_template TEMPLATE '^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/debian-13-[A-Za-z0-9._-]+_amd64\.tar\.(zst|xz|gz)$'
  pve_select_storage STORAGE rootdir "$ROOTFS_GB"
fi
[[ $CT_ID != "$ROUTER_CT_ID" ]] || die 'Honcho and router CT IDs must differ.'
[[ $OPENWEBUI_PORT =~ ^[0-9]{2,5}$ ]] && (( OPENWEBUI_PORT <= 65535 )) || die 'Invalid OPENWEBUI_PORT.'
[[ $HONCHO_MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._:/+-]*$ ]] || die 'Invalid HONCHO_MODEL.'
[[ $HONCHO_EMBEDDING_MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._:/+-]*$ ]] || die 'Set HONCHO_EMBEDDING_MODEL.'
[[ $HONCHO_EMBEDDING_DIMENSIONS =~ ^[1-9][0-9]{0,5}$ ]] || die 'Set HONCHO_EMBEDDING_DIMENSIONS.'
[[ -z $HONCHO_EMBEDDING_BASE_URL || $HONCHO_EMBEDDING_BASE_URL =~ ^https?://[A-Za-z0-9][A-Za-z0-9._-]*:[0-9]{1,5}/v1/?$ ]] || die 'Invalid HONCHO_EMBEDDING_BASE_URL; use host:port/v1.'
[[ $HONCHO_EMBEDDING_DIMENSIONS_MODE =~ ^(never|auto|always)$ ]] || die 'Invalid HONCHO_EMBEDDING_DIMENSIONS_MODE.'
[[ $HONCHO_REF =~ ^(main|v[0-9][A-Za-z0-9._-]*|[0-9a-f]{40})$ ]] || die 'Invalid HONCHO_REF.'
[[ $BRIDGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid BRIDGE.'
if [[ $mode == create ]]; then [[ $STORAGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid STORAGE.'; fi
[[ $CT_HOSTNAME =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,61}$ ]] || die 'Invalid CT_HOSTNAME.'
for number in CORES MEMORY_MB ROOTFS_GB; do
  [[ ${!number} =~ ^[1-9][0-9]*$ ]] || die "Invalid $number."
done
[[ $SWAP_MB =~ ^(0|[1-9][0-9]*)$ && $ONBOOT =~ ^[01]$ ]] || die 'Invalid SWAP_MB or ONBOOT.'
[[ -z $VLAN_TAG || $VLAN_TAG =~ ^[1-9][0-9]{0,3}$ ]] || die 'Invalid VLAN_TAG.'
[[ -z $NAMESERVER || $NAMESERVER =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die 'Invalid NAMESERVER.'
[[ $IP_CIDR =~ ^[0-9]+(\.[0-9]+){3}/[0-9]{1,2}$ ]] || die 'Set a static IP_CIDR.'
if [[ $mode == create ]]; then
  [[ $GATEWAY =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die 'Set a static GATEWAY.'
  [[ $TEMPLATE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/debian-13-[A-Za-z0-9._-]+_amd64\.tar\.(zst|xz|gz)$ ]] ||
    die 'TEMPLATE must be a downloaded Debian 13 amd64 LXC template.'
fi
for ip in $HONCHO_CLIENT_IPS; do
  [[ $ip =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "Invalid HONCHO_CLIENT_IPS address: $ip"
done
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
for file in install-target.sh honcho-api.service honcho-deriver.service honcho-mcp.service integrate-webui.py; do
  [[ -r $source_dir/$file ]] || die "Missing $source_dir/$file"
done
honcho_ip=${IP_CIDR%/*}
stage=$(mktemp -d "${TMPDIR:-/tmp}/honcho-target.XXXXXX")
router_stage="/root/honcho-integration-$$"
cleanup() {
  if (( ! dry_run )); then pct exec "$ROUTER_CT_ID" -- rm -rf -- "$router_stage" >/dev/null 2>&1 || true; fi
  rm -rf -- "$stage"
}
trap cleanup EXIT
if (( dry_run )); then
  printf 'Would %s Honcho CT %s at %s with %s, then register MCP in router CT %s.\n' \
    "$mode" "$CT_ID" "$honcho_ip" "$HONCHO_REF" "$ROUTER_CT_ID"
  exit 0
fi
[[ $(id -u) == 0 ]] || die 'Run as root on the Proxmox host.'
for tool in pct pvesh pvesm curl; do command -v "$tool" >/dev/null || die "Missing $tool"; done
pct status "$ROUTER_CT_ID" 2>/dev/null | grep -q 'status: running' || die "Router CT $ROUTER_CT_ID is not running."
router_ip=$(pct exec "$ROUTER_CT_ID" -- ip -4 route get "$honcho_ip" |
  sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1)
[[ $router_ip =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die 'Cannot detect router source IP for Honcho.'
router_port=$(pct exec "$ROUTER_CT_ID" -- sh -c "sed -n 's/^ROUTER_PORT=//p' /app/router/.env | head -n1" | tr -d '\r\n')
router_port=${router_port:-8000}
[[ $router_port =~ ^[0-9]{2,5}$ ]] || die 'Invalid router port.'
router_url="http://${router_ip}:${router_port}"
pct exec "$ROUTER_CT_ID" -- awk -F= '$1=="ROUTER_API_KEY" {sub(/^[^=]*=/,""); print; exit}' \
  /app/router/secrets.env > "$stage/router-api-key"
[[ -s $stage/router-api-key ]] || printf 'no-key\n' > "$stage/router-api-key"

fw_file="/etc/pve/firewall/${CT_ID}.fw"
if [[ $mode == create && -e $fw_file ]]; then die "Refusing to replace $fw_file"; fi
if [[ $mode == reconfigure && -z $honcho_clients_explicit && -f $fw_file ]]; then
  HONCHO_CLIENT_IPS=$(awk '
    / # osr-honcho-api$/ { split($4, parts, "/"); clients[parts[1]]=1 }
    / # osr-honcho-mcp$/ { split($4, parts, "/"); router[parts[1]]=1 }
    END { for (ip in clients) if (!(ip in router)) print ip }
  ' "$fw_file" | sort -u | paste -sd' ' -)
fi
for ip in $HONCHO_CLIENT_IPS; do
  [[ $ip =~ ^[0-9]+(\.[0-9]+){3}$ ]] || die "Invalid HONCHO_CLIENT_IPS address: $ip"
done
if [[ $mode == create ]]; then
  pvesh get /cluster/nextid --vmid "$CT_ID" >/dev/null 2>&1 || die "CT $CT_ID already exists."
  [[ -r $(pvesm path "$TEMPLATE") ]] || die "Template is unreadable: $TEMPLATE"
  net="name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,gw=$GATEWAY,firewall=1"
  [[ -z $VLAN_TAG ]] || net+=",tag=$VLAN_TAG"
  create=(pct create "$CT_ID" "$TEMPLATE" --hostname "$CT_HOSTNAME" --ostype debian
    --unprivileged 1 --features nesting=1 --cores "$CORES" --memory "$MEMORY_MB"
    --swap "$SWAP_MB" --rootfs "$STORAGE:$ROOTFS_GB" --net0 "$net"
    --onboot "$ONBOOT" --tags 'ai;ai-tools;osr-target;honcho'
    --description 'Honcho AI for Ollama Smart Router')
  [[ -z $NAMESERVER ]] || create+=(--nameserver "$NAMESERVER")
  (umask 022; "${create[@]}")
  pct start "$CT_ID"
else
  pct status "$CT_ID" 2>/dev/null | grep -q 'status: running' || die "Honcho CT $CT_ID is not running."
  pct config "$CT_ID" | grep -qx 'description: Honcho AI for Ollama Smart Router' ||
    die "CT $CT_ID is not marked as this target's Honcho CT."
fi

honcho_rules() {
  for ip in $router_ip $HONCHO_CLIENT_IPS; do
    printf 'IN ACCEPT -source %s/32 -p tcp -dport 8000 -log nolog # osr-honcho-api\n' "$ip"
    [[ $ip != "$router_ip" ]] || printf 'IN ACCEPT -source %s/32 -p tcp -dport 3000 -log nolog # osr-honcho-mcp\n' "$ip"
  done
}
rules=$(honcho_rules)
if [[ $mode == reconfigure && -f $fw_file ]]; then
  awk -v rules="$rules" '
    $0 == "[RULES]" { print; print rules; seen=1; next }
    $0 !~ / # osr-honcho-(api|mcp)$/ { print }
    END { if (!seen) { print "[RULES]"; print rules } }
  ' "$fw_file" > "$stage/firewall.new"
  cat "$stage/firewall.new" > "$fw_file"
else
  printf '[OPTIONS]\nenable: 1\npolicy_in: DROP\npolicy_out: ACCEPT\n\n[RULES]\n%s\n' "$rules" > "$fw_file"
fi

for attempt in {1..60}; do
  if pct exec "$CT_ID" -- sh -c 'test -d /run/systemd/system && ip route show default | grep -q . && getent hosts github.com >/dev/null' 2>/dev/null; then break; fi
  (( attempt < 60 )) || die 'Honcho CT did not get network and systemd readiness.'
  sleep 2
done
pct exec "$CT_ID" -- install -d -m 0700 /root/honcho-deploy
for file in install-target.sh honcho-api.service honcho-deriver.service honcho-mcp.service; do
  pct push "$CT_ID" "$source_dir/$file" "/root/honcho-deploy/$file" --perms 0600
done
pct push "$CT_ID" "$stage/router-api-key" /root/honcho-deploy/router-api-key --perms 0600
pct exec "$CT_ID" -- env "ROUTER_URL=$router_url" "HONCHO_MODEL=$HONCHO_MODEL" \
  "HONCHO_REF=$HONCHO_REF" "HONCHO_EMBEDDING_MODEL=$HONCHO_EMBEDDING_MODEL" \
  "HONCHO_EMBEDDING_DIMENSIONS=$HONCHO_EMBEDDING_DIMENSIONS" \
  "HONCHO_EMBEDDING_BASE_URL=$HONCHO_EMBEDDING_BASE_URL" \
  "HONCHO_EMBEDDING_DIMENSIONS_MODE=$HONCHO_EMBEDDING_DIMENSIONS_MODE" \
  bash /root/honcho-deploy/install-target.sh
pct exec "$ROUTER_CT_ID" -- curl -fsS --max-time 10 "http://${honcho_ip}:3000/health" >/dev/null ||
  die 'Router CT cannot reach Honcho MCP; check the CT firewall.'

[[ -n ${OPENWEBUI_ADMIN_TOKEN:-} ]] || die 'OPENWEBUI_ADMIN_TOKEN is needed to register Honcho MCP.'
printf '%s\n' "$OPENWEBUI_ADMIN_TOKEN" > "$stage/openwebui-admin-token"
pct exec "$CT_ID" -- cat /etc/honcho-target/api-key > "$stage/honcho-api-key"
[[ -s $stage/honcho-api-key ]] || die 'Honcho did not generate an API key.'
pct exec "$ROUTER_CT_ID" -- install -d -m 0700 "$router_stage"
pct push "$ROUTER_CT_ID" "$source_dir/integrate-webui.py" "$router_stage/integrate-webui.py" --perms 0600
pct push "$ROUTER_CT_ID" "$stage/openwebui-admin-token" "$router_stage/admin-token" --perms 0600
pct push "$ROUTER_CT_ID" "$stage/honcho-api-key" "$router_stage/honcho-api-key" --perms 0600
pct exec "$ROUTER_CT_ID" -- python3 "$router_stage/integrate-webui.py" \
  "http://127.0.0.1:$OPENWEBUI_PORT" "$router_stage/admin-token" "$router_stage/honcho-api-key" \
  "http://${honcho_ip}:3000"
printf 'Honcho API: http://%s:8000; MCP: http://%s:3000/mcp\n' "$honcho_ip" "$honcho_ip"
