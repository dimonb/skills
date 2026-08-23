#!/usr/bin/env bash
# t4 — two peers claim the same turn on purpose (the hole Codex found).
# Both are frozen at the same view of the log, so both believe they hold the floor.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
R="${TMPDIR:-/tmp}/council-test/t4"; rm -rf "$R"
mkroom "$R" a b c
export COUNCIL_ROOM="$R" ROOM="$R"

# a opens, so turn 0 is taken and the log is non-empty.
( export COUNCIL_ME=a; . "$SKILL/lib/lib.sh"; c_send --act propose --text "turn 0 by a" >/dev/null )
# b and c both send WITHOUT draining: each still sees one turn, so each stamps turn=1.
( export COUNCIL_ME=b; . "$SKILL/lib/lib.sh"; c_send --act object --refs '["a-1"]' --text "turn 1 by b" >/dev/null ) &
( export COUNCIL_ME=c; . "$SKILL/lib/lib.sh"; c_send --act object --refs '["a-1"]' --text "turn 1 by c" >/dev/null ) &
wait

fail=0
claims=$(bash "$CLI" order | jq -s '[.[] | select(.turn == 1)] | length')
[ "$claims" = 2 ] || { echo "FAIL setup: $claims messages claimed turn 1, wanted 2"; fail=1; }

# every peer must settle the conflict the same way, and settle it only one way
for p in a b c; do
  COUNCIL_ME=$p bash -c '. '"$SKILL"'/lib/lib.sh; c_canon' \
    | jq -r 'select(.turn == 1) | "\(.id) valid=\(.valid)"' | sort > "$R/log/verdict.$p"
done
cmp -s "$R/log/verdict.a" "$R/log/verdict.b" && cmp -s "$R/log/verdict.a" "$R/log/verdict.c" \
  || { echo "FAIL peers disagree on who won turn 1"; fail=1; }
winners=$(grep -c "valid=true" "$R/log/verdict.a" || true)
losers=$(grep -c "valid=false" "$R/log/verdict.a" || true)
[ "$winners" = 1 ] && [ "$losers" = 1 ] || { echo "FAIL winners=$winners losers=$losers, wanted 1/1"; fail=1; }
# the loser's words must still be in the room — demoted, not dropped
lost_id=$(grep "valid=false" "$R/log/verdict.a" | cut -d' ' -f1)
bash "$CLI" order | jq -e --arg i "$lost_id" 'select(.id==$i) | .text' >/dev/null \
  || { echo "FAIL the demoted message vanished from the log"; fail=1; }
echo "turn 1 claimed twice; winner/loser settled identically by all three; loser ($lost_id) kept in the log"
echo "turns counted after settling: $(COUNCIL_ME=a bash -c '. '"$SKILL"'/lib/lib.sh; c_turns') (2 = a's turn + one winner)"
[ "$fail" = 0 ] && echo "t4 PASS" || echo "t4 FAIL"
exit $fail
