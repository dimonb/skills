#!/usr/bin/env bash
# t6 — the two ways a room ends without agreement, both of which must be VISIBLE:
#   STUCK       a whole lap went by, the objection is still open, nobody said anything new
#               (this is the polite-echo failure that was invisible before);
#   unresolved  the turn budget ran out — an honest record, not a hidden failure.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
R="$COUNCIL_TEST_ROOT/t6"; rm -rf "$R"
mkroom "$R" a b c
export COUNCIL_ROOM="$R" ROOM="$R"
jq '.turns_budget = 9' "$R/roster.json" > "$R/roster.tmp" && mv "$R/roster.tmp" "$R/roster.json"
echo "Should we take on one more schedule mode?" > "$R/agenda.md"
v() { bash "$CLI" verdict | cut -d' ' -f1; }
fail=0

prop=$(say_floor propose '[]' "Add a swarm mode right away, alongside token.")
say_floor object '["'"$prop"'-1"]' "Swarm needs a stability rule, or delivery lies about the order. That is separate work." >/dev/null
echo "objection filed: $(v)"
# a lap of polite echo: three turns, not one new claim
say_floor msg '[]' "I see both sides." >/dev/null
say_floor msg '[]' "Yes, it is a hard question." >/dev/null
say_floor msg '[]' "Agreed, it is hard." >/dev/null
echo "after the echo lap:  $(v)"
[ "$(v)" = stuck ] || { echo "FAIL expected stuck, got $(v)"; fail=1; }
bash "$CLI" status > "$R/log/status.stuck" 2>&1
grep -q "STUCK" "$R/log/status.stuck" || { echo "FAIL status raised no STUCK alarm; output:"; cat "$R/log/status.stuck"; fail=1; }
COUNCIL_ME=a bash "$CLI" decide >/dev/null 2>&1 && { echo "FAIL decide agreed to close a stuck room"; fail=1; }
echo "decide on a stuck room: refused (correct)"
# now spend the rest of the budget
for _t in "Right." "Uh-huh." "Mm." "Still thinking."; do say_floor msg '[]' "$_t" >/dev/null; done
echo "after the budget:    $(v)"
[ "$(v)" = unresolved ] || { echo "FAIL expected unresolved, got $(v)"; fail=1; }
OUT=$(COUNCIL_ME=a bash "$CLI" decide --force) || { echo "FAIL --force did not write unresolved"; fail=1; }
grep -q "status: \*\*unresolved\*\*" "$OUT" || { echo "FAIL the ADR does not say unresolved"; fail=1; }
grep -q "Left open" "$OUT" || { echo "FAIL the ADR did not list what stayed open"; fail=1; }
grep -q "stability rule" "$OUT" || { echo "FAIL the ADR lost the text of the open objection"; fail=1; }
echo "--- what the ADR left open ---"; sed -n '/## Left open/,/## Transcript/p' "$OUT" | head -5
[ "$fail" = 0 ] && echo "t6 PASS" || echo "t6 FAIL"
exit $fail
