#!/usr/bin/env bash
# t9 — the lap counter: "nothing new for N turns (lap M)".
#
# N must be the number of turns that went by CARRYING NO NEW CLAIM. It is the only TIMING
# input to `stuck` and to `ready-to-decide` -- the objection and proposal counts are the
# other half -- and a supervisor is told to read it at a glance, so an off-by-one here is
# not cosmetic: it fires the alarm half a lap early, and it fires it on a lap that did
# contain a fresh objection.
#
# Two peers on purpose. With a lap of 2, one turn early is HALF a lap, so the error is
# unmissable; at three peers the same bug hides inside a plausible-looking number.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
: "${COUNCIL_TEST_ROOT:=$(mktemp -d)}"   # set and reaped by _helpers.sh; this is the standalone case
fail=0

want()  { # <what> <expected-since> <expected-verdict>
  local j got_s got_v
  j=$(bash "$CLI" verdict --json)
  got_s=$(printf '%s' "$j" | jq -r .since_last_claim)
  got_v=$(printf '%s' "$j" | jq -r .verdict)
  if [ "$got_s" = "$2" ] && [ "$got_v" = "$3" ]; then
    printf '  ok   %-34s nothing new for %s turns, %s\n' "$1" "$got_s" "$got_v"
  else
    printf '  FAIL %-34s want (%s, %s) got (%s, %s)\n' "$1" "$2" "$3" "$got_s" "$got_v"
    fail=1
  fi
}

echo "--- token mode, 2 peers: a claim just made is not silence ---"
R="$COUNCIL_TEST_ROOT/t9-token"; rm -rf "$R"
mkroom "$R" a b
export COUNCIL_ROOM="$R" ROOM="$R"
echo "Should the room keep a lap counter?" > "$R/agenda.md"

prop=$(say_floor propose '[]' "Count the lap over claims, not over turns.")
# The proposal was posted THIS turn. Nothing has gone by since it.
want "after propose" 0 deliberating

say_floor object '["'"$prop"'-1"]' "A barrier round claims no turn, so it would read as silence." >/dev/null
# Likewise: the objection IS the newest thing in the room. This is the case from the bug
# report — an alarm fired on the very lap a fresh objection landed in.
want "after a fresh objection" 0 deliberating

say_floor msg '[]' "I see both sides." >/dev/null
# One turn of echo. A lap here is two turns, so half a lap is not a lap: no alarm yet.
want "after ONE echo turn (half a lap)" 1 deliberating

say_floor msg '[]' "Yes, it is a hard question." >/dev/null
# Now a whole lap has gone by with nothing new, and the objection is still open.
want "after a FULL lap of echo" 2 stuck

say_floor object '["'"$prop"'-1"]' "Second objection, and it is new." >/dev/null
# A new claim resets the window in the same tick it lands — not one tick later.
want "a new claim resets it at once" 0 deliberating

# A claim raised OUT of turn stamps no turn either, and `--hand` is what the protocol
# tells a participant to use for an urgent objection. This is the case from the bug report
# reached the other way: the window has to reset in the tick the objection lands, not on
# the message after it.
echo "--- token mode, 2 peers: a hand-raised objection is a fresh claim ---"
R1b="$COUNCIL_TEST_ROOT/t9-hand"; rm -rf "$R1b"
mkroom "$R1b" a b
export COUNCIL_ROOM="$R1b" ROOM="$R1b"
echo "Should the room keep a lap counter?" > "$R1b/agenda.md"
prop2=$(say_floor propose '[]' "Count the lap over claims.")
say_floor msg '[]' "Sounds fine." >/dev/null
say_floor msg '[]' "No objections from me." >/dev/null
want "a full quiet lap" 2 ready-to-decide
COUNCIL_ME=b bash "$CLI" send --act object --hand \
  --refs '["'"$prop2"'-1"]' "Wait - this breaks the ordering rule." >/dev/null
want "a hand-raised objection resets it" 0 deliberating

echo "--- roundtable mode, 2 peers: the barrier round is claims, not silence ---"
R2="$COUNCIL_TEST_ROOT/t9-barrier"; rm -rf "$R2"
mkroom "$R2" a b
export COUNCIL_ROOM="$R2" ROOM="$R2"
jq '.mode = "roundtable"' "$R2/roster.json" > "$R2/r.tmp" && mv "$R2/r.tmp" "$R2/roster.json"
echo "Should the room keep a lap counter?" > "$R2/agenda.md"

say a propose '[]' "Opening position from a."
say b propose '[]' "Opening position from b."
# The barrier just closed. Both participants stated a brand-new position, and the round
# counts as one whole lap — so the window since the last claim is zero, not a full lap.
# Reading it as a full lap is what let the counter show more silence than the room has
# participants before anybody had said a second word.
want "right after the barrier closes" 0 deliberating

say_floor msg '[]' "Noted." >/dev/null
want "one turn past the barrier" 1 deliberating

echo "--- roundtable mode, 2 peers: the barrier round alone can ripen a decision ---"
R3="$COUNCIL_TEST_ROOT/t9-ripen"; rm -rf "$R3"
mkroom "$R3" a b
export COUNCIL_ROOM="$R3" ROOM="$R3"
jq '.mode = "roundtable"' "$R3/roster.json" > "$R3/r.tmp" && mv "$R3/r.tmp" "$R3/roster.json"
echo "Should the room keep a lap counter?" > "$R3/agenda.md"

# One opening position is a proposal and the other is not, so exactly one proposal is live
# and `ready-to-decide` is reachable at all. (t9b's room has two, and could never reach it
# however long the room stays quiet.)
say a propose '[]' "The only opening proposal."
say b msg     '[]' "Nothing to add beyond a's."
want "barrier closed, one proposal" 0 deliberating
say_floor msg '[]' "Still nothing." >/dev/null
want "half a lap past the barrier" 1 deliberating
say_floor msg '[]' "Still nothing here either." >/dev/null
# The claims that ripen this room stamped no turn at all -- they are barrier positions.
# Gating the threshold on the last STAMPED turn left this room `deliberating` until the
# budget forced an `unresolved` record on a room that had in fact converged.
want "a FULL lap past the barrier" 2 ready-to-decide
if COUNCIL_ME=a bash "$CLI" decide >/dev/null 2>&1; then
  echo "  ok   the room can write its decision record"
else
  echo "  FAIL decide refused a roundtable room that had converged"; fail=1
fi

[ "$fail" = 0 ] && echo "t9 PASS" || echo "t9 FAIL"
exit $fail
