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

# --- held_ms before the room's first turn: 0, and 0 everywhere ------------------
# The run above wedges c only after six turns, so it never exercises turn 0. Barrier positions
# and `--hand` messages are stamped `turn: null`, so before anybody has taken a turn there is
# no turn to measure from, and c_floor_held_ms answers 0 — deliberately, because the thing a
# caller wants there (when the current holder RECEIVED the floor) is in no message and in no
# file. protocol/_channel.md tells participants what that 0 means and hands them their own
# wait to time the holder with instead.
#
# These cases exist because the conservative answer was once replaced with a proxy anchored on
# `created_ms`, which charged the whole opening round to the first post-barrier holder: on the
# shipped `debate` defaults that reported a healthy seat as hundreds of seconds overdue the
# instant it got the floor, which protocol/_channel.md turns into a licence to consume its
# turn. Every case below is a room shape in which SOME proxy reads non-zero, so a future
# attempt to plug the 0 reds here rather than in a live room.
zero_held() { # <label> <room>
  local fl held sh
  fl=$(COUNCIL_ROOM="$2" bash "$CLI" floor 2>/dev/null)
  held=$(printf '%s' "$fl" | sed -n 's/.*held_ms=\([^ ]*\).*/\1/p')
  sh=$(COUNCIL_ROOM="$2" bash "$CLI" status 2>/dev/null | sed -n 's/.*(held \([0-9-]*\)s).*/\1/p')
  # `floor` prints no held_ms during an open barrier round; only `status` is asserted there.
  if [ -n "$held" ] && [ "$held" != 0 ]; then
    echo "FAIL $1: floor reported held_ms=$held before the room's first turn"; fail=1
  elif [ "${sh:-x}" != 0 ]; then
    echo "FAIL $1: status reported held ${sh}s before the room's first turn"; fail=1
  else
    echo "ok   $1: held is 0 before the first turn (floor and status agree)"
  fi
}

# An old room, no turns: `created_ms` is far in the past. A created_ms anchor reads ~4s here.
R2="$COUNCIL_TEST_ROOT/t3-no-turn-old-room"; rm -rf "$R2"
mkroom "$R2" a b c
jq --argjson cms "$(( 10#${EPOCHREALTIME/./} / 1000 - 4000 ))" '.created_ms = $cms' \
  "$R2/roster.json" > "$R2/r.tmp" && mv "$R2/r.tmp" "$R2/roster.json"
zero_held "a token room with no turns yet" "$R2"

# An OPEN barrier round, positions posted. Every position is turn:null by design and the round
# may legitimately run for minutes.
R3="$COUNCIL_TEST_ROOT/t3-open-barrier"; rm -rf "$R3"
mkroom "$R3" a b c
jq --argjson cms "$(( 10#${EPOCHREALTIME/./} / 1000 - 4000 ))" \
   '.mode = "roundtable" | .round_deadline_ms = 600000 | .created_ms = $cms' \
  "$R3/roster.json" > "$R3/r.tmp" && mv "$R3/r.tmp" "$R3/roster.json"
COUNCIL_ROOM="$R3" COUNCIL_ME=a bash "$CLI" send --act propose "my position" >/dev/null 2>&1
zero_held "an open barrier round" "$R3"

# The tick AFTER a long barrier closes — the case that a `! c_round_open` exemption misses and
# the one that shipped a false skip. All three positions are in, so the round is closed and the
# floor is real, but nobody has taken a turn: a created_ms anchor reads ~4s and a last-position
# anchor reads the age of the oldest position.
R4="$COUNCIL_TEST_ROOT/t3-barrier-just-closed"; rm -rf "$R4"
mkroom "$R4" a b c
jq --argjson cms "$(( 10#${EPOCHREALTIME/./} / 1000 - 4000 ))" \
   '.mode = "roundtable" | .round_deadline_ms = 600000 | .created_ms = $cms' \
  "$R4/roster.json" > "$R4/r.tmp" && mv "$R4/r.tmp" "$R4/roster.json"
for p in a b c; do
  COUNCIL_ROOM="$R4" COUNCIL_ME="$p" bash "$CLI" send --act propose "position of $p" >/dev/null 2>&1
done
zero_held "a barrier that has just closed" "$R4"
# ...and the seat it names as next= must NOT read the holder as overdue there.
fl4=$(COUNCIL_ROOM="$R4" bash "$CLI" floor 2>/dev/null)
h4=$(printf '%s' "$fl4" | sed -n 's/.*held_ms=\([^ ]*\).*/\1/p')
d4=$(printf '%s' "$fl4" | sed -n 's/.*deadline_ms=\([^ ]*\).*/\1/p')
if [ "${h4:-0}" -gt "${d4:-0}" ]; then
  echo "FAIL the first post-barrier holder reads as overdue (held_ms=$h4 > $d4) — a healthy seat is skippable"; fail=1
else
  echo "ok   the first post-barrier holder does not read as overdue"
fi

# A peer whose clock runs ahead stamps a turn in the future; a floor held for a negative time is
# not a measurement either, and `status` must not render one.
R5="$COUNCIL_TEST_ROOT/t3-future-turn"; rm -rf "$R5"
mkroom "$R5" a b c
COUNCIL_ROOM="$R5" COUNCIL_ME=a bash "$CLI" send --act propose "from a fast clock" >/dev/null 2>&1
f5=$(ls "$R5"/lane/a/*.json | head -1)
jq --argjson ms "$(( 10#${EPOCHREALTIME/./} / 1000 + 60000 ))" '.sent_ms = $ms' "$f5" > "$R5/m.tmp" \
  && mv "$R5/m.tmp" "$f5"
h5=$(COUNCIL_ROOM="$R5" bash "$CLI" floor 2>/dev/null | sed -n 's/.*held_ms=\([^ ]*\).*/\1/p')
if [ "${h5:-0}" = 0 ]; then echo "ok   a turn stamped in the future reads as held 0, not negative"
else echo "FAIL a future-stamped turn produced held_ms=$h5"; fail=1; fi

[ "$fail" = 0 ] && echo "t3 PASS" || echo "t3 FAIL"
exit $fail
