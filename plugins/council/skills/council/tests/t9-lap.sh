#!/usr/bin/env bash
# t9 — the lap counter: "nothing new for N turns (lap M)".
#
# N must be the number of turns that went by CARRYING NO NEW CLAIM. It is the only input
# to `stuck` and to `ready-to-decide`, and a supervisor is told to read it at a glance, so
# an off-by-one here is not cosmetic: it fires the alarm half a lap early and it fires it
# on a lap that did contain a fresh objection.
#
# Two peers on purpose. With a lap of 2, one turn early is HALF a lap, so the error is
# unmissable; at three peers the same bug hides inside a plausible-looking number.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
fail=0

since() { bash "$CLI" verdict --json | jq -r .since_last_claim; }
vd()    { bash "$CLI" verdict | cut -d' ' -f1; }
want()  { # <what> <expected-since> <expected-verdict>
  local got_s got_v; got_s=$(since); got_v=$(vd)
  if [ "$got_s" = "$2" ] && [ "$got_v" = "$3" ]; then
    printf '  ok   %-34s nothing new for %s turns, %s\n' "$1" "$got_s" "$got_v"
  else
    printf '  FAIL %-34s want (%s, %s) got (%s, %s)\n' "$1" "$2" "$3" "$got_s" "$got_v"
    fail=1
  fi
}

echo "--- token mode, 2 peers: a claim just made is not silence ---"
R="${TMPDIR:-/tmp}/council-test/t9a"; rm -rf "$R"
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

echo "--- roundtable mode, 2 peers: the barrier round is claims, not silence ---"
R2="${TMPDIR:-/tmp}/council-test/t9b"; rm -rf "$R2"
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

[ "$fail" = 0 ] && echo "t9 PASS" || echo "t9 FAIL"
exit $fail
