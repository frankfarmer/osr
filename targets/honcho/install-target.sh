#!/usr/bin/env bash
# Run as root inside the dedicated Honcho LXC. The provisioner pushes the
# router key in a root-only file before calling this script.
set -Eeuo pipefail
umask 077

deploy=${HONCHO_DEPLOY_DIR:-/root/honcho-deploy}
opt=${HONCHO_OPT:-/opt/honcho}
etc=${HONCHO_ETC:-/etc/honcho-target}
ref=${HONCHO_REF:-main}
model=${HONCHO_MODEL:-fast}
router_url=${ROUTER_URL:-}
embedding_model=${HONCHO_EMBEDDING_MODEL:-}
embedding_dimensions=${HONCHO_EMBEDDING_DIMENSIONS:-}
embedding_url=${HONCHO_EMBEDDING_BASE_URL:-${router_url}/v1}
embedding_dimensions_mode=${HONCHO_EMBEDDING_DIMENSIONS_MODE:-never}
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }

[[ $(id -u) == 0 ]] || die 'Run as root in the Honcho CT.'
[[ $router_url =~ ^https?://[A-Za-z0-9][A-Za-z0-9._-]*:[0-9]{1,5}$ ]] || die 'Set ROUTER_URL to the OSR base URL.'
[[ $model =~ ^[A-Za-z0-9][A-Za-z0-9._:/+-]*$ ]] || die 'Invalid HONCHO_MODEL.'
[[ $embedding_model =~ ^[A-Za-z0-9][A-Za-z0-9._:/+-]*$ ]] || die 'Set HONCHO_EMBEDDING_MODEL to a model served by an OpenAI-compatible embedding endpoint.'
[[ $embedding_dimensions =~ ^[1-9][0-9]{0,5}$ ]] || die 'Set HONCHO_EMBEDDING_DIMENSIONS to the model vector size.'
[[ $embedding_url =~ ^https?://[A-Za-z0-9][A-Za-z0-9._-]*:[0-9]{1,5}/v1/?$ ]] || die 'Set HONCHO_EMBEDDING_BASE_URL to an HTTP(S) host:port/v1 endpoint.'
[[ $embedding_dimensions_mode =~ ^(never|auto|always)$ ]] || die 'HONCHO_EMBEDDING_DIMENSIONS_MODE must be never, auto or always.'
embedding_url=${embedding_url%/}
[[ $ref =~ ^(main|v[0-9][A-Za-z0-9._-]*|[0-9a-f]{40})$ ]] || die 'HONCHO_REF must be main, a release tag or a full commit SHA.'
[[ -s $deploy/router-api-key ]] || die "Missing $deploy/router-api-key."

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  ca-certificates curl git openssl python3 python3-venv postgresql postgresql-client
python3 - "$router_url" "$model" "$embedding_url" "$embedding_model" "$embedding_dimensions" "$embedding_dimensions_mode" "$deploy/router-api-key" <<'PY'
import json
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen

base, model, embedding_base, embedding_model, dimensions, dimensions_mode, key_file = sys.argv[1:]
key = Path(key_file).read_text(encoding="utf-8").strip()
headers = {"Authorization": "Bearer " + key} if key != "no-key" else {}
try:
    with urlopen(Request(base + "/v1/models", headers=headers), timeout=15) as response:
        models = json.load(response)
    ids = {item.get("id") for item in models.get("data", [])}
    if model not in ids:
        sys.exit(f"The router does not advertise Honcho model {model!r} at {base}/v1/models.")
    body = {"model": embedding_model, "input": "Honcho setup check",
            "encoding_format": "float"}
    if dimensions_mode in ("auto", "always"):
        body["dimensions"] = int(dimensions)
    embedding_key = key if embedding_base == base + "/v1" else "no-key"
    request = Request(embedding_base + "/embeddings", data=json.dumps(body).encode(),
                      headers={"Authorization": "Bearer " + embedding_key,
                               "Content-Type": "application/json"})
    with urlopen(request, timeout=30) as response:
        embedding = json.load(response)["data"][0]["embedding"]
    if len(embedding) != int(dimensions):
        sys.exit(f"HONCHO_EMBEDDING_DIMENSIONS={dimensions} but {embedding_model!r} returned {len(embedding)} values.")
except (HTTPError, URLError, ValueError, KeyError, IndexError, TypeError) as exc:
    sys.exit(f"Honcho cannot use the router model or embedding endpoint: {exc}")
PY
systemctl enable --now postgresql
pg_major=$(runuser -u postgres -- psql -Atqc 'SHOW server_version_num' 2>/dev/null | cut -c1-2)
[[ $pg_major =~ ^[0-9]{2}$ ]] || die 'PostgreSQL did not start.'
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "postgresql-${pg_major}-pgvector" ||
  die "The template has no postgresql-${pg_major}-pgvector package. Choose a Debian template with matching pgvector."
systemctl enable --now postgresql

if ! id honcho >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/honcho --create-home --shell /usr/sbin/nologin honcho
fi
install -d -m 0750 -o honcho -g honcho "$opt"
install -d -m 0750 -o root -g honcho "$etc"
if [[ ! -d $opt/.git ]]; then
  git clone https://github.com/plastic-labs/honcho.git "$opt"
fi
git -C "$opt" fetch --tags origin
if [[ $ref == main ]]; then ref=origin/main; fi
git -C "$opt" checkout --detach "$ref"
chown -R honcho:honcho "$opt"

if [[ ! -x /opt/honcho-uv/bin/uv ]]; then
  python3 -m venv /opt/honcho-uv
  /opt/honcho-uv/bin/pip install --no-cache-dir uv
fi
runuser -u honcho -- env HOME=/var/lib/honcho /opt/honcho-uv/bin/uv --directory "$opt" sync --frozen --no-dev --python 3.13

if [[ ! -s $etc/db-password ]]; then openssl rand -hex 32 > "$etc/db-password"; fi
db_password=$(<"$etc/db-password")
if ! runuser -u postgres -- psql -Atqc "SELECT 1 FROM pg_roles WHERE rolname='honcho'" | grep -qx 1; then
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "CREATE ROLE honcho LOGIN PASSWORD '$db_password'"
else
  runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "ALTER ROLE honcho PASSWORD '$db_password'"
fi
if ! runuser -u postgres -- psql -Atqc "SELECT 1 FROM pg_database WHERE datname='honcho'" | grep -qx 1; then
  runuser -u postgres -- createdb -O honcho honcho
fi
runuser -u postgres -- psql -d honcho -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION IF NOT EXISTS vector'
runuser -u postgres -- psql -d honcho -v ON_ERROR_STOP=1 -c 'CREATE EXTENSION IF NOT EXISTS pg_trgm'

if [[ ! -s $etc/jwt-secret ]]; then openssl rand -hex 48 > "$etc/jwt-secret"; fi
router_key=$(<"$deploy/router-api-key")
[[ -n $router_key ]] || router_key=no-key
{
  printf 'DB_CONNECTION_URI=postgresql+psycopg://honcho:%s@127.0.0.1:5432/honcho\n' "$db_password"
  printf 'AUTH_USE_AUTH=true\nAUTH_JWT_SECRET=%s\n' "$(<"$etc/jwt-secret")"
  printf 'LLM_OPENAI_API_KEY=%s\n' "$router_key"
  for prefix in DERIVER SUMMARY DREAM_DEDUCTION DREAM_INDUCTION; do
    printf '%s_MODEL_CONFIG__MODEL=%s\n' "$prefix" "$model"
    printf '%s_MODEL_CONFIG__OVERRIDES__BASE_URL=%s/v1\n' "$prefix" "$router_url"
  done
  for level in minimal low medium high max; do
    printf 'DIALECTIC_LEVELS__%s__MODEL_CONFIG__MODEL=%s\n' "$level" "$model"
    printf 'DIALECTIC_LEVELS__%s__MODEL_CONFIG__OVERRIDES__BASE_URL=%s/v1\n' "$level" "$router_url"
  done
  printf 'EMBEDDING_VECTOR_DIMENSIONS=%s\n' "$embedding_dimensions"
  printf 'EMBEDDING_MODEL_CONFIG__MODEL=%s\n' "$embedding_model"
  printf 'EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL=%s\n' "$embedding_url"
  if [[ $embedding_url != "$router_url/v1" ]]; then
    printf 'EMBEDDING_MODEL_CONFIG__OVERRIDES__API_KEY=no-key\n'
  fi
  printf 'EMBEDDING_MODEL_CONFIG__DIMENSIONS_MODE=%s\n' "$embedding_dimensions_mode"
} > "$etc/honcho.env"
chown root:honcho "$etc/honcho.env"
chmod 0640 "$etc/honcho.env"
runuser -u honcho -- env HOME=/var/lib/honcho EMBEDDING_VECTOR_DIMENSIONS=1536 \
  /opt/honcho-uv/bin/uv --directory "$opt" run --no-dev --env-file "$etc/honcho.env" alembic upgrade head
runuser -u honcho -- env HOME=/var/lib/honcho /opt/honcho-uv/bin/uv --directory "$opt" run --no-dev --env-file "$etc/honcho.env" \
  python scripts/configure_embeddings.py --yes

if [[ ! -s $etc/api-key ]]; then
  runuser -u honcho -- env HOME=/var/lib/honcho /opt/honcho-uv/bin/uv --directory "$opt" run --no-dev --env-file "$etc/honcho.env" \
    python scripts/generate_jwt.py --admin --print-only > "$etc/api-key"
  chmod 0600 "$etc/api-key"
fi

# Bun runs the upstream HTTP MCP package. It forwards each client's bearer key
# to the authenticated API; the key is never stored in this unit.
if [[ ! -x /var/lib/honcho/.bun/bin/bun ]]; then
  runuser -u honcho -- env HOME=/var/lib/honcho bash -c 'curl -fsSL https://bun.sh/install | bash'
fi
runuser -u honcho -- env HOME=/var/lib/honcho /var/lib/honcho/.bun/bin/bun --cwd "$opt/mcp" install --frozen-lockfile
install -m 0644 "$deploy/honcho-api.service" /etc/systemd/system/honcho-api.service
install -m 0644 "$deploy/honcho-deriver.service" /etc/systemd/system/honcho-deriver.service
install -m 0644 "$deploy/honcho-mcp.service" /etc/systemd/system/honcho-mcp.service
systemctl daemon-reload
systemctl enable --now honcho-api.service honcho-deriver.service honcho-mcp.service
systemctl restart honcho-api.service honcho-deriver.service honcho-mcp.service
for attempt in {1..60}; do
  if curl -fsS --max-time 2 http://127.0.0.1:8000/health >/dev/null &&
     curl -fsS --max-time 2 http://127.0.0.1:3000/health >/dev/null; then
    printf 'Honcho API and MCP are healthy.\n'
    exit 0
  fi
  sleep 2
done
die 'Honcho did not become healthy. Inspect journalctl -u honcho-api -u honcho-deriver -u honcho-mcp.'
