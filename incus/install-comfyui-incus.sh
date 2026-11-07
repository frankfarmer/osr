#!/usr/bin/env bash
# Incus port of the ComfyUI image-generation target (targets/comfyui).
#
# Creates an Ubuntu container with the host's NVIDIA GPU attached, builds the
# community-script-style ComfyUI install that targets/comfyui/install-target.sh
# expects (/opt/ComfyUI + venv, uv on PATH, a plain comfyui.service), checks out
# the repo-pinned release commit, then runs install-target.sh to adopt it and
# download the FLUX.2 Klein weights. Connecting it to Open WebUI is a separate
# step (incus/integrate-comfyui-incus.sh), because it needs an admin API key.
#
# Settings (environment variables):
#   CT_NAME              container name                       (osr-comfyui)
#   IMAGE                Incus image                          (images:ubuntu/26.04)
#   CT_IP                fixed IPv4 on the Incus bridge       (10.127.234.11)
#   GPU_PCI              PCI address of the GPU (lspci -D)    (auto: first NVIDIA)
#   CPUS / MEMORY        resource limits                      (4 / 16GiB)
#   NVIDIA_BRANCH        driver package suffix                (auto from the host)
#   COMFYUI_IMAGE_VARIANT klein-4b | klein-9b                 (klein-4b)
#   TORCH_BUILD          PyTorch wheel index suffix           (cu130)
#   HF_TOKEN             Hugging Face token (klein-9b only)
set -euo pipefail

CT_NAME="${CT_NAME:-osr-comfyui}"
IMAGE="${IMAGE:-images:ubuntu/26.04}"
CT_IP="${CT_IP:-10.127.234.11}"
CPUS="${CPUS:-4}"
MEMORY="${MEMORY:-16GiB}"
COMFYUI_IMAGE_VARIANT="${COMFYUI_IMAGE_VARIANT:-klein-4b}"
TORCH_BUILD="${TORCH_BUILD:-cu130}"
PY_VERSION="${PY_VERSION:-3.12}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="$REPO_ROOT/targets/comfyui"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

command -v incus >/dev/null || { echo "incus not found" >&2; exit 1; }
incus info >/dev/null 2>&1 || { echo "cannot talk to incus (incus-admin group?)" >&2; exit 1; }
[[ -r "$TARGET_DIR/install-target.sh" ]] || { echo "missing $TARGET_DIR/install-target.sh" >&2; exit 1; }
[[ $COMFYUI_IMAGE_VARIANT == klein-4b || $COMFYUI_IMAGE_VARIANT == klein-9b ]] || { echo "COMFYUI_IMAGE_VARIANT must be klein-4b or klein-9b" >&2; exit 1; }
if [[ $COMFYUI_IMAGE_VARIANT == klein-9b && -z "${HF_TOKEN:-}" ]]; then
  echo "klein-9b is gated on Hugging Face: set HF_TOKEN." >&2; exit 1
fi
if incus info "$CT_NAME" >/dev/null 2>&1; then
  echo "Container ${CT_NAME} already exists; refusing to touch it." >&2
  exit 1
fi

COMFYUI_VERSION="$(sed -n 's/^readonly COMFYUI_DEFAULT_VERSION=//p' "$TARGET_DIR/install-target.sh")"
COMFYUI_COMMIT="$(sed -n 's/^readonly COMFYUI_DEFAULT_COMMIT=//p' "$TARGET_DIR/install-target.sh")"
[[ $COMFYUI_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && $COMFYUI_COMMIT =~ ^[0-9a-f]{40}$ ]] || { echo "cannot read the pinned ComfyUI release from install-target.sh" >&2; exit 1; }
echo "ComfyUI ${COMFYUI_VERSION} (${COMFYUI_COMMIT:0:12}), PyTorch ${TORCH_BUILD}, image model ${COMFYUI_IMAGE_VARIANT}."

# --- GPU and driver branch on the host ----------------------------------------------
if [[ -z "${GPU_PCI:-}" ]]; then
  GPU_PCI="$(lspci -D -d 10de: | awk '/3D controller|VGA compatible/ {print $1; exit}')"
fi
[[ -n "$GPU_PCI" ]] || { echo "no NVIDIA GPU found on the host" >&2; exit 1; }
nvidia-smi -L >/dev/null 2>&1 || { echo "nvidia-smi does not work on the host; install the driver first" >&2; exit 1; }
if [[ -z "${NVIDIA_BRANCH:-}" ]]; then
  NVIDIA_BRANCH="$(dpkg-query -W -f='${Package}\n' 'libnvidia-compute-*' 2>/dev/null | sed -n 's/^libnvidia-compute-\(.*\)$/\1/p' | head -1)"
fi
[[ -n "$NVIDIA_BRANCH" ]] || { echo "cannot tell the host's driver branch (set NVIDIA_BRANCH, e.g. 595-server)" >&2; exit 1; }

ct() { incus exec "$CT_NAME" -- "$@"; }

# --- container ---------------------------------------------------------------------------
echo "Creating container ${CT_NAME} (${CT_IP}) with GPU ${GPU_PCI}."
incus init "$IMAGE" "$CT_NAME" -c security.nesting=true -c boot.autostart=true \
  -c limits.cpu="$CPUS" -c limits.memory="$MEMORY"
incus config device override "$CT_NAME" eth0 ipv4.address="$CT_IP"
incus config device add "$CT_NAME" gpu0 gpu pci="$GPU_PCI"
incus start "$CT_NAME"

for _ in $(seq 1 60); do
  state="$(ct systemctl is-system-running 2>/dev/null || true)"
  if [[ "$state" == running || "$state" == degraded ]] && ct getent hosts archive.ubuntu.com >/dev/null 2>&1; then break; fi
  sleep 2
done
ct getent hosts archive.ubuntu.com >/dev/null || { echo "no DNS/network in the container" >&2; exit 1; }

echo "Installing base packages and the NVIDIA user-space libraries."
ct apt-get update -qq
ct apt-get install -y -qq git curl ca-certificates python3 python3-venv python3-pip pciutils
ct apt-get install -y -qq "libnvidia-compute-${NVIDIA_BRANCH}" "nvidia-utils-${NVIDIA_BRANCH}"
ct nvidia-smi -L || { echo "nvidia-smi fails inside the container" >&2; exit 1; }

# --- what the community script would have left ------------------------------------------------
echo "Installing uv."
ct bash -c "
  set -e
  python3 -m venv /opt/uv-bootstrap
  /opt/uv-bootstrap/bin/pip install --no-cache-dir -q --upgrade pip uv
  ln -sfn /opt/uv-bootstrap/bin/uv /usr/local/bin/uv
  uv --version
"

echo "Checking out ComfyUI ${COMFYUI_VERSION} at the reviewed commit."
ct bash -c "
  set -euo pipefail
  git clone --quiet https://github.com/Comfy-Org/ComfyUI.git /opt/ComfyUI
  git -C /opt/ComfyUI checkout --quiet '${COMFYUI_COMMIT}'
  [ \"\$(git -C /opt/ComfyUI rev-parse HEAD)\" = '${COMFYUI_COMMIT}' ]
  printf '%s\n' '${COMFYUI_COMMIT}' > /opt/ComfyUI/.comfyui-target-commit
  grep -E '^__version__' /opt/ComfyUI/comfyui_version.py
"

echo "Building the venv (Python ${PY_VERSION}, PyTorch ${TORCH_BUILD}); this is a large download."
ct bash -c "
  set -euo pipefail
  cd /opt/ComfyUI
  uv venv --quiet --python '${PY_VERSION}' venv
  uv pip install --quiet --python venv/bin/python torch torchvision torchaudio \
    --index-url 'https://download.pytorch.org/whl/${TORCH_BUILD}'
  uv pip install --quiet --python venv/bin/python -r requirements.txt
  venv/bin/python -c 'import torch, torchvision, aiohttp, sqlalchemy, yaml, safetensors; print(\"torch\", torch.__version__, \"cuda\", torch.version.cuda)'
"

cat > "$STAGE/comfyui.service" <<'EOF'
[Unit]
Description=ComfyUI
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/ComfyUI
ExecStart=/opt/ComfyUI/venv/bin/python /opt/ComfyUI/main.py --listen 0.0.0.0 --port 8188
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
incus file push "$STAGE/comfyui.service" "$CT_NAME/etc/systemd/system/comfyui.service"
ct systemctl daemon-reload

# --- adopt with the repo's own installer and fetch the weights --------------------------------------
echo "Pushing the target files and adopting the install (downloads the ${COMFYUI_IMAGE_VARIANT} weights)."
ct mkdir -p /root/comfyui-target-deploy
tar -C "$TARGET_DIR" -cf - . | incus exec "$CT_NAME" -- tar -C /root/comfyui-target-deploy -xf -
if [[ -n "${HF_TOKEN:-}" ]]; then
  ( umask 077; printf '%s' "$HF_TOKEN" > "$STAGE/hf_token" )
  incus file push --mode 0600 "$STAGE/hf_token" "$CT_NAME/root/hf_token"
  ct env COMFYUI_IMAGE_VARIANT="$COMFYUI_IMAGE_VARIANT" COMFYUI_DEVICE=gpu HF_TOKEN_FILE=/root/hf_token \
    bash /root/comfyui-target-deploy/install-target.sh
  ct rm -f /root/hf_token
else
  ct env COMFYUI_IMAGE_VARIANT="$COMFYUI_IMAGE_VARIANT" COMFYUI_DEVICE=gpu \
    bash /root/comfyui-target-deploy/install-target.sh
fi

echo "=============================================================================="
echo "ComfyUI container ${CT_NAME} is up at http://${CT_IP}:8188 (internal bridge only)."
echo "  Status       : incus exec ${CT_NAME} -- systemctl status comfyui"
echo "  GPU check    : curl -s http://${CT_IP}:8188/system_stats"
echo "  Open WebUI   : OPENWEBUI_ADMIN_TOKEN=<admin api key> incus/integrate-comfyui-incus.sh"
echo "=============================================================================="
