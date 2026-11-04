#!/usr/bin/env bash
# Local checks only: no Proxmox, network, or root privileges are needed.
set -Eeuo pipefail
exec </dev/null

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$here/../../tests/lib/assert.sh"
provision=$here/provision-lxc.sh
installer=$here/install-target.sh
unit=$here/deepseek-harness.service

describe dsh_syntax
assert_ok "shell syntax" bash -n "$provision" "$installer" "$here/pve-select.sh" "$here/test-install.sh"
assert_ok "pve-select.sh is the shared copy" cmp -s "$here/pve-select.sh" "$here/../hermes/pve-select.sh"

describe dsh_provision_helpers
# shellcheck disable=SC1090
source <(awk '/^# Provision helpers$/{c=1;next} /^# End provision helpers\.$/{c=0} c' "$provision")
assert_eq "a host address becomes its network" 192.0.2.0/24 "$(cidr_network 192.0.2.81/24)"
assert_eq "a /32 stays a host" 192.0.2.81/32 "$(cidr_network 192.0.2.81/32)"
assert_eq "an odd prefix" 10.0.0.0/15 "$(cidr_network 10.1.200.7/15)"
assert_eq "the MCP URL follows the API host" http://192.0.2.85:3000/mcp "$(honcho_mcp_url http://192.0.2.85:8000)"
assert_eq "an HTTPS API keeps its scheme" https://honcho.example:3000/mcp "$(honcho_mcp_url https://honcho.example/)"
assert_fail "an API URL with a path is refused" honcho_mcp_url http://192.0.2.85:8000/v3
record=$'DSH_MODEL=code-model\nDSH_HONCHO_MCP_URL=\nDSH_PORT=3080'
assert_eq "a record value is read" code-model "$(record_value "$record" DSH_MODEL)"
assert_eq "an empty one is empty" "" "$(record_value "$record" DSH_HONCHO_MCP_URL)"
assert_fail "a missing one fails" record_value "$record" DSH_VERSION
fw=$(mktemp)
printf '[OPTIONS]\nenable: 1\n\n[RULES]\nIN ACCEPT -source 192.0.2.0/24 -p tcp -dport 8000 -log nolog\n' > "$fw"
updated=$(router_fw_with_dsh "$fw" 192.0.2.81 8000)
assert_contains "the router admits Harness first in [RULES]" \
  "$(printf '[RULES]\nIN ACCEPT -source 192.0.2.81/32 -p tcp -dport 8000 -log nolog # osr-deepseek-harness-router\nIN ACCEPT -source 192.0.2.0/24')" "$updated"
printf '%s\n' "$updated" > "$fw"
moved=$(router_fw_with_dsh "$fw" 192.0.2.82 8001)
assert_eq "a new address or port replaces the old rule" 1 "$(grep -c 'osr-deepseek-harness-router' <<< "$moved")"
assert_contains "with the new values" "192.0.2.82/32 -p tcp -dport 8001" "$moved"
printf '[OPTIONS]\nenable: 1\n' > "$fw"
assert_contains "a file without rules gets a [RULES] section" "$(printf '[RULES]\nIN ACCEPT -source 192.0.2.81/32')" "$(router_fw_with_dsh "$fw" 192.0.2.81 8000)"
rm -f "$fw"

describe dsh_provision_dry_run
common=(ROUTER_CT_ID=250 CT_ID=281
  TEMPLATE=local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst
  STORAGE=local-lvm IP_CIDR=192.0.2.81/24 GATEWAY=192.0.2.1)
plan=$(env "${common[@]}" DSH_MODEL=fast DSH_ACCESS_CIDR=192.0.2.0/24 bash "$provision" --dry-run 2>&1)
assert_contains "a dedicated unprivileged CT" '--unprivileged 1' "$plan"
assert_contains "tagged as an OSR target" '--tags ai\;ai-tools\;osr-target\;deepseek-harness' "$plan"
assert_contains "the Web UI firewall source" 'IN ACCEPT -source 192.0.2.0/24 -p tcp -dport 3080' "$plan"
assert_contains "the model reaches the guest" 'DSH_MODEL=fast' "$plan"
assert_contains "and the router address" 'DSH_ROUTER_URL=http://\<router-ct-ip\>:8000' "$plan"
assert_contains "the pinned release by default" 'DSH_VERSION=0.2.1-rc.5' "$plan"
assert_contains "the router key goes to the deploy directory as a private file" 'router-api-key /root/deepseek-harness-deploy/router-api-key --perms 0600' "$plan"
assert_contains "the router firewall admits the CT" 'admit 192.0.2.81 to the router API in /etc/pve/firewall/250.fw' "$plan"
assert_contains "Honcho is off unless asked for" 'DSH_HONCHO_MCP_URL= bash' "$plan"
plan=$(env "${common[@]}" bash "$provision" --dry-run 2>&1)
assert_contains "the default Web UI range is the CT's network, not its host address" '-source 192.0.2.0/24 -p tcp -dport 3080' "$plan"
assert_not_contains "the router firewall can be left alone" 'admit' "$(env "${common[@]}" DSH_ROUTER_FIREWALL=false bash "$provision" --dry-run 2>&1)"
plan=$(env "${common[@]}" DEEPSEEK_HARNESS_MODEL=code-model DEEPSEEK_HARNESS_CONTEXT_WINDOW=65536 bash "$provision" --dry-run 2>&1)
assert_contains "the installer's names are read too" 'DSH_MODEL=code-model DSH_CONTEXT_WINDOW=65536' "$plan"

describe dsh_provision_honcho
plan=$(env "${common[@]}" HONCHO_URL=http://192.0.2.85:8000 HONCHO_CT_ID=285 bash "$provision" --dry-run 2>&1)
assert_contains "the MCP URL is derived from the API URL" 'DSH_HONCHO_MCP_URL=http://192.0.2.85:3000/mcp' "$plan"
assert_contains "the workspace key is read from the Honcho CT" 'read the osr workspace key from Honcho CT 285' "$plan"
assert_contains "and pushed as a private file" 'honcho-api-key /root/deepseek-harness-deploy/honcho-api-key --perms 0600' "$plan"
plan=$(env "${common[@]}" HONCHO_MCP_URL=https://honcho.example/mcp HONCHO_API_KEY_FILE=/dev/null bash "$provision" --dry-run 2>&1)
assert_contains "an external Honcho MCP URL is used as given" 'DSH_HONCHO_MCP_URL=https://honcho.example/mcp' "$plan"
assert_fail "Honcho needs a 32k window" env "${common[@]}" HONCHO_URL=http://192.0.2.85:8000 HONCHO_CT_ID=285 DSH_CONTEXT_WINDOW=16384 bash "$provision" --dry-run
assert_fail "a Honcho URL with a path is refused" env "${common[@]}" HONCHO_URL=http://192.0.2.85:8000/v3 bash "$provision" --dry-run
assert_fail "HONCHO_CT_ID cannot be this CT" env "${common[@]}" HONCHO_URL=http://192.0.2.85:8000 HONCHO_CT_ID=281 bash "$provision" --dry-run
assert_fail "an unreadable key file is refused" env "${common[@]}" HONCHO_URL=http://192.0.2.85:8000 HONCHO_API_KEY_FILE=/nonexistent bash "$provision" --dry-run
assert_contains "the agent takes the workspace key" '/etc/honcho-target/client-api-key' "$(cat "$provision")"
assert_not_contains "never the Honcho admin key" 'cat /etc/honcho-target/api-key' "$(cat "$provision")"

describe dsh_provision_refusals
assert_fail "an invalid firewall source is refused" env "${common[@]}" DSH_ACCESS_CIDR=bad bash "$provision" --dry-run
assert_fail "the router CT cannot be reused" env "${common[@]}" CT_ID=250 bash "$provision" --dry-run
assert_fail "output tokens cannot equal the context" env "${common[@]}" DSH_MAX_TOKENS=32768 bash "$provision" --dry-run
assert_fail "a moving dist-tag other than latest is refused" env "${common[@]}" DSH_VERSION=next bash "$provision" --dry-run
assert_fail "a model id with spaces is refused" env "${common[@]}" "DSH_MODEL=a b" bash "$provision" --dry-run
plan=$(env ROUTER_CT_ID=250 CT_ID=281 bash "$provision" --dry-run --reconfigure 2>&1)
assert_contains "a dry-run reconfigure plans the guest run" 'install-target.sh' "$plan"
assert_not_contains "and never creates a CT" 'pct create' "$plan"

describe dsh_guest_dry_run
guest=$(env DSH_ROUTER_URL=http://192.0.2.50:8000 DSH_BIND_IP=192.0.2.81 bash "$installer" --dry-run 2>&1)
assert_contains "Node.js 24 and the pinned npm release" '@deepseek-ai/dsh@0.2.1-rc.5' "$guest"
assert_contains "a rollback-guarded service" 'deepseek-harness.service on 192.0.2.81:3080; roll back on failure' "$guest"
assert_fail "a router URL with a path is refused" env DSH_ROUTER_URL=http://192.0.2.50:8000/path DSH_BIND_IP=192.0.2.81 bash "$installer" --dry-run

describe dsh_unit
assert_file_contains "the service is unprivileged" 'User=deepseek-harness' "$unit"
assert_file_contains "its filesystem is protected" 'ProtectSystem=strict' "$unit"
assert_file_contains "keys come from the root-only env file" 'EnvironmentFile=/etc/deepseek-harness/service.env' "$unit"
assert_ok "the Web UI listens on the CT address and port" grep -q '^ExecStart=.*/current/node_modules/@deepseek-ai/dsh/lib/bin.js --profile web.*--host .*--port ' "$unit"

describe dsh_configure
if command -v node >/dev/null && node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)'; then
  result=0
  output=$(node --test "$here/configure.test.mjs" 2>&1) || result=$?
  assert_eq "configure.mjs passes its mock-router tests" 0 "$result"
  (( result == 0 )) || printf '%s\n' "$output" | tail -n 30
else
  skip "configure.mjs tests" "needs Node.js 20 or newer"
fi

summary
