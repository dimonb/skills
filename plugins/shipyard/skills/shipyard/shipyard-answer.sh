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
#
# WINDOW carries the outcome to the closing message at the bottom, which must not re-derive it.
# It used to: the closing line tested `$KIND`/`$ST` a second time and so claimed the answer "was
# delivered through its window" on EVERY path that reached it — including `--no-tell`, where
# nothing was sent, and a dead terminal, where stderr had just said the child could not be
# reached. The success path exits before the closing line, so the one outcome it asserted was the
# one outcome it could never be. One variable, set where the outcome is actually known.
WINDOW=none
if [ "$KIND" = "notice" ] || [ "$ST" = "done" ]; then
  if [ "$NO_TELL" = 1 ]; then
    WINDOW=skipped
    echo "warning: $ID is a '$KIND' in status '$ST' — the child does not poll it, so this answer will not be read (--no-tell)" >&2
  else
    case "$KIND" in
      notice) echo "note: $ID is a notice (fire-and-forget) — the child never polls it; delivering through its window instead" >&2 ;;
      *)      echo "note: $ID is already consumed ('$ST') — the child is no longer polling it; delivering through its window instead" >&2 ;;
    esac
    # Exit 6 is shipyard-tell.sh's UNCONFIRMED: it typed and submitted, but saw no turn start, so
    # the text may be sitting unsent in the child's input box. That is not "could not reach the
    # child" — it is "may not have been read yet", and it is the case where also writing the
    # answer onto the record is worth the belt: if the directive never started a turn, the record
    # is the only copy left.
    #
    # EXIT 7 IS NEITHER, AND IT MUST NOT REACH THE WRITE BELOW. It means the slot could not be
    # RESOLVED — the backend did not answer, or this process resolved a different one from the
    # fleet's pin — so nothing was sent, nothing was recorded by tell.sh, and nothing is known
    # about the child. Two reasons it returns here instead of falling through:
    #   * the closing line would say "could not be reached ... nobody is going to read this",
    #     which is a confident negative drawn from a question that was never answered — the very
    #     inference the exit code exists to stop;
    #   * the write stamps `.status="answered"`, and on a CONSUMED record that is what the status
    #     gate above tests. So the remedy the refusal prints — clear the backend, re-ask — would
    #     then skip this branch entirely and report a ~5s pickup on a record the child does not
    #     poll. Leaving the record untouched keeps the re-run working, and loses nothing: on a 7
    #     tell.sh wrote no directive either.
    bash "$DIR/shipyard-tell.sh" "$ID" "$ANS"; TELL_RC=$?
    [ "$TELL_RC" = 0 ] && exit 0
    if [ "$TELL_RC" = 7 ]; then
      echo "warning: nothing was sent and $ID was left untouched — the slot could not be resolved" >&2
      echo "         (see above). This is NOT evidence the child is gone. Clear the backend" >&2
      echo "         question and run the same command again; it re-delivers from here." >&2
      exit 7
    fi
    if [ "$TELL_RC" = 6 ]; then
      WINDOW=unconfirmed
      echo "warning: the directive was sent but NOT confirmed (see above) — also recording the answer on $ID" >&2
    else
      WINDOW=failed
      echo "warning: could not reach the child — recording the answer on $ID anyway (it may never be read)" >&2
    fi
  fi
elif [ "$ST" = "answered" ]; then
  echo "warning: $ID is already 'answered' — overwriting the answer" >&2
fi

TMP="$F.tmp.$$"
jq --arg a "$ANS" --arg now "$(shipyard_now)" \
  '.answer=$a | .status="answered" | .answered_at=$now' "$F" >"$TMP" \
  && mv "$TMP" "$F" || { rm -f "$TMP"; echo "error: write failed" >&2; exit 1; }

SLOT=$(jq -r '.slot // "?"' "$F")
# The ~5s pickup is true only for a record the child actually POLLS. On a `notice` or a consumed
# record it does not, which is the whole reason the branch above delivers through the window — so
# claiming a pickup here would contradict the warning printed moments earlier. Keep the record
# write (it is the only surviving copy if the directive never started a turn) and say what is true.
case "$WINDOW" in
  unconfirmed)
    echo "recorded the answer on $ID (slot $SLOT) — the child does NOT poll this record, and the"
    echo "directive it was delivered as is UNCONFIRMED (see above), so check the child's box" ;;
  failed)
    echo "recorded the answer on $ID (slot $SLOT) — the child does NOT poll this record and could"
    echo "not be reached, so nobody is going to read this. It is an audit copy only." ;;
  skipped)
    echo "recorded the answer on $ID (slot $SLOT) — nothing was delivered (--no-tell), and the"
    echo "child does not poll this record, so it is an audit copy only" ;;
  *)
    # WINDOW=none: a record the child really does poll, so the pickup claim is true here only.
    echo "answered $ID (slot $SLOT) — the child session will pick it up within ~5s" ;;
esac
