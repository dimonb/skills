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
    # The header, to the first line that is not a comment. A line-numbered range goes stale the
    # moment anyone adds a paragraph above it, and this one already had: it over-ran by one line
    # and printed a shell option back at the operator.
    -h|--help)     awk 'NR < 2 { next } /^#/ { sub(/^# ?/, ""); print; next } /^$/ { print; next } { exit }' "$0"; exit 0 ;;
    *)             [ -z "$SLOT" ] && SLOT="$1"; shift ;;
  esac
done
[ -n "$SLOT" ] || { echo "usage: shipyard-compact.sh <slot> [--resume-file <path>|--resume <text>|--no-resume]" >&2; exit 2; }

shipyard_backend_check || exit 1
# Exit 3 means the backend answered and does not have this slot — the child is gone. Exit 7 means
# the question could not be answered at all (the backend was unreachable, or this process resolved
# a different one from the fleet's pin) and the child's fate is UNKNOWN. Reporting the second as
# the first tells a supervisor its work died; see shipyard_absence_report in shipyard-backend.sh.
T=$(shipyard_where "$SLOT") || { shipyard_absence_report "$SLOT" || exit 7; exit 3; }

pane() { shipyard_capture "$SLOT"; }

# Submit is not the same key on every client build, and a session AT its ceiling can
# refuse both — so try one, look, then try the other. Never conclude from one key.
# (On agterm both are the same real newline, so the second attempt is a harmless retry.)
submit() {
  shipyard_submit "$SLOT"
  sleep 3
  if ! adp_turn_running "$(pane)"; then
    shipyard_submit "$SLOT" alt
    sleep 3
  fi
}

# NEVER drive the pane mid-turn. The first thing we send is Escape, and Escape is
# INTERRUPT while a turn is running — it would kill the work in flight, which is the
# opposite of the point. Wait for the turn marker to leave (shared/adapters spells it).
#
# The THREE-state read, not the boolean, and that is the point of this line: an unreadable capture
# is what a backend blip returns as well as what a blank screen returns, and the boolean calls
# both "no turn running" — so a socket hiccup here would fall straight through to the Escape.
# Waiting on `unknown` too means an unreadable pane times out into the exit below, which is the
# safe direction, instead of into an interrupt.
waited=0
while case "$(adp_turn_state "$(pane)")" in running|queued|unknown) true ;; *) false ;; esac; do
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
    if ! adp_turn_running "$p"; then
      echo "compacted after ${waited}s"
      break
    fi
  fi
  sleep 5; waited=$((waited+5))
done
if [ "$waited" -ge "$TIMEOUT" ]; then
  # EXIT 4 IS AMBIGUOUS, and saying otherwise has nearly killed a healthy run. This message
  # used to assert the session was past accepting a slash command; it was not — two review
  # subagents were running and the wait simply expired inside a long turn. The mid-turn guard
  # above cannot see that case: background agents keep working after the main turn ends, so
  # the session sits at a live prompt, accepts `/compact`, and then compacts slowly or not at
  # all while they run. Acting on the old wording means discarding a session that was fine.
  echo "warning: no 'Compacted' marker after ${TIMEOUT}s. This does NOT prove the session is dead." >&2
  echo "         Two things produce it, and they need opposite responses:" >&2
  echo "           * BENIGN — background agents or a long turn. The pane still shows a spinner or an" >&2
  echo "             agent list. Re-run when that list is empty, or raise --timeout. Change nothing else." >&2
  echo "           * REAL — the session is past accepting even a slash command. The pane shows no turn" >&2
  echo "             running and typing into it does nothing." >&2
  echo "         Tell them apart from GIT FIRST — \`git -C <worktree> log --oneline -5\` and \`git status\`" >&2
  echo "         say what the child actually produced — then look at the pane. Only on REAL, recover with" >&2
  echo "         a FRESH session on the same worktree plus a handoff file. \`/clear\` is never the answer." >&2
  exit 4
fi

[ "$NO_RESUME" = 1 ] && { echo "not resuming (--no-resume) — the child is IDLE and will stay that way until told otherwise"; exit 0; }

# --- the half that is always forgotten ----------------------------------------
# Every arm below `exec`s, so shipyard-tell.sh's status BECOMES this script's — including its
# exit 6, UNCONFIRMED: the compaction itself succeeded and the resume was typed and submitted, but
# no turn was seen to start, so the child may be sitting there with the brief unsent in its box.
# That is exactly the state a compaction is supposed to end, so surfacing it beats reporting
# success. tell.sh prints what to look at; 6 does not collide with 2/3/4/5 above.
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
