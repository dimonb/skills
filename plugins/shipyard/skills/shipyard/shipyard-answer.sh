#!/usr/bin/env bash
# shipyard-answer.sh — the PARENT watcher's reply to a child ship session's escalation.
#
# Usage:
#   shipyard-answer.sh <id> "<the human's answer / decision>"
#   shipyard-answer.sh <id> @<file>           payload read VERBATIM from a file
#   shipyard-answer.sh <id> @-                payload read VERBATIM from stdin
#
# Prefer @file / @- for anything with backticks, $(...) or code in it. The
# payload is a shell argument, so the CALLER's shell expands it first — that has
# already silently eaten identifiers out of a real decision.
#   shipyard-answer.sh --list                 list every escalation (id / slot / status)
#   shipyard-answer.sh --no-tell <id> "..."   write the record only, never fall back
#
# For a `question` or a `decision` the child picks the answer up on its own
# (shipyard-ask.sh blocks or polls) and keeps going — you never type into its window.
#
# A `notice` is different: it is fire-and-forget, the child never polls it, and an
# answer written onto it would be read by nobody. Same for a record already
# `done` (the child consumed its answer and moved on). In those two cases this
# script does NOT pretend to have answered — it hands the text to shipyard-tell.sh,
# which delivers it into the child's terminal. `--no-tell` disables that.
set -o pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shipyard-lib.sh
. "$DIR/shipyard-lib.sh"

MB=$(shipyard_mailbox) || { echo "error: not inside a git repository" >&2; exit 1; }

if [ "${1:-}" = "--list" ]; then
  shopt -s nullglob
  files=("$MB"/*.json)
  if [ ${#files[@]} -eq 0 ]; then echo "_no escalations_"; exit 0; fi
  printf '%-22s %-10s %-9s %-9s %s\n' ID SLOT KIND STATUS TEXT
  for f in "${files[@]}"; do
    jq -r '[.id, .slot, .kind, .status, (.text|gsub("\n";" ")|.[0:60])] | @tsv' "$f" 2>/dev/null \
      | awk -F'\t' '{printf "%-22s %-10s %-9s %-9s %s\n", $1,$2,$3,$4,$5}'
  done
  exit 0
fi

NO_TELL=0
if [ "${1:-}" = "--no-tell" ]; then NO_TELL=1; shift; fi

ID="${1:-}"; ANS_RAW="${2:-}"
if [ -z "$ID" ] || [ -z "$ANS_RAW" ]; then
  echo 'usage: shipyard-answer.sh [--no-tell] <id> "<answer>"        (short, single-line)' >&2
  echo '       shipyard-answer.sh [--no-tell] <id> @<file>           (verbatim, RECOMMENDED)' >&2
  echo '       shipyard-answer.sh [--no-tell] <id> @-              (verbatim, from stdin)' >&2
  echo '       shipyard-answer.sh --list' >&2
  echo >&2
  echo 'Use @file or @- for ANY answer containing backticks, $(...) or code: a' >&2
  echo 'double-quoted shell argument runs them and writes what is left.' >&2
  exit 2
fi
ANS=$(shipyard_payload "$ANS_RAW") || exit 1
[ -n "$ANS" ] || { echo "error: empty answer" >&2; exit 2; }

F="$MB/$ID.json"
[ -f "$F" ] || { echo "error: no such escalation: $ID" >&2; exit 2; }

KIND=$(jq -r '.kind // "question"' "$F" 2>/dev/null)
ST=$(jq -r '.status // "pending"' "$F" 2>/dev/null)

# Nobody is polling this record — writing an answer onto it would be a silent
# no-op. Deliver through the child's window instead (see the header).
if [ "$KIND" = "notice" ] || [ "$ST" = "done" ]; then
  if [ "$NO_TELL" = 1 ]; then
    echo "warning: $ID is a '$KIND' in status '$ST' — the child does not poll it, so this answer will not be read (--no-tell)" >&2
  else
    case "$KIND" in
      notice) echo "note: $ID is a notice (fire-and-forget) — the child never polls it; delivering through its window instead" >&2 ;;
      *)      echo "note: $ID is already consumed ('$ST') — the child is no longer polling it; delivering through its window instead" >&2 ;;
    esac
    if bash "$DIR/shipyard-tell.sh" "$ID" "$ANS"; then exit 0; fi
    echo "warning: could not reach the child — recording the answer on $ID anyway (it may never be read)" >&2
  fi
elif [ "$ST" = "answered" ]; then
  echo "warning: $ID is already 'answered' — overwriting the answer" >&2
fi

TMP="$F.tmp.$$"
jq --arg a "$ANS" --arg now "$(shipyard_now)" \
  '.answer=$a | .status="answered" | .answered_at=$now' "$F" >"$TMP" \
  && mv "$TMP" "$F" || { rm -f "$TMP"; echo "error: write failed" >&2; exit 1; }

SLOT=$(jq -r '.slot // "?"' "$F")
echo "answered $ID (slot $SLOT) — the child session will pick it up within ~5s"
