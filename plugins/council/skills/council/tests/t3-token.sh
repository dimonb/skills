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

# --- the floor's age before the room's first turn -------------------------------
# The run above wedges c only after six turns, so it never exercises turn 0. Barrier positions
# and `--hand` messages carry `turn: null`, so before the first turn there is no turn to
# measure from and c_floor_held_ms answers from the room's shape instead: in token mode the
# floor is order[0] from the instant the room was created, so `created_ms` is that instant
# exactly; in roundtable it is not recoverable on every path, so the answer is 0.
#
# Both halves are asserted, and both have shipped wrong. Answering 0 everywhere reinstates the
# freeze in the two shipped token scenarios; anchoring roundtable on `created_ms` charges the
# whole opening round to the first post-barrier holder, which reported a HEALTHY seat as
# hundreds of seconds overdue the instant it got the floor.
#
# `held` must be PRESENT wherever `floor` prints it: an absent field defaulting to a passing
# value let an earlier version of these cases stay green with `held_ms` deleted from the printf
# altogether — the one number every participant is told to gate a skip on.
held_of() { # <room> -- the held_ms floor prints, or the empty string if it prints none
  COUNCIL_ROOM="$1" bash "$CLI" floor 2>/dev/null | sed -n 's/.*held_ms=\([^ ]*\).*/\1/p'
}
status_held_of() { # <room> -- the held figure status renders, in seconds
  COUNCIL_ROOM="$1" bash "$CLI" status 2>/dev/null | sed -n 's/.*(held \([0-9-]*\)s).*/\1/p'
}
# <label> <room> -- floor must print held_ms, and it must be 0; status must agree.
held_is_zero() {
  local held sh; held=$(held_of "$2"); sh=$(status_held_of "$2")
  if [ -z "$held" ]; then echo "FAIL $1: floor printed no held_ms at all"; fail=1
  elif [ "$held" != 0 ]; then echo "FAIL $1: floor reported held_ms=$held, wanted 0"; fail=1
  elif [ "${sh:-x}" != 0 ]; then echo "FAIL $1: status reported held ${sh}s, wanted 0"; fail=1
  else echo "ok   $1: held is 0 (floor and status agree)"; fi
}

# A token room with no turns yet: the floor has been a's since the room was created, so the age
# is known and must be reported. created_ms is 4s back, past this room's 3000ms deadline.
R2="$COUNCIL_TEST_ROOT/t3-token-no-turn"; rm -rf "$R2"
mkroom "$R2" a b c
jq --argjson cms "$(( 10#${EPOCHREALTIME/./} / 1000 - 4000 ))" '.created_ms = $cms' \
  "$R2/roster.json" > "$R2/r.tmp" && mv "$R2/r.tmp" "$R2/roster.json"
h2=$(held_of "$R2"); s2=$(status_held_of "$R2")
d2=$(COUNCIL_ROOM="$R2" bash "$CLI" floor | sed -n 's/.*deadline_ms=\([^ ]*\).*/\1/p')
if [ -z "$h2" ]; then echo "FAIL a token room with no turns: floor printed no held_ms"; fail=1
elif [ "$h2" -le "$d2" ]; then
  echo "FAIL a token room with no turns reports held_ms=$h2 (not past $d2), so its first holder can never be skipped"; fail=1
elif [ "${s2:-0}" -lt 3 ]; then
  echo "FAIL status reported held ${s2}s for a token room the floor calls ${h2}ms"; fail=1
else echo "ok   a token room times its first holder from the room ($h2 ms > $d2, status ${s2}s)"; fi
# ...and the skip itself is reachable for that seat. This asserts REACHABILITY only — c_send
# exempts `skip` from the floor check, so it passes whatever held_ms says, and it stays green
# under every mutation of the anchor above. The gate is the case above; this is the mechanism.
nx=$(COUNCIL_ROOM="$R2" bash "$CLI" floor | sed -n 's/.*next=\([^ ]*\).*/\1/p')
ho=$(COUNCIL_ROOM="$R2" bash "$CLI" floor | sed -n 's/.*floor=\([^ ]*\).*/\1/p')
if COUNCIL_ROOM="$R2" COUNCIL_ME="$nx" bash "$CLI" send --act skip "$ho overdue" >/dev/null 2>&1 \
   && [ "$(COUNCIL_ROOM="$R2" bash "$CLI" floor | sed -n 's/.*turns=\([0-9]*\).*/\1/p')" = 1 ]; then
  echo "ok   $nx skipped the wedged first holder $ho and the room moved to turn 1"
else echo "FAIL the first holder of a token room could not be skipped"; fail=1; fi

# An OPEN roundtable round: every position is turn:null by design and the round may legitimately
# run for minutes. `floor` prints the barrier line and no held_ms there, so only status is read.
R3="$COUNCIL_TEST_ROOT/t3-open-barrier"; rm -rf "$R3"
mkroom "$R3" a b c
jq --argjson cms "$(( 10#${EPOCHREALTIME/./} / 1000 - 4000 ))" \
   '.mode = "roundtable" | .round_deadline_ms = 600000 | .created_ms = $cms' \
  "$R3/roster.json" > "$R3/r.tmp" && mv "$R3/r.tmp" "$R3/roster.json"
COUNCIL_ROOM="$R3" COUNCIL_ME=a bash "$CLI" send --act propose "my position" >/dev/null 2>&1
s3=$(status_held_of "$R3")
if [ "${s3:-x}" = 0 ]; then echo "ok   an open barrier round reports held 0s (no false STALL)"
else echo "FAIL an open barrier round reported held ${s3}s — a healthy room would alarm"; fail=1; fi

# The tick AFTER a roundtable barrier closes — the case a `! c_round_open` exemption misses, and
# the one that shipped a false skip. All positions in, floor is real, no turn taken yet.
R4="$COUNCIL_TEST_ROOT/t3-barrier-just-closed"; rm -rf "$R4"
mkroom "$R4" a b c
jq --argjson cms "$(( 10#${EPOCHREALTIME/./} / 1000 - 4000 ))" \
   '.mode = "roundtable" | .round_deadline_ms = 600000 | .created_ms = $cms' \
  "$R4/roster.json" > "$R4/r.tmp" && mv "$R4/r.tmp" "$R4/roster.json"
for p in a b c; do
  COUNCIL_ROOM="$R4" COUNCIL_ME="$p" bash "$CLI" send --act propose "position of $p" >/dev/null 2>&1
done
held_is_zero "a roundtable barrier that has just closed" "$R4"
h4=$(held_of "$R4")
d4=$(COUNCIL_ROOM="$R4" bash "$CLI" floor | sed -n 's/.*deadline_ms=\([^ ]*\).*/\1/p')
if [ -n "$h4" ] && [ "$h4" -gt "${d4:-0}" ]; then
  echo "FAIL the first post-barrier holder reads as overdue (held_ms=$h4 > $d4) — a healthy seat is skippable"; fail=1
else echo "ok   the first post-barrier holder does not read as overdue"; fi

# A peer whose clock runs ahead stamps a turn in the future. A floor held for a negative time is
# not a measurement, and neither verb may render one.
R5="$COUNCIL_TEST_ROOT/t3-future-turn"; rm -rf "$R5"
mkroom "$R5" a b c
COUNCIL_ROOM="$R5" COUNCIL_ME=a bash "$CLI" send --act propose "from a fast clock" >/dev/null 2>&1
f5=$(ls "$R5"/lane/a/*.json | head -1)
jq --argjson ms "$(( 10#${EPOCHREALTIME/./} / 1000 + 60000 ))" '.sent_ms = $ms' "$f5" > "$R5/m.tmp" \
  && mv "$R5/m.tmp" "$f5"
held_is_zero "a turn stamped in the future" "$R5"

[ "$fail" = 0 ] && echo "t3 PASS" || echo "t3 FAIL"
exit $fail
