#!/usr/bin/env bash
# Incus port of the router-CT part of ollama-smart-router-install.sh.
#
# Builds the router container (router + monitor + LiteLLM + Open WebUI) on an
# Incus host instead of Proxmox. It reuses the repo's own service tree
# (services/, env/, install/) and mirrors the installer's in-container steps,
# replacing `pct create/exec/push` with `incus`. Non-interactive; no Gitea.
#
# Usage (run as a user in the incus-admin group, from anywhere):
#   incus/install-router-incus.sh
# Settings (environment variables):
#   CT_NAME          container name                         (osr-router)
#   IMAGE            Incus image                            (images:debian/13)
#   MODEL_SERVERS    comma list of model server base URLs   (http://127.0.0.1:11434)
#   MODEL            model tag for the static LiteLLM tiers (llama3.2:3b)
#   OPENWEBUI_PORT   Open WebUI port                        (8080)
#   OPENWEBUI_PY_VERSION  Python for Open WebUI             (3.12)
#   TORCH_CPU_ONLY   preinstall CPU-only torch             (true)
#   PUBLISH          forward API/UI ports on the host       (true)
set -euo pipefail

CT_NAME="${CT_NAME:-osr-router}"
IMAGE="${IMAGE:-images:debian/13}"
MODEL_SERVERS="${MODEL_SERVERS:-http://127.0.0.1:11434}"
MODEL="${MODEL:-llama3.2:3b}"
OPENWEBUI_PORT="${OPENWEBUI_PORT:-8080}"
OPENWEBUI_PY_VERSION="${OPENWEBUI_PY_VERSION:-3.12}"
OPENWEBUI_PY_DIR="${OPENWEBUI_PY_DIR:-/opt/python}"
TORCH_CPU_ONLY="${TORCH_CPU_ONLY:-true}"
PUBLISH="${PUBLISH:-true}"
CONFIG_REPO_DIR=/app/config-repo

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

command -v incus >/dev/null || { echo "incus not found" >&2; exit 1; }
incus info >/dev/null 2>&1 || { echo "cannot talk to incus (are you in the incus-admin group?)" >&2; exit 1; }
if incus info "$CT_NAME" >/dev/null 2>&1; then
  echo "Container ${CT_NAME} already exists; refusing to touch it." >&2
  exit 1
fi
for d in services env install; do
  [[ -d "$REPO_ROOT/$d" ]] || { echo "missing $REPO_ROOT/$d (run from a full checkout)" >&2; exit 1; }
done

ct() { incus exec "$CT_NAME" -- "$@"; }

# --- per-install config, rewritten on a copy of the repo's env file ------------
cp -r "$REPO_ROOT/env" "$STAGE/env"
setenv() {  # setenv FILE KEY VALUE
  if grep -q "^$2=" "$1"; then sed -i "s|^$2=.*|$2=$3|" "$1"; else printf '%s=%s\n' "$2" "$3" >> "$1"; fi
}
FIRST_SERVER="${MODEL_SERVERS%%,*}"
N_SERVERS="$(awk -F, '{print NF}' <<<"$MODEL_SERVERS")"
E="$STAGE/env/router.env"
setenv "$E" GITEA_SERVER_URL ""
setenv "$E" GITEA_ADMIN_USER ""
setenv "$E" BACKEND_FAST "$FIRST_SERVER"
setenv "$E" BACKEND_MEDIUM "$FIRST_SERVER"
setenv "$E" BACKEND_LARGE "$FIRST_SERVER"
setenv "$E" BACKEND_XLARGE ""
setenv "$E" MODEL_SERVER_COUNT "$N_SERVERS"
setenv "$E" MODEL_SERVERS "$MODEL_SERVERS"
setenv "$E" MODEL_FAST "$MODEL"
setenv "$E" MODEL_MEDIUM "$MODEL"
setenv "$E" MODEL_LARGE "$MODEL"
setenv "$E" MODEL_XLARGE ""
setenv "$E" TORCH_CPU_ONLY "$TORCH_CPU_ONLY"
setenv "$E" OPENWEBUI_HEALTH_URL "http://127.0.0.1:${OPENWEBUI_PORT}/health"
setenv "$STAGE/env/openwebui.env" PORT "$OPENWEBUI_PORT"

ROUTER_API_KEY="$(openssl rand -hex 24)"
( umask 077
  printf 'GITEA_DEPLOY_TOKEN=\nMATTERMOST_WEBHOOK_URL=\nROUTER_API_KEY=%s\nOPENAI_API_KEYS=%s\n' \
    "$ROUTER_API_KEY" "$ROUTER_API_KEY" > "$STAGE/secrets.env" )
# Open WebUI authenticates to the router with the same key.
setenv "$STAGE/env/openwebui.env" OPENAI_API_KEYS "$ROUTER_API_KEY"

# --- container ------------------------------------------------------------------
echo "Creating container ${CT_NAME} from ${IMAGE}."
incus launch "$IMAGE" "$CT_NAME" -c security.nesting=true -c boot.autostart=true

echo "Waiting for the container to finish booting and get a network."
for _ in $(seq 1 60); do
  state="$(ct systemctl is-system-running 2>/dev/null || true)"
  if [[ "$state" == running || "$state" == degraded ]] && ct getent hosts deb.debian.org >/dev/null 2>&1; then break; fi
  sleep 2
done
ct getent hosts deb.debian.org >/dev/null || { echo "no DNS/network in the container" >&2; exit 1; }

echo "Installing base packages."
ct apt-get update -qq
ct apt-get install -y -qq python3 python3-pip python3-venv curl ca-certificates

echo "Creating application user and directories."
ct groupadd --system ollama-router
ct useradd --system --gid ollama-router --home-dir /app/router --shell /usr/sbin/nologin ollama-router
ct mkdir -p /app/router /app/openwebui/data /app/openwebui/cache "$CONFIG_REPO_DIR"

echo "Pushing the config tree."
tar -C "$REPO_ROOT" -cf - services install | incus exec "$CT_NAME" -- tar -C "$CONFIG_REPO_DIR" -xf -
tar -C "$STAGE" -cf - env | incus exec "$CT_NAME" -- tar -C "$CONFIG_REPO_DIR" -xf -

echo "Applying configuration."
ct bash "${CONFIG_REPO_DIR}/install/apply-config.sh" "$CONFIG_REPO_DIR"

echo "Installing secrets."
incus file push --mode 0640 "$STAGE/secrets.env" "$CT_NAME/app/router/secrets.env"
ct chown root:ollama-router /app/router/secrets.env

echo "Installing router/monitor dependencies."
ct python3 -m venv /app/router/venv
ct /app/router/venv/bin/pip install --no-cache-dir -q \
  -r "${CONFIG_REPO_DIR}/services/ollama-router/requirements.txt" \
  -r "${CONFIG_REPO_DIR}/services/ollama-monitor/requirements.txt"

echo "Installing LiteLLM (own venv)."
ct install -d -m 0755 /app/litellm
ct python3 -m venv /app/litellm/venv
ct bash -c "
  set -e
  lock='${CONFIG_REPO_DIR}/services/litellm-proxy/requirements.lock'
  req='${CONFIG_REPO_DIR}/services/litellm-proxy/requirements.txt'
  if [ -f \"\$lock\" ]; then
    /app/litellm/venv/bin/pip install --no-cache-dir -q --require-hashes -r \"\$lock\"
  else
    /app/litellm/venv/bin/pip install --no-cache-dir -q -r \"\$req\"
  fi
  /app/litellm/venv/bin/python -c 'import litellm.proxy.proxy_server' >/dev/null
  chmod -R u+rwX,go+rX,go-w /app/litellm
"

echo "Provisioning Python ${OPENWEBUI_PY_VERSION} for Open WebUI (via uv)."
ct bash -c "
  set -e
  python3 -m venv /opt/uv-bootstrap
  /opt/uv-bootstrap/bin/pip install --no-cache-dir -q --upgrade pip uv
  UV_PYTHON_INSTALL_DIR='${OPENWEBUI_PY_DIR}' /opt/uv-bootstrap/bin/uv python install '${OPENWEBUI_PY_VERSION}'
  chmod -R a+rX '${OPENWEBUI_PY_DIR}'
"
OWUI_PY="$(ct bash -c "UV_PYTHON_INSTALL_DIR='${OPENWEBUI_PY_DIR}' /opt/uv-bootstrap/bin/uv python find '${OPENWEBUI_PY_VERSION}'" | tr -d '\r' | awk 'NF{print; exit}')"
[[ -n "$OWUI_PY" ]] || { echo "could not find provisioned Python ${OPENWEBUI_PY_VERSION}" >&2; exit 1; }
ct runuser -u ollama-router -- "$OWUI_PY" -c '' || { echo "Python at ${OWUI_PY} not runnable by service user" >&2; exit 1; }
echo "Using ${OWUI_PY}"

echo "Installing Open WebUI (large; takes a while)."
ct "$OWUI_PY" -m venv /app/openwebui/venv
ct /app/openwebui/venv/bin/pip install --no-cache-dir -q --upgrade pip
if [[ "$TORCH_CPU_ONLY" == true ]]; then
  ct /app/openwebui/venv/bin/pip install --no-cache-dir -q --index-url https://download.pytorch.org/whl/cpu torch \
    || echo "WARNING: CPU-only torch install failed; falling back to the default build." >&2
fi
ct /app/openwebui/venv/bin/pip install --no-cache-dir -q -r "${CONFIG_REPO_DIR}/services/open-webui/requirements.txt"

echo "Setting ownership and permissions."
ct chown -R ollama-router:ollama-router /app/router /app/openwebui
ct chown root:ollama-router /app/router/.env /app/openwebui/.env
ct chmod 0640 /app/router/.env /app/openwebui/.env

echo "Starting services."
ct systemctl daemon-reload
ct systemctl enable --now litellm-proxy.service ollama-router.service ollama-monitor.service open-webui.service

if [[ "$PUBLISH" == true ]]; then
  echo "Forwarding ports 8000 and ${OPENWEBUI_PORT} from the host."
  incus config device add "$CT_NAME" api proxy listen=tcp:0.0.0.0:8000 connect=tcp:127.0.0.1:8000
  incus config device add "$CT_NAME" webui proxy listen="tcp:0.0.0.0:${OPENWEBUI_PORT}" connect="tcp:127.0.0.1:${OPENWEBUI_PORT}"
fi

echo "=============================================================================="
echo "Router container ${CT_NAME} is up."
echo "  OpenAI-compatible API : http://<host>:8000/v1"
echo "  Open WebUI            : http://<host>:${OPENWEBUI_PORT}  (first visitor creates the admin account)"
echo "  API key               : incus exec ${CT_NAME} -- grep ROUTER_API_KEY /app/router/secrets.env"
echo "  Status                : incus exec ${CT_NAME} -- systemctl status open-webui ollama-router litellm-proxy ollama-monitor"
echo "=============================================================================="
