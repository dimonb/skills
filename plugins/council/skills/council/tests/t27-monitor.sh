#!/usr/bin/env bash
# t27 — the supervisor's monitor protocol: `status --only-changed`, `status --alarms-only`,
# the quiet annotation, the closed-room terminal read, and the seat-liveness sentences.
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
#
# THE BACKEND IS A SHADOW SKILL, NOT A LIVE tmux, and that is the second thing this file is for.
# The first version of it drove a real tmux, which on a developer machine looked like strong
# coverage and on CI was none at all: CI installs no tmux, so 14 of 59 assertions vanished — nine
# of them silently — and two mutants that break this feature's whole point (deleting the
# corroboration guard, deleting the live-seat sentence) passed GREEN there. A fake also tests
# BETTER than the real thing here, because the subject is what the code does with the backend's
# ANSWERS — including "the backend did not answer", which a live tmux cannot easily be made to
# produce and a fake produces exactly. `export PATH=$FAKEBIN:$PATH` does NOT work for this skill
# (council.sh and term.sh both re-prepend /opt/homebrew/bin, so a real tmux shadows the fake), so
# this copies t24's shadow-skill pattern instead: the shipped skill with ONE file replaced, and
# that file sources the real term.sh and overrides only the enumeration.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
: "${COUNCIL_TEST_ROOT:=$(mktemp -d)}"
REAL_SKILL="$SKILL"

fails=0
ok() { # <what> <expected> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"; fails=$((fails+1)); fi
}

# Age a room's floor by rewriting `created_ms`, which is what `c_floor_held_ms` times a token
# room's first holder from. Held time without a wall-clock wait — a test that slept past a 300s
# threshold would be a test nobody runs.
#
# IT ONLY WORKS ON A ROOM THAT HAS NOT SPOKEN. `c_floor_held_ms` times from the last
# turn-consuming message's `sent_ms` and falls back to `created_ms` only while the log is empty,
# so aging a room that has sent anything moves nothing — which is how a first draft of this file
# asserted an alarm against a room whose held time was two seconds and read the silence as a bug.
age_room() { # <room> <seconds>
  local r="$1" back="$2" now_ms
  now_ms=$(( $(date +%s) * 1000 ))
  jq --argjson c "$(( now_ms - back * 1000 ))" '.created_ms = $c' "$r/roster.json" > "$r/roster.tmp"
  mv "$r/roster.tmp" "$r/roster.json"
}

# Age a room that HAS spoken. `c_floor_held_ms` times from the last turn-consuming message once
# the log is non-empty, so `age_room` moves nothing there — this is the companion for a room that
# has taken turns, which every closed room has.
#
# ALWAYS PAIR IT WITH AN OLDER `age_room`. `v_status` has two STALL wordings and only one of them
# carries the liveness read: when `held` exceeds the room's own age the alarm switches to "one
# seat's clock is wrong" and reads no terminal at all. A fixture that ages only the messages sits
# on that arm — which is how three assertions here about the liveness sentence came to pass
# against a branch that cannot produce one. Mutation caught it; reading did not. Keep
# `age_room <older>` before every `age_messages <newer>`.
age_messages() { # <room> <seconds>
  local r="$1" back="$2" now_ms f
  now_ms=$(( $(date +%s) * 1000 ))
  for f in "$r"/lane/*/*.json; do
    [ -f "$f" ] || continue
    jq --argjson s "$(( now_ms - back * 1000 ))" '.sent_ms = $s' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done
}

# --- the shadow skill ----------------------------------------------------------------------
# Everything is the shipped skill except lib/term.sh, which SOURCES the shipped one and then
# overrides `ct_sessions` alone. So `ct_name`, `ct_backend`, `ct_absence_class` and
# `drv_pins_elsewhere` are all production code reading the room's real pin directory — which
# matters, because the corroboration those provide is exactly what several cases below assert.
SHADOW="$COUNCIL_TEST_ROOT/t27shadow"; rm -rf "$SHADOW"; mkdir -p "$SHADOW/lib"
for e in "$REAL_SKILL"/*; do
  case "${e##*/}" in lib|tests) ;; *) ln -s "$e" "$SHADOW/${e##*/}" ;; esac
done
for e in "$REAL_SKILL"/lib/*; do
  case "${e##*/}" in term.sh) ;; *) ln -s "$e" "$SHADOW/lib/${e##*/}" ;; esac
done
SESSIONS="$COUNCIL_TEST_ROOT/t27-sessions"       # what the backend lists, one name per line
SESSIONS_RC="$COUNCIL_TEST_ROOT/t27-sessions-rc" # ...and the status it answers with
: > "$SESSIONS"; printf '0\n' > "$SESSIONS_RC"
cat >"$SHADOW/lib/term.sh" <<SHADOWEOF
# The shipped terminal with only the enumeration replaced. Pinned to tmux so the pin cases mean
# the same thing here as on a machine running agterm — \`auto\` would resolve against whatever the
# developer happens to have up.
COUNCIL_BACKEND=tmux
. "$REAL_SKILL/lib/term.sh"
ct_sessions() { cat "$SESSIONS" 2>/dev/null; return "\$(cat "$SESSIONS_RC" 2>/dev/null || printf 0)"; }
SHADOWEOF
SCLI="$SHADOW/council.sh"

# Drive the shadow backend: `sessions <name>...` lists those sessions and answers 0;
# `sessions_unreachable` answers non-zero, which is the case a live tmux cannot be made to give.
sessions()             { printf '%s\n' "$@" > "$SESSIONS"; printf '0\n' > "$SESSIONS_RC"; }
sessions_none()        { : > "$SESSIONS"; printf '0\n' > "$SESSIONS_RC"; }
sessions_unreachable() { : > "$SESSIONS"; printf '1\n' > "$SESSIONS_RC"; }

# --- 1. the filter filters -------------------------------------------------------------
R="$COUNCIL_TEST_ROOT/t27a"; rm -rf "$R"
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
# The whole point, asserted on the HARD tier, which is the one that is still an alarm.
RS="$COUNCIL_TEST_ROOT/t27s"; rm -rf "$RS"
mkroom "$RS" a b c
export COUNCIL_ROOM="$RS" ROOM="$RS"
# One message, then BOTH clocks aged, the room older than the floor. A never-spoken room has
# held == room_age, which is one rounding step from the clock-is-wrong arm — deterministic here
# instead.
say_floor msg '[]' "Taking a while." >/dev/null
age_room "$RS" 9000
age_messages "$RS" 1200
bash "$CLI" status --only-changed >/dev/null 2>&1      # let the signature settle on this state
h1=$(bash "$CLI" status --only-changed 2>/dev/null)
h2=$(bash "$CLI" status --only-changed 2>/dev/null)
ok "a standing STALL prints on tick N"   1 "$(printf '%s' "$h1" | grep -c '🛑 STALL')"
ok "...and on tick N+1, unchanged"       1 "$(printf '%s' "$h2" | grep -c '🛑 STALL')"
# ...and it is the ORDINARY arm, not the clock-is-wrong one. Asserted explicitly because the two
# read differently and only this one carries the liveness sentence every later case is about.
ok "...on the ordinary STALL arm"        1 "$(printf '%s' "$h1" | grep -c 'has held the floor for')"
ok "...not the clock-is-wrong arm"       0 "$(printf '%s' "$h1" | grep -c 'clock is wrong')"

# --- 3. the quiet tier is an ANNOTATION, not an alarm -----------------------------------
# It was an alarm in the first draft. Measured single turns of 24, 51, 55 and 84 minutes — every
# one a healthy seat thinking — would each have raised it, which is the alarm-on-the-normal-path
# failure this repo has been bitten by three times; and raising the threshold past that
# measurement would put it ABOVE the 900s hard tier it exists to sit below. So it moved to the
# block. These assertions are what stop it moving back.
RQ="$COUNCIL_TEST_ROOT/t27q"; rm -rf "$RQ"
mkroom "$RQ" a b c
export COUNCIL_ROOM="$RQ" ROOM="$RQ"
age_room "$RQ" 400     # past the 300s annotation threshold, under the 900s stall threshold

blk=$(bash "$CLI" status 2>/dev/null)
ok "the quiet line is on the block"      1 "$(printf '%s' "$blk" | grep -c '^quiet: a has held')"
ok "...and it is NOT in the alarms line" 0 "$(printf '%s' "$blk" | grep -c 'alarms:.*quiet')"
ok "...and no stall alarm at 400s"       0 "$(printf '%s' "$blk" | grep -c '🛑 STALL')"
ok "...so alarms read as none"           1 "$(printf '%s' "$blk" | grep -c 'alarms: —')"

# It must NOT reach the fast alarm loop: that loop's whole value is printing nothing until
# something needs a person, and a healthy long think is not that.
out=$(bash "$CLI" status --alarms-only 2>/dev/null)
ok "the quiet line never reaches --alarms-only" 0 "${#out}"

# And it must NOT break --only-changed's silence, for the same reason.
bash "$CLI" status --only-changed >/dev/null 2>&1
out=$(bash "$CLI" status --only-changed 2>/dev/null)
ok "...and does not break the filter's silence" 0 "${#out}"

# Past the hard threshold it IS an alarm again, and that one does everything the quiet line does
# not.
a=$(COUNCIL_STALL_SECS=100 bash "$CLI" status --alarms-only 2>/dev/null)
ok "past COUNCIL_STALL_SECS it is 🛑"    1 "$(printf '%s' "$a" | grep -c '🛑 STALL')"
a=$(COUNCIL_STALL_WARN_SECS=100000 bash "$CLI" status 2>/dev/null)
ok "COUNCIL_STALL_WARN_SECS raises it"   0 "$(printf '%s' "$a" | grep -c '^quiet:')"

# The quiet tier must not push, and this is mechanical rather than a matter of taste:
# _stall_escalate de-duplicates on `[stall:<peer>:<turns>]`, so a push from the early tier would
# consume the key the real STALL needs and silence the alarm it exists to warn about.
rm -f "$POLICY_MAILBOX_DIR"/council-t27q-*.json 2>/dev/null
bash "$CLI" status >/dev/null 2>&1
n=$(ls "$POLICY_MAILBOX_DIR"/council-t27q-*.json 2>/dev/null | wc -l | tr -d ' ')
ok "the quiet tier pushes nothing" 0 "$n"

COUNCIL_STALL_SECS=100 bash "$CLI" status >/dev/null 2>&1
n=$(ls "$POLICY_MAILBOX_DIR"/council-t27q-*.json 2>/dev/null | wc -l | tr -d ' ')
ok "the hard tier still pushes" 1 "$n"

# The two flags parse together, and combined they must not consume the BLOCK loop's memory: the
# fast loop printed nothing and still stored the signature, so an operator who added
# `--only-changed` to it "to make it quieter" silenced the ten-minute block for that turn.
export COUNCIL_ROOM="$R" ROOM="$R"
bash "$CLI" status --only-changed >/dev/null 2>&1          # settle the signature
say_floor msg '[]' "A change the block loop must see." >/dev/null
bash "$CLI" status --only-changed --alarms-only >/dev/null 2>&1
out=$(bash "$CLI" status --only-changed 2>/dev/null)
ok "--alarms-only does not eat the block loop's change" 1 "$(printf '%s' "$out" | grep -c '^=== council')"
export COUNCIL_ROOM="$RQ" ROOM="$RQ"

# --- 4. --alarms-only is an alarm channel, not a heartbeat -------------------------------
R2="$COUNCIL_TEST_ROOT/t27b"; rm -rf "$R2"
mkroom "$R2" a b c
export COUNCIL_ROOM="$R2" ROOM="$R2"

out=$(bash "$CLI" status --alarms-only 2>/dev/null)
ok "a clean room prints NOTHING" 0 "${#out}"
bash "$CLI" status --alarms-only >/dev/null 2>&1
ok "...and still exits 1 (the room is open)" 1 "$?"

age_room "$R2" 1200
out=$(bash "$CLI" status --alarms-only 2>/dev/null)
ok "an alarmed room prints the room name" 1 "$(printf '%s' "$out" | grep -c '^=== council')"
ok "...and the alarm"                     1 "$(printf '%s' "$out" | grep -c 'alarms:.*🛑 STALL')"
# It is the alarms ALONE — no transcript, no floor line. That is what makes a 60s cadence
# readable, and it is the difference between this and the block the 10-minute loop prints.
ok "...and nothing else"                  0 "$(printf '%s' "$out" | grep -c 'last messages')"
ok "...not even the floor line"           0 "$(printf '%s' "$out" | grep -c '^mode ')"

# --- 5. a closed room: never suppressed, and no liveness verdict ------------------------
R3="$COUNCIL_TEST_ROOT/t27c"; rm -rf "$R3"
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
ok "no pin ⇒ no terminal alarm"       0 "$(printf '%s' "$c1" | grep -c 'terminals are still up')"

# THE LIVENESS SENTENCE MUST NOT RIDE A CLOSED ROOM'S STALL. `held` is `now - last turn` and
# grows without bound after a closure, so every decided room reaches the hard tier about fifteen
# minutes later. The 🛑 STALL alarm itself is DELIBERATE there (t22 pins it, because a closure is
# two files a participant can forge and a withheld alarm would buy that silence) — so this asserts
# the alarm still fires and the relaunch prescription does not ride along.
sessions_none
printf 'fake-container\n' > "$R3/state/container-tmux"
age_room "$R3" 20000      # the room is OLDER than its floor: the ordinary arm, see age_messages
age_messages "$R3" 7200
cs=$(COUNCIL_STALL_SECS=100 bash "$SCLI" status --alarms-only 2>/dev/null)
ok "a closed room still raises STALL"        1 "$(printf '%s' "$cs" | grep -c '🛑 STALL')"
ok "...on the ordinary arm"                  1 "$(printf '%s' "$cs" | grep -c 'has held the floor for')"
# The seat has no launcher (mkroom writes none) and the backend lists nothing, so an unguarded
# read WOULD produce a GONE sentence here — which is what makes these two assertions bite.
ok "...but prescribes no relaunch"           0 "$(printf '%s' "$cs" | grep -c 'council.sh relaunch %s\|before running council.sh relaunch')"
ok "...and claims nothing about a terminal"  0 "$(printf '%s' "$cs" | grep -c 'terminal is GONE')"
rm -f "$R3/state/container-tmux"

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
ok "the signature is in the mailbox" 1 \
  "$(ls "$POLICY_MAILBOX_DIR/council-status-sig-$(basename "$R")" 2>/dev/null | wc -l | tr -d ' ')"
ok "...and not in the room" 0 "$(find "$R" -name '*status-sig*' 2>/dev/null | wc -l | tr -d ' ')"
# It must not look like an escalation entry to the mailbox's readers, which glob `*.json`.
ok "...and is not a *.json entry" 0 "$(ls "$POLICY_MAILBOX_DIR"/council-status-sig-*.json 2>/dev/null | wc -l | tr -d ' ')"
# One file PER ROOM, not one shared by all of them: a shared signature would make each room's
# tick suppress the next room's, which on a fleet of rooms is silence by arithmetic.
ok "one signature per room" 1 \
  "$(ls "$POLICY_MAILBOX_DIR/council-status-sig-$(basename "$RS")" 2>/dev/null | wc -l | tr -d ' ')"

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

# --- 9. the closed-room terminal read, over the shadow backend ----------------------------
# Every case here is one the alarm exists for, and every one of them used to be untested.
export COUNCIL_ROOM="$R3" ROOM="$R3"
RN=$(basename "$R3")
printf 'fake-container\n' > "$R3/state/container-tmux"

# 9a. Two of three seats listed: the alarm fires and names the count.
sessions "council-$RN-a" "council-$RN-b"
ok "terminals counts the live seats" "2/3" "$(bash "$SCLI" terminals 2>/dev/null)"
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "a closed room with live seats alarms" 1 "$(printf '%s' "$out" | grep -c '2 of 3 terminals are still up')"
# It must survive the filter like every other alarm: this is the tick the monitor loop EXITS on,
# so a suppressed one is a supervisor told nothing, once, at the only moment it mattered.
bash "$SCLI" status --only-changed >/dev/null 2>&1
out=$(bash "$SCLI" status --only-changed 2>/dev/null)
ok "...on every tick, through --only-changed" 1 "$(printf '%s' "$out" | grep -c 'terminals are still up')"

# 9b. An honest empty answer from a backend that DID answer — a legitimately torn-down room. No
#     alarm is owed, but the tick must still SAY what it read: a zero comes through a pin inside
#     the room, so it is not proof, and falling silent here is what made a retargeted pin invisible.
sessions_none
ok "terminals counts zero once they are gone" "0/3" "$(bash "$SCLI" terminals 2>/dev/null)"
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "a torn-down room raises no alarm" 0 "$(printf '%s' "$out" | grep -c 'terminals are still up')"
blk=$(bash "$SCLI" status 2>/dev/null)
ok "...but the block says what it read"  1 "$(printf '%s' "$blk" | grep -c '^terminals: none of 3')"
ok "...and that a zero is not proof"     1 "$(printf '%s' "$blk" | grep -c 'not proof')"

# 9c. THE SUPPRESSION ROUTE. A participant retargets the pin at a container that does not exist;
#     the backend answers honestly that it holds nothing, so this is a RESOLVED read reporting
#     zero while the seats run. It is indistinguishable from 9b by design — `council_down` leaves
#     the pin in place — which is why the answer is the block line above and not an alarm. What
#     must never happen again is the tick printing NOTHING.
printf 'no-such-container\n' > "$R3/state/container-tmux"
sessions_none
blk=$(bash "$SCLI" status 2>/dev/null)
ok "a retargeted pin does not silence the tick" 1 "$(printf '%s' "$blk" | grep -c '^terminals:')"

# 9d. An unresolvable read must FAIL OPEN — the alarm still fires, worded as "could not tell".
#     Two routes: a backend that did not answer, and a pin naming the other backend.
sessions_unreachable
printf 'fake-container\n' > "$R3/state/container-tmux"
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "an unreachable backend still alarms" 1 "$(printf '%s' "$out" | grep -c 'could not be determined')"
ok "...and says to run down"             1 "$(printf '%s' "$out" | grep -c 'council.sh down')"
ok "terminals says ? rather than a number" "?" "$(bash "$SCLI" terminals 2>/dev/null)"
bash "$SCLI" terminals >/dev/null 2>&1; ok "...and exits 1" 1 "$?"

# The tmux pin must GO first: `drv_pins_elsewhere` treats both pins present as "this caller has
# launched on each", i.e. no disagreement — so leaving it here would test nothing.
sessions_none
rm -f "$R3/state/container-tmux"
printf 'other\n' > "$R3/state/container-agterm"
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "a pin naming the other backend still alarms" 1 "$(printf '%s' "$out" | grep -c 'could not be determined')"
rm -f "$R3/state/container-agterm"
printf 'fake-container\n' > "$R3/state/container-tmux"

# 9e. A ROSTER THE READER REFUSES IS NOT A ZERO. `c_peers` returns 1 for a roster it will not
#     validate, and that refusal used to be swallowed by a heredoc: empty list, confident `0/0`
#     at rc 0, alarm gone while the terminals ran. Reachable without an adversary too — `up`
#     writes roster.json with a plain `>`, so an interrupted run leaves a truncated file.
sessions "council-$RN-a" "council-$RN-b"
cp "$R3/roster.json" "$R3/roster.bak"
jq '.order = "not-a-list"' "$R3/roster.bak" > "$R3/roster.json"
ok "a refused roster is ? not 0/0" "?" "$(bash "$SCLI" terminals 2>/dev/null)"
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "...and the alarm still fires" 1 "$(printf '%s' "$out" | grep -c 'could not be determined')"
mv "$R3/roster.bak" "$R3/roster.json"
rm -f "$R3/state/container-tmux"

# --- 10. the seat-liveness sentences ------------------------------------------------------
# ALIVE-and-idle-at-a-prompt and GONE look identical from inside the room and need opposite
# remedies, so these sentences are the most dangerous strings in the change: one of them names a
# command that discards everything a seat has read. They are EVIDENCE, not verdicts, and these
# assertions pin that wording.
export COUNCIL_ROOM="$RS" ROOM="$RS"     # the open room aged past the stall tier
SN=$(basename "$RS")
FLOOR=$(bash "$CLI" floor | sed -n 's/.*floor=\([^ ]*\).*/\1/p')
printf 'fake-container\n' > "$RS/state/container-tmux"
# `mkroom` writes no launchers; a seat with none is the `--me` case (9f below), so the seats that
# stand in for agent seats need one.
printf '#!/bin/sh\n' > "$RS/state/launch-$FLOOR.sh"

# 10a. Listed: do not reach for relaunch — and no claim about what the pane is doing.
sessions "council-$SN-$FLOOR"
out=$(COUNCIL_STALL_SECS=100 bash "$SCLI" status --alarms-only 2>/dev/null)
ok "a listed seat is described, not judged" 1 "$(printf '%s' "$out" | grep -c 'what a live seat looks like')"
ok "...and relaunch is discouraged"         1 "$(printf '%s' "$out" | grep -c 'do not reach for relaunch')"
ok "...and GONE is not claimed"             0 "$(printf '%s' "$out" | grep -c 'terminal is GONE')"
ok "...and no claim about a prompt"         0 "$(printf '%s' "$out" | grep -c 'at a prompt')"

# 10b. Not listed, corroborated: the absence may be reported — as what a dead seat LOOKS LIKE,
#      with the provenance of the read, and never as authority to relaunch on.
sessions_none
out=$(COUNCIL_STALL_SECS=100 bash "$SCLI" status --alarms-only 2>/dev/null)
ok "a gone seat is named as GONE"        1 "$(printf '%s' "$out" | grep -c 'terminal is GONE')"
ok "...as a resemblance, not a verdict"  1 "$(printf '%s' "$out" | grep -c 'what a dead seat looks like')"
ok "...with the read's provenance"       1 "$(printf '%s' "$out" | grep -c 'a file in the room')"
ok "...and relaunch is not prescribed"   1 "$(printf '%s' "$out" | grep -c 'look at the terminal before')"
ok "...and the discard is spelled out"   1 "$(printf '%s' "$out" | grep -c 'discards everything')"

# 10c. UNCORROBORATED absence claims nothing. A wrong confident "gone" is the expensive error:
#      it is the one that sends a supervisor to relaunch a live seat mid-turn.
sessions_unreachable
out=$(COUNCIL_STALL_SECS=100 bash "$SCLI" status --alarms-only 2>/dev/null)
ok "an unreachable backend claims nothing" 0 "$(printf '%s' "$out" | grep -c 'terminal is GONE')"
ok "...but the STALL alarm is untouched"   1 "$(printf '%s' "$out" | grep -c '🛑 STALL')"

# 10d. THE --me SEAT. `council up` gives the seat the human took no launcher and no terminal, and
#      that seat still holds its turn — so without a launcher check the commonest healthy path in
#      a human-in-the-room scenario (a person thinking) printed a confident GONE and prescribed a
#      command `relaunch` refuses. The absence is still REPORTED; only the advice changes.
sessions_none
rm -f "$RS/state/launch-$FLOOR.sh"
out=$(COUNCIL_STALL_SECS=100 bash "$SCLI" status --alarms-only 2>/dev/null)
ok "a launcher-less seat still reports GONE" 1 "$(printf '%s' "$out" | grep -c 'terminal is GONE')"
ok "...names it as never given a terminal"   1 "$(printf '%s' "$out" | grep -c 'never GIVEN one')"
ok "...points at the human"                  1 "$(printf '%s' "$out" | grep -c 'waiting on a person')"
ok "...and prescribes no relaunch"           0 "$(printf '%s' "$out" | grep -c 'before running council.sh relaunch')"
printf '#!/bin/sh\n' > "$RS/state/launch-$FLOOR.sh"

# 10e. THE BARRIER LABEL. During an open barrier round `$floor` is the label `— (barrier)`, not a
#      seat, and this printed `council.sh relaunch — (barrier)` while `_stall_escalate`'s notice
#      for the same event degraded correctly — because that one had a roster-membership test and
#      this did not. Both now share `_is_seat`.
sessions_none
cp "$RS/roster.json" "$RS/roster.bak"
jq '.mode = "roundtable"' "$RS/roster.bak" > "$RS/roster.json"
out=$(COUNCIL_STALL_SECS=100 bash "$SCLI" status --alarms-only 2>/dev/null)
ok "a barrier label is never called a seat" 0 "$(printf '%s' "$out" | grep -c 'relaunch — (barrier)')"
ok "...and no terminal claim is made of it" 0 "$(printf '%s' "$out" | grep -c 'terminal is GONE')"
mv "$RS/roster.bak" "$RS/roster.json"
rm -f "$RS/state/container-tmux" "$RS/state/launch-$FLOOR.sh"

printf '\n%s\n' "$([ "$fails" = 0 ] && echo 't27: all passed' || echo "t27: $fails FAILURES")"
exit $([ "$fails" = 0 ] && echo 0 || echo 1)
