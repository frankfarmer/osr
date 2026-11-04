#!/usr/bin/env bash
# Run on the Proxmox host. Create or reconfigure a dedicated DeepSeek Harness
# LXC that uses an existing local OSR CT as its model provider and, optionally,
# Honcho as its long-term memory.
set -Eeuo pipefail
umask 077

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
source "$(dirname -- "${BASH_SOURCE[0]}")/pve-select.sh"
usage() {
  cat <<'USAGE'
Usage: bash provision-lxc.sh [--dry-run | --reconfigure]
Creates a dedicated unprivileged Debian 12/13 LXC for DeepSeek Harness Web.
The OSR router must be a running CT on the same Proxmox host. Its API key is
read from /app/router/secrets.env and copied to the new CT as a 0600 file.

Required: ROUTER_CT_ID, CT_ID; for a new CT also TEMPLATE, STORAGE, IP_CIDR,
  GATEWAY (interactive runs prompt for missing values).
Settings: DSH_MODEL=auto, DSH_CONTEXT_WINDOW=32768, DSH_MAX_TOKENS=8192,
  DSH_VERSION=0.2.1-rc.5 (or latest), DSH_PORT=3080,
  DSH_ACCESS_CIDR=<CT subnet>, DSH_ROUTER_FIREWALL=true.
Honcho memory: HONCHO_URL=http://<honcho-ip>:8000 with HONCHO_CT_ID (or
  HONCHO_API_KEY_FILE); HONCHO_MCP_URL overrides the derived
  http://<honcho-ip>:3000/mcp. HONCHO_URL= (set, empty) turns it off.
CT: BRIDGE=vmbr0, CT_HOSTNAME=deepseek-harness, CORES=2, MEMORY_MB=4096,
  SWAP_MB=1024, ROOTFS_GB=32, ONBOOT=1, NAMESERVER, VLAN_TAG.

--reconfigure updates the router key, model overlay, npm release, Honcho
memory and service inside the existing CT. It never creates or deletes a CT.
Settings it is not given keep the values the CT recorded on its last run.
USAGE
}

# Provision helpers
ipv4() {
  local octet
  local -a parts
  [[ $1 =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a parts <<< "$1"
  for octet in "${parts[@]}"; do
    [[ $octet =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( 10#$octet <= 255 )) || return 1
  done
}
valid_cidr() {
  local address prefix
  [[ $1 =~ ^([^/]+)/([0-9]{1,2})$ ]] || return 1
  address=${BASH_REMATCH[1]}; prefix=${BASH_REMATCH[2]}
  ipv4 "$address" && (( 10#$prefix >= 1 && 10#$prefix <= 32 ))
}
# cidr_network CIDR: the network address with its prefix (192.0.2.81/24 ->
# 192.0.2.0/24), the form a Proxmox firewall -source accepts.
cidr_network() {
  local address=${1%/*} prefix=${1#*/} a b c d value mask
  IFS=. read -r a b c d <<< "$address"
  value=$(( (a << 24) | (b << 16) | (c << 8) | d ))
  mask=$(( prefix == 0 ? 0 : (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
  value=$(( value & mask ))
  printf '%d.%d.%d.%d/%d\n' $(( value >> 24 & 255 )) $(( value >> 16 & 255 )) $(( value >> 8 & 255 )) $(( value & 255 )) "$prefix"
}
# record_value TEXT KEY: KEY's value in a KEY=VALUE record (never sourced).
record_value() {
  awk -v key="$2" 'index($0, key "=") == 1 { print substr($0, length(key) + 2); found=1; exit } END { exit !found }' <<< "$1"
}
# honcho_mcp_url API_URL: Honcho's MCP endpoint on the API's host (the Honcho
# target serves it on port 3000 at /mcp).
honcho_mcp_url() {
  [[ $1 =~ ^(https?)://([A-Za-z0-9][A-Za-z0-9._-]*)(:[0-9]{1,5})?/?$ ]] || return 1
  printf '%s://%s:3000/mcp\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}
# router_fw_with_dsh FILE IP PORT: FILE with this target's one rule (IP to the
# router API PORT) first in [RULES]; an older one is dropped, the rest kept.
router_fw_with_dsh() {
  awk -v rule="IN ACCEPT -source $2/32 -p tcp -dport $3 -log nolog # osr-deepseek-harness-router" '
    / # osr-deepseek-harness-router$/ { next }
    $0 == "[RULES]" && !seen { print; print rule; seen=1; next }
    { print }
    END { if (!seen) { print ""; print "[RULES]"; print rule } }
  ' "$1"
}
# End provision helpers.
positive() { [[ $2 =~ ^[1-9][0-9]{0,8}$ ]] || die "$1 must be a positive integer."; }
run() {
  printf '+'; printf ' %q' "$@"; printf '\n'
  if (( ! dry_run )); then "$@"; fi
}

dry_run=0
mode=create
while (( $# )); do
  case $1 in
    --dry-run) dry_run=1 ;;
    --reconfigure) mode=reconfigure ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done

ROUTER_CT_ID=${ROUTER_CT_ID:-${ROUTER:-}}
CT_ID=${CT_ID:-}
TEMPLATE=${TEMPLATE:-}
STORAGE=${STORAGE:-}
IP_CIDR=${IP_CIDR:-}
GATEWAY=${GATEWAY:-}
BRIDGE=${BRIDGE:-vmbr0}
CT_HOSTNAME=${CT_HOSTNAME:-deepseek-harness}
CORES=${CORES:-2}
MEMORY_MB=${MEMORY_MB:-4096}
SWAP_MB=${SWAP_MB:-1024}
ROOTFS_GB=${ROOTFS_GB:-32}
ONBOOT=${ONBOOT:-1}
NAMESERVER=${NAMESERVER:-}
VLAN_TAG=${VLAN_TAG:-}
DSH_ROUTER_FIREWALL=${DSH_ROUTER_FIREWALL:-true}
DEFAULT_DSH_VERSION=0.2.1-rc.5
# Harness settings: DSH_* or the installer's DEEPSEEK_HARNESS_* names. Unset
# ones keep the CT's recorded value on a reconfigure, else take the default.
declare -A dsh_default=([MODEL]=auto [CONTEXT_WINDOW]=32768 [MAX_TOKENS]=8192 [VERSION]=$DEFAULT_DSH_VERSION [PORT]=3080)
declare -A dsh_given=()
for name in MODEL CONTEXT_WINDOW MAX_TOKENS VERSION PORT; do
  short=DSH_$name long=DEEPSEEK_HARNESS_$name
  if [[ -n ${!short:-} ]]; then dsh_given[$name]=${!short}
  elif [[ -n ${!long:-} ]]; then dsh_given[$name]=${!long}; fi
done
DSH_ACCESS_CIDR=${DSH_ACCESS_CIDR:-${DEEPSEEK_HARNESS_ACCESS_CIDR:-}}
honcho_url_set=${HONCHO_URL+set} honcho_mcp_set=${HONCHO_MCP_URL+set}
HONCHO_URL=${HONCHO_URL:-}
HONCHO_MCP_URL=${HONCHO_MCP_URL:-}
HONCHO_CT_ID=${HONCHO_CT_ID:-}
HONCHO_API_KEY_FILE=${HONCHO_API_KEY_FILE:-}

pve_prompt_required ROUTER_CT_ID 'Existing OSR router CT ID on this PVE host'
pve_prompt_required CT_ID 'DeepSeek Harness CT ID'
[[ $ROUTER_CT_ID =~ ^[1-9][0-9]{2,8}$ && $CT_ID =~ ^[1-9][0-9]{2,8}$ ]] ||
  die 'ROUTER_CT_ID and CT_ID must be distinct numeric Proxmox IDs (100 or greater).'
[[ $ROUTER_CT_ID != "$CT_ID" ]] || die 'Harness and router CT IDs must differ.'
[[ -z $HONCHO_CT_ID || ( $HONCHO_CT_ID =~ ^[1-9][0-9]{2,8}$ && $HONCHO_CT_ID != "$CT_ID" ) ]] ||
  die 'HONCHO_CT_ID must be the Honcho CT ID (100 or greater), not this CT.'
if [[ $mode == create ]]; then
  positive ROOTFS_GB "$ROOTFS_GB"
  pve_select_template TEMPLATE '^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/debian-(12|13)-[A-Za-z0-9._-]+_amd64\.tar\.(zst|xz|gz)$'
  pve_select_storage STORAGE rootdir "$ROOTFS_GB"
  pve_prompt_required TEMPLATE 'Downloaded Debian 12/13 amd64 template'
  pve_prompt_required STORAGE 'Storage for the Harness CT root disk'
  pve_prompt_required IP_CIDR 'Static IP/CIDR for the Harness CT'
  pve_prompt_required GATEWAY 'Gateway for the Harness CT'
  [[ -n $DSH_ACCESS_CIDR ]] || DSH_ACCESS_CIDR=$IP_CIDR
fi
for name in CORES MEMORY_MB ROOTFS_GB; do positive "$name" "${!name}"; done
[[ $SWAP_MB =~ ^(0|[1-9][0-9]{0,8})$ && $ONBOOT =~ ^[01]$ ]] || die 'Invalid SWAP_MB or ONBOOT.'
[[ $BRIDGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid BRIDGE.'
[[ $CT_HOSTNAME =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || die 'Invalid CT_HOSTNAME.'
[[ -z $NAMESERVER ]] || ipv4 "$NAMESERVER" || die 'NAMESERVER must be IPv4.'
[[ -z $VLAN_TAG ]] || { positive VLAN_TAG "$VLAN_TAG"; (( VLAN_TAG <= 4094 )) || die 'VLAN_TAG must be <=4094.'; }
[[ -z $DSH_ACCESS_CIDR ]] || valid_cidr "$DSH_ACCESS_CIDR" || die 'DSH_ACCESS_CIDR must be an IPv4 CIDR.'
[[ $DSH_ROUTER_FIREWALL =~ ^(true|false)$ ]] || die 'DSH_ROUTER_FIREWALL must be true or false.'
[[ -z $HONCHO_URL ]] || honcho_mcp_url "$HONCHO_URL" >/dev/null ||
  die 'HONCHO_URL must be the Honcho API origin, e.g. http://192.0.2.85:8000.'
[[ -z $HONCHO_MCP_URL || $HONCHO_MCP_URL =~ ^https?://[A-Za-z0-9][A-Za-z0-9._-]*(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$ ]] ||
  die 'HONCHO_MCP_URL must be an HTTP(S) URL such as http://192.0.2.85:3000/mcp.'
[[ -z $HONCHO_API_KEY_FILE || -r $HONCHO_API_KEY_FILE ]] || die "Cannot read HONCHO_API_KEY_FILE: $HONCHO_API_KEY_FILE"
if [[ $mode == create ]]; then
  [[ $TEMPLATE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*:vztmpl/debian-(12|13)-[A-Za-z0-9._-]+_amd64\.tar\.(zst|xz|gz)$ ]] ||
    die 'TEMPLATE must be a Debian 12/13 amd64 archive.'
  [[ $STORAGE =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'Invalid STORAGE.'
  valid_cidr "$IP_CIDR" && ipv4 "$GATEWAY" || die 'IP_CIDR and GATEWAY must be valid IPv4 settings.'
fi

source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
for file in install-target.sh configure.mjs deepseek-harness.service; do
  [[ -r $source_dir/$file ]] || die "Deployment file missing: $source_dir/$file"
done
stage=$(mktemp -d "${TMPDIR:-/tmp}/deepseek-harness-target.XXXXXX")
trap 'rm -rf -- "$stage"' EXIT
deploy=/root/deepseek-harness-deploy

recorded=''
if (( ! dry_run )); then
  [[ $EUID -eq 0 ]] || die 'Run as root on the Proxmox host.'
  for command_name in pct pvesh pvesm; do
    command -v "$command_name" >/dev/null || die "Missing command: $command_name"
  done
  [[ -d /etc/pve/nodes ]] || die 'Proxmox cluster filesystem is unavailable.'
  pct status "$ROUTER_CT_ID" | grep -q 'status: running' || die 'The router CT is not running.'
  pct exec "$ROUTER_CT_ID" -- test -f /app/router/router.py || die 'The selected CT is not an OSR router.'
  if [[ $mode == create ]]; then
    pvesh get /cluster/nextid --vmid "$CT_ID" >/dev/null || die "CT ID $CT_ID is already used."
    [[ -d /sys/class/net/$BRIDGE ]] || die "Bridge does not exist: $BRIDGE"
    [[ -r $(pvesm path "$TEMPLATE") ]] || die "Template is unreadable: $TEMPLATE"
    pve_select_storage_rows rootdir | awk -F '\t' -v s="$STORAGE" '$1==s {found=1} END {exit !found}' ||
      die 'STORAGE is inactive or does not support rootdir.'
    [[ ! -e /etc/pve/firewall/${CT_ID}.fw ]] || die "Firewall file already exists for CT $CT_ID."
  else
    pct status "$CT_ID" | grep -q 'status: running' || die "Harness CT $CT_ID is not running."
    pct config "$CT_ID" | grep -qx 'description: DeepSeek Harness for Ollama Smart Router' ||
      die 'The selected CT is not this target; refusing to reconfigure it.'
    IP_CIDR=$(pct exec "$CT_ID" -- ip -4 -o addr show dev eth0 | awk 'NR==1 {print $4}')
    valid_cidr "$IP_CIDR" || die 'Cannot determine the Harness CT IPv4 address.'
    if [[ -z $DSH_ACCESS_CIDR ]]; then
      DSH_ACCESS_CIDR=$(sed -nE 's/.*-source ([0-9.]+\/[0-9]+).*# osr-deepseek-harness$/\1/p' "/etc/pve/firewall/${CT_ID}.fw" | head -n1)
    fi
    valid_cidr "$DSH_ACCESS_CIDR" || die 'Set DSH_ACCESS_CIDR to reconfigure this CT.'
    recorded=$(pct exec "$CT_ID" -- cat /etc/deepseek-harness/settings 2>/dev/null | tr -d '\r' || true)
  fi
fi

# --- Harness settings: given, else recorded (reconfigure), else default ------
for name in MODEL CONTEXT_WINDOW MAX_TOKENS VERSION PORT; do
  var=DSH_$name
  if [[ -n ${dsh_given[$name]:-} ]]; then
    printf -v "$var" '%s' "${dsh_given[$name]}"
  elif [[ -n $recorded ]] && value=$(record_value "$recorded" "$var") && [[ -n $value ]]; then
    printf -v "$var" '%s' "$value"
    note "Keeping $var=$value from the CT's last run."
  else
    printf -v "$var" '%s' "${dsh_default[$name]}"
  fi
done
if [[ -z ${dsh_given[VERSION]:-} && -n $recorded && $DSH_VERSION != "$DEFAULT_DSH_VERSION" ]]; then
  note "This target is tested with $DEFAULT_DSH_VERSION; set DSH_VERSION=$DEFAULT_DSH_VERSION to move to it."
fi
for name in DSH_PORT DSH_CONTEXT_WINDOW DSH_MAX_TOKENS; do positive "$name" "${!name}"; done
(( DSH_PORT <= 65535 && DSH_MAX_TOKENS < DSH_CONTEXT_WINDOW )) || die 'Invalid port or token capacity.'
[[ $DSH_VERSION =~ ^(latest|[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.-]+)?)$ ]] || die 'Invalid DSH_VERSION.'
[[ $DSH_MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._:/+-]*$ ]] || die 'Invalid DSH_MODEL.'
[[ -z $DSH_ACCESS_CIDR ]] || DSH_ACCESS_CIDR=$(cidr_network "$DSH_ACCESS_CIDR")

# --- Honcho memory: given, else recorded, else off ---------------------------
honcho_mcp=''
if [[ -n $HONCHO_MCP_URL ]]; then honcho_mcp=$HONCHO_MCP_URL
elif [[ -n $HONCHO_URL ]]; then honcho_mcp=$(honcho_mcp_url "$HONCHO_URL")
elif [[ -z $honcho_url_set && -z $honcho_mcp_set && -n $recorded ]]; then
  honcho_mcp=$(record_value "$recorded" DSH_HONCHO_MCP_URL || true)
  [[ -z $honcho_mcp ]] || note "Keeping Honcho memory at $honcho_mcp (set HONCHO_URL= to turn it off)."
fi
if [[ -n $honcho_mcp ]]; then
  (( DSH_CONTEXT_WINDOW >= 32768 )) ||
    die 'Honcho memory adds about 40 tool definitions; set DSH_CONTEXT_WINDOW to 32768 or more.'
fi

honcho_key_push=false
if (( ! dry_run )); then
  pct exec "$ROUTER_CT_ID" -- awk -F= '$1=="ROUTER_API_KEY" {sub(/^[^=]*=/,""); print; exit}' \
    /app/router/secrets.env > "$stage/router-api-key" 2>/dev/null || : > "$stage/router-api-key"
  router_ip=$(pct exec "$ROUTER_CT_ID" -- ip -4 -o addr show dev eth0 | awk 'NR==1 {split($4,a,"/"); print a[1]}')
  router_ip=${router_ip//[$'\r\n ']/}
  ipv4 "$router_ip" || die 'Cannot determine the OSR router CT IPv4 address.'
  router_port=$(pct exec "$ROUTER_CT_ID" -- sh -c "sed -n 's/^ROUTER_PORT=//p' /app/router/.env 2>/dev/null | head -n1" || true)
  router_port=${router_port//[$'\r\n ']/}
  router_port=${router_port:-8000}
  positive ROUTER_PORT "$router_port"
  (( router_port <= 65535 )) || die 'Invalid router port.'
  if [[ -n $honcho_mcp ]]; then
    # The Honcho target's client key is scoped to the shared osr workspace.
    if [[ -n $HONCHO_CT_ID ]]; then
      pct exec "$HONCHO_CT_ID" -- cat /etc/honcho-target/client-api-key > "$stage/honcho-api-key" 2>/dev/null ||
        die "Honcho CT $HONCHO_CT_ID has no osr workspace key. Run targets/honcho/provision-lxc.sh --reconfigure for it first."
      honcho_key_push=true
    elif [[ -n $HONCHO_API_KEY_FILE ]]; then
      cp -- "$HONCHO_API_KEY_FILE" "$stage/honcho-api-key"
      honcho_key_push=true
    elif [[ $mode == reconfigure ]] && pct exec "$CT_ID" -- test -s /etc/deepseek-harness/honcho-api-key; then
      note "Using the Honcho key already in CT $CT_ID; set HONCHO_CT_ID to fetch it again."
    else
      die 'Honcho memory needs HONCHO_CT_ID (the Honcho target) or HONCHO_API_KEY_FILE.'
    fi
    [[ $honcho_key_push == false || -s $stage/honcho-api-key ]] || die 'The Honcho API key is empty.'
    # The Honcho target admits agents by address; say how before changing anything.
    honcho_fw=/etc/pve/firewall/${HONCHO_CT_ID}.fw
    if [[ -n $HONCHO_CT_ID && -f $honcho_fw && -n $IP_CIDR ]] &&
       ! grep -q -- "-source ${IP_CIDR%/*}/32 -p tcp -dport 3000 " "$honcho_fw"; then
      die "Honcho CT $HONCHO_CT_ID does not admit ${IP_CIDR%/*} to its MCP port. Add it on this host with:
  CT_ID=$HONCHO_CT_ID ROUTER_CT_ID=$ROUTER_CT_ID HONCHO_CLIENT_IPS='<other agent IPs> ${IP_CIDR%/*}' bash targets/honcho/provision-lxc.sh --reconfigure"
    fi
  fi
else
  router_ip='<router-ct-ip>'
  router_port=8000
  [[ $mode != reconfigure ]] || IP_CIDR=${IP_CIDR:-<existing-ct-ip>/32}
  printf '+ read ROUTER_API_KEY from router CT %s into a temporary 0600 file\n' "$ROUTER_CT_ID"
  if [[ -n $honcho_mcp ]]; then
    if [[ -n $HONCHO_CT_ID ]]; then key_from="Honcho CT $HONCHO_CT_ID"
    elif [[ -n $HONCHO_API_KEY_FILE ]]; then key_from=$HONCHO_API_KEY_FILE
    else key_from="the key already in CT $CT_ID"; fi
    printf '+ read the osr workspace key from %s into a temporary 0600 file\n' "$key_from"
  fi
fi
ROUTER_URL="http://$router_ip:$router_port"

if [[ $mode == create ]]; then
  net="name=eth0,bridge=$BRIDGE,ip=$IP_CIDR,gw=$GATEWAY,firewall=1"
  [[ -z $VLAN_TAG ]] || net+=",tag=$VLAN_TAG"
  create=(pct create "$CT_ID" "$TEMPLATE" --hostname "$CT_HOSTNAME" --ostype debian
    --unprivileged 1 --features nesting=1 --cores "$CORES" --memory "$MEMORY_MB" --swap "$SWAP_MB"
    --rootfs "$STORAGE:$ROOTFS_GB" --net0 "$net" --onboot "$ONBOOT"
    --tags 'ai;ai-tools;osr-target;deepseek-harness'
    --description 'DeepSeek Harness for Ollama Smart Router')
  [[ -z $NAMESERVER ]] || create+=(--nameserver "$NAMESERVER")
  # Proxmox extracts an unprivileged template as the mapped root user, with
  # this process's umask: under 077 the rootfs path is 0700 and tar cannot
  # open it. Scope 022 to pct create only; keys and staging stay private.
  (umask 022; run "${create[@]}")
  firewall_file="/etc/pve/firewall/${CT_ID}.fw"
  firewall=$(printf '[OPTIONS]\nenable: 1\npolicy_in: DROP\npolicy_out: ACCEPT\n\n[RULES]\nIN ACCEPT -source %s -p tcp -dport %s -log nolog # osr-deepseek-harness\n' \
    "$DSH_ACCESS_CIDR" "$DSH_PORT")
  if (( dry_run )); then printf '+ write %s:\n%s\n' "$firewall_file" "$firewall"
  else printf '%s' "$firewall" > "$firewall_file"; fi
  run pct start "$CT_ID"
  if (( ! dry_run )); then
    ready=false
    for (( attempt=0; attempt<60; attempt++ )); do
      if pct exec "$CT_ID" -- test -d /run/systemd/system 2>/dev/null &&
         pct exec "$CT_ID" -- getent hosts registry.npmjs.org >/dev/null 2>&1; then ready=true; break; fi
      sleep 3
    done
    $ready || die "CT $CT_ID has no working systemd or DNS after 180 seconds. Resume with --reconfigure."
  else
    printf '+ wait for systemd and DNS in CT %s\n' "$CT_ID"
  fi
else
  rule="IN ACCEPT -source $DSH_ACCESS_CIDR -p tcp -dport $DSH_PORT -log nolog # osr-deepseek-harness"
  if (( ! dry_run )); then
    firewall_file="/etc/pve/firewall/${CT_ID}.fw"
    grep -q '# osr-deepseek-harness$' "$firewall_file" || die 'Refusing to replace an unrecognized CT firewall.'
    grep -qx '\[RULES\]' "$firewall_file" || die 'The CT firewall has no [RULES] section.'
    awk -v rule="$rule" '
      / # osr-deepseek-harness$/ {next}
      {print; if ($0 == "[RULES]") print rule}
    ' "$firewall_file" > "$stage/firewall"
    cmp -s "$stage/firewall" "$firewall_file" || cat "$stage/firewall" > "$firewall_file"
  else
    printf '+ keep one Web UI rule in /etc/pve/firewall/%s.fw: %s\n' "$CT_ID" "$rule"
  fi
fi

# The router CT's own firewall must let Harness reach the router API. One owned
# rule, replaced when the Harness address or router port changes; everything
# else in that file stays as it is.
router_fw=/etc/pve/firewall/${ROUTER_CT_ID}.fw
if [[ $DSH_ROUTER_FIREWALL == true ]]; then
  if (( dry_run )); then
    printf '+ admit %s to the router API in %s, if that file exists\n' "${IP_CIDR%/*}" "$router_fw"
  elif [[ -f $router_fw ]]; then
    router_fw_with_dsh "$router_fw" "${IP_CIDR%/*}" "$router_port" > "$stage/router.fw"
    cmp -s "$stage/router.fw" "$router_fw" || cat "$stage/router.fw" > "$router_fw"
  fi
fi

run pct exec "$CT_ID" -- install -d -m 0700 "$deploy"
run pct push "$CT_ID" "$stage/router-api-key" "$deploy/router-api-key" --perms 0600
if [[ $honcho_key_push == true ]] || { (( dry_run )) && [[ -n $honcho_mcp && ( -n $HONCHO_CT_ID || -n $HONCHO_API_KEY_FILE ) ]]; }; then
  run pct push "$CT_ID" "$stage/honcho-api-key" "$deploy/honcho-api-key" --perms 0600
fi
for file in install-target.sh configure.mjs deepseek-harness.service; do
  perms=0644
  [[ $file == *.sh || $file == *.mjs ]] && perms=0755
  run pct push "$CT_ID" "$source_dir/$file" "$deploy/$file" --perms "$perms"
done
run pct exec "$CT_ID" -- env "DSH_ROUTER_URL=$ROUTER_URL" "DSH_BIND_IP=${IP_CIDR%/*}" \
  "DSH_MODEL=$DSH_MODEL" "DSH_CONTEXT_WINDOW=$DSH_CONTEXT_WINDOW" \
  "DSH_MAX_TOKENS=$DSH_MAX_TOKENS" "DSH_PORT=$DSH_PORT" "DSH_VERSION=$DSH_VERSION" \
  "DSH_HONCHO_MCP_URL=$honcho_mcp" bash "$deploy/install-target.sh"

printf 'DeepSeek Harness CT %s: http://%s:%s/\n' "$CT_ID" "${IP_CIDR%/*}" "$DSH_PORT"
[[ -z $honcho_mcp ]] || printf 'Honcho memory: %s (workspace osr; peers user and deepseek-harness).\n' "$honcho_mcp"
printf 'Read its tokenized login URL with: pct exec %s -- journalctl -u deepseek-harness.service -b --no-pager | grep "dsh web:" | tail -n1\n' "$CT_ID"
