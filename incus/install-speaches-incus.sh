#!/usr/bin/env bash
# Voice container for Open WebUI voice chat: Speaches (speaches-ai/speaches), an
# OpenAI-compatible server for speech-to-text (faster-whisper) and
# text-to-speech (Kokoro, Piper). Incus-only; there is no Proxmox equivalent in
# this repo.
#
# Builds an Ubuntu container with the host's NVIDIA GPU attached, installs the
# pinned Speaches commit natively with uv (no Docker), runs it as a hardened
# systemd service, downloads one STT and one TTS model and round-trips a
# sentence through both as a self-test.
#
# Open WebUI is NOT reconfigured here (Admin Settings > Audio); see the summary
# printed at the end.
#
# Settings (environment variables):
#   CT_NAME        container name                         (osr-speaches)
#   IMAGE          Incus image                            (images:ubuntu/26.04)
#   BRIDGE       Incus bridge to take the subnet from      (incusbr0)
#   CT_IP          fixed IPv4 on the Incus bridge         (.12 in the bridge /24)
#   GPU_PCI        PCI address of the GPU (lspci -D)      (auto: first NVIDIA)
#   CPUS / MEMORY  resource limits                        (4 / 8GiB)
#   NVIDIA_BRANCH  driver package suffix                  (auto from the host)
#   SPEACHES_COMMIT reviewed upstream commit              (993994f7984bf3fe9655b267448328cf66fccb42)
#   STT_MODEL      Whisper model to download              (Systran/faster-whisper-small)
#   TTS_MODEL      TTS model to download                  (speaches-ai/Kokoro-82M-v1.0-ONNX)
#   TTL_SECONDS    seconds an idle model stays on the GPU (60)
set -euo pipefail

CT_NAME="${CT_NAME:-osr-speaches}"
IMAGE="${IMAGE:-images:ubuntu/26.04}"
CT_IP="${CT_IP:-}"
BRIDGE="${BRIDGE:-incusbr0}"
# Default container address: .N in the bridge's /24. Incus picks a random subnet
# for each host, so nothing here may assume a particular one.
bridge_ip() {
  local cidr
  cidr="$(incus network get "$BRIDGE" ipv4.address 2>/dev/null || true)"
  if [[ "$cidr" =~ ^([0-9]+\.[0-9]+\.[0-9]+)\.[0-9]+/24$ ]]; then
    echo "${BASH_REMATCH[1]}.$1"
  else
    echo "cannot derive a default address: ${BRIDGE} ipv4.address is '${cidr}' (expected an IPv4 /24); set CT_IP" >&2
    return 1
  fi
}
CPUS="${CPUS:-4}"
MEMORY="${MEMORY:-8GiB}"
SPEACHES_COMMIT="${SPEACHES_COMMIT:-993994f7984bf3fe9655b267448328cf66fccb42}"
STT_MODEL="${STT_MODEL:-Systran/faster-whisper-small}"
TTS_MODEL="${TTS_MODEL:-speaches-ai/Kokoro-82M-v1.0-ONNX}"
TTL_SECONDS="${TTL_SECONDS:-60}"
VOICE="${VOICE:-af_heart}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

command -v incus >/dev/null || { echo "incus not found" >&2; exit 1; }
incus info >/dev/null 2>&1 || { echo "cannot talk to incus (incus-admin group?)" >&2; exit 1; }
[[ -n "$CT_IP" ]] || CT_IP="$(bridge_ip 12)"
[[ $SPEACHES_COMMIT =~ ^[0-9a-f]{40}$ ]] || { echo "SPEACHES_COMMIT must be a full 40-digit SHA-1" >&2; exit 1; }
if incus info "$CT_NAME" >/dev/null 2>&1; then
  echo "Container ${CT_NAME} already exists; refusing to touch it." >&2
  exit 1
fi

if [[ -z "${GPU_PCI:-}" ]]; then
  GPU_PCI="$(lspci -D -d 10de: | awk '/3D controller|VGA compatible/ {print $1; exit}')"
fi
[[ -n "$GPU_PCI" ]] || { echo "no NVIDIA GPU found on the host" >&2; exit 1; }
nvidia-smi -L >/dev/null 2>&1 || { echo "nvidia-smi does not work on the host" >&2; exit 1; }
if [[ -z "${NVIDIA_BRANCH:-}" ]]; then
  NVIDIA_BRANCH="$(dpkg-query -W -f='${Package}\n' 'libnvidia-compute-*' 2>/dev/null | sed -n 's/^libnvidia-compute-\(.*\)$/\1/p' | head -1)"
fi
[[ -n "$NVIDIA_BRANCH" ]] || { echo "cannot tell the host's driver branch (set NVIDIA_BRANCH)" >&2; exit 1; }

ct() { incus exec "$CT_NAME" -- "$@"; }

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
ct apt-get install -y -qq git curl ca-certificates ffmpeg python3 python3-venv python3-pip pciutils
ct apt-get install -y -qq "libnvidia-compute-${NVIDIA_BRANCH}" "nvidia-utils-${NVIDIA_BRANCH}"
ct nvidia-smi -L || { echo "nvidia-smi fails inside the container" >&2; exit 1; }

echo "Installing uv."
ct bash -c "
  set -e
  python3 -m venv /opt/uv-bootstrap
  /opt/uv-bootstrap/bin/pip install --no-cache-dir -q --upgrade pip uv
  ln -sfn /opt/uv-bootstrap/bin/uv /usr/local/bin/uv
"

echo "Checking out Speaches ${SPEACHES_COMMIT:0:12} and building its environment."
ct bash -c "
  set -euo pipefail
  git clone --quiet https://github.com/speaches-ai/speaches /opt/speaches
  git -C /opt/speaches checkout --quiet '${SPEACHES_COMMIT}'
  [ \"\$(git -C /opt/speaches rev-parse HEAD)\" = '${SPEACHES_COMMIT}' ]
  cd /opt/speaches
  export UV_PYTHON_INSTALL_DIR=/opt/python UV_LINK_MODE=copy
  uv sync --frozen --no-dev --quiet
  chmod -R a+rX /opt/python /opt/speaches
  # The CUDA libraries live inside the venv (pip wheels); register them so the
  # C++ libraries (ctranslate2, onnxruntime) find them.
  find /opt/speaches/.venv -maxdepth 7 -path '*/nvidia/*/lib' -type d > /etc/ld.so.conf.d/venv-nvidia.conf
  ldconfig
  /opt/speaches/.venv/bin/python -c 'import ctranslate2, faster_whisper, kokoro_onnx; print(\"imports ok; ctranslate2\", ctranslate2.__version__, \"cuda devices:\", ctranslate2.get_cuda_device_count())'
"

echo "Creating the service."
ct bash -c "
  set -e
  getent group speaches >/dev/null || groupadd --system speaches
  getent passwd speaches >/dev/null || useradd --system --gid speaches --home-dir /var/lib/speaches --create-home --shell /usr/sbin/nologin speaches
  usermod -a -G video speaches || true
  install -d -o speaches -g speaches -m 0750 /var/lib/speaches /var/lib/speaches/hf
"
cat > "$STAGE/speaches.service" <<EOF
[Unit]
Description=Speaches (OpenAI-compatible speech-to-text and text-to-speech)
After=network-online.target
Wants=network-online.target

[Service]
User=speaches
Group=speaches
WorkingDirectory=/opt/speaches
Environment=HOME=/var/lib/speaches
Environment=HF_HOME=/var/lib/speaches/hf
Environment=PATH=/opt/speaches/.venv/bin:/usr/local/bin:/usr/bin:/bin
Environment=STT_MODEL_TTL=${TTL_SECONDS}
Environment=TTS_MODEL_TTL=${TTL_SECONDS}
Environment=WHISPER__COMPUTE_TYPE=int8_float16
Environment=DO_NOT_TRACK=1
Environment=DISABLE_TELEMETRY=1
Environment=HF_HUB_DISABLE_TELEMETRY=1
Environment=GRADIO_ANALYTICS_ENABLED=False
Environment=PYANNOTE_METRICS_ENABLED=0
ExecStart=/opt/speaches/.venv/bin/uvicorn --factory speaches.main:create_app --host 0.0.0.0 --port 8000
Restart=on-failure
RestartSec=5
TimeoutStopSec=30
UMask=0027
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/speaches
PrivateTmp=true
# Keep the passed-through GPU device nodes visible.
PrivateDevices=false
RestrictSUIDSGID=true
LockPersonality=true
CapabilityBoundingSet=
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6 AF_NETLINK

[Install]
WantedBy=multi-user.target
EOF
incus file push "$STAGE/speaches.service" "$CT_NAME/etc/systemd/system/speaches.service"
ct systemctl daemon-reload
ct systemctl enable --now speaches.service

echo "Waiting for the API."
ready=""
for _ in $(seq 1 60); do
  if ct curl -fsS -m3 -o /dev/null http://127.0.0.1:8000/health 2>/dev/null; then ready=1; break; fi
  sleep 3
done
[[ -n "$ready" ]] || { ct systemctl status speaches --no-pager -n 30 || true; echo "Speaches did not come up" >&2; exit 1; }

echo "Downloading models: ${STT_MODEL} and ${TTS_MODEL}."
ct curl -fsS -m900 -X POST "http://127.0.0.1:8000/v1/models/${STT_MODEL}" -o /dev/null
ct curl -fsS -m900 -X POST "http://127.0.0.1:8000/v1/models/${TTS_MODEL}" -o /dev/null

echo "Self-test: text -> speech -> text."
ct bash -c "
  set -e
  curl -fsS -m300 http://127.0.0.1:8000/v1/audio/speech -H 'Content-Type: application/json' \
    -d '{\"input\":\"Hello. This is a test of the voice chat system.\",\"model\":\"${TTS_MODEL}\",\"voice\":\"${VOICE}\",\"response_format\":\"wav\"}' \
    -o /tmp/selftest.wav
  ls -l /tmp/selftest.wav
  curl -fsS -m300 http://127.0.0.1:8000/v1/audio/transcriptions -F 'file=@/tmp/selftest.wav' -F 'model=${STT_MODEL}'
  echo
  rm -f /tmp/selftest.wav
"

echo "=============================================================================="
echo "Speaches container ${CT_NAME} is up at http://${CT_IP}:8000 (internal bridge only)."
echo
echo "Open WebUI > Admin Settings > Audio:"
echo "  Speech-to-Text : engine OpenAI, URL http://${CT_IP}:8000/v1, key any non-empty text, model ${STT_MODEL}"
echo "  Text-to-Speech : engine OpenAI, URL http://${CT_IP}:8000/v1, key any non-empty text,"
echo "                   model ${TTS_MODEL}, voice ${VOICE}"
echo "Voice calls need HTTPS or localhost in the browser; from a Mac use:"
echo "  ssh -L 8080:localhost:8080 <this host>   then open http://localhost:8080"
echo "=============================================================================="
