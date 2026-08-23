#!/usr/bin/env bash
# shipyard-compact.sh — compact a ship child and PUT IT BACK TO WORK.
#
# `/compact` is a TUI slash command, so the mailbox cannot carry it. And on its own
# it is only half the job: a compacted child comes back with an empty context and
# then SITS IDLE waiting for a turn. It does not resume by itself. Every manual
# compaction has therefore ended with a child that looks healthy, reports no
# escalation, and does nothing — the same signature as the ceiling stall it was
# meant to cure. This script always does both halves.
#
# usage:
#   shipyard-compact.sh <slot> [--resume-file <path>] [--resume "<text>"] [--timeout <sec>]
#   shipyard-compact.sh <slot> --no-resume        # only when you will drive it yourself
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/shipyard-lib.sh"

SLOT=""; RESUME_FILE=""; RESUME_TEXT=""; NO_RESUME=0; TIMEOUT=300
while [ $# -gt 0 ]; do
  case "$1" in
    --resume-file) RESUME_FILE="${2:-}"; shift 2 || true ;;
    --resume)      RESUME_TEXT="${2:-}"; shift 2 || true ;;
    --timeout)     TIMEOUT="${2:-300}"; shift 2 || true ;;
    --no-resume)   NO_RESUME=1; shift ;;
    -h|--help)     sed -n '2,14p' "$0"; exit 0 ;;
    *)             [ -z "$SLOT" ] && SLOT="$1"; shift ;;
  esac
done
[ -n "$SLOT" ] || { echo "usage: shipyard-compact.sh <slot> [--resume-file <path>|--resume <text>|--no-resume]" >&2; exit 2; }

shipyard_backend_check || exit 1
T=$(shipyard_where "$SLOT") || {
  echo "error: no live terminal \`ship-$SLOT\` in $(shipyard_container_kind) \`$(shipyard_container)\`" >&2; exit 3; }

pane() { shipyard_capture "$SLOT"; }

# Submit is not the same key on every client build, and a session AT its ceiling can
# refuse both — so try one, look, then try the other. Never conclude from one key.
# (On agterm both are the same real newline, so the second attempt is a harmless retry.)
submit() {
  shipyard_submit "$SLOT"
  sleep 3
  if [ "$(pane | grep -c 'esc to interrupt')" = "0" ]; then
    shipyard_submit "$SLOT" alt
    sleep 3
  fi
}

# NEVER drive the pane mid-turn. The first thing we send is Escape, and Escape is
# INTERRUPT while a turn is running — it would kill the work in flight, which is the
# opposite of the point. Wait for the footer to stop offering "esc to interrupt".
waited=0
while [ "$(pane | grep -c 'esc to interrupt')" != "0" ]; do
  if [ "$waited" -eq 0 ]; then echo "ship-$SLOT is mid-turn — waiting for it to finish before compacting…"; fi
  sleep 10; waited=$((waited+10))
  if [ "$waited" -ge "$TIMEOUT" ]; then
    echo "warning: still mid-turn after ${TIMEOUT}s; not interrupting it. Re-run when it is idle." >&2
    exit 5
  fi
done
[ "$waited" -gt 0 ] && echo "turn ended after ${waited}s; compacting now"

echo "compacting ship-$SLOT ($T)…"
shipyard_esc "$SLOT"; sleep 1                # Escape CLEARS the box; BSpace restores an older draft
shipyard_type "$SLOT" "/compact"; sleep 1
submit

# Wait for it to finish. "Compacted" is the marker; a compaction of a very large
# session retries on API errors for a while, so the timeout is generous.
waited=0
while [ "$waited" -lt "$TIMEOUT" ]; do
  p=$(pane)
  if printf '%s' "$p" | grep -q 'Compacted'; then
    if [ "$(printf '%s' "$p" | grep -c 'esc to interrupt')" = "0" ]; then
      echo "compacted after ${waited}s"
      break
    fi
  fi
  sleep 5; waited=$((waited+5))
done
if [ "$waited" -ge "$TIMEOUT" ]; then
  echo "warning: no 'Compacted' marker after ${TIMEOUT}s — the session may be past the point of accepting even a slash command." >&2
  echo "         recover with a FRESH session on the same worktree plus a handoff file; check git status/log there first." >&2
  exit 4
fi

[ "$NO_RESUME" = 1 ] && { echo "not resuming (--no-resume) — the child is IDLE and will stay that way until told otherwise"; exit 0; }

# --- the half that is always forgotten ----------------------------------------
if [ -n "$RESUME_FILE" ]; then
  exec bash "$DIR/shipyard-tell.sh" "$SLOT" "@$RESUME_FILE"
elif [ -n "$RESUME_TEXT" ]; then
  exec bash "$DIR/shipyard-tell.sh" "$SLOT" "$RESUME_TEXT"
else
  # Standing orders are the ONLY thing that reliably survives a compaction, because a
  # rule held in conversation dies with the context. If the slot has such a file, the
  # resume brief must point at it — otherwise a hard constraint ("do not merge") is
  # silently lifted by the very operation meant to keep the child working.
  MB=$(shipyard_mailbox 2>/dev/null) || MB=""
  ORDERS="$MB/standing-orders-$SLOT.md"
  EXTRA=""
  if [ -n "$MB" ] && [ -f "$ORDERS" ]; then
    EXTRA=" STANDING ORDERS ARE IN FORCE: read $ORDERS NOW, before doing anything else, and treat it as authoritative over anything you remember. It exists because your remembered context was just discarded."
    echo "note: standing orders found for $SLOT — the resume brief points at them"
  fi
  exec bash "$DIR/shipyard-tell.sh" "$SLOT" "You were compacted — that was your supervisor, not a failure, and you lost no work: worktree, branch and mailbox are intact. Do NOT re-derive the change from scratch; read only what the next slice needs. Check git log and your tasks file for where you actually are, then continue with the next unticked task. Escalate as usual if anything is ambiguous.$EXTRA"
fi
