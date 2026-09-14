#!/usr/bin/env bash
# t25 — what SATISFIES the opening barrier (#175).
#
# The barrier used to count by field alone: any non-`--hand` message sent into an open round was
# stamped `round: 0`, and `c_round0` selected on that field without ever consulting the act. So a
# seat that fumbled its first message closed the round on nothing. Measured in a live `debate`
# room: one seat's first message was the literal string `--help`, sent as the default act `msg`,
# the barrier counted it, and the room reached `ready-to-decide` in four turns with one proposal,
# zero objections and zero independent positions.
#
# The rule is now that an opening position is `--act propose`, and it is enforced in two halves
# keyed on ONE predicate:
#   * c_round0 does not COUNT anything else — which is what fixes the arithmetic, and it fixes it
#     for every reader that goes through that accessor (the posted count, "have I spoken", and
#     the deadline's anchor);
#   * c_send REFUSES anything else, at exit 7 — because the filter alone would be a silent no-op
#     from the seat's side: the message lands, the seat believes it has spoken, and it waits out
#     a round that will never count it.
#
# Both halves are asserted here, and the filter is asserted THROUGH A DIRECT LANE WRITE rather
# than through `send`, because a fixture that can only reach the counter via the send path cannot
# tell the filter from the refusal — it would report coverage for c_round0 that it does not have.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
fail=0

ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fail=1; }

# A round-0 message written straight into a lane, bypassing council.sh entirely. The shared
# raw_msg helper hardcodes `round: null` and `sent_ms: 0`, and both are exactly what these
# assertions have to control, so this file carries its own rather than widening that one.
raw_round0() { # <peer> <seq> <lamport> <act> <sent_ms> <text>
  local f; f=$(printf '%s/lane/%s/%06d.json' "$ROOM" "$1" "$2")
  jq -n --arg id "$1-$2" --arg from "$1" --argjson lam "$3" --arg act "$4" \
        --argjson ms "$5" --arg text "$6" \
    '{id:$id,from:$from,lamport:$lam,deps:{},act:$act,refs:[],to:["*"],
      hand:false,turn:null,round:0,text:$text,created_at:"test",sent_ms:$ms}' > "$f"
  printf '%s' "$2" > "$ROOM/state/$1.seq"
}

barrier() { COUNCIL_ME="${1:-a}" bash -c '. '"$SKILL"'/lib/lib.sh; c_barrier'; }
now_ms()  { printf '%s' "$(( 10#${EPOCHREALTIME/./} / 1000 ))"; }

newroom() { # <dir> <deadline_ms> <quorum> <peer>...
  local d="$1" dl="$2" q="$3"; shift 3
  rm -rf "$d"; mkroom "$d" "$@"
  ROOM="$d"; export COUNCIL_ROOM="$d"
  jq --argjson dl "$dl" --argjson q "$q" \
     '.mode="roundtable" | .round_deadline_ms=$dl | .round_quorum=$q' \
     "$d/roster.json" > "$d/r.tmp" && mv "$d/r.tmp" "$d/roster.json"
}

# ------------------------------------------------ 1. the refusal, act by act
echo "--- a non-position is refused, and nothing is written ---"
R1="$COUNCIL_TEST_ROOT/t25a"; newroom "$R1" 600000 2 a b

# Every act in the table that is NOT a position. Each is listed with the reason it cannot open a
# round, so this loop is the derivation in the code comment made executable rather than a list
# somebody can extend by taste.
for act in msg notice clarify object support concede amend withdraw skip decide overrule; do
  rc=$(COUNCIL_ME=a bash "$CLI" send --act "$act" "opening with $act" >/dev/null 2>&1; echo $?)
  [ "$rc" = 7 ] || bad "an opening --act $act was not refused at exit 7 (got $rc)"
done
ok "every non-position act is refused at exit 7"

# NOTHING WAS WRITTEN. The refusal is worthless if the message lands anyway -- that is the
# accept-and-not-count shape the fix deliberately did not take, and from outside it looks
# identical to a clean refusal until you count the lane.
n=$(find "$R1/lane/a" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
[ "$n" = 0 ] && ok "every refused send left the lane empty" \
              || bad "a refused send still wrote to the lane ($n files)"

# The message has to be actionable: it must name the act to use, or a seat cannot recover from it.
err=$(COUNCIL_ME=a bash "$CLI" send --act msg "opening with msg" 2>&1 >/dev/null)
case "$err" in *"--act propose"*) ok "the refusal names --act propose" ;;
  *) bad "the refusal does not name --act propose: $err" ;; esac
case "$err" in *"--hand"*) ok "the refusal names --hand as the way to say a non-position" ;;
  *) bad "the refusal does not name --hand: $err" ;; esac

# THE POSITIVE CONTROL. Without it every assertion above is satisfied by a send path that refuses
# everything, including a legitimate position -- which would be a worse bug than the one fixed.
COUNCIL_ME=a bash "$CLI" send --act propose "position a" >/dev/null 2>&1 \
  && ok "a propose still opens the round" || bad "a propose was refused"

# 5 AND 7 MUST NOT COLLAPSE INTO EACH OTHER. They ask for opposite things -- 5 means "you have
# already posted, wait", 7 means "nothing is in yet, send it again as a position" -- and
# protocol/_channel.md tells a participant to act on the difference. A seat that read a 7 as a 5
# would wait out the round in silence, which is the freeze this change exists to close.
rc=$(COUNCIL_ME=a bash "$CLI" send --act msg "a second thing" >/dev/null 2>&1; echo $?)
[ "$rc" = 5 ] && ok "after posting, a further send is still 5 (not 7)" \
              || bad "a second message after posting returned $rc, want 5"

# --hand IS THE ESCAPE HATCH, and the refusal's promise that it exists has to be true. It is
# allowed both before and after a seat has posted, so it is checked on both sides.
COUNCIL_ME=a bash "$CLI" send --act notice --hand "a notice after posting" >/dev/null 2>&1 \
  && ok "--hand still goes through after posting" || bad "--hand was refused after posting"
COUNCIL_ME=b bash "$CLI" send --act object --hand "an objection before posting" >/dev/null 2>&1 \
  && ok "--hand still goes through before posting" || bad "--hand was refused before posting"
# ...and a hand-raised message must not have satisfied the barrier on b's behalf.
[ "$(barrier a)" = open ] && ok "a --hand message does not close the round" \
                          || bad "the round closed on a --hand message"

# ------------------------------------------------ 2. the COUNTER, reached without the send path
echo "--- the barrier does not count a non-position, however it reached the lane ---"
R2="$COUNCIL_TEST_ROOT/t25b"; newroom "$R2" 600000 2 a b
COUNCIL_ME=a bash "$CLI" send --act propose "position a" >/dev/null
raw_round0 b 1 5 msg "$(now_ms)" "--help"
[ "$(barrier a)" = open ] && ok "a round-0 msg written straight into a lane does not close the round" \
                          || bad "the barrier counted a round-0 msg that bypassed send"

# c_posted_round0 inherits the same narrowing, so the seat is not locked out by its own stray
# message: it still owes a position and must still be able to state one.
COUNCIL_ME=b bash "$CLI" send --act propose "position b" >/dev/null 2>&1 \
  && ok "a seat whose stray round-0 message was not counted can still post" \
  || bad "a seat was locked out by a round-0 message that did not count"
[ "$(barrier a)" = closed ] && ok "...and that position closes the round" \
                            || bad "the round did not close on the real position"

# THE CONTROL FOR THE FIXTURE ITSELF: the same direct write, with the act changed to propose,
# must close the round. Without this the assertion above passes for a room whose barrier can
# never close at all -- a lane write the readers simply cannot see.
R3="$COUNCIL_TEST_ROOT/t25c"; newroom "$R3" 600000 2 a b
COUNCIL_ME=a bash "$CLI" send --act propose "position a" >/dev/null
raw_round0 b 1 5 propose "$(now_ms)" "position b, written directly"
[ "$(barrier a)" = closed ] && ok "the same direct write as a propose DOES close the round" \
                            || bad "a directly written propose did not close the round"

# ------------------------------------------------ 3. the deadline anchors on the first POSITION
echo "--- the round deadline starts at the first position, not the first message ---"
# c_barrier takes its clock from min_by(.sent_ms) over c_round0's output. While that selected on
# the field alone, a non-position was the anchor -- in the observed room, the `--help`. A stray
# message minutes before anybody actually spoke therefore backdated the deadline, and the round
# could close on a quorum the moment the first real position landed.
R4="$COUNCIL_TEST_ROOT/t25d"; newroom "$R4" 1000 2 a b c
old=$(( $(now_ms) - 10000 ))
raw_round0 a 1 5 msg "$old" "--help, ten seconds before anybody spoke"
COUNCIL_ME=b bash "$CLI" send --act propose "position b" >/dev/null
COUNCIL_ME=c bash "$CLI" send --act propose "position c" >/dev/null
[ "$(barrier b)" = open ] && ok "a stale non-position does not backdate the deadline" \
                          || bad "the deadline was anchored on a non-position: the round closed early"

# THE CONTROL: the same stale message as a POSITION must close the round, or the fixture's clock
# never reaches the deadline and the assertion above is vacuous.
R5="$COUNCIL_TEST_ROOT/t25e"; newroom "$R5" 1000 2 a b c
old=$(( $(now_ms) - 10000 ))
raw_round0 a 1 5 propose "$old" "a real position, ten seconds ago"
COUNCIL_ME=b bash "$CLI" send --act propose "position b" >/dev/null
[ "$(barrier b)" = closed ] && ok "the same stale message as a position DOES anchor the deadline" \
                            || bad "the fixture's clock never reaches the deadline, so the check above is vacuous"

rm -rf "$R1" "$R2" "$R3" "$R4" "$R5"
[ "$fail" = 0 ] && echo "t25 PASS" || echo "t25 FAIL"
exit $fail
