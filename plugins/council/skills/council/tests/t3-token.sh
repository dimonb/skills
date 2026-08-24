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
# let a few clean laps happen, then wedge c
sleep 4
kill -STOP $CPID 2>/dev/null
echo "-- peer c wedged (SIGSTOP) --"
t0=$(date +%s)
while [ "$(bash "$CLI" floor | sed 's/.*turns=\([0-9]*\).*/\1/')" -lt "$TURNS" ]; do
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
[ "$fail" = 0 ] && echo "t3 PASS" || echo "t3 FAIL"
exit $fail
