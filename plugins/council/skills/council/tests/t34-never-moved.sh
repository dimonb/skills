#!/usr/bin/env bash
# t34 — a room that has never moved raises `🛑 NEVER MOVED`, timed by the ROOM and not the floor,
# and one write to the roster cannot silence it (#158).
#
# THE DEFECT. `status`'s STALL alarm asks how long the floor has been held, and before a room's
# first turn-consuming message that has no honest answer outside a token room — so a `debate` room
# whose first seat never started read `alarms: —` for ever, and a round where no seat posted a
# position stayed OPEN for ever with no alarm at all. In a token room the STALL arm does fire, but
# its condition is the roster's `created_ms`, so one roster write turned it off.
#
# WHAT THIS PINS, per output (the alarm line AND its push), because the rule is per output:
#   * the roundtable half now alarms — open round with no position, and closed barrier, no turn;
#   * a roster `created_ms` rewritten forward does not silence it while the launch record keeps
#     the old one;
#   * a creation stamp in the future is an alarm, not a young room;
#   * a peer-writable round deadline can make it sooner, never later;
#   * the healthy path stays quiet: a long first turn below the threshold, and a room that moved;
#   * where `🛑 STALL` already fires about the same room, this defers to it rather than doubling it.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}

now_ms() { printf '%s' "$(( 10#${EPOCHREALTIME/./} / 1000 ))"; }

# Set the roster's creation time (and optionally mode) on a room built by mkroom.
set_roster() { # <room> <jq-filter> [--argjson name value]...
  local room="$1" f="$2"; shift 2
  jq "$@" "$f" "$room/roster.json" > "$room/roster.tmp" && mv "$room/roster.tmp" "$room/roster.json"
}
aged() { # <room> <seconds-old>
  set_roster "$1" '.created_ms = $c' --argjson c "$(( $(now_ms) - $2 * 1000 ))"
}
# The launch record `up` writes into the mailbox, bound to the room's physical path.
launch_record() { # <room> <created_ms>
  local path; path=$(cd "$1" && pwd -P)
  mkdir -p "$POLICY_MAILBOX_DIR"
  jq -n --arg r "$path" --argjson c "$2" '{room:$r, created_ms:$c, generation:1, seats:{}}' \
    > "$POLICY_MAILBOX_DIR/council-launch-$(basename "$path")"
}
notices() { # <room-basename> <key-fragment> — how many of this room's notices carry the fragment
  local n=0 f
  for f in "$POLICY_MAILBOX_DIR"/council-"$1"-*.json; do
    [ -f "$f" ] || continue
    case "$(basename "$f")" in "council-$1-"*[!0-9].json) continue ;; esac
    grep -qF -- "$2" "$f" && n=$((n + 1))
  done
  printf '%s' "$n"
}
st() { COUNCIL_ROOM="$1" COUNCIL_WAIT_SCREEN_FILE="${2:-$QUIET}" bash "$CLI" status 2>&1; }
cnt() { printf '%s' "$1" | grep -c -- "$2"; }

QUIET="$COUNCIL_TEST_ROOT/screen-quiet"; printf '%s\n' 'Waiting.' > "$QUIET"
RUNNING="$COUNCIL_TEST_ROOT/screen-running"
printf '%s\n' '⏺ Weighing the third option' '  ⏵⏵ esc to interrupt' > "$RUNNING"

# --- 1. a roundtable round where nobody ever posted: open for ever, and now an alarm ----------
R1="$COUNCIL_TEST_ROOT/t34a"; mkroom "$R1" alpha beta
set_roster "$R1" '.mode = "roundtable"'; aged "$R1" 8000
out=$(st "$R1")
ok "an open round with no position is still open"   1 "$(cnt "$out" 'OPEN ROUND: posted 0/2')"
ok "...and past the threshold it alarms"            1 "$(cnt "$out" '🛑 NEVER MOVED: this room was created')"
ok "...saying the round is still open"              1 "$(cnt "$out" 'the opening round is still open')"
ok "...and pushes it"                               1 "$(notices t34a '[never:')"
st "$R1" >/dev/null
ok "a second tick pushes nothing new"               1 "$(notices t34a '[never:')"
ok "--alarms-only carries it"                       1 "$(COUNCIL_ROOM="$R1" bash "$CLI" status --alarms-only 2>&1 | grep -c 'NEVER MOVED')"

# Below the threshold (the stall backstop plus twice the default round) the open round is normal.
R2="$COUNCIL_TEST_ROOT/t34b"; mkroom "$R2" alpha beta
set_roster "$R2" '.mode = "roundtable"'; aged "$R2" 3000
out=$(st "$R2")
ok "an open round younger than the threshold is quiet" 0 "$(cnt "$out" '🛑')"
ok "...and pushes nothing"                          0 "$(notices t34b '[never:')"

# The threshold is spelled from the default deadline, and a roster deadline can only lower it.
# Twice the default is a value every jq holds exactly; uncapped it would move the threshold to
# 7800s, past this room's 7000s.
R3="$COUNCIL_TEST_ROOT/t34c"; mkroom "$R3" alpha beta
set_roster "$R3" '.mode = "roundtable" | .round_deadline_ms = 1200000'; aged "$R3" 7000
ok "a longer roster round deadline does not delay it" 1 "$(cnt "$(st "$R3")" '🛑 NEVER MOVED')"
# The roundtable allowance itself: 6000s is past the 5400s backstop and inside twice the default
# round, so a default room is quiet there — and a roster deadline shorter than the default brings
# the threshold down to meet it (5400 + 2 x 60 = 5520s).
R3b="$COUNCIL_TEST_ROOT/t34c2"; mkroom "$R3b" alpha beta
set_roster "$R3b" '.mode = "roundtable"'; aged "$R3b" 6000
ok "the round allowance keeps a 6000s open round quiet" 0 "$(cnt "$(st "$R3b")" 'NEVER MOVED')"
R3c="$COUNCIL_TEST_ROOT/t34c3"; mkroom "$R3c" alpha beta
set_roster "$R3c" '.mode = "roundtable" | .round_deadline_ms = 60000'; aged "$R3c" 6000
ok "...and a shorter roster deadline makes it sooner" 1 "$(cnt "$(st "$R3c")" '🛑 NEVER MOVED')"

# --- 2. a closed barrier whose first holder never spoke --------------------------------------
# `turns` reads 2 here (the barrier's lap), which is why the alarm counts turn-consuming messages
# rather than reading `turns`.
R4="$COUNCIL_TEST_ROOT/t34d"; mkroom "$R4" alpha beta
set_roster "$R4" '.mode = "roundtable"'; aged "$R4" 8000
ROOM="$R4"; say alpha propose '[]' "alpha's position"; say beta propose '[]' "beta's position"
out=$(st "$R4")
ok "the barrier has closed"                         0 "$(cnt "$out" 'OPEN ROUND')"
ok "a closed barrier with no turn taken alarms"     1 "$(cnt "$out" '🛑 NEVER MOVED')"
first=$(COUNCIL_ROOM="$R4" bash "$CLI" floor | sed -n 's/.*floor=\([^ ]*\).*/\1/p')
ok "...naming the seat whose turn it is"            1 "$(cnt "$out" "the first turn is ${first:-?}'s")"
ok "...and pushes it"                               1 "$(notices t34d "[never:${first:-?}:")"
# One turn taken is the room moving, and the alarm has nothing to say about it.
ROOM="$R4"; say_floor msg '[]' "the first turn" >/dev/null
ok "a room that has moved does not raise it"        0 "$(cnt "$(st "$R4")" 'NEVER MOVED')"

# --- 3. one roster write does not silence it -------------------------------------------------
# A token room whose roster `created_ms` was rewritten to now: the STALL arm reads that field and
# goes quiet, and the launch record, outside the room, still says when the room was made.
R5="$COUNCIL_TEST_ROOT/t34e"; mkroom "$R5" alpha beta
launch_record "$R5" "$(( $(now_ms) - 7200000 ))"
out=$(st "$R5")
ok "the roster-only rewrite silences the STALL arm" 0 "$(cnt "$out" '🛑 STALL')"
ok "...but not the never-moved alarm"               1 "$(cnt "$out" '🛑 NEVER MOVED: this room was created 7')"
ok "...nor its push"                                1 "$(notices t34e '[never:alpha:')"
# And the record is bound to its room: another room's record is not read as this one's.
R6="$COUNCIL_TEST_ROOT/t34f"; mkroom "$R6" alpha beta
jq -n --argjson c "$(( $(now_ms) - 7200000 ))" '{room:"/elsewhere/t34f", created_ms:$c, seats:{}}' \
  > "$POLICY_MAILBOX_DIR/council-launch-t34f"
ok "a record for another room path is ignored"      0 "$(cnt "$(st "$R6")" 'NEVER MOVED')"

# --- 4. a creation stamp in the future is not a young room -----------------------------------
# Roundtable, where the STALL arm has no floor anchor and so no clock arm of its own to raise.
R7="$COUNCIL_TEST_ROOT/t34g"; mkroom "$R7" alpha beta
set_roster "$R7" '.mode = "roundtable" | .created_ms = $c' --argjson c "$(( $(now_ms) + 86400000 ))"
out=$(st "$R7")
ok "a future created_ms raises it at once"          1 "$(cnt "$out" 'how long this room has existed cannot be read')"
ok "...and pushes it under its own key"             1 "$(notices t34g '[neverclock:')"
# The same through the record alone, with an honest roster.
R8="$COUNCIL_TEST_ROOT/t34h"; mkroom "$R8" alpha beta
launch_record "$R8" "$(( $(now_ms) + 86400000 ))"
ok "a future record stamp raises it too"            1 "$(cnt "$(st "$R8")" 'cannot be read')"

# --- 5. the healthy path, and deference to a louder line --------------------------------------
# A token room's first holder thinking a long, healthy turn: 3000s, under the 5400s backstop, with
# its client mid-turn. LONG TURN is the line; this alarm must not add a 🛑 to it.
R9="$COUNCIL_TEST_ROOT/t34i"; mkroom "$R9" alpha beta
set_roster "$R9" '.peers = [{name:"alpha",kind:"claude",role:"peer"},{name:"beta",kind:"claude",role:"peer"}]'
aged "$R9" 3000; launch_record "$R9" "$(( $(now_ms) - 3000000 ))"
out=$(st "$R9" "$RUNNING")
ok "a long healthy first turn reads as LONG TURN"   1 "$(cnt "$out" '⏳ LONG TURN')"
ok "...and raises no never-moved alarm"             0 "$(cnt "$out" 'NEVER MOVED')"
# Past the backstop the STALL arm already says 🛑 about this room; one alarm, one push.
R10="$COUNCIL_TEST_ROOT/t34j"; mkroom "$R10" alpha beta
aged "$R10" 7200
out=$(st "$R10")
ok "a STALL about the same room is the one line"    1 "$(cnt "$out" '🛑 STALL: alpha has held the floor')"
ok "...and the never-moved alarm defers to it"      0 "$(cnt "$out" 'NEVER MOVED')"
ok "...pushing the stall, not a second notice"      0 "$(notices t34j '[never:')"
ok "...and the stall push is there"                 1 "$(notices t34j '[stall:alpha:')"
# The same deference to the clock-wrong STALL: a token room whose roster stamp is in the future
# raises that STALL (the floor is timed from it), and this alarm must not add a second 🛑 or push.
R12="$COUNCIL_TEST_ROOT/t34l"; mkroom "$R12" alpha beta
set_roster "$R12" '.created_ms = $c' --argjson c "$(( $(now_ms) + 86400000 ))"
out=$(st "$R12")
ok "a future stamp in a token room is one 🛑 line"  1 "$(printf '%s' "$out" | grep -o '🛑' | wc -l | tr -d ' ')"
ok "...the clock STALL, pushed under its own key"   1 "$(notices t34l '[clock:')"
ok "...and no never-moved notice beside it"         0 "$(notices t34l '[neverclock:')"
# A closed room that never moved still prints the line — a closure is two files a seat can forge —
# but says the room is recorded as closed rather than telling anyone to relaunch, and pushes nothing.
R13="$COUNCIL_TEST_ROOT/t34m"; mkroom "$R13" alpha beta
set_roster "$R13" '.mode = "roundtable"'; aged "$R13" 8000
mkdir -p "$R13/board"; printf 'unresolved' > "$R13/board/status"
printf '# decision\n\nstatus: **unresolved**\n' > "$R13/board/decision.md"
out=$(st "$R13")
ok "a closed never-moved room still alarms"         1 "$(cnt "$out" '🛑 NEVER MOVED')"
ok "...worded as a recorded close"                  1 "$(cnt "$out" 'recorded as unresolved')"
ok "...without the relaunch advice"                 0 "$(printf '%s' "$out" | grep 'NEVER MOVED' | grep -c 'relaunch')"
ok "...and pushes nothing"                          0 "$(notices t34m '[never:')"
# A fresh room says nothing at all.
R11="$COUNCIL_TEST_ROOT/t34k"; mkroom "$R11" alpha beta
ok "a fresh room raises nothing"                    0 "$(cnt "$(st "$R11")" '🛑')"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then echo "t34 PASS ($CHECKS checks)"; else echo "t34 FAIL ($FAILURES/$CHECKS)"; exit 1; fi
