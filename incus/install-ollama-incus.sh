#!/usr/bin/env bash
# Incus port of the Ollama inference target (targets/ollama).
#
# Creates an Ubuntu container with the host's NVIDIA GPU attached, installs the
# repo-pinned Ollama release the way the Proxmox community script lays it out
# (/usr/local/lib/ollama + /usr/local/bin/ollama + ollama.service), then runs
# the repo's own targets/ollama/install-target.sh to adopt it (unprivileged
# user, hardening drop-in, env file, model dir).
#
# Prerequisites on the host: Incus, and the NVIDIA driver installed from the
# Ubuntu archive (the container installs the SAME-version user-space libraries).
#
# Settings (environment variables):
#   CT_NAME              container name                       (osr-ollama)
#   IMAGE                Incus image                          (images:ubuntu/26.04)
#   CT_IP                fixed IPv4 on the Incus bridge       (10.127.234.10)
#   BRIDGE_NIC           name of the container NIC            (eth0)
#   GPU_PCI              PCI address of the GPU (lspci -D)    (auto: first NVIDIA)
#   CPUS / MEMORY        resource limits                      (4 / 16GiB)
#   NVIDIA_BRANCH        driver branch package suffix         (auto from the host)
#   OLLAMA_PULL_MODELS   models to pull after install         (llama3.2:3b)
#   OLLAMA_CONTEXT_LENGTH default context window              (32768)
set -euo pipefail

CT_NAME="${CT_NAME:-osr-ollama}"
IMAGE="${IMAGE:-images:ubuntu/26.04}"
CT_IP="${CT_IP:-10.127.234.10}"
CPUS="${CPUS:-4}"
MEMORY="${MEMORY:-16GiB}"
OLLAMA_PULL_MODELS="${OLLAMA_PULL_MODELS:-llama3.2:3b}"
OLLAMA_CONTEXT_LENGTH="${OLLAMA_CONTEXT_LENGTH:-32768}"
OLLAMA_DEFAULT_VERSION="$(sed -n 's/^readonly OLLAMA_DEFAULT_VERSION=//p' "$(dirname "${BASH_SOURCE[0]}")/../targets/ollama/install-target.sh")"
OLLAMA_VERSION="${OLLAMA_VERSION:-$OLLAMA_DEFAULT_VERSION}"
RELEASE_BASE="https://github.com/ollama/ollama/releases/download"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="$REPO_ROOT/targets/ollama"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

command -v incus >/dev/null || { echo "incus not found" >&2; exit 1; }
incus info >/dev/null 2>&1 || { echo "cannot talk to incus (incus-admin group?)" >&2; exit 1; }
[[ -r "$TARGET_DIR/install-target.sh" ]] || { echo "missing $TARGET_DIR/install-target.sh" >&2; exit 1; }
[[ $OLLAMA_VERSION =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "bad OLLAMA_VERSION '$OLLAMA_VERSION'" >&2; exit 1; }
if incus info "$CT_NAME" >/dev/null 2>&1; then
  echo "Container ${CT_NAME} already exists; refusing to touch it." >&2
  exit 1
fi

# --- find the GPU and the driver branch on the host ---------------------------
if [[ -z "${GPU_PCI:-}" ]]; then
  GPU_PCI="$(lspci -D -d 10de: | awk '/3D controller|VGA compatible/ {print $1; exit}')"
fi
[[ -n "$GPU_PCI" ]] || { echo "no NVIDIA GPU found on the host" >&2; exit 1; }
HOST_DRIVER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)"
[[ -n "$HOST_DRIVER" ]] || { echo "nvidia-smi does not work on the host; install the driver first" >&2; exit 1; }
if [[ -z "${NVIDIA_BRANCH:-}" ]]; then
  NVIDIA_BRANCH="$(dpkg-query -W -f='${Package}\n' 'libnvidia-compute-*' 2>/dev/null | sed -n 's/^libnvidia-compute-\(.*\)$/\1/p' | head -1)"
fi
[[ -n "$NVIDIA_BRANCH" ]] || { echo "cannot tell the host's driver branch (set NVIDIA_BRANCH, e.g. 595-server)" >&2; exit 1; }
echo "GPU ${GPU_PCI}, host driver ${HOST_DRIVER}, package branch ${NVIDIA_BRANCH}."

ct() { incus exec "$CT_NAME" -- "$@"; }

# --- container ----------------------------------------------------------------
echo "Creating container ${CT_NAME} (${CT_IP})."
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
ct apt-get install -y -qq curl ca-certificates zstd pciutils
ct apt-get install -y -qq "libnvidia-compute-${NVIDIA_BRANCH}" "nvidia-utils-${NVIDIA_BRANCH}"
if ! ct nvidia-smi -L; then
  echo "nvidia-smi fails inside the container (driver/library mismatch or the GPU device is not passed in)." >&2
  exit 1
fi

# --- Ollama release (pinned, checksum-verified) ---------------------------------
echo "Installing Ollama ${OLLAMA_VERSION}."
ct bash -c "
  set -euo pipefail
  work=\$(mktemp -d)
  archive=ollama-linux-amd64.tar.zst
  curl -fsSL --retry 3 -o \"\$work/sha256sum.txt\" '${RELEASE_BASE}/${OLLAMA_VERSION}/sha256sum.txt'
  curl -fsSL --retry 3 -o \"\$work/\$archive\" '${RELEASE_BASE}/${OLLAMA_VERSION}/'\"\$archive\"
  want=\$(awk -v n=\"\$archive\" '{f=\$2; sub(/^\\*?(\\.\\/)?/,\"\",f)} f==n {print tolower(\$1); exit}' \"\$work/sha256sum.txt\")
  got=\$(sha256sum \"\$work/\$archive\" | awk '{print \$1}')
  [ -n \"\$want\" ] && [ \"\$got\" = \"\$want\" ] || { echo 'checksum mismatch' >&2; exit 1; }
  install -d -m 0755 /usr/local/lib/ollama
  zstd -dc \"\$work/\$archive\" | tar -xf - -C /usr/local/lib/ollama --no-same-owner
  chmod -R u=rwX,go=rX /usr/local/lib/ollama
  ln -sfn /usr/local/lib/ollama/bin/ollama /usr/local/bin/ollama
  rm -rf \"\$work\"
  /usr/local/bin/ollama --version
"

# The unit the community script would have left; install-target.sh layers its
# hardening drop-in on top of this.
cat > "$STAGE/ollama.service" <<'EOF'
[Unit]
Description=Ollama Service
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
ExecStart=/usr/local/bin/ollama serve
Environment=HOME=/root
Environment=OLLAMA_HOST=0.0.0.0
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
incus file push "$STAGE/ollama.service" "$CT_NAME/etc/systemd/system/ollama.service"

echo "Pushing the target files and adopting the install."
ct mkdir -p /root/ollama-target
tar -C "$TARGET_DIR" -cf - . | incus exec "$CT_NAME" -- tar -C /root/ollama-target -xf -
ct env OLLAMA_GPU=nvidia OLLAMA_PULL_MODELS="$OLLAMA_PULL_MODELS" OLLAMA_CONTEXT_LENGTH="$OLLAMA_CONTEXT_LENGTH" \
  bash /root/ollama-target/install-target.sh

echo "=============================================================================="
echo "Ollama container ${CT_NAME} is up at http://${CT_IP}:11434"
echo "  GPU check : incus exec ${CT_NAME} -- journalctl -u ollama | grep -i -E 'inference compute|cuda'"
echo "  Models    : incus exec ${CT_NAME} -- ollama list"
echo "  Register  : incus exec osr-router -- manage-model-servers add http://${CT_IP}:11434 ..."
echo "=============================================================================="
