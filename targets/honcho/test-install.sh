#!/usr/bin/env bash
# install-target.sh end to end against a temporary tree: a fake router (a local
# HTTP server) and stubbed apt, systemd, PostgreSQL, git, uv and Bun. Nothing is
# downloaded, installed or started, and no root is needed: the script's paths
# are pointed into the tree and `id -u` answers 0.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$here/../../tests/lib/assert.sh"
script=$here/install-target.sh

tmp=$(mktemp -d "${TMPDIR:-/tmp}/honcho-install-test.XXXXXX")
server_pid=''
cleanup() {
  [[ -z $server_pid ]] || kill "$server_pid" 2>/dev/null || true
  [[ $tmp == "${TMPDIR:-/tmp}"/honcho-install-test.* ]] && rm -rf -- "$tmp"
}
trap cleanup EXIT
bin=$tmp/bin fake=$tmp/fake
mkdir -p "$bin" "$fake"
export FAKE_DIR=$fake FAKE_LOG=$tmp/calls.log

# --- router inventory and a distinct /direct model-target path --------------
# Behaviour is read from files in $fake per request, so cases change it freely.
cat > "$tmp/router.py" <<'PY'
import json, os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
state = sys.argv[1]
def get(name, default=""):
    try:
        with open(os.path.join(state, name)) as f:
            return f.read().strip()
    except FileNotFoundError:
        return default
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass
    def send(self, status, body, headers=()):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        for key, value in headers:
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)
    def authorized(self):
        return self.headers.get("Authorization") == "Bearer " + get("router-key")
    def do_GET(self):
        if not self.authorized():
            return self.send(401, {"error": {"message": "bad key"}})
        if self.path == "/v1/models":
            return self.send(200, {"data": [{"id": m} for m in get("models", "auto,fast").split(",")]})
        if self.path == "/routing/inventory":
            server = "http://127.0.0.1:%s/direct" % self.server.server_port
            return self.send(200, {"enabled": True, "servers": [server],
                                   "server_status": {server: {"up": True}},
                                   "models": [
                                       {"server": server, "name": "fast-model", "tools": not bool(get("chat-warning")),
                                        "context_length": 131072, "loaded": True, "is_embedding": False},
                                       {"server": server, "name": "nomic-embed-text", "loaded": True,
                                        "is_embedding": True}]})
        self.send(404, {})
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path == "/routing/explain":
            if not self.authorized():
                return self.send(401, {"error": {"message": "bad key"}})
            server = "http://127.0.0.1:%s/direct" % self.server.server_port
            return self.send(200, {"candidates": [{"server": server, "model": "fast-model"}]})
        if self.path == "/direct/v1/chat/completions":
            if body.get("tools"):
                with open(os.path.join(state, "tool-probe.json"), "w") as f:
                    json.dump(body, f)
                return self.send(200, {"choices": [{"message": {"role": "assistant", "content": "",
                    "tool_calls": [{"id": "call-1", "type": "function",
                                    "function": {"name": "noop", "arguments": "{}"}}]}}]})
            with open(os.path.join(state, "probe.json"), "w") as f:
                json.dump(body, f)
            status = int(get("chat-status", "200"))
            if status != 200:
                return self.send(status, {"error": {"message": "response_format json_schema is not supported"}})
            return self.send(200, {"choices": [{"message": {"role": "assistant", "content": '{"ready": true}'}}]})
        if self.path in ("/direct/v1/embeddings", "/v1/embeddings"):
            with open(os.path.join(state, "embedding-auth"), "w") as f:
                f.write(self.headers.get("Authorization", ""))
            return self.send(200, {"data": [{"embedding": [0.0] * int(get("dims", "768"))}]})
        self.send(404, {})
server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(os.path.join(state, "port"), "w") as f:
    f.write(str(server.server_address[1]))
server.serve_forever()
PY
printf 'sk-router-test-key\n' > "$fake/router-key"
python3 "$tmp/router.py" "$fake" & server_pid=$!
for _ in {1..50}; do [[ -s $fake/port ]] && break; sleep 0.1; done
[[ -s $fake/port ]] || { echo 'the fake router did not start' >&2; exit 1; }
router=http://127.0.0.1:$(<"$fake/port")

# --- stubs ------------------------------------------------------------------------
stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$bin/$1"; chmod +x "$bin/$1"; }
stub id 'case $1 in -u) echo 0 ;; honcho|honcho-proxy) [[ -e $FAKE_DIR/user-$1 ]] ;; esac'
stub useradd 'echo "useradd $*" >> "$FAKE_LOG"; touch "$FAKE_DIR/user-${@: -1}"'
stub chown 'echo "chown $*" >> "$FAKE_LOG"'
stub sleep ':'
# The Windows Git Bash runner cannot chmod directories under its temporary
# mount. The fixture needs file copies and directory creation, not ownership.
stub install 'directory=false; mode=""; args=()
while (( $# )); do
  case $1 in
    -o|-g) shift 2 ;;
    -m) mode=$2; shift 2 ;;
    -d) directory=true; shift ;;
    *) args+=("$1"); shift ;;
  esac
done
if $directory; then mkdir -p -- "${args[@]}"; exit; fi
dest=${args[${#args[@]}-1]}
if (( ${#args[@]} > 2 )); then mkdir -p -- "$dest"; fi
for (( i=0; i<${#args[@]}-1; i++ )); do
  cp -- "${args[i]}" "$dest" || exit
done
[[ -z $mode ]] || chmod "$mode" -- "$dest" 2>/dev/null || true'
stub apt-get 'echo "apt-get $*" >> "$FAKE_LOG"
[[ -z ${FAKE_NO_PGVECTOR:-} || $* != *pgvector* ]] || exit 100'
stub systemctl 'echo "systemctl $*" >> "$FAKE_LOG"
cmd=$1; shift
for unit in "$@"; do
  case $cmd in
    restart) touch "$FAKE_DIR/active-${unit%.service}" ;;
    stop) rm -f "$FAKE_DIR/active-${unit%.service}" ;;
  esac
done; exit 0'
stub runuser 'echo "runuser $2 ${*:4}" >> "$FAKE_LOG"; exec "${@:4}"'
# PostgreSQL: the database's content is one line in $FAKE_DIR/db-data.
stub psql 'echo "psql $*" >> "$FAKE_LOG"
case $* in
  *server_version_num*) echo 170005 ;;
  *pg_roles*) [[ -e $FAKE_DIR/pg-role ]] && echo 1 ;;
  *"CREATE ROLE"*) touch "$FAKE_DIR/pg-role" ;;
  *pg_database*) [[ -e $FAKE_DIR/pg-db ]] && echo 1 ;;
  *alembic_version*) if [[ -e $FAKE_DIR/db-data ]]; then echo t; else echo f; fi ;;
esac; exit 0'
stub createdb 'echo "createdb $*" >> "$FAKE_LOG"; touch "$FAKE_DIR/pg-db"'
stub dropdb 'echo "dropdb $*" >> "$FAKE_LOG"; rm -f "$FAKE_DIR/pg-db" "$FAKE_DIR/db-data"'
stub pg_dump 'echo "pg_dump $*" >> "$FAKE_LOG"; cat "$FAKE_DIR/db-data"'
stub pg_restore 'echo "pg_restore $*" >> "$FAKE_LOG"; cat > "$FAKE_DIR/db-data"'
# git: the checkout is the commit named in .git/FAKE_HEAD; tags map to commits.
# Like real git as root, a call into the honcho-owned checkout must name it
# safe (-c safe.directory=DIR) or it fails with "dubious ownership".
stub git 'echo "git $*" >> "$FAKE_LOG"
dir="" safe=""
while [[ $1 == -c || $1 == -C ]]; do
  if [[ $1 == -C ]]; then dir=$2; elif [[ $2 == safe.directory=* ]]; then safe=${2#safe.directory=}; fi
  shift 2
done
if [[ -n $dir && -e $dir/.git/FAKE_HEAD && $safe != "$dir" ]]; then
  echo "fatal: detected dubious ownership in repository at $dir" >&2; exit 128
fi
case $1 in
  clone) mkdir -p "$3/.git" "$3/mcp" ;;
  fetch) : ;;
  rev-parse)
    if [[ $2 == HEAD ]]; then cat "$dir/.git/FAKE_HEAD"; exit; fi
    ref=${3%^\{commit\}}
    case $ref in
      v3.5.0) printf "a%.0s" {1..40} ;; v3.6.0) printf "b%.0s" {1..40} ;; v3.7.0) printf "d%.0s" {1..40} ;;
      origin/main) printf "c%.0s" {1..40} ;;
      *) [[ $ref =~ ^[0-9a-f]{40}$ ]] || exit 128; printf %s "$ref" ;;
    esac; echo ;;
  checkout) printf "%s\n" "$3" > "$dir/.git/FAKE_HEAD" ;;
esac'
# curl: the health checks (healthy unless the checkout is FAKE_UNHEALTHY_COMMIT)
# and the Bun release download.
stub curl 'echo "curl $*" >> "$FAKE_LOG"
out=""; url=""
while (( $# )); do case $1 in -o) out=$2; shift 2 ;; http*) url=$1; shift ;; *) shift ;; esac; done
case $url in
  http://127.0.0.1:8765/healthz)
    [[ -e $FAKE_DIR/active-honcho-proxy ]] || exit 7 ;;
  http://127.0.0.1:8000/health|http://127.0.0.1:3000/health)
    [[ -e $FAKE_DIR/active-honcho-api && -e $FAKE_DIR/active-honcho-mcp ]] || exit 7
    [[ $(cat "$FAKE_OPT/.git/FAKE_HEAD") != "${FAKE_UNHEALTHY_COMMIT:-none}" ]] || exit 22 ;;
  https://github.com/oven-sh/bun/*) cp "$FAKE_BUN_ZIP" "$out" ;;
  *) exit 6 ;;
esac'

# uv and Bun live where the script expects them, so it does not install them.
make_uv() {
  mkdir -p "$tmp/uv/bin"
  cat > "$tmp/uv/bin/uv" <<'UV'
#!/usr/bin/env bash
[[ $1 == --directory ]] && shift 2
head=$(cat "$FAKE_OPT/.git/FAKE_HEAD")
case $1 in
  sync) echo "uv sync $head" >> "$FAKE_LOG"; exit 0 ;;
  run) shift ;;
esac
env_file=''
while [[ $1 == --* ]]; do [[ $1 == --env-file ]] && { env_file=$2; shift; }; shift; done
case $* in
  'alembic upgrade head')
    echo "alembic dims=${EMBEDDING_VECTOR_DIMENSIONS:-from-env-file} $head" >> "$FAKE_LOG"
    echo "half-migrated $head" > "$FAKE_DIR/db-data"
    [[ $head != "${FAKE_MIGRATE_FAIL_COMMIT:-none}" ]] || exit 1
    echo "migrated $head" > "$FAKE_DIR/db-data" ;;
  'python scripts/configure_embeddings.py --yes') echo 'configure_embeddings' >> "$FAKE_LOG" ;;
  python\ scripts/generate_jwt.py*)
    secret=$(sed -n 's/^AUTH_JWT_SECRET=//p' "$env_file")
    shift 2; echo "generate_jwt $*" >> "$FAKE_LOG"
    echo "jwt-${secret:0:8}-${*// /_}" ;;
  *) echo "unexpected uv run: $*" >&2; exit 3 ;;
esac
UV
  chmod +x "$tmp/uv/bin/uv"
}
make_bun() {
  mkdir -p "$tmp/bun"
  printf '#!/usr/bin/env bash\n[[ $1 == --version ]] && { echo %s; exit; }\necho "bun $*" >> "$FAKE_LOG"\n' "${1:-1.4.4}" > "$tmp/bun/bun"
  chmod +x "$tmp/bun/bun"
}

# fresh: an empty CT. guest VAR=...: one run of the script; its output is $out.
fresh() {
  rm -rf -- "$tmp/ct" "$tmp/uv" "$tmp/bun" "$fake"/active-* "$fake"/pg-* "$fake/db-data" "$fake/user-honcho" "$fake/user-honcho-proxy" "$fake/probe.json" "$fake/tool-probe.json"
  rm -f "$fake/chat-status" "$fake/chat-warning" "$fake/dims"
  mkdir -p "$tmp/ct/deploy" "$tmp/ct/units"
  cp "$here"/honcho-*.service "$here/budgets.py" "$here/honcho-proxy.py" "$here/direct_dispatch.py" "$tmp/ct/deploy/"
  cp "$fake/router-key" "$tmp/ct/deploy/router-api-key"
  : > "$tmp/ct/deploy/backend-keys"
  printf 'flags : fpu sse2 avx avx2\n' > "$tmp/ct/cpuinfo"
  make_uv; make_bun
  : > "$FAKE_LOG"
}
guest() {
  : > "$FAKE_LOG"
  env PATH="$bin:$PATH" FAKE_OPT="$tmp/ct/opt" \
    HONCHO_DEPLOY_DIR="$tmp/ct/deploy" HONCHO_OPT="$tmp/ct/opt" HONCHO_ETC="$tmp/ct/etc" \
    HONCHO_STATE_DIR="$tmp/ct/state" HONCHO_HOME="$tmp/ct/home" HONCHO_UV_DIR="$tmp/uv" \
    HONCHO_BUN_DIR="$tmp/bun" HONCHO_UNIT_DIR="$tmp/ct/units" HONCHO_CPUINFO="$tmp/ct/cpuinfo" \
    HONCHO_PROXY_LIB_DIR="$tmp/ct/lib" \
    HONCHO_HEALTH_TRIES=2 ROUTER_URL="$router" \
    HONCHO_EMBEDDING_MODEL=nomic-embed-text HONCHO_EMBEDDING_DIMENSIONS=768 \
    HONCHO_EMBEDDING_BASE_URL= \
    "$@" bash "$script" 2>&1
}
calls() { cat "$FAKE_LOG"; }
etc=$tmp/ct/etc
file_mode() {
  case $(uname -s) in
    MINGW*|MSYS*) skip "$1" 'Git Bash temporary files do not preserve Unix modes' ;;
    *) assert_file_mode "$1" "$2" "$3" ;;
  esac
}

describe honcho_required_inputs
out=$(env PATH="$bin:$PATH" ROUTER_URL="$router" \
  HONCHO_EMBEDDING_MODEL=nomic-embed-text HONCHO_EMBEDDING_DIMENSIONS=768 \
  NONINTERACTIVE=true env -u HONCHO_EMBEDDING_BASE_URL bash "$script" 2>&1 || true)
assert_contains "an unattended guest must choose its embedding endpoint" \
  'Set HONCHO_EMBEDDING_BASE_URL' "$out"

describe honcho_fresh_install
fresh
out=$(guest) && rc=0 || rc=$?
assert_eq "a fresh install succeeds" 0 "$rc"
assert_contains "and reports both services healthy" "Honcho API and MCP are healthy." "$out"
assert_contains "the release is checked out" "git -c safe.directory=$tmp/ct/opt -C $tmp/ct/opt checkout --detach $(printf 'a%.0s' {1..40})" "$(calls)"
assert_not_contains "every git call into the checkout names it safe (it belongs to honcho)" "git -C $tmp/ct/opt" "$(calls)"
assert_contains "the probe offered a tool" '"name": "noop"' "$(cat "$fake/tool-probe.json")"
assert_contains "and asked for JSON-schema output" '"type": "json_schema"' "$(cat "$fake/probe.json")"
assert_contains "btree_gin is created with the other extensions" "CREATE EXTENSION IF NOT EXISTS btree_gin" "$(calls)"
assert_contains "the first migration makes the default 1536 columns" "alembic dims=1536" "$(calls)"
assert_contains "then the columns get the model's size" "configure_embeddings" "$(calls)"
assert_contains "an admin key is made" "generate_jwt --admin" "$(calls)"
assert_contains "and a key scoped to the osr workspace" "generate_jwt --workspace osr" "$(calls)"
file_mode "the admin key is root-only" 600 "$etc/api-key"
file_mode "so is the client key" 600 "$etc/client-api-key"
file_mode "the router key is limited to the proxy group" 640 "$etc/router-api-key"
file_mode "the backend keys are limited to the proxy group" 640 "$etc/backend-keys"
assert_contains "the env file has the vector size" "EMBEDDING_VECTOR_DIMENSIONS=768" "$(cat "$etc/honcho.env")"
assert_contains "and the local proxy as the model endpoint" "DERIVER_MODEL_CONFIG__OVERRIDES__BASE_URL=http://127.0.0.1:8765/v1" "$(cat "$etc/honcho.env")"
assert_contains "and the local proxy as the embedding endpoint" "EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL=http://127.0.0.1:8765/v1" "$(cat "$etc/honcho.env")"
assert_not_contains "Honcho does not hold the router address" "$router" "$(cat "$etc/honcho.env")"
assert_not_contains "Honcho does not hold the router key" "sk-router-test-key" "$(cat "$etc/honcho.env")"
assert_not_contains "upstream's structured output by default" "STRUCTURED_OUTPUT_MODE" "$(cat "$etc/honcho.env")"
assert_eq "the model target receives no router key" "" "$(cat "$fake/embedding-auth")"
assert_not_contains "nothing is dumped on a first install" "pg_dump" "$(calls)"
assert_ok "the proxy unit is installed" test -f "$tmp/ct/units/honcho-proxy.service"
assert_contains "the proxy pins the resolved model" 'RESOLVED_MODEL=fast-model' "$(<"$etc/proxy.settings")"
assert_fail "and nothing is left set aside" test -e "$tmp/ct/state/rollback"
assert_eq "a first install sizes its budgets for 65536 tokens" "HONCHO_CONTEXT_TOKENS=65536" "$(<"$etc/budgets.env")"
assert_contains "and says so" "Honcho budgets for a 65536-token context" "$out"
assert_contains "the proxy asks for that much context" "HONCHO_CONTEXT_TOKENS=65536" "$(<"$etc/proxy.settings")"
admin_key=$(<"$etc/api-key") client_key=$(<"$etc/client-api-key")

describe honcho_rerun
out=$(guest) && rc=0 || rc=$?
assert_eq "an unchanged rerun succeeds" 0 "$rc"
assert_not_contains "it migrates with the real vector size" "alembic dims=1536" "$(calls)"
assert_contains "taken from the env file" "alembic dims=from-env-file" "$(calls)"
assert_contains "even the same commit gets a rollback dump" "pg_dump -Fc honcho" "$(calls)"
assert_eq "the admin key is kept" "$admin_key" "$(<"$etc/api-key")"
assert_eq "and the client key" "$client_key" "$(<"$etc/client-api-key")"
assert_eq "and the first install's context" "HONCHO_CONTEXT_TOKENS=65536" "$(<"$etc/budgets.env")"
out=$(guest HONCHO_EMBEDDING_BASE_URL="http://localhost:$(<"$fake/port")/v1") && rc=0 || rc=$?
assert_eq "a separate embedding endpoint works" 0 "$rc"
assert_eq "and gets a placeholder key, not the router's" "Bearer no-key" "$(cat "$fake/embedding-auth")"

describe honcho_same_commit_rollback
before_env=$(<"$etc/honcho.env") before_db=$(<"$fake/db-data")
before_proxy=$(<"$etc/proxy.settings")
printf '# prior proxy revision\n' >> "$tmp/ct/lib/honcho-proxy.py"
before_proxy_code=$(<"$tmp/ct/lib/honcho-proxy.py")
printf '1024\n' > "$fake/dims"
out=$(guest HONCHO_EMBEDDING_DIMENSIONS=1024 FAKE_MIGRATE_FAIL_COMMIT="$(printf 'a%.0s' {1..40})") && rc=0 || rc=$?
assert_ne "a failed same-commit migration fails the run" 0 "$rc"
assert_contains "its database is restored from the dump" "pg_restore --exit-on-error -d honcho" "$(calls)"
assert_eq "including the prior data" "$before_db" "$(<"$fake/db-data")"
assert_eq "and its embedding configuration" "$before_env" "$(<"$etc/honcho.env")"
assert_eq "and its prior proxy settings" "$before_proxy" "$(<"$etc/proxy.settings")"
assert_eq "and its prior proxy implementation" "$before_proxy_code" "$(<"$tmp/ct/lib/honcho-proxy.py")"
rm -f "$fake/dims"

describe honcho_upgrade
out=$(guest HONCHO_REF=v3.6.0) && rc=0 || rc=$?
assert_eq "an upgrade succeeds" 0 "$rc"
assert_contains "it says what it does" "the database is dumped first" "$out"
log=$(calls)
stop_line=$(grep -n 'systemctl stop' <<< "$log" | head -n1 | cut -d: -f1)
dump_line=$(grep -n 'pg_dump' <<< "$log" | head -n1 | cut -d: -f1)
assert_ok "the services stop before the dump" test "${stop_line:-999}" -lt "${dump_line:-0}"
assert_eq "the database is migrated" "migrated $(printf 'b%.0s' {1..40})" "$(cat "$fake/db-data")"
assert_fail "and the dump is deleted after success" test -e "$tmp/ct/state/rollback"

describe honcho_upgrade_rollback
before_env=$(<"$etc/honcho.env")
out=$(guest HONCHO_REF=v3.7.0 FAKE_UNHEALTHY_COMMIT="$(printf 'd%.0s' {1..40})" HONCHO_MODEL=auto) && rc=0 || rc=$?
assert_ne "an upgrade that does not come up fails" 0 "$rc"
assert_contains "and puts the previous release back" "The previous Honcho (bbbbbbbbbbbb) is running again." "$out"
assert_eq "at its commit" "$(printf 'b%.0s' {1..40})" "$(cat "$tmp/ct/opt/.git/FAKE_HEAD")"
assert_contains "with its database restored from the dump" "pg_restore --exit-on-error -d honcho" "$(calls)"
assert_eq "as it was" "migrated $(printf 'b%.0s' {1..40})" "$(cat "$fake/db-data")"
assert_eq "and its env file" "$before_env" "$(<"$etc/honcho.env")"
assert_ok "running again" test -e "$fake/active-honcho-api"
out=$(guest HONCHO_REF=v3.7.0 FAKE_MIGRATE_FAIL_COMMIT="$(printf 'd%.0s' {1..40})") && rc=0 || rc=$?
assert_ne "a failed migration fails the run" 0 "$rc"
assert_eq "and the half-migrated database is replaced by the dump" "migrated $(printf 'b%.0s' {1..40})" "$(cat "$fake/db-data")"
assert_fail "nothing set aside remains after a clean rollback" test -e "$tmp/ct/state/rollback"

describe honcho_rotate_keys
secret=$(<"$etc/jwt-secret")
out=$(guest HONCHO_REF=v3.6.0 HONCHO_ROTATE_KEYS=true FAKE_UNHEALTHY_COMMIT="$(printf 'b%.0s' {1..40})") && rc=0 || rc=$?
assert_ne "a rotation whose restart fails is undone" 0 "$rc"
assert_eq "the old secret is back" "$secret" "$(<"$etc/jwt-secret")"
assert_eq "and the old client key" "$client_key" "$(<"$etc/client-api-key")"
# That commit is unhealthy before the rotation too, so the rollback cannot
# bring Honcho back: it keeps its copies, and the next run waits for them.
assert_contains "a rollback that cannot come back keeps its copies" "the set-aside copies are in $tmp/ct/state/rollback" "$out"
assert_ok "with the dump" test -s "$tmp/ct/state/rollback/honcho.dump"
out=$(guest HONCHO_REF=v3.6.0 HONCHO_ROTATE_KEYS=true) && rc=0 || rc=$?
assert_ne "the next run refuses while they remain" 0 "$rc"
assert_contains "and names them" "Previous rollback data remains in $tmp/ct/state/rollback" "$out"
assert_contains "and how to continue" "rm -r -- $tmp/ct/state/rollback" "$out"
assert_contains "pointing at the README" "When a rollback does not complete" "$out"
assert_not_contains "before stopping or dumping anything" "pg_dump" "$(calls)"
assert_eq "the secret is untouched" "$secret" "$(<"$etc/jwt-secret")"
rm -rf -- "$tmp/ct/state/rollback"
out=$(guest HONCHO_REF=v3.6.0 HONCHO_ROTATE_KEYS=true) && rc=0 || rc=$?
assert_eq "a rotation succeeds" 0 "$rc"
assert_ne "with a new JWT secret" "$secret" "$(<"$etc/jwt-secret")"
assert_ne "a new admin key" "$admin_key" "$(<"$etc/api-key")"
assert_ne "and a new client key" "$client_key" "$(<"$etc/client-api-key")"
assert_contains "made with the new secret" "jwt-$(head -c 8 "$etc/jwt-secret")" "$(<"$etc/client-api-key")"
assert_contains "env file uses the new secret" "AUTH_JWT_SECRET=$(<"$etc/jwt-secret")" "$(<"$etc/honcho.env")"

describe honcho_budgets
out=$(guest HONCHO_CONTEXT_TOKENS=32768) && rc=0 || rc=$?
assert_eq "a 32k context window installs" 0 "$rc"
assert_contains "and says which budgets it set" "Honcho budgets for a 32768-token context" "$out"
assert_contains "the dialectic input fits the window" "DIALECTIC_MAX_INPUT_TOKENS=24576" "$(<"$etc/honcho.env")"
assert_contains "dreams get a smaller output cap" "DREAM_DEDUCTION_MODEL_CONFIG__MAX_OUTPUT_TOKENS=4096" "$(<"$etc/honcho.env")"
assert_eq "the choice is recorded for later runs" "HONCHO_CONTEXT_TOKENS=32768" "$(<"$etc/budgets.env")"
file_mode "root-only" 600 "$etc/budgets.env"
out=$(guest) && rc=0 || rc=$?
assert_eq "a rerun without the variable succeeds" 0 "$rc"
assert_contains "and keeps the budgets" "DIALECTIC_MAX_INPUT_TOKENS=24576" "$(<"$etc/honcho.env")"
out=$(guest HONCHO_DIALECTIC_MAX_INPUT_TOKENS=20000 HONCHO_DREAM_ENABLED=false) && rc=0 || rc=$?
assert_eq "an override succeeds" 0 "$rc"
assert_contains "and wins over the derived value" "DIALECTIC_MAX_INPUT_TOKENS=20000" "$(<"$etc/honcho.env")"
assert_contains "dreams can be turned off" "DREAM_ENABLED=false" "$(<"$etc/honcho.env")"
before_env=$(<"$etc/honcho.env") before_record=$(<"$etc/budgets.env")
out=$(guest HONCHO_CONTEXT_TOKENS=4096) && rc=0 || rc=$?
assert_ne "a window too small for a request is refused" 0 "$rc"
assert_contains "naming the range" "HONCHO_CONTEXT_TOKENS must be a whole number from 8192" "$out"
assert_not_contains "before anything is stopped" "systemctl stop" "$(calls)"
assert_eq "the env file is untouched" "$before_env" "$(<"$etc/honcho.env")"
out=$(guest HONCHO_CONTEXT_TOKENS=65536 FAKE_UNHEALTHY_COMMIT="$(<"$tmp/ct/opt/.git/FAKE_HEAD")") && rc=0 || rc=$?
assert_ne "a run that fails after changing the budgets is rolled back" 0 "$rc"
assert_eq "with the previous budget record" "$before_record" "$(<"$etc/budgets.env")"
assert_eq "and env file" "$before_env" "$(<"$etc/honcho.env")"
rm -rf -- "$tmp/ct/state/rollback"
out=$(guest HONCHO_CONTEXT_TOKENS= HONCHO_DIALECTIC_MAX_INPUT_TOKENS= HONCHO_DREAM_ENABLED=) && rc=0 || rc=$?
assert_eq "empty values return to Honcho's defaults" 0 "$rc"
assert_not_contains "no budget settings remain" "DIALECTIC_MAX_INPUT_TOKENS" "$(<"$etc/honcho.env")"
assert_eq "and the record is empty" "" "$(<"$etc/budgets.env")"
assert_contains "the run says so" "Honcho budgets: Honcho's defaults." "$out"
out=$(guest) && rc=0 || rc=$?
assert_eq "a later run of an installed Honcho" 0 "$rc"
assert_eq "keeps Honcho's defaults (the 65536 default is for a first install only)" "" "$(<"$etc/budgets.env")"

describe honcho_kept_settings
head_now() { cat "$tmp/ct/opt/.git/FAKE_HEAD"; }
out=$(guest HONCHO_REF=v3.6.0 HONCHO_MODEL=auto HONCHO_STRUCTURED_OUTPUT_MODE=json_object) && rc=0 || rc=$?
assert_eq "a run that sets the release, model and output mode succeeds" 0 "$rc"
assert_eq "it records them" "$(printf 'HONCHO_REF=v3.6.0\nHONCHO_MODEL=auto\nHONCHO_STRUCTURED_OUTPUT_MODE=json_object')" "$(<"$etc/settings.env")"
file_mode "root-only" 600 "$etc/settings.env"
out=$(guest) && rc=0 || rc=$?
assert_eq "a plain rerun succeeds" 0 "$rc"
assert_eq "and stays on the recorded release instead of the default" "$(printf 'b%.0s' {1..40})" "$(head_now)"
assert_contains "with the recorded model" "DERIVER_MODEL_CONFIG__MODEL=auto" "$(<"$etc/honcho.env")"
assert_contains "and output mode" "DERIVER_MODEL_CONFIG__STRUCTURED_OUTPUT_MODE=json_object" "$(<"$etc/honcho.env")"
assert_contains "the probe used the recorded mode" '"type": "json_object"' "$(cat "$fake/probe.json")"
assert_contains "and says what it kept" "Kept from the last run: HONCHO_REF=v3.6.0 HONCHO_MODEL=auto" "$out"
out=$(guest HONCHO_STRUCTURED_OUTPUT_MODE= HONCHO_MODEL=) && rc=0 || rc=$?
assert_eq "empty values succeed" 0 "$rc"
assert_not_contains "and return the output mode to the default" "STRUCTURED_OUTPUT_MODE" "$(<"$etc/honcho.env")"
assert_contains "and the model" "DERIVER_MODEL_CONFIG__MODEL=fast" "$(<"$etc/honcho.env")"
assert_eq "only the release stays recorded" "HONCHO_REF=v3.6.0" "$(<"$etc/settings.env")"
before=$(<"$etc/settings.env")
out=$(guest HONCHO_REF=v3.7.0 FAKE_MIGRATE_FAIL_COMMIT="$(printf 'd%.0s' {1..40})") && rc=0 || rc=$?
assert_ne "a failed upgrade" 0 "$rc"
assert_eq "keeps the previous record" "$before" "$(<"$etc/settings.env")"
printf 'HONCHO_REF=v3.6.0\nPATH=/nowhere\nHONCHO_ROTATE_KEYS=true\n' > "$etc/settings.env"
out=$(guest) && rc=0 || rc=$?
assert_eq "unknown names in the record are ignored" 0 "$rc"
assert_not_contains "it does not rotate the keys" "Rotating the JWT secret" "$out"

describe honcho_model_probe
fresh
printf '400\n' > "$fake/chat-status"
out=$(guest) && rc=0 || rc=$?
assert_ne "a model without JSON-schema output stops the install" 0 "$rc"
assert_contains "with the fallback named" "HONCHO_STRUCTURED_OUTPUT_MODE=json_object" "$out"
assert_not_contains "before anything is created" "createdb" "$(calls)"
out=$(guest HONCHO_STRUCTURED_OUTPUT_MODE=json_object) && rc=0 || rc=$?
assert_ne "json_object mode is probed too" 0 "$rc"
assert_contains "with JSON mode" '"type": "json_object"' "$(cat "$fake/probe.json")"
rm -f "$fake/chat-status"
out=$(guest HONCHO_STRUCTURED_OUTPUT_MODE=json_object) && rc=0 || rc=$?
assert_eq "json_object mode installs" 0 "$rc"
assert_eq "and is set for all nine model configs" 9 "$(grep -c 'STRUCTURED_OUTPUT_MODE=json_object' "$etc/honcho.env")"
printf 'no-tool-model\n' > "$fake/chat-warning"
out=$(guest) && rc=0 || rc=$?
assert_ne "a router without a tool-capable model stops the run" 0 "$rc"
assert_contains "and says why" "no reachable model that reports tool support" "$out"
assert_ok "an existing install is left running" test -e "$fake/active-honcho-api"
out=$(guest HONCHO_SKIP_CHAT_PROBE=true) && rc=0 || rc=$?
assert_ne "skipping the active probe still checks inventory capabilities" 0 "$rc"
rm -f "$fake/chat-warning"
printf '400\n' > "$fake/chat-status"
out=$(guest HONCHO_SKIP_CHAT_PROBE=true) && rc=0 || rc=$?
assert_eq "the active chat probe can be skipped" 0 "$rc"
rm -f "$fake/chat-status"
printf '1024\n' > "$fake/dims"
out=$(guest) && rc=0 || rc=$?
assert_ne "a wrong vector size stops the run" 0 "$rc"
assert_contains "naming both sizes" "embedding returned 1024 values; configured 768" "$out"
rm -f "$fake/dims"
out=$(guest HONCHO_MODEL=large) && rc=0 || rc=$?
assert_ne "a model the router does not list is refused" 0 "$rc"

describe honcho_bun
python3 - "$tmp/bun.zip" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("bun-linux-x64/bun", '#!/usr/bin/env bash\n[[ $1 == --version ]] && { echo 9.9.9; exit; }\necho "bun $*" >> "$FAKE_LOG"\n')
PY
zip_sha=$(sha256sum "$tmp/bun.zip" | cut -d' ' -f1)
export FAKE_BUN_ZIP=$tmp/bun.zip
out=$(guest HONCHO_BUN_VERSION=9.9.9 HONCHO_BUN_SHA256="$(printf '0%.0s' {1..64})") && rc=0 || rc=$?
assert_ne "a Bun zip that does not match its checksum is refused" 0 "$rc"
assert_contains "and says so" "does not match its pinned SHA-256" "$out"
assert_eq "the previous Bun is put back" 1.4.4 "$("$tmp/bun/bun" --version)"
out=$(guest HONCHO_BUN_VERSION=9.9.9 HONCHO_BUN_SHA256="$zip_sha") && rc=0 || rc=$?
assert_eq "a matching zip is installed" 0 "$rc"
assert_contains "from the release URL of that version" "bun-v9.9.9/bun-linux-x64.zip" "$(calls)"
assert_eq "as the Bun the MCP unit runs" 9.9.9 "$("$tmp/bun/bun" --version)"
printf 'flags : fpu sse2\n' > "$tmp/ct/cpuinfo"
out=$(guest HONCHO_BUN_VERSION=9.9.8 HONCHO_BUN_SHA256="$zip_sha") && rc=0 || rc=$?
assert_ne "a CPU without AVX2 needs the baseline checksum" 0 "$rc"
assert_contains "and is told which one" "Set HONCHO_BUN_BASELINE_SHA256" "$out"
assert_contains "a run without Bun settings keeps the recorded pin" "HONCHO_BUN_VERSION=9.9.9" "$(<"$etc/settings.env")"
out=$(guest HONCHO_BUN_VERSION= HONCHO_BUN_SHA256=) && rc=0 || rc=$?
assert_contains "the default Bun takes the baseline build here" "bun-v1.4.4/bun-linux-x64-baseline.zip" "$(calls)"
assert_ne "and is held to its built-in checksum (the fake zip is not Bun 1.4.4)" 0 "$rc"
assert_contains "which it reports" "does not match its pinned SHA-256" "$out"

summary
