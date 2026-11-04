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
assert_contains "budgets.py is pushed with the guest installer" "install-target.sh budgets.py honcho-api.service" "$(cat "$provision")"

describe honcho_guest_files
install=$here/install-target.sh
assert_contains "the guest pins a release too" 'ref=${HONCHO_REF:-v3.5.0}' "$(cat "$install")"
assert_contains "Bun comes from a checksum-pinned release zip" 'sha256sum -c --quiet' "$(cat "$install")"
assert_not_contains "and never from a piped install script" 'bun.sh/install' "$(cat "$install")"
assert_contains "clients get a key scoped to the osr workspace" 'generate_key --workspace osr' "$(cat "$install")"
assert_contains "Open WebUI is given that key" '/etc/honcho-target/client-api-key' "$(cat "$provision")"
assert_not_contains "and never the admin key" 'cat /etc/honcho-target/api-key' "$(cat "$provision")"
for unit in honcho-api honcho-deriver; do
  assert_contains "$unit runs the locked environment" 'uv run --frozen --no-dev' "$(cat "$here/$unit.service")"
done
assert_contains "the MCP unit runs the pinned Bun" 'ExecStart=/opt/honcho-bun/bun run http' "$(cat "$here/honcho-mcp.service")"
for agent in hermes openclaw; do
  assert_not_contains "$agent never takes the Honcho admin key" '/etc/honcho-target/api-key' "$(cat "$here/../$agent/provision-lxc.sh")"
done
summary
