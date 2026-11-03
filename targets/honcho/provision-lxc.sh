#!/usr/bin/env bash
# Create or reconfigure a dedicated CPU-only Honcho LXC on the router's PVE host.
set -Eeuo pipefail
umask 077

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
# Router firewall helper
# router_fw_with_honcho FILE IP PORT: FILE with this target's one rule (IP to
# the router API PORT) first in [RULES]; an older one is dropped, the rest kept.
router_fw_with_honcho() {
  awk -v rule="IN ACCEPT -source $2/32 -p tcp -dport $3 -log nolog # osr-honcho-router" '
    / # osr-honcho-router$/ { next }
    $0 == "[RULES]" && !seen { print; print rule; seen=1; next }
    { print }
    END { if (!seen) { print ""; print "[RULES]"; print rule } }
  ' "$1"
}
# End router firewall helper.
source "$(dirname -- "${BASH_SOURCE[0]}")/pve-select.sh"
usage() {
  cat <<'USAGE'
Usage: CT_ID=285 ROUTER_CT_ID=280 TEMPLATE=local:vztmpl/debian-13-standard_..._amd64.tar.zst \
       STORAGE=local-lvm IP_CIDR=192.168.11.85/24 GATEWAY=192.168.11.1 \
       OPENWEBUI_ADMIN_TOKEN=... bash provision-lxc.sh [--dry-run] [--reconfigure [--rotate-keys]]

Creates an unprivileged Debian 13 LXC with native PostgreSQL/pgvector,
Honcho API and deriver services, and Honcho's Streamable HTTP MCP server. The
chat model uses the router; HONCHO_MODEL=fast by default. Set
HONCHO_EMBEDDING_MODEL and HONCHO_EMBEDDING_DIMENSIONS for an embedding model.
HONCHO_EMBEDDING_BASE_URL can point directly to its OpenAI-compatible /v1
endpoint; by default Honcho asks the router /v1/embeddings. HONCHO_REF
(default v3.5.0) may select another upstream tag, main, or a commit. HONCHO_CLIENT_IPS is a space-separated list of agent CT addresses to
allow through the Proxmox firewall. The router CT is always allowed.

HONCHO_STRUCTURED_OUTPUT_MODE=json_object is for a router model whose backend
lacks JSON-schema output; the install probes the model with tools and
structured output first (HONCHO_SKIP_CHAT_PROBE=true skips that). Another Bun
than 1.4.4 needs HONCHO_BUN_VERSION with HONCHO_BUN_SHA256 (bun-linux-x64.zip)
or HONCHO_BUN_BASELINE_SHA256 (CPUs without AVX2). If the router CT has a
Proxmox firewall file, a rule admitting this CT to the router API is kept in
it (HONCHO_ROUTER_FIREWALL=false leaves that file alone).

This target registers the MCP server in Open WebUI. --reconfigure updates an
existing Honcho CT and the registration without deleting its PostgreSQL data;
every reconfigure dumps the database before migrations and restores it if the
guest setup fails. --rotate-keys (with --reconfigure) replaces the JWT secret and
both keys; reconfigure Hermes and OpenClaw with HONCHO_CT_ID afterwards.
USAGE
}
mode=create; dry_run=0; rotate_keys=false
for arg in "$@"; do
  case $arg in
    --dry-run) dry_run=1 ;;
    --reconfigure) mode=reconfigure ;;
    --rotate-keys) rotate_keys=true ;;
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
HONCHO_REF=${HONCHO_REF:-v3.5.0}
HONCHO_EMBEDDING_MODEL=${HONCHO_EMBEDDING_MODEL:-}
HONCHO_EMBEDDING_DIMENSIONS=${HONCHO_EMBEDDING_DIMENSIONS:-}
HONCHO_EMBEDDING_BASE_URL=${HONCHO_EMBEDDING_BASE_URL:-}
HONCHO_EMBEDDING_DIMENSIONS_MODE=${HONCHO_EMBEDDING_DIMENSIONS_MODE:-never}
HONCHO_STRUCTURED_OUTPUT_MODE=${HONCHO_STRUCTURED_OUTPUT_MODE:-}
HONCHO_SKIP_CHAT_PROBE=${HONCHO_SKIP_CHAT_PROBE:-false}
HONCHO_ROUTER_FIREWALL=${HONCHO_ROUTER_FIREWALL:-true}
HONCHO_BUN_VERSION=${HONCHO_BUN_VERSION:-}
HONCHO_BUN_SHA256=${HONCHO_BUN_SHA256:-}
HONCHO_BUN_BASELINE_SHA256=${HONCHO_BUN_BASELINE_SHA256:-}
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
[[ -z $HONCHO_EMBEDDING_BASE_URL || $HONCHO_EMBEDDING_BASE_URL =~ ^https?://[A-Za-z0-9][A-Za-z0-9._-]*(:[0-9]{1,5})?/v1/?$ ]] || die 'Invalid HONCHO_EMBEDDING_BASE_URL; use http(s)://host[:port]/v1.'
[[ $HONCHO_EMBEDDING_DIMENSIONS_MODE =~ ^(never|auto|always)$ ]] || die 'Invalid HONCHO_EMBEDDING_DIMENSIONS_MODE.'
[[ -z $HONCHO_STRUCTURED_OUTPUT_MODE || $HONCHO_STRUCTURED_OUTPUT_MODE =~ ^(json_schema|json_object)$ ]] || die 'HONCHO_STRUCTURED_OUTPUT_MODE must be json_schema or json_object.'
[[ $HONCHO_SKIP_CHAT_PROBE =~ ^(true|false)$ ]] || die 'HONCHO_SKIP_CHAT_PROBE must be true or false.'
[[ $HONCHO_ROUTER_FIREWALL =~ ^(true|false)$ ]] || die 'HONCHO_ROUTER_FIREWALL must be true or false.'
[[ -z $HONCHO_BUN_VERSION || $HONCHO_BUN_VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid HONCHO_BUN_VERSION.'
for sha in "$HONCHO_BUN_SHA256" "$HONCHO_BUN_BASELINE_SHA256"; do
  [[ -z $sha || $sha =~ ^[0-9a-f]{64}$ ]] || die 'HONCHO_BUN_SHA256 and HONCHO_BUN_BASELINE_SHA256 are SHA-256 hex digests.'
done
if [[ -n $HONCHO_BUN_VERSION && $HONCHO_BUN_VERSION != 1.4.4 && -z $HONCHO_BUN_SHA256$HONCHO_BUN_BASELINE_SHA256 ]]; then
  die 'HONCHO_BUN_VERSION needs HONCHO_BUN_SHA256 (bun-linux-x64.zip) or HONCHO_BUN_BASELINE_SHA256 (no AVX2).'
fi
[[ $rotate_keys == false || $mode == reconfigure ]] || die '--rotate-keys needs --reconfigure: a new CT gets new keys anyway.'
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
rotation_stage="/root/honcho-rotation-$$"
rotation_pending=false
rotation_staged=false
# Set just before the router CT's staging directory is made: a run that stops
# earlier (not root, no token, router CT down) has nothing there to clean.
router_stage_created=false
rotation_files=(jwt-secret api-key client-api-key)
# Rotation recovery helper
# rotation_applied: the guest replaced the JWT secret. A guest that stopped
# before rotating (model probe, leftover rollback data, apt) leaves nothing to undo.
rotation_applied() {
  # An unreachable CT is unknown, not proof that the keys stayed unchanged.
  pct exec "$CT_ID" -- true >/dev/null 2>&1 || return 2
  if pct exec "$CT_ID" -- test -f "$rotation_stage/jwt-secret"; then
    ! pct exec "$CT_ID" -- cmp -s "$rotation_stage/jwt-secret" /etc/honcho-target/jwt-secret
  else
    pct exec "$CT_ID" -- test -f /etc/honcho-target/jwt-secret
  fi
}
# restore_rotation: only the credentials go back. The rest of honcho.env stays
# as this run wrote it, matching the code and schema the guest left running
# (its own rollback copies are gone once it succeeded); only its
# AUTH_JWT_SECRET line is set to the restored secret, read inside the CT so
# the secret is never on a command line.
restore_rotation() {
  local file attempt
  for file in "${rotation_files[@]}"; do
    if pct exec "$CT_ID" -- test -f "$rotation_stage/$file"; then
      pct exec "$CT_ID" -- cp -a -- "$rotation_stage/$file" "/etc/honcho-target/$file" || return 1
    else
      pct exec "$CT_ID" -- rm -f -- "/etc/honcho-target/$file" || return 1
    fi
  done
  pct exec "$CT_ID" -- python3 -c 'import pathlib
etc = pathlib.Path("/etc/honcho-target")
secret = (etc / "jwt-secret").read_text(encoding="utf-8").strip()
env = etc / "honcho.env"
lines = env.read_text(encoding="utf-8").splitlines()
lines = ["AUTH_JWT_SECRET=" + secret if line.startswith("AUTH_JWT_SECRET=") else line for line in lines]
env.write_text("\n".join(lines) + "\n", encoding="utf-8")' || return 1
  pct exec "$CT_ID" -- systemctl restart honcho-api.service honcho-deriver.service honcho-mcp.service || return 1
  for attempt in {1..30}; do
    if pct exec "$CT_ID" -- curl -fsS --max-time 2 http://127.0.0.1:8000/health >/dev/null &&
       pct exec "$CT_ID" -- curl -fsS --max-time 2 http://127.0.0.1:3000/health >/dev/null; then break; fi
    (( attempt < 30 )) || return 1
    sleep 2
  done
  pct exec "$ROUTER_CT_ID" -- python3 "$router_stage/integrate-webui.py" --restore \
    "http://127.0.0.1:$OPENWEBUI_PORT" "$router_stage/admin-token" \
    "$router_stage/webui-honcho-snapshot.json" || return 1
  pct exec "$CT_ID" -- rm -rf -- "$rotation_stage" || return 1
}
# clean_router_stage: the router CT's staging directory goes, unless a key
# rotation is still unresolved; then only the saved Open WebUI connection
# stays. Recovery is a plain --reconfigure, which pushes the credentials again.
clean_router_stage() {
  [[ $router_stage_created == true ]] || return 0
  if [[ $rotation_pending == false ]]; then
    pct exec "$ROUTER_CT_ID" -- rm -rf -- "$router_stage" >/dev/null 2>&1 ||
      printf 'Could not remove router CT %s:%s; it may still hold an Open WebUI admin token. Delete it when the CT is reachable.\n' \
        "$ROUTER_CT_ID" "$router_stage" >&2
  else
    pct exec "$ROUTER_CT_ID" -- rm -f -- "$router_stage/admin-token" "$router_stage/honcho-api-key" \
      "$router_stage/integrate-webui.py" >/dev/null 2>&1 ||
      printf 'Could not remove staged credentials from router CT %s:%s; delete admin-token and honcho-api-key when the CT is reachable.\n' \
        "$ROUTER_CT_ID" "$router_stage" >&2
  fi
}
# End rotation recovery helper.
cleanup() {
  local rc=$? applied_rc=0
  trap - EXIT
  if (( rc != 0 )) && [[ $rotation_pending == true ]]; then
    rotation_applied || applied_rc=$?
    if (( applied_rc == 1 )); then
      rotation_pending=false
      printf 'The run stopped before the Honcho keys were rotated; they are unchanged.\n' >&2
    elif (( applied_rc != 0 )); then
      printf 'Could not verify Honcho key rotation in CT %s; recovery files remain at %s.\n' \
        "$CT_ID" "$rotation_stage" >&2
      printf 'The previous Open WebUI connection remains in router CT %s:%s/webui-honcho-snapshot.json.\n' \
        "$ROUTER_CT_ID" "$router_stage" >&2
      printf 'Once CT %s is reachable and Honcho is healthy, run this provisioner again with --reconfigure\n' "$CT_ID" >&2
      printf '(without --rotate-keys): it registers Open WebUI with the key Honcho has then. Reconfigure Hermes\n' >&2
      printf 'and OpenClaw with HONCHO_CT_ID=%s if the keys did change, then remove both directories.\n' "$CT_ID" >&2
    fi
  fi
  if (( rc != 0 )) && [[ $rotation_pending == true && $applied_rc == 0 ]]; then
    if restore_rotation; then
      rotation_staged=false
      rotation_pending=false
      printf 'Honcho key rotation was undone after downstream setup failed.\n' >&2
    else
      printf 'Honcho key rotation could not be fully undone; the previous secret and keys remain in CT %s:%s.\n' \
        "$CT_ID" "$rotation_stage" >&2
      printf 'The previous Open WebUI connection remains in router CT %s:%s/webui-honcho-snapshot.json.\n' \
        "$ROUTER_CT_ID" "$router_stage" >&2
      printf 'Open WebUI may hold a key Honcho no longer accepts. Once Honcho is healthy, run this provisioner\n' >&2
      printf 'again with --reconfigure (without --rotate-keys): it registers Open WebUI with the key Honcho has\n' >&2
      printf 'now. Then reconfigure Hermes and OpenClaw with HONCHO_CT_ID=%s, and remove %s from CT %s.\n' \
        "$CT_ID" "$rotation_stage" "$CT_ID" >&2
      printf 'After recovery, also remove %s from router CT %s.\n' "$router_stage" "$ROUTER_CT_ID" >&2
    fi
  fi
  if [[ $rotation_staged == true && $rotation_pending == false ]]; then
    pct exec "$CT_ID" -- rm -rf -- "$rotation_stage" >/dev/null 2>&1 || true
  fi
  if (( ! dry_run )); then clean_router_stage; fi
  rm -rf -- "$stage"
  exit "$rc"
}
trap cleanup EXIT
if (( dry_run )); then
  printf 'Would %s Honcho CT %s at %s with %s, then register MCP in router CT %s.\n' \
    "$mode" "$CT_ID" "$honcho_ip" "$HONCHO_REF" "$ROUTER_CT_ID"
  [[ $HONCHO_ROUTER_FIREWALL == false ]] ||
    printf 'Would admit %s to the router API in /etc/pve/firewall/%s.fw, if that file exists.\n' "$honcho_ip" "$ROUTER_CT_ID"
  [[ $rotate_keys == false ]] || printf 'Would replace the JWT secret and both Honcho keys.\n'
  exit 0
fi
[[ $(id -u) == 0 ]] || die 'Run as root on the Proxmox host.'
# Checked before anything is created: the run ends by registering MCP.
[[ -n ${OPENWEBUI_ADMIN_TOKEN:-} ]] || die 'OPENWEBUI_ADMIN_TOKEN is needed to register Honcho MCP in Open WebUI.'
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
# Validate the admin token and endpoint before creating or modifying a Honcho CT.
printf '%s\n' "$OPENWEBUI_ADMIN_TOKEN" > "$stage/openwebui-admin-token"
router_stage_created=true
pct exec "$ROUTER_CT_ID" -- install -d -m 0700 "$router_stage"
pct push "$ROUTER_CT_ID" "$source_dir/integrate-webui.py" "$router_stage/integrate-webui.py" --perms 0600
pct push "$ROUTER_CT_ID" "$stage/openwebui-admin-token" "$router_stage/admin-token" --perms 0600
pct exec "$ROUTER_CT_ID" -- python3 "$router_stage/integrate-webui.py" --check \
  "http://127.0.0.1:$OPENWEBUI_PORT" "$router_stage/admin-token"
if [[ $rotate_keys == true ]]; then
  pct exec "$ROUTER_CT_ID" -- python3 "$router_stage/integrate-webui.py" --snapshot \
    "http://127.0.0.1:$OPENWEBUI_PORT" "$router_stage/admin-token" \
    "$router_stage/webui-honcho-snapshot.json"
fi

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

# The router CT's own firewall must let Honcho reach the router API. One owned
# rule, replaced when the Honcho address or router port changes; everything
# else in that file stays as it is.
router_fw="/etc/pve/firewall/${ROUTER_CT_ID}.fw"
if [[ $HONCHO_ROUTER_FIREWALL == true && -f $router_fw ]]; then
  router_fw_with_honcho "$router_fw" "$honcho_ip" "$router_port" > "$stage/router.fw"
  if ! cmp -s "$stage/router.fw" "$router_fw"; then
    cat "$stage/router.fw" > "$router_fw"
    printf 'Router CT %s firewall: admitted Honcho %s to port %s.\n' "$ROUTER_CT_ID" "$honcho_ip" "$router_port"
  fi
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
if [[ $rotate_keys == true ]]; then
  pct exec "$CT_ID" -- install -d -m 0700 "$rotation_stage"
  rotation_staged=true
  for file in "${rotation_files[@]}"; do
    if pct exec "$CT_ID" -- test -f "/etc/honcho-target/$file"; then
      pct exec "$CT_ID" -- cp -a -- "/etc/honcho-target/$file" "$rotation_stage/$file"
    fi
  done
  rotation_pending=true
fi
pct exec "$CT_ID" -- env "ROUTER_URL=$router_url" "HONCHO_MODEL=$HONCHO_MODEL" \
  "HONCHO_REF=$HONCHO_REF" "HONCHO_EMBEDDING_MODEL=$HONCHO_EMBEDDING_MODEL" \
  "HONCHO_EMBEDDING_DIMENSIONS=$HONCHO_EMBEDDING_DIMENSIONS" \
  "HONCHO_EMBEDDING_BASE_URL=$HONCHO_EMBEDDING_BASE_URL" \
  "HONCHO_EMBEDDING_DIMENSIONS_MODE=$HONCHO_EMBEDDING_DIMENSIONS_MODE" \
  "HONCHO_STRUCTURED_OUTPUT_MODE=$HONCHO_STRUCTURED_OUTPUT_MODE" \
  "HONCHO_SKIP_CHAT_PROBE=$HONCHO_SKIP_CHAT_PROBE" "HONCHO_ROTATE_KEYS=$rotate_keys" \
  ${HONCHO_BUN_VERSION:+"HONCHO_BUN_VERSION=$HONCHO_BUN_VERSION"} \
  ${HONCHO_BUN_SHA256:+"HONCHO_BUN_SHA256=$HONCHO_BUN_SHA256"} \
  ${HONCHO_BUN_BASELINE_SHA256:+"HONCHO_BUN_BASELINE_SHA256=$HONCHO_BUN_BASELINE_SHA256"} \
  bash /root/honcho-deploy/install-target.sh
pct exec "$ROUTER_CT_ID" -- curl -fsS --max-time 10 "http://${honcho_ip}:3000/health" >/dev/null ||
  die 'Router CT cannot reach Honcho MCP; check the CT firewall.'

# Open WebUI gets the key scoped to the osr workspace, not the admin key.
pct exec "$CT_ID" -- cat /etc/honcho-target/client-api-key > "$stage/honcho-api-key"
[[ -s $stage/honcho-api-key ]] || die 'Honcho did not generate its osr workspace key.'
pct push "$ROUTER_CT_ID" "$stage/honcho-api-key" "$router_stage/honcho-api-key" --perms 0600
pct exec "$ROUTER_CT_ID" -- python3 "$router_stage/integrate-webui.py" \
  "http://127.0.0.1:$OPENWEBUI_PORT" "$router_stage/admin-token" "$router_stage/honcho-api-key" \
  "http://${honcho_ip}:3000"
if [[ $rotate_keys == true ]]; then
  rotation_pending=false
  if ! pct exec "$CT_ID" -- rm -rf -- "$rotation_stage"; then
    printf 'Honcho is registered with rotated keys, but could not remove the old keys from CT %s:%s. Remove that directory manually.\n' \
      "$CT_ID" "$rotation_stage" >&2
  fi
  rotation_staged=false
fi
printf 'Honcho API: http://%s:8000; MCP: http://%s:3000/mcp\n' "$honcho_ip" "$honcho_ip"
if [[ $rotate_keys == true ]]; then
  printf 'The keys changed: Hermes and OpenClaw lose Honcho until each is reconfigured, e.g.\n'
  printf '  CT_ID=<agent CT> ROUTER_CT_ID=%s HONCHO_CT_ID=%s bash targets/hermes/provision-lxc.sh --reconfigure\n' "$ROUTER_CT_ID" "$CT_ID"
  printf '  CT_ID=<agent CT> ROUTER_CT_ID=%s HONCHO_CT_ID=%s bash targets/openclaw/provision-lxc.sh --reconfigure\n' "$ROUTER_CT_ID" "$CT_ID"
fi
