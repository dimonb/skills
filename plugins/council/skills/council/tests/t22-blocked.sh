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

# The turn-state screens (#188). What these pin is the WIRING — that a client's own mid-turn
# marker reclassifies the alarm's tier and can never remove either of its outputs. The ANCHOR is
# somebody else's to pin, and is: shared/adapters/tests/t-turn.sh drives the real read against
# verbatim captures of both clients, with their provenance in fixtures/panes.notes. These are
# minimal screens carrying the marker where that capture records it — the footer for the first
# kind, a column-one service line for the second — in the same spirit as the banner screens above.
#
# THEY ARE WRITTEN OUT, NOT BUILT FROM THE MODULE'S CONSTANTS, and that is not laziness avoided by
# accident: a fixture composed from the same expression it guards passes whatever that expression
# becomes, so it asserts nothing. One such fixture shipped in this tree and was caught by its own
# author. If a client's marker changes, this file should go red and be re-derived from a capture.
RUNNING="$COUNCIL_TEST_ROOT/screen-running"
printf '%s\n' \
  '⏺ Weighing the third option' \
  '  ⏵⏵ esc to interrupt' > "$RUNNING"

QUEUED="$COUNCIL_TEST_ROOT/screen-queued"
printf '%s\n' \
  '⏺ Still on the second option' \
  '• Messages to be submitted (1)' > "$QUEUED"

# ADVERSARIAL: a seat that simply SAYS the words. The footer anchor is positional, so prose that
# lands on the last non-empty line reads as mid-turn — a council seat arguing about this very
# feature is exactly the agent that produces it. The pair of cases below is the honest statement
# of what that buys and what it does not.
FORGED="$COUNCIL_TEST_ROOT/screen-forged"
printf '%s\n' \
  '⏺ The line the monitor reads is this one: esc to interrupt' > "$FORGED"

# An unreadable pane. `unknown` is what a FAILED capture returns as well as a blank screen, so it
# is an absence of evidence and must never buy the calmer wording.
EMPTY="$COUNCIL_TEST_ROOT/screen-empty"
: > "$EMPTY"

# Re-age a room built by `stalled_room`, whose floor otherwise reads as held for 7200s — past the
# 5400s backstop, where the pane is not consulted at all. Every case that exercises the turn-state
# tier needs a room UNDER that backstop, and hard-coding one age into the helper is what would make
# these cases pass for the wrong reason.
age_room_to() { # <dir> <seconds-held>
  local room="$1" secs="$2"
  jq --argjson cms "$(( 10#${EPOCHREALTIME/./} / 1000 - secs * 1000 ))" \
     '.created_ms = $cms' "$room/roster.json" > "$room/roster.tmp" \
    && mv "$room/roster.tmp" "$room/roster.json"
}

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
   "$(grep -lF '[stall:alpha:0]' "$POLICY_MAILBOX_DIR"/council-t22j-1.json 2>/dev/null | wc -l | tr -d ' ')"

# THE ROOM IS MATCHED AS AN EXACT FIELD, and this is why. `council.sh up` names a repeated scenario
# `<name>-2`, so `x` and `x-2` are the ordinary pair rather than a contrived one — and an entry glob
# of `council-x-*.json` matches `council-x-2-1.json`. With the same --agents spec both rooms have
# the same seat names, so matching the room by filename prefix made whichever room polled SECOND
# push nothing, permanently. An UNANCHORED tighter glob does not fix it either
# (`council-x-[0-9]*.json` eats the sibling too); an anchored pattern would, and comparing `.slot`
# with `==` does — which is what the code uses, for the reasons its header gives. The `notices`
# helper at the top of this file takes the anchored-pattern route, so both forms are exercised.
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

# --- 10. the turn-state tier: a working seat is named as one, and is still reported ---------
# #188: at 900s this alarm fired on every healthy long turn — single turns on real rooms measured
# at 24, 51, 55 and 84 minutes — so `🛑 STALL` and a pushed notice both landed on seats that were
# thinking. The issue proposed GATING the alarm on turn state. That is the forbidden shape, and
# every case here exists to keep it forbidden: the pane is the seat's own to write, so a gate would
# let a seat silence the supervisor's alarm about itself. What ships instead is a reclassification
# plus a backstop that reads no pane at all.
#
# THE PAIR THAT MATTERS is 10a with 10b. Separately each is satisfiable by a broken design — 10a
# alone passes if the alarm was simply deleted, 10b alone passes if the tier was never built. Only
# together do they say: the line changed, and nothing went quiet.

# 10a. Below the backstop, a client that says it is mid-turn changes the GLYPH and the SENTENCE.
R12="$COUNCIL_TEST_ROOT/t22p"; stalled_room "$R12" claude alpha beta; age_room_to "$R12" 1000
out=$(COUNCIL_ROOM="$R12" COUNCIL_WAIT_SCREEN_FILE="$RUNNING" bash "$CLI" status 2>&1)
ok "a mid-turn seat is named a long turn"    1 "$(printf '%s' "$out" | grep -c '⏳ LONG TURN')"
ok "...and is not called a stopped room"     0 "$(printf '%s' "$out" | grep -c '🛑 STALL')"
# EVIDENCE, NOT A VERDICT — the same labelling the banner annotation is held to, because it is the
# same untrusted pane.
ok "...labelled a quote, not a verdict"      1 "$(printf '%s' "$out" | grep -c 'not a verdict')"
# And it says when the alarm comes anyway, so a reader knows this is a delay and not a dismissal.
ok "...naming the backstop it will hit"      1 "$(printf '%s' "$out" | grep -c 'it is raised as a stall whatever the pane says')"
# AND NAMING IT WITHOUT CARRYING THE LOUD GLYPH. A supervisor's fast loop greps this channel, so a
# `🛑` inside the calm sentence matches a healthy turn and reinstates the noise #188 is about —
# through the wording of its own fix. The assertion above already went red for exactly that.
# 10b. ...AND NOTHING WENT QUIET. The push is the same event's other output, and #188's own care
#      note names the trap: an earlier or more frequent push can consume the key a later one needs.
ok "...and the push still happens"           1 "$(notices t22p)"
ok "...under the long-turn key"              1 \
   "$(grep -lF '[longturn:alpha:0]' "$POLICY_MAILBOX_DIR"/council-t22p-1.json 2>/dev/null | wc -l | tr -d ' ')"
ok "...and NOT under the stall key"          0 \
   "$(grep -lF '[stall:alpha:0]' "$POLICY_MAILBOX_DIR"/council-t22p-1.json 2>/dev/null | wc -l | tr -d ' ')"
# The notice must not send a supervisor to look at a seat that is working — that is the noise the
# issue was filed about — while still carrying the bound.
body=$(cat "$POLICY_MAILBOX_DIR/council-t22p-1.json" 2>/dev/null)
ok "...the notice says there is nothing to do yet" 1 "$(printf '%s' "$body" | grep -c 'nothing to do yet')"
ok "...and quotes the backstop"                    1 "$(printf '%s' "$body" | grep -c 'at 5400s')"

# 10c. THE BACKSTOP, on the very same room and the very same screen. This is what makes the
#      reclassification an annotation rather than a suppression: past it the read is not consulted,
#      so no arrangement of a seat's own pane keeps `🛑 STALL` away for ever.
age_room_to "$R12" 7200
out=$(COUNCIL_ROOM="$R12" COUNCIL_WAIT_SCREEN_FILE="$RUNNING" bash "$CLI" status 2>&1)
ok "past the backstop it is a stall again"   1 "$(printf '%s' "$out" | grep -c '🛑 STALL')"
ok "...and no longer a long turn"            0 "$(printf '%s' "$out" | grep -c '⏳ LONG TURN')"
# THE ASSERTION THIS WHOLE SECTION IS FOR. A shared de-duplication key would have let 10a's notice
# consume 10c's, so the backstop would print on a console nobody is reading and push nothing —
# silence bought by the calmer tier, which is exactly the trap #188's care note names.
ok "...and the backstop pushes its own notice" 2 "$(notices t22p)"
ok "...under the stall key"                    1 \
   "$(grep -lF '[stall:alpha:0]' "$POLICY_MAILBOX_DIR"/council-t22p-2.json 2>/dev/null | wc -l | tr -d ' ')"

# 10d. A FORGED marker buys the calmer line, and that is stated rather than hidden. The footer
#      anchor is positional, so a seat whose last line of prose carries the words reads as
#      mid-turn — and a seat arguing about this feature writes exactly that line. What it cannot
#      buy is silence: the push still happens, and the backstop still arrives.
R13="$COUNCIL_TEST_ROOT/t22q"; stalled_room "$R13" claude alpha beta; age_room_to "$R13" 1000
out=$(COUNCIL_ROOM="$R13" COUNCIL_WAIT_SCREEN_FILE="$FORGED" bash "$CLI" status 2>&1)
ok "a seat can talk its way into the calmer tier" 1 "$(printf '%s' "$out" | grep -c '⏳ LONG TURN')"
ok "...but not out of the push"                   1 "$(notices t22q)"
age_room_to "$R13" 7200
out=$(COUNCIL_ROOM="$R13" COUNCIL_WAIT_SCREEN_FILE="$FORGED" bash "$CLI" status 2>&1)
ok "...and not past the backstop"                 1 "$(printf '%s' "$out" | grep -c '🛑 STALL')"

# 10e. `queued` counts as mid-turn, and on the second kind it is a column-one service line rather
#      than a footer — a different place, which is why the adapter has two arms and why reasoning
#      from one kind to the other is not allowed here either.
R14="$COUNCIL_TEST_ROOT/t22r"; stalled_room "$R14" codex alpha beta; age_room_to "$R14" 1000
out=$(COUNCIL_ROOM="$R14" COUNCIL_WAIT_SCREEN_FILE="$QUEUED" bash "$CLI" status 2>&1)
ok "a queued client counts as mid-turn"      1 "$(printf '%s' "$out" | grep -c '⏳ LONG TURN')"

# 10f. THE THREE WAYS THE READ DECLINES, all below the backstop so the threshold cannot be what
#      produces the answer. Each must land on `🛑 STALL`, which is today's behaviour exactly.
#      `idle` is the wedge this tier exists to keep visible; `unknown` is an absence of evidence;
#      an unanchored kind is a client whose chrome nobody has captured.
R15="$COUNCIL_TEST_ROOT/t22s"; stalled_room "$R15" claude alpha beta; age_room_to "$R15" 1000
out=$(COUNCIL_ROOM="$R15" COUNCIL_WAIT_SCREEN_FILE="$QUIET" bash "$CLI" status 2>&1)
ok "an idle seat under the backstop stalls"  1 "$(printf '%s' "$out" | grep -c '🛑 STALL')"
ok "...and is not called a long turn"        0 "$(printf '%s' "$out" | grep -c '⏳ LONG TURN')"
# WHAT THIS PAIR ACTUALLY PINS, stated because the obvious reading is wrong and mutation proved
# it: an empty capture is stopped by `_floor_mid_turn`'s emptiness guard, NOT by `unknown` being
# absent from its list of mid-turn states. `adp_turn_state` returns `unknown` for an empty screen
# and for nothing else, so that list entry is unreachable and adding it back changes nothing any
# test can see. These two assertions guard the guard; the list is guarded by the `idle` pair above.
out=$(COUNCIL_ROOM="$R15" COUNCIL_WAIT_SCREEN_FILE="$EMPTY" bash "$CLI" status 2>&1)
ok "an unreadable pane buys nothing"         1 "$(printf '%s' "$out" | grep -c '🛑 STALL')"
ok "...and is not called a long turn"        0 "$(printf '%s' "$out" | grep -c '⏳ LONG TURN')"
R16="$COUNCIL_TEST_ROOT/t22t"; stalled_room "$R16" antigravity alpha beta; age_room_to "$R16" 1000
out=$(COUNCIL_ROOM="$R16" COUNCIL_WAIT_SCREEN_FILE="$RUNNING" bash "$CLI" status 2>&1)
ok "an unanchored kind is read at all"       0 "$(printf '%s' "$out" | grep -c '⏳ LONG TURN')"
ok "...and stalls as it always did"          1 "$(printf '%s' "$out" | grep -c '🛑 STALL')"

# 10g. THE ALARM MUST NOT DENY ITS OWN READ. "Nothing this check recognises explains it" is owed to
#      the `🛑 STALL` arm; printed under a `⏳ LONG TURN` line it denies, in the next sentence, the
#      very read that chose the line. That defect has already happened once here, when the banner
#      was the only recogniser; this is the same arm reached by a second door.
out=$(COUNCIL_ROOM="$R12" COUNCIL_WAIT_SCREEN_FILE="$QUIET" bash "$CLI" status 2>&1)
ok "an unexplained stall still says so"      1 "$(printf '%s' "$out" | grep -c 'Nothing this check recognises')"
age_room_to "$R12" 1000
out=$(COUNCIL_ROOM="$R12" COUNCIL_WAIT_SCREEN_FILE="$RUNNING" bash "$CLI" status 2>&1)
ok "a long turn does not deny its own read"  0 "$(printf '%s' "$out" | grep -c 'Nothing this check recognises')"

# 10h. THE KNOB, AND THE DIRECTION ITS FALLBACK MUST FAIL IN. `[ … -gt … ]` on a value that is not
#      a number errors and tests FALSE, so an unusable setting would quietly leave the room on the
#      calmer tier for ever — the one direction this threshold may never fail in. The fallback is
#      observable because the line quotes the effective figure.
R17="$COUNCIL_TEST_ROOT/t22u"; stalled_room "$R17" claude alpha beta; age_room_to "$R17" 1000
out=$(COUNCIL_ROOM="$R17" COUNCIL_STALL_HARD_SECS=abc COUNCIL_WAIT_SCREEN_FILE="$RUNNING" \
      bash "$CLI" status 2>&1)
ok "an unusable backstop falls back"         1 "$(printf '%s' "$out" | grep -c 'at 5400s it is raised as a stall')"
out=$(COUNCIL_ROOM="$R17" COUNCIL_STALL_HARD_SECS=100 COUNCIL_WAIT_SCREEN_FILE="$RUNNING" \
      bash "$CLI" status 2>&1)
ok "...and an operator can lower it"         1 "$(printf '%s' "$out" | grep -c '🛑 STALL')"
out=$(COUNCIL_ROOM="$R17" COUNCIL_STALL_HARD_SECS=100000 COUNCIL_WAIT_SCREEN_FILE="$RUNNING" \
      bash "$CLI" status 2>&1)
ok "...and raise it"                         1 "$(printf '%s' "$out" | grep -c '⏳ LONG TURN')"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then echo "t22 PASS ($CHECKS checks)"; else echo "t22 FAIL ($FAILURES/$CHECKS)"; exit 1; fi
