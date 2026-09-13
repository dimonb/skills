#!/usr/bin/env bash
# t22 — what a stalled seat's own terminal says, added to the room's alarm and never able to
# remove it, plus the push that carries a stall out of the console and into the shared mailbox.
#
# THE DEFECT. `status` could report a long-held floor and nothing else, so it guessed a cause —
# "it may be sitting on a permission prompt" — and finding out meant a human capturing the terminal
# by hand. The guess mattered because the room's remedy for a seat that will not move is
# `council.sh relaunch`, which is right for a dead seat and destroys a live one: a seat parked on a
# capacity limit resumes by itself, and a seat on a first-launch trust prompt needs that prompt
# answered IN PLACE.
#
# THE PROPERTY MOST OF THIS FILE PINS is the one the first draft got wrong. Everything the read
# keys on is peer-writable — the roster's `kind`, the container pin, the pane itself — so the
# classification is EVIDENCE, not a verdict:
#
#   untrusted evidence may ANNOTATE an operator-facing signal, never SUPPRESS one.
#
# A draft that let a recognised banner replace the alarm let a seat silence the supervisor's alarm
# about itself with two lines of `jq`, which is worse than the blindness it was fixing, because the
# supervisor stops looking. So every case below that supplies a classifiable screen asserts the
# STALL line and the pushed notice are STILL THERE, and the adversarial screens assert no sentence
# is added that the evidence does not support.
#
# NO TERMINALS. The capture is replaced through COUNCIL_WAIT_SCREEN_FILE, the one documented seam;
# the classification (shared/adapters) and the disposition (shared/policy) are the real ones, so
# what this exercises is the wiring and the gates, not a re-implementation of either.
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
  # Anchored on the entry's full shape (`council-<room>-<n>.json`), not globbed on a prefix. The
  # glob form counts a SIBLING room's entries too — `council-x-*.json` matches `council-x-2-1.json`
  # — which is the same over-match that made the production de-duplication drop a room's notice,
  # and it would have made the regression case below pass for the wrong reason.
  ls "$POLICY_MAILBOX_DIR" 2>/dev/null | grep -cE "^council-$1-[0-9]+\.json$"
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

# --- 1. THE INVARIANT: a recognised banner annotates the alarm and does not remove it -------
# If this pair ever goes green the other way round, the feature has become a way for a seat to
# report itself healthy. The notice count is half the assertion: the push is the channel that
# reaches a person who is not reading the console, and it must survive the annotation too.
R1="$COUNCIL_TEST_ROOT/t22a"; stalled_room "$R1" claude alpha beta
out=$(COUNCIL_ROOM="$R1" COUNCIL_WAIT_SCREEN_FILE="$BANNER" bash "$CLI" status 2>&1)
ok "a live banner does NOT remove the alarm" 1 "$(printf '%s' "$out" | grep -c '🛑 STALL')"
ok "...nor the push"                         1 "$(notices t22a)"
ok "...and is added as an annotation"        1 "$(printf '%s' "$out" | grep -c 'its pane carries a live rate_limited banner')"
ok "...naming the class from the adapter"    1 "$(printf '%s' "$out" | grep -c 'rate_limited')"
ok "...printing the line it matched"         1 "$(printf '%s' "$out" | grep -c 'Evidence: ⚠ Usage limit reached')"
# The sentence is policy's (policy_park_advice), so this asserts the WIRING, not a copy of it.
ok "...carrying policy's park advice"        1 "$(printf '%s' "$out" | grep -c 'self-healing wait')"
# Presented as a quote to be checked, never as a verdict to be believed — because the pane it came
# from is one the seat itself can author.
ok "...labelled a quote, not a verdict"      1 "$(printf '%s' "$out" | grep -c 'not a verdict')"
# And the alarm does not deny what it just said. Printed unconditionally, the recognition clause
# made one line read "nothing this check recognises explains it … its pane carries a live
# rate_limited banner" — the same output asserting and denying the same fact, on the one path the
# feature exists for, with the suite green because it only ever asserted each sentence separately.
ok "...without denying its own annotation"   0 \
   "$(printf '%s' "$out" | grep -c 'Nothing this check recognises')"
# The annotation travels with the notice, so the person woken at 3am gets the same evidence as the
# person reading the console.
body=$(cat "$(ls "$POLICY_MAILBOX_DIR"/council-t22a-*.json | head -1)")
ok "the notice carries the annotation too"   1 "$(printf '%s' "$body" | grep -c 'rate_limited')"

# --- 2. the adversarial screens: a seat CANNOT talk its way into an annotation --------------
# These are the cases this repo has already shipped twice in the other direction. A seat working on
# the council skill quotes the banner as a matter of course, and an annotation it can author is a
# sentence telling a supervisor a wedged seat will recover on its own.
R2="$COUNCIL_TEST_ROOT/t22b"; stalled_room "$R2" claude alpha beta
out=$(COUNCIL_ROOM="$R2" COUNCIL_WAIT_SCREEN_FILE="$QUOTED" bash "$CLI" status 2>&1)
ok "a seat QUOTING the banner still stalls"  1 "$(printf '%s' "$out" | grep -c '🛑 STALL')"
ok "...and earns no annotation"              0 "$(printf '%s' "$out" | grep -c 'its pane carries')"

R3="$COUNCIL_TEST_ROOT/t22c"; stalled_room "$R3" claude alpha beta
out=$(COUNCIL_ROOM="$R3" COUNCIL_WAIT_SCREEN_FILE="$INDENTED" bash "$CLI" status 2>&1)
ok "an INDENTED banner is not column one"    0 "$(printf '%s' "$out" | grep -c 'its pane carries')"

# A banner the client has spoken past is history, not a current wait — the adapter's staleness
# rule. Without it, a seat that hit a limit an hour ago and has since genuinely wedged is annotated
# "it resumes by itself", which is a reassurance attached to a silent stall.
R4="$COUNCIL_TEST_ROOT/t22d"; stalled_room "$R4" claude alpha beta
out=$(COUNCIL_ROOM="$R4" COUNCIL_WAIT_SCREEN_FILE="$STALE" bash "$CLI" status 2>&1)
ok "a banner spoken past earns no annotation" 0 "$(printf '%s' "$out" | grep -c 'its pane carries')"

# --- 3. the per-kind gate: no captured pane, no claim about that client ---------------------
# The banner anchor rests on captures of two clients. council admits a third kind, and nobody has
# captured where ITS client puts the agent's own words — so `status` must not print a sentence
# about what that client's chrome means. This is the gate in shared/adapters (adp_wait_anchored),
# asserted from council because council is the caller with the wider admission set.
R5="$COUNCIL_TEST_ROOT/t22e"; stalled_room "$R5" agy alpha beta
out=$(COUNCIL_ROOM="$R5" COUNCIL_WAIT_SCREEN_FILE="$BANNER" bash "$CLI" status 2>&1)
ok "an unanchored kind earns no annotation"  0 "$(printf '%s' "$out" | grep -c 'its pane carries')"
ok "...and still alarms"                     1 "$(printf '%s' "$out" | grep -c '🛑 STALL')"

# A room built without `.peers` at all — every room made before `up` recorded the field, and every
# room these tests build by hand — has no kind to gate on and therefore gets no annotation either.
R6="$COUNCIL_TEST_ROOT/t22f"; stalled_room "$R6" claude alpha beta
jq 'del(.peers)' "$R6/roster.json" > "$R6/r.tmp" && mv "$R6/r.tmp" "$R6/roster.json"
out=$(COUNCIL_ROOM="$R6" COUNCIL_WAIT_SCREEN_FILE="$BANNER" bash "$CLI" status 2>&1)
ok "a roster with no kinds earns none"       0 "$(printf '%s' "$out" | grep -c 'its pane carries')"

# THE FORGERY THAT DECIDED THE DESIGN. The gate reads `.kind` from roster.json, which every
# participant can write, so an unanchored seat can declare itself anchored. That must buy it an
# annotation at most — never the alarm's silence, and never the mailbox's.
R6B="$COUNCIL_TEST_ROOT/t22i"; stalled_room "$R6B" agy alpha beta
jq '.peers |= map(.kind = "claude")' "$R6B/roster.json" > "$R6B/r.tmp" && mv "$R6B/r.tmp" "$R6B/roster.json"
out=$(COUNCIL_ROOM="$R6B" COUNCIL_WAIT_SCREEN_FILE="$BANNER" bash "$CLI" status 2>&1)
ok "a forged kind cannot silence the alarm"  1 "$(printf '%s' "$out" | grep -c '🛑 STALL')"
ok "...nor the push"                         1 "$(notices t22i)"

# --- 4. the STALL line no longer guesses, and says which remedy goes with which cause -------
R7="$COUNCIL_TEST_ROOT/t22g"; stalled_room "$R7" claude alpha beta
out=$(COUNCIL_ROOM="$R7" COUNCIL_WAIT_SCREEN_FILE="$QUIET" bash "$CLI" status 2>&1)
ok "an unexplained stall still alarms"       1 "$(printf '%s' "$out" | grep -c '🛑 STALL')"
ok "...and says a prompt is answered in place" 1 "$(printf '%s' "$out" | grep -c 'ANSWERED IN PLACE')"
ok "...and scopes relaunch to a dead seat"   1 "$(printf '%s' "$out" | grep -c 'only for a seat that is genuinely dead')"
# It claims only what it checked. The commonest wedge puts the reason on the terminal in plain
# words this code cannot read, so "nothing on its terminal says why" would be false.
ok "...claiming only what it checked"        1 "$(printf '%s' "$out" | grep -c 'Nothing this check recognises')"

# --- 5. the push: a stall reaches the shared mailbox, once ---------------------------------
ok "a stall pushes a notice"                 1 "$(notices t22g)"
kind=$(jq -r '.kind' "$(ls "$POLICY_MAILBOX_DIR"/council-t22g-*.json | head -1)")
ok "...as a notice, not a question"          notice "$kind"
body=$(cat "$(ls "$POLICY_MAILBOX_DIR"/council-t22g-*.json | head -1)")
ok "...naming the seat that holds the floor" 1 "$(printf '%s' "$body" | grep -cF 'alpha has been held')"
ok "...and carrying the two remedies"        1 "$(printf '%s' "$body" | grep -cF 'answered IN PLACE')"

COUNCIL_ROOM="$R7" COUNCIL_WAIT_SCREEN_FILE="$QUIET" bash "$CLI" status >/dev/null 2>&1
COUNCIL_ROOM="$R7" COUNCIL_WAIT_SCREEN_FILE="$QUIET" bash "$CLI" status >/dev/null 2>&1
ok "polling status does not accrue notices"  1 "$(notices t22g)"

# The de-duplication key is the room, the floor holder and the turn count, so a room that MOVES and
# stalls again is a new
# event and notifies afresh. Asserted by moving the room the only way that leaves the floor old:
# a message written straight into a lane, which claims the turn without restamping the clock.
ROOM="$R7" raw_msg alpha 1 1 1 msg '[]' "still here" >/dev/null
COUNCIL_ROOM="$R7" COUNCIL_WAIT_SCREEN_FILE="$QUIET" bash "$CLI" status >/dev/null 2>&1
ok "a room that moved and stalled again notifies" 2 "$(notices t22g)"

# THERE IS NO LATCH FILE, and that is the point. Nothing confines a participant — SKILL.md's "The
# room is not a trust boundary" measured all three kinds writing outside the repo entirely — so a
# latch anywhere is a file the seat the notice is about could pre-write, and pre-writing it is
# silence. The push de-duplicates against the MAILBOX instead, so suppressing it THROUGH THAT CHECK
# costs an entry where the supervisor looks. A latch planted at the path the previous design used
# is the regression guard.
R7B="$COUNCIL_TEST_ROOT/t22j"; stalled_room "$R7B" claude alpha beta
printf '%s' 'alpha 0' > "$POLICY_MAILBOX_DIR/.council-t22j.stall-latch" 2>/dev/null
COUNCIL_ROOM="$R7B" COUNCIL_WAIT_SCREEN_FILE="$QUIET" bash "$CLI" status >/dev/null 2>&1
ok "a planted latch file suppresses nothing"  1 "$(notices t22j)"
# And the de-duplication key really is what stops the second notice, not the clock: an entry
# carrying the key is enough, and it is an entry the supervisor can see.
ok "...and the key is carried in the notice"  1 \
   "$(grep -lF '[stall:t22j:alpha:0]' "$POLICY_MAILBOX_DIR"/council-t22j-*.json 2>/dev/null | wc -l | tr -d ' ')"

# THE ROOM IS IN THE KEY, and this is why. `council.sh up` names a repeated scenario `<name>-2`, so
# `x` and `x-2` are the ordinary pair rather than a contrived one — and the entry glob
# `council-x-*.json` matches `council-x-2-1.json`. With the same --agents spec both rooms have the
# same seat names, so a key of `<peer>:<turns>` alone made whichever room polled SECOND push
# nothing, permanently. Narrowing the glob cannot fix it; only a room-exact key can.
RA="$COUNCIL_TEST_ROOT/t22n"; stalled_room "$RA" claude alpha beta
RB="$COUNCIL_TEST_ROOT/t22n-2"; stalled_room "$RB" claude alpha beta
COUNCIL_ROOM="$RB" COUNCIL_WAIT_SCREEN_FILE="$QUIET" bash "$CLI" status >/dev/null 2>&1
COUNCIL_ROOM="$RA" COUNCIL_WAIT_SCREEN_FILE="$QUIET" bash "$CLI" status >/dev/null 2>&1
ok "a sibling room's notice suppresses nothing" 1 "$(notices t22n)"
ok "...and the sibling kept its own"            1 "$(notices t22n-2)"

# --- 6. a CLOSED room is nobody's emergency ------------------------------------------------
# Its floor stops meaning anything the moment the record is written, and `decide` has already
# escalated the one closure that needs a person. RESIDUAL, asserted here so it is not mistaken for
# a property: the record is two files inside the room, so a seat can forge one and stop the push.
# A forged closure also makes every other reader report the room decided, which is the larger
# pre-existing lie (#66) rather than something this gate adds.
R8="$COUNCIL_TEST_ROOT/t22h"; stalled_room "$R8" claude alpha beta
mkdir -p "$R8/board"; printf 'decided' > "$R8/board/status"
printf '# decision\n\nstatus: **decided**\n' > "$R8/board/decision.md"
out=$(COUNCIL_ROOM="$R8" COUNCIL_WAIT_SCREEN_FILE="$QUIET" bash "$CLI" status 2>&1)
ok "a closed room pushes nothing"            0 "$(notices t22h)"
# The alarm is NOT withheld, so the forgery is visible rather than silent.
ok "...but still prints its alarm"           1 "$(printf '%s' "$out" | grep -c '🛑 STALL')"

# --- 7. the clock-wrong arm keeps its wording — and still pushes ---------------------------
# `held > room_age` means the held figure came from a wrong clock, so nothing about that seat
# should be concluded from it, and the screen read does not run on this arm. v_status's header
# says the threshold is tested FIRST and the impossible-value case only chooses the WORDING.
#
# THE NOTICE COUNT IS HALF THIS CASE, and its absence was the defect a reviewer found: the first
# version of this test built exactly this room, asserted the wording, and asserted nothing about
# the push — while `_stall_escalate` sat inside the other branch. So `created_ms`, a field every
# participant can write and which only chooses between two wordings, decided whether a person was
# woken, and this test pinned that loss as correct. A case that builds an attack must assert every
# output the attack can reach.
R9="$COUNCIL_TEST_ROOT/t22k"; stalled_room "$R9" claude alpha beta
old_ms=$(( 10#${EPOCHREALTIME/./} / 1000 - 7200000 ))
jq --argjson cms "$(( 10#${EPOCHREALTIME/./} / 1000 ))" '.created_ms = $cms' \
   "$R9/roster.json" > "$R9/r.tmp" && mv "$R9/r.tmp" "$R9/roster.json"
jq -n --arg id "alpha-1" --arg from alpha --argjson lam 1 --argjson turn 1 \
      --argjson ms "$old_ms" \
  '{id:$id,from:$from,lamport:$lam,deps:{},act:"msg",refs:[],to:["*"],
    hand:false,turn:$turn,round:null,text:"long ago",created_at:"test",sent_ms:$ms}' \
  > "$R9/lane/alpha/000001.json"
printf '1' > "$R9/state/alpha.seq"
out=$(COUNCIL_ROOM="$R9" COUNCIL_WAIT_SCREEN_FILE="$BANNER" bash "$CLI" status 2>&1)
ok "an impossible held time keeps its own wording" 1 "$(printf '%s' "$out" | grep -c 'clock is wrong')"
ok "...and the annotation does not reach it"       0 "$(printf '%s' "$out" | grep -c 'its pane carries')"
ok "...and the push happens anyway"                1 "$(notices t22k)"

# --- 8. an unnamed floor degrades the notice instead of naming an empty seat ----------------
# With no floor holder and an unreadable roster, both sides of the membership test are empty and
# the member arm used to match, so the notice read "council room 'x':  has been held for 7200s".
R10="$COUNCIL_TEST_ROOT/t22l"; stalled_room "$R10" claude alpha beta
jq '.order = ["al pha", "beta"]' "$R10/roster.json" > "$R10/r.tmp" && mv "$R10/r.tmp" "$R10/roster.json"
COUNCIL_ROOM="$R10" COUNCIL_WAIT_SCREEN_FILE="$QUIET" bash "$CLI" status >/dev/null 2>&1
body=$(cat "$(ls "$POLICY_MAILBOX_DIR"/council-t22l-*.json 2>/dev/null | head -1)" 2>/dev/null)
ok "an unnamed floor degrades to the room"   0 \
   "$(printf '%s' "$body" | grep -qF "the room's floor has been held"; echo $?)"

# --- 9. the real capture path, with no seam ------------------------------------------------
# Every case above replaces the capture. This one does not: a pinned container makes _floor_screen
# take its production path, sourcing term.sh and calling ct_capture for real. Whatever the backend
# answers — and on a machine with none it answers nothing — the alarm and the push must both still
# happen, because the read can only ever annotate.
R11="$COUNCIL_TEST_ROOT/t22m"; stalled_room "$R11" claude alpha beta
printf 'no-such-container\n' > "$R11/state/container-tmux"
printf 'no-such-container\n' > "$R11/state/container-agterm"
out=$(COUNCIL_ROOM="$R11" bash "$CLI" status 2>&1)
ok "the real capture path still alarms"      1 "$(printf '%s' "$out" | grep -c '🛑 STALL')"
ok "...and still pushes"                     1 "$(notices t22m)"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then echo "t22 PASS ($CHECKS checks)"; else echo "t22 FAIL ($FAILURES/$CHECKS)"; exit 1; fi
