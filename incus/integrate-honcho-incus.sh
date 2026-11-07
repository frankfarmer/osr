#!/usr/bin/env bash
# Register the Honcho container's MCP tools with Open WebUI. Incus port of the
# last step of targets/honcho/provision-lxc.sh: stages integrate-webui.py, an
# admin token and Honcho's workspace-scoped client key inside the router
# container (0700 directory), runs it against Open WebUI on localhost, and
# removes everything afterwards. The admin key never leaves the router container.
#
# Needs an Open WebUI ADMIN API key. Supply OPENWEBUI_ADMIN_TOKEN, or type it
# when asked (nothing is echoed).
#
#   ROUTER_CT   router container   (osr-router)
#   HONCHO_CT   Honcho container   (osr-honcho)
set -euo pipefail

ROUTER_CT="${ROUTER_CT:-osr-router}"
HONCHO_CT="${HONCHO_CT:-osr-honcho}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/targets/honcho"
STAGE="$(mktemp -d)"
REMOTE_DIR=/root/honcho-integrate
cleanup() {
  rm -rf "$STAGE"
  incus exec "$ROUTER_CT" -- rm -rf "$REMOTE_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

command -v incus >/dev/null || { echo "incus not found" >&2; exit 1; }
for c in "$ROUTER_CT" "$HONCHO_CT"; do
  incus info "$c" >/dev/null 2>&1 || { echo "container $c does not exist" >&2; exit 1; }
done

TOKEN="${OPENWEBUI_ADMIN_TOKEN:-}"
unset OPENWEBUI_ADMIN_TOKEN
if [[ -z "$TOKEN" ]]; then
  [[ -t 0 ]] || { echo "Set OPENWEBUI_ADMIN_TOKEN for unattended use." >&2; exit 1; }
  read -r -s -p "Open WebUI admin API key: " TOKEN; echo
fi
[[ -n "$TOKEN" ]] || { echo "no token given" >&2; exit 1; }

HONCHO_IP="$(incus list "$HONCHO_CT" -c4 -f csv | sed -n 's/^\([0-9.]*\) (eth0).*/\1/p' | head -1)"
[[ -n "$HONCHO_IP" ]] || { echo "cannot find ${HONCHO_CT}'s address" >&2; exit 1; }
PORT="$(incus exec "$ROUTER_CT" -- sh -c "sed -n 's/^PORT=//p' /app/openwebui/.env | head -n1" | tr -d '\r\n ')"
PORT="${PORT:-8080}"

echo "Checking that the router container can reach Honcho (${HONCHO_IP}:3000) and Open WebUI (127.0.0.1:${PORT})."
incus exec "$ROUTER_CT" -- curl -fsS -m10 -o /dev/null "http://${HONCHO_IP}:3000/health" \
  || { echo "the router container cannot reach Honcho's MCP port" >&2; exit 1; }
incus exec "$ROUTER_CT" -- curl -fsS -m10 -o /dev/null "http://127.0.0.1:${PORT}/health" \
  || { echo "Open WebUI is not healthy in ${ROUTER_CT}" >&2; exit 1; }

( umask 077
  printf '%s' "$TOKEN" > "$STAGE/admin-token"
  incus exec "$HONCHO_CT" -- cat /etc/honcho-target/client-api-key | tr -d '\r\n' > "$STAGE/honcho-api-key" )
unset TOKEN
[[ -s "$STAGE/honcho-api-key" ]] || { echo "Honcho has not generated its client key" >&2; exit 1; }

incus exec "$ROUTER_CT" -- sh -c "rm -rf '$REMOTE_DIR' && install -d -m 0700 '$REMOTE_DIR'"
incus file push --mode 0600 "$SRC/integrate-webui.py" "$ROUTER_CT$REMOTE_DIR/integrate-webui.py"
incus file push --mode 0600 "$STAGE/admin-token" "$ROUTER_CT$REMOTE_DIR/admin-token"
incus file push --mode 0600 "$STAGE/honcho-api-key" "$ROUTER_CT$REMOTE_DIR/honcho-api-key"

echo "Registering Honcho with Open WebUI."
incus exec "$ROUTER_CT" -- python3 "$REMOTE_DIR/integrate-webui.py" \
  "http://127.0.0.1:${PORT}" "$REMOTE_DIR/admin-token" "$REMOTE_DIR/honcho-api-key" "http://${HONCHO_IP}:3000"
echo "Done."
