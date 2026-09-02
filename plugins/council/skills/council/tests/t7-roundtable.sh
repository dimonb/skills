#!/usr/bin/env bash
# t7 — the opening barrier of `mode: roundtable`.
#   * an opening position is invisible to everyone else until the round is complete, in
#     EVERY reader — `recv`, `transcript`, `claims`, `order` and `status` — while a
#     supervisor watching the room still sees all of it;
#   * when the last one lands, all of them are released at once, in one order;
#   * the round counts as one lap, and the room is turn-taking from there on;
#   * a participant that never posts does not hold the room: the deadline plus a quorum
#     closes the round without it.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
fail=0

# ---------------------------------------------------------------- 1. the barrier holds
R="$COUNCIL_TEST_ROOT/t7"; rm -rf "$R"
mkroom "$R" a b c
export COUNCIL_ROOM="$R" ROOM="$R"
jq '.mode="roundtable" | .round_deadline_ms=600000' "$R/roster.json" > "$R/r.tmp" && mv "$R/r.tmp" "$R/roster.json"

seen() { COUNCIL_ROOM="$R" COUNCIL_ME="$1" bash "$CLI" recv --peek | jq -r '.id' | paste -sd, -; }

# Does <peer>'s view of the room, through <verb>, contain <text>? An EMPTY peer is a
# supervisor — the verbs below all run without `--me`, and one that is watching the room must
# keep seeing it.
#
# Captured and matched in the shell rather than piped into grep, for two reasons this suite has
# already paid for: `status` returns 1 for a live room, which under pipefail reads as a failing
# grep (council.sh's own usage says do not pipe status), and `grep -q` closes the pipe on its
# first hit, so a match can come back as SIGPIPE rather than as a match.
sees() { # <peer|""> <verb> <text>
  local out
  if [ -n "$1" ]; then out=$(COUNCIL_ROOM="$R" COUNCIL_ME="$1" bash "$CLI" "$2" 2>&1)
  else out=$(env -u COUNCIL_ME COUNCIL_ROOM="$R" bash "$CLI" "$2" 2>&1); fi
  case "$out" in *"$3"*) return 0 ;; *) return 1 ;; esac
}

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

# ------------------------------------------------- 1b. EVERY reader holds the barrier
# It used to live in c_drain alone, so `recv` withheld a position while `transcript`,
# `claims`, `order` and `status` printed it — `status` directly under its own line saying
# nobody can see it yet, and `status` is the verb protocol/_channel.md tells a participant to
# run in exactly this situation.
#
# The barrier is asserted OPEN first: with it closed nothing below can fail, and an assertion
# whose fixture cannot produce the defect reports coverage that is not there.
st=$(COUNCIL_ME=a bash -c '. '"$SKILL"'/lib/lib.sh; c_barrier')
[ "$st" = open ] || { echo "FAIL the round is $st, so the reader checks below prove nothing"; fail=1; }
# Both peers are checked, and that is the point of the pair: c has not posted, a has. The
# promise is "nobody reads anyone else's until the round is complete", not "until you have
# spoken", so posting does not release the rest of the room to you.
for v in transcript claims status order; do
  sees c "$v" "for the first lap only" && { echo "FAIL c saw a's position through '$v' while the round was open"; fail=1; }
  sees c "$v" "not needed at all" && { echo "FAIL c saw b's position through '$v' while the round was open"; fail=1; }
  sees a "$v" "not needed at all" && { echo "FAIL a saw b's position through '$v' after posting its own"; fail=1; }
done
echo "the barrier holds in every reader: transcript, claims, order and status withhold what recv does"

# A supervisor is not a participant and owes no position. Gating it would blank the one block
# a human is told to watch, at the one moment a room is most likely to need watching.
for v in transcript status; do
  sees "" "$v" "for the first lap only" || { echo "FAIL a supervisor could not see a's position through '$v'"; fail=1; }
  sees "" "$v" "not needed at all" || { echo "FAIL a supervisor could not see b's position through '$v'"; fail=1; }
done
echo "a supervisor still sees the whole room while the round is open"

# ------------------------------------------------------- 2. the last one releases all
say c propose '[]' "position c: the barrier is needed beyond the first lap too"
got=$(seen b)
[ "$got" = "a-1,c-1" ] || { echo "FAIL b got '$got', expected both other positions at once"; fail=1; }
echo "round complete: b got both other positions in one batch ($got)"

# ...and the readers open with it. A filter that never lifts would be the same defect wearing
# the opposite sign, and it would show up as a room whose transcript is permanently empty.
for v in transcript claims status order; do
  sees b "$v" "for the first lap only" || { echo "FAIL b could not see a's position through '$v' once the round had closed"; fail=1; }
done
echo "and once the round is complete every reader hands the positions over"

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
R2="$COUNCIL_TEST_ROOT/t7b"; rm -rf "$R2"
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

# ------------------- 5. the RECORD holds the whole log, not the writer's view of it
# `decide --force` mid-round is the supervisor's escape hatch, and the record is the room's one
# durable output. Rendered through the barrier it would hold only the writer's own position,
# written at rc 0 and afterwards indistinguishable from a complete record — which is this
# codebase's worst failure mode, so the record reads the log and not the seat.
R3="$COUNCIL_TEST_ROOT/t7c"; rm -rf "$R3"
mkroom "$R3" a b c
ROOM="$R3"; export COUNCIL_ROOM="$R3"
jq '.mode="roundtable" | .round_deadline_ms=600000' "$R3/roster.json" > "$R3/r.tmp" && mv "$R3/r.tmp" "$R3/roster.json"
say a propose '[]' "position a: a record must not be written through the barrier"
say b propose '[]' "position b: nor may it lose the seat that did not write it"
st=$(COUNCIL_ME=a bash -c '. '"$SKILL"'/lib/lib.sh; c_barrier')
[ "$st" = open ] || { echo "FAIL the round is $st, so the record check below proves nothing"; fail=1; }
COUNCIL_ME=a bash "$CLI" decide --force >/dev/null 2>&1
rec="$R3/board/decision.md"
[ -s "$rec" ] || { echo "FAIL no record was written at all"; fail=1; }
for t in "a record must not be written through the barrier" "nor may it lose the seat that did not write it"; do
  grep -qF "$t" "$rec" || { echo "FAIL the record forced mid-round is missing: $t"; fail=1; }
done
echo "a record forced mid-round holds every position, not only the writer's own"

[ "$fail" = 0 ] && echo "t7 PASS" || echo "t7 FAIL"
exit $fail
