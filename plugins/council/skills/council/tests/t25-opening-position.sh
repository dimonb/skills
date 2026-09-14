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
# and the gate asks the opposite question, so narrowing it RELEASED. No fixture that existed for
# that gate had a round-0 message whose act was not a position -- the ones carrying round-0
# traffic all write `propose`, and the rest carry none at all -- so not one of them could tell
# the two predicates apart, and the whole battery stayed green through the broken version. A
# suite that cannot fail is a defect in itself. (Stated as the property rather than as a list of
# fixture names: two earlier versions of this sentence named a list, and both were incomplete.)
#
# SECTION 5 IS THE STRUCTURAL GUARD, AND ITS FIRST VERSION WAS VACUOUS — which is the sharpest
# lesson in this file, above the disclosure regression, because it is about testing rather than
# about council. Section 1's act list is a tripwire defeated by one obvious edit: widen the send
# predicate and drop that act from the list. Section 5 derives both sides from the same table, so
# that edit cannot silence it (measured). But an EQUIVALENCE AGREES WHEN BOTH SIDES ARE EMPTY, so
# the first version was green for `c_opens_round` returning false — a rule admitting NOTHING,
# which is a worse bug than the one it was written to defend against. Its passing condition was
# satisfiable by total failure. The `propose` row is the repair and it does two jobs at once: it
# is the positive case AND the fixture control, so the partition is now stated instead of assumed
# — equivalence catches widening of the send predicate, the positive row catches narrowing on
# either side, sections 2-4 catch the counting side, and section 1 pins identity.
#
# A GENERAL BASH TRAP, WORTH CARRYING OUT OF THIS FILE: a call to a function that does not exist,
# inside `$( )`, yields THE EMPTY STRING — not a failure. So a renamed or deleted accessor does
# not crash a shell test, it silently makes every string comparison around it read as empty, and
# a whole call site can sit unasserted while the suite is green. That is exactly how v_status's
# pair went uncovered (section 2 now pins it). When a shell test greps command output for an
# expected string, the absence of that string and the absence of the COMMAND are indistinguishable
# — so every such assertion needs a control that proves the command still produces anything at
# all. Section 4's last line is that control; it was added after a reviewer measured its absence.
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

# THE SUPERVISOR'S VIEW OF THE SAME FACT, and it is the one reader of the counting accessor that
# nothing else in this suite asserts. Measured by a reviewer: pointing v_status's two call sites
# at a name that does not exist leaves the ENTIRE council suite green, because a missing function
# inside `$( )` yields the empty string rather than failing -- so the line would render
# `posted 0/2, waiting for a,b` to a human watching a live round with nothing red anywhere
# (measured: `wc -l` of empty input prints 0, so the count is a plausible zero, not a blank).
# v_floor's identical pair is already covered (t9e asserts its waiting= list); this is its twin.
st=$(COUNCIL_ME=a bash "$CLI" status 2>&1 || true)
case "$st" in *"posted 1/2"*) ok "status reports the position count, not the message count" ;;
  *) bad "status did not report 'posted 1/2'; it said: $st" ;; esac
case "$st" in *"waiting for b"*) ok "...and names the seat whose message was not a position" ;;
  *) bad "status did not name b as still owing a position; it said: $st" ;; esac

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
# c_barrier takes its clock from min_by(.sent_ms) over c_round0_positions' output. While the one
# round-0 accessor selected on the field alone, a non-position was the anchor -- in the observed
# room, the `--help`. A stray message minutes before anybody actually spoke therefore backdated
# the deadline, and the round could close on a quorum the moment the first real position landed.
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
# No fixture that already existed for this gate carries a round-0 message whose act is not a
# position: the ones with round-0 traffic write `propose` (through a real `send` in one case and
# into a hand-written lane in the others), and the rest have no round-0 message at all. So the
# raw and narrow predicates agree in every one of them, and the suite stayed green through the
# broken version. A fixture whose act is NOT a position is what tells the two apart.
R6="$COUNCIL_TEST_ROOT/t25f"; newroom "$R6" 600000 2 a b
raw_round0 b 1 5 msg "$(now_ms)" "SECRET-B-TEXT"
[ "$(barrier a)" = open ] || bad "the gate fixture's barrier is not open, so it proves nothing"
# a is withheld from b's lane: that is the state in which the gate must refuse.
seen_a=$(COUNCIL_ME=a bash "$CLI" transcript 2>/dev/null | grep -c "SECRET-B-TEXT" || true)
[ "$seen_a" = 0 ] || bad "the fixture does not withhold b's message from a, so the gate is moot"
# ...and c_drain must agree. The withholding rule has three spellings -- c_round0_withheld, which
# the gate below asks, and the two inline `.round == 0` tests that cannot call it (c_drain's
# truncation, c_visible's lane filter). `transcript` above exercises c_visible; `recv` exercises
# c_drain, and nothing else in the suite reaches that one with a round-0 message that is NOT a
# position. They agree today; these two lines are what notices if either is narrowed alone.
#
# THE ok NAMES BOTH READERS, SO IT IS GATED ON BOTH. Asserting a two-reader property while
# measuring one is how a green line comes to contradict the FAIL above it: with c_visible
# narrowed, `seen_a` reds and a line claiming the two agree would print immediately after it.
seen_r=$(COUNCIL_ME=a bash "$CLI" recv --peek 2>/dev/null | grep -c "SECRET-B-TEXT" || true)
[ "$seen_r" = 0 ] || bad "recv released b's round-0 message that transcript withheld"
[ "$seen_a" = 0 ] && [ "$seen_r" = 0 ] \
  && ok "transcript and recv both withhold it, so c_visible and c_drain agree"

out=$(COUNCIL_ME=a bash "$CLI" decide --force 2>&1); rc=$?
[ "$rc" = 2 ] && ok "a seat that posted nothing is refused while foreign round-0 traffic is withheld" \
               || bad "decide --force returned $rc, want 2 — the disclosure gate is open again"
# WHICH exit 2, not merely exit 2. t7 records, measured, that a bare rc check on this gate also
# passes with `need_me` deleted -- a different refusal entirely. Assert the clause that is unique
# to the disclosure gate.
case "$out" in *"round-0 traffic being withheld from you"*) ok "...naming the disclosure it refused over" ;;
  *) bad "the refusal was not the disclosure gate's; it said: $out" ;; esac
[ -s "$R6/board/decision.md" ] && bad "the refused close wrote a record anyway" \
                               || ok "...and wrote no record"

# THE POSITIVE CONTROL: the same seat must still be able to clear the refusal by posting, or the
# gate is a freeze rather than a gate. This is also the self-heal for a room upgraded mid-flight.
COUNCIL_ME=a bash "$CLI" send --act propose "a's real position" >/dev/null 2>&1 \
  && ok "the refused seat can still post its own position" \
  || bad "the refused seat could not post — the gate is a wedge, not a gate"
out=$(COUNCIL_ME=a bash "$CLI" decide --force 2>&1); rc=$?
[ "$rc" = 0 ] && ok "...and that stands the refusal down at once" \
              || bad "decide --force still refused after posting (exit $rc): $out"

# AND NOW THE DISCLOSURE IS REAL, SO PROVE IT ON THE RECORD THAT EXISTS. An earlier version of
# this section grepped for the text in the record the REFUSED close did not write -- a file the
# line above had just asserted absent -- so the green line printed without testing anything, the
# very shape this file's header is about. The close that succeeded writes the record from the
# whole log (c_canon), with no act filter, so b's text IS in it: that is exactly what the gate
# was holding back a moment ago, and finding it here is what makes the refusal above meaningful.
grep -q "SECRET-B-TEXT" "$R6/board/decision.md" 2>/dev/null \
  && ok "...and the record it then wrote does carry b's text — what the gate was withholding" \
  || bad "the record does not carry b's text, so the refusal above was not protecting anything"

# THE FIXTURE CONTROL FOR THE TWO WITHHOLDING CHECKS ABOVE, and it is the same lesson a third
# time. `grep -c` over EMPTY output is 0, so `seen_a` and `seen_r` are both satisfied by a reader
# that returns NOTHING AT ALL -- for any reason, including this fixture quietly ceasing to
# produce a readable message. Measured: with `recv --peek` reduced to a bare `return 4`, every
# assertion in this section passed and the whole file went green.
#
# So close the round for real and require the SAME reader to release the SAME text. That is the
# only thing that separates "withheld" from "there was never anything to read". Note what it
# takes: `a`'s own position is not enough, because the barrier counts POSITIONS and b's lane
# holds a `msg` -- b has to state one. Writing this control is what established that; the first
# version asserted release after a's post alone and reds, correctly.
COUNCIL_ME=b bash "$CLI" send --act propose "b's real position" >/dev/null 2>&1
[ "$(barrier a)" = closed ] || bad "the control's round did not close, so it proves nothing"
back=$(COUNCIL_ME=a bash "$CLI" recv --peek 2>/dev/null | grep -c "SECRET-B-TEXT" || true)
[ "$back" -ge 1 ] && ok "...and once the round closes the same reader does release it" \
                  || bad "recv never releases b's text even with the round closed — the withholding checks above prove nothing"

# ------------------------------- 5. send-acceptance and barrier-counting must agree
echo "--- every act: accepted by send iff counted by the barrier ---"
# THE STRUCTURAL GUARD, as opposed to the act list in section 1. That list is a tripwire and a
# reviewer measured how it is defeated: widen the send predicate AND drop the act from the list
# -- a one-word edit the list invites -- and the suite goes green while the divergence is live
# (the seat sends successfully, gets an id, and `status` reports the room still waiting for it,
# which is #175 verbatim). This section is not defeated that way: it derives both sides from the
# same act table, so dropping an act from section 1 does not remove it from here. Measured: with
# `support` widened in c_opens_round AND removed from section 1's list, section 1 goes silent and
# this section still reds.
#
# WHAT IT COVERS, STATED AS A SCOPE RATHER THAN AS "WHICHEVER SIDE MOVES", WHICH IT IS NOT.
# Agreement is a weaker property than correctness: `(refused, counted 0)` is agreement too, so a
# rule that admits NOTHING satisfies the table for every act. Measured with `c_opens_round() {
# false; }` -- which section 1 calls a worse bug than the one fixed -- this table stayed green on
# all twelve and every FAIL came from other sections.
#
# So, precisely: the equivalence catches widening of the SEND predicate, and the `propose` row
# below catches NARROWING on either side. It does NOT catch widening of the COUNTING filter --
# a non-position send is refused, so nothing reaches the lane and `counted` is 0 however wide the
# filter has become. That direction is reachable only by writing a lane directly, which is what
# sections 2, 3 and 4 do, and only for the act they write. Section 1 remains the identity pin for
# the exit code and the refusal's wording. Four claims, four different assertions; do not
# collapse them into "this section covers it".
#
# The `propose` row is also this section's FIXTURE CONTROL, which it otherwise lacked: if the
# rooms stopped being built at all, every act would agree at (refused, 0) and the section would
# pass in silence. One row that must come back ACCEPTED AND COUNTED makes that impossible.
agree_ok=1
for act in propose msg notice clarify object support concede amend withdraw skip decide overrule; do
  RX="$COUNCIL_TEST_ROOT/t25g-$act"; newroom "$RX" 600000 2 a b
  COUNCIL_ME=a bash "$CLI" send --act "$act" "opening with $act" >/dev/null 2>&1; sent=$?
  counted=$(COUNCIL_ME=a bash -c '. '"$SKILL"'/lib/lib.sh; c_round0_positions' | wc -l | tr -d ' ')
  # accepted == counted, as booleans: a send that succeeded must leave exactly one position in
  # the round, and a send that was refused must leave none.
  if [ "$sent" = 0 ] && [ "$counted" != 1 ]; then
    bad "--act $act was ACCEPTED by send but the barrier counted $counted — the silent no-op of #175"
    agree_ok=0
  elif [ "$sent" != 0 ] && [ "$counted" != 0 ]; then
    bad "--act $act was REFUSED by send but the barrier counted $counted"
    agree_ok=0
  fi
  # THE POSITIVE ROW. Without it the whole table is satisfied by a rule that opens nothing.
  if [ "$act" = propose ] && { [ "$sent" != 0 ] || [ "$counted" != 1 ]; }; then
    bad "the opening act itself was not accepted-and-counted (sent=$sent counted=$counted) — the table proves nothing"
    agree_ok=0
  fi
  rm -rf "$RX"
done
[ "$agree_ok" = 1 ] && ok "send-acceptance and barrier-counting agree on every act in the table"

rm -rf "$R1" "$R2" "$R3" "$R4" "$R5" "$R6"
[ "$fail" = 0 ] && echo "t25 PASS" || echo "t25 FAIL"
exit $fail
