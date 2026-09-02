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
