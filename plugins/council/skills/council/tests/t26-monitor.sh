#!/usr/bin/env bash
# t26 — the supervisor's monitor protocol: `status --only-changed`, `status --alarms-only`,
# the two stall tiers, and the closed-room-with-live-terminals alarm.
#
# WHAT THIS FILE IS REALLY GUARDING is one property, and it is the property the feature was
# asked for: a change-triggered monitor must not be able to go quiet on a room that needs a
# person. A stalled room CHANGES NOTHING — that is what being stopped means — so a filter that
# suppressed a standing alarm would be silent in exactly the case it exists to report, which is
# how a hand-rolled supervisor loop (printing on verdict changes, with the verdict sitting
# still) let a room sit until a human asked what it was doing. Every `--only-changed` assertion
# below is either "it filters" or "it refuses to filter", and the second kind is the load-bearing
# one: delete them and the flag can regress to plain suppression with a green suite.
#
# The alarm is asserted on TWO CONSECUTIVE TICKS on purpose. A signature that merely INCLUDES the
# alarm set also breaks silence when an alarm arrives, so a single-tick test passes under both
# designs and pins neither. Only the second tick separates "news once" from "news while it holds".
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
: "${COUNCIL_TEST_ROOT:=$(mktemp -d)}"

fails=0
ok() { # <what> <expected> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"; fails=$((fails+1)); fi
}

# Age a room's floor by rewriting `created_ms`, which is what `c_floor_held_ms` times a token
# room's first holder from. Held time without a wall-clock wait — a test that slept past a 300s
# threshold would be a test nobody runs.
age_room() { # <room> <seconds>
  local r="$1" back="$2" now_ms
  now_ms=$(( $(date +%s) * 1000 ))
  jq --argjson c "$(( now_ms - back * 1000 ))" '.created_ms = $c' "$r/roster.json" > "$r/roster.tmp"
  mv "$r/roster.tmp" "$r/roster.json"
}

# --- 1. the filter filters -------------------------------------------------------------
R="$COUNCIL_TEST_ROOT/t26a"; rm -rf "$R"
mkroom "$R" a b c
export COUNCIL_ROOM="$R" ROOM="$R"

out=$(bash "$CLI" status --only-changed 2>/dev/null)
ok "first tick prints" 1 "$(printf '%s' "$out" | grep -c '^=== council')"

out=$(bash "$CLI" status --only-changed 2>/dev/null)
ok "an unmoved room is silent" 0 "${#out}"

# An open room is still exit 1 while suppressed — the loop must keep watching, not conclude the
# room closed. A suppressed tick that returned 0 would BREAK the documented `&&`-exit loop and
# end supervision on the quietest room there is.
bash "$CLI" status --only-changed >/dev/null 2>&1; ok "suppressed tick still exits 1" 1 "$?"

say_floor msg '[]' "Something new." >/dev/null
out=$(bash "$CLI" status --only-changed 2>/dev/null)
ok "a moved room prints again" 1 "$(printf '%s' "$out" | grep -c '^=== council')"

# --- 2. the filter must NOT filter an alarm ---------------------------------------------
# The whole point. Age a room past the warn tier and assert the block keeps arriving.
#
# A ROOM WITH NO MESSAGES IN IT, deliberately, and this is worth knowing before reusing
# `age_room`: `c_floor_held_ms` times the floor from the last turn-consuming message's `sent_ms`
# and falls back to `created_ms` only while the room has said nothing. So aging `created_ms` on a
# room that has spoken moves nothing at all — which is how the first draft of this test asserted
# an alarm against a room whose held time was two seconds, and read the resulting silence as a
# filter bug.
RS="$COUNCIL_TEST_ROOT/t26s"; rm -rf "$RS"
mkroom "$RS" a b c
export COUNCIL_ROOM="$RS" ROOM="$RS"
age_room "$RS" 400
bash "$CLI" status --only-changed >/dev/null 2>&1      # let the signature settle on this state
t1=$(bash "$CLI" status --only-changed 2>/dev/null)
t2=$(bash "$CLI" status --only-changed 2>/dev/null)
ok "a standing alarm prints on tick N"   1 "$(printf '%s' "$t1" | grep -c '⚠️ quiet')"
ok "...and on tick N+1, unchanged"       1 "$(printf '%s' "$t2" | grep -c '⚠️ quiet')"

# Same question for the hard tier, which is the one that also wakes somebody.
h1=$(COUNCIL_STALL_SECS=100 bash "$CLI" status --only-changed 2>/dev/null)
h2=$(COUNCIL_STALL_SECS=100 bash "$CLI" status --only-changed 2>/dev/null)
ok "a standing STALL prints on tick N"   1 "$(printf '%s' "$h1" | grep -c '🛑 STALL')"
ok "...and on tick N+1, unchanged"       1 "$(printf '%s' "$h2" | grep -c '🛑 STALL')"

# --- 3. the two tiers are different in kind, not just in number --------------------------
a=$(bash "$CLI" status --alarms-only 2>/dev/null)
ok "at 400s the warn tier fires"         1 "$(printf '%s' "$a" | grep -c '⚠️ quiet')"
ok "...and the hard tier does not"       0 "$(printf '%s' "$a" | grep -c '🛑 STALL')"
ok "the warn line names the hard one"    1 "$(printf '%s' "$a" | grep -c 'at 900s')"

a=$(COUNCIL_STALL_SECS=100 bash "$CLI" status --alarms-only 2>/dev/null)
ok "past COUNCIL_STALL_SECS it is 🛑"    1 "$(printf '%s' "$a" | grep -c '🛑 STALL')"
ok "...and the warn tier stands down"    0 "$(printf '%s' "$a" | grep -c '⚠️ quiet')"

a=$(COUNCIL_STALL_WARN_SECS=100000 bash "$CLI" status --alarms-only 2>/dev/null)
ok "COUNCIL_STALL_WARN_SECS raises it"   0 "$(printf '%s' "$a" | grep -c '⚠️ quiet')"

# THE WARN TIER MUST NOT PUSH, and this is mechanical rather than a matter of taste:
# _stall_escalate de-duplicates on `[stall:<peer>:<turns>]`, so a push from the early tier would
# consume the key the real STALL needs and silence the alarm it exists to warn about.
rm -f "$POLICY_MAILBOX_DIR"/*.json 2>/dev/null
bash "$CLI" status --alarms-only >/dev/null 2>&1
n=$(ls "$POLICY_MAILBOX_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
ok "the warn tier pushes nothing" 0 "$n"

COUNCIL_STALL_SECS=100 bash "$CLI" status --alarms-only >/dev/null 2>&1
n=$(ls "$POLICY_MAILBOX_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')
ok "the hard tier still pushes" 1 "$n"

# --- 4. --alarms-only is an alarm channel, not a heartbeat -------------------------------
R2="$COUNCIL_TEST_ROOT/t26b"; rm -rf "$R2"
mkroom "$R2" a b c
export COUNCIL_ROOM="$R2" ROOM="$R2"

out=$(bash "$CLI" status --alarms-only 2>/dev/null)
ok "a clean room prints NOTHING" 0 "${#out}"
bash "$CLI" status --alarms-only >/dev/null 2>&1
ok "...and still exits 1 (the room is open)" 1 "$?"

age_room "$R2" 400
out=$(bash "$CLI" status --alarms-only 2>/dev/null)
ok "an alarmed room prints the room name" 1 "$(printf '%s' "$out" | grep -c '^=== council')"
ok "...and the alarm"                     1 "$(printf '%s' "$out" | grep -c 'alarms:.*⚠️ quiet')"
# It is the alarms ALONE — no transcript, no floor line. That is what makes a 60s cadence
# readable, and it is the difference between this and the block the 10-minute loop prints.
ok "...and nothing else"                  0 "$(printf '%s' "$out" | grep -c 'last messages')"
ok "...not even the floor line"           0 "$(printf '%s' "$out" | grep -c '^mode ')"

# --- 5. a closed room is never suppressed, and says what is still running ---------------
R3="$COUNCIL_TEST_ROOT/t26c"; rm -rf "$R3"
mkroom "$R3" a b c
export COUNCIL_ROOM="$R3" ROOM="$R3"
prop=$(say_floor propose '[]' "Arm the monitors.")
say_floor msg '[]' "Agreed." >/dev/null
say_floor msg '[]' "No objections." >/dev/null
say_floor msg '[]' "Record it." >/dev/null
holder=$(bash "$CLI" floor | sed -n 's/.*floor=\([^ ]*\).*/\1/p')
COUNCIL_ME="$holder" bash "$CLI" decide >/dev/null 2>&1 || { echo "FAIL decide refused"; exit 1; }

bash "$CLI" status --only-changed >/dev/null 2>&1
ok "a closed room exits 0 (the loop's exit condition)" 0 "$?"
# TWICE, because this is the tick the documented loop stops on: if --only-changed could swallow
# it, the end of the watch would be silence — the loudest thing this verb says arriving as
# nothing at all.
c1=$(bash "$CLI" status --only-changed 2>/dev/null)
c2=$(bash "$CLI" status --only-changed 2>/dev/null)
ok "a closed room prints on tick N"   1 "$(printf '%s' "$c1" | grep -c '^=== council')"
ok "...and on tick N+1"               1 "$(printf '%s' "$c2" | grep -c '^=== council')"

# This room was never launched with terminals (no container pin), so there is nothing to release
# and no alarm is owed. The pin guard is what keeps every hand-built and test room quiet.
ok "no pin ⇒ no terminal alarm" 0 "$(printf '%s' "$c1" | grep -c 'terminals are still up')"

# --- 6. the terminals verb ---------------------------------------------------------------
out=$(bash "$CLI" terminals 2>/dev/null); rc=$?
ok "terminals on an unlaunched room" "-" "$out"
ok "...exits 0"                      0 "$rc"

# --- 7. the signature lives OUTSIDE the room ----------------------------------------------
# A signature file inside the room would be one a participant could pre-write to buy itself
# silence on the one display a supervisor is told to watch. It goes to the shared escalation
# mailbox instead, where shipyard's reporter already keeps its own.
export COUNCIL_ROOM="$R" ROOM="$R"
bash "$CLI" status --only-changed >/dev/null 2>&1
ok "the signature is in the mailbox" 1   "$(ls "$POLICY_MAILBOX_DIR/council-status-sig-$(basename "$R")" 2>/dev/null | wc -l | tr -d ' ')"
ok "...and not in the room" 0 "$(find "$R" -name '*status-sig*' 2>/dev/null | wc -l | tr -d ' ')"
# It must not look like an escalation entry to the mailbox's readers, which glob `*.json`.
ok "...and is not a *.json entry" 0 "$(ls "$POLICY_MAILBOX_DIR"/council-status-sig-*.json 2>/dev/null | wc -l | tr -d ' ')"
# One file PER ROOM, not one shared by all of them: a shared signature would make each room's
# tick suppress the next room's, which on a fleet of rooms is silence by arithmetic.
ok "one signature per room" 1   "$(ls "$POLICY_MAILBOX_DIR/council-status-sig-$(basename "$RS")" 2>/dev/null | wc -l | tr -d ' ')"

# --- 8. the exit-code contract is unchanged by every flag ---------------------------------
# `status`'s 0/1 is what the documented loop terminates on, so a flag that shifted it would
# either end supervision early or never end it.
export COUNCIL_ROOM="$R2" ROOM="$R2"
bash "$CLI" status >/dev/null 2>&1;                 ok "open, no flags"      1 "$?"
bash "$CLI" status --alarms-only >/dev/null 2>&1;   ok "open, --alarms-only" 1 "$?"
bash "$CLI" status --only-changed >/dev/null 2>&1;  ok "open, --only-changed" 1 "$?"
export COUNCIL_ROOM="$R3" ROOM="$R3"
bash "$CLI" status >/dev/null 2>&1;                 ok "closed, no flags"      0 "$?"
bash "$CLI" status --alarms-only >/dev/null 2>&1;   ok "closed, --alarms-only" 0 "$?"
bash "$CLI" status --only-changed >/dev/null 2>&1;  ok "closed, --only-changed" 0 "$?"

# An unknown option is refused loudly rather than ignored. A silently-swallowed flag is how a
# supervisor comes to believe a filter is armed that is not.
bash "$CLI" status --nope >/dev/null 2>&1; ok "an unknown option exits 2" 2 "$?"

# --- 9. terminal liveness, over the REAL backend -------------------------------------------
# The counting itself, and the one property that matters more than the count: an UNRESOLVABLE
# read must still raise the alarm. Every input here is room state a participant can write — the
# container pin above all — and this repo's rule is that untrusted evidence may annotate an
# operator-facing signal and never suppress one. A closed room whose terminals cannot be counted
# must therefore still tell the supervisor to run `down`, or a seat could buy its own silence by
# writing one file.
export COUNCIL_ROOM="$R3" ROOM="$R3"   # the closed room from section 5
RN=$(basename "$R3")

# 9a. A pin the resolved backend disagrees with (`elsewhere`): the pin says these seats were
#     launched on agterm, this run resolved tmux. Nothing can be concluded — and the alarm must
#     appear anyway, saying exactly that.
printf 'some-container\n' > "$R3/state/container-agterm"
out=$(COUNCIL_BACKEND=tmux bash "$CLI" status --alarms-only 2>/dev/null)
ok "an unresolvable read still alarms" 1 "$(printf '%s' "$out" | grep -c 'could not be determined')"
ok "...and it says to run down"        1 "$(printf '%s' "$out" | grep -c 'council.sh down')"
out=$(COUNCIL_BACKEND=tmux bash "$CLI" terminals 2>/dev/null)
ok "terminals says ? rather than a number" "?" "$out"

# 9b. A backend that cannot answer at all (`unreachable`) — same requirement, other route.
out=$(COUNCIL_BACKEND=none-for-tests bash "$CLI" status --alarms-only 2>/dev/null)
ok "an unreachable backend still alarms" 1 "$(printf '%s' "$out" | grep -c 'could not be determined')"
rm -f "$R3/state/container-agterm"

if command -v tmux >/dev/null 2>&1; then
  # 9c/9d over a real tmux container, because the seam this is about is the backend's answer and
  # a stubbed enumeration would assert the stub. The windows are named exactly as `ct_name`
  # renders them, which is the spelling `drv_absence_class` warns must match on both sides.
  CONT="council-t26-$$"
  # Bounded by its own command, not by a trap: `_helpers.sh` owns the only EXIT trap here, and a
  # second one would replace it. A wedged or killed test therefore leaks this session for at most
  # the sleep below rather than until the machine reboots.
  tmux new-session -d -s "$CONT" -n "council-$RN-a" 'sleep 30' 2>/dev/null
  tmux new-window -t "$CONT" -n "council-$RN-b" 'sleep 30' 2>/dev/null
  printf '%s\n' "$CONT" > "$R3/state/container-tmux"

  out=$(COUNCIL_BACKEND=tmux bash "$CLI" terminals 2>/dev/null)
  ok "terminals counts the live seats" "2/3" "$out"

  out=$(COUNCIL_BACKEND=tmux bash "$CLI" status --alarms-only 2>/dev/null)
  ok "a closed room with live seats alarms" 1 "$(printf '%s' "$out" | grep -c '2 of 3 terminals are still up')"
  # It must survive the filter like every other alarm: this is the tick the monitor loop EXITS
  # on, so a suppressed one is a supervisor told nothing, once, at the only moment it mattered.
  COUNCIL_BACKEND=tmux bash "$CLI" status --only-changed >/dev/null 2>&1
  out=$(COUNCIL_BACKEND=tmux bash "$CLI" status --only-changed 2>/dev/null)
  ok "...on every tick, through --only-changed" 1 "$(printf '%s' "$out" | grep -c 'terminals are still up')"

  # 9d. The seats are gone: an honest empty answer from a backend that DID answer. No alarm is
  #     owed, and raising one here is how an operator learns to ignore the block.
  tmux kill-session -t "$CONT" 2>/dev/null
  out=$(COUNCIL_BACKEND=tmux bash "$CLI" terminals 2>/dev/null)
  ok "terminals counts zero once they are gone" "0/3" "$out"
  out=$(COUNCIL_BACKEND=tmux bash "$CLI" status --alarms-only 2>/dev/null)
  ok "a torn-down room raises nothing" 0 "$(printf '%s' "$out" | grep -c 'terminals are still up')"
  rm -f "$R3/state/container-tmux"
else
  echo "skip tmux is not installed — 9c/9d (the live-count path) did not run"
fi

# --- 10. which of the two stall remedies the alarm names ------------------------------------
# ALIVE-and-idle-at-a-prompt and GONE look identical from inside the room, and they need opposite
# moves: the prompt is answered in place and the seat keeps everything it has read, while
# `relaunch` throws all of that away. So the alarm must name the case it can corroborate, and say
# NOTHING when it cannot — a wrong confident "gone" is the expensive error, because it is the one
# that sends a supervisor to `relaunch` on a live seat mid-turn.
export COUNCIL_ROOM="$RS" ROOM="$RS"      # the open room aged past the stall tiers
SN=$(basename "$RS")
FLOOR=$(bash "$CLI" floor | sed -n 's/.*floor=\([^ ]*\).*/\1/p')

# With no container pin at all there is nothing to ask, and the alarm keeps its both-remedies
# wording rather than inventing a verdict.
out=$(COUNCIL_STALL_SECS=100 bash "$CLI" status --alarms-only 2>/dev/null)
ok "no pin ⇒ the alarm names no verdict" 0 "$(printf '%s' "$out" | grep -c 'terminal is GONE')"
ok "...and still gives both remedies"    1 "$(printf '%s' "$out" | grep -c 'ANSWERED IN PLACE')"

if command -v tmux >/dev/null 2>&1; then
  CONT2="council-t26b-$$"
  tmux new-session -d -s "$CONT2" -n "council-$SN-$FLOOR" 'sleep 30' 2>/dev/null
  printf '%s\n' "$CONT2" > "$RS/state/container-tmux"

  out=$(COUNCIL_BACKEND=tmux COUNCIL_STALL_SECS=100 bash "$CLI" status --alarms-only 2>/dev/null)
  ok "a live seat is named as NOT dead" 1 "$(printf '%s' "$out" | grep -c 'NOT a dead seat')"
  ok "...and relaunch is warned against" 1 "$(printf '%s' "$out" | grep -c 'do not relaunch it')"
  ok "...and GONE is not claimed"        0 "$(printf '%s' "$out" | grep -c 'terminal is GONE')"
  # The same sentence rides the earlier tier, which is the tier that would actually have caught
  # the measured wedges (323s and 344s, both under the hard threshold).
  out=$(COUNCIL_BACKEND=tmux bash "$CLI" status --alarms-only 2>/dev/null)
  ok "the warn tier carries it too" 1 "$(printf '%s' "$out" | grep -c 'NOT a dead seat')"

  # The seat dies. The backend answers and does not have it, so now the absence IS corroborated
  # and `relaunch` is the right move — which the alarm may finally say.
  tmux kill-session -t "$CONT2" 2>/dev/null
  out=$(COUNCIL_BACKEND=tmux COUNCIL_STALL_SECS=100 bash "$CLI" status --alarms-only 2>/dev/null)
  ok "a gone seat is named as GONE"      1 "$(printf '%s' "$out" | grep -c 'terminal is GONE')"
  ok "...and relaunch is prescribed"     1 "$(printf '%s' "$out" | grep -c "council.sh relaunch $FLOOR")"
  ok "...and the discard is spelled out" 1 "$(printf '%s' "$out" | grep -c 'discards everything')"

  # An UNCORROBORATED absence must stay silent rather than guess, and this is the assertion that
  # keeps the arm honest: the pin says these seats were launched on agterm, so a tmux run that
  # cannot see them has established nothing.
  printf 'some-container\n' > "$RS/state/container-agterm"
  rm -f "$RS/state/container-tmux"
  out=$(COUNCIL_BACKEND=tmux COUNCIL_STALL_SECS=100 bash "$CLI" status --alarms-only 2>/dev/null)
  ok "an uncorroborated absence claims nothing" 0 "$(printf '%s' "$out" | grep -c 'terminal is GONE')"
  ok "...but the STALL alarm is untouched"      1 "$(printf '%s' "$out" | grep -c '🛑 STALL')"
  rm -f "$RS/state/container-agterm"
fi

printf '\n%s\n' "$([ "$fails" = 0 ] && echo 't26: all passed' || echo "t26: $fails FAILURES")"
exit $([ "$fails" = 0 ] && echo 0 || echo 1)
