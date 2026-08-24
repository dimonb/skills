#!/usr/bin/env bash
# t5 — a full deliberation that converges: propose → object → amend closes it →
# a whole lap with nothing new → ready-to-decide → the ADR.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
R="${TMPDIR:-/tmp}/council-test/t5"; rm -rf "$R"
mkroom "$R" a b c
export COUNCIL_ROOM="$R" ROOM="$R"
echo "Where should the room keep its history?" > "$R/agenda.md"
v() { bash "$CLI" verdict | cut -d' ' -f1; }

# Whoever holds the floor says the next thing: the rotation belongs to the code, and a
# test that re-derives it is testing its own copy of the formula.
prop=$(say_floor propose '[]' "Keep the history as one lane per author, with a total order by Lamport clock.")
obj=$(say_floor  object  '["'"$prop"'-1"]' "Then a reader has to scan N directories on every poll.")
say_floor support '[]' "A lane per author removes the locks, which matters more." >/dev/null
echo "after the objection: $(v)"
[ "$(v)" = deliberating ] || { echo "FAIL expected deliberating"; exit 1; }
say_floor amend '["'"$prop"'-1","'"$obj"'-1"]' "One lane per author; a reader probes upward from its cursor, no directory scans." >/dev/null
echo "after the amendment: $(v)  (the objection was closed by it)"
# now a lap with no new claims: N=3 turns of chatter
say_floor msg '[]' "I agree with the amendment." >/dev/null
say_floor msg '[]' "No objections." >/dev/null
say_floor msg '[]' "Then let us record it." >/dev/null
echo "after the lap:      $(v)"
[ "$(v)" = ready-to-decide ] || { echo "FAIL expected ready-to-decide, got $(v)"; bash "$CLI" claims; exit 1; }
OUT=$(COUNCIL_ME=a bash "$CLI" decide) || { echo "FAIL decide refused"; exit 1; }
grep -q "status: \*\*decided\*\*" "$OUT" || { echo "FAIL the ADR does not say decided"; exit 1; }
grep -q "no directory scans" "$OUT" || { echo "FAIL the ADR carries the original proposal, not the amended text"; exit 1; }
grep -q "closed by \`" "$OUT" || { echo "FAIL the ADR does not record what closed the objection"; exit 1; }
echo "after the decision: $(v)"
[ "$(v)" = decided ] || { echo "FAIL the room did not close"; exit 1; }
bash "$CLI" status >/dev/null; [ $? = 0 ] || { echo "FAIL status did not return 0 for a decided room"; exit 1; }
echo "--- ADR ---"; sed -n '1,12p' "$OUT"
echo "t5 PASS"
