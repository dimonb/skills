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

# Exactly one proposal must be LIVE for `ready-to-decide` to be reachable at all (t9b's room
# has two, and could never reach it however long the room stays quiet). A barrier round that
# COMPLETES ON POSITIONS puts N proposals on the table -- only `propose` opens a round (#175),
# so the old fixture's `say b msg` is refused rather than counted. (Not "always N": c_barrier
# also closes on the deadline with a quorum, and on the 2x backstop, both with fewer. t7b asserts
# the deadline-with-quorum close; the 2x backstop is asserted by NO test in this suite, so do not
# read this parenthesis as saying it is covered. This room closes on positions, which is why one
# proposal per seat holds HERE.) The way a
# room gets from N live proposals to one is the lap after the barrier, which is what
# protocol/_channel.md tells a participant to do: yield yours if someone else's is better.
#
# `say b`, NOT `say_floor`, and the difference is an assertion rather than a preference:
# claims.jq retires a proposal on a concede from THE PROPOSAL'S OWN AUTHOR, and say_floor is
# documented as not caring who speaks. The rotation does put b on the floor here (floor at
# turns=2 is order[(2%2 + 2/2) % 2] = order[1] = b), so say_floor would work -- by coincidence,
# silently, until a rotation change broke it three lines later as a lap-counter error. Naming b
# states the requirement the fixture actually depends on.
#
# The arithmetic is unchanged by that substitution, and it is worth seeing why rather than
# trusting it: `concede` is not one of the acts that counts as a NEW claim (claims.jq counts
# propose|amend|object), so b's concession advances the turn count without resetting the
# silence window -- exactly as the `msg` it replaces did.
say a propose '[]' "The only opening proposal."
say b propose '[]' "A rival opening proposal, which b will yield."
want "barrier closed, two proposals" 0 deliberating
say b concede '["b-1"]' "Yielding to a's."
# THE PRECONDITION, ASSERTED WHERE IT IS ESTABLISHED. `want ... 1 deliberating` below holds with
# two live proposals too, so without this line a claims.jq regression in the proposer-yield rule
# would surface three lines later as a lap-counter failure -- a diagnosis pointing at the wrong
# subsystem -- the unasserted-precondition shape t7-roundtable.sh records in its own comments.
lv=$(bash "$CLI" verdict --json | jq -r '.live | length')
[ "$lv" = 1 ] && echo "  ok   b's concession retired its own proposal" \
              || { echo "  FAIL b's concession left $lv live proposals, want 1"; fail=1; }
want "half a lap past the barrier" 1 deliberating
say_floor msg '[]' "Still nothing here either." >/dev/null
# The claims that ripen this room stamped no turn at all -- they are barrier positions.
# Gating the threshold on the last STAMPED turn left this room `deliberating` until the
# budget forced an `unresolved` record on a room that had in fact converged.
want "a FULL lap past the barrier" 2 ready-to-decide

# The turn count every reader reports must be the same number, and it must include the
# barrier lap. The graph does not know about that lap, so a reader taking its count is short
# by the whole opening round -- which is what the decision record used to write down.
jt=$(bash "$CLI" verdict --json | jq -r .turns)
[ "$jt" = 4 ] && echo "  ok   verdict --json counts the barrier lap (turns=4)" \
              || { echo "  FAIL verdict --json turns=$jt, want 4"; fail=1; }
ct=$(bash "$CLI" claims | head -1)
case "$ct" in *"turns: 4"*) echo "  ok   claims reports the same turns as verdict" ;;
  *) echo "  FAIL claims disagrees with verdict: $ct"; fail=1 ;; esac

if OUT=$(COUNCIL_ME=a bash "$CLI" decide 2>/dev/null); then
  echo "  ok   the room can write its decision record"
  # The record is the durable artefact; a room that spent its budget must not write down
  # that it had turns in hand.
  if grep -q '^\* turns: 4 of ' "$OUT"; then
    echo "  ok   the decision record counts the barrier lap too"
  else
    echo "  FAIL the record's turn count is wrong: $(grep '^\* turns:' "$OUT")"; fail=1
  fi
else
  echo "  FAIL decide refused a roundtable room that had converged"; fail=1
fi

# A room where nobody ever claimed anything takes the `no claim at all` fallback, and it is
# the one verdict the suite otherwise never visits.
echo "--- token mode, 2 peers: a room with no claim at all ---"
R4="$COUNCIL_TEST_ROOT/t9-noclaim"; rm -rf "$R4"
mkroom "$R4" a b
export COUNCIL_ROOM="$R4" ROOM="$R4"
echo "Should the room keep a lap counter?" > "$R4/agenda.md"
say_floor msg '[]' "Just talking." >/dev/null
say_floor msg '[]' "Still just talking." >/dev/null
want "nothing was ever claimed" 2 no-proposal

[ "$fail" = 0 ] && echo "t9 PASS" || echo "t9 FAIL"
exit $fail
