#!/usr/bin/env bash
# t9f — a room is closed when its RECORD says so, never because a `decide` message exists.
#
# `verdict` and `status` exit 0 for a closed room and non-zero for a live one, and that exit
# code is the supervising contract: it is what a watching session branches on to decide the
# room is finished. So the failure this file pins is not cosmetic. A bare
# `{"act":"decide"}` written into any lane used to make the room report `decided` with rc 0
# while holding a live proposal and having written no decision record at all — a room that
# reads as finished, from the outside, with nothing anywhere saying otherwise.
#
# The cause was a reader, not an author: `c_slurp_raw` returns 0 for a MISSING file, and the
# verdict mapped that 0 onto `decided`. It reproduces identically with an honest `.from`,
# which is why it is here and not in t9e — deriving a message's author does not touch it.
#
# BOTH directions are asserted, and the second matters as much as the first: the cheap way
# to pass the first half is to stop believing `board/status` at all, which would break every
# room that legitimately closed. A test that pinned only "does not close" would let that
# through, and the inversion would surface as rooms that never finish.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
R="$COUNCIL_TEST_ROOT/t9f-decided-needs-record"; rm -rf "$R"
export COUNCIL_ROOM="$R" ROOM="$R"
fail=0

fresh() { rm -rf "$R"; mkroom "$R" a b; echo "Is this room finished?" > "$R/agenda.md"; }

# `verdict`'s word and its exit code, which are two separate assertions: the word is for a
# human reading a terminal, the code is what a supervisor branches on.
verd() { local v rc; v=$(bash "$CLI" verdict 2>/dev/null | cut -d' ' -f1); rc=$?; printf '%s %s' "$v" "$rc"; }
stat_rc() { bash "$CLI" status >/dev/null 2>&1; printf '%s' "$?"; }
# say_floor prints who spoke; these cases do not care, and letting it through interleaves
# stray peer names with the assertions.
floor_say() { say_floor "$@" >/dev/null; }
id_of() { bash "$CLI" order 2>/dev/null | jq -r --arg a "$1" 'select(.act == $a) | .id' | head -1; }
refs_to() { jq -c -n --arg i "$1" '[$i]'; }

# A decide message written straight into a lane — what any participant can produce, and what
# a genuine `council.sh decide` never produces on its own, because it writes the record first.
decide_msg() { # <lane> <claimed-from>
  jq -n --arg id "$1-9" --arg from "$2" \
    '{id:$id,from:$from,lamport:9,deps:{},act:"decide",refs:[],to:["*"],
      hand:false,turn:null,round:null,text:"decided",created_at:"test",sent_ms:0}' \
    > "$(printf '%s/lane/%s/000009.json' "$ROOM" "$1")"
  printf '9' > "$ROOM/state/$1.seq"
}

# --- 1. a decide message with no record closes nothing ---------------------------
# The issue's third reproduction. Run twice: once with a forged author and once with an
# honest one, because they are the SAME defect and asserting only the forged case would
# credit this to author derivation and leave the real mechanism untested.
for claim in a b; do
  fresh
  floor_say propose '[]' "Adopt the thing."
  decide_msg b "$claim"
  read -r v rc <<<"$(verd)"
  src=$([ "$claim" = b ] && echo honest || echo forged)
  if [ "$v" != decided ] && [ "$rc" != 0 ] && [ "$(stat_rc)" != 0 ] \
     && [ ! -f "$R/board/decision.md" ]; then
    echo "ok   a record-less decide ($src author) left the room open: verdict=$v rc=$rc"
  else
    echo "FAIL a record-less decide ($src author) closed the room: verdict=$v rc=$rc status_rc=$(stat_rc)"; fail=1
  fi
done

# --- 2. the room still holds what it really holds --------------------------------
# Reporting `deliberating` while silently dropping the live proposal would satisfy case 1
# and be just as wrong.
live=$(bash "$CLI" verdict --json 2>/dev/null | jq -r .live)
if [ "$live" = 1 ]; then echo "ok   the live proposal is still on the table"
else echo "FAIL the proposal vanished: live=$live (want 1)"; fail=1; fi

# --- 3. an honestly decided room still reads as decided, rc 0 --------------------
# The regression guard. `decide` writes the record, then board/status, then the message.
fresh
p=$(say_floor propose '[]' "Adopt the thing.")
# A lap of silence with no open objection is what makes the verdict ripe.
floor_say msg '[]' "Nothing further from me."
floor_say msg '[]' "Nor from me."
COUNCIL_ROOM="$R" COUNCIL_ME="$p" bash "$CLI" decide >/dev/null 2>&1
read -r v rc <<<"$(verd)"
if [ "$v" = decided ] && [ "$rc" = 0 ] && [ "$(stat_rc)" = 0 ] && [ -f "$R/board/decision.md" ]; then
  echo "ok   an honestly decided room still reads decided, rc 0"
else
  echo "FAIL a real decision no longer reads as closed: verdict=$v rc=$rc status_rc=$(stat_rc) record=$([ -f "$R/board/decision.md" ] && echo yes || echo no)"; fail=1
fi

# --- 4. an honest `unresolved` still reads back as unresolved, rc 0 --------------
# The other closed state, and the one the repo's own law names: a room closed as
# `unresolved` must read back as `unresolved`, not as a live room and not as `decided`.
fresh
floor_say propose '[]' "Adopt the thing."
floor_say object "$(refs_to "$(id_of propose)")" "No."
COUNCIL_ROOM="$R" COUNCIL_ME=a bash "$CLI" decide --force >/dev/null 2>&1
read -r v rc <<<"$(verd)"
if [ "$v" = unresolved ] && [ "$rc" = 0 ] && [ -f "$R/board/decision.md" ]; then
  echo "ok   a forced unresolved record still reads back as unresolved, rc 0"
else
  echo "FAIL an unresolved close did not read back: verdict=$v rc=$rc record=$([ -f "$R/board/decision.md" ] && echo yes || echo no)"; fail=1
fi

# --- 5. only the two words decide writes are believed -----------------------------
# board/status sits in the room like every other file, so a value neither `decide` nor this
# reader recognises is treated as ABSENT — the rule every other untrusted room input follows
# — rather than passed through as a verdict of its own invention.
for bogus in 'yes' '0' 'DECIDED' ''; do
  fresh
  floor_say propose '[]' "Adopt the thing."
  decide_msg b b
  printf '%s' "$bogus" > "$R/board/status"
  read -r v rc <<<"$(verd)"
  # Assert the room's REAL verdict, not merely "not one of the two closed words". Excluding
  # `decided|unresolved` is satisfied by a reader that passes board/status through verbatim,
  # which is exactly what this case exists to forbid: against the old reader it printed
  # `ok  board/status='yes' was treated as absent (verdict=yes)` — a pass whose own message
  # contradicts itself. It is also satisfied by an empty $v, i.e. a CLI that failed outright.
  # This room holds one live proposal and no open objection, so `deliberating` is the answer.
  if [ "$v" = deliberating ] && [ "$rc" = 1 ]; then
    echo "ok   board/status='$bogus' was treated as absent (verdict=$v rc=$rc)"
  else
    echo "FAIL board/status='$bogus' was not treated as absent: verdict=$v rc=$rc (want deliberating rc 1)"; fail=1
  fi
done

# --- 6. a zero-byte record is not a record, in EVERY reader -----------------------
# `v_decide` opens the record with `> "$out"`, which creates it at zero bytes the instant the
# redirect opens, so a decide that dies part-way leaves an empty file behind. Both readers of
# that file must agree it is not a record — and `decision`'s exit 0 is what the protocol tells
# every participant to stop on, so a reader that says "yes" here stops the whole room on an
# open one. The two readers were fixed one round apart, which is exactly the drift this file
# exists to catch.
fresh
floor_say propose '[]' "Adopt the thing."
: > "$R/board/decision.md"
printf 'decided' > "$R/board/status"
read -r v rc <<<"$(verd)"
bash "$CLI" decision >/dev/null 2>&1; drc=$?
if [ "$v" = deliberating ] && [ "$rc" = 1 ] && [ "$drc" != 0 ]; then
  echo "ok   a zero-byte record reads as no record in both verdict and decision (rc $rc/$drc)"
else
  echo "FAIL a zero-byte record was believed: verdict=$v rc=$rc decision_rc=$drc"; fail=1
fi

[ "$fail" = 0 ] && echo "t9f PASS" || echo "t9f FAIL"
exit $fail
