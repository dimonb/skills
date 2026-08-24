#!/usr/bin/env bash
# t7 — the opening barrier of `mode: roundtable`.
#   * an opening position is invisible to everyone else until the round is complete;
#   * when the last one lands, all of them are released at once, in one order;
#   * the round counts as one lap, and the room is turn-taking from there on;
#   * a participant that never posts does not hold the room: the deadline plus a quorum
#     closes the round without it.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
fail=0

# ---------------------------------------------------------------- 1. the barrier holds
R="${TMPDIR:-/tmp}/council-test/t7"; rm -rf "$R"
mkroom "$R" a b c
export COUNCIL_ROOM="$R" ROOM="$R"
jq '.mode="roundtable" | .round_deadline_ms=600000' "$R/roster.json" > "$R/r.tmp" && mv "$R/r.tmp" "$R/roster.json"

seen() { COUNCIL_ROOM="$R" COUNCIL_ME="$1" bash "$CLI" recv --peek | jq -r '.id' | paste -sd, -; }

# a participant that owes a position must be released at once: in a barrier round there is
# no floor holder to wait for, and --until-floor would otherwise wait forever (a live Codex
# participant did exactly that the first time a roundtable room ran).
COUNCIL_ME=a timeout 12 bash "$CLI" recv --until-floor --timeout 8 >/dev/null
[ $? = 0 ] || { echo "FAIL a participant that still owes a position was not released from --until-floor"; fail=1; }

say a propose '[]' "position a: the barrier is for the first lap only"

# ...and one that HAS posted keeps waiting for the round, not for a turn
COUNCIL_ME=a timeout 12 bash "$CLI" recv --until-floor --timeout 6 >/dev/null
[ $? = 4 ] || { echo "FAIL a participant that has posted did not wait for the round to complete"; fail=1; }
echo "recv in a barrier: releases the one that owes a position, holds the one that posted"
[ -z "$(seen b)" ] || { echo "FAIL b saw the position of a before the round completed: $(seen b)"; fail=1; }
say b propose '[]' "position b: the barrier is not needed at all"
[ -z "$(seen c)" ] || { echo "FAIL c saw other positions before the round completed: $(seen c)"; fail=1; }
echo "the barrier holds: b and c see nothing, though two positions are already written"

# a second position from the same participant is refused, not silently queued
COUNCIL_ROOM="$R" COUNCIL_ME=a bash "$CLI" send --act msg "and one more thing" >/dev/null 2>&1
[ $? = 5 ] || { echo "FAIL a second message in an open round was not refused"; fail=1; }

# ------------------------------------------------------- 2. the last one releases all
say c propose '[]' "position c: the barrier is needed beyond the first lap too"
got=$(seen b)
[ "$got" = "a-1,c-1" ] || { echo "FAIL b got '$got', expected both other positions at once"; fail=1; }
echo "round complete: b got both other positions in one batch ($got)"

# ---------------------------------------------- 3. one lap consumed, token from here on
turns=$(COUNCIL_ME=a bash -c '. '"$SKILL"'/lib/lib.sh; c_turns')
[ "$turns" = 3 ] || { echo "FAIL turns=$turns after the round, expected 3 (one lap)"; fail=1; }
floor=$(bash "$CLI" floor | sed -n 's/.*floor=\([a-z]*\).*/\1/p')
[ "$floor" = b ] || { echo "FAIL the floor is with '$floor', the rotation says b"; fail=1; }
say b object '["a-1"]' "I object to the position of a"
turns=$(COUNCIL_ME=a bash -c '. '"$SKILL"'/lib/lib.sh; c_turns')
[ "$turns" = 4 ] || { echo "FAIL an ordinary turn after the round was not counted: $turns"; fail=1; }
conf=$(bash "$CLI" floor | sed -n 's/.*conflicts=\([0-9]*\).*/\1/p')
[ "$conf" = 0 ] || { echo "FAIL the opening positions fought over a turn: conflicts=$conf"; fail=1; }
echo "the round is one lap, token from there on: turns=$turns, conflicts=$conf"

# ------------------------------------------- 4. a silent participant does not hold it
R2="${TMPDIR:-/tmp}/council-test/t7b"; rm -rf "$R2"
mkroom "$R2" a b c
ROOM="$R2"; export COUNCIL_ROOM="$R2"
jq '.mode="roundtable" | .round_deadline_ms=1000 | .round_quorum=2' "$R2/roster.json" > "$R2/r.tmp" && mv "$R2/r.tmp" "$R2/roster.json"
COUNCIL_ME=a bash "$CLI" send --act propose "position a" >/dev/null
COUNCIL_ME=b bash "$CLI" send --act propose "position b" >/dev/null
st=$(COUNCIL_ME=a bash -c '. '"$SKILL"'/lib/lib.sh; c_barrier')
[ "$st" = open ] || { echo "FAIL the round closed before the deadline with 2 of 3"; fail=1; }
sleep 1.5
st=$(COUNCIL_ME=a bash -c '. '"$SKILL"'/lib/lib.sh; c_barrier')
[ "$st" = closed ] || { echo "FAIL the round did not close on the deadline with a quorum: $st"; fail=1; }
got=$(COUNCIL_ROOM="$R2" COUNCIL_ME=c bash "$CLI" recv --peek | jq -r '.id' | paste -sd, -)
[ "$got" = "a-1,b-1" ] || { echo "FAIL what was collected was not released after the deadline: '$got'"; fail=1; }
echo "a silent participant does not hold the room: the round closed on the deadline, positions released"

# ...and the latecomer must not reopen or rewrite the round it missed. (Raised by a live
# Codex participant while writing its own position in a roundtable room.)
# c missed the round entirely; out of turn it is refused like anyone else, so let the
# rotation come round to it and check what its first message then IS.
rc0=$(COUNCIL_ME=c bash "$CLI" send --act msg "I am late" >/dev/null 2>&1; echo $?)
[ "$rc0" = 6 ] || { echo "FAIL the latecomer spoke out of turn (exit $rc0)"; fail=1; }
while [ "$(bash "$CLI" floor | sed -n 's/.*floor=\([^ ]*\).*/\1/p')" != c ]; do
  say_floor msg '[]' "a turn" >/dev/null || break
done
COUNCIL_ME=c bash "$CLI" send --act msg "I am late, but I waited for my turn" >/dev/null
late=$(bash "$CLI" order | jq -r 'select(.from=="c") | .round')
[ "$late" = null ] || { echo "FAIL the late message was recorded as an opening position (round=$late)"; fail=1; }
st=$(COUNCIL_ME=a bash -c '. '"$SKILL"'/lib/lib.sh; c_barrier')
[ "$st" = closed ] || { echo "FAIL the latecomer reopened the round: $st"; fail=1; }
turns=$(COUNCIL_ME=a bash -c '. '"$SKILL"'/lib/lib.sh; c_turns')
[ "$turns" -ge 3 ] || { echo "FAIL the turn count after a closed round is wrong: $turns"; fail=1; }
echo "a latecomer does not reopen the round: its message is an ordinary turn, the round stayed closed"

[ "$fail" = 0 ] && echo "t7 PASS" || echo "t7 FAIL"
exit $fail
