#!/usr/bin/env bash
# Vendor every shared/<mod>/ module's canonical script into the copies it lists.
#
# Historically this synced the driver alone; it now vendors EVERY shared/<mod>/ module — the
# driver, the flow guard, and any later one (e.g. the escalation policy). Kept at this path so
# every doc and gate message that already names `scripts/sync-driver.sh` stays correct.
#
# A Codex plugin is installed as a self-contained directory and cannot depend on another plugin,
# so each carries its own copy of shared code. This script writes those copies from each module's
# single source of truth; scripts/check.sh (check 11) fails the gate if any copy drifts.
#
# A module is a directory shared/<mod>/ holding EXACTLY ONE *.sh directly (its canonical — tests/
# and examples/ are subdirs and do not count) plus a targets.txt listing the vendored copy paths.
# Workflow: edit shared/<mod>/<canonical>.sh, run this, commit the canonical AND the copies.
set -euo pipefail
cd "$(dirname "$0")/.."

total=0
for moddir in shared/*/; do
  [ -d "$moddir" ] || continue
  mod=${moddir%/}
  targets="$mod/targets.txt"
  [ -f "$targets" ] || { echo "sync: $mod has no targets.txt" >&2; exit 1; }
  # canonical = the lone *.sh directly in the module dir. The glob's literal-on-no-match is
  # filtered by the [ -f ] guard, so a module with no direct *.sh yields ncanon=0.
  canonical=""; ncanon=0
  for f in "$mod"/*.sh; do
    [ -f "$f" ] || continue
    ncanon=$((ncanon + 1)); canonical=$f
  done
  [ "$ncanon" -eq 1 ] \
    || { echo "sync: $mod must hold exactly one *.sh canonical (found $ncanon)" >&2; exit 1; }
  n=0
  while IFS= read -r t || [ -n "$t" ]; do
    case "$t" in ''|\#*) continue ;; esac
    mkdir -p "$(dirname "$t")"
    cp "$canonical" "$t"
    echo "synced $canonical -> $t"
    n=$((n + 1))
  done < "$targets"
  [ "$n" -gt 0 ] || { echo "sync: $mod target list is empty — nothing to sync" >&2; exit 1; }
  total=$((total + n))
done
[ "$total" -gt 0 ] || { echo "sync: no shared/<mod>/ module found under shared/" >&2; exit 1; }
echo "sync: $total copy(ies) up to date across shared/*/"
