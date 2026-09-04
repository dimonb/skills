#!/usr/bin/env bash
# Vendor the one canonical agent driver into every plugin that ships a copy.
#
# A Codex plugin is installed as a self-contained directory and cannot depend on another
# plugin, so each carries its own copy of the shared driver. This script writes those copies
# from the single source of truth; scripts/check.sh (check 11) fails the gate if they drift.
#
# Workflow: edit shared/driver/agent-driver.sh, run this, commit the canonical AND the copies.
set -euo pipefail
cd "$(dirname "$0")/.."

canonical=shared/driver/agent-driver.sh
targets=shared/driver/targets.txt

[ -f "$canonical" ] || { echo "sync-driver: missing canonical $canonical" >&2; exit 1; }
[ -f "$targets" ]   || { echo "sync-driver: missing target list $targets" >&2; exit 1; }

n=0
while IFS= read -r t || [ -n "$t" ]; do
  case "$t" in ''|\#*) continue ;; esac
  mkdir -p "$(dirname "$t")"
  cp "$canonical" "$t"
  echo "synced -> $t"
  n=$((n + 1))
done < "$targets"

[ "$n" -gt 0 ] || { echo "sync-driver: target list is empty — nothing to sync" >&2; exit 1; }
echo "sync-driver: $n copy(ies) up to date with $canonical"
