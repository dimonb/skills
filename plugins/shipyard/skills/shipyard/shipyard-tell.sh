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
# Exit: 0 delivered or queued (the child took it), 6 UNCONFIRMED — it was typed and submitted
#       but no turn was seen to start, so it may be sitting unsent in the input box and wants
#       your eyes, 3 no live terminal for that slot, 2 usage error, 1 mailbox/backend failure.
#       6 rather than 0 on purpose: an `unconfirmed` that exits 0 is a note nobody has to
#       notice, which is the same defect class as the false `delivered` it replaced.
set -o pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shipyard-lib.sh
. "$DIR/shipyard-lib.sh"

# The header, to the first line that is not a comment. Line-numbered ranges go stale the moment
# anyone adds a paragraph above them, and this one already had: it over-ran by three lines and
# `--help` printed `set -o pipefail` back at the operator.
usage() { awk 'NR < 3 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; }

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

# --- delivery: a STATE read, sampled, never a before/after screen diff --------
# The diff this replaced could not answer the question. Typing changes the screen whether or not
# the Return took, so it was non-empty either way and an unsubmitted directive reported
# `delivered`. `adp_delivery_verdict` (shared/adapters) holds the rule and the definition of each
# verdict, including what `unconfirmed` does and does not rule out; this loop only samples.
#
# It POLLS rather than sleeping once because the sampling rate is the only thing that sets how
# often a real delivery still reads `unconfirmed`: the residual case is a turn that starts AND
# finishes between two samples, and one `sleep 3` misses a two-second turn completely.
#
# Re-folding the whole series on every sample is deliberate — the rule stays in exactly one place
# and the loop stays a sampler. Over one window that is at most a few hundred string comparisons.
#
# Both knobs are VALIDATED, not just defaulted. An unusable value here fails OPEN in the worst
# way: a non-numeric window makes the deadline arithmetic empty, `[ … -lt "" ]` errors, and the
# loop breaks after ONE sample — which is exactly the single-sleep behaviour the poll exists to
# replace, announced only by a stray test error on stderr. `_shipyard_admission_uint` already
# carries this lesson for the admission gate's knobs; the interval is deliberately fractional, so
# it gets its own pattern check rather than that helper.
CONFIRM_SECS=$(_shipyard_admission_uint "${SHIPYARD_TELL_CONFIRM_SECS:-}" 10)
case "${SHIPYARD_TELL_CONFIRM_INTERVAL:-0.5}" in
  *[!0-9.]*|''|*.*.*) echo "warning: SHIPYARD_TELL_CONFIRM_INTERVAL is not a number — using 0.5" >&2
                      CONFIRM_INTERVAL=0.5 ;;
  *)                  CONFIRM_INTERVAL=${SHIPYARD_TELL_CONFIRM_INTERVAL:-0.5} ;;
esac

# The pre-send sample. It is what lets a turn seen LATER count as one our submit started, and what
# stops a queued hint left over from an earlier send being read as being about this one.
STATES=("$(adp_turn_state "$(shipyard_capture "$SLOT")")")
shipyard_type "$SLOT" "$LINE" || { echo "error: typing into $WHERE failed" >&2; exit 1; }
sleep 1
shipyard_submit "$SLOT" || { echo "error: submitting to $WHERE failed" >&2; exit 1; }

DEADLINE=$(( $(date +%s) + CONFIRM_SECS ))
while :; do
  STATES+=("$(adp_turn_state "$(shipyard_capture "$SLOT")")")
  DELIVERY=$(adp_delivery_verdict "${STATES[@]}")
  [ "$DELIVERY" = unconfirmed ] || break
  [ "$(date +%s)" -lt "$DEADLINE" ] || break
  sleep "$CONFIRM_INTERVAL"
done
shipyard_json_set "$MB/$ID.json" --arg d "$DELIVERY" '.delivery=$d'

# A run-length census of what was ACTUALLY sampled, pre-send state first. This replaced a list of
# the causes `unconfirmed` could have had: that list was incomplete the moment the rule changed
# (it omitted the commonest one, a child mid-turn all window with no queued hint), and naming the
# evidence cannot go stale the way an enumeration does.
SAMPLED=""; _prev=""; _run=0
for _s in "${STATES[@]}"; do
  if [ "$_s" = "$_prev" ]; then _run=$((_run + 1)); continue; fi
  if [ -n "$_prev" ]; then
    if [ "$_run" -gt 1 ]; then SAMPLED="$SAMPLED,$_prev x$_run"; else SAMPLED="$SAMPLED,$_prev"; fi
  fi
  _prev="$_s"; _run=1
done
if [ "$_run" -gt 1 ]; then SAMPLED="$SAMPLED,$_prev x$_run"; else SAMPLED="$SAMPLED,$_prev"; fi
SAMPLED=${SAMPLED#,}

case "$DELIVERY" in
  queued)      echo "told ship-$SLOT ($WHERE) — $ID queued; the child is mid-turn and will take it next" ;;
  delivered)   echo "told ship-$SLOT ($WHERE) — $ID delivered" ;;
  unconfirmed) echo "warning: told ship-$SLOT ($WHERE) — $ID was typed and submitted, but no turn" >&2
               echo "         was seen to start within ${CONFIRM_SECS}s and the child never said it had" >&2
               echo "         queued it. Sampled: $SAMPLED." >&2
               echo "         THE TEXT MAY BE SITTING UNSENT IN THE INPUT BOX. Look before re-sending —" >&2
               echo "         a second send types another copy onto the first:" >&2
               echo "           $(shipyard_peek_hint "$SLOT")" >&2
               echo "         if your directive is in the box, submit what is already there:" >&2
               echo "           bash -c '. \"$DIR/shipyard-lib.sh\"; shipyard_submit \"$SLOT\"'" >&2
               echo "         This is NOT proof it went nowhere — see adp_delivery_verdict in" >&2
               echo "         shared/adapters for what the verdict does and does not rule out." >&2 ;;
  *)           # Only reachable if the shared module did not load, which leaves the verdict empty.
               # Never report that as success: an unverified directive exiting 0 silently is the
               # defect this whole path exists to remove.
               echo "error: could not read a delivery verdict for $ID (got '${DELIVERY:-<empty>}')." >&2
               echo "       the shared turn-state module may be missing — reinstall the plugin." >&2
               exit 1 ;;
esac
[ -n "$SRC" ] && echo "(in reply to $SRC — that record is not polled by the child, hence this channel)"
[ "$DELIVERY" = unconfirmed ] && exit 6
exit 0
