#!/usr/bin/env bash
# t3 — token discipline with no token file, and a hung peer that must not freeze the room.
#   * the floor is recomputed from the log by each peer independently;
#   * the speaking order rotates one step per lap;
#   * when the holder is overdue, ONLY the next peer in order may write skip.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
TURNS=${1:-24}
R="$COUNCIL_TEST_ROOT/t3"; rm -rf "$R"
mkroom "$R" a b c
export COUNCIL_ROOM="$R" ROOM="$R"
DEADLINE=$(jq -r .turn_deadline_ms "$R/roster.json")

peer() {
  local me="$1" hang="${2:-0}"
  export COUNCIL_ME="$me"
  . "$SKILL/lib/lib.sh"
  c_bell_open
  while [ "$(c_turns)" -lt "$TURNS" ]; do
    c_drain >/dev/null
    local f; f=$(c_floor)
    if [ "$f" = "$me" ]; then
      if [ "$hang" = 1 ]; then sleep 999; fi     # wedged: never speaks again
      c_send --act msg --text "turn $(c_turns) by $me" >/dev/null
      continue
    fi
    # not my floor: may I declare a skip? only if I am next AND the holder is overdue
    if [ "$(c_next_after)" = "$me" ]; then
      local age=$(( $(c_ms) - $(c_last_turn_ms) ))
      if [ "$age" -gt "$DEADLINE" ]; then
        c_send --act skip --text "$f overdue ${age}ms" >/dev/null
        continue
      fi
    fi
    c_bell_wait 0.3
  done
}
for p in a b; do peer "$p" & done
peer c 0 & CPID=$!
# Let a couple of clean laps happen, THEN wedge c — gated on the TURN COUNT, never a wall clock.
# A fixed `sleep 4` here raced the room on a fast machine: all TURNS finished before the wedge, so
# no skip was ever needed and the room's skip path went untested (the run read turns=24 skips=0).
# Gating on turns keeps the "a few clean laps first" intent while guaranteeing turns still remain
# for the wedge to force a skip, on any hardware.
turns_now() { bash "$CLI" floor | sed 's/.*turns=\([0-9]*\).*/\1/'; }
wedge_t0=$(date +%s)
while [ "$(turns_now)" -lt 6 ]; do
  [ $(( $(date +%s) - wedge_t0 )) -gt 30 ] && { echo "FAIL room never reached the pre-wedge laps"; break; }
  sleep 0.1
done
kill -STOP $CPID 2>/dev/null
echo "-- peer c wedged (SIGSTOP) after $(turns_now) turns --"
t0=$(date +%s)
while [ "$(turns_now)" -lt "$TURNS" ]; do
  [ $(( $(date +%s) - t0 )) -gt 40 ] && { echo "FAIL room froze with a wedged peer"; break; }
  sleep 1
done
kill -CONT $CPID 2>/dev/null; sleep 0.2; jobs -p | xargs -r kill 2>/dev/null; wait 2>/dev/null

fail=0
# Canonical turns only: a message that LOST a turn conflict is kept in the log but does
# not consume a turn, so counting it here would shift every later index by one and read as
# out-of-turn speech by everybody.
bash "$CLI" order | jq -s -c '[.[]|select(.hand==false and .valid)|{from,act,turn}]' > "$R/log/turns.json"
turns=$(jq 'length' "$R/log/turns.json")
[ "$turns" -ge "$TURNS" ] || { echo "FAIL only $turns turns, wanted $TURNS"; fail=1; }
# every turn must have been taken by whoever the floor formula named at that index
n=3
# Assert on each message's OWN turn number, not on its position in the canonical list:
# the canonical order is (lamport, from), which is the causal order, and it is a separate
# sequence from the turn numbers. Reading position as turn index made this test blame the
# room for two adjacent entries whose clocks happened to sort the other way.
bad=$(jq -r --argjson n $n '
  .[] | select(.act != "skip") | "\(.turn) \(.from)"' "$R/log/turns.json" | while read -r i who; do
    lap=$(( i / n )); idx=$(( (i % n + lap) % n ))
    want=$(jq -r --argjson i "$idx" '.order[$i]' "$R/roster.json")
    [ "$who" = "$want" ] || echo "turn $i: $who spoke, floor was $want"
  done)
[ -z "$bad" ] || { echo "FAIL out-of-turn speech:"; echo "$bad"; fail=1; }
skips=$(jq '[.[]|select(.act=="skip")]|length' "$R/log/turns.json")
conf=$(bash "$CLI" order | jq -s '[.[]|select(.hand==false and (.valid|not))]|length')
echo "turns=$turns skips=$skips conflicts=$conf (c was wedged for most of the run)"
[ "$skips" -gt 0 ] || { echo "FAIL nobody skipped the wedged peer"; fail=1; }
# a skip is only legal from the peer who is next after the one being skipped

# --- the room's FIRST turn is measurable, so its first holder can be skipped ------
# The run above wedges c only after six turns, so it never exercises turn 0 — and turn 0 is
# where the room used to freeze for good. Barrier positions and `--hand` messages are stamped
# `turn: null`, so before anybody has taken a turn there is no turn to measure from, and
# `held_ms` answered 0 no matter how long the first holder sat there. protocol/_channel.md
# gates `skip` on `held_ms` past `deadline_ms`, so a first holder that never starts could never
# be skipped by the rule participants are given — a total freeze at turns=0, with `status`
# raising nothing, because its STALL arm reads the same number.
#
# c_floor_held_ms anchors on the room's creation while no turn has been claimed. Asserted on
# BOTH verbs: they used to derive this separately and the whole point is that they no longer do.
R2="$COUNCIL_TEST_ROOT/t3-first-turn"; rm -rf "$R2"
mkroom "$R2" a b c
# created_ms four seconds ago: past this room's 3000ms turn_deadline_ms, and far under the
# 900s STALL threshold, so this asserts the participant's gate and not the supervisor's alarm.
jq --argjson cms "$(( 10#${EPOCHREALTIME/./} / 1000 - 4000 ))" '.created_ms = $cms' \
  "$R2/roster.json" > "$R2/r.tmp" && mv "$R2/r.tmp" "$R2/roster.json"
fl=$(COUNCIL_ROOM="$R2" bash "$CLI" floor)
held=$(printf '%s' "$fl" | sed -n 's/.*held_ms=\([^ ]*\).*/\1/p')
dl=$(printf '%s' "$fl" | sed -n 's/.*deadline_ms=\([^ ]*\).*/\1/p')
if [ "${held:-0}" -gt "$dl" ]; then
  echo "ok   before the first turn, floor times the holder from the room (held_ms=$held > $dl)"
else
  echo "FAIL a room with no turns yet reports held_ms=$held, so its first holder can never be skipped"; fail=1
fi
# The supervisor's display reads the same number, so it must not still say 0s.
sh=$(COUNCIL_ROOM="$R2" bash "$CLI" status 2>/dev/null | sed -n 's/.*(held \([0-9]*\)s).*/\1/p')
if [ "${sh:-0}" -ge 3 ]; then echo "ok   status renders the same held figure ($sh""s)"
else echo "FAIL status still reports held ${sh}s before the first turn"; fail=1; fi
# ...and the seat floor names as next= can actually skip on that basis.
nx=$(printf '%s' "$fl" | sed -n 's/.*next=\([^ ]*\).*/\1/p')
ho=$(printf '%s' "$fl" | sed -n 's/.*floor=\([^ ]*\).*/\1/p')
if COUNCIL_ROOM="$R2" COUNCIL_ME="$nx" bash "$CLI" send --act skip "$ho overdue" >/dev/null 2>&1 \
   && [ "$(COUNCIL_ROOM="$R2" bash "$CLI" floor | sed -n 's/.*turns=\([0-9]*\).*/\1/p')" = 1 ]; then
  echo "ok   $nx skipped the first holder $ho and the room moved to turn 1"
else
  echo "FAIL the first holder could not be skipped"; fail=1
fi

# An OPEN barrier is the exemption: every opening position is turn:null by design and the round
# may legitimately run for minutes, so timing the floor from the room's creation there would
# raise a STALL on a perfectly healthy room. held must stay 0 while the round is open.
R3="$COUNCIL_TEST_ROOT/t3-open-barrier"; rm -rf "$R3"
mkroom "$R3" a b c
jq --argjson cms "$(( 10#${EPOCHREALTIME/./} / 1000 - 4000 ))" \
   '.mode = "roundtable" | .round_deadline_ms = 600000 | .created_ms = $cms' \
  "$R3/roster.json" > "$R3/r.tmp" && mv "$R3/r.tmp" "$R3/roster.json"
COUNCIL_ROOM="$R3" COUNCIL_ME=a bash "$CLI" send --act propose "my position" >/dev/null 2>&1
bh=$(COUNCIL_ROOM="$R3" bash "$CLI" status 2>/dev/null | sed -n 's/.*(held \([0-9]*\)s).*/\1/p')
if [ "${bh:-1}" = 0 ]; then echo "ok   an open barrier round still reports held 0s (no false STALL)"
else echo "FAIL an open barrier round reported held ${bh}s — a healthy room would alarm"; fail=1; fi

[ "$fail" = 0 ] && echo "t3 PASS" || echo "t3 FAIL"
exit $fail
