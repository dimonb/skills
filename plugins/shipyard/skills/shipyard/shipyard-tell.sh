#!/usr/bin/env bash
# shipyard-tell.sh — PARENT watcher -> CHILD ship session. An UNSOLICITED directive.
#
# The mailbox (shipyard-ask.sh / shipyard-answer.sh) is a child-initiated channel: the child
# creates a record and polls it, the parent fills in the answer. That covers
# `question` and `decision` — but NOT:
#   * a `notice`, which is fire-and-forget: the child never polls it, so an answer
#     written onto a notice is read by nobody;
#   * an already-consumed (`done`) record, for the same reason;
#   * anything the parent wants to say that the child never asked about
#     ("also fix the MR description", "stop, don't merge yet").
#
# For those, the only channel that actually reaches a running child is its own
# terminal: Claude Code accepts a typed message and queues it if it is mid-turn. That
# is what this script does — through the backend layer, so it works the same on an
# agterm session and a tmux window — plus it records the directive in the mailbox so
# the exchange stays auditable.
#
# Usage (parent side, from anywhere in the repo):
#   shipyard-tell.sh <slot|escalation-id> "<the directive>"
#   shipyard-tell.sh --list                 every directive sent so far
#
# An escalation id (`57-3`) is accepted as a convenience and resolves to its slot,
# so you can reply to a notice with the id you were shown.
#
# Exit: 0 delivered (queued or accepted), 3 no live terminal for that slot,
#       2 usage error, 1 mailbox/backend failure.
set -o pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shipyard-lib.sh
. "$DIR/shipyard-lib.sh"

usage() { sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'; }

# How long a one-line directive may get before we send a pointer to the full text
# instead of the text itself (a very long send-keys line is fragile to read back).
MAXLINE=${SHIPYARD_TELL_MAXLINE:-1200}

MB=$(shipyard_mailbox_ensure) || { echo "error: not inside a git repository" >&2; exit 1; }

if [ "${1:-}" = "--list" ]; then
  shopt -s nullglob
  files=("$MB"/directive-*.json)
  if [ ${#files[@]} -eq 0 ]; then echo "_no directives sent_"; exit 0; fi
  printf '%-24s %-10s %-11s %s\n' ID SLOT DELIVERY TEXT
  for f in "${files[@]}"; do
    jq -r '[.id, .slot, (.delivery // "?"), (.text|gsub("\n";" ")|.[0:60])] | @tsv' "$f" 2>/dev/null \
      | awk -F'\t' '{printf "%-24s %-10s %-11s %s\n", $1,$2,$3,$4}'
  done
  exit 0
fi

case "${1:-}" in -h|--help) usage; exit 0 ;; esac

TARGET="${1:-}"; MSG_RAW="${2:-}"
# `@file` / `@-` bypass the caller's shell — see shipyard_payload in shipyard-lib.sh. Use it
# for any directive containing backticks, $(...) or code.
MSG=$(shipyard_payload "$MSG_RAW") || exit 1
if [ -z "$TARGET" ] || [ -z "$MSG" ]; then
  echo 'usage: shipyard-tell.sh <slot|escalation-id> "<directive>"   |   shipyard-tell.sh --list' >&2
  exit 2
fi

# An escalation id resolves to its slot; anything else IS the slot. Checked in this
# order because a text slot may itself contain dashes (`add-x-to-y`).
SLOT="$TARGET"
SRC=""
if [ -f "$MB/$TARGET.json" ]; then
  s=$(jq -r '.slot // empty' "$MB/$TARGET.json" 2>/dev/null)
  [ -n "$s" ] && { SLOT="$s"; SRC="$TARGET"; }
fi

shipyard_backend_check || exit 1
WHERE=$(shipyard_where "$SLOT") || {
  echo "error: no live terminal \`ship-$SLOT\` in $(shipyard_container_kind) \`$(shipyard_container)\` — nothing to tell." >&2
  echo "       the child is gone; if this was an answer, the record keeps it but no one will read it." >&2
  exit 3
}

# --- record it first, so the full text survives regardless of delivery ----------
n=1
while [ -e "$MB/directive-$SLOT-$n.json" ]; do n=$((n+1)); done
ID="directive-$SLOT-$n"
TXT="$MB/$ID.txt"
printf '%s\n' "$MSG" >"$TXT"

# Status is deliberately NOT "pending": the escalation viewers count every pending
# record as an open escalation, and a directive is not one.
jq -n --arg id "$ID" --arg slot "$SLOT" --arg text "$MSG" --arg src "$SRC" \
      --arg now "$(shipyard_now)" --arg txt "$TXT" \
  '{id:$id, slot:$slot, kind:"directive", text:$text, in_reply_to:$src,
    text_file:$txt, created_at:$now, status:"sent", delivery:"unknown"}' \
  >"$MB/$ID.json" || { echo "error: failed to record the directive" >&2; exit 1; }

# --- flatten to one line: a literal newline would submit the message early ------
ONELINE=$(printf '%s' "$MSG" | tr '\n' ' ' | tr -s ' ')
PREFIX="[supervisor directive"
[ -n "$SRC" ] && PREFIX="$PREFIX, re $SRC"
PREFIX="$PREFIX]"
if [ "${#ONELINE}" -gt "$MAXLINE" ]; then
  LINE="$PREFIX The full text is in $TXT — read that file and follow it. First line: $(printf '%s' "$ONELINE" | cut -c1-200)…"
else
  LINE="$PREFIX $ONELINE"
fi

BEFORE=$(shipyard_capture "$SLOT")
shipyard_type "$SLOT" "$LINE" || { echo "error: typing into $WHERE failed" >&2; exit 1; }
sleep 1
shipyard_submit "$SLOT" || { echo "error: submitting to $WHERE failed" >&2; exit 1; }
sleep 3
AFTER=$(shipyard_capture "$SLOT")

# Delivery check. Claude Code either starts working on it, or shows the queued-message
# hint when it is mid-turn. An unchanged pane means the keys went nowhere.
DELIVERY=delivered
if printf '%s' "$AFTER" | grep -q 'queued message'; then
  DELIVERY=queued
elif [ "$BEFORE" = "$AFTER" ]; then
  DELIVERY=unconfirmed
fi
shipyard_json_set "$MB/$ID.json" --arg d "$DELIVERY" '.delivery=$d'

case "$DELIVERY" in
  queued)      echo "told ship-$SLOT ($WHERE) — $ID queued; the child is mid-turn and will take it next" ;;
  delivered)   echo "told ship-$SLOT ($WHERE) — $ID delivered" ;;
  unconfirmed) echo "warning: told ship-$SLOT ($WHERE) — $ID sent but the screen did not change." >&2
               echo "         look inside: $(shipyard_peek_hint "$SLOT")" >&2 ;;
esac
[ -n "$SRC" ] && echo "(in reply to $SRC — that record is not polled by the child, hence this channel)"
exit 0
