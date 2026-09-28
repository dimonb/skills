#!/usr/bin/env bash
# shipyard-escalations.sh — PARENT watcher side: show escalations raised by child ship
# sessions.
#
# Usage:
#   shipyard-escalations.sh          every open (pending) item — read-only, flags untouched
#   shipyard-escalations.sh --new    only items not shown yet; marks them notified
#                              (for the fast monitor: silent when nothing is new)
#
# Prints one whole markdown block (so Monitor batches it into a single
# notification) or NOTHING when there is nothing to show. Always exits 0 —
# escalations are never a loop-stop condition.
#
# A record it cannot READ is shown too, in a block of its own (#197) — see below.
set -o pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shipyard-lib.sh
. "$DIR/shipyard-lib.sh"

ONLY_NEW=0
[ "${1:-}" = "--new" ] && ONLY_NEW=1

MB=$(shipyard_mailbox) || exit 0
[ -d "$MB" ] || exit 0

shopt -s nullglob
FILES=("$MB"/*.json)
[ ${#FILES[@]} -eq 0 ] && exit 0

declare -a SHOW BAD BAD_FP BAD_SHOW
for f in "${FILES[@]}"; do
  # A record this view cannot READ is not a record of another kind, and it used to be treated as one
  # (#197): the kind filter below printed an empty string for a truncated or non-JSON file, the
  # allow-list's `*) continue` took it, and a corrupted question vanished from every view while the
  # child that asked it waited for an answer. So it is set aside BEFORE the allow-list and rendered
  # in a block of its own below. It is not counted as a pending question — nothing can be said about
  # its kind — and it is not hidden either.
  #
  # Not a regular file is unreadable too, and is never opened: every child can write this directory,
  # and a FIFO matching the glob blocked the first jq here, which hung the escalation monitor for the
  # whole fleet (#253). The window between that test and jq's open is the read residual #246
  # deferred: a FIFO swapped in there still hangs this run.
  if ! shipyard_record_readable "$f"; then
    BAD+=("$f")
    # What --new compares, never printed. The content and not the name alone, so a record rewritten
    # into other unreadable bytes is news again. `cksum` is POSIX, and is only given a regular file.
    if [ -f "$f" ]; then
      BAD_FP+=("${f##*/}	$(cksum <"$f" 2>/dev/null)")
    else
      BAD_FP+=("${f##*/}	not-a-regular-file")
    fi
    continue
  fi
  # ALLOW-LIST, not a deny-list. The mailbox holds other records too — `directive`
  # (parent->child, shipyard-tell.sh) and `launch` (what a child was started with) — and a
  # deny-list only knows the kinds that existed when it was written. Anything whose
  # kind is not an escalation kind (including a record with no kind at all) used to
  # default to a pending question: a fake escalation nobody can answer, which keeps
  # the monitor awake for ever.
  case "$(jq -r '.kind // ""' "$f" 2>/dev/null)" in
    question|decision|notice) ;;
    *) continue ;;
  esac
  st=$(jq -r '.status // "pending"' "$f" 2>/dev/null)
  [ "$st" = "pending" ] || continue
  if [ "$ONLY_NEW" = 1 ]; then
    nt=$(jq -r '.notified // false' "$f" 2>/dev/null)
    [ "$nt" = "true" ] && continue
  fi
  SHOW+=("$f")
done

# --new: an unreadable record cannot carry a `notified` flag (writing one needs the bytes jq just
# failed on), so which ones were already pushed is kept beside the records, in $SEENFILE, one
# fingerprint per line. It is REWRITTEN WHOLE from this run's set, so a record repaired and later
# broken again is news again.
#
# WHAT DECIDES WHETHER AN UNREADABLE RECORD APPEARS, per output (AGENTS.md, "untrusted evidence may
# annotate an operator-facing signal, never suppress one"):
#   * the full view — this script without --new, which shipyard-report.sh appends to every tick it
#     prints — shows every unreadable record on every run. Nothing a child writes removes it there
#     short of repairing or removing the record itself, which is the remedy.
#   * the --new push shows each one ONCE, and that once is decided by $SEENFILE, which lives in the
#     mailbox every child can write. NOT PREVENTED: a child that writes the right fingerprint into
#     it before the fast monitor runs suppresses the push. It is the same exposure as the `notified`
#     flag a readable record carries in its own peer-writable bytes, and the full view is the
#     backstop for both.
# A peer-written file here decides nothing about any OTHER record: an unreadable one is set aside
# before the allow-list and never reaches SHOW, and a malformed $SEENFILE only makes an unreadable
# record read as new.
SEENFILE="$MB/report-unreadable"
if [ "$ONLY_NEW" = 1 ]; then
  i=0
  for f in ${BAD[@]+"${BAD[@]}"}; do
    fp=${BAD_FP[$i]}; i=$((i+1))
    # Line-exact and string-exact through ENVIRON, so a name carrying a regex metacharacter or a
    # backslash cannot match a row it is not.
    if [ -f "$SEENFILE" ] \
       && FP="$fp" awk '$0""==ENVIRON["FP"]"" {found=1; exit} END {exit !found}' "$SEENFILE" 2>/dev/null; then
      continue
    fi
    BAD_SHOW+=("$f")
  done
  # By rename, like every report-* write (#253). Only when there is something to say about it, so a
  # mailbox that never held an unreadable record never grows the file.
  if [ "${#BAD_FP[@]}" -gt 0 ] || [ -e "$SEENFILE" ]; then
    { [ "${#BAD_FP[@]}" -gt 0 ] && printf '%s\n' "${BAD_FP[@]}"; } \
      | policy_mailbox_write "$SEENFILE" 2>/dev/null
  fi
else
  BAD_SHOW=(${BAD[@]+"${BAD[@]}"})
fi
[ ${#SHOW[@]} -eq 0 ] && [ ${#BAD_SHOW[@]} -eq 0 ] && exit 0

{
  echo "### ⚠️ ship escalations — $(date '+%H:%M:%S %Z')"
  for f in ${SHOW[@]+"${SHOW[@]}"}; do
    id=$(jq -r '.id' "$f"); slot=$(jq -r '.slot' "$f")
    kind=$(jq -r '.kind' "$f"); txt=$(jq -r '.text' "$f")
    ctx=$(jq -r '.context // ""' "$f"); at=$(jq -r '.created_at' "$f")
    echo
    case "$kind" in
      notice)   echo "**[notice] \`$id\`** (slot \`$slot\`, $at)" ;;
      decision) echo "**[🏛 architecture decision] \`$id\`** (slot \`$slot\`, $at)" ;;
      *)        echo "**[question] \`$id\`** (slot \`$slot\`, $at)" ;;
    esac
    echo "> $(printf '%s' "$txt" | tr '\n' ' ')"
    [ -n "$ctx" ] && { echo; echo "Context: $(printf '%s' "$ctx" | tr '\n' ' ')"; }
    echo
    # `id` and `slot` are written by whoever wrote the record, and these lines exist to be pasted
    # into a shell, so both are shell-quoted here: `%q` leaves a valid name as it is, and a crafted
    # one (`$(…)`) reaches the script as text, where tell's slot check refuses it (#198).
    if [ "$kind" != notice ]; then
      echo "Reply: \`bash $DIR/shipyard-answer.sh $(printf '%q' "$id") \"<answer>\"\`"
    else
      # A notice needs no reply and the child does not poll it. If you DO want to
      # say something back, it has to go into the child's window.
      echo "No reply needed. To send something back anyway: \`bash $DIR/shipyard-tell.sh $(printf '%q' "$slot") \"<directive>\"\`"
    fi
  done
  # The file name is written by whoever wrote the file, and these lines are operator-facing and meant
  # to be pasted, so the name goes out through `%q`: a newline or an ESC in it renders as `$'\n'` on
  # one line and cannot forge a line of its own (measured on the report's HELD block, which names
  # these same files through slot_unsettled_files).
  for f in ${BAD_SHOW[@]+"${BAD_SHOW[@]}"}; do
    echo
    if [ -f "$f" ]; then why="jq cannot parse it as a record"; else why="it is not a regular file"; fi
    echo "**[❓ unreadable record] \`$(printf '%q' "${f##*/}")\`** — $why, so nothing can be said about its kind or its slot."
    echo "If it was an escalation, the child that wrote it is waiting on a question nobody can see, and"
    echo "\`shipyard-answer.sh\` cannot write an answer into it. Look at the file, then repair or remove it (#197):"
    echo "\`ls -l $(printf '%q' "$f")\`"
  done
} | cat

# A notice needs no reply — close it right away so it stops showing as pending.
for f in ${SHOW[@]+"${SHOW[@]}"}; do
  if [ "$(jq -r '.kind' "$f" 2>/dev/null)" = notice ]; then
    shipyard_json_set "$f" '.notified=true | .status="done"'
  elif [ "$ONLY_NEW" = 1 ]; then
    shipyard_json_set "$f" '.notified=true'
  fi
done
exit 0
