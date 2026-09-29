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
  # A launch record is bound to the room by `created_ms`, and `up` would have written it with the
  # value the room was created with. Keep it bound, or every aged room reads as having a record
  # that belongs to some other room.
  local lr; lr="$POLICY_MAILBOX_DIR/council-launch-$(basename "$r")"
  if [ -f "$lr" ]; then
    jq --argjson c "$(( now_ms - back * 1000 ))" '.created_ms = $c' "$lr" > "$lr.tmp" && mv "$lr.tmp" "$lr"
  fi
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
HANDLES="$COUNCIL_TEST_ROOT/t27-handles"         # ...and the same sessions as handle lines
SESSIONS_RC="$COUNCIL_TEST_ROOT/t27-sessions-rc" # ...and the status it answers with
SESSIONS_CALLS="$COUNCIL_TEST_ROOT/t27-sessions-calls"  # one line per enumeration, for cost tests
OCC="$COUNCIL_TEST_ROOT/t27-occupant"            # what drv_occupant answers (agent|none); absent = no verdict
OCC_CALLS="$COUNCIL_TEST_ROOT/t27-occupant-calls"  # one line per occupant read
rm -f "$OCC"; : > "$OCC_CALLS"
: > "$SESSIONS"; : > "$HANDLES"; printf '0\n' > "$SESSIONS_RC"; : > "$SESSIONS_CALLS"
cat >"$SHADOW/lib/term.sh" <<SHADOWEOF
# The shipped terminal with only the enumeration replaced. Pinned to tmux so the pin cases mean
# the same thing here as on a machine running agterm — \`auto\` would resolve against whatever the
# developer happens to have up.
COUNCIL_BACKEND=tmux
. "$REAL_SKILL/lib/term.sh"
ct_sessions() { printf 'call\\n' >> "$SESSIONS_CALLS"; cat "$SESSIONS" 2>/dev/null; return "\$(cat "$SESSIONS_RC" 2>/dev/null || printf 0)"; }
# The handle enumeration the launch-record readers use (#247), from the same backend state: one
# "<handle><TAB><container><TAB><name>" line per listed session, answering with the same status.
ct_handles()  { printf 'call\\n' >> "$SESSIONS_CALLS"; cat "$HANDLES" 2>/dev/null; return "\$(cat "$SESSIONS_RC" 2>/dev/null || printf 0)"; }
# The occupant read (#235), replaced for the same reason: a live tmux cannot be made to answer
# \`none\` on demand. No file is no verdict, which is what every case outside section 10f gets.
# Replaced at the driver, so the shipped \`ct_no_agent\` and the driver's two-read rule still run.
drv_occupant() { printf 'call\\n' >> "$OCC_CALLS"; [ -f "$OCC" ] || return 1; cat "$OCC"; }
SHADOWEOF
SCLI="$SHADOW/council.sh"

# Drive the shadow backend: `sessions <name>...` lists those sessions and answers 0;
# `sessions_unreachable` answers non-zero, which is the case a live tmux cannot be made to give.
# Each listed session is also a handle, `h-<name>`, in `fake-container`, which is the handle
# `record_launch` records for it, so "listed" means "the launched terminal is up" unless a case
# writes $HANDLES itself.
sessions()             { printf '%s\n' "$@" > "$SESSIONS"; printf '0\n' > "$SESSIONS_RC"
                         local s; : > "$HANDLES"
                         for s in "$@"; do printf 'h-%s\tfake-container\t%s\n' "$s" "$s" >> "$HANDLES"; done; }
calls_reset()          { : > "$SESSIONS_CALLS"; }
calls_count()          { wc -l < "$SESSIONS_CALLS" | tr -d ' '; }
sessions_none()        { : > "$SESSIONS"; : > "$HANDLES"; printf '0\n' > "$SESSIONS_RC"; }
sessions_unreachable() { : > "$SESSIONS"; : > "$HANDLES"; printf '1\n' > "$SESSIONS_RC"; }

# The launch record `up` would have written for <room>: every roster seat launched on tmux into
# `fake-container` as `h-council-<room>-<peer>`, except the seats named after `--unlaunched`,
# for which nothing was launched (the `--me` seat, a failed launch). `record_forget` removes it.
record_launch() { # <room> [--unlaunched <peer>...]
  local r="$1" rp; shift
  [ "${1:-}" = --unlaunched ] && shift
  rp=$(cd "$r" && pwd -P)
  jq -n --arg room "$rp" --argjson cms "$(jq '.created_ms' "$r/roster.json")" \
        --argjson order "$(jq -c '.order' "$r/roster.json")" --arg rn "$(basename "$rp")" \
        --argjson un "$(printf '%s\n' "$@" | jq -R . | jq -s 'map(select(length > 0))')" '
    {room: $room, created_ms: $cms, generation: 1,
     seats: ($order | map(. as $p | "council-\($rn)-\($p)" as $n
       | {key: $p, value: (if ($un | index($p)) != null
         then {backend: "tmux", container: "fake-container", name: $n, handle: null, launched: false, generation: 1}
         else {backend: "tmux", container: "fake-container", name: $n, handle: "h-\($n)", launched: true, generation: 1} end)})
       | from_entries)}' > "$POLICY_MAILBOX_DIR/council-launch-$(basename "$rp")"
}
record_forget() { rm -f "$POLICY_MAILBOX_DIR/council-launch-$(basename "$1")"; }

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

# 1b. A ROOM REOPENED UNDER THE SAME NAME ARMS (#200). The signature file is keyed by the room's
#     name, and a fresh room's signature is deterministic, so a new room at a freed name used to
#     match the dead room's stored signature and print nothing on its first tick, the one that
#     tells a supervisor the watch is live. Nothing removes the file here, as nothing does when a
#     room directory is deleted by hand: the room's creation time in the signature is what arms it.
R1B="$COUNCIL_TEST_ROOT/t27b"; mkroom "$R1B" a b c
export COUNCIL_ROOM="$R1B" ROOM="$R1B"
bash "$CLI" status --only-changed >/dev/null 2>&1
ok "1b: an unmoved room is silent"                  0 "$(bash "$CLI" status --only-changed 2>/dev/null | wc -c | tr -d ' ')"
mkroom "$R1B" a b c
jq '.created_ms += 1' "$R1B/roster.json" > "$R1B/roster.tmp" && mv "$R1B/roster.tmp" "$R1B/roster.json"
out=$(bash "$CLI" status --only-changed 2>/dev/null)
ok "1b: the same name reopened arms on its first tick" 1 "$(printf '%s' "$out" | grep -c '^=== council')"
export COUNCIL_ROOM="$R" ROOM="$R"

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
# h1 is this episode's SECOND firing of the block monitor (the settling tick was the first), so it
# is the one-line delta t28 covers — `(still)` marks the ordinary arm in that shape.
ok "...on the ordinary STALL arm"        1 "$(printf '%s' "$h1" | grep -c '🛑 STALL (still): ')"
ok "...not the clock-is-wrong arm"       0 "$(printf '%s' "$h1" | grep -c 'clock is wrong')"

# --- 3. the quiet tier is an ANNOTATION, not an alarm -----------------------------------
# It was an alarm in the first draft. Measured single turns of 24, 51, 55 and 84 minutes — every
# one a healthy seat thinking — would each have raised it, which is the alarm-on-the-normal-path
# failure this repo has been bitten by three times; and raising the threshold past that
# measurement would put it ABOVE the 900s stall tier it exists to sit below. So it moved to the
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

# But it must be NEWS EXACTLY ONCE, not never. A quiet room moves none of the other signature
# terms — that is what quiet means — so without a quiet bit in the signature the annotation lands
# on a block the filter then suppresses for the whole wedge, and the 300s signal never reaches the
# loop this skill tells a supervisor to arm. Entering the state breaks silence once; holding it
# does not. Same treatment shipyard gives a wait class.
RQ2="$COUNCIL_TEST_ROOT/t27q2"; rm -rf "$RQ2"
mkroom "$RQ2" a b c
export COUNCIL_ROOM="$RQ2" ROOM="$RQ2"
bash "$CLI" status --only-changed >/dev/null 2>&1          # settle while not yet quiet
out=$(bash "$CLI" status --only-changed 2>/dev/null)
ok "not yet quiet: the filter is silent" 0 "${#out}"
age_room "$RQ2" 400                                         # cross into quiet
out=$(bash "$CLI" status --only-changed 2>/dev/null)
ok "entering quiet breaks silence once"  1 "$(printf '%s' "$out" | grep -c '^quiet:')"
out=$(bash "$CLI" status --only-changed 2>/dev/null)
ok "...and holding it does not"          0 "${#out}"
export COUNCIL_ROOM="$RQ" ROOM="$RQ"

# THE LIVENESS APPEND RIDES THE QUIET LINE, AND ONLY THE QUIET LINE. Until this fixture carried a
# pin, `_seat_liveness` returned 1 here and the append at the end of the quiet branch was dead
# under the whole suite: routing it into `$alarms` instead — which bypasses `--only-changed` for
# as long as the seat thinks, with the name of a command that discards a seat's context — changed
# nothing that any assertion could see.
#
# WHICH ASSERTION CATCHES WHAT, because these three are not interchangeable: the routing is caught
# by "carries the liveness note" and "still does not bypass the filter". The third, "never reaches
# --alarms-only", canNOT catch it — the `alarms_only` gate added in the same commit keeps this
# whole branch from running in that mode, so `$alarms` stays empty there however the note is
# routed. It is a backstop against the MODE regressing, duplicating the assertion above it, and
# an earlier version of this comment claimed the routing would "wake the 60-second alarm loop",
# which that same commit's own gate had already made impossible.
printf 'fake-container\n' > "$RQ/state/container-tmux"
printf '#!/bin/sh\n' > "$RQ/state/launch-$(bash "$CLI" floor | sed -n 's/.*floor=\([^ ]*\).*/\1/p').sh"
record_launch "$RQ"
sessions_none
blk=$(bash "$SCLI" status 2>/dev/null)
ok "the quiet line carries the liveness note" 1 "$(printf '%s' "$blk" | grep -c '^quiet:.*terminal is GONE')"
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "...and it still never reaches --alarms-only" 0 "${#out}"
bash "$SCLI" status --only-changed >/dev/null 2>&1
out=$(bash "$SCLI" status --only-changed 2>/dev/null)
ok "...and still does not bypass the filter"     0 "${#out}"

# THE `_is_seat` HALF OF THE QUIET GATE. A roster `c_peers` refuses leaves `$floor` unusable, and
# without the gate the annotation named an empty seat — the same "  has been held for 7200s"
# defect this change fixed in `_stall_escalate`. Reachable without an adversary: `up` writes
# roster.json with a plain `>`, so an interrupted run truncates it.
cp "$RQ/roster.json" "$RQ/roster.bak"
jq '.order = "not-a-list"' "$RQ/roster.bak" > "$RQ/roster.json"
blk=$(bash "$SCLI" status 2>/dev/null)
ok "an uncheckable floor earns no quiet line" 0 "$(printf '%s' "$blk" | grep -c '^quiet:')"
mv "$RQ/roster.bak" "$RQ/roster.json"

# AND IT MUST NOT PAY FOR ONE EITHER. The quiet branch composes its line with `_seat_liveness`,
# which sources term.sh (re-resolving the backend — on agterm a control-socket probe) and
# enumerates the container. Left ungated, the documented 60-second alarm loop paid that every tick
# for the whole time a seat was thinking, to build a sentence the mode then discarded. Asserted by
# counting enumerations rather than by timing, so it is deterministic.
sessions_none
calls_reset
bash "$SCLI" status --alarms-only >/dev/null 2>&1
ok "--alarms-only asks the backend nothing on a quiet room" 0 "$(calls_count)"
calls_reset
bash "$SCLI" status >/dev/null 2>&1
ok "...while the block does ask it"                         1 "$(calls_count)"
rm -f "$RQ/state/container-tmux" "$RQ"/state/launch-*.sh; record_forget "$RQ"

# Past the hard threshold it IS an alarm again, and that one does everything the quiet line does
# not.
a=$(COUNCIL_STALL_SECS=100 bash "$CLI" status --alarms-only 2>/dev/null)
ok "past COUNCIL_STALL_SECS it is 🛑"    1 "$(printf '%s' "$a" | grep -c '🛑 STALL')"
a=$(COUNCIL_STALL_WARN_SECS=100000 bash "$CLI" status 2>/dev/null)
ok "COUNCIL_STALL_WARN_SECS raises it"   0 "$(printf '%s' "$a" | grep -c '^quiet:')"

# The quiet tier must not push. The reason USED to be mechanical — one de-duplication key for
# every tier, so a push from here would consume the key the real STALL needs and silence the alarm
# it exists to warn about. That argument no longer holds on its own: since #188 the key carries the
# tier (`[<tier>:<peer>:<turns>]`), precisely so a calm notice cannot eat a loud one. What keeps
# this tier push-free now is what it is: a line on the BLOCK rather than an alarm, at a threshold
# (300s) chosen to cost nothing because it never leaves the console. Pushing from here would put a
# notice in the mailbox for every seat that thinks for five minutes, which is the noise #188 was
# filed about, one tier lower.
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
# grows without bound after a closure, so every decided room reaches the stall tier about fifteen
# minutes later. The 🛑 STALL alarm itself is DELIBERATE there (t22 pins it, because a closure is
# two files a participant can forge and a withheld alarm would buy that silence) — so this asserts
# the alarm still fires and the relaunch prescription does not ride along. A closed room is also
# never reclassified to `⏳ LONG TURN`, for the same reason and at any age; t22 case 10d-bis pins
# that, under the backstop where it was briefly reachable.
sessions_none
printf 'fake-container\n' > "$R3/state/container-tmux"
age_room "$R3" 20000      # the room is OLDER than its floor: the ordinary arm, see age_messages
age_messages "$R3" 7200
cs=$(COUNCIL_STALL_SECS=100 bash "$SCLI" status --alarms-only 2>/dev/null)
ok "a closed room still raises STALL"        1 "$(printf '%s' "$cs" | grep -c '🛑 STALL')"
ok "...on the ordinary arm"                  1 "$(printf '%s' "$cs" | grep -c 'has held the floor for')"
# THE SEAT NEEDS A LAUNCHER for this to bite. Without one, `_seat_liveness` takes the `--me`
# branch, whose wording contains no relaunch prescription at all — so the assertion passed
# whether or not the guard existed, and only its companion below did any work. Measured: dropping
# the closed-room half of the gate left this one green until the launcher was added.
printf '#!/bin/sh\n' > "$R3/state/launch-$holder.sh"
# ...and a launch record, since #247: without one the read settles nothing and says nothing, so
# the two assertions below would pass with the closed-room gate gone.
record_launch "$R3"
cs=$(COUNCIL_STALL_SECS=100 bash "$SCLI" status --alarms-only 2>/dev/null)
ok "...but prescribes no relaunch"           0 "$(printf '%s' "$cs" | grep -c 'before running council.sh relaunch')"
ok "...and claims nothing about a terminal"  0 "$(printf '%s' "$cs" | grep -c 'terminal is GONE')"
# All three removed: section 6 asserts the never-launched answer on this room, and a launcher or a
# record left behind would make it rc 2 / `?` — correctly, which is exactly why they have to go.
rm -f "$R3/state/container-tmux" "$R3"/state/launch-*.sh; record_forget "$R3"

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
# Every case here is one the alarm exists for, and every one of them used to be untested. Since
# #247 the count is checked against the room's launch record, which names the handle each seat was
# launched as, so `record_launch` is the fixture `up` would have left.
export COUNCIL_ROOM="$R3" ROOM="$R3"
RN=$(basename "$R3")
printf 'fake-container\n' > "$R3/state/container-tmux"
record_launch "$R3"

# 9a. Two of three seats listed: the alarm fires and names the count.
sessions "council-$RN-a" "council-$RN-b"
ok "terminals counts the live seats" "2/3" "$(bash "$SCLI" terminals 2>/dev/null)"
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "a closed room with live seats alarms" 1 "$(printf '%s' "$out" | grep -c '2 of 3 terminals are still up')"
# It must survive the filter like every other alarm: this is the tick the monitor loop EXITS on,
# so a suppressed one is a supervisor told nothing, once, at the only moment it mattered.
bash "$SCLI" status --only-changed >/dev/null 2>&1
out=$(bash "$SCLI" status --only-changed 2>/dev/null)
ok "...on every tick, through --only-changed" 1 "$(printf '%s' "$out" | grep -cE '[0-9]+ of [0-9]+ terminals are still up')"

# 9a-bis. THE --me SEAT IS NOT A TERMINAL (#200). `up --me a` records `a` as never launched and
#     writes it no launcher, and it stays in the roster. With both agent seats up, the room is
#     whole: `2/2`, and the closed-room alarm says 2 of 2. Counted against the roster it read `2/3`
#     for the life of the room, which is what a room that has lost a seat looks like.
record_launch "$R3" --unlaunched a
sessions "council-$RN-b" "council-$RN-c"
ok "9a-bis: the --me seat is not in the total"     "2/2" "$(bash "$SCLI" terminals 2>/dev/null)"
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "...nor in the closed-room alarm's count"       1 "$(printf '%s' "$out" | grep -c '2 of 2 terminals are still up')"
# A seat whose LAUNCH failed keeps its launcher (`up` writes it before launching) and so stays in
# the total: that seat was meant to have a terminal, and a count that dropped it would hide it.
printf '#!/bin/sh\n' > "$R3/state/launch-a.sh"
ok "...but a seat whose launch failed stays in it" "2/3" "$(bash "$SCLI" terminals 2>/dev/null)"
rm -f "$R3/state/launch-a.sh"
# The exclusion needs the absent verdict first: a session carrying the unlaunched seat's name
# reads unknown, whatever the launcher says, so the exclusion can never hide a live terminal.
sessions "council-$RN-a" "council-$RN-b" "council-$RN-c"
ok "...and a session under its name is still ?"    "?" "$(bash "$SCLI" terminals 2>/dev/null)"
record_launch "$R3"
sessions "council-$RN-a" "council-$RN-b"

# 9b. GENUINE TEARDOWN — verified absent. The record names what was launched and the backend,
#     which answered, lists none of it. No alarm is owed, but the tick must still SAY what it
#     read: the record is in the mailbox, which a seat can write, so the zero is not proof.
sessions_none
ok "terminals counts zero once they are gone" "0/3" "$(bash "$SCLI" terminals 2>/dev/null)"
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "a torn-down room raises no alarm" 0 "$(printf '%s' "$out" | grep -c 'terminals are still up')"
ok "...nor a could-not-tell alarm"    0 "$(printf '%s' "$out" | grep -c 'could not be determined')"
ok "...and the block line stays off the alarm channel" 0 "$(printf '%s' "$out" | grep -c '^terminals:')"
blk=$(bash "$SCLI" status 2>/dev/null)
ok "...but the block says what it read"  1 "$(printf '%s' "$blk" | grep -c '^terminals: none of 3')"
ok "...and that a zero is not proof"     1 "$(printf '%s' "$blk" | grep -c 'not proof')"
# Teardown on tmux usually takes the server with it, and `drv_handles` reads "no server" as an
# answered, empty backend. That half is asserted in shared/driver/tests; this is the council half.

# 9c. THE SUPPRESSION ROUTE, CLOSED. A participant retargets the pin at a container that does not
#     exist. By name, the backend answered honestly that it held nothing, so this was a RESOLVED
#     zero while the seats ran, indistinguishable from 9b. Against the record, the pin disagrees
#     with what was launched, so it is unknown and alarms, while the seats are listed or not.
printf 'no-such-container\n' > "$R3/state/container-tmux"
sessions "council-$RN-a" "council-$RN-b"
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "a retargeted pin alarms, even while seats are up" 1 "$(printf '%s' "$out" | grep -c 'could not be determined')"
ok "...saying the pin disagrees with the record"      1 "$(printf '%s' "$out" | grep -c 'room pin names no-such-container')"
ok "...and terminals says ?"                          "?" "$(bash "$SCLI" terminals 2>/dev/null)"
sessions_none
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "...and while none are"                            1 "$(printf '%s' "$out" | grep -c 'could not be determined')"
# Deleting the pin reads the same: unknown, not a zero.
rm -f "$R3/state/container-tmux"
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "a deleted pin alarms"                             1 "$(printf '%s' "$out" | grep -c 'room has no container pin')"
printf 'fake-container\n' > "$R3/state/container-tmux"

# 9c-bis. A STALE HANDLE, two ways. The launched terminal is gone and a session with its name is
#     listed (a relaunch the record does not know about, or a planted name); and the recorded
#     handle is listed but now belongs to another terminal (tmux ids restart with the server).
#     Neither is live and neither is gone.
printf 'h-other\tfake-container\tcouncil-%s-a\n' "$RN" > "$HANDLES"; printf '0\n' > "$SESSIONS_RC"
ok "a same-named session where the launched one is gone is ?" "?" "$(bash "$SCLI" terminals 2>/dev/null)"
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "...and alarms, naming the stale handle"            1 "$(printf '%s' "$out" | grep -c 'a stale record or a planted name')"
printf 'h-council-%s-a\tfake-container\tsomething-else\n' "$RN" > "$HANDLES"
ok "a recorded handle on another terminal is ?"        "?" "$(bash "$SCLI" terminals 2>/dev/null)"
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "...and alarms as stale"                            1 "$(printf '%s' "$out" | grep -c 'so it is stale')"
# ...and the CONTAINER half: the right name, in another container (a recycled tmux id).
printf 'h-council-%s-a\tanother-session\tcouncil-%s-a\n' "$RN" "$RN" > "$HANDLES"
ok "a recorded handle in another container is ?"       "?" "$(bash "$SCLI" terminals 2>/dev/null)"
sessions_none

# 9c-ter. THE RECORD ALONE. A seat that edits only the launch record — renaming its entry and
#     giving it a handle nobody holds — must not make a live seat read gone, and copying a live
#     seat's entry into a dead seat's must not make it read live. The recorded name is checked
#     against the peer, so both read unknown and alarm.
sessions "council-$RN-a" "council-$RN-b" "council-$RN-c"
jq '.seats.a.name = "x" | .seats.a.handle = "@999"' "$POLICY_MAILBOX_DIR/council-launch-$RN" > "$R3.lr"
mv "$R3.lr" "$POLICY_MAILBOX_DIR/council-launch-$RN"
ok "a renamed record entry does not read a live seat as gone" "?" "$(bash "$SCLI" terminals 2>/dev/null)"
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "...and alarms, saying the record names another session" 1 "$(printf '%s' "$out" | grep -c 'the launch record names x for this seat')"
record_launch "$R3"
sessions "council-$RN-a" "council-$RN-b"
jq '.seats.c = .seats.a' "$POLICY_MAILBOX_DIR/council-launch-$RN" > "$R3.lr"
mv "$R3.lr" "$POLICY_MAILBOX_DIR/council-launch-$RN"
ok "a dead seat's entry copied from a live one does not read live" "?" "$(bash "$SCLI" terminals 2>/dev/null)"
record_launch "$R3"
# ...while a forged handle with the true name finds the real session by name, which is unknown too.
sessions "council-$RN-a" "council-$RN-b"
jq '.seats.a.handle = "@999"' "$POLICY_MAILBOX_DIR/council-launch-$RN" > "$R3.lr"
mv "$R3.lr" "$POLICY_MAILBOX_DIR/council-launch-$RN"
ok "a forged handle alone reads ?"                     "?" "$(bash "$SCLI" terminals 2>/dev/null)"
record_launch "$R3"
# "Nothing was launched here", in some other container: a `launched: false` entry is not checked
# against the pin, so the search for the live session by name must not be scoped to the
# container the record names, or this one write reads every live seat as gone.
sessions "council-$RN-a" "council-$RN-b" "council-$RN-c"
jq '.seats |= map_values(.launched = false | .handle = null | .container = "nowhere")' \
  "$POLICY_MAILBOX_DIR/council-launch-$RN" > "$R3.lr"
mv "$R3.lr" "$POLICY_MAILBOX_DIR/council-launch-$RN"
ok "a record saying nothing was launched, elsewhere, is ? while seats are up" "?" "$(bash "$SCLI" terminals 2>/dev/null)"
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "...and alarms"                                     1 "$(printf '%s' "$out" | grep -c 'could not be determined')"
record_launch "$R3"
# A live seat dropped from the ROSTER is not dropped from the count: the record still holds it.
sessions "council-$RN-a"
cp "$R3/roster.json" "$R3/roster.bak"
jq '.order = ["b","c"]' "$R3/roster.bak" > "$R3/roster.json"
ok "a live seat dropped from the roster is ? not 0/2"  "?" "$(bash "$SCLI" terminals 2>/dev/null)"
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "...and alarms, saying the roster no longer lists it" 1 "$(printf '%s' "$out" | grep -c 'the roster no longer lists')"
mv "$R3/roster.bak" "$R3/roster.json"
sessions_none

# 9c-quinquies. ANOTHER REPO, THE SAME ROOM NAME. Session names carry no repo, so a room of the same
#     scenario elsewhere on the backend lists sessions with exactly this room's names, in its own
#     container. A genuine teardown here must still read gone, and a seat nothing was launched for
#     must still read never-launched, not unknown because of somebody else's terminals.
for p in a b c; do printf 'h-other-%s\tother-repo\tcouncil-%s-%s\n' "$p" "$RN" "$p"; done > "$HANDLES"
printf '0\n' > "$SESSIONS_RC"
ok "a torn-down room beside another repo's same-named room is 0/3" "0/3" "$(bash "$SCLI" terminals 2>/dev/null)"
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "...and raises no could-not-tell alarm"              0 "$(printf '%s' "$out" | grep -c 'could not be determined')"
record_launch "$R3" --unlaunched a
# `0/2`, not `0/3`: a seat never launched AND given no launcher is the `--me` shape (#200), which
# is left out of the total. It still reads absent rather than unknown, or this would be `?`.
ok "...and a seat nothing was launched for still reads absent" "0/2" "$(bash "$SCLI" terminals 2>/dev/null)"
record_launch "$R3"
# Scoping the search to the pin opens nothing: a retargeted pin still reads unknown, because the
# pin and the recorded container disagree before any name is searched.
printf 'other-repo\n' > "$R3/state/container-tmux"
ok "...while a pin retargeted at that other room is still ?" "?" "$(bash "$SCLI" terminals 2>/dev/null)"
printf 'fake-container\n' > "$R3/state/container-tmux"
sessions_none

# 9c-quater. CONTROL BYTES IN A QUOTED VALUE. The alarm quotes the pin, and a pin is a file a seat
#     writes. Cursor-control bytes in it must not reach the one-line alarms output, where they
#     could erase the line on a terminal, and the alarm must still say what it read.
printf 'evil\033[2K\033[1Gall clear\033[8m\n' > "$R3/state/container-tmux"
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "an escape-laden pin still alarms"                  1 "$(printf '%s' "$out" | grep -c 'could not be determined')"
ok "...with no control byte in the output"             0 "$(printf '%s' "$out" | LC_ALL=C tr -d '\n' | LC_ALL=C grep -c '[[:cntrl:]]')"
err=$(bash "$SCLI" terminals 2>&1 >/dev/null)
ok "...nor in the terminals verb's reason"             0 "$(printf '%s' "$err" | LC_ALL=C tr -d '\n' | LC_ALL=C grep -c '[[:cntrl:]]')"
printf 'fake-container\n' > "$R3/state/container-tmux"

# 9d. An unresolvable read must FAIL OPEN — the alarm still fires, worded as "could not tell".
#     Two routes: a backend that did not answer, and a record naming the other backend.
sessions_unreachable
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "an unreachable backend still alarms" 1 "$(printf '%s' "$out" | grep -c 'could not be determined')"
ok "...and says to run down"             1 "$(printf '%s' "$out" | grep -c 'council.sh down')"
ok "terminals says ? rather than a number" "?" "$(bash "$SCLI" terminals 2>/dev/null)"
bash "$SCLI" terminals >/dev/null 2>&1; ok "...and exits 1" 1 "$?"
ok "...giving the reason on stderr"       1 "$(bash "$SCLI" terminals 2>&1 >/dev/null | grep -c 'did not answer')"
sessions_none
jq '.seats |= map_values(.backend = "agterm")' "$POLICY_MAILBOX_DIR/council-launch-$RN" > "$R3.lr"
mv "$R3.lr" "$POLICY_MAILBOX_DIR/council-launch-$RN"
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "a record naming the other backend still alarms" 1 "$(printf '%s' "$out" | grep -c 'launched on agterm')"
record_launch "$R3"

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

# 9f. NO RECORD IS UNKNOWN, AND SAYS SO. A room launched before launch records existed has none,
#     and neither does a room whose record was deleted. Both read `?` and alarm, and the alarm
#     says why, so an old room's permanent `?` reads as expected rather than as a fault, and a
#     deletion reads exactly the same way: self-revealing rather than silent.
printf 'fake-container\n' > "$R3/state/container-tmux"
printf '#!/bin/sh\n' > "$R3/state/launch-a.sh"
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "9f: baseline — the record is there and seats are up" 1 "$(printf '%s' "$out" | grep -cE '[0-9]+ of [0-9]+ terminals are still up')"
record_forget "$R3"
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "a launched room with no record alarms" 1 "$(printf '%s' "$out" | grep -c 'could not be determined')"
ok "...saying there is no launch record"   1 "$(printf '%s' "$out" | grep -c 'no launch record (it predates launch records, or the record was removed)')"
ok "...never counting names instead"       0 "$(printf '%s' "$out" | grep -cE '[0-9]+ of [0-9]+ terminals are still up')"
ok "...and terminals says ?"               "?" "$(bash "$SCLI" terminals 2>/dev/null)"
# A record left by an EARLIER room of the same name does not vouch for this one.
record_launch "$R3"
jq '.created_ms = 1' "$POLICY_MAILBOX_DIR/council-launch-$RN" > "$R3.lr" && mv "$R3.lr" "$POLICY_MAILBOX_DIR/council-launch-$RN"
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "a record for another room alarms"      1 "$(printf '%s' "$out" | grep -c 'belongs to another room')"
# ...even with the pin and every launcher gone: a record that EXISTS means something was launched
# here, so it is never read as "never had any".
mv "$R3/state/container-tmux" "$R3.pin"; mv "$R3/state/launch-a.sh" "$R3.launch"
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "...even with no pin and no launchers"  1 "$(printf '%s' "$out" | grep -c 'belongs to another room')"
mv "$R3.pin" "$R3/state/container-tmux"; mv "$R3.launch" "$R3/state/launch-a.sh"
# With the record present, removing the pin AND every launcher no longer gets the silence back —
# that single-kind route is what the record closes.
record_launch "$R3"
rm -f "$R3"/state/container-* "$R3"/state/launch-*.sh
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
ok "no pin and no launchers, but a record: still alarms" 1 "$(printf '%s' "$out" | grep -c 'could not be determined')"
# ...and the honest limit: remove the record too and it is back to a block line. The test asserts
# the limit rather than pretending the route is closed — removing this assertion is how a later
# reader comes to believe the guard is stronger than it is.
record_forget "$R3"
out=$(bash "$SCLI" status --alarms-only 2>/dev/null)
# Asserted on the TERMINAL alarm specifically, not on emptiness: this room is aged past the stall
# threshold, so `--alarms-only` correctly carries a 🛑 STALL here and an emptiness check would
# pass for the wrong reason (and would go red the day the fixture's age changed).
ok "removing the record too gets the silence back" 0 "$(printf '%s' "$out" | grep -c 'could not be determined')"
ok "...and its block line stays off the alarm channel" 0 "$(printf '%s' "$out" | grep -c '^terminals:')"
blk=$(bash "$SCLI" status 2>/dev/null)
ok "...but the block still says what it read"     1 "$(printf '%s' "$blk" | grep -c '^terminals: this room carries no container pin, no launchers and no launch record')"

# 9g. A ZERO MEANS OPPOSITE THINGS BY RECORDED STATUS. `decide` reaps its own seats, so on a
#     `decided` room a zero is the expected answer. An `unresolved` close deliberately LEAVES the
#     seats up ("a room that did not converge is one a person should be able to walk into"),
#     exits 0 and never 5 — so the decided wording is false in every clause for that room, and it
#     steers the one operator who should reach for `down` away from it.
RU="$COUNCIL_TEST_ROOT/t27u"; rm -rf "$RU"
mkroom "$RU" a b c
export COUNCIL_ROOM="$RU" ROOM="$RU"
say_floor propose '[]' "Something nobody agrees on." >/dev/null
holder=$(bash "$CLI" floor | sed -n 's/.*floor=\([^ ]*\).*/\1/p')
COUNCIL_ME="$holder" bash "$CLI" decide --force >/dev/null 2>&1
ok "9g: the room closed as unresolved" "unresolved" "$(cat "$RU/board/status" 2>/dev/null)"
printf 'fake-container\n' > "$RU/state/container-tmux"
record_launch "$RU"
sessions_none
blk=$(bash "$SCLI" status 2>/dev/null)
ok "an unresolved room's zero is not called expected" 0 "$(printf '%s' "$blk" | grep -c 'what a decided room looks like')"
ok "...it says the close leaves seats up"             1 "$(printf '%s' "$blk" | grep -c 'LEAVES the seats up on purpose')"
ok "...and still sends the operator to down"          1 "$(printf '%s' "$blk" | grep -c 'council.sh down is how to be sure')"
# ...while a decided room keeps the other sentence, so this is a branch and not a rewording.
export COUNCIL_ROOM="$R3" ROOM="$R3"
printf 'fake-container\n' > "$R3/state/container-tmux"
record_launch "$R3"
blk=$(bash "$SCLI" status 2>/dev/null)
ok "a decided room's zero IS called expected"         1 "$(printf '%s' "$blk" | grep -c 'what a decided room looks like')"
rm -f "$R3/state/container-tmux"; record_forget "$R3"
rm -f "$RU/state/container-tmux"; record_forget "$RU"

# --- 10. the seat-liveness sentences ------------------------------------------------------
# ALIVE-and-idle-at-a-prompt and GONE look identical from inside the room and need opposite
# remedies, so these sentences are the most dangerous strings in the change: one of them names a
# command that discards everything a seat has read. They are EVIDENCE, not verdicts, and these
# assertions pin that wording.
export COUNCIL_ROOM="$RS" ROOM="$RS"     # the open room aged past the stall tier
SN=$(basename "$RS")
FLOOR=$(bash "$CLI" floor | sed -n 's/.*floor=\([^ ]*\).*/\1/p')
printf 'fake-container\n' > "$RS/state/container-tmux"
# `mkroom` writes no launchers and no launch record, which `up` would have. The record is what the
# liveness read matches on (#247), and a launcher is kept beside it as `up` leaves one.
printf '#!/bin/sh\n' > "$RS/state/launch-$FLOOR.sh"
record_launch "$RS"

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
ok "...with the read's provenance"       1 "$(printf '%s' "$out" | grep -c 'which a seat can write too')"
ok "...and relaunch is not prescribed"   1 "$(printf '%s' "$out" | grep -c 'look at the terminal before')"
ok "...and the discard is spelled out"   1 "$(printf '%s' "$out" | grep -c 'discards everything')"

# 10c. UNCORROBORATED absence claims nothing. A wrong confident "gone" is the expensive error:
#      it is the one that sends a supervisor to relaunch a live seat mid-turn.
sessions_unreachable
out=$(COUNCIL_STALL_SECS=100 bash "$SCLI" status --alarms-only 2>/dev/null)
ok "an unreachable backend claims nothing" 0 "$(printf '%s' "$out" | grep -c 'terminal is GONE')"
ok "...but the STALL alarm is untouched"   1 "$(printf '%s' "$out" | grep -c '🛑 STALL')"

# 10c-bis. EVIDENCE THE RECORD CANNOT SETTLE claims nothing either: a same-named session where the
#      launched terminal is gone (planted, or a relaunch the record never heard of), a pin that
#      disagrees with the record, and no record at all. Each used to be read by NAME, so the first
#      read as a live seat and the other two as whatever the pin's container happened to hold.
printf 'h-planted\tfake-container\tcouncil-%s-%s\n' "$SN" "$FLOOR" > "$HANDLES"; printf '0\n' > "$SESSIONS_RC"
out=$(COUNCIL_STALL_SECS=100 bash "$SCLI" status --alarms-only 2>/dev/null)
ok "a planted name is not a live seat"      0 "$(printf '%s' "$out" | grep -c 'what a live seat looks like')"
ok "...nor a dead one"                      0 "$(printf '%s' "$out" | grep -c 'terminal is GONE')"
sessions "council-$SN-$FLOOR"
printf 'no-such-container\n' > "$RS/state/container-tmux"
out=$(COUNCIL_STALL_SECS=100 bash "$SCLI" status --alarms-only 2>/dev/null)
ok "a retargeted pin claims neither"        0 "$(printf '%s' "$out" | grep -cE 'what a live seat looks like|terminal is GONE')"
printf 'fake-container\n' > "$RS/state/container-tmux"
record_forget "$RS"
out=$(COUNCIL_STALL_SECS=100 bash "$SCLI" status --alarms-only 2>/dev/null)
ok "no record claims neither"               0 "$(printf '%s' "$out" | grep -cE 'what a live seat looks like|terminal is GONE')"
ok "...and the STALL alarm is untouched"    1 "$(printf '%s' "$out" | grep -c '🛑 STALL')"
record_launch "$RS"

# 10d. THE --me SEAT. `council up` launches nothing for the seat the human took, and records it
#      as launched: false, and that seat still holds its turn — so without this branch the
#      commonest healthy path in a human-in-the-room scenario (a person thinking) printed a
#      confident GONE and prescribed a command `relaunch` refuses. The absence is still
#      REPORTED; only the advice changes.
sessions_none
record_launch "$RS" --unlaunched "$FLOOR"
out=$(COUNCIL_STALL_SECS=100 bash "$SCLI" status --alarms-only 2>/dev/null)
ok "an unlaunched seat still reports GONE"   1 "$(printf '%s' "$out" | grep -c 'terminal is GONE')"
ok "...points at the human"                  1 "$(printf '%s' "$out" | grep -c 'waiting on a person')"
ok "...and prescribes no relaunch"           0 "$(printf '%s' "$out" | grep -c 'before running council.sh relaunch')"
# The branch is chosen by the record, which a seat can write, so the sentence must name both
# readings rather than leading with the benign one: a launch that failed at `up` records the same.
ok "...names the failed-launch reading too"  1 "$(printf '%s' "$out" | grep -c 'its last launch failed')"
ok "...and tells the operator to settle it"  1 "$(printf '%s' "$out" | grep -c 'check how this room was started')"
# ...and a session with that seat's name, where nothing was launched, is not taken for it.
sessions "council-$SN-$FLOOR"
out=$(COUNCIL_STALL_SECS=100 bash "$SCLI" status --alarms-only 2>/dev/null)
ok "a session named after an unlaunched seat claims neither" 0 "$(printf '%s' "$out" | grep -cE 'what a live seat looks like|terminal is GONE')"
record_launch "$RS"

# 10f. A FLOOR HOLDER WHOSE TERMINAL HOLDS NO AGENT (#235). The terminal is listed, so the
#      liveness sentence used to say "what a live seat looks like" about a seat whose agent had
#      exited. The occupant read is process state, and `none` on two reads is its own alarm. It
#      removes no alarm — the STALL line stays — and replaces only the two calm lines it would
#      contradict: the listed sentence and, below the stall tier, the `quiet:` line.
sessions "council-$SN-$FLOOR"
printf 'none' > "$OCC"; : > "$OCC_CALLS"
out=$(COUNCIL_STALL_SECS=100 bash "$SCLI" status --alarms-only 2>/dev/null)
ok "10f: no agent in a listed terminal alarms"   1 "$(printf '%s' "$out" | grep -c '🛑 NO AGENT')"
ok "...naming the seat and the remedy"           1 "$(printf '%s' "$out" | grep -c "no live agent to lose: council.sh relaunch $FLOOR")"
ok "...read twice before it is believed"         2 "$(wc -l < "$OCC_CALLS" | tr -d ' ')"
ok "...and the STALL alarm is untouched"         1 "$(printf '%s' "$out" | grep -c '🛑 STALL')"
ok "...and 'a live seat' is not claimed"         0 "$(printf '%s' "$out" | grep -c 'what a live seat looks like')"
# Below the stall threshold: the crash surfaces from the quiet tier's 300s, on the alarms line,
# and the calm `quiet:` sentence — "not a thing that is wrong" — gives way to it.
out=$(COUNCIL_STALL_SECS=100000 bash "$SCLI" status --alarms-only 2>/dev/null)
ok "10f: under the stall tier it still alarms"   1 "$(printf '%s' "$out" | grep -c '🛑 NO AGENT')"
ok "...with no STALL yet"                        0 "$(printf '%s' "$out" | grep -c '🛑 STALL')"
blk=$(COUNCIL_STALL_SECS=100000 bash "$SCLI" status 2>/dev/null)
ok "...and the quiet line gives way to it"       "1 0" "$(printf '%s' "$blk" | grep -c '🛑 NO AGENT') $(printf '%s' "$blk" | grep -c '^quiet:')"
# Under the quiet tier's own threshold nothing is read at all: a moving room pays no occupant call.
: > "$OCC_CALLS"
out=$(COUNCIL_STALL_SECS=100000 COUNCIL_STALL_WARN_SECS=100000 bash "$SCLI" status --alarms-only 2>/dev/null)
ok "10f: under 300s-equivalent: no read, no alarm" "0 0" "$(printf '%s' "$out" | grep -c '🛑 NO AGENT') $(wc -l < "$OCC_CALLS" | tr -d ' ')"
# `agent` and no verdict are no evidence either way, and change nothing.
printf 'agent' > "$OCC"
out=$(COUNCIL_STALL_SECS=100 bash "$SCLI" status --alarms-only 2>/dev/null)
ok "10f: agent -> no alarm, the listed sentence" "0 1" "$(printf '%s' "$out" | grep -c '🛑 NO AGENT') $(printf '%s' "$out" | grep -c 'what a live seat looks like')"
blk=$(COUNCIL_STALL_SECS=100000 bash "$SCLI" status 2>/dev/null)
ok "...and the quiet line is back"               1 "$(printf '%s' "$blk" | grep -c '^quiet:')"
rm -f "$OCC"
out=$(COUNCIL_STALL_SECS=100 bash "$SCLI" status --alarms-only 2>/dev/null)
ok "10f: no verdict -> no alarm"                 0 "$(printf '%s' "$out" | grep -c '🛑 NO AGENT')"
# A closed room holds no floor anyone is waiting on, so its seats are not asked about.
export COUNCIL_ROOM="$R3" ROOM="$R3"
printf 'fake-container\n' > "$R3/state/container-tmux"; printf 'none' > "$OCC"; : > "$OCC_CALLS"
out=$(COUNCIL_STALL_SECS=0 COUNCIL_STALL_WARN_SECS=0 bash "$SCLI" status --alarms-only 2>/dev/null)
ok "10f: a closed room is never asked"           "0 0" "$(printf '%s' "$out" | grep -c '🛑 NO AGENT') $(wc -l < "$OCC_CALLS" | tr -d ' ')"
rm -f "$OCC" "$R3/state/container-tmux"
export COUNCIL_ROOM="$RS" ROOM="$RS"

# 10e. THE BARRIER LABEL. During an open barrier round `$floor` is the label `— (barrier)`, not a
#      seat, and this printed `council.sh relaunch — (barrier)` while `_stall_escalate`'s notice
#      for the same event degraded correctly — because that one had a roster-membership test and
#      this did not. Both now share `_is_seat`.
sessions_none
cp "$RS/roster.json" "$RS/roster.bak"
jq '.mode = "roundtable"' "$RS/roster.bak" > "$RS/roster.json"
# The label needs a launcher for the dead-seat wording to be reachable at all; without one an
# ungated read takes the launcher-less branch, whose text carries no relaunch prescription, and
# the first assertion below passes whether or not the guard exists.
printf '#!/bin/sh\n' > "$RS/state/launch-— (barrier).sh"
out=$(COUNCIL_STALL_SECS=100 bash "$SCLI" status --alarms-only 2>/dev/null)
# BOTH OF THESE BITE, and the fixture line above is what makes the first one do it. An earlier
# version of this comment said the first was unfixable — that a label with spaces and a dash
# "can have no `state/launch-<peer>.sh`" — which was an untested claim about a solution space,
# written while justifying not fixing something, and false: the room is participant-writable, the
# filename is legal, and writing it costs one line. Measured both ways: without the launcher,
# dropping `_is_seat` reds only the second assertion; with it, both.
ok "a barrier label is never called a seat" 0 "$(printf '%s' "$out" | grep -c 'relaunch — (barrier)')"
ok "...and no terminal claim is made of it" 0 "$(printf '%s' "$out" | grep -c 'terminal is GONE')"
mv "$RS/roster.bak" "$RS/roster.json"
rm -f "$RS/state/container-tmux" "$RS/state/launch-$FLOOR.sh" "$RS/state/launch-— (barrier).sh"
record_forget "$RS"

printf '\n%s\n' "$([ "$fails" = 0 ] && echo 't27: all passed' || echo "t27: $fails FAILURES")"
exit $([ "$fails" = 0 ] && echo 0 || echo 1)
