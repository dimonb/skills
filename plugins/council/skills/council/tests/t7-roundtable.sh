#!/usr/bin/env bash
# t7 — the opening barrier of `mode: roundtable`.
#   * an opening position is invisible to everyone else until the round is complete, in
#     EVERY reader — `recv`, `transcript`, `claims`, `order` and `status` — while a
#     supervisor watching the room still sees all of it, and a seat keeps seeing its own;
#   * neither a roster nobody can parse nor a peer-chosen `.lamport` lifts that;
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
#
# `$2` is deliberately UNQUOTED so a verb can carry a flag: `order` and `order --ids` are two
# different code paths and verbs.sh argues that both must be filtered, so an assertion has to
# be able to name the second one. Without the split, reverting only the `--ids` branch left
# this file green.
# shellcheck disable=SC2086
sees() { # <peer|""> <verb [flag]> <text>
  local out
  if [ -n "$1" ]; then out=$(COUNCIL_ROOM="$R" COUNCIL_ME="$1" bash "$CLI" $2 2>&1)
  else out=$(env -u COUNCIL_ME COUNCIL_ROOM="$R" bash "$CLI" $2 2>&1); fi
  case "$out" in *"$3"*) return 0 ;; *) return 1 ;; esac
}

# STDERR ALONE. `sees` folds the two streams together, which is right for asking what a
# participant was shown but structurally blind to which stream anything arrived on — the exact
# miss that put four green-but-empty assertions into an earlier change here. The withholding
# diagnostic lives on stderr and protocol/_channel.md tells a participant to recognise it by
# its opening words, so it needs an assertion that can only pass from stderr.
says_err() { # <peer> <verb> <text>
  local err
  err=$(COUNCIL_ROOM="$R" COUNCIL_ME="$1" bash "$CLI" $2 2>&1 >/dev/null)
  case "$err" in *"$3"*) return 0 ;; *) return 1 ;; esac
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
  # THE POSITIVE CONTROL, and it is not decoration: without it every assertion above is
  # satisfied by a filter that returns NOTHING. Two one-token mutations proved that — making
  # the filter yield an empty list, and dropping its `.from != $me` term so a seat loses sight
  # of its own words — and this file reported PASS for both. The section-2 positives cannot
  # cover it, because by then the barrier is closed and the filter is never exercised.
  sees a "$v" "for the first lap only" || { echo "FAIL a lost sight of its OWN position through '$v' while the round was open"; fail=1; }
done
# `order --ids` is a second code path, and verbs.sh argues it must be filtered too: an id is
# not content, but a list of them says who has posted. Reverting only that branch left this
# file green until these three lines existed.
sees c "order --ids" "a-1" && { echo "FAIL c saw a's id through 'order --ids' while the round was open"; fail=1; }
sees a "order --ids" "b-1" && { echo "FAIL a saw b's id through 'order --ids' after posting its own"; fail=1; }
sees a "order --ids" "a-1" || { echo "FAIL a lost its OWN id through 'order --ids' while the round was open"; fail=1; }
echo "the barrier holds in every reader: transcript, claims, order (and --ids) and status withhold what recv does"

# A supervisor is not a participant and owes no position. Gating it would blank the one block
# a human is told to watch, at the one moment a room is most likely to need watching.
for v in transcript status; do
  sees "" "$v" "for the first lap only" || { echo "FAIL a supervisor could not see a's position through '$v'"; fail=1; }
  sees "" "$v" "not needed at all" || { echo "FAIL a supervisor could not see b's position through '$v'"; fail=1; }
done
echo "a supervisor still sees the whole room while the round is open"

# A THIN READ MUST SAY WHY. Without this the whole diagnostic can be deleted and the suite
# stays green, while protocol/_channel.md instructs a participant to recognise the exact
# opening words and keep going, and SKILL.md promises "nothing was said" cannot be mistaken
# for "nothing was shown to you". The substring asserted is the one those two files quote.
for v in transcript claims status order; do
  says_err c "$v" "the opening round is not complete" \
    || { echo "FAIL '$v' withheld from c without saying why on stderr"; fail=1; }
done
says_err "" transcript "the opening round is not complete" \
  && { echo "FAIL a supervisor, which is withheld nothing, was told the round is incomplete"; fail=1; }
echo "a withheld read says why on stderr, and a supervisor's read does not"

# THE ROOM'S ARITHMETIC IS EXEMPT, and only an assertion taken while the round is OPEN can
# hold that: after it closes the filter is the identity and every reader agrees anyway.
# Rendering `verdict` through the barrier leaves the rest of the suite green.
vp=$(COUNCIL_ROOM="$R" COUNCIL_ME=c bash "$CLI" verdict --json 2>/dev/null)
vs=$(env -u COUNCIL_ME COUNCIL_ROOM="$R" bash "$CLI" verdict --json 2>/dev/null)
for f in live open turns; do
  [ "$(printf '%s' "$vp" | jq -r ".$f")" = "$(printf '%s' "$vs" | jq -r ".$f")" ] \
    || { echo "FAIL verdict's '$f' differs between a withheld participant and a supervisor: $(printf '%s' "$vp" | jq -r ".$f") vs $(printf '%s' "$vs" | jq -r ".$f")"; fail=1; }
done
[ "$(printf '%s' "$vp" | jq -r .live)" = 2 ] \
  || { echo "FAIL verdict did not count both posted positions for a participant: $(printf '%s' "$vp" | jq -r .live)"; fail=1; }
echo "verdict counts the whole room for a participant that is being withheld from"

# --------------------------------- 1c. a roster nobody can parse must not lift the barrier
# c_barrier's first line is a c_mode read, and c_mode is a bare jq: over a roster.json that is
# empty, truncated or missing it prints NOTHING, and over the literal `null` it prints `token`
# — so the barrier answered `closed` and never reached the `n > 0` precondition that answers
# `open`. Every reader then handed the whole log over, silently, in the state where withholding
# matters most, while `recv` (which needs c_peers) stayed deaf. t9h's unreadable-roster case
# cannot reach this: it damages `.order` in a roster that still parses.
cp "$R/roster.json" "$R/roster.good"
for shape in empty truncated null missing; do
  case "$shape" in
    empty)     : > "$R/roster.json" ;;
    truncated) printf '{"order":["a","b"' > "$R/roster.json" ;;
    null)      printf 'null' > "$R/roster.json" ;;
    missing)   rm -f "$R/roster.json" ;;
  esac
  for v in transcript claims status order; do
    sees c "$v" "for the first lap only" && { echo "FAIL a $shape roster let '$v' hand c the position the barrier withholds"; fail=1; }
    # The positive control this branch belongs to, for the same reason the round path has one:
    # every assertion above is a negative, and a branch that returns NOTHING satisfies them all.
    # Blanking a reader is the failure class this file names as its worst.
    sees a "$v" "for the first lap only" \
      || { echo "FAIL a $shape roster cost a sight of its OWN position through '$v'"; fail=1; }
  done
  says_err c transcript "the opening barrier cannot be resolved" \
    || { echo "FAIL a $shape roster withheld silently, with no word about the roster"; fail=1; }
  cp "$R/roster.good" "$R/roster.json"
done
# `two` is its own shape and not a variation: a roster of TWO documents is valid JSON whose
# LAST value is an object, so a per-value `type == "object"` test exits 0 and passes it — while
# `c_mode` prints two lines, matches neither, and the barrier is gone. The check has to ask
# about the file, which is what slurping does.
printf '\n{}\n' >> "$R/roster.json"
for v in transcript claims status order; do
  sees c "$v" "for the first lap only" && { echo "FAIL a two-document roster let '$v' hand c the position the barrier withholds"; fail=1; }
done
cp "$R/roster.good" "$R/roster.json"
echo "a roster that is not one JSON object withholds rather than lifting the barrier (empty, truncated, null, missing, two documents)"

# ------------------------- 1d. a peer cannot push its own words past the barrier
# A lane is withheld WHOLE. Cutting a prefix of it needs an order, and the only ordering key a
# message carries is `.lamport`, which the peer writes — so a peer put a second document in its
# own lane below its position's lamport and every waiting seat rendered it, while `recv` (which
# orders a lane by its file sequence) withheld it. `claims` is not asserted here: it renders
# proposals and objections only, so a `msg` act could not appear in it either way.
jq -n '{id:"a-2",from:"a",lamport:0,deps:{},act:"msg",refs:[],to:["*"],hand:false,turn:null,
        round:null,text:"a pushes its own words past the barrier",created_at:"test",sent_ms:0}' \
  > "$R/lane/a/000002.json"
printf '2' > "$R/state/a.seq"
for v in transcript status order; do
  sees c "$v" "pushes its own words past the barrier" && { echo "FAIL a pushed its own words past the barrier through '$v'"; fail=1; }
done
rm -f "$R/lane/a/000002.json"; printf '1' > "$R/state/a.seq"
echo "a peer cannot push its own words past the barrier by choosing a lamport"

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

# ...and the roster check governs the room's WHOLE LIFE, not just its opening round, because it
# runs before the barrier read. A closed round plus a damaged roster is therefore withheld too.
# That is the deliberate answer — an unresolvable barrier withholds — and it is asserted so a
# later narrowing of the check to the open round cannot ship green.
cp "$R/roster.json" "$R/roster.good2"; : > "$R/roster.json"
sees b transcript "for the first lap only" \
  && { echo "FAIL a damaged roster after the round closed handed b the positions anyway"; fail=1; }
says_err b transcript "the opening barrier cannot be resolved" \
  || { echo "FAIL a damaged roster after the round closed withheld silently"; fail=1; }
sees "" transcript "for the first lap only" \
  || { echo "FAIL a damaged roster blinded the supervisor as well"; fail=1; }
cp "$R/roster.good2" "$R/roster.json"
echo "an unresolvable barrier withholds for the room's whole life, not only during the round"

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

# THE TURN ARITHMETIC IS EXEMPT FROM THE FILTER, and this is the only fixture in the file where
# that can be shown: it needs the filter LIVE and a foreign lane holding a TURN-CLAIMING
# message, and an opening position claims no turn. So the damaged roster (which withholds for
# the room's whole life) plus b's objection above is the one state where a filtered c_turns
# would be visible — everywhere else it reads the same either way, and rendering c_turns
# through c_visible leaves the whole suite green.
cp "$R/roster.json" "$R/roster.good3"; : > "$R/roster.json"
tp=$(COUNCIL_ME=a bash -c '. '"$SKILL"'/lib/lib.sh; c_turns' 2>/dev/null)
ts=$(env -u COUNCIL_ME bash -c 'COUNCIL_ROOM="'"$R"'"; . '"$SKILL"'/lib/lib.sh; c_turns' 2>/dev/null)
[ -n "$tp" ] && [ "$tp" = "$ts" ] \
  || { echo "FAIL the turn count differs between a withheld participant and a supervisor: '$tp' vs '$ts'"; fail=1; }
cp "$R/roster.good3" "$R/roster.json"
echo "the turn count is the room's, not the reader's: $tp for a withheld seat and for a supervisor alike"

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

# ...and once the round has CLOSED, the latecomer may close the room like anyone else. This is
# the only fixture in the file where a seat has posted nothing while somebody else has AND the
# round is over, so it is the only one that can show the decide gate consulting the barrier at
# all: drop that test and the gate refuses c here for ever, on a round it can no longer join.
out=$(COUNCIL_ME=c bash "$CLI" decide --force 2>&1); rc=$?
[ "$rc" = 0 ] || { echo "FAIL a closed round refused the seat that missed it (exit $rc): $out"; fail=1; }
[ -s "$R2/board/decision.md" ] || { echo "FAIL closing a completed round wrote no record"; fail=1; }
rm -f "$R2/board/decision.md" "$R2/board/status"
echo "a seat that missed the round can still close it once the round is over"
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
# `decide --force` mid-round is reachable by any participant that has posted and by NO
# supervisor (`decide` takes `need_me`), and the record is the room's one durable output.
# Rendered through the barrier it would hold only the writer's own position, written at rc 0
# and afterwards indistinguishable from a complete record — which is this codebase's worst
# failure mode, so the record reads the log and not the seat.
R3="$COUNCIL_TEST_ROOT/t7c"; rm -rf "$R3"
mkroom "$R3" a b c
ROOM="$R3"; export COUNCIL_ROOM="$R3"
jq '.mode="roundtable" | .round_deadline_ms=600000' "$R3/roster.json" > "$R3/r.tmp" && mv "$R3/r.tmp" "$R3/roster.json"
say a propose '[]' "position a: a record must not be written through the barrier"
say b propose '[]' "position b: nor may it lose the seat that did not write it"
st=$(COUNCIL_ME=a bash -c '. '"$SKILL"'/lib/lib.sh; c_barrier')
[ "$st" = open ] || { echo "FAIL the round is $st, so the record check below proves nothing"; fail=1; }

# BOTH DIRECTIONS OF THE GATE, before the record check, because the record check itself depends
# on the allowed direction still working. Closing a room writes the record from the whole log
# and `decision` hands it to anyone, so a seat that has stated no position must not be able to
# close the round it owes one to — that is two commands away from reading everybody.
out=$(COUNCIL_ME=c bash "$CLI" decide --force 2>&1); rc=$?
[ "$rc" = 2 ] || { echo "FAIL a seat that has posted nothing closed the open round (exit $rc)"; fail=1; }
[ -s "$R3/board/decision.md" ] && { echo "FAIL the refused close wrote a record anyway"; fail=1; }
case "$out" in
  *"another seat has stated an opening position and you have not"*) ;;
  *) echo "FAIL the refusal did not say why; it said: $out"; fail=1 ;;
esac
case "$out" in
  *"Post your position first"*) ;;
  *) echo "FAIL the refusal did not name the way out; it said: $out"; fail=1 ;;
esac
# ...and a supervisor cannot reach it at all, which is why the gate has to live on the seat.
# The MESSAGE is asserted and not only the code: `need_me` and the gate both exit 2, so a bare
# `[ "$rc" = 2 ]` passes with `need_me` deleted — the gate catches the supervisor instead and
# the assertion's own failure text becomes false. Measured: it does.
out=$(env -u COUNCIL_ME COUNCIL_ROOM="$R3" bash "$CLI" decide --force 2>&1); rc=$?
[ "$rc" = 2 ] || { echo "FAIL a supervisor's decide did not stop at need_me (exit $rc)"; fail=1; }
case "$out" in
  *"who are you? set COUNCIL_ME"*) ;;
  *) echo "FAIL a supervisor's decide did not stop at need_me; it said: $out"; fail=1 ;;
esac
echo "a seat that has stated no position cannot close a round another seat has started"

# ...but a round NOBODY has posted in holds nothing to disclose, so any seat may close it. This
# is the wedge the gate had before it asked whether there was anything to buy: `c_barrier`
# returns `open` from its `[ "$first" = 0 ]` short-circuit before it consults the deadline, so
# such a round never closes on its own — every seat refused, for ever, and no supervisor able to
# run `decide` at all. The deadline here is 1ms and the fixture still proves it by consequence.
R4="$COUNCIL_TEST_ROOT/t7d"; rm -rf "$R4"
mkroom "$R4" a b c
jq '.mode="roundtable" | .round_deadline_ms=1 | .round_quorum=2' "$R4/roster.json" > "$R4/r.tmp" && mv "$R4/r.tmp" "$R4/roster.json"
sleep 0.1
st=$(COUNCIL_ROOM="$R4" COUNCIL_ME=a bash -c ". $SKILL/lib/lib.sh; c_barrier")
[ "$st" = open ] || { echo "FAIL an empty round reads $st past its own deadline, so the wedge check below proves nothing"; fail=1; }
out=$(COUNCIL_ROOM="$R4" COUNCIL_ME=c bash "$CLI" decide --force 2>&1); rc=$?
[ "$rc" = 0 ] || { echo "FAIL a round nobody had posted in could not be closed by anyone (exit $rc): $out"; fail=1; }
[ -s "$R4/board/decision.md" ] || { echo "FAIL closing an empty round wrote no record"; fail=1; }
[ "$(cat "$R4/board/status" 2>/dev/null)" = unresolved ] \
  || { echo "FAIL an empty round did not close as unresolved: $(cat "$R4/board/status" 2>/dev/null)"; fail=1; }
echo "a round nobody has posted in holds nothing to disclose, so it can still be closed"

# ...and ONCE A RECORD EXISTS the gate stands down, because `decision` already hands that record
# to anyone: refusing the rewrite would protect nothing and cost the documented exit codes. It
# needs its own room, because it is the one state the other fixtures cannot reach — a record on
# disk, a foreign `round: 0` message in the log, and a barrier still open. Closing an empty round
# produces exactly that: `c_send` stamps the closer's own trailing `decide` message `round: 0`
# (the barrier is open and it has not posted), and with a long deadline the round stays open, so
# from then on every other seat looks like a latecomer to a round it never joined.
R5="$COUNCIL_TEST_ROOT/t7e"; rm -rf "$R5"
mkroom "$R5" a b c
jq '.mode="roundtable" | .round_deadline_ms=600000' "$R5/roster.json" > "$R5/r.tmp" && mv "$R5/r.tmp" "$R5/roster.json"
COUNCIL_ROOM="$R5" COUNCIL_ME=a bash "$CLI" decide --force >/dev/null 2>&1 \
  || { echo "FAIL could not close the empty round to set up the recorded-room case"; fail=1; }
[ -n "$(COUNCIL_ROOM="$R5" COUNCIL_ME=b bash -c ". $SKILL/lib/lib.sh; c_round0" | head -1)" ] \
  || { echo "FAIL the fixture has no round-0 message, so it cannot separate the two tests"; fail=1; }
st=$(COUNCIL_ROOM="$R5" COUNCIL_ME=b bash -c ". $SKILL/lib/lib.sh; c_barrier")
[ "$st" = open ] || { echo "FAIL the fixture's barrier reads $st, so the check below proves nothing"; fail=1; }
out=$(COUNCIL_ROOM="$R5" COUNCIL_ME=b bash "$CLI" decide --force 2>&1); rc=$?
[ "$rc" = 0 ] || { echo "FAIL a room whose record is already written refused a seat (exit $rc): $out"; fail=1; }
echo "once a record exists the gate stands down: decision already hands it to anyone"

# ...and the gate asks for SOMEBODY ELSE'S position, which is not the same as asking whether any
# exists. `c_posted_round0` reads the same documents through `.id`, so a round-0 message in my
# own lane with an empty `.id` — never minted by `c_send`, but written by any hand that builds a
# lane file — reads back as "I have not posted". Without the `.from != $me` filter the gate then
# refuses the ONE seat that did post, and tells it another seat has spoken.
R6="$COUNCIL_TEST_ROOT/t7f"; rm -rf "$R6"
mkroom "$R6" a b c
jq '.mode="roundtable" | .round_deadline_ms=600000' "$R6/roster.json" > "$R6/r.tmp" && mv "$R6/r.tmp" "$R6/roster.json"
jq -n '{id:"",from:"a",lamport:1,deps:{},act:"propose",refs:[],to:["*"],hand:false,turn:null,
        round:0,text:"position a, written by hand",created_at:"test",sent_ms:1}' > "$R6/lane/a/000001.json"
printf '1' > "$R6/state/a.seq"
[ -z "$(COUNCIL_ROOM="$R6" COUNCIL_ME=a bash -c ". $SKILL/lib/lib.sh; c_posted_round0")" ] \
  || { echo "FAIL the fixture's empty id is visible to c_posted_round0, so it separates nothing"; fail=1; }
[ -n "$(COUNCIL_ROOM="$R6" COUNCIL_ME=a bash -c ". $SKILL/lib/lib.sh; c_round0" | head -1)" ] \
  || { echo "FAIL the fixture has no round-0 message at all"; fail=1; }
out=$(COUNCIL_ROOM="$R6" COUNCIL_ME=a bash "$CLI" decide --force 2>&1); rc=$?
[ "$rc" = 0 ] || { echo "FAIL the gate refused the only seat that had posted (exit $rc): $out"; fail=1; }
echo "the gate asks for another seat's position, not merely for any position"

# ...and the gate must not PREEMPT the verdict dispatch. Placed ahead of it, it answered a
# recorded room with its own refusal as soon as `c_round0` came back empty — the inversion
# v_verdict's header records as introduced and reverted twice. t9g pins the `decided` room's
# exit 3 over a damaged log, but only in a `token` room, where this gate never fires; a
# roundtable room is the case the gate put at risk, so it is pinned here, by the WORDING of the
# refusal rather than by its code — `decide` on a room recorded `unresolved` answers 2 either
# way, so only the message can tell which of the two refused.
[ "$(cat "$R4/board/status" 2>/dev/null)" = unresolved ] || { echo "FAIL the fixture is not a closed room"; fail=1; }
printf 'not json' > "$R4/lane/c/000001.json"
for who in a b c; do
  out=$(COUNCIL_ROOM="$R4" COUNCIL_ME="$who" bash "$CLI" decide 2>&1); rc=$?
  [ "$rc" = 2 ] || { echo "FAIL a closed room answered $rc to $who, not the documented 2"; fail=1; }
  case "$out" in
    *"the decision is not ripe"*) ;;
    *) echo "FAIL the gate preempted the verdict dispatch for $who on a closed room; it said: $out"; fail=1 ;;
  esac
done
echo "the gate does not preempt the verdict dispatch: a closed room still answers from its record"

COUNCIL_ME=a bash "$CLI" decide --force >/dev/null 2>&1
rec="$R3/board/decision.md"
[ -s "$rec" ] || { echo "FAIL no record was written at all"; fail=1; }
for t in "a record must not be written through the barrier" "nor may it lose the seat that did not write it"; do
  grep -qF "$t" "$rec" || { echo "FAIL the record forced mid-round is missing: $t"; fail=1; }
done
echo "a record forced mid-round holds every position, not only the writer's own"

[ "$fail" = 0 ] && echo "t7 PASS" || echo "t7 FAIL"
exit $fail
