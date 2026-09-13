#!/usr/bin/env bash
# t21 — a blocked participant is told apart from a thinking one, and the supervisor is TOLD.
#
# THE DEFECT. `status` could report a long-held floor and nothing else, so it guessed a cause —
# "it may be sitting on a permission prompt" — and a supervisor had to capture the terminal by hand
# to find out. Worse, the room's documented remedy for a seat that will not move is
# `council.sh relaunch`, which is right for a dead seat and destroys a live one: a seat parked on a
# capacity limit resumes by itself, and a seat on a first-launch trust prompt needs that prompt
# answered IN PLACE. Guessing wrong in either direction costs the seat's reading of the argument.
#
# WHAT IS ASSERTED HERE, and the bias it pins. The read is a screen read, and this repo's law
# (AGENTS.md, "anchor on chrome, never on anything it can type") says any screen predicate is
# forgeable by an agent whose work IS that predicate — which a council seat arguing about this very
# feature literally is. So the adversarial cases below matter more than the positive one: a seat
# QUOTING the banner in its own output must still read as stalled, and a kind whose pane nobody has
# captured must not be given the exemption at all. Every gate is a reason to give up, never a
# reason to clear, so a miss falls through to the alarm that existed before this change.
#
# NO TERMINALS. The capture is replaced through COUNCIL_WAIT_SCREEN_FILE, the one documented seam;
# the classification (shared/adapters) and the disposition (shared/policy) are the real ones, so
# what the test exercises is the wiring and the gates, not a re-implementation of either.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}

# A room whose floor reads as held far past the stall threshold, with a declared agent kind per
# seat. Pushing `created_ms` back is what ages it: a token room that has never moved times its
# first holder from that field (c_floor_held_ms), and the room's age comes from the same field, so
# the two stay consistent and `status` takes its ordinary branch rather than the clock-wrong one.
stalled_room() { # <dir> <kind> <peer>...
  local room="$1" kind="$2"; shift 2
  mkroom "$room" "$@"
  local peers; peers=$(printf '%s\n' "$@" | jq -R . | jq -s --arg k "$kind" \
    '[.[] | {name: ., kind: $k, role: "peer"}]')
  jq --argjson cms "$(( 10#${EPOCHREALTIME/./} / 1000 - 7200000 ))" --argjson p "$peers" \
     '.created_ms = $cms | .peers = $p' "$room/roster.json" > "$room/roster.tmp" \
    && mv "$room/roster.tmp" "$room/roster.json"
}

notices() { # <room-basename> — how many escalations this room has pushed
  ls "$POLICY_MAILBOX_DIR"/council-"$1"-*.json 2>/dev/null | wc -l | tr -d ' '
}

# Every screen below ends with the line that decides it: adp_wait_class clears a banner the moment
# the client renders something of its own after it, so ordering is part of each fixture.
BANNER="$COUNCIL_TEST_ROOT/screen-banner"
printf '%s\n' \
  '⏺ Reading the agenda' \
  '⚠ Usage limit reached · continuing automatically at 2am' > "$BANNER"

QUOTED="$COUNCIL_TEST_ROOT/screen-quoted"
printf '%s\n' \
  '⏺ The alarm we are replacing guesses "it may be sitting on a permission prompt"' \
  '⏺ The line it should match is ⚠ Usage limit reached, in column one' > "$QUOTED"

INDENTED="$COUNCIL_TEST_ROOT/screen-indented"
printf '%s\n' \
  '⏺ Here is the banner shape, quoted from the module:' \
  '    ⚠ Usage limit reached · continuing automatically at 2am' > "$INDENTED"

STALE="$COUNCIL_TEST_ROOT/screen-stale"
printf '%s\n' \
  '⚠ Usage limit reached · continuing automatically at 2am' \
  '⏺ …and then it resumed, worked for an hour, and stopped again' > "$STALE"

QUIET="$COUNCIL_TEST_ROOT/screen-quiet"
printf '%s\n' 'Waiting.' > "$QUIET"

# --- 1. an announced capacity wait reads as a WAIT, not as a stall -------------------------
R1="$COUNCIL_TEST_ROOT/t21a"; stalled_room "$R1" claude alpha beta
out=$(COUNCIL_ROOM="$R1" COUNCIL_WAIT_SCREEN_FILE="$BANNER" bash "$CLI" status 2>&1)
ok "a live banner raises WAITING"            1 "$(printf '%s' "$out" | grep -c '⏳ WAITING')"
ok "...and not STALL"                        0 "$(printf '%s' "$out" | grep -c '🛑 STALL')"
ok "...naming the class from the adapter"    1 "$(printf '%s' "$out" | grep -c 'rate_limited')"
ok "...printing the line that bought it"     1 "$(printf '%s' "$out" | grep -c 'Evidence: ⚠ Usage limit reached')"
# The sentence is policy's (policy_park_advice), so this asserts the WIRING, not a copy of it.
ok "...carrying policy's park advice"        1 "$(printf '%s' "$out" | grep -c 'self-healing wait')"
# The whole point of telling the two apart: the remedy for a wedge must be refused here.
ok "...and refusing relaunch"                1 "$(printf '%s' "$out" | grep -c 'Do NOT relaunch')"
ok "a self-healing wait wakes nobody"        0 "$(notices t21a)"

# --- 2. the adversarial screens: a seat CANNOT talk its way out of its own alarm ------------
# These are the cases this repo has already shipped twice in the other direction. A seat working on
# the council skill quotes the banner as a matter of course; if that cleared the alarm, the room
# would report a wedged seat as fine for as long as the transcript held the quote.
R2="$COUNCIL_TEST_ROOT/t21b"; stalled_room "$R2" claude alpha beta
out=$(COUNCIL_ROOM="$R2" COUNCIL_WAIT_SCREEN_FILE="$QUOTED" bash "$CLI" status 2>&1)
ok "a seat QUOTING the banner still stalls"  1 "$(printf '%s' "$out" | grep -c '🛑 STALL')"
ok "...and is not reported as waiting"       0 "$(printf '%s' "$out" | grep -c '⏳ WAITING')"

R3="$COUNCIL_TEST_ROOT/t21c"; stalled_room "$R3" claude alpha beta
out=$(COUNCIL_ROOM="$R3" COUNCIL_WAIT_SCREEN_FILE="$INDENTED" bash "$CLI" status 2>&1)
ok "an INDENTED banner is not column one"    1 "$(printf '%s' "$out" | grep -c '🛑 STALL')"

# A banner the client has spoken past is history, not a current wait — the adapter's staleness
# rule. Without it, a seat that hit a limit an hour ago and has since genuinely wedged reads as
# "waiting, nothing to do", which is the silent stall with a reassurance attached.
R4="$COUNCIL_TEST_ROOT/t21d"; stalled_room "$R4" claude alpha beta
out=$(COUNCIL_ROOM="$R4" COUNCIL_WAIT_SCREEN_FILE="$STALE" bash "$CLI" status 2>&1)
ok "a banner spoken past is not a live wait" 1 "$(printf '%s' "$out" | grep -c '🛑 STALL')"

# --- 3. the per-kind gate: no captured pane, no exemption ----------------------------------
# The banner anchor rests on captures of two clients. council admits a third kind, and nobody has
# captured where ITS client puts the agent's own words — so the same screen must not clear the
# alarm for it. This is the gate in shared/adapters (adp_wait_anchored), asserted from council
# because council is the caller with the wider admission set.
R5="$COUNCIL_TEST_ROOT/t21e"; stalled_room "$R5" agy alpha beta
out=$(COUNCIL_ROOM="$R5" COUNCIL_WAIT_SCREEN_FILE="$BANNER" bash "$CLI" status 2>&1)
ok "an unanchored kind gets no exemption"    1 "$(printf '%s' "$out" | grep -c '🛑 STALL')"
ok "...even with the very same banner"       0 "$(printf '%s' "$out" | grep -c '⏳ WAITING')"

# A room built without `.peers` at all — every room made before `up` recorded the field, and every
# room these tests build by hand — has no kind to gate on and therefore gets no exemption either.
R6="$COUNCIL_TEST_ROOT/t21f"; stalled_room "$R6" claude alpha beta
jq 'del(.peers)' "$R6/roster.json" > "$R6/r.tmp" && mv "$R6/r.tmp" "$R6/roster.json"
out=$(COUNCIL_ROOM="$R6" COUNCIL_WAIT_SCREEN_FILE="$BANNER" bash "$CLI" status 2>&1)
ok "a roster with no kinds gets no exemption" 1 "$(printf '%s' "$out" | grep -c '🛑 STALL')"

# --- 4. the STALL line no longer guesses, and says which remedy goes with which cause -------
R7="$COUNCIL_TEST_ROOT/t21g"; stalled_room "$R7" claude alpha beta
out=$(COUNCIL_ROOM="$R7" COUNCIL_WAIT_SCREEN_FILE="$QUIET" bash "$CLI" status 2>&1)
ok "an unexplained stall still alarms"       1 "$(printf '%s' "$out" | grep -c '🛑 STALL')"
ok "...and says a prompt is answered in place" 1 "$(printf '%s' "$out" | grep -c 'ANSWERED IN PLACE')"
ok "...and scopes relaunch to a dead seat"   1 "$(printf '%s' "$out" | grep -c 'only for a seat that is genuinely dead')"

# --- 5. the push: an unexplained stall reaches the shared mailbox, once --------------------
# `status` is a symptom readout and it needs someone to be looking. This is the half that makes an
# unattended room able to say when it stopped being unattended, through the same fire-and-forget
# channel `decide` uses for a room that closed unresolved.
ok "an unexplained stall pushes a notice"    1 "$(notices t21g)"
kind=$(jq -r '.kind' "$(ls "$POLICY_MAILBOX_DIR"/council-t21g-*.json | head -1)")
ok "...as a notice, not a question"          notice "$kind"
body=$(cat "$(ls "$POLICY_MAILBOX_DIR"/council-t21g-*.json | head -1)")
ok "...naming the seat that holds the floor" 0 "$(printf '%s' "$body" | grep -qF 'alpha has been held'; echo $?)"
ok "...and carrying the two remedies"        0 "$(printf '%s' "$body" | grep -qF 'answered IN PLACE'; echo $?)"

COUNCIL_ROOM="$R7" COUNCIL_WAIT_SCREEN_FILE="$QUIET" bash "$CLI" status >/dev/null 2>&1
COUNCIL_ROOM="$R7" COUNCIL_WAIT_SCREEN_FILE="$QUIET" bash "$CLI" status >/dev/null 2>&1
ok "polling status does not accrue notices"  1 "$(notices t21g)"

# The latch is the floor holder and the turn count, so a room that MOVES and stalls again is a new
# event and notifies afresh. Asserted by moving the room the only way that leaves the floor old:
# a message written straight into a lane, which claims the turn without restamping the clock.
ROOM="$R7" raw_msg alpha 1 1 1 msg '[]' "still here" >/dev/null
COUNCIL_ROOM="$R7" COUNCIL_WAIT_SCREEN_FILE="$QUIET" bash "$CLI" status >/dev/null 2>&1
ok "a room that moved and stalled again notifies" 2 "$(notices t21g)"

# --- 6. a CLOSED room is nobody's emergency ------------------------------------------------
# Its floor stops meaning anything the moment the record is written, and `decide` has already
# escalated the one closure that needs a person.
R8="$COUNCIL_TEST_ROOT/t21h"; stalled_room "$R8" claude alpha beta
mkdir -p "$R8/board"; printf 'decided' > "$R8/board/status"
printf '# decision\n\nstatus: **decided**\n' > "$R8/board/decision.md"
COUNCIL_ROOM="$R8" COUNCIL_WAIT_SCREEN_FILE="$QUIET" bash "$CLI" status >/dev/null 2>&1
ok "a closed room pushes nothing"            0 "$(notices t21h)"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then echo "t21 PASS ($CHECKS checks)"; else echo "t21 FAIL ($FAILURES/$CHECKS)"; exit 1; fi
