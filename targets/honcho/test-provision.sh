#!/usr/bin/env bash
# The Honcho preflight must reject an unusable embedding setup before PVE calls.
set -Eeuo pipefail
exec </dev/null
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$here/../../tests/lib/assert.sh"
provision=$here/provision-lxc.sh
common=(CT_ID=285 ROUTER_CT_ID=280 TEMPLATE=local:vztmpl/debian-13-standard_13.1-1_amd64.tar.zst
  STORAGE=local-lvm IP_CIDR=192.0.2.85/24 GATEWAY=192.0.2.1
  HONCHO_EMBEDDING_MODEL=nomic-embed-text HONCHO_EMBEDDING_DIMENSIONS=768
  HONCHO_EMBEDDING_BASE_URL=http://192.0.2.90:11434/v1)

describe honcho_dry_run
plan=$(env "${common[@]}" bash "$provision" --dry-run)
assert_contains "valid setup gets a plan" "Would create Honcho CT 285" "$plan"
assert_fail "a missing embedding model is refused" env "${common[@]}" HONCHO_EMBEDDING_MODEL= bash "$provision" --dry-run
assert_fail "a missing vector size is refused" env "${common[@]}" HONCHO_EMBEDDING_DIMENSIONS= bash "$provision" --dry-run
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
