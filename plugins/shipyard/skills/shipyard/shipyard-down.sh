#!/usr/bin/env bash
# shipyard-down.sh — tear a finished ship slot down: its terminal, then its worktree.
#
# MERGE (or close) is the only teardown signal. A child re-wakes itself and continues
# after long idle pauses, so tearing one down early kills work in flight — and the
# worktree goes with it.
#
# usage:
#   shipyard-down.sh <slot> [<slot> ...]     tear down, refusing anything unsafe
#   shipyard-down.sh <slot> --force          tear down even when the gates below refuse
#   shipyard-down.sh --list                  what is safe to tear down right now
#
# Safety gates (each one refuses, and says what to look at):
#   * uncommitted or untracked changes in the worktree;
#   * content that is not provably in the base branch already;
#   * a question that could not be asked at all — no base branch to compare against,
#     or a tree git could not read.
# --force overrides all of them. There is no gate on the MR state: the report knows
# that, and a slot can also be legitimately torn down after a CLOSE.
#
# The second gate asks about CONTENT, not ancestry: a squash merge leaves none of the
# branch's commits an ancestor of the base branch, so an ancestry test refuses the
# successful path — and passes a branch with no upstream at all. It also distinguishes
# work that is genuinely missing from the base branch from containment it merely could
# not prove, because those want opposite things from the operator.
# shipyard-down-gate.sh carries the measurements behind all of it.
#
# Exit: 0 all requested slots are down, 1 at least one was refused or failed.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shipyard-lib.sh
. "$DIR/shipyard-lib.sh"
# shellcheck source=shipyard-down-gate.sh
. "$DIR/shipyard-down-gate.sh"

FORCE=0; LIST=0
declare -a SLOTS=()
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    --list)  LIST=1 ;;
    # The header block IS the help text, so print it by SHAPE rather than by line number:
    # a fixed `2,Np` range silently starts printing code the moment the header grows, and
    # the old one already leaked `set -uo pipefail` into --help.
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
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
    # The listed state is the GATE's own verdict, not a second opinion computed here: a
    # column that says "clean" where teardown then refuses is how an operator learns to
    # stop reading the column.
    # Called WITHOUT a command substitution on purpose: the verdict comes back in globals so
    # the gate's one-fetch-per-invocation latch lives in THIS shell. A `$( )` here would fork
    # it away and make a listing fetch once per in-flight slot.
    shipyard_down_verdict "$w"
    kind=$SHIPYARD_DOWN_KIND; ref=$SHIPYARD_DOWN_REF
    case "$kind" in
      safe)       st="safe, content in $ref" ;;
      dirty)      st="DIRTY" ;;
      unmerged)   st="UNMERGED against $ref" ;;
      # Not "unmerged": the gate failed to PROVE containment, and a column that asserts more
      # than the gate measured is how the old commit count read as a loss warning.
      unprovable) st="unproven against $ref" ;;
      no-default) st="NO BASE REF" ;;
      *)          st="UNKNOWN ($kind)" ;;
    esac
    printf '%-24s %-10s %-9s %s\n' "$s" "$t" "present" "$st"
  done
  exit 0
fi

[ ${#SLOTS[@]} -gt 0 ] || { echo 'usage: shipyard-down.sh <slot> [<slot> ...] [--force] | shipyard-down.sh --list' >&2; exit 1; }

rc=0
for slot in "${SLOTS[@]}"; do
  WT=$(wt_of "$slot")

  if [ -d "$WT" ] && [ "$FORCE" != 1 ]; then
    shipyard_down_verdict "$WT"          # globals, not $( ) — see the --list note above
    kind=$SHIPYARD_DOWN_KIND; ref=$SHIPYARD_DOWN_REF
    case "$kind" in
      safe)
        # Say WHY it is safe. The guard spent a long time crying wolf on the happy path,
        # and one line naming the proof is what makes the next refusal worth reading.
        echo "ship-$slot: content is already in $ref — nothing to lose"
        ;;
      dirty)
        # The gate that actually stands between the operator and unrecoverable content:
        # committed work survives `worktree remove`, uncommitted work does not.
        echo "refused: ship-$slot has uncommitted or untracked changes in $WT" >&2
        echo "         look: git -C '$WT' status" >&2
        rc=1; continue
        ;;
      unmerged)
        # Deliberately NO commit count. The count is what made the old message unreadable:
        # after a squash it names commits that are fully merged, so it read as a loss
        # warning on the successful path and trained everyone to reach straight for
        # --force. Point at the content instead, which is the thing actually at stake.
        echo "refused: ship-$slot carries content that is NOT in $ref" >&2
        echo "         look: git -C '$WT' diff $ref" >&2
        echo "         look: git -C '$WT' log --oneline $ref..HEAD" >&2
        echo "         --force would orphan that content in its branch" >&2
        rc=1; continue
        ;;
      unprovable)
        echo "refused: ship-$slot's content could not be PROVEN to be in $ref" >&2
        echo "         (a later change to the same region blocks the test merge, or this git" >&2
        echo "          is older than 2.38 — this is not a claim that anything is missing)" >&2
        echo "         look: git -C '$WT' diff $ref" >&2
        echo "         --force is the right answer once you have looked" >&2
        rc=1; continue
        ;;
      no-default)
        echo "refused: ship-$slot has no base branch to compare against" >&2
        echo "         (tried origin/HEAD, the branch's upstream, origin/main, origin/master)" >&2
        echo "         look: git -C '$WT' branch -r" >&2
        rc=1; continue
        ;;
      *)
        echo "refused: ship-$slot could not be inspected — git did not answer" >&2
        echo "         (not a worktree, or an unreadable index; the gate never ran)" >&2
        echo "         look: git -C '$WT' status" >&2
        rc=1; continue
        ;;
    esac
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
remaining_slots=""
enumeration_status=0
remaining_slots=$(shipyard_slots 2>/dev/null) || enumeration_status=$?
cleanup_status=0
shipyard_continuity_cleanup_last_slot "$enumeration_status" "$remaining_slots" || cleanup_status=$?
if [ "$cleanup_status" -eq 2 ]; then
  echo "warning: could not verify that every shipyard slot is gone; lifecycle state was preserved" >&2
  rc=1
elif [ "$cleanup_status" -eq 3 ]; then
  echo "warning: could not stop every parent continuity watcher; lifecycle state was preserved" >&2
  rc=1
fi
exit "$rc"
