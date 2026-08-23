#!/usr/bin/env bash
# shipyard-down.sh — tear a finished ship slot down: its terminal, then its worktree.
#
# MERGE (or close) is the only teardown signal. A child re-wakes itself and continues
# after long idle pauses, so tearing one down early kills work in flight — and the
# worktree goes with it.
#
# usage:
#   shipyard-down.sh <slot> [<slot> ...]     tear down, refusing anything unsafe
#   shipyard-down.sh <slot> --force          tear down even with uncommitted/unpushed work
#   shipyard-down.sh --list                  what is safe to tear down right now
#
# Safety gates (each one refuses, and says what to look at):
#   * uncommitted changes in the worktree;
#   * commits on the branch that are not in origin.
# --force overrides both. There is no gate on the MR state: the report knows that,
# and a slot can also be legitimately torn down after a CLOSE.
#
# Exit: 0 all requested slots are down, 1 at least one was refused or failed.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shipyard-lib.sh
. "$DIR/shipyard-lib.sh"

FORCE=0; LIST=0
declare -a SLOTS=()
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    --list)  LIST=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)       SLOTS+=("$a") ;;
  esac
done

shipyard_backend_check || exit 1
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "error: not inside a git repository" >&2; exit 1; }
# Refuse to run from inside a ship worktree: removing the worktree you are standing in
# leaves git and the shell in a state that takes longer to explain than to avoid.
case "$(basename "$ROOT")" in
  ship-*) echo "error: run this from the MAIN worktree, not from $ROOT" >&2; exit 1 ;;
esac

wt_of() { printf '%s/.claude/worktrees/ship-%s' "$ROOT" "$1"; }

if [ "$LIST" = 1 ]; then
  printf '%-24s %-10s %-9s %s\n' SLOT TERMINAL WORKTREE STATE
  for w in "$ROOT"/.claude/worktrees/ship-*; do
    [ -d "$w" ] || continue
    s=$(basename "$w"); s="${s#ship-}"
    t="gone"; shipyard_target "$s" >/dev/null 2>&1 && t="live"
    dirty=$(git -C "$w" status --porcelain 2>/dev/null | head -1)
    unpushed=$(git -C "$w" log --oneline '@{upstream}..HEAD' 2>/dev/null | wc -l | tr -d ' ')
    st="clean"
    [ -n "$dirty" ] && st="DIRTY"
    [ "${unpushed:-0}" != 0 ] && st="$st, $unpushed unpushed"
    printf '%-24s %-10s %-9s %s\n' "$s" "$t" "present" "$st"
  done
  exit 0
fi

[ ${#SLOTS[@]} -gt 0 ] || { echo 'usage: shipyard-down.sh <slot> [<slot> ...] [--force] | shipyard-down.sh --list' >&2; exit 1; }

rc=0
for slot in "${SLOTS[@]}"; do
  WT=$(wt_of "$slot")

  if [ -d "$WT" ] && [ "$FORCE" != 1 ]; then
    if [ -n "$(git -C "$WT" status --porcelain 2>/dev/null)" ]; then
      echo "refused: ship-$slot has uncommitted changes in $WT" >&2
      echo "         look: git -C '$WT' status" >&2
      rc=1; continue
    fi
    n=$(git -C "$WT" log --oneline '@{upstream}..HEAD' 2>/dev/null | wc -l | tr -d ' ')
    if [ "${n:-0}" != 0 ]; then
      echo "refused: ship-$slot has $n commit(s) not in its upstream" >&2
      echo "         look: git -C '$WT' log --oneline '@{upstream}..HEAD'" >&2
      rc=1; continue
    fi
  fi

  if shipyard_target "$slot" >/dev/null 2>&1; then
    where=$(shipyard_where "$slot")
    shipyard_kill "$slot" && echo "closed $where"
  fi

  if [ -d "$WT" ]; then
    # A DOUBLE -f: one for a dirty worktree, one more for a locked one. A single -f
    # fails on a lock with a message that reads like a permissions problem.
    if git -C "$ROOT" worktree remove -f -f "$WT" 2>/dev/null; then
      echo "removed worktree $WT"
    else
      echo "warning: could not remove $WT — remove it by hand" >&2
      rc=1
    fi
  fi
done

git -C "$ROOT" worktree prune 2>/dev/null

# Once the last child is gone, drop the container and forget its pinned name, so the
# next run derives a fresh one from wherever you launch it. Keeping a stale pin would
# send tomorrow's children into a workspace you have since stopped working in.
if [ -z "$(shipyard_slots 2>/dev/null)" ]; then
  shipyard_container_prune
  shipyard_container_unpin
fi
exit "$rc"
