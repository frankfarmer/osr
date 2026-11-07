#!/usr/bin/env bash
# Launcher only: the real tool is install/manage-model-servers.sh (the installer
# symlinks it to /usr/local/bin/manage-model-servers). Do NOT copy this file into
# the container; use install/update-router.sh or copy the install/ script itself.
set -euo pipefail
OSR_MMS_LAUNCHER=1   # marker: lets a launcher recognise another launcher
self="$(readlink -f -- "${BASH_SOURCE[0]}")"
candidates=("$(dirname -- "$self")/install/manage-model-servers.sh"
            "${CONFIG_REPO_DIR:-/app/config-repo}/install/manage-model-servers.sh")
for target in "${candidates[@]}"; do
  [[ -f "$target" && "$(readlink -f -- "$target")" != "$self" ]] || continue
  if grep -q '^OSR_MMS_LAUNCHER=1' "$target"; then
    echo "ERROR: ${target} is a copy of this launcher, not the real tool." >&2
    echo "       Restore it from install/manage-model-servers.sh in the repo." >&2
    exit 1
  fi
  exec bash "$target" "$@"
done
[[ "$self" == */install/manage-model-servers.sh ]] && {
  echo "ERROR: ${self} is this launcher, not the real tool. Restore it from" >&2
  echo "       install/manage-model-servers.sh in the repo." >&2; exit 1; }
echo "ERROR: install/manage-model-servers.sh not found in any of:" >&2
printf '         %s\n' "${candidates[@]}" >&2
echo "       Run from a full checkout, or copy install/manage-model-servers.sh itself." >&2
exit 1
