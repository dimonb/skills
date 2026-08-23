#!/usr/bin/env bash
# sh-escalations.sh — PARENT watcher side: show escalations raised by child ship
# sessions.
#
# Usage:
#   sh-escalations.sh          every open (pending) item — read-only, flags untouched
#   sh-escalations.sh --new    only items not shown yet; marks them notified
#                              (for the fast monitor: silent when nothing is new)
#
# Prints one whole markdown block (so Monitor batches it into a single
# notification) or NOTHING when there is nothing to show. Always exits 0 —
# escalations are never a loop-stop condition.
set -o pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sh-lib.sh
. "$DIR/sh-lib.sh"

ONLY_NEW=0
[ "${1:-}" = "--new" ] && ONLY_NEW=1

MB=$(sh_mailbox) || exit 0
[ -d "$MB" ] || exit 0

shopt -s nullglob
FILES=("$MB"/*.json)
[ ${#FILES[@]} -eq 0 ] && exit 0

declare -a SHOW
for f in "${FILES[@]}"; do
  # ALLOW-LIST, not a deny-list. The mailbox holds other records too — `directive`
  # (parent->child, sh-tell.sh) and `launch` (what a child was started with) — and a
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
[ ${#SHOW[@]} -eq 0 ] && exit 0

{
  echo "### ⚠️ ship escalations — $(TZ=Europe/Moscow date '+%H:%M:%S MSK')"
  for f in "${SHOW[@]}"; do
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
    if [ "$kind" != notice ]; then
      echo "Reply: \`bash $DIR/sh-answer.sh $id \"<answer>\"\`"
    else
      # A notice needs no reply and the child does not poll it. If you DO want to
      # say something back, it has to go into the child's window.
      echo "No reply needed. To send something back anyway: \`bash $DIR/sh-tell.sh $slot \"<directive>\"\`"
    fi
  done
} | cat

# A notice needs no reply — close it right away so it stops showing as pending.
for f in "${SHOW[@]}"; do
  if [ "$(jq -r '.kind' "$f" 2>/dev/null)" = notice ]; then
    sh_json_set "$f" '.notified=true | .status="done"'
  elif [ "$ONLY_NEW" = 1 ]; then
    sh_json_set "$f" '.notified=true'
  fi
done
exit 0
