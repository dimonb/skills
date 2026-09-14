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
# The rule is now that an opening position is `--act propose` (C_OPENING_ACT), enforced in two
# halves that read that one constant:
#   * c_round0_positions does not COUNT anything else — which fixes the arithmetic for every
#     reader asking how many positions are in (the posted count, "have I spoken", the deadline's
#     anchor, and the posted=/waiting= displays);
#   * c_send REFUSES anything else, at exit 7 — because the filter alone would be a silent no-op
#     from the seat's side: the message lands, the seat believes it has spoken, and it waits out
#     a round that will never count it.
#
# Both halves are asserted here, and the counting half is asserted THROUGH A DIRECT LANE WRITE
# rather than through `send`, because a fixture that can only reach the counter via the send path
# cannot tell the filter from the refusal — it would report coverage it does not have.
#
# SECTION 4 IS THE ONE THIS SUITE DID NOT HAVE. The first version of this change narrowed the
# barrier's accessor and thereby narrowed v_decide's disclosure gate, which read the same one —
# and the gate asks the opposite question, so narrowing it RELEASED. Every other fixture for that
# gate (t7f/t7g/t7h) writes act:"propose", where the two predicates agree, so the whole battery
# stayed green through the broken version. A suite that cannot fail is a defect in itself.
#
# SECTION 5 IS THE STRUCTURAL GUARD. Section 1's act list is a tripwire and it is defeated by one
# obvious edit — widen the send predicate and drop that act from the list. Section 5 derives both
# sides from the same table and asserts they agree, so it reds whichever side moves. Measured:
# with `support` widened in c_opens_round AND removed from section 1, section 1 goes quiet and
# section 5 still reds.
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

barrier() { COUNCIL_ME="$1" bash -c '. '"$SKILL"'/lib/lib.sh; c_barrier'; }
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
#
# THE SUMMARY `ok` IS GATED ON A FLAG. It used to print unconditionally after the loop, so a run
# in which all eleven acts FAILED still ended the section with a green line asserting they were
# all refused. The suite's exit status was still right, but the output is what a human or an
# agent scans, and a green line stating what the run just disproved is the reporting-side version
# of the check that proves nothing. Caught by a reviewer replaying the mutation this file's own
# header describes -- the author's mutation run counted FAIL lines and never read the rest.
acts_ok=1
for act in msg notice clarify object support concede amend withdraw skip decide overrule; do
  rc=$(COUNCIL_ME=a bash "$CLI" send --act "$act" "opening with $act" >/dev/null 2>&1; echo $?)
  [ "$rc" = 7 ] || { bad "an opening --act $act was not refused at exit 7 (got $rc)"; acts_ok=0; }
done
[ "$acts_ok" = 1 ] && ok "every non-position act is refused at exit 7"

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

# ------------------------------- 4. the DISCLOSURE gate reads the withholding predicate
echo "--- decide --force still refuses while a foreign round-0 message is withheld ---"
# THE REGRESSION THIS FILE EXISTS TO PREVENT A SECOND TIME, and the battery could not see it.
# Narrowing the barrier's counting predicate silently narrowed v_decide's mid-round disclosure
# gate, which read the same accessor. That gate asks the WITHHOLDING question -- "is something
# being held back from me that the record would hand over" -- not the counting one, and the two
# have opposite safe directions. While it was keyed to counting, a round-0 message with any act
# but `propose` stopped satisfying it while c_visible went on withholding that same message, so
# a seat that had posted nothing could force-close and read a peer's withheld text in the record.
#
# t7f/t7g/t7h are the only other fixtures for this gate and every one of them writes
# act:"propose" into its hand-written lane -- so raw and narrow agree there and the whole suite
# stayed green through the broken version. A fixture whose act is NOT a position is the only
# thing that can tell the two predicates apart.
R6="$COUNCIL_TEST_ROOT/t25f"; newroom "$R6" 600000 2 a b
raw_round0 b 1 5 msg "$(now_ms)" "SECRET-B-TEXT"
[ "$(barrier a)" = open ] || bad "the gate fixture's barrier is not open, so it proves nothing"
# a is withheld from b's lane: that is the state in which the gate must refuse.
seen_a=$(COUNCIL_ME=a bash "$CLI" transcript 2>/dev/null | grep -c "SECRET-B-TEXT" || true)
[ "$seen_a" = 0 ] || bad "the fixture does not withhold b's message from a, so the gate is moot"
out=$(COUNCIL_ME=a bash "$CLI" decide --force 2>&1); rc=$?
[ "$rc" = 2 ] && ok "a seat that posted nothing is refused while foreign round-0 traffic is withheld" \
               || bad "decide --force returned $rc, want 2 — the disclosure gate is open again"
[ -s "$R6/board/decision.md" ] && bad "the refused close wrote a record anyway" \
                               || ok "...and wrote no record"
# ...and the record it would have written is the disclosure, so prove the text was really at risk.
grep -q "SECRET-B-TEXT" "$R6/board/decision.md" 2>/dev/null \
  && bad "b's withheld text reached the record" \
  || ok "...so b's withheld text did not reach a"

# THE POSITIVE CONTROL: the same seat must still be able to clear the refusal by posting, or the
# gate is a freeze rather than a gate. This is also the self-heal for a room upgraded mid-flight.
COUNCIL_ME=a bash "$CLI" send --act propose "a's real position" >/dev/null 2>&1 \
  && ok "the refused seat can still post its own position" \
  || bad "the refused seat could not post — the gate is a wedge, not a gate"
out=$(COUNCIL_ME=a bash "$CLI" decide --force 2>&1); rc=$?
[ "$rc" = 0 ] && ok "...and that stands the refusal down at once" \
              || bad "decide --force still refused after posting (exit $rc): $out"

# ------------------------------- 5. send-acceptance and barrier-counting must agree
echo "--- every act: accepted by send iff counted by the barrier ---"
# THE STRUCTURAL GUARD, as opposed to the act list in section 1. That list is a tripwire and a
# reviewer measured how it is defeated: widen the send predicate AND drop the act from the list
# -- a one-word edit the list invites -- and the suite goes green while the divergence is live
# (the seat sends successfully, gets an id, and `status` reports the room still waiting for it,
# which is #175 verbatim). This section cannot be satisfied that way: it derives BOTH sides from
# the same act table and asserts they agree, so any one-sided change to what opens a round reds
# it whichever side moves, and it keeps working if the rule ever becomes a set.
for act in propose msg notice clarify object support concede amend withdraw skip decide overrule; do
  RX="$COUNCIL_TEST_ROOT/t25g-$act"; newroom "$RX" 600000 2 a b
  COUNCIL_ME=a bash "$CLI" send --act "$act" "opening with $act" >/dev/null 2>&1; sent=$?
  counted=$(COUNCIL_ME=a bash -c '. '"$SKILL"'/lib/lib.sh; c_round0_positions' | wc -l | tr -d ' ')
  # accepted == counted, as booleans: a send that succeeded must leave exactly one position in
  # the round, and a send that was refused must leave none.
  if [ "$sent" = 0 ] && [ "$counted" != 1 ]; then
    bad "--act $act was ACCEPTED by send but the barrier counted $counted — the silent no-op of #175"
  elif [ "$sent" != 0 ] && [ "$counted" != 0 ]; then
    bad "--act $act was REFUSED by send but the barrier counted $counted"
  fi
  rm -rf "$RX"
done
ok "send-acceptance and barrier-counting agree on all twelve acts"

rm -rf "$R1" "$R2" "$R3" "$R4" "$R5" "$R6"
[ "$fail" = 0 ] && echo "t25 PASS" || echo "t25 FAIL"
exit $fail
