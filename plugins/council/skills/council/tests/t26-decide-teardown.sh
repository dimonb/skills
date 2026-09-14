#!/usr/bin/env bash
# t26 — a decided room closes its own participant terminals (#48).
#
# The decision is the deliverable. A room that reaches `decided` used to leave its agent sessions
# running with nothing anywhere saying so, and the reason an operator walked past them is
# structural rather than careless: the moment a room decides is the moment its OUTPUT arrives, and
# the output is what the operator turns to. So the room has to do it, not the reminder.
#
# THE HAZARD THAT DECIDES THE SHAPE, and what this file therefore pins. `decide` is `--me`-gated,
# so a PARTICIPANT runs it: the seat closing the room is closing its own terminal, and a reap
# written inline would race the process that began it. The room's keeper already runs in its own
# process group and already closes every participant terminal and exits — that is what `up --hold`
# uses when its owner dies — so `decide` signals the keeper instead of growing a second teardown
# path. Everything below is about that hand-off: that it happens, that it happens to the RIGHT
# keeper, that a close whose teardown cannot happen says so rather than reporting one, and that
# the record survives all of it.
#
# No real agent consoles: ct_kill is faked so a reap leaves one marker per peer — the t16/t15/t13
# argument, that a harness must not depend on a live backend.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_helpers.sh
. "$DIR/_helpers.sh"

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}
has() { printf '%s' "$1" | grep -q -- "$2" && printf yes || printf no; }
# Poll, up to <deciseconds> tenths of a second, for a file to appear / a pid to go.
wait_file() { local f="$1" n="${2:-80}" i; for ((i=0;i<n;i++)); do [ -e "$f" ] && { echo yes; return; }; sleep 0.1; done; echo no; }
wait_gone_file() { local f="$1" n="${2:-80}" i; for ((i=0;i<n;i++)); do [ -e "$f" ] || { echo gone; return; }; sleep 0.1; done; echo there; }
wait_gone() { local p="$1" n="${2:-80}" i; for ((i=0;i<n;i++)); do kill -0 "$p" 2>/dev/null || { echo gone; return; }; sleep 0.1; done; echo alive; }
# The keeper polls on a five-second cycle, so every wait here has to allow more than one turn of
# it. 8s is that with room to spare on a loaded machine, and a failure costs 8s rather than hanging.
PATIENCE=80

MARK="$COUNCIL_TEST_ROOT/t26-marks"; rm -rf "$MARK"; mkdir -p "$MARK" || exit 1

# The helpers' `mkroom` with one thing added: the keeper is forked from a shell that has a FAKED
# ct_kill, so a reap is observable as a file per peer. `_mkroom` forks the keeper, and a fork
# carries the functions defined in the shell that made it — which is how t16 watches the canary
# reap without a terminal backend anywhere.
mkroom_faked() { # <dir> <mark-subdir> <peer>...
  local room="$1"; T26_MARK="$COUNCIL_TEST_ROOT/t26-marks/$2"; shift 2
  rm -rf "$room"; mkdir -p "$T26_MARK" || return 1
  ( SKILL="$SKILL"; . "$SKILL/lib/up.sh"
    ct_kill() { : > "$T26_MARK/reaped-$1"; }
    _mkroom "$room" "$@" )
  ROOM_KEEPERS+=("$room/state/keeper.pid")
  printf '%s\n' "$@" | jq -R . | jq -s --argjson t 30 --argjson cms "$(( 10#${EPOCHREALTIME/./} / 1000 ))" \
    '{order:., mode:"token", decide_by:"unanimous", order_rotate:true,
      turn_deadline_ms:3000, turns_budget:$t, created_at:"test", created_ms:$cms}' > "$room/roster.json"
}
kpid_of() { local v; v=$(cat "$1" 2>/dev/null || true); case "$v" in ''|*[!0-9]*) printf '' ;; *) printf '%s' "$v" ;; esac; }

# ================================================================================================
echo "--- A. the keeper takes the marker, reaps every seat, consumes it and exits ---"
# The mechanism on its own, in a DETACHED room — the default kind, and the one with no canary at
# all. Before this change the only reaping trigger a keeper had needed an owner to die.
RA="$COUNCIL_TEST_ROOT/t26a"
mkroom_faked "$RA" a a b
KA=$(kpid_of "$RA/state/keeper.pid")
ok "the room has a keeper to ask" yes "$([ -n "$KA" ] && kill -0 "$KA" 2>/dev/null && echo yes || echo no)"

( . "$SKILL/lib/up.sh"; _keeper_teardown "$RA" ); rc=$?
ok "_keeper_teardown reports it asked the keeper" 0 "$rc"
ok "...and the marker is on disk for the keeper to find" yes "$([ -f "$RA/state/teardown" ] && echo yes || echo no)"
ok "the first seat is closed" yes "$(wait_file "$MARK/a/reaped-a" "$PATIENCE")"
ok "the second seat is closed too" yes "$(wait_file "$MARK/a/reaped-b" "$PATIENCE")"
ok "the keeper exits after reaping" gone "$(wait_gone "$KA" "$PATIENCE")"
# One-shot: a marker left in place is taken again by whatever keeper the room is given next, and
# `relaunch` forks one — so a seat put back up would die within a poll of starting.
ok "...and the marker is consumed, not left for the next keeper" gone "$(wait_gone_file "$RA/state/teardown" "$PATIENCE")"
ok "the record directory is untouched by a teardown" yes "$([ -d "$RA/lane" ] && [ -d "$RA/board" ] && echo yes || echo no)"

# ================================================================================================
echo "--- B. a SUPERSEDED keeper reaps nothing, whoever left the marker ---"
# The step-down check runs before the teardown check, and the order is the whole of this case. A
# keeper whose pid file names somebody else belongs to a room that was rebuilt at this path; its
# ct_kill resolves terminals from $ROOM, so reaping here would close the terminals of the room
# that replaced it — turning a leaked process into a room torn down under its owner.
RB="$COUNCIL_TEST_ROOT/t26b"
mkroom_faked "$RB" b a b
KB=$(kpid_of "$RB/state/keeper.pid")
sleep 30 & USURPER=$!          # a live pid that is not this keeper: the rebuild's own keeper
printf '%s' "$USURPER" > "$RB/state/keeper.pid"
printf 'teardown\n' > "$RB/state/teardown"
ok "the superseded keeper steps down" gone "$(wait_gone "$KB" "$PATIENCE")"
ok "...having reaped nothing" no "$([ -e "$MARK/b/reaped-a" ] || [ -e "$MARK/b/reaped-b" ] && echo yes || echo no)"
ok "...and left the instruction for the keeper it is addressed to" yes "$([ -f "$RB/state/teardown" ] && echo yes || echo no)"
kill -9 "$USURPER" 2>/dev/null; wait "$USURPER" 2>/dev/null

# ================================================================================================
echo "--- C. with no live keeper there is nothing to ask, and nothing is written ---"
# A marker nothing will ever take is worse than none: `decide` would report a teardown that cannot
# happen, and the file would sit waiting for whichever keeper the room is given next.
RC="$COUNCIL_TEST_ROOT/t26c"; rm -rf "$RC"; mkdir -p "$RC/state" || exit 1
( . "$SKILL/lib/up.sh"; _keeper_teardown "$RC" ); rc=$?
ok "no pid file at all: refused" 1 "$rc"
ok "...and no marker written" no "$([ -e "$RC/state/teardown" ] && echo yes || echo no)"

sleep 0 & DEADPID=$!; wait "$DEADPID" 2>/dev/null    # a pid that has certainly exited
printf '%s' "$DEADPID" > "$RC/state/keeper.pid"
( . "$SKILL/lib/up.sh"; _keeper_teardown "$RC" ); rc=$?
ok "a pid file naming a dead process: refused" 1 "$rc"
ok "...and still no marker written" no "$([ -e "$RC/state/teardown" ] && echo yes || echo no)"

# `kill -0 0` SUCCEEDS and means every process in the sender's own process group, so a pid file
# holding `0` reads as "a keeper is running" to any check that does not go through `_keeper_pid`.
# This is a new caller of that reader, so the trap is asserted here rather than assumed.
printf '0' > "$RC/state/keeper.pid"
( . "$SKILL/lib/up.sh"; _keeper_teardown "$RC" ); rc=$?
ok "a pid file holding 0 is not a keeper: refused" 1 "$rc"
ok "...and still no marker written" no "$([ -e "$RC/state/teardown" ] && echo yes || echo no)"

# ================================================================================================
echo "--- D. the shipped verb: a decided close asks for the seats, and says so ---"
# Through council.sh, because the call site is what was missing — the hand-off has to be wired into
# `decide`, not merely available to it.
RD="$COUNCIL_TEST_ROOT/t26d"
mkroom_faked "$RD" d a b c
export COUNCIL_ROOM="$RD" ROOM="$RD"
echo "Should the log keep one lane per author?" > "$RD/agenda.md"
prop=$(say_floor propose '[]' "Keep the history as one lane per author.")
obj=$(say_floor  object  '["'"$prop"'-1"]' "Then a reader scans N directories on every poll.")
say_floor amend '["'"$prop"'-1","'"$obj"'-1"]' "One lane per author; readers probe upward from a cursor." >/dev/null
say_floor msg '[]' "Agreed."        >/dev/null
say_floor msg '[]' "No objections." >/dev/null
say_floor msg '[]' "Record it."     >/dev/null
ok "the room is ripe" ready-to-decide "$(verdict1)"
KD=$(kpid_of "$RD/state/keeper.pid")
errd="$COUNCIL_TEST_ROOT/t26d.err"
outd=$(COUNCIL_ME=a bash "$CLI" decide 2>"$errd"); rc=$?
ok "a decided close still exits 0" 0 "$rc"
# The record path is the verb's OUTPUT and callers read it as one line; everything the teardown
# has to say is a report, so it goes to stderr or it corrupts that.
ok "...printing the record path and nothing else on stdout" "$RD/board/decision.md" "$outd"
ok "...and stderr says the terminals are going" yes "$(has "$(cat "$errd")" 'keeper has been asked')"
ok "the seats are closed" yes "$(wait_file "$MARK/d/reaped-a" "$PATIENCE")"
ok "...all of them" yes "$([ -e "$MARK/d/reaped-b" ] && [ -e "$MARK/d/reaped-c" ] && echo yes || echo no)"
ok "the keeper exits" gone "$(wait_gone "$KD" "$PATIENCE")"
# The whole argument for closing the seats is that nothing of value goes with them.
ok "the record survives the teardown" yes "$([ -s "$RD/board/decision.md" ] && echo yes || echo no)"
ok "board/status still says decided" decided "$(cat "$RD/board/status" 2>/dev/null)"
ok "the transcript still serves" yes "$(bash "$CLI" transcript 2>/dev/null | grep -q 'one lane per author' && echo yes || echo no)"
# The announcement rings every seat so each learns now rather than at its own timeout. Closing the
# terminals before it lands would make it pointless, so it must be in the log by the time the
# teardown is asked for — and it is, because the request is the verb's last act.
ok "the room was told before the seats went" yes "$(bash "$CLI" order 2>/dev/null | jq -e 'select(.act == "decide")' >/dev/null 2>&1 && echo yes || echo no)"

# ================================================================================================
echo "--- E. an UNRESOLVED close leaves the seats up, and points at down ---"
# A room that did not converge is the one a person is most likely to want to walk into, and the
# close has just escalated it as needs-human (ESC-04). The owner's rule is about a room whose
# question is answered; it does not reach a room that failed to answer one.
RE="$COUNCIL_TEST_ROOT/t26e"
mkroom_faked "$RE" e a b c
export COUNCIL_ROOM="$RE" ROOM="$RE"
jq '.turns_budget = 9' "$RE/roster.json" > "$RE/roster.tmp" && mv "$RE/roster.tmp" "$RE/roster.json"
echo "Should we take on one more schedule mode?" > "$RE/agenda.md"
prop=$(say_floor propose '[]' "Add a swarm mode right away, alongside token.")
say_floor object '["'"$prop"'-1"]' "Swarm needs a stability rule first. Separate work." >/dev/null
for _t in "I see both sides." "Yes, it is hard." "Agreed, it is hard." "Right." "Uh-huh." "Mm." "Still thinking."; do
  say_floor msg '[]' "$_t" >/dev/null
done
ok "the room is unresolved" unresolved "$(verdict1)"
KE=$(kpid_of "$RE/state/keeper.pid")
erre="$COUNCIL_TEST_ROOT/t26e.err"
oute=$(COUNCIL_ME=a bash "$CLI" decide --force 2>"$erre"); rc=$?
ok "--force still closes the room at exit 0" 0 "$rc"
ok "...printing the record path and nothing else on stdout" "$RE/board/decision.md" "$oute"
ok "...and asking for no teardown" no "$([ -e "$RE/state/teardown" ] && echo yes || echo no)"
ok "...saying the terminals are left live" yes "$(has "$(cat "$erre")" 'LEFT LIVE')"
ok "...and naming the verb that closes them" yes "$(has "$(cat "$erre")" 'council.sh down --room t26e')"
# Give the keeper more than a poll cycle to prove it is not going anywhere.
sleep 6
ok "the keeper is still there" yes "$([ -n "$KE" ] && kill -0 "$KE" 2>/dev/null && echo yes || echo no)"
ok "...and nothing was reaped" no "$([ -e "$MARK/e/reaped-a" ] && echo yes || echo no)"

# ================================================================================================
echo "--- F. a close whose teardown cannot happen reports it, and is still a close ---"
# The record is the deliverable, so a failed teardown must not turn a successful close into a
# failure. It gets an exit code of its own rather than borrowing 4 (the announcement's) or
# spoiling 0 — a pass that did not run is never reported as one that did.
RF="$COUNCIL_TEST_ROOT/t26f"
mkroom_faked "$RF" f a b c
export COUNCIL_ROOM="$RF" ROOM="$RF"
echo "Should the log keep one lane per author?" > "$RF/agenda.md"
prop=$(say_floor propose '[]' "Keep the history as one lane per author.")
obj=$(say_floor  object  '["'"$prop"'-1"]' "Then a reader scans N directories on every poll.")
say_floor amend '["'"$prop"'-1","'"$obj"'-1"]' "One lane per author; readers probe upward from a cursor." >/dev/null
say_floor msg '[]' "Agreed."        >/dev/null
say_floor msg '[]' "No objections." >/dev/null
say_floor msg '[]' "Record it."     >/dev/null
KF=$(kpid_of "$RF/state/keeper.pid")
kill_keeper "$RF/state/keeper.pid"
ok "the keeper is gone before the close" gone "$(wait_gone "$KF" "$PATIENCE")"
errf="$COUNCIL_TEST_ROOT/t26f.err"
outf=$(COUNCIL_ME=a bash "$CLI" decide 2>"$errf"); rc=$?
ok "the close exits 5, not 0 and not 4" 5 "$rc"
ok "...still printing the record path, because the record is the output" "$RF/board/decision.md" "$outf"
ok "...saying the terminals could NOT be closed" yes "$(has "$(cat "$errf")" 'could NOT be closed')"
ok "...and naming the verb that closes them" yes "$(has "$(cat "$errf")" 'council.sh down --room t26f')"
ok "the room is genuinely closed" decided "$(cat "$RF/board/status" 2>/dev/null)"
ok "...and was told so" yes "$(bash "$CLI" order 2>/dev/null | jq -e 'select(.act == "decide")' >/dev/null 2>&1 && echo yes || echo no)"
ok "...and no marker was left for a future keeper to act on" no "$([ -e "$RF/state/teardown" ] && echo yes || echo no)"

# ================================================================================================
echo "--- G. relaunch cancels a pending teardown, at the call site ---"
# Putting a seat back up is an operator saying this room is in use again, so it outranks a close
# that asked for the seats to go — and it has to, or the seat launched by `relaunch` is killed
# within one keeper poll of starting, which reads as the relaunch having silently failed.
#
# The real verb, over a real room built by the real `up`, on a backend name that cannot resolve —
# t24's arrangement. `relaunch` fails at its launch, which is expected and not what is asserted:
# the clear and the keeper both happen before it, and a check tested anywhere but at its call site
# stays green when the caller stops calling it.
RG_REPO="$COUNCIL_TEST_ROOT/t26g-repo"; rm -rf "$RG_REPO"; mkdir -p "$RG_REPO" || exit 1
( cd "$RG_REPO" && git init -q . \
  && COUNCIL_BACKEND=none-for-tests bash "$CLI" --room t26g --me codex up \
       --scenario debate --agents claude,codex --cwd . "does relaunch cancel a teardown?" ) >"$COUNCIL_TEST_ROOT/t26g-up.log" 2>&1
RG="$RG_REPO/.git/council/t26g"
if [ ! -f "$RG/roster.json" ]; then
  echo "  FAIL G: up did not build a room"; sed -n '1,20p' "$COUNCIL_TEST_ROOT/t26g-up.log"; FAILURES=$((FAILURES + 1))
else
  ROOM_KEEPERS+=("$RG/state/keeper.pid")
  kill_keeper "$RG/state/keeper.pid"          # the stale marker's premise: its keeper died first
  printf 'teardown\n' > "$RG/state/teardown"
  ( cd "$RG_REPO" && COUNCIL_BACKEND=none-for-tests bash "$CLI" --room t26g relaunch claude ) \
    >"$COUNCIL_TEST_ROOT/t26g-relaunch.log" 2>&1
  # THE LIVE KEEPER IS THE ASSERTION HERE, not the absent marker, and the difference was measured
  # rather than reasoned: with the clear removed, the keeper `_keeper_ensure` forks takes the
  # marker on its very FIRST pass — in milliseconds, before the next line of this test runs — so
  # the file is gone either way and a check on the file alone passes straight over the bug. What
  # only the clear produces is a keeper that is still there a moment later, which is exactly the
  # thing the relaunched seat needs.
  KG=$(kpid_of "$RG/state/keeper.pid")
  ok "relaunch left a keeper running" yes "$([ -n "$KG" ] && echo yes || echo no)"
  ok "...which found no teardown to act on, so it is still alive" alive "$(wait_gone "$KG" 20)"
  ok "...over a room with no pending teardown" no "$([ -e "$RG/state/teardown" ] && echo yes || echo no)"
fi

# ================================================================================================
printf '\nt26-decide-teardown: %s checks, %s failed\n' "$CHECKS" "$FAILURES"
[ "$FAILURES" = 0 ] || exit 1
echo "t26 PASS"
