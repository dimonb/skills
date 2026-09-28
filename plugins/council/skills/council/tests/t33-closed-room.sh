#!/usr/bin/env bash
# t33 — a closed room's answers agree with its record (#176).
#
# Measured in a live room: an objection landed 11 s after `decide`. The record said "there were no
# objections", and `claims` and `rooms` reported one open, for ever. Three parts close that:
#   1  `send` refuses a non-hand message into a room whose record is written: exit 8, nothing on
#      the lane;
#   2  what still reaches the lane after the close (a `--hand` claim, or a send that passed the
#      check just before the record landed) is listed "after the close" and never counted OPEN,
#      because readers build a closed room's graph from the snapshot `decide` wrote;
#   3  the snapshot can MOVE a claim between the two sections, never hide one.
# Plus the scenario #295 re-homed onto #176: an amend closes objections only on the proposal it
# amends.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_helpers.sh
. "$DIR/_helpers.sh"

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}
has() { grep -qF -- "$2" <<<"$1" && printf yes || printf no; }
lane_n() { ls "$ROOM/lane/$1" 2>/dev/null | wc -l | tr -d ' '; }
open_n() { bash "$CLI" claims | sed -n 's/^open objections: //p'; }

# --- 1. a DECIDED room refuses a claim -------------------------------------------------------------
ROOM="$COUNCIL_TEST_ROOT/t33d"; mkroom "$ROOM" a b; export COUNCIL_ROOM="$ROOM"
say_floor propose '[]' "Ship it." >/dev/null
say_floor msg '[]' "Fine." >/dev/null
say_floor msg '[]' "Fine by me." >/dev/null
ok "1: setup converged"                              ready-to-decide "$(verdict1)"
COUNCIL_ME=a bash "$CLI" decide >/dev/null 2>&1
ok "1: the room is decided"                          decided "$(cat "$ROOM/board/status")"
ok "1: decide wrote a snapshot of what it recorded"  '["a-1","b-1","b-2"]' \
   "$(jq -c '[.[].id]' "$ROOM/board/closed-over" 2>/dev/null)"
# Sent by the seat that holds the floor, so no other refusal (exit 6) can stand in for this one.
fl=$(bash "$CLI" floor | sed -n 's/.*floor=\([^ ]*\).*/\1/p')
nf=$(lane_n "$fl")
err=$(COUNCIL_ME="$fl" bash "$CLI" send --act object --refs '["a-1"]' "Too late, but no." 2>&1 >/dev/null); rc=$?
ok "1: a non-hand send into a decided room exits 8"  8 "$rc"
ok "1: ...and puts nothing on the lane"              "$nf" "$(lane_n "$fl")"
nb=$(lane_n b)
ok "1: ...and sends the seat to the record"          yes "$(has "$err" "council.sh decision")"
ok "1: ...and tells it not to retry"                 yes "$(has "$err" "do not retry")"

# --- 2. what still lands after the close is listed apart, never OPEN ------------------------------
COUNCIL_ME=b bash "$CLI" send --hand --act object --refs '["a-1"]' "A hand raised after the close." >/dev/null
ok "2: a --hand send is still accepted"              $((nb + 1)) "$(lane_n b)"
c=$(bash "$CLI" claims)
ok "2: claims lists it after the close"              yes "$(has "$c" "⊘ b-3 (b) object: A hand raised after the close.")"
ok "2: ...under its own heading"                     yes "$(has "$c" "after the close, or outside the snapshot of the record")"
ok "2: ...never as OPEN"                             no  "$(has "$c" "✗ OPEN")"
ok "2: ...and counts no open objection"              0   "$(open_n)"
ok "2: verdict --json agrees"                        0   "$(bash "$CLI" verdict --json | jq -r .open)"
ok "2: the record still says there were none"        yes "$(has "$(cat "$ROOM/board/decision.md")" "(there were no objections)")"
# A send that passed the check a moment before the record landed reaches the lane by the normal
# write; raw_msg stands for it.
raw_msg a 9 99 null object '["a-1"]' "Raced the close."
c=$(bash "$CLI" claims)
ok "2: a claim that raced the close is listed too"   yes "$(has "$c" "⊘ a-9 (a) object: Raced the close.")"
ok "2: ...and still nothing is OPEN"                 0   "$(open_n)"
# The announcement follows the record by construction, so it is outside the snapshot; it must
# still be found.
ok "2: the decide announcement is still found"       true "$(bash "$CLI" verdict --json | jq -r '.decide_msg != null')"

# --- 3. the snapshot moves claims, it never hides one ---------------------------------------------
cp "$ROOM/board/closed-over" "$ROOM/co.bak"
printf '[]\n' > "$ROOM/board/closed-over"
c=$(bash "$CLI" claims)
ok "3: an emptied snapshot still prints the proposal" yes "$(has "$c" "⊘ a-1 (a) propose: Ship it.")"
ok "3: ...and every late objection"                   yes "$(has "$c" "⊘ b-3 (b) object:")"
# The status block is the output an operator watches, so late claims are shown there too.
s=$(bash "$CLI" status 2>/dev/null)
ok "3: status shows the late claims too"              yes "$(has "$s" "⊘ after the close b-3 (b) object:")"
printf 'not json' > "$ROOM/board/closed-over"
c=$(bash "$CLI" claims)
ok "3: an unreadable snapshot falls back to the whole log" 2 "$(open_n)"
ok "3: ...where the late objections read OPEN, as before"  yes "$(has "$c" "✗ OPEN b-3")"
printf '[]\n[]\n' > "$ROOM/board/closed-over"
ok "3: a snapshot of two documents is refused as a whole" 2 "$(open_n)"
rm -f "$ROOM/board/closed-over"
ok "3: a room with no snapshot reads as before"       2 "$(open_n)"
mv "$ROOM/co.bak" "$ROOM/board/closed-over"

# --- 4. an UNRESOLVED room refuses too, and a re-force takes in the late claims --------------------
ROOM="$COUNCIL_TEST_ROOT/t33u"; mkroom "$ROOM" a b; export COUNCIL_ROOM="$ROOM"
say_floor propose '[]' "Do X." >/dev/null
COUNCIL_ME=b bash "$CLI" send --hand --act object --refs '["a-1"]' "Before the close." >/dev/null
COUNCIL_ME=a bash "$CLI" decide --force >/dev/null 2>&1
ok "4: the room is unresolved"                       unresolved "$(cat "$ROOM/board/status")"
ok "4: ...with the objection the record left open"   1 "$(open_n)"
fl=$(bash "$CLI" floor | sed -n 's/.*floor=\([^ ]*\).*/\1/p')
err=$(COUNCIL_ME="$fl" bash "$CLI" send --act object --refs '["a-1"]' "No." 2>&1 >/dev/null); rc=$?
ok "4: a non-hand send into an unresolved room exits 8" 8 "$rc"
ok "4: ...and names where the argument goes"         yes "$(has "$err" "belongs in a new room")"
# A claim after the close can close nothing: the record left b-1 open, so it stays open.
COUNCIL_ME=b bash "$CLI" send --hand --act withdraw --refs '["b-1"]' "Withdrawn, too late." >/dev/null
COUNCIL_ME=b bash "$CLI" send --hand --act object --refs '["a-1"]' "No, by hand." >/dev/null
ok "4: a late withdraw does not close b-1"           '["b-1"]' "$(bash "$CLI" claims --raw | jq -c '[.open[].id]')"
ok "4: ...and the late objection is not OPEN"        1 "$(open_n)"
COUNCIL_ME=a bash "$CLI" decide --force >/dev/null 2>&1
ok "4: a re-force records the late claims"           yes "$(has "$(cat "$ROOM/board/decision.md")" "No, by hand.")"
ok "4: ...and then counts them, as the record does"  '["b-3"]' "$(bash "$CLI" claims --raw | jq -c '[.open[].id]')"
# The record's own Objections section, not only its transcript: the re-force builds its graph
# over the whole log, so the late withdraw closes b-1 there and b-3 is left open.
rec=$(cat "$ROOM/board/decision.md")
ok "4: the rewritten record closes b-1 by the withdraw"  yes "$(has "$rec" 'closed by `b-2` — withdraw from b')"
ok "4: ...and leaves b-3 open"                           yes "$(has "$rec" '* `b-3` from b: No, by hand.')"

# --- 4b. a PARTIAL snapshot cannot hide a claim ----------------------------------------------------
# Kept objection, dropped proposal: the objection used to be printed nowhere and counted nowhere.
ROOM="$COUNCIL_TEST_ROOT/t33p"; mkroom "$ROOM" a b c; export COUNCIL_ROOM="$ROOM"
raw_msg a 1 1 0 propose '[]'       "P."
raw_msg b 1 2 1 object  '["a-1"]'  "Objection kept in the snapshot."
raw_msg c 1 3 2 amend   '["b-1"]'  "Amend of it."
printf 'unresolved' > "$ROOM/board/status"; printf '# record\n' > "$ROOM/board/decision.md"
printf '[{"from":"b","id":"b-1"},{"from":"c","id":"c-1"}]\n' > "$ROOM/board/closed-over"
c=$(bash "$CLI" claims)
ok "4b: the dropped proposal is late"                yes "$(has "$c" "⊘ a-1 (a) propose: P.")"
ok "4b: ...and so is the objection it orphaned"      yes "$(has "$c" "⊘ b-1 (b) object: Objection kept in the snapshot.")"
ok "4b: ...and the amend that orphaned in turn"      yes "$(has "$c" "⊘ c-1 (c) amend: Amend of it.")"

# --- 5. an amend closes objections only on the proposal it amends (re-homed from #295) -------------
ROOM="$COUNCIL_TEST_ROOT/t33a"; mkroom "$ROOM" a b c; export COUNCIL_ROOM="$ROOM"
g() { bash "$CLI" claims --raw; }
raw_msg a 1 1 0 propose '[]'            "A."
raw_msg b 1 2 1 object  '["a-1"]'       "b objects to A."
raw_msg c 1 3 2 propose '[]'            "C."
raw_msg b 2 4 3 object  '["c-1"]'       "b objects to C."
raw_msg c 2 5 4 withdraw '["c-1"]'      "C withdrawn."
raw_msg b 3 6 5 amend   '["b-2","b-1"]' "An amend owned by C, through b-2."
ok "5: the amend is C's, not A's"                    '[]' "$(g | jq -c '.proposals[] | select(.id == "a-1") | .amends')"
ok "5: it does NOT close A's objection"              'null' "$(g | jq -c '.proposals[] | select(.id == "a-1") | .objections[0].closed_by')"
ok "5: ...so A has an open objection"                '["b-1"]' "$(g | jq -c '[.open[].id]')"
# A full lap with nothing new: before this rule the room read ready-to-decide here, with A the
# decision rendered un-amended. Now A's objection stands and the room is stuck.
raw_msg a 2 7 6 msg '[]' "Nothing to add."
raw_msg b 4 8 7 msg '[]' "Nor I."
raw_msg c 3 9 8 msg '[]' "Nor I."
ok "5: ...so after a quiet lap the room is stuck, not ripe" stuck "$(verdict1)"
# The shapes #295 fixed still close.
ROOM="$COUNCIL_TEST_ROOT/t33b"; mkroom "$ROOM" a b; export COUNCIL_ROOM="$ROOM"
raw_msg a 1 1 0 propose '[]'            "A."
raw_msg b 1 2 1 object  '["a-1"]'       "No."
raw_msg a 2 3 2 amend   '["b-1"]'       "A, amended."
ok "5: an amend naming only the objection closes it" 'a-2' "$(g | jq -r '.proposals[0].objections[0].closed_by')"
ok "5: ...and carries its proposal"                  '["a-2"]' "$(g | jq -c '.proposals[0].amends')"
raw_msg b 2 4 3 object  '["a-1"]'       "Still no."
raw_msg a 3 5 4 amend   '["a-1","b-2"]' "A, amended again."
ok "5: an amend naming its proposal still closes"    'a-3' "$(g | jq -r '.proposals[0].objections[1].closed_by')"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then printf 't33-closed-room: %d checks, all passed\n' "$CHECKS"; exit 0; fi
printf 't33-closed-room: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"
exit 1
