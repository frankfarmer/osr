#!/usr/bin/env bash
# Run as root inside the dedicated Honcho LXC. The provisioner pushes the
# router key in a root-only file before calling this script.
#
# A rerun on an installed CT sets the configuration, keys and units aside,
# stops the services and dumps the database before migrations. Any failure
# after that point restores the previous commit, database, configuration and
# units, and starts them again.
set -Eeuo pipefail
umask 077

deploy=${HONCHO_DEPLOY_DIR:-/root/honcho-deploy}
opt=${HONCHO_OPT:-/opt/honcho}
etc=${HONCHO_ETC:-/etc/honcho-target}
# Test hooks: the tests point these into a temporary tree.
state=${HONCHO_STATE_DIR:-/var/lib/honcho-target}
home=${HONCHO_HOME:-/var/lib/honcho}
uv=${HONCHO_UV_DIR:-/opt/honcho-uv}/bin/uv
uv_dir=${HONCHO_UV_DIR:-/opt/honcho-uv}
bun_dir=${HONCHO_BUN_DIR:-/opt/honcho-bun}
unit_dir=${HONCHO_UNIT_DIR:-/etc/systemd/system}
# A directory of its own: Python puts a script's directory first on its import
# path, so nothing else may live beside the proxy.
proxy_lib_dir=${HONCHO_PROXY_LIB_DIR:-/usr/local/lib/honcho-proxy}
proxy_url=http://127.0.0.1:8765
cpuinfo=${HONCHO_CPUINFO:-/proc/cpuinfo}
health_tries=${HONCHO_HEALTH_TRIES:-60}

# Settings a reconfigure keeps, from settings.env: unset here, the last run's
# value is used; set and empty, the default. Only these names are read back.
kept_names=(HONCHO_REF HONCHO_MODEL HONCHO_STRUCTURED_OUTPUT_MODE HONCHO_EMBEDDING_DIMENSIONS_MODE
  HONCHO_BUN_VERSION HONCHO_BUN_SHA256 HONCHO_BUN_BASELINE_SHA256)
kept_from_last_run=()
if [[ -f $etc/settings.env ]]; then
  while IFS='=' read -r key value; do
    [[ " ${kept_names[*]} " == *" $key "* ]] || continue
    [[ -z ${!key+set} ]] || continue
    printf -v "$key" '%s' "$value"
    kept_from_last_run+=("$key=$value")
  done < "$etc/settings.env"
fi

ref=${HONCHO_REF:-v3.5.0}
model=${HONCHO_MODEL:-fast}
router_url=${ROUTER_URL:-}
embedding_model=${HONCHO_EMBEDDING_MODEL:-}
embedding_dimensions=${HONCHO_EMBEDDING_DIMENSIONS:-}
embedding_endpoint_chosen=${HONCHO_EMBEDDING_BASE_URL+x}
embedding_url=${HONCHO_EMBEDDING_BASE_URL:-}
embedding_dimensions_mode=${HONCHO_EMBEDDING_DIMENSIONS_MODE:-never}
# Empty keeps upstream's default (JSON-schema output); json_object is for
# backends that only do JSON mode.
structured_output_mode=${HONCHO_STRUCTURED_OUTPUT_MODE:-}
skip_probe=${HONCHO_SKIP_CHAT_PROBE:-false}
rotate_keys=${HONCHO_ROTATE_KEYS:-false}
# Bun runs the MCP server, from its release zip checked against a pinned
# SHA-256: bun-linux-x64 needs AVX2, bun-linux-x64-baseline does not.
default_bun_version=1.4.4
bun_version=${HONCHO_BUN_VERSION:-$default_bun_version}
bun_sha256_x64=${HONCHO_BUN_SHA256:-}
bun_sha256_baseline=${HONCHO_BUN_BASELINE_SHA256:-}
if [[ $bun_version == "$default_bun_version" ]]; then
  bun_sha256_x64=${bun_sha256_x64:-bf8ccbfb2b0b80159e0f9a6d15c55317add8077534dbc6130a3edb52fccb395c}
  bun_sha256_baseline=${bun_sha256_baseline:-e0446eb55995772eb9894bebae9a6be368d985a8b9271ee124486f9946eedd76}
fi
bun=$bun_dir/bun
units=(honcho-proxy honcho-api honcho-deriver honcho-mcp)
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
note() { printf '%s\n' "$*" >&2; }
(( ${#kept_from_last_run[@]} == 0 )) || note "Kept from the last run: ${kept_from_last_run[*]}"

if [[ ${1:-} == --help ]]; then
  cat <<'USAGE'
Usage: bash install-target.sh

Run as root inside an existing Honcho CT after the Proxmox provisioner has
staged router-api-key. An interactive run asks for ROUTER_URL, the embedding
model and its vector dimensions when unset. It also asks for the embedding
/v1 endpoint when HONCHO_EMBEDDING_BASE_URL is unset; a blank answer uses the
router inventory to find the model target. For unattended runs set ROUTER_URL,
HONCHO_EMBEDDING_MODEL, HONCHO_EMBEDDING_DIMENSIONS, and
HONCHO_EMBEDDING_BASE_URL (empty means router inventory).
CT ID and CT IP are chosen by provision-lxc.sh on the Proxmox host.
USAGE
  exit 0
fi

[[ $(id -u) == 0 ]] || die 'Run as root in the Honcho CT.'
if [[ ${NONINTERACTIVE:-false} != true && -t 0 ]]; then
  if [[ -z $router_url ]]; then
    IFS= read -r -p 'Router base URL (http(s)://router-address:port): ' router_url ||
      die 'No router URL was entered.'
  fi
  if [[ -z $embedding_model ]]; then
    IFS= read -r -p 'Embedding model served by the chosen endpoint: ' embedding_model ||
      die 'No embedding model was entered.'
  fi
  if [[ -z $embedding_dimensions ]]; then
    IFS= read -r -p 'Embedding vector dimensions: ' embedding_dimensions ||
      die 'No embedding dimensions were entered.'
  fi
  if [[ -z $embedding_endpoint_chosen ]]; then
    IFS= read -r -p 'Embedding base URL (/v1; blank = router inventory): ' embedding_url ||
      die 'No embedding endpoint choice was entered.'
    embedding_endpoint_chosen=yes
  fi
fi
[[ -n $embedding_endpoint_chosen ]] ||
  die 'Set HONCHO_EMBEDDING_BASE_URL to the embedding server /v1 URL, or set it to an empty string to use router inventory.'
embedding_url=${embedding_url:-${router_url}/v1}
[[ $router_url =~ ^https?://[A-Za-z0-9][A-Za-z0-9._-]*:[0-9]{1,5}$ ]] || die 'Set ROUTER_URL to the OSR base URL.'
[[ $model =~ ^[A-Za-z0-9][A-Za-z0-9._:/+-]*$ ]] || die 'Invalid HONCHO_MODEL.'
[[ $embedding_model =~ ^[A-Za-z0-9][A-Za-z0-9._:/+-]*$ ]] || die 'Set HONCHO_EMBEDDING_MODEL to a model served by an OpenAI-compatible embedding endpoint.'
[[ $embedding_dimensions =~ ^[1-9][0-9]{0,5}$ ]] || die 'Set HONCHO_EMBEDDING_DIMENSIONS to the model vector size.'
[[ $embedding_url =~ ^https?://[A-Za-z0-9][A-Za-z0-9._-]*(:[0-9]{1,5})?/v1/?$ ]] || die 'Set HONCHO_EMBEDDING_BASE_URL to an HTTP(S) host[:port]/v1 endpoint.'
[[ $embedding_dimensions_mode =~ ^(never|auto|always)$ ]] || die 'HONCHO_EMBEDDING_DIMENSIONS_MODE must be never, auto or always.'
[[ -z $structured_output_mode || $structured_output_mode =~ ^(json_schema|json_object)$ ]] || die 'HONCHO_STRUCTURED_OUTPUT_MODE must be json_schema or json_object.'
[[ $skip_probe =~ ^(true|false)$ && $rotate_keys =~ ^(true|false)$ ]] || die 'HONCHO_SKIP_CHAT_PROBE and HONCHO_ROTATE_KEYS are true or false.'
embedding_url=${embedding_url%/}
[[ $ref =~ ^(main|v[0-9][A-Za-z0-9._-]*|[0-9a-f]{40})$ ]] || die 'HONCHO_REF must be main, a release tag or a full commit SHA.'
[[ -s $deploy/router-api-key ]] || die "Missing $deploy/router-api-key."
[[ -s $deploy/budgets.py ]] || die "Missing $deploy/budgets.py."
for file in honcho-proxy.py direct_dispatch.py honcho-proxy.service; do
  [[ -s $deploy/$file ]] || die "Missing $deploy/$file."
done
[[ -f $deploy/backend-keys ]] || : > "$deploy/backend-keys"
[[ $bun_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'HONCHO_BUN_VERSION must be a release such as 1.4.4.'
for sha in "$bun_sha256_x64" "$bun_sha256_baseline"; do
  [[ -z $sha || $sha =~ ^[0-9a-f]{64}$ ]] || die 'HONCHO_BUN_SHA256 and HONCHO_BUN_BASELINE_SHA256 are SHA-256 hex digests.'
done

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  ca-certificates curl git openssl python3 python3-venv postgresql postgresql-client
# Token budgets for the model's context window (HONCHO_CONTEXT_TOKENS and the
# HONCHO_<SETTING> overrides; see the README), checked before anything changes.
# Unset variables keep the last run's values from $etc/budgets.env. A first
# install with no HONCHO_CONTEXT_TOKENS sizes them for 65536 tokens, the model
# targets' default context (set it empty for Honcho's own, 128k budgets).
if [[ ! -d $opt/.git && ! -e $etc/budgets.env && -z ${HONCHO_CONTEXT_TOKENS+set} ]]; then
  export HONCHO_CONTEXT_TOKENS=65536
fi
python3 "$deploy/budgets.py" "$etc/budgets.env" "$deploy/budgets.record" "$deploy/budgets.settings" ||
  die 'Invalid Honcho budget settings; nothing was changed.'
# The proxy alone contacts the router inventory and model hosts. It resolves
# one tool-capable model with enough context, probes tools and structured
# output, then checks the embedding endpoint before Honcho's data is touched.
context_tokens=$(sed -n 's/^HONCHO_CONTEXT_TOKENS=//p' "$deploy/budgets.record" | head -n1)
context_tokens=${context_tokens:-131072}
{
  printf 'ROUTER_URL=%s\nHONCHO_MODEL=%s\nHONCHO_CONTEXT_TOKENS=%s\n' "$router_url" "$model" "$context_tokens"
  printf 'EMBEDDING_BASE_URL=%s\nEMBEDDING_MODEL=%s\nEMBEDDING_DIMENSIONS=%s\n' \
    "$embedding_url" "$embedding_model" "$embedding_dimensions"
  printf 'EMBEDDING_DIMENSIONS_MODE=%s\nHONCHO_STRUCTURED_OUTPUT_MODE=%s\nHONCHO_SKIP_CHAT_PROBE=%s\n' \
    "$embedding_dimensions_mode" "$structured_output_mode" "$skip_probe"
} > "$deploy/proxy.settings"
selected_model=$(python3 "$deploy/honcho-proxy.py" --probe "$deploy") ||
  die 'Honcho proxy could not validate a direct chat and embedding target.'
[[ $selected_model =~ ^[A-Za-z0-9][A-Za-z0-9._:/+-]*$ ]] || die 'Honcho proxy selected an invalid model name.'
printf 'RESOLVED_MODEL=%s\n' "$selected_model" >> "$deploy/proxy.settings"
note "Honcho proxy selected $selected_model from router inventory for $model."
systemctl enable --now postgresql
pg_major=$(runuser -u postgres -- psql -Atqc 'SHOW server_version_num' 2>/dev/null | cut -c1-2)
[[ $pg_major =~ ^[0-9]{2}$ ]] || die 'PostgreSQL did not start.'
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "postgresql-${pg_major}-pgvector" ||
  die "The template has no postgresql-${pg_major}-pgvector package. Choose a Debian template with matching pgvector."
systemctl enable --now postgresql

if ! id honcho >/dev/null 2>&1; then
  useradd --system --home-dir "$home" --create-home --shell /usr/sbin/nologin honcho
fi
if ! id honcho-proxy >/dev/null 2>&1; then
  useradd --system --no-create-home --shell /usr/sbin/nologin honcho-proxy
fi
install -d -m 0750 -o honcho -g honcho "$opt"
install -d -m 0700 "$state"
install -d -m 0755 "$proxy_lib_dir"

as_honcho() { runuser -u honcho -- env HOME="$home" "$@"; }
# opt_git: git in the checkout, as root. The checkout belongs to honcho after the
# first run, and git (2.35.2+) refuses a repository owned by another user
# ("detected dubious ownership") unless it is named safe; command-line scope
# counts, so nothing is written to root's git config.
opt_git() { git -c safe.directory="$opt" -C "$opt" "$@"; }
honcho_run() { as_honcho "$uv" --directory "$opt" run --frozen --no-dev --env-file "$etc/honcho.env" "$@"; }
proxy_expected=true
healthy() {
  local _
  for (( _ = 0; _ < health_tries; _++ )); do
    if { [[ $proxy_expected != true ]] || curl -fsS --max-time 2 "$proxy_url/healthz" >/dev/null; } &&
       curl -fsS --max-time 2 http://127.0.0.1:8000/health >/dev/null &&
       curl -fsS --max-time 2 http://127.0.0.1:3000/health >/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# --- an installed CT: set aside what this run changes ---------------------------
existing=false prev_commit='' dump_taken=false had_proxy=false
previous_etc_mode='' previous_etc_owner=''
backup=$state/rollback
if [[ -f $unit_dir/honcho-api.service && -d $opt/.git ]]; then
  existing=true
  [[ ! -f $unit_dir/honcho-proxy.service ]] || had_proxy=true
  previous_etc_mode=$(stat -c %a "$etc")
  previous_etc_owner=$(stat -c %u:%g "$etc")
  prev_commit=$(opt_git rev-parse HEAD)
  if [[ -e $backup ]]; then
    die "Previous rollback data remains in $backup: an earlier run's rollback did not complete.
It holds what that run set aside: honcho.env, the budget and settings records, the keys, the units, Bun and, as honcho.dump, the
database from before that run. Check Honcho (systemctl status honcho-proxy honcho-api honcho-deriver honcho-mcp).
If it is healthy, or after restoring from those copies (see 'When a rollback does not complete' in
targets/honcho/README.md), remove the directory with: rm -r -- $backup
Then run the reconfigure again. Nothing was changed by this run."
  fi
  install -d -m 0700 "$backup"
  for file in "$etc/honcho.env" "$etc/budgets.env" "$etc/settings.env" "$etc/proxy.settings" \
              "$etc/router-api-key" "$etc/backend-keys" "$etc/jwt-secret" "$etc/api-key" "$etc/client-api-key" \
              "$proxy_lib_dir/honcho-proxy.py" "$proxy_lib_dir/direct_dispatch.py" "$bun" \
              "$unit_dir/honcho-proxy.service" "$unit_dir/honcho-api.service" \
              "$unit_dir/honcho-deriver.service" "$unit_dir/honcho-mcp.service"; do
    if [[ -f $file ]]; then cp -a -- "$file" "$backup/$(basename "$file")"; fi
  done
fi

# rollback: the previous commit, database, configuration and units, started
# again. The set-aside copies stay when they cannot all be put back.
rollback() {
  local ok=true name
  trap - EXIT
  note 'Honcho setup failed; restoring the previous installation.'
  systemctl stop "${units[@]/%/.service}" >/dev/null 2>&1 || true
  for name in honcho.env budgets.env settings.env proxy.settings router-api-key backend-keys jwt-secret api-key client-api-key; do
    if [[ -f $backup/$name ]]; then cp -a -- "$backup/$name" "$etc/$name"
    else rm -f -- "$etc/$name"; fi
  done
  for name in "${units[@]}"; do
    if [[ -f $backup/$name.service ]]; then cp -a -- "$backup/$name.service" "$unit_dir/$name.service"
    else rm -f -- "$unit_dir/$name.service"; fi
  done
  for name in honcho-proxy.py direct_dispatch.py; do
    if [[ -f $backup/$name ]]; then cp -a -- "$backup/$name" "$proxy_lib_dir/$name"
    else rm -f -- "$proxy_lib_dir/$name"; fi
  done
  install -d -m "$previous_etc_mode" -o "${previous_etc_owner%%:*}" \
    -g "${previous_etc_owner#*:}" "$etc" || ok=false
  if [[ -f $backup/bun ]]; then cp -a -- "$backup/bun" "$bun"; fi
  if [[ $(opt_git rev-parse HEAD 2>/dev/null) != "$prev_commit" ]]; then
    { opt_git checkout --detach "$prev_commit" && chown -R honcho:honcho "$opt" &&
      as_honcho "$uv" --directory "$opt" sync --frozen --no-dev --python 3.13 &&
      as_honcho "$bun" --cwd "$opt/mcp" install --frozen-lockfile; } || ok=false
  fi
  if $dump_taken; then
    { runuser -u postgres -- dropdb --if-exists honcho &&
      runuser -u postgres -- createdb -O honcho honcho &&
      runuser -u postgres -- pg_restore --exit-on-error -d honcho < "$backup/honcho.dump"; } || ok=false
  fi
  systemctl daemon-reload || ok=false
  if $had_proxy; then
    systemctl restart "${units[@]/%/.service}" || ok=false
  else
    systemctl restart honcho-api.service honcho-deriver.service honcho-mcp.service || ok=false
  fi
  proxy_expected=$had_proxy
  if $ok && healthy; then
    rm -rf -- "$backup"
    note "The previous Honcho (${prev_commit:0:12}) is running again."
  else
    note "Honcho did not come back cleanly; the set-aside copies are in $backup. Inspect journalctl -u honcho-proxy -u honcho-api -u honcho-deriver -u honcho-mcp."
  fi
}
on_exit() {
  local rc=$?
  if (( rc != 0 )) && $existing; then rollback; fi
  exit "$rc"
}
trap on_exit EXIT

if [[ ! -d $opt/.git ]]; then
  git clone https://github.com/plastic-labs/honcho.git "$opt"
fi
opt_git fetch --tags origin
target=$ref
if [[ $ref == main ]]; then target=origin/main; fi
new_commit=$(opt_git rev-parse --verify "${target}^{commit}")
if $existing; then
  # Even the same commit can change vector dimensions during reconfigure.
  note "Reconfiguring Honcho from ${prev_commit:0:12} to ${new_commit:0:12}; the database is dumped first."
  systemctl stop "${units[@]/%/.service}"
  runuser -u postgres -- pg_dump -Fc honcho > "$backup/honcho.dump"
  dump_taken=true
fi
install -d -m 0711 -o root -g root "$etc"
install -m 0644 "$deploy/honcho-proxy.py" "$proxy_lib_dir/honcho-proxy.py"
install -m 0644 "$deploy/direct_dispatch.py" "$proxy_lib_dir/direct_dispatch.py"
install -m 0640 -o root -g honcho-proxy "$deploy/proxy.settings" "$etc/proxy.settings"
install -m 0640 -o root -g honcho-proxy "$deploy/router-api-key" "$etc/router-api-key"
install -m 0640 -o root -g honcho-proxy "$deploy/backend-keys" "$etc/backend-keys"
opt_git checkout --detach "$new_commit"
chown -R honcho:honcho "$opt"

# The services and as_honcho run uv as honcho, so its venv must be readable by
# others. Under this script's umask 077 it would be root-only ("env:
# '/opt/honcho-uv/bin/uv': Permission denied"), and root could still run it, so
# a venv left that way by an earlier run is repaired here too.
if [[ ! -x $uv ]]; then
  (umask 022; python3 -m venv "$uv_dir" && "$uv_dir/bin/pip" install --no-cache-dir uv)
fi
chmod -R go+rX,go-w -- "$uv_dir"
as_honcho "$uv" --directory "$opt" sync --frozen --no-dev --python 3.13

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
for extension in vector pg_trgm btree_gin; do
  runuser -u postgres -- psql -d honcho -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS $extension"
done

# --rotate-keys: a new JWT secret invalidates every key made with the old one.
if [[ $rotate_keys == true ]]; then
  note 'Rotating the JWT secret and both Honcho keys; every client needs the new osr key.'
  rm -f -- "$etc/jwt-secret" "$etc/api-key" "$etc/client-api-key"
fi
if [[ ! -s $etc/jwt-secret ]]; then openssl rand -hex 48 > "$etc/jwt-secret"; fi
{
  printf 'DB_CONNECTION_URI=postgresql+psycopg://honcho:%s@127.0.0.1:5432/honcho\n' "$db_password"
  printf 'AUTH_USE_AUTH=true\nAUTH_JWT_SECRET=%s\n' "$(<"$etc/jwt-secret")"
  printf 'LLM_OPENAI_API_KEY=honcho-local-proxy\n'
  for prefix in DERIVER SUMMARY DREAM_DEDUCTION DREAM_INDUCTION; do
    printf '%s_MODEL_CONFIG__MODEL=%s\n' "$prefix" "$model"
    printf '%s_MODEL_CONFIG__OVERRIDES__BASE_URL=%s/v1\n' "$prefix" "$proxy_url"
    [[ -z $structured_output_mode ]] ||
      printf '%s_MODEL_CONFIG__STRUCTURED_OUTPUT_MODE=%s\n' "$prefix" "$structured_output_mode"
  done
  for level in minimal low medium high max; do
    printf 'DIALECTIC_LEVELS__%s__MODEL_CONFIG__MODEL=%s\n' "$level" "$model"
    printf 'DIALECTIC_LEVELS__%s__MODEL_CONFIG__OVERRIDES__BASE_URL=%s/v1\n' "$level" "$proxy_url"
    [[ -z $structured_output_mode ]] ||
      printf 'DIALECTIC_LEVELS__%s__MODEL_CONFIG__STRUCTURED_OUTPUT_MODE=%s\n' "$level" "$structured_output_mode"
  done
  printf 'EMBEDDING_VECTOR_DIMENSIONS=%s\n' "$embedding_dimensions"
  printf 'EMBEDDING_MODEL_CONFIG__MODEL=%s\n' "$embedding_model"
  printf 'EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL=%s/v1\n' "$proxy_url"
  printf 'EMBEDDING_MODEL_CONFIG__OVERRIDES__API_KEY=honcho-local-proxy\n'
  printf 'EMBEDDING_MODEL_CONFIG__DIMENSIONS_MODE=%s\n' "$embedding_dimensions_mode"
  cat "$deploy/budgets.settings"
} > "$etc/honcho.env"
chown root:honcho "$etc/honcho.env"
chmod 0640 "$etc/honcho.env"
install -m 0600 "$deploy/budgets.record" "$etc/budgets.env"
for key in "${kept_names[@]}"; do
  [[ -z ${!key:-} ]] || printf '%s=%s\n' "$key" "${!key}"
done > "$deploy/settings.record"
install -m 0600 "$deploy/settings.record" "$etc/settings.env"

# Upstream's bootstrap: the first migration creates vector(1536) columns, then
# configure_embeddings.py sets them to the model's size. Later runs migrate
# with the real size, so a migration that touches those columns keeps it.
if [[ $(runuser -u postgres -- psql -d honcho -Atqc "SELECT to_regclass('public.alembic_version') IS NOT NULL") == t ]]; then
  honcho_run alembic upgrade head
else
  as_honcho EMBEDDING_VECTOR_DIMENSIONS=1536 \
    "$uv" --directory "$opt" run --frozen --no-dev --env-file "$etc/honcho.env" alembic upgrade head
fi
honcho_run python scripts/configure_embeddings.py --yes

# api-key is the admin key and stays in this CT. client-api-key is scoped to the
# shared osr workspace; Open WebUI, Hermes and OpenClaw get only that one.
generate_key() { honcho_run python scripts/generate_jwt.py "$@" --print-only; }
if [[ ! -s $etc/api-key ]]; then
  generate_key --admin > "$etc/api-key.new"
  chmod 0600 "$etc/api-key.new"
  mv -f "$etc/api-key.new" "$etc/api-key"
fi
if [[ ! -s $etc/client-api-key ]]; then
  generate_key --workspace osr > "$etc/client-api-key.new"
  chmod 0600 "$etc/client-api-key.new"
  mv -f "$etc/client-api-key.new" "$etc/client-api-key"
fi

# Bun runs the upstream HTTP MCP package. It forwards each client's bearer key
# to the authenticated API; the key is never stored in this unit.
if [[ ! -x $bun || $("$bun" --version 2>/dev/null) != "$bun_version" ]]; then
  if grep -qw avx2 "$cpuinfo"; then
    bun_asset=bun-linux-x64 bun_sha256=$bun_sha256_x64 sha_var=HONCHO_BUN_SHA256
  else
    bun_asset=bun-linux-x64-baseline bun_sha256=$bun_sha256_baseline sha_var=HONCHO_BUN_BASELINE_SHA256
  fi
  [[ -n $bun_sha256 ]] || die "Set $sha_var to the SHA-256 of ${bun_asset}.zip for Bun $bun_version (this CPU needs that build)."
  bun_tmp=$(mktemp -d)
  curl -fsSL -o "$bun_tmp/bun.zip" \
    "https://github.com/oven-sh/bun/releases/download/bun-v${bun_version}/${bun_asset}.zip"
  printf '%s  %s\n' "$bun_sha256" "$bun_tmp/bun.zip" | sha256sum -c --quiet - ||
    die "Bun ${bun_version} (${bun_asset}.zip) does not match its pinned SHA-256."
  python3 -m zipfile -e "$bun_tmp/bun.zip" "$bun_tmp"
  install -d -m 0755 "$bun_dir"
  install -m 0755 "$bun_tmp/$bun_asset/bun" "$bun"
  rm -rf -- "$bun_tmp"
fi
as_honcho "$bun" --cwd "$opt/mcp" install --frozen-lockfile
for name in "${units[@]}"; do
  install -m 0644 "$deploy/$name.service" "$unit_dir/$name.service"
done
systemctl daemon-reload
systemctl enable "${units[@]/%/.service}"
systemctl restart "${units[@]/%/.service}"
healthy || die 'Honcho did not become healthy. Inspect journalctl -u honcho-proxy -u honcho-api -u honcho-deriver -u honcho-mcp.'
trap - EXIT
rm -rf -- "$backup"
printf 'Honcho API and MCP are healthy.\n'
