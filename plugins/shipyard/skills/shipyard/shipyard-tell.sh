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
#   shipyard-tell.sh --again <slot|escalation-id> "<the directive>"   send a repeat on purpose
#   shipyard-tell.sh <slot|escalation-id> --submit   submit the draft ALREADY in the box
#   shipyard-tell.sh --list                 every directive sent so far
#
# A directive whose text AND reply target (the escalation id, if one was given) are identical to
# one already recorded for that slot within SHIPYARD_TELL_DEDUPE_SECS (default 600; 0 turns the
# check off) is REFUSED with exit 9, naming the earlier record — nothing typed, nothing recorded
# (#211). It is what re-sending after an `unconfirmed` verdict produces, and a child may act on
# both copies. `--again` sends it anyway. The same text re-sent through the slot name after going
# out by escalation id (or the other way round) is NOT a repeat: the typed line differs.
#
# `--submit` types nothing: it presses Return on whatever the input box already holds and then
# takes the same delivery reading as a directive, with the same exit codes. It is the recovery for
# an `unconfirmed` directive left sitting in the box — sending the text again would type a second
# copy onto the first, and compacting would clear it (its first key is Escape). It records nothing
# in the mailbox: the draft's text is already in the directive record that put it there.
#
# An escalation id (`57-3`) is accepted as a convenience and resolves to its slot,
# so you can reply to a notice with the id you were shown.
#
# Exit: 0 delivered or queued (the child took it), 6 UNCONFIRMED — it was typed and submitted
#       but no turn was seen to start, so it may be sitting unsent in the input box and wants
#       your eyes, 3 the backend answered, does not list that slot, and is the one this fleet was
#       launched on (the child IS gone), 7 UNRESOLVED — the slot could not be resolved, because
#       the backend did not answer, or is not the one this fleet was launched on, or still lists
#       the slot (so the per-slot lookup is what failed), leaving whether the child is alive
#       UNKNOWN, 8 NO AGENT — the slot resolved and its terminal is up, but on two reads the
#       backend reports a shell prompt or an exited pane where the agent was launched, so nothing
#       was typed or recorded (3 is "no terminal at all"; 8 is "a terminal, and nobody in it" —
#       recover the child either way, and on 8 the terminal itself is still there to look at),
#       9 REPEAT — the same text, to the same reply target, was sent to this slot inside the
#       window, so nothing was typed or recorded (see above; `--again` to send it anyway),
#       2 usage error, 1 mailbox/backend failure — which is also where a dead agterm control
#       socket lands, since the backend precheck refuses before any of this runs.
#       6 rather than 0 on purpose: an `unconfirmed` that exits 0 is a note nobody has to
#       notice, which is the same defect class as the false `delivered` it replaced. 7 rather
#       than 3 for the same reason one level along: 3 tells a supervisor the child died, and the
#       reasonable response to that is teardown or relaunch — against work that may be running.
set -o pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shipyard-lib.sh
. "$DIR/shipyard-lib.sh"

# The header, to the first line that is not a comment. Line-numbered ranges go stale the moment
# anyone adds a paragraph above them, and this one already had: it over-ran by three lines and
# `--help` printed `set -o pipefail` back at the operator.
usage() { awk 'NR < 3 { next } /^#/ { sub(/^# ?/, ""); print; next } /^$/ { print; next } { exit }' "$0"; }

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
    # Only a readable record reaches jq: a FIFO matching the glob would block the listing (#253),
    # and one jq cannot parse gets a row saying so rather than no row (#197). The window between
    # the check and jq's open is the read residual #246 deferred.
    if ! shipyard_record_readable "$f"; then
      printf '%-24s %-10s %-11s %s\n' "$(printf '%q' "${f##*/}")" '?' UNREADABLE \
        'jq cannot read this record (#197)'
      continue
    fi
    jq -r '[.id, .slot, (.delivery // "?"), (.text|gsub("\n";" ")|.[0:60])] | @tsv' "$f" 2>/dev/null \
      | awk -F'\t' '{printf "%-24s %-10s %-11s %s\n", $1,$2,$3,$4}'
  done
  exit 0
fi

case "${1:-}" in -h|--help) usage; exit 0 ;; esac

AGAIN=""
[ "${1:-}" = "--again" ] && { AGAIN=1; shift; }

TARGET="${1:-}"; MSG_RAW="${2:-}"
SUBMIT_ONLY=""
# `--again` goes FIRST. In the second position, where `--submit` goes, it would otherwise be taken
# as the directive's text and typed into the child as `[supervisor directive] --again`.
if [ "$MSG_RAW" = "--again" ]; then
  echo 'usage: --again goes before the slot: shipyard-tell.sh --again <slot|escalation-id> "<directive>"' >&2
  exit 2
fi
if [ "$MSG_RAW" = "--submit" ]; then
  SUBMIT_ONLY=1; MSG=""
else
  # `@file` / `@-` bypass the caller's shell — see shipyard_payload in shipyard-lib.sh. Use it
  # for any directive containing backticks, $(...) or code.
  MSG=$(shipyard_payload "$MSG_RAW") || exit 1
fi
if [ -z "$TARGET" ] || { [ -z "$MSG" ] && [ -z "$SUBMIT_ONLY" ]; }; then
  echo 'usage: shipyard-tell.sh [--again] <slot|escalation-id> "<directive>" | <slot> --submit | --list' >&2
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
# Checked AFTER that resolution, because a record's `.slot` is written by whoever wrote the record.
shipyard_slot_check "$SLOT" || exit 2

shipyard_backend_check || exit 1
# An absence is not a death. `shipyard_where` resolves against the backend THIS process picked, and
# `auto` picks per process — so the refusal has to say which of the two it actually established
# (shipyard_absence_report classifies it and prints the operator's next move). 3 stays the
# corroborated "gone"; 7 is the one that must never be acted on as a teardown.
WHERE=$(shipyard_where "$SLOT") || {
  shipyard_absence_report "$SLOT" || exit 7
  echo "       nothing to tell; if this was an answer, the record keeps it but no one will read it." >&2
  exit 3
}

# The terminal is there — is the AGENT? A terminal outlives the agent launched into it, and then a
# directive is typed at a shell prompt: measured, `zsh: bad pattern: [supervisor`, recorded as sent
# because a shell starts no turn to confirm or deny (#172). So ask the backend which process owns
# the pane BEFORE typing, and refuse on `none` with nothing typed and nothing recorded. Two reads,
# SHIPYARD_MOTION_INTERVAL apart exactly as in the report: one `none` can be a launch caught before
# its `exec`, and the second read is paid only on the rare path where the first said `none`. No
# verdict is not `none` and goes on exactly as before; neither does `agent` prove the child alive.
# The rule is `drv_no_agent` in shared/driver, which says why each reading can be wrong.
if shipyard_no_agent "$SLOT"; then
  echo "error: $WHERE is up, but the agent launched into it is not: the backend reports a shell prompt" >&2
  echo "       or an exited pane there. Nothing was typed and nothing was recorded — a directive would" >&2
  echo "       reach a shell. Recover the child (SKILL.md, Step 5); do not compact it." >&2
  exit 8
fi

if [ -n "$SUBMIT_ONLY" ]; then
  # Nothing to record and nothing to type; ID only names what was sent, in the lines below.
  ID="the draft in its box"
else
  # --- the same text, sent again inside the window: REFUSED (#211) ----------------
  # An `unconfirmed` verdict is honest about what it cannot rule out, and what a supervisor does
  # with it is re-send — measured: two byte-identical copies of one long directive queued a minute
  # apart, and the child had to be told by hand which one to ignore. A child may act on each copy,
  # and "file this", "run one round" are not idempotent. So a directive whose text and reply target are
  # IDENTICAL to one recorded for this slot within $DEDUPE_SECS is refused before anything is typed or recorded,
  # with its own exit code (9), naming the earlier record and its verdict and printing both ways
  # on: `--submit` when the first copy is still in the box, `--again` to send a second copy on
  # purpose. Refused rather than collapsed into a silent no-op: a collapse would exit 0 having
  # sent nothing this time, the quiet kind of success this script exists not to report.
  #
  # The window is age, not verdict: an `unconfirmed` first copy may be in the box, and a
  # `delivered` or `queued` one has already been read — a second copy of either is the duplicate.
  #
  # WHAT THIS LETS A CHILD SUPPRESS, per output, since it removes a directive that used to go out
  # (AGENTS.md, "untrusted evidence may annotate an operator-facing signal, never suppress one").
  # The directive records live in the mailbox every child can write, so a child that writes a
  # record carrying the exact text of the supervisor's next directive makes that directive refuse.
  # NOT PREVENTED, and made SELF-REVEALING: the refusal is exit 9 on stderr naming the record, which
  # is one the supervisor knows whether they sent, and `--again` bypasses the check outright. It
  # needs the exact text in advance, too. `shipyard-compact.sh` always passes `--again`: its resume
  # follows an Escape that cleared the box and a compaction that cleared the child's context, so it
  # is never a duplicate of anything the child still holds, and a refused resume would leave a
  # compacted child with nothing to do.
  #
  # Also NOT closed: two tells of one text started together both scan before either records, so
  # both go out. The check is a scan, not a lock. A record jq cannot read is not compared, which is
  # the sending side.
  DEDUPE_SECS=$(knob_uint "${SHIPYARD_TELL_DEDUPE_SECS:-}" 600) \
    || echo "warning: SHIPYARD_TELL_DEDUPE_SECS is not a usable whole number — using 600" >&2
  if [ -z "$AGAIN" ] && [ "$DEDUPE_SECS" -gt 0 ]; then
    now_iso=$(shipyard_now)
    since_epoch=$(( $(date +%s) - DEDUPE_SECS ))
    # BSD `date -r <epoch>`, else GNU `date -d @<epoch>` (on GNU, `-r` takes a FILE and fails here).
    since_iso=$(date -u -r "$since_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
      || date -u -d "@$since_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
    DUP=""; DUP_AT=""; DUP_D=""
    case "$since_iso" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
      *) since_iso=""
         echo "warning: could not compute the duplicate window on this system's date — not checking for a repeat" >&2 ;;
    esac
    for f in "$MB/directive-$SLOT-"*.json; do
      [ -n "$since_iso" ] || break
      # `directive-<slot>-*` also matches slot `<slot>-2`'s records (the launcher's name for a second
      # slot from one idea): what follows the prefix must be the number alone, and the record must
      # name this slot. The same two tests as last_directive_since in the report.
      rn=${f##*/directive-$SLOT-}; rn=${rn%.json}
      case "$rn" in ''|*[!0-9]*) continue ;; esac
      shipyard_record_readable "$f" || continue
      # The reply target is part of the key: an answer to escalation s-4 is typed as
      # `[supervisor directive, re s-4] …`, so the same short text sent earlier in reply to s-3 is a
      # different line to the child, not a copy of it.
      row=$(jq -r --arg s "$SLOT" --arg t "$MSG" --arg r "$SRC" \
        'select(.slot == $s and .text == $t and ((.in_reply_to // "") == $r)) | [(.created_at // ""), (.delivery // "unknown"), (.id // "")] | @tsv' \
        "$f" 2>/dev/null) || continue
      [ -n "$row" ] || continue
      c=$(printf '%s' "$row" | cut -f1); d=$(printf '%s' "$row" | cut -f2)
      # Held to the shape its writer produces, and to [window start, now]: a record dated in the
      # future would otherwise refuse this text for as long as it stood.
      case "$c" in [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;; *) continue ;; esac
      [[ "$c" < "$since_iso" ]] && continue
      [[ "$c" > "$now_iso" ]] && continue
      case "$d" in ''|*[!a-z_-]*) d=unknown ;; esac
      if [ -z "$DUP_AT" ] || [[ "$c" > "$DUP_AT" ]]; then DUP="${f##*/}"; DUP_AT="$c"; DUP_D="$d"; fi
    done
    if [ -n "$DUP" ]; then
      DUP=${DUP%.json}
      echo "refused: ship-$SLOT was sent this exact directive at $DUP_AT UTC — $(printf '%q' "$DUP")," >&2
      echo "         delivery: $DUP_D. Nothing was typed and nothing was recorded: a second copy is what" >&2
      echo "         a retry after an unconfirmed verdict produces, and a child may act on each copy." >&2
      case "$DUP_D" in
        delivered|queued)
          echo "         The child took the first copy." >&2 ;;
        *)
          echo "         The first copy may still be in the input box — look before anything else:" >&2
          echo "           $(shipyard_peek_hint "$SLOT")" >&2
          echo "         if it is there, submit what is already in the box:" >&2
          echo "           bash $DIR/shipyard-tell.sh $SLOT --submit" >&2 ;;
      esac
      echo "         To send it again on purpose:" >&2
      # $TARGET, not $SLOT: a reply to an escalation keeps its `re <id>` line and its reply target.
      echo "           bash $DIR/shipyard-tell.sh --again $(printf '%q' "$TARGET") \"<the same directive>\"" >&2
      exit 9
    fi
  fi

  # --- record it first, so the full text survives regardless of delivery ----------
  # Both files are written by rename (policy_mailbox_write), never opened: every child can write
  # this directory, and a FIFO at either name — the `.txt` is not even probed — blocked a plain `>`
  # before anything was typed (#253).
  n=1
  while [ -e "$MB/directive-$SLOT-$n.json" ]; do n=$((n+1)); done
  ID="directive-$SLOT-$n"
  TXT="$MB/$ID.txt"
  printf '%s\n' "$MSG" | policy_mailbox_write "$TXT"

  # Status is deliberately NOT "pending": the escalation viewers count every pending
  # record as an open escalation, and a directive is not one.
  REC=$(jq -n --arg id "$ID" --arg slot "$SLOT" --arg text "$MSG" --arg src "$SRC" \
        --arg now "$(shipyard_now)" --arg txt "$TXT" \
    '{id:$id, slot:$slot, kind:"directive", text:$text, in_reply_to:$src,
      text_file:$txt, created_at:$now, status:"sent", delivery:"unknown"}') \
    && printf '%s\n' "$REC" | policy_mailbox_write "$MB/$ID.json" \
    || { echo "error: failed to record the directive" >&2; exit 1; }

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
fi

# --- delivery: a STATE read, sampled, never a before/after screen diff --------
# The diff this replaced could not answer the question. Typing changes the screen whether or not
# the Return took, so it was non-empty either way and an unsubmitted directive reported
# `delivered`. `adp_delivery_verdict` (shared/adapters) holds the rule and the definition of each
# verdict, including what `unconfirmed` does and does not rule out. `adp_delivery_poll` beside it
# is the sampling loop, and says why it polls rather than sleeping once.
#
# Both knobs are VALIDATED, not just defaulted. An unusable value here fails OPEN in the worst
# way: a non-numeric window makes the deadline arithmetic empty, `[ … -lt "" ]` errors, and the
# loop breaks after ONE sample — which is exactly the single-sleep behaviour the poll exists to
# replace, announced only by a stray test error on stderr.
#
# BOTH RULES NOW LIVE IN `shared/knobs`, and the correction matters more than the move. This file
# used to say that `_shipyard_admission_uint` "already carries this lesson" and that the interval
# "gets its own pattern check rather than that helper". Neither sentence was true of what the code
# did, and each hid a defect that shipped:
#
#   * the uint helper has no base-ten normalisation, so `SHIPYARD_TELL_CONFIRM_SECS=08` passed its
#     all-digits test and then made `$(( … + CONFIRM_SECS ))` an invalid-octal EXPANSION. MEASURED
#     against the pre-fix script rather than assumed — three earlier versions of this sentence said
#     it killed the shell and none was right: at top level bash prints the error, leaves `DEADLINE`
#     EMPTY and carries on, so `[ "$(date +%s)" -lt "" ]` errors too and the loop breaks after ONE
#     sample. The verdict still prints; what is gone is the poll, silently restored to the
#     single-sleep behaviour it exists to replace — so a delivered directive reads `unconfirmed`,
#     and the supervisor's next move is to re-send a second copy onto the first;
#   * the interval's `0|0.|0.0|.0` pattern ENUMERATED zero instead of testing for a non-zero
#     digit, so `00`, `000`, `0.00`, `.00` and `000.000` all passed and made `sleep` a no-op.
#
# `council say` asks the same question and had both defects identically, which is what earned the
# shared home. The wording stays here, because naming the operator's own variable is this skill's
# business and not the module's.
CONFIRM_SECS=$(knob_uint "${SHIPYARD_TELL_CONFIRM_SECS:-}" 10) \
  || echo "warning: SHIPYARD_TELL_CONFIRM_SECS is not a usable whole number — using 10" >&2
CONFIRM_INTERVAL=$(knob_interval "${SHIPYARD_TELL_CONFIRM_INTERVAL:-}" 0.5) \
  || echo "warning: SHIPYARD_TELL_CONFIRM_INTERVAL is not a usable positive number — using 0.5" >&2

# The settle delay between typing and submitting, one second by default and NOT being changed:
# a client needs a moment to register the typed line before Enter, and submitting into a box the
# client has not caught up with is how a directive goes nowhere.
#
# `_DELAY`, deliberately, and not `_SECS` or `_INTERVAL`: in this plugin `_SECS` names a window
# that is polled and `_INTERVAL` names the sleep BETWEEN two samples (which is what `knob_interval`
# is documented as), and this is neither — it is a one-shot pause before a single action. The
# `_DELAY` suffix is the existing spelling for exactly that here; `shipyard-continuity.sh` already
# carries nine of them, one of them `_SETTLE_DELAY`. Those are private test seams and this one is
# operator-facing, hence no leading underscore.
#
# It is a knob because `t16-tell-knobs` runs this script fourteen times against a faked backend
# where nothing has to settle at all — thirteen of that file's forty-four seconds, and with the
# rest of #203 done that file is the shipyard suite's critical path. `knob_interval` validates it:
# a one-shot `sleep` has the same two failure modes as a polled one (every spelling of zero makes
# it a no-op, a bare `.` makes it error), and zero here is a legitimate value only for a test.
SETTLE_DELAY=$(knob_interval "${SHIPYARD_TELL_SETTLE_DELAY:-}" 1) \
  || echo "warning: SHIPYARD_TELL_SETTLE_DELAY is not a usable positive number — using 1" >&2

# The pre-send sample. It is what lets a turn seen LATER count as one our submit started, and what
# stops a queued hint left over from an earlier send being read as being about this one.
PRE=$(adp_turn_sample shipyard_capture "$SLOT")
if [ -z "$SUBMIT_ONLY" ]; then
  shipyard_type "$SLOT" "$LINE" || { echo "error: typing into $WHERE failed" >&2; exit 1; }
  sleep "$SETTLE_DELAY"
fi
shipyard_submit "$SLOT" || { echo "error: submitting to $WHERE failed" >&2; exit 1; }

# The loop and the census of what it sampled are `adp_delivery_poll` (shared/adapters), which
# `council say` runs too. An empty answer is the `*)` arm below: never success.
POLLED=$(adp_delivery_poll "$CONFIRM_SECS" "$CONFIRM_INTERVAL" "$PRE" shipyard_capture "$SLOT") || POLLED=""
DELIVERY=${POLLED%%"$(printf '\t')"*}; SAMPLED=${POLLED#*"$(printf '\t')"}
[ -n "$SUBMIT_ONLY" ] || shipyard_json_set "$MB/$ID.json" --arg d "$DELIVERY" '.delivery=$d'

case "$DELIVERY" in
  queued)      echo "told ship-$SLOT ($WHERE) — $ID queued; the child is mid-turn and will take it next" ;;
  delivered)   echo "told ship-$SLOT ($WHERE) — $ID delivered" ;;
  unconfirmed) if [ -n "$SUBMIT_ONLY" ]; then
                 echo "warning: pressed Return in ship-$SLOT ($WHERE), but no turn was seen to start" >&2
                 echo "         within ${CONFIRM_SECS}s and the child never said it had queued anything." >&2
                 echo "         Sampled: $SAMPLED. Look at the box before doing anything else:" >&2
                 echo "           $(shipyard_peek_hint "$SLOT")" >&2
                 echo "         a draft still there was not taken — do NOT compact, its first key is" >&2
                 echo "         Escape, which clears the box (SKILL.md, Step 5, 2b)." >&2
               else
                 echo "warning: told ship-$SLOT ($WHERE) — $ID was typed and submitted, but no turn" >&2
                 echo "         was seen to start within ${CONFIRM_SECS}s and the child never said it had" >&2
                 echo "         queued it. Sampled: $SAMPLED." >&2
                 echo "         THE TEXT MAY BE SITTING UNSENT IN THE INPUT BOX. Look before re-sending —" >&2
                 if [ "$DEDUPE_SECS" -gt 0 ]; then
                   echo "         the same text is refused for ${DEDUPE_SECS}s (exit 9), and --again types" >&2
                   echo "         another copy onto the first:" >&2
                 else
                   echo "         a second send types another copy onto the first:" >&2
                 fi
                 echo "           $(shipyard_peek_hint "$SLOT")" >&2
                 echo "         if your directive is in the box, submit what is already there:" >&2
                 echo "           bash $DIR/shipyard-tell.sh $SLOT --submit" >&2
               fi
               echo "         This is NOT proof it went nowhere — see adp_delivery_verdict in" >&2
               echo "         shared/adapters for what the verdict does and does not rule out." >&2 ;;
  *)           # Only reachable if the shared module did not load, which leaves the verdict empty.
               # Never report that as success: an unverified directive exiting 0 silently is the
               # defect this whole path exists to remove.
               echo "error: could not read a delivery verdict for $ID (got '${DELIVERY:-<empty>}')." >&2
               echo "       the shared turn-state module may be missing — reinstall the plugin." >&2
               exit 1 ;;
esac
[ -n "$SRC" ] && [ -z "$SUBMIT_ONLY" ] && echo "(in reply to $SRC — that record is not polled by the child, hence this channel)"
[ "$DELIVERY" = unconfirmed ] && exit 6
exit 0
