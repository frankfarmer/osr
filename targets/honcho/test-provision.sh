#!/usr/bin/env bash
# The Honcho preflight must reject an unusable embedding setup before PVE calls.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$here/../../tests/lib/assert.sh"
provision=$here/provision-lxc.sh
common=(CT_ID=285 ROUTER_CT_ID=280 ROUTER_IP=192.0.2.80 TEMPLATE=local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst
  STORAGE=local-lvm IP_CIDR=192.0.2.85/24 GATEWAY=192.0.2.1
  HONCHO_EMBEDDING_MODEL=nomic-embed-text HONCHO_EMBEDDING_DIMENSIONS=768
  HONCHO_EMBEDDING_BASE_URL=http://192.0.2.90:11434/v1)

describe honcho_dry_run
plan=$(env "${common[@]}" bash "$provision" --dry-run)
assert_contains "valid setup gets a plan" "Would create Honcho CT 285" "$plan"
assert_contains "the plan shows the entered router IP" "Router IP: 192.0.2.80" "$plan"
assert_contains "the plan shows the selected embedding endpoint" "via http://192.0.2.90:11434/v1" "$plan"
assert_fail "a missing Honcho CT ID cannot be guessed" env "${common[@]}" CT_ID= bash "$provision" --dry-run
assert_fail "a missing router CT ID cannot be guessed" env "${common[@]}" ROUTER_CT_ID= bash "$provision" --dry-run
assert_fail "a missing Honcho IP cannot be guessed" env "${common[@]}" IP_CIDR= bash "$provision" --dry-run
assert_fail "a missing router IP cannot be guessed" env "${common[@]}" ROUTER_IP= bash "$provision" --dry-run
assert_fail "Honcho cannot reuse the router IP" env "${common[@]}" ROUTER_IP=192.0.2.85 bash "$provision" --dry-run
assert_fail "an agent cannot reuse the Honcho IP" env "${common[@]}" HONCHO_CLIENT_IPS=192.0.2.85 bash "$provision" --dry-run
assert_fail "a missing embedding model is refused" env "${common[@]}" HONCHO_EMBEDDING_MODEL= bash "$provision" --dry-run
assert_fail "a missing vector size is refused" env "${common[@]}" HONCHO_EMBEDDING_DIMENSIONS= bash "$provision" --dry-run
assert_fail "an unattended install must choose an embedding endpoint" env "${common[@]}" env -u HONCHO_EMBEDDING_BASE_URL bash "$provision" --dry-run
assert_fail "a non-v1 embedding URL is refused" env "${common[@]}" HONCHO_EMBEDDING_BASE_URL=http://192.0.2.90:11434/api bash "$provision" --dry-run
assert_fail "Debian 12 lacks the packaged pgvector target" env "${common[@]}" TEMPLATE=local:vztmpl/debian-12-standard_12.0-1_amd64.tar.zst bash "$provision" --dry-run
assert_contains "a release is pinned by default" "with v3.5.0" "$plan"
assert_ok "a blank embedding URL uses the router" env "${common[@]}" HONCHO_EMBEDDING_BASE_URL= bash "$provision" --dry-run
assert_ok "an HTTPS embedding URL needs no port" env "${common[@]}" HONCHO_EMBEDDING_BASE_URL=https://embed.example.net/v1 bash "$provision" --dry-run
assert_fail "a moving branch other than main is refused" env "${common[@]}" HONCHO_REF=develop bash "$provision" --dry-run
assert_fail "--rotate-keys needs an existing CT" env "${common[@]}" bash "$provision" --dry-run --rotate-keys
plan=$(env "${common[@]}" bash "$provision" --dry-run --reconfigure --rotate-keys)
assert_contains "a reconfigure can rotate the keys" "Would replace the JWT secret and both Honcho keys" "$plan"
assert_contains "and admits Honcho in the router's firewall" "Would admit 192.0.2.85 to the router API in /etc/pve/firewall/280.fw" "$plan"
assert_not_contains "unless that is turned off" "Would admit" "$(env "${common[@]}" HONCHO_ROUTER_FIREWALL=false bash "$provision" --dry-run)"
assert_fail "json_object or json_schema only" env "${common[@]}" HONCHO_STRUCTURED_OUTPUT_MODE=xml bash "$provision" --dry-run
assert_fail "another Bun needs a checksum" env "${common[@]}" HONCHO_BUN_VERSION=1.5.0 bash "$provision" --dry-run
assert_ok "and runs with the baseline one alone" env "${common[@]}" HONCHO_BUN_VERSION=1.5.0 HONCHO_BUN_BASELINE_SHA256="$(printf 'a%.0s' {1..64})" bash "$provision" --dry-run
assert_fail "a checksum is 64 hex digits" env "${common[@]}" HONCHO_BUN_SHA256=abc bash "$provision" --dry-run

describe router_fw_with_honcho
# shellcheck disable=SC1090
source <(awk '/^# Router firewall helper$/{c=1;next} /^# End router firewall helper\.$/{c=0} c' "$provision")
fw=$(mktemp)
printf '[OPTIONS]\nenable: 1\n\n[RULES]\nIN ACCEPT -source 192.0.2.0/24 -p tcp -dport 8000 -log nolog\n' > "$fw"
updated=$(router_fw_with_honcho "$fw" 192.0.2.85 8000)
assert_eq "the rule goes first in [RULES], the rest stays" \
  "$(printf '[OPTIONS]\nenable: 1\n\n[RULES]\nIN ACCEPT -source 192.0.2.85/32 -p tcp -dport 8000 -log nolog # osr-honcho-router\nIN ACCEPT -source 192.0.2.0/24 -p tcp -dport 8000 -log nolog')" "$updated"
printf '%s\n' "$updated" > "$fw"
assert_eq "a rerun changes nothing" "$updated" "$(router_fw_with_honcho "$fw" 192.0.2.85 8000)"
moved=$(router_fw_with_honcho "$fw" 192.0.2.86 8001)
assert_eq "a new address or port replaces the old rule" 1 "$(grep -c 'osr-honcho-router' <<< "$moved")"
assert_contains "with the new values" "192.0.2.86/32 -p tcp -dport 8001" "$moved"
printf '[OPTIONS]\nenable: 1\n' > "$fw"
assert_contains "a file without rules gets a [RULES] section" "$(printf '[RULES]\nIN ACCEPT -source 192.0.2.85/32')" "$(router_fw_with_honcho "$fw" 192.0.2.85 8000)"
rm -f "$fw"

describe honcho_rules
# shellcheck disable=SC1090
source <(awk '/^# Honcho firewall helpers$/{c=1;next} /^# End Honcho firewall helpers\.$/{c=0} c' "$provision")
rules=$(honcho_rules 192.0.2.80 192.0.2.81 192.0.2.82)
assert_contains "the router reaches the API" "-source 192.0.2.80/32 -p tcp -dport 8000 -log nolog # osr-honcho-api" "$rules"
assert_contains "and MCP (Open WebUI)" "-source 192.0.2.80/32 -p tcp -dport 3000 -log nolog # osr-honcho-mcp" "$rules"
assert_contains "an agent reaches the API" "-source 192.0.2.81/32 -p tcp -dport 8000 -log nolog # osr-honcho-api" "$rules"
assert_contains "and MCP (DeepSeek Harness uses it), under its own tag" "-source 192.0.2.82/32 -p tcp -dport 3000 -log nolog # osr-honcho-client-mcp" "$rules"
assert_eq "one API and one MCP rule each" 6 "$(grep -c '^IN ACCEPT' <<< "$rules")"
fw=$(mktemp)
printf '[RULES]\n%s\nIN ACCEPT -source 192.0.2.0/24 -p tcp -dport 22\n' "$rules" > "$fw"
assert_eq "a reconfigure reads back the agents, not the router" "192.0.2.81 192.0.2.82" "$(honcho_fw_clients "$fw")"
printf '[RULES]\n%s\n' "$(honcho_rules 192.0.2.80)" > "$fw"
assert_eq "no agents: an empty list" "" "$(honcho_fw_clients "$fw")"
# A Honcho CT from before agents had MCP rules reads back the same.
printf '[RULES]\nIN ACCEPT -source 192.0.2.80/32 -p tcp -dport 8000 -log nolog # osr-honcho-api\nIN ACCEPT -source 192.0.2.80/32 -p tcp -dport 3000 -log nolog # osr-honcho-mcp\nIN ACCEPT -source 192.0.2.81/32 -p tcp -dport 8000 -log nolog # osr-honcho-api\n' > "$fw"
assert_eq "older rule sets read back too" "192.0.2.81" "$(honcho_fw_clients "$fw")"
assert_contains "replacing the rules drops the agents' MCP rules too" 'osr-honcho-(api|mcp|client-mcp)$' "$(cat "$provision")"
rm -f "$fw"

describe rotation_recovery
# shellcheck disable=SC1090
source <(awk '/^# Rotation recovery helper$/{c=1;next} /^# End rotation recovery helper\.$/{c=0} c' "$provision")
stage=$(mktemp -d "${TMPDIR:-/tmp}/honcho-rotation-test.XXXXXX")
# Read by the sourced helpers.
# shellcheck disable=SC2034
CT_ID=285 ROUTER_CT_ID=280 OPENWEBUI_PORT=8080 rotation_files=(jwt-secret api-key client-api-key)
# shellcheck disable=SC2034
rotation_stage=/root/honcho-rotation-test router_stage=/root/honcho-integration-test
# pct: logs each call; FAKE_SAME_SECRET makes cmp report an unchanged secret,
# FAIL_CT makes the Honcho CT unreachable, FAIL_WEBUI fails its restore, and
# FAIL_ROUTER_RM simulates losing router CT access during cleanup.
pct() {
  printf '%s\n' "$*" >> "$stage/calls"
  if [[ $1 == exec && $2 == 285 && $4 == true && ${FAIL_CT:-false} == true ]]; then return 1; fi
  if [[ $1 == exec && $4 == cmp ]]; then [[ ${FAKE_SAME_SECRET:-false} == true ]]; return; fi
  if [[ $1 == exec && $2 == 280 && $4 == python3 && ${FAIL_WEBUI:-false} == true ]]; then return 1; fi
  if [[ $1 == exec && $2 == 280 && $4 == rm && ${FAIL_ROUTER_RM:-false} == true ]]; then return 1; fi
  return 0
}
calls() { cat "$stage/calls"; }
: > "$stage/calls"
assert_ok "a changed secret means the keys were rotated" rotation_applied
assert_contains "compared inside the Honcho CT" "exec 285 -- cmp -s $rotation_stage/jwt-secret /etc/honcho-target/jwt-secret" "$(calls)"
FAKE_SAME_SECRET=true
assert_fail "an unchanged secret means nothing to undo" rotation_applied
unset FAKE_SAME_SECRET
FAIL_CT=true
rc=0; rotation_applied || rc=$?
assert_eq "an unreachable CT cannot prove the keys stayed unchanged" 2 "$rc"
unset FAIL_CT
: > "$stage/calls"
assert_ok "old credentials and the Open WebUI connection can be restored" restore_rotation
for file in jwt-secret api-key client-api-key; do
  assert_contains "$file is put back" "exec 285 -- cp -a -- $rotation_stage/$file /etc/honcho-target/$file" "$(calls)"
done
assert_not_contains "the rest of honcho.env is not rolled back" "/etc/honcho-target/honcho.env" "$(calls | grep -v '^exec 285 -- python3 -c')"
assert_contains "only its JWT secret line is set, inside the CT" 'lines = ["AUTH_JWT_SECRET=" + secret' "$(calls)"
restart=$(calls | grep -n 'systemctl restart' | cut -d: -f1)
restore=$(calls | grep -n 'integrate-webui.py --restore' | cut -d: -f1)
assert_ok "Honcho restarts before Open WebUI gets its old connection back" test "${restart:-999}" -lt "${restore:-0}"
assert_contains "from the saved snapshot" "--restore http://127.0.0.1:8080 $router_stage/admin-token $router_stage/webui-honcho-snapshot.json" "$(calls)"
assert_contains "recovery cleans its CT copy after success" "rm -rf -- $rotation_stage" "$(calls)"
: > "$stage/calls"
FAIL_WEBUI=true
assert_fail "a failed Open WebUI restore is reported" restore_rotation
assert_not_contains "and leaves the CT copy available" "rm -rf -- $rotation_stage" "$(calls)"
unset FAIL_WEBUI
# Read by clean_router_stage.
# shellcheck disable=SC2034
router_stage_created=false rotation_pending=false
: > "$stage/calls"
warning=$(FAIL_ROUTER_RM=true clean_router_stage 2>&1)
assert_eq "a run that stopped before the router stage existed stays silent" "" "$warning"
assert_eq "and touches nothing in the router CT" "" "$(calls)"
# shellcheck disable=SC2034
router_stage_created=true
: > "$stage/calls"
# shellcheck disable=SC2034
rotation_pending=true
clean_router_stage
assert_contains "an unresolved rotation drops the admin token and new key from the router CT" \
  "exec 280 -- rm -f -- $router_stage/admin-token $router_stage/honcho-api-key $router_stage/integrate-webui.py" "$(calls)"
assert_not_contains "but keeps the saved connection" "rm -rf -- $router_stage" "$(calls)"
warning=$(FAIL_ROUTER_RM=true clean_router_stage 2>&1)
assert_contains "a failed credential cleanup warns with the router CT path" "$router_stage" "$warning"
: > "$stage/calls"
# shellcheck disable=SC2034
rotation_pending=false
clean_router_stage
assert_contains "otherwise the whole staging directory goes" "exec 280 -- rm -rf -- $router_stage" "$(calls)"
warning=$(FAIL_ROUTER_RM=true clean_router_stage 2>&1)
assert_contains "a failed whole-directory cleanup warns about the admin token" 'it may still hold an Open WebUI admin token' "$warning"
[[ $stage == "${TMPDIR:-/tmp}"/honcho-rotation-test.* ]] && rm -rf -- "$stage"

describe model_choice_helpers
unset -f pct   # the rotation cases' stand-in; these use the stubs below
# shellcheck disable=SC1090
source <(awk '/^# Model choice helpers$/{c=1;next} /^# End model choice helpers\.$/{c=0} c' "$provision")
stubs=$(mktemp -d)
cat > "$stubs/inventory.json" <<'JSON'
{"models": [
 {"server": "http://192.0.2.90:11434", "name": "qwen3:14b", "tools": true, "context_length": 65536, "params_b": 14.8, "loaded": true, "is_embedding": false},
 {"server": "http://192.0.2.90:11434", "name": "gemma3:12b", "tools": null, "context_length": 131072, "params_b": 12, "is_embedding": false},
 {"server": "http://192.0.2.90:11434", "name": "nomic-embed-text:latest", "tools": null, "context_length": 2048, "is_embedding": true}
]}
JSON
cat > "$stubs/pct" <<'STUB'
#!/usr/bin/env bash
printf 'pct %s\n' "$*" >> "$STUBS/calls"
case "$*" in
  *ROUTER_PORT*) echo 8123 ;;
  *ROUTER_API_KEY*) printf 'sk-router"key\n' ;;
  *'curl -K -'*) cat > "$STUBS/pct-curl-config"; cat "$STUBS/inventory.json" ;;
esac
STUB
cat > "$stubs/curl" <<'STUB'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$STUBS/calls"
case "$*" in
  *routing/inventory*)
    cat > "$STUBS/curl-config"
    [[ ${FAIL_HOST_CURL:-} != true ]] || exit 7
    cat "$STUBS/inventory.json" ;;
  *embeddings*)
    [[ ${FAIL_EMBED:-} != true ]] || exit 22
    while (( $# )); do [[ $1 == -o ]] && out=$2; shift; done
    python3 -c 'import json,sys; json.dump({"data": [{"embedding": [0.0] * int(sys.argv[2])}]}, open(sys.argv[1], "w"))' \
      "$out" "${STUB_DIMS:-640}" ;;
esac
STUB
chmod +x "$stubs/pct" "$stubs/curl"
export STUBS=$stubs
saved_path=$PATH; PATH="$stubs:$PATH"
inventory=$(router_inventory 280 192.0.2.80)
assert_contains "the inventory comes from the router's address" "curl -K - http://192.0.2.80:8123/routing/inventory" "$(cat "$stubs/calls")"
assert_contains "and is returned" '"qwen3:14b"' "$inventory"
assert_contains "the router key goes to curl on stdin, quoted" 'header = "Authorization: Bearer sk-router\"key"' "$(cat "$stubs/curl-config")"
assert_not_contains "never on a command line" "sk-router" "$(grep '^curl' "$stubs/calls")"
: > "$stubs/calls"
inventory=$(FAIL_HOST_CURL=true router_inventory 280 192.0.2.80)
assert_contains "a firewalled router is asked from inside its CT" "pct exec 280 -- curl -K - http://127.0.0.1:8123/routing/inventory" "$(cat "$stubs/calls")"
assert_contains "with the same key on stdin" "sk-router" "$(cat "$stubs/pct-curl-config")"
assert_contains "and its answer is used" '"qwen3:14b"' "$inventory"
lines=($'qwen3:14b\t65536-token context, loaded\thttp://192.0.2.90:11434/v1' $'qwen3:32b\t65536-token context\thttp://192.0.2.91:11434/v1')
assert_eq "Enter takes the suggestion" "qwen3:14b" "$(choose_from Model qwen3:14b valid_model_name "${lines[@]}" <<< '' 2>/dev/null)"
assert_eq "a number takes its line" "qwen3:32b" "$(choose_from Model qwen3:14b valid_model_name "${lines[@]}" <<< '2' 2>/dev/null)"
assert_eq "a name or tier is taken as typed" "large" "$(choose_from Model qwen3:14b valid_model_name "${lines[@]}" <<< 'large' 2>/dev/null)"
out=$(choose_from Model qwen3:14b valid_model_name "${lines[@]}" 2>&1 <<< $'9\nbad name\n1')
assert_contains "the list is shown with descriptions" "2) qwen3:32b  (65536-token context)" "$out"
assert_contains "a number off the list is asked again" "Choose 1-2, or type a name." "$out"
assert_contains "so is an invalid name" "Not a valid choice: bad name" "$out"
assert_eq "until an answer fits" "qwen3:14b" "$(tail -n1 <<< "$out")"
assert_fail "the end of input is no choice" choose_from Model '' valid_model_name <<< ''
assert_eq "without a list a number is the value" 1024 "$(choose_from Size '' valid_dimensions <<< '1024' 2>/dev/null)"
assert_eq "listed_url finds a listed model's host, in any case" "http://192.0.2.91:11434/v1" "$(listed_url QWEN3:32B "${lines[@]}")"
assert_eq "and nothing for an unlisted one" "" "$(listed_url other "${lines[@]}")"
choices=$here/model_choices.py
assert_eq "the vector size is measured with one request when the host is known" \
  $'640\tmeasured at http://192.0.2.90:11434/v1' "$(suggest_dimensions "$choices" nomic-embed-text http://192.0.2.90:11434/v1)"
assert_contains "at the host's /embeddings" "http://192.0.2.90:11434/v1/embeddings" "$(cat "$stubs/calls")"
assert_eq "an unreachable host falls back to the model's known size" \
  $'768\tthe size nomic-embed-text is known to have' "$(FAIL_EMBED=true suggest_dimensions "$choices" nomic-embed-text http://192.0.2.90:11434/v1)"
assert_eq "as does no host" $'1024\tthe size bge-m3 is known to have' "$(suggest_dimensions "$choices" bge-m3)"
assert_eq "an unknown model with no host gets no suggestion" "" "$(suggest_dimensions "$choices" my-embedder)"

describe honcho_interactive_choices
if command -v script >/dev/null; then
  interactive_env=(CT_ID=285 ROUTER_CT_ID=280 ROUTER_IP=192.0.2.80 GATEWAY=192.0.2.1 IP_CIDR=192.0.2.85/24
    TEMPLATE=local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst STORAGE=local-lvm HONCHO_CLIENT_IPS=)
  # Answers: the chat model (Enter: the suggestion), the embedding model
  # (its number), the embedding URL (Enter: inventory), the vector size (Enter).
  out=$(printf '\n1\n\n\n' | env "${interactive_env[@]}" STUBS="$stubs" PATH="$PATH" \
    script -qec "bash $provision --dry-run" /dev/null 2>&1 | tr -d '\r') || true
  assert_contains "the router's inventory is read once its address is known" "Reading the models router CT 280 serves" "$out"
  assert_contains "the usable chat model is listed" "1) qwen3:14b  (65536-token context, 14.8B, loaded, on http://192.0.2.90:11434)" "$out"
  assert_contains "the ones the proxy cannot use are named, with the reason" "gemma3:12b (tool support not reported)" "$out"
  assert_contains "and the embedding models" "1) nomic-embed-text:latest" "$out"
  assert_contains "the vector size is suggested" "Embedding vector dimensions: 640 suggested (measured at http://192.0.2.90:11434/v1)." "$out"
  assert_contains "and the answers reach the plan" "chat model: qwen3:14b; embedding: nomic-embed-text:latest (640 dimensions) via router inventory" "$out"
  # A preset chat model; the embedding model typed, so no listed host to measure.
  out=$(printf 'nomic-embed-text\n\n\n' | env "${interactive_env[@]}" STUBS="$stubs" PATH="$PATH" HONCHO_MODEL=large \
    script -qec "bash $provision --dry-run" /dev/null 2>&1 | tr -d '\r') || true
  assert_not_contains "a preset chat model is not asked for" "Chat model (number" "$out"
  assert_contains "a vector size it cannot measure is the model's known one" "768 suggested (the size nomic-embed-text is known to have)" "$out"
  assert_contains "the preset is kept" "chat model: large;" "$out"
  cp "$stubs/inventory.json" "$stubs/full.json"
  printf '{"models": [{"server": "http://192.0.2.90:11434", "name": "gemma3:12b", "tools": null, "context_length": 131072}]}\n' > "$stubs/inventory.json"
  out=$(printf '\nnomic-embed-text\n\n\n' | env "${interactive_env[@]}" STUBS="$stubs" PATH="$PATH" \
    script -qec "bash $provision --dry-run" /dev/null 2>&1 | tr -d '\r') || true
  assert_contains "with no usable model, the install is said to need one" "No model in the inventory reports tool support" "$out"
  assert_contains "and the fast tier is suggested" "Chat model (number, name or tier) [fast]" "$out"
  assert_contains "the Enter key takes it" "chat model: fast;" "$out"
  printf 'not json\n' > "$stubs/inventory.json"
  out=$(printf '\nnomic-embed-text\n\n\n' | env "${interactive_env[@]}" STUBS="$stubs" PATH="$PATH" \
    script -qec "bash $provision --dry-run" /dev/null 2>&1 | tr -d '\r') || true
  assert_contains "an unreadable inventory is said so" "Could not read the router inventory; enter the model names yourself." "$out"
  assert_contains "and the names are still asked for" "chat model: fast; embedding: nomic-embed-text (768 dimensions)" "$out"
  mv "$stubs/full.json" "$stubs/inventory.json"
else
  printf 'SKIP honcho_interactive_choices (no script command for a terminal)\n'
fi
PATH=$saved_path
rm -rf -- "$stubs"
unset STUBS

describe honcho_budget_passthrough
plan=$(env "${common[@]}" HONCHO_CONTEXT_TOKENS=32768 HONCHO_DREAM_ENABLED= bash "$provision" --dry-run)
assert_contains "set budget variables are passed on" "HONCHO_CONTEXT_TOKENS=32768" "$plan"
assert_contains "an empty one too: it returns the setting to the default" "HONCHO_DREAM_ENABLED=" "$plan"
assert_not_contains "unset ones are not, so the CT keeps its values" "HONCHO_DIALECTIC_MAX_INPUT_TOKENS" "$plan"
assert_fail "a budget with a unit is refused before any Proxmox call" env "${common[@]}" HONCHO_CONTEXT_TOKENS=32k bash "$provision" --dry-run
assert_fail "DREAM_ENABLED is true or false" env "${common[@]}" HONCHO_DREAM_ENABLED=no bash "$provision" --dry-run
provision_names=$(sed -n '/^honcho_budget_names=(/,/)/p' "$provision" | tr -d '()' | sed 's/honcho_budget_names=//' | tr -s ' \n' '\n' | grep . | sort)
helper_names=$(python3 -c 'import importlib.util,sys
spec = importlib.util.spec_from_file_location("b", sys.argv[1]); b = importlib.util.module_from_spec(spec); spec.loader.exec_module(b)
print("\n".join(sorted(b.NAMES)))' "$here/budgets.py" | tr -d '\r')
assert_eq "the provisioner forwards exactly the settings budgets.py knows" "$helper_names" "$provision_names"
plan=$(env "${common[@]}" HONCHO_MODEL=auto HONCHO_STRUCTURED_OUTPUT_MODE= bash "$provision" --dry-run --reconfigure)
assert_contains "a reconfigure without HONCHO_REF keeps the CT's release" "with its recorded release (v3.5.0 if none)" "$plan"
assert_contains "set kept settings are passed on" "HONCHO_MODEL=auto" "$plan"
assert_contains "an empty one too, to clear it" "HONCHO_STRUCTURED_OUTPUT_MODE=" "$plan"
assert_not_contains "unset ones are not" "HONCHO_REF=" "$plan"
plan=$(env "${common[@]}" HONCHO_REF=v3.6.0 bash "$provision" --dry-run --reconfigure)
assert_contains "a given release is used" "with v3.6.0" "$plan"
assert_not_contains "and the guest is never handed a default it did not ask for" "HONCHO_MODEL=fast" "$(env "${common[@]}" bash "$provision" --dry-run --reconfigure)"
assert_contains "budgets.py is pushed with the guest installer" "install-target.sh budgets.py honcho-proxy.py" "$(cat "$provision")"
assert_contains "the local proxy is staged" "honcho-proxy.py direct_dispatch.py honcho-proxy.service" "$(cat "$provision")"
assert_contains "backend keys are staged for the proxy" '"$stage/backend-keys" /root/honcho-deploy/backend-keys' "$(cat "$provision")"
assert_ok "the vendored direct dispatcher matches Hermes" cmp -s "$here/direct_dispatch.py" "$here/../hermes/direct-dispatch.py"

describe honcho_guest_files
install=$here/install-target.sh
assert_contains "the guest pins a release too" 'ref=${HONCHO_REF:-v3.5.0}' "$(cat "$install")"
assert_contains "Bun comes from a checksum-pinned release zip" 'sha256sum -c --quiet' "$(cat "$install")"
assert_not_contains "and never from a piped install script" 'bun.sh/install' "$(cat "$install")"
assert_contains "clients get a key scoped to the osr workspace" 'generate_key --workspace osr' "$(cat "$install")"
assert_contains "Open WebUI is given that key" '/etc/honcho-target/client-api-key' "$(cat "$provision")"
assert_contains "Honcho uses a stable local chat endpoint" '%s_MODEL_CONFIG__OVERRIDES__BASE_URL=%s/v1' "$(cat "$install")"
assert_contains "Honcho uses a stable local embedding endpoint" 'EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL=%s/v1' "$(cat "$install")"
assert_contains "the proxy runs as a dedicated user" 'User=honcho-proxy' "$(cat "$here/honcho-proxy.service")"
assert_not_contains "and never the admin key" 'cat /etc/honcho-target/api-key' "$(cat "$provision")"
for unit in honcho-api honcho-deriver; do
  assert_contains "$unit runs the locked environment" 'uv run --frozen --no-dev' "$(cat "$here/$unit.service")"
done
assert_contains "the MCP unit runs the pinned Bun" 'ExecStart=/opt/honcho-bun/bun run http' "$(cat "$here/honcho-mcp.service")"
for agent in hermes openclaw deepseek-harness; do
  assert_not_contains "$agent never takes the Honcho admin key" '/etc/honcho-target/api-key' "$(cat "$here/../$agent/provision-lxc.sh")"
done
summary
