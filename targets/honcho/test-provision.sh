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
summary
