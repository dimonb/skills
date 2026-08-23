#!/usr/bin/env bash
# shipyard-ask.sh — escalate from a CHILD ship session up to the parent watcher.
#
# A child session has no human in it: it runs in a background terminal (an agterm
# session by default, a tmux window with SHIPYARD_BACKEND=tmux). Every
# question, every architectural decision and every important event goes through
# this script into the shared mailbox (.git/ship-escalations). The parent watcher
# surfaces it to the human, writes the answer back with shipyard-answer.sh, and the
# child picks the answer up and keeps working.
#
# Usage (run from the child worktree):
#   shipyard-ask.sh "<question>" [--context "<state / options / your recommendation>"]
#                          [--timeout N]
#       Create a question and block until answered (default 90s).
#       stdout: "ESCALATED:<id>" then "ANSWER: <text>"  (exit 0)
#                                  or  "PENDING:<id>"   (exit 4 — timed out)
#
#   shipyard-ask.sh --kind decision "<architectural decision to make>" \
#             --context "<options A/B/C, trade-offs, your recommendation>"
#       Same blocking flow, flagged as a design/architecture decision.
#       --context is REQUIRED for this kind: the parent cannot decide blind.
#
#   shipyard-ask.sh --kind notice "<what happened>" [--context ...]
#       Fire-and-forget FYI, no waiting (exit 0).
#
#   shipyard-ask.sh --wait <id> [--timeout N]   block waiting on an existing id
#   shipyard-ask.sh --poll <id>                 single check: ANSWER/PENDING
#
# Env: SHIPYARD_SLOT (default: derived from worktree name), SHIPYARD_ASK_TIMEOUT (default 90).
#
# NOTE on the Bash tool: its default timeout is 120000ms, max 600000. For a long
# wait pass `--timeout 540` and set the Bash tool timeout to 600000.
set -o pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shipyard-lib.sh
. "$DIR/shipyard-lib.sh"

usage() { sed -n '3,33p' "$0" | sed 's/^# \{0,1\}//'; }

MODE=ask KIND=question CONTEXT_RAW="" TEXT_RAW="" CONTEXT="" TEXT="" ID=""
TIMEOUT=${SHIPYARD_ASK_TIMEOUT:-90}

while [ $# -gt 0 ]; do
  case "$1" in
    --poll)    MODE=poll; ID="${2:-}"; shift 2 || true ;;
    --wait)    MODE=wait; ID="${2:-}"; shift 2 || true ;;
    --kind)    KIND="${2:-question}"; shift 2 || true ;;
    --context) CONTEXT_RAW="${2:-}"; shift 2 || true ;;
    --context-file) CONTEXT_RAW="@${2:-}"; shift 2 || true ;;
    --text-file)    TEXT_RAW="@${2:-}"; shift 2 || true ;;
    --timeout) TIMEOUT="${2:-90}"; shift 2 || true ;;
    -h|--help) usage; exit 0 ;;
    *)         TEXT_RAW="$1"; shift ;;
  esac
done

# Resolve payloads through shipyard_payload so `@file` / `@-` bypass the caller's
# shell entirely. Escalation context is the field most likely to carry code,
# and it is the one that has already lost a term in transit. Must run BEFORE
# the validations below, which test these very variables.
TEXT=$(shipyard_payload "${TEXT_RAW:-}") || exit 1
CONTEXT=$(shipyard_payload "${CONTEXT_RAW:-}") || exit 1

MB=$(shipyard_mailbox_ensure) || { echo "error: not inside a git repository" >&2; exit 1; }

answer_of() { # <file> -> prints the answer, exit 0 if answered
  local f="$1" st ans
  st=$(jq -r '.status // "pending"' "$f" 2>/dev/null)
  [ "$st" = "answered" ] || return 1
  ans=$(jq -r '.answer // ""' "$f" 2>/dev/null)
  printf 'ANSWER: %s\n' "$ans"
  return 0
}

wait_for() { # <id>
  local f deadline
  f=$(shipyard_esc_file "$1")
  [ -f "$f" ] || { echo "error: no such escalation: $1" >&2; exit 2; }
  deadline=$(( $(date +%s) + TIMEOUT ))
  while :; do
    answer_of "$f" && { shipyard_json_set "$f" '.status="done" | .consumed_at="'"$(shipyard_now)"'"'; return 0; }
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 5
  done
  printf 'PENDING:%s\n' "$1"
  return 4
}

case "$MODE" in
  poll)
    [ -n "$ID" ] || { echo "usage: shipyard-ask.sh --poll <id>" >&2; exit 2; }
    F=$(shipyard_esc_file "$ID")
    [ -f "$F" ] || { echo "error: no such escalation: $ID" >&2; exit 2; }
    if answer_of "$F"; then
      shipyard_json_set "$F" '.status="done" | .consumed_at="'"$(shipyard_now)"'"'
      exit 0
    fi
    printf 'PENDING:%s\n' "$ID"; exit 4 ;;
  wait)
    [ -n "$ID" ] || { echo "usage: shipyard-ask.sh --wait <id>" >&2; exit 2; }
    wait_for "$ID"; exit $? ;;
esac

# --- create a new escalation ---------------------------------------------------
[ -n "$TEXT" ] || { usage >&2; exit 2; }
case "$KIND" in
  question|decision|notice) ;;
  *) echo "error: --kind must be question|decision|notice" >&2; exit 2 ;;
esac
if [ "$KIND" = decision ] && [ -z "$CONTEXT" ]; then
  echo "error: --kind decision requires --context with the options, trade-offs and your recommendation" >&2
  exit 2
fi

SLOT=$(shipyard_slot) || SLOT="unknown"
# Allocate the next FREE id. Without this loop every escalation writes
# <slot>-1, silently overwriting the previous record — and the child then
# polls that same id, so two children on one slot read each other's answers.
n=1
while [ -e "$MB/$SLOT-$n.json" ]; do n=$((n+1)); done
ID="$SLOT-$n"
F="$MB/$ID.json"

jq -n --arg id "$ID" --arg slot "$SLOT" --arg kind "$KIND" \
      --arg text "$TEXT" --arg ctx "$CONTEXT" --arg now "$(shipyard_now)" \
      --arg wt "$(git rev-parse --show-toplevel 2>/dev/null)" \
  '{id:$id, slot:$slot, kind:$kind, text:$text, context:$ctx,
    worktree:$wt, created_at:$now, status:"pending", notified:false,
    answer:null, answered_at:null}' >"$F" || {
  echo "error: failed to write escalation" >&2; exit 1; }

printf 'ESCALATED:%s\n' "$ID"

if [ "$KIND" = notice ]; then
  echo "(notice — not waiting for a reply)"
  exit 0
fi

wait_for "$ID"
exit $?
