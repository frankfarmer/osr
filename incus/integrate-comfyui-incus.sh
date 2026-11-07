#!/usr/bin/env bash
# Register the ComfyUI container with Open WebUI as its image-generation engine.
# Incus port of the last step of targets/comfyui/provision-lxc.sh: it stages
# integrate-webui.py and the Klein workflows inside the router container, runs
# it there against Open WebUI on localhost, and removes everything afterwards.
#
# Needs an Open WebUI ADMIN API key (Settings > Account > API keys, after
# creating the first admin account). Supply it as OPENWEBUI_ADMIN_TOKEN, or
# type it when asked (nothing is echoed).
#
# Settings (environment variables):
#   OPENWEBUI_ADMIN_TOKEN  admin API key or JWT              (prompted)
#   ROUTER_CT              router container                  (osr-router)
#   COMFYUI_CT             ComfyUI container                 (osr-comfyui)
#   COMFYUI_IMAGE_VARIANT  klein-4b | klein-9b | auto        (klein-4b)
#   COMFYUI_IMAGE_SIZE     e.g. 1024x1024                    (installer default)
#   COMFYUI_IMAGE_STEPS    e.g. 4                            (installer default)
set -euo pipefail

ROUTER_CT="${ROUTER_CT:-osr-router}"
COMFYUI_CT="${COMFYUI_CT:-osr-comfyui}"
VARIANT="${COMFYUI_IMAGE_VARIANT:-klein-4b}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/targets/comfyui"
STAGE="$(mktemp -d)"
REMOTE_DIR=/root/comfyui-integrate
cleanup() {
  rm -rf "$STAGE"
  incus exec "$ROUTER_CT" -- rm -rf "$REMOTE_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT

command -v incus >/dev/null || { echo "incus not found" >&2; exit 1; }
for c in "$ROUTER_CT" "$COMFYUI_CT"; do
  incus info "$c" >/dev/null 2>&1 || { echo "container $c does not exist" >&2; exit 1; }
done

TOKEN="${OPENWEBUI_ADMIN_TOKEN:-}"
unset OPENWEBUI_ADMIN_TOKEN
if [[ -z "$TOKEN" ]]; then
  [[ -t 0 ]] || { echo "Set OPENWEBUI_ADMIN_TOKEN for unattended use." >&2; exit 1; }
  read -r -s -p "Open WebUI admin API key: " TOKEN; echo
fi
[[ -n "$TOKEN" ]] || { echo "no token given" >&2; exit 1; }

COMFYUI_IP="$(incus list "$COMFYUI_CT" -c4 -f csv | sed -n 's/^\([0-9.]*\) (eth0).*/\1/p' | head -1)"
[[ -n "$COMFYUI_IP" ]] || { echo "cannot find ${COMFYUI_CT}'s address" >&2; exit 1; }
PORT="$(incus exec "$ROUTER_CT" -- sh -c "sed -n 's/^PORT=//p' /app/openwebui/.env | head -n1" | tr -d '\r\n ')"
PORT="${PORT:-8080}"

echo "Checking that ComfyUI answers at http://${COMFYUI_IP}:8188 and Open WebUI at 127.0.0.1:${PORT}."
incus exec "$ROUTER_CT" -- curl -fsS -m10 -o /dev/null "http://${COMFYUI_IP}:8188/system_stats" \
  || { echo "the router container cannot reach ComfyUI" >&2; exit 1; }
incus exec "$ROUTER_CT" -- curl -fsS -m10 -o /dev/null "http://127.0.0.1:${PORT}/health" \
  || { echo "Open WebUI is not healthy in ${ROUTER_CT}" >&2; exit 1; }

echo "Staging the integration files (token goes in a 0600 file in a 0700 directory)."
incus exec "$ROUTER_CT" -- sh -c "rm -rf '$REMOTE_DIR' && install -d -m 0700 '$REMOTE_DIR'"
for f in integrate-webui.py flux2-klein-4b-api.json flux2-klein-9b-api.json; do
  incus file push --mode 0600 "$SRC/$f" "$ROUTER_CT$REMOTE_DIR/$f"
done
( umask 077; printf '%s' "$TOKEN" > "$STAGE/token" )
unset TOKEN
incus file push --mode 0600 "$STAGE/token" "$ROUTER_CT$REMOTE_DIR/token"

args=(--webui-url "http://127.0.0.1:${PORT}" --comfyui-url "http://${COMFYUI_IP}:8188"
      --admin-token-file "$REMOTE_DIR/token" --variant "$VARIANT")
[[ -z "${COMFYUI_IMAGE_SIZE:-}" ]] || args+=(--image-size "$COMFYUI_IMAGE_SIZE")
[[ -z "${COMFYUI_IMAGE_STEPS:-}" ]] || args+=(--image-steps "$COMFYUI_IMAGE_STEPS")

echo "Configuring Open WebUI."
incus exec "$ROUTER_CT" -- python3 "$REMOTE_DIR/integrate-webui.py" "${args[@]}"
echo "Done. Open WebUI now uses ComfyUI at http://${COMFYUI_IP}:8188 for images."
