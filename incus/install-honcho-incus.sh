#!/usr/bin/env bash
# Incus port of the Honcho memory target (targets/honcho).
#
# Creates a Debian 13 container and stages exactly what the Proxmox provisioner
# pushes (the nine target files, the router API key, an empty backend-keys file),
# then runs the repo's own targets/honcho/install-target.sh inside it. That
# installer is Proxmox-independent: it installs PostgreSQL + pgvector, builds the
# pinned llama.cpp for the CPU embedding model, installs the pinned Honcho
# release (plastic-labs/honcho) and Bun, and starts five systemd services.
#
# Registering Honcho's MCP tools with Open WebUI needs an admin API key and is a
# separate step: incus/integrate-honcho-incus.sh.
#
# Settings (environment variables):
#   CT_NAME               container name                          (osr-honcho)
#   IMAGE                 Incus image                             (images:debian/13)
#   CT_IP                 fixed IPv4 on the Incus bridge          (10.127.234.13)
#   CPUS / MEMORY         resource limits                         (4 / 8GiB)
#   ROUTER_CT             router container (key is read from it)  (osr-router)
#   ROUTER_URL            router base URL as the container sees it (http://<bridge gateway>:8000)
#   HONCHO_MODEL          chat model name or tier                 (gemma4:12b)
#   HONCHO_CONTEXT_TOKENS context window the chat model serves    (32768)
#   HONCHO_REF            upstream Honcho release                 (the installer's pin)
#   HONCHO_STRUCTURED_OUTPUT_MODE  json_schema | json_object     (installer default)
set -euo pipefail

CT_NAME="${CT_NAME:-osr-honcho}"
IMAGE="${IMAGE:-images:debian/13}"
CT_IP="${CT_IP:-10.127.234.13}"
CPUS="${CPUS:-4}"
MEMORY="${MEMORY:-8GiB}"
ROUTER_CT="${ROUTER_CT:-osr-router}"
HONCHO_MODEL="${HONCHO_MODEL:-gemma4:12b}"
HONCHO_CONTEXT_TOKENS="${HONCHO_CONTEXT_TOKENS:-32768}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="$REPO_ROOT/targets/honcho"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

command -v incus >/dev/null || { echo "incus not found" >&2; exit 1; }
incus info >/dev/null 2>&1 || { echo "cannot talk to incus (incus-admin group?)" >&2; exit 1; }
incus info "$ROUTER_CT" >/dev/null 2>&1 || { echo "router container ${ROUTER_CT} not found" >&2; exit 1; }
FILES=(install-target.sh budgets.py honcho-proxy.py direct_dispatch.py honcho-proxy.service
       honcho-api.service honcho-deriver.service honcho-mcp.service honcho-embedding.service)
for f in "${FILES[@]}"; do
  [[ -s "$TARGET_DIR/$f" ]] || { echo "missing $TARGET_DIR/$f" >&2; exit 1; }
done
if incus info "$CT_NAME" >/dev/null 2>&1; then
  echo "Container ${CT_NAME} already exists; refusing to touch it." >&2
  exit 1
fi

# The Honcho container reaches the router through the bridge gateway: the router
# container's API port is forwarded on the host's 0.0.0.0, so this address does
# not change when the router container restarts.
if [[ -z "${ROUTER_URL:-}" ]]; then
  GATEWAY="$(incus network get incusbr0 ipv4.address | cut -d/ -f1)"
  [[ -n "$GATEWAY" ]] || { echo "cannot read the incusbr0 address; set ROUTER_URL" >&2; exit 1; }
  ROUTER_URL="http://${GATEWAY}:8000"
fi

ct() { incus exec "$CT_NAME" -- "$@"; }

# --- the router key, read from the router container -------------------------------------
( umask 077
  incus exec "$ROUTER_CT" -- awk -F= '$1=="ROUTER_API_KEY" {sub(/^[^=]*=/,""); print; exit}' \
    /app/router/secrets.env | tr -d '\r\n' > "$STAGE/router-api-key"
  [[ -s "$STAGE/router-api-key" ]] || printf 'no-key\n' > "$STAGE/router-api-key"
  : > "$STAGE/backend-keys" )

echo "Creating container ${CT_NAME} (${CT_IP})."
incus init "$IMAGE" "$CT_NAME" -c security.nesting=true -c boot.autostart=true \
  -c limits.cpu="$CPUS" -c limits.memory="$MEMORY"
incus config device override "$CT_NAME" eth0 ipv4.address="$CT_IP"
incus start "$CT_NAME"

for _ in $(seq 1 60); do
  state="$(ct systemctl is-system-running 2>/dev/null || true)"
  if [[ "$state" == running || "$state" == degraded ]] && ct getent hosts github.com >/dev/null 2>&1; then break; fi
  sleep 2
done
ct getent hosts github.com >/dev/null || { echo "no DNS/network in the container" >&2; exit 1; }

echo "Staging the deploy files."
ct install -d -m 0700 /root/honcho-deploy
tar -C "$TARGET_DIR" -cf - "${FILES[@]}" | incus exec "$CT_NAME" -- tar -C /root/honcho-deploy -xf -
ct chmod 0600 /root/honcho-deploy/install-target.sh /root/honcho-deploy/budgets.py /root/honcho-deploy/honcho-proxy.py \
  /root/honcho-deploy/direct_dispatch.py /root/honcho-deploy/honcho-proxy.service /root/honcho-deploy/honcho-api.service \
  /root/honcho-deploy/honcho-deriver.service /root/honcho-deploy/honcho-mcp.service /root/honcho-deploy/honcho-embedding.service
incus file push --mode 0600 "$STAGE/router-api-key" "$CT_NAME/root/honcho-deploy/router-api-key"
incus file push --mode 0600 "$STAGE/backend-keys" "$CT_NAME/root/honcho-deploy/backend-keys"

echo "Running the Honcho installer (installs PostgreSQL, builds llama.cpp, installs Honcho; this takes a while)."
env_args=("ROUTER_URL=${ROUTER_URL}" "HONCHO_MODEL=${HONCHO_MODEL}" "HONCHO_CONTEXT_TOKENS=${HONCHO_CONTEXT_TOKENS}"
          "HONCHO_SKIP_CHAT_PROBE=${HONCHO_SKIP_CHAT_PROBE:-false}" "KINDI_READ_TIMEOUT_SECONDS=${KINDI_READ_TIMEOUT_SECONDS:-3600}"
          "NONINTERACTIVE=true")
[[ -z "${HONCHO_REF:-}" ]] || env_args+=("HONCHO_REF=${HONCHO_REF}")
[[ -z "${HONCHO_STRUCTURED_OUTPUT_MODE:-}" ]] || env_args+=("HONCHO_STRUCTURED_OUTPUT_MODE=${HONCHO_STRUCTURED_OUTPUT_MODE}")
ct env "${env_args[@]}" bash /root/honcho-deploy/install-target.sh

echo "=============================================================================="
echo "Honcho container ${CT_NAME} is up."
echo "  API : http://${CT_IP}:8000"
echo "  MCP : http://${CT_IP}:3000/mcp   (internal bridge only)"
echo "  Chat model: ${HONCHO_MODEL} (context ${HONCHO_CONTEXT_TOKENS} tokens) via ${ROUTER_URL}"
echo "  Client key (scoped to the 'osr' workspace): incus exec ${CT_NAME} -- cat /etc/honcho-target/client-api-key"
echo "  Open WebUI : OPENWEBUI_ADMIN_TOKEN=<admin api key> incus/integrate-honcho-incus.sh"
echo "=============================================================================="
