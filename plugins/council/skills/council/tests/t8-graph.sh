#!/usr/bin/env bash
# t8 — closure and attribution rules that a live room needed and the graph did not have.
#   * an amend belongs to ONE proposal (its first proposal-typed ref), so a single
#     amendment cannot rewrite two rival positions into the same words;
#   * an amend naming no proposal belongs to the proposal its first objection was raised
#     against, and a direct proposal ref still wins over that;
#   * `concede` pointing at the sender's OWN proposal kills it — the natural way to yield
#     in favour of somebody else's position.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
R="$COUNCIL_TEST_ROOT/t8"; rm -rf "$R"
mkroom "$R" a b
export COUNCIL_ROOM="$R" ROOM="$R"
fail=0

# two rival proposals, as a barrier round would produce
raw_msg a 1 1 0 propose '[]' "position a"
raw_msg b 1 2 1 propose '[]' "position b"
# one amendment naming BOTH, plus an objection id
raw_msg b 2 3 2 object  '["a-1"]' "I object to a"
raw_msg a 2 4 3 amend   '["a-1","b-1","b-2"]' "amended position a"

g=$(COUNCIL_ME=a bash "$CLI" claims --raw)
ta=$(printf '%s' "$g" | jq -r '.proposals[] | select(.id=="a-1") | .current_text')
tb=$(printf '%s' "$g" | jq -r '.proposals[] | select(.id=="b-1") | .current_text')
[ "$ta" = "amended position a" ] || { echo "FAIL the amendment did not reach its own proposal: '$ta'"; fail=1; }
[ "$tb" = "position b" ] || { echo "FAIL the amendment rewrote somebody else's proposal: '$tb'"; fail=1; }
closed=$(printf '%s' "$g" | jq -r '[.proposals[].objections[] | select(.closed_by != null)] | length')
[ "$closed" = 1 ] || { echo "FAIL the amendment did not close the objection it referenced"; fail=1; }
echo "an amendment amends one proposal and closes the objection it names"

# b yields its own position
raw_msg b 3 5 4 concede '["b-1"]' "I yield my own position"
g=$(COUNCIL_ME=a bash "$CLI" claims --raw)
dead=$(printf '%s' "$g" | jq -r '.proposals[] | select(.id=="b-1") | .dead')
live=$(printf '%s' "$g" | jq -r '.live | length')
[ "$dead" = true ] || { echo "FAIL conceding one own proposal did not drop it"; fail=1; }
[ "$live" = 1 ] || { echo "FAIL $live proposals left on the table, expected 1"; fail=1; }
echo "conceding your own proposal drops it: one is left on the table"

# An amend that names ONLY the objection belongs to the proposal that objection was raised
# against (#34). It closes the objection regardless, so without the attribution the room
# ripened on it while the proposal carried no amendment at all, and the decision record
# rendered the un-amended text.
R2="$COUNCIL_TEST_ROOT/t8-objref"; rm -rf "$R2"
mkroom "$R2" a b
export COUNCIL_ROOM="$R2" ROOM="$R2"
raw_msg a 1 1 0 propose '[]' "position a"
raw_msg b 1 2 1 object  '["a-1"]' "I object to a"
raw_msg b 2 3 2 amend   '["b-1"]' "amended position a"
g=$(COUNCIL_ME=a bash "$CLI" claims --raw)
am=$(printf '%s' "$g" | jq -r '.proposals[] | select(.id=="a-1") | .amends | join(",")')
ct=$(printf '%s' "$g" | jq -r '.proposals[] | select(.id=="a-1") | .current_text')
cb=$(printf '%s' "$g" | jq -r '.proposals[] | select(.id=="a-1") | .objections[0].closed_by')
[ "$am" = "b-2" ] || { echo "FAIL an objection-only amend is not attributed to the proposal it closes an objection on: '$am'"; fail=1; }
[ "$ct" = "amended position a" ] || { echo "FAIL current_text ignores the objection-only amend: '$ct'"; fail=1; }
[ "$cb" = "b-2" ] || { echo "FAIL the objection-only amend no longer closes the objection: '$cb'"; fail=1; }
echo "an amend naming only the objection amends the proposal that objection was raised against"

# A direct proposal ref wins over the proposal an objection it names was raised against.
raw_msg a 2 4 3 propose '[]' "position c"
raw_msg a 3 5 4 object  '["a-2"]' "I object to c"
raw_msg b 3 6 5 amend   '["a-3","a-1"]' "amended again, closing an objection on c"
g=$(COUNCIL_ME=a bash "$CLI" claims --raw)
am1=$(printf '%s' "$g" | jq -r '.proposals[] | select(.id=="a-1") | .amends | join(",")')
am2=$(printf '%s' "$g" | jq -r '.proposals[] | select(.id=="a-2") | .amends | join(",")')
[ "$am1" = "b-2,b-3" ] || { echo "FAIL a direct proposal ref did not win: a-1 amends '$am1'"; fail=1; }
[ -z "$am2" ] || { echo "FAIL an amend went to its objection's proposal over a direct ref: a-2 amends '$am2'"; fail=1; }
echo "a direct proposal ref wins over an objection's proposal"
[ "$fail" = 0 ] && echo "t8 PASS" || echo "t8 FAIL"
exit $fail
