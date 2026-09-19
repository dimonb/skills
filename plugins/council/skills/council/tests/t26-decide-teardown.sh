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
#
# Needs bash >= 5 for what IT uses: `$EPOCHREALTIME` in mkroom_faked, and — in case H — the
# `{fd}` redirections `_keeper_ensure` builds the owner canary with. Stock macOS starts scripts
# under bash 3.2, so re-exec into a modern one, the same guard council.sh, t15, t16 and t19 use.
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ] && [ -z "${T26_BASH_REEXEC:-}" ]; then
  for _c in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash bash; do
    _p=$(command -v "$_c" 2>/dev/null) || continue
    _v=$("$_p" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null) || continue
    [ "${_v:-0}" -ge 5 ] && exec env T26_BASH_REEXEC=1 "$_p" "$0" "$@"
  done
  echo "t26: needs bash >= 5, this one is ${BASH_VERSION:-unknown}." >&2
  exit 70
fi

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

# THE DIAGONAL: no keeper AND a state directory that would also be refused. Liveness is checked
# FIRST, so this must answer "no live keeper" (1) and not "could not be written" (2) — with no
# keeper nothing will ever reap whatever the directory looks like, and reporting the write is
# reporting a cause that was never reached. Without this the reorder is untested: moving
# `_room_dirs_sane` back above the liveness pair leaves the rest of this file green.
RCS="$COUNCIL_TEST_ROOT/t26c-sym"; rm -rf "$RCS" "$RCS-real"
mkdir -p "$RCS" "$RCS-real/state" || exit 1
ln -s "$RCS-real/state" "$RCS/state"
printf '%s' "$DEADPID" > "$RCS-real/state/keeper.pid"
( . "$SKILL/lib/up.sh"; _keeper_teardown "$RCS" ) 2>/dev/null; rc=$?
ok "a dead keeper behind a symlinked state/: refused as NO KEEPER, not as a failed write" 1 "$rc"
ok "...and still no marker written" no "$([ -e "$RCS-real/state/teardown" ] && echo yes || echo no)"

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
# Give the keeper more than a poll cycle to prove it is not going anywhere. `hold` spends that
# window checking, so a keeper that DOES go reds here immediately instead of six seconds later.
hold 1 "$KE"
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
# HOLD THE ROOM'S BELLS OPEN ACROSS THE CLOSE. This case has deliberately removed the only process
# that normally does, and `decide` still rings every peer (`c_send`'s trailing `c_ring` loop). A
# ring is a DETACHED writer — `( printf '.' > "$f" & )` — so with no reader it blocks in open(2)
# for ever; and because it is forked inside the verb's `>/dev/null` scope, it inherits the copy of
# the caller's ORIGINAL stdout that bash saved on fd 10, which is this line's command-substitution
# pipe. `$( )` returns when the last writer to that pipe closes, not when the command exits — so
# the verb finished, wrote its record and its stderr, and this test still hung for ever, with two
# blocked orphans per run.
#
# WHAT WAS ACTUALLY HOLDING THIS CASE UP BEFORE, because it was not the absence of the problem: at
# the production five-second period the keeper's `sleep 5` is a CHILD that inherited its bell fds,
# so killing the keeper left that orphan holding every bell open for up to five more seconds —
# long enough for these rings to complete. The case passed on a leaked file descriptor. Shorten
# the period and the orphan goes in 50 ms, the rings block, and the hang is permanent. So this is
# not a symptom of the faster poll; it is a dependency the faster poll exposed, and the fix is to
# say out loud what the fixture needs rather than to slow the suite back down until luck returns.
#
# The premise is untouched: a fifo held open by this shell is not a keeper. `_keeper_teardown`
# still asks `_keeper_pid` + `kill -0`, still gets nothing, and still returns 1 — which is the
# exit-5 arm every assertion below is about.
#
# (The blocking `c_ring` itself is a production hazard, not a test one — a `decide` against a
# genuinely keeperless room leaks a stuck writer per peer — and it is #209 rather than something
# fixed here, where the change is about how long the suite takes. The hang this line-block avoids
# is the fourth instance on #109.)
f_bells=()
for _p in a b c; do
  exec {_bf}<>"$RF/bell/$_p.fifo" && f_bells+=("$_bf")
done
outf=$(COUNCIL_ME=a bash "$CLI" decide 2>"$errf"); rc=$?
for _bf in ${f_bells[@]+"${f_bells[@]}"}; do exec {_bf}>&-; done
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
echo "--- H. a --hold room takes the marker too, while its owner is still holding ---"
# The placement of the teardown check is what this case pins, and nothing else in the suite can
# see it. Every other room in this file is DETACHED — `mkroom_faked` sets no _KEEPER_OWNER_HOLD,
# so its keepers have no canary and fall straight through to `sleep 5`. A `--hold` keeper takes
# the other branch: it blocks in `read -t 5` on the canary and `continue`s on every timeout, so a
# teardown check placed below that read is not merely late, it is NEVER REACHED — the marker
# would sit on disk for the life of the room while `decide` exited 0 saying the seats were going.
# Measured by mutation through the shipped `up --hold` + `decide` path, where the mutant's exit
# code and stderr were byte-identical to the healthy one.
#
# The owner is a live subshell holding the canary write end, exactly as t16's OWNER script and the
# tail of `up --hold` do, and its `wait` is FORKLESS on purpose: a `sleep` child would inherit the
# write end and the canary would never EOF (t16 case D). One consequence is asserted rather than
# fought: the keeper is that subshell's background job, so the owner falls out of `wait` and exits
# the moment the keeper does. The owner is therefore checked alive BEFORE the marker is written —
# which is what makes this a teardown and not a canary death — and never after the reap. Asserting
# "the owner outlives the keeper" would be flaky by construction, and measuring it on the HEALTHY
# code is what showed that.
#
# THE CONSUMED MARKER IS WHAT NAMES THE TRIGGER. Both of the keeper's reaping paths leave the same
# `reaped-*` files, so those alone cannot tell a teardown from an owner death; of the two, only
# the teardown path `rm`s the marker. "Seats reaped AND marker gone" is therefore the one
# combination the canary path cannot produce. (`relaunch` clears the marker too — no case here
# relaunches, but a case that did could not use this discriminator.)
RH="$COUNCIL_TEST_ROOT/t26h"; rm -rf "$RH"
T26H_MARK="$COUNCIL_TEST_ROOT/t26-marks/h"; mkdir -p "$T26H_MARK" || exit 1
( SKILL="$SKILL"; . "$SKILL/lib/up.sh"
  ct_kill() { : > "$T26H_MARK/reaped-$1"; }
  _KEEPER_OWNER_HOLD=1
  _mkroom "$RH" a b || exit 1
  unset _KEEPER_OWNER_HOLD
  # The ready file carries the CANARY FD, not a word, and that is this case's premise assertion.
  # `_keeper_ensure` sets `_KEEPER_CANARY_WFD` in the calling shell when and only when the hold
  # branch ran, so a non-empty integer here is the proof that this really is a held room.
  printf '%s\n' "${_KEEPER_CANARY_WFD:-}" > "$T26H_MARK/ready"
  wait ) &                       # the owner: holds the canary write end until the keeper exits
HOWNER=$!
ROOM_KEEPERS+=("$RH/state/keeper.pid")
ok "the --hold room came up" yes "$(wait_file "$T26H_MARK/ready" "$PATIENCE")"
KH=$(kpid_of "$RH/state/keeper.pid")
ok "...with a live keeper" yes "$([ -n "$KH" ] && kill -0 "$KH" 2>/dev/null && echo yes || echo no)"
# ASSERT THE PREMISE, because without this the case silently stops testing what it is for. The
# old check here was `kill -0` alone and was LABELLED "carrying a canary", which it did not
# establish: measured, deleting `_KEEPER_OWNER_HOLD=1` from the fixture above left this whole file
# passing 74/74 against the very mutation case H exists to kill. A room that is quietly detached
# is a room this case cannot distinguish from the thing it is testing.
ok "...whose canary is actually armed — the premise of this case" yes \
   "$(read -r _wfd < "$T26H_MARK/ready" 2>/dev/null; case "${_wfd:-}" in ''|*[!0-9]*) echo no ;; *) echo yes ;; esac)"
ok "...and an owner still holding it open" yes "$(kill -0 "$HOWNER" 2>/dev/null && echo yes || echo no)"
ok "nothing is reaped while the owner lives and no marker exists" no \
   "$([ -e "$T26H_MARK/reaped-a" ] && echo yes || echo no)"
( . "$SKILL/lib/up.sh"; _keeper_teardown "$RH" ); rc=$?
ok "_keeper_teardown reports it asked the --hold keeper" 0 "$rc"
ok "the first seat is closed" yes "$(wait_file "$T26H_MARK/reaped-a" "$PATIENCE")"
ok "the second seat is closed too" yes "$(wait_file "$T26H_MARK/reaped-b" "$PATIENCE")"
ok "the keeper exits after reaping" gone "$(wait_gone "$KH" "$PATIENCE")"
ok "...having consumed the marker, which is what names the trigger" gone \
   "$(wait_gone_file "$RH/state/teardown" "$PATIENCE")"
ok "the record directory is untouched" yes "$([ -d "$RH/lane" ] && [ -d "$RH/board" ] && echo yes || echo no)"
kill -9 "$HOWNER" 2>/dev/null; wait "$HOWNER" 2>/dev/null

# ================================================================================================
echo "--- I. --force on a RIPE room still records decided, and still tears down ---"
# The cell no test visited, and the one four documentation sites used to describe backwards.
# `--force` is read in exactly one expression in v_decide — the `*)` arm that lifts the not-ripe
# refusal — so on a room that HAS converged it is a no-op: the verdict is still ready-to-decide,
# the record still comes out `decided`, and the teardown still happens. Case E covers `--force` on
# an unresolved room, which is the other half and the one that leaves the seats up; between them
# they say that the gate is the RECORDED STATUS and never the flag.
RI="$COUNCIL_TEST_ROOT/t26i"
mkroom_faked "$RI" i a b c
export COUNCIL_ROOM="$RI" ROOM="$RI"
echo "Should the log keep one lane per author?" > "$RI/agenda.md"
prop=$(say_floor propose '[]' "Keep the history as one lane per author.")
obj=$(say_floor  object  '["'"$prop"'-1"]' "Then a reader scans N directories on every poll.")
say_floor amend '["'"$prop"'-1","'"$obj"'-1"]' "One lane per author; readers probe upward from a cursor." >/dev/null
say_floor msg '[]' "Agreed."        >/dev/null
say_floor msg '[]' "No objections." >/dev/null
say_floor msg '[]' "Record it."     >/dev/null
ok "the room is ripe" ready-to-decide "$(verdict1)"
KI=$(kpid_of "$RI/state/keeper.pid")
erri="$COUNCIL_TEST_ROOT/t26i.err"
outi=$(COUNCIL_ME=a bash "$CLI" decide --force 2>"$erri"); rc=$?
ok "--force on a ripe room exits 0" 0 "$rc"
ok "...recording decided, not unresolved" decided "$(cat "$RI/board/status" 2>/dev/null)"
ok "...printing the record path and nothing else on stdout" "$RI/board/decision.md" "$outi"
ok "...and asking for the teardown like any decided close" yes "$(has "$(cat "$erri")" 'keeper has been asked')"
ok "the seats go" yes "$(wait_file "$MARK/i/reaped-a" "$PATIENCE")"
ok "...all of them" yes "$([ -e "$MARK/i/reaped-b" ] && [ -e "$MARK/i/reaped-c" ] && echo yes || echo no)"
ok "the keeper exits" gone "$(wait_gone "$KI" "$PATIENCE")"

# ================================================================================================
echo "--- J. a successful close does not let an advisory write decide its exit status ---"
# The verb's last statement is a message on stderr. Without an explicit `return 0` that write
# BECOMES the exit status, and a close that fully succeeded then reports 1 — the code documented
# as "the record could not be written, the room is NOT closed, no path is printed", every clause
# of it false. Measured before the fix: `2>&-` gave 1 and a dead stderr pipe gave 141, where
# origin/main gave 0 for both. No in-tree caller closes stderr, which is exactly why the suite
# could not see it; this case is the trigger the tree otherwise lacks.
RJ="$COUNCIL_TEST_ROOT/t26j"
mkroom_faked "$RJ" j a b c
export COUNCIL_ROOM="$RJ" ROOM="$RJ"
echo "Should the log keep one lane per author?" > "$RJ/agenda.md"
prop=$(say_floor propose '[]' "Keep the history as one lane per author.")
obj=$(say_floor  object  '["'"$prop"'-1"]' "Then a reader scans N directories on every poll.")
say_floor amend '["'"$prop"'-1","'"$obj"'-1"]' "One lane per author; readers probe upward from a cursor." >/dev/null
say_floor msg '[]' "Agreed."        >/dev/null
say_floor msg '[]' "No objections." >/dev/null
say_floor msg '[]' "Record it."     >/dev/null
outj=$(COUNCIL_ME=a bash "$CLI" decide 2>&-); rc=$?
ok "a clean close with stderr CLOSED still exits 0" 0 "$rc"
ok "...and still prints the record path" "$RJ/board/decision.md" "$outj"
ok "...over a room that really did close" decided "$(cat "$RJ/board/status" 2>/dev/null)"

# ================================================================================================
echo "--- K. a teardown that could not be WRITTEN says so, and does not blame a missing keeper ---"
# `_keeper_teardown` can fail two ways and they are different facts. While both returned 1, a room
# whose keeper was alive and answering `kill -0` was told "this room has no live keeper to do the
# reaping" — a verb reporting a cause it had not established, which is the defect exit 5 exists to
# prevent, one level down. Reached with an unwritable `state/`, and the reason that is reachable
# rather than theoretical is worth recording: `c_send` bumps `state/$ME.seq` and `.lamport` with
# NO status check, so an unwritable state directory does not fail the close first — the room
# closes, the announcement lands, and only the teardown notices.
#
# Root cannot be made to fail an open(2) by mode bits, so skip rather than assert a lie.
if [ "$(id -u)" = 0 ]; then
  echo "  SKIP K: running as root — mode bits do not apply"
else
  RK="$COUNCIL_TEST_ROOT/t26k"
  mkroom_faked "$RK" k a b c
  export COUNCIL_ROOM="$RK" ROOM="$RK"
  echo "Should the log keep one lane per author?" > "$RK/agenda.md"
  prop=$(say_floor propose '[]' "Keep the history as one lane per author.")
  obj=$(say_floor  object  '["'"$prop"'-1"]' "Then a reader scans N directories on every poll.")
  say_floor amend '["'"$prop"'-1","'"$obj"'-1"]' "One lane per author; readers probe upward from a cursor." >/dev/null
  say_floor msg '[]' "Agreed."        >/dev/null
  say_floor msg '[]' "No objections." >/dev/null
  say_floor msg '[]' "Record it."     >/dev/null
  KK=$(kpid_of "$RK/state/keeper.pid")
  # RESTORE THE MODE FROM A TRAP, chained onto the helpers' own handler rather than replacing it.
  # t23 carries this same guard and says why: a test killed between the two chmods leaves a
  # mode-500 directory that `rm -rf` CANNOT remove, so run-all.sh's EXIT trap fails and the whole
  # run root leaks permanently — and nothing ever reuses or cleans that path. The suite's 600 s
  # ceiling group-kills a wedged test, so it is a reachable path, not a hypothetical one.
  # Reproduced here before it was added: abort between the chmods, `rm: … Directory not empty`,
  # root left behind. Copying t23's chmod without t23's trap is exactly how it came back.
  _t26_restore_state() { local rc=$?; chmod 700 "$RK/state" 2>/dev/null; ( exit $rc ); _council_test_cleanup; }
  trap _t26_restore_state EXIT
  chmod 500 "$RK/state" || { echo "  FAIL K: could not make state/ read-only"; exit 1; }
  errk="$COUNCIL_TEST_ROOT/t26k.err"
  outk=$(COUNCIL_ME=a bash "$CLI" decide 2>"$errk"); rc=$?
  chmod 700 "$RK/state"
  trap _council_test_cleanup EXIT
  ok "an unwritable state/ still exits 5, like any teardown that did not happen" 5 "$rc"
  ok "...still printing the record path, because the close stands" "$RK/board/decision.md" "$outk"
  ok "...saying the request could not be WRITTEN" yes "$(has "$(cat "$errk")" 'could not be written to')"
  # The whole point: it must NOT claim the room has no keeper, because the keeper is right there.
  ok "...and NOT blaming a missing keeper" no "$(has "$(cat "$errk")" 'no live keeper')"
  # And the suppressor has to be in front of the redirection, or bash's own diagnostic for the
  # MARKER write lands above council's sentence. Since the message no longer says "the error above
  # says why", a silent revert would leave that raw line unexplained.
  #
  # Matched on the PATH, not on "Permission denied" alone, and the difference is the whole
  # assertion: this fixture makes `state/` unwritable, so `c_send`'s own `state/<me>.seq` and
  # `.lamport` bumps fail too and leak their own "Permission denied" (lib.sh:696-697 writes them
  # through `c_atomic` with no status check — which is also why the close still reaches the
  # teardown instead of failing earlier). A bare "Permission denied" test therefore passes or
  # fails for a reason that has nothing to do with the suppressor. Caught by this assertion
  # reporting the wrong thing on its first run.
  ok "...with no raw shell diagnostic for the marker write above it" no \
     "$(has "$(cat "$errk")" 'teardown: Permission denied')"
  ok "the keeper really was alive throughout" yes "$([ -n "$KK" ] && kill -0 "$KK" 2>/dev/null && echo yes || echo no)"
  ok "the room is closed regardless" decided "$(cat "$RK/board/status" 2>/dev/null)"
fi

# ================================================================================================
echo "--- L. a caller with no keeper machinery in scope says THAT, not 'no live keeper' ---"
# The third arm of the exit-5 branch, and the only one `council.sh decide` cannot reach —
# council.sh always sources lib/up.sh for this verb, which is exactly why it needs a test here:
# nothing else in the tree exercises the sentence, and a later refactor of that sourcing would
# make it CLI-reachable with nothing watching. The distinction matters because "no live keeper"
# is a claim about the ROOM, while this is a fact about the CALLER, and the room in this case has
# a perfectly good keeper.
RL="$COUNCIL_TEST_ROOT/t26l"
mkroom_faked "$RL" l a b c
export COUNCIL_ROOM="$RL" ROOM="$RL"
echo "Should the log keep one lane per author?" > "$RL/agenda.md"
prop=$(say_floor propose '[]' "Keep the history as one lane per author.")
obj=$(say_floor  object  '["'"$prop"'-1"]' "Then a reader scans N directories on every poll.")
say_floor amend '["'"$prop"'-1","'"$obj"'-1"]' "One lane per author; readers probe upward from a cursor." >/dev/null
say_floor msg '[]' "Agreed."        >/dev/null
say_floor msg '[]' "No objections." >/dev/null
say_floor msg '[]' "Record it."     >/dev/null
KL=$(kpid_of "$RL/state/keeper.pid")
errl="$COUNCIL_TEST_ROOT/t26l.err"
# lib.sh + verbs.sh + policy.sh, deliberately WITHOUT lib/up.sh — a library caller, not the CLI.
outl=$( COUNCIL_ROOM="$RL" COUNCIL_ME=a SKILL="$SKILL" bash -c '
  set -uo pipefail
  . "$SKILL/lib/lib.sh"; . "$SKILL/lib/verbs.sh"; . "$SKILL/lib/policy.sh"
  v_decide' 2>"$errl" ); rc=$?
ok "a library caller without lib/up.sh exits 5" 5 "$rc"
ok "...still printing the record path" "$RL/board/decision.md" "$outl"
ok "...saying the machinery is not in scope" yes "$(has "$(cat "$errl")" 'no keeper machinery in scope')"
ok "...and NOT blaming the room for a missing keeper" no "$(has "$(cat "$errl")" 'no live keeper')"
ok "the room's keeper really was alive" yes "$([ -n "$KL" ] && kill -0 "$KL" 2>/dev/null && echo yes || echo no)"
ok "...and nothing was reaped, since nobody was asked" no "$([ -e "$MARK/l/reaped-a" ] && echo yes || echo no)"

# ================================================================================================
echo "--- M. the marker path cannot be turned into a symlink that swallows the request ---"
# The fourth bypass route, and the only one that was a live defect rather than a race. `>` FOLLOWS
# a symlink, so pointing `state/teardown` at a non-regular file made the write succeed — rc 0,
# `decide` reporting the seats were going — while the keeper's `[ -f "$tdn" ]` stayed false for
# ever and nothing reaped. The room is not a trust boundary, so a seat can plant that link; the
# write goes through `mv -f` now, which REPLACES a link at the destination instead of following
# it, exactly as `_write_launcher` has always done a few hundred lines away.
RM="$COUNCIL_TEST_ROOT/t26m"
mkroom_faked "$RM" m a b
KM=$(kpid_of "$RM/state/keeper.pid")
ln -sf /dev/null "$RM/state/teardown"
ok "the marker path starts out as a planted symlink" yes "$([ -L "$RM/state/teardown" ] && echo yes || echo no)"
( . "$SKILL/lib/up.sh"; _keeper_teardown "$RM" ); rc=$?
ok "_keeper_teardown still reports it asked the keeper" 0 "$rc"
# The discriminator: a bare `>` leaves the link in place and writes through it, so the keeper
# never sees a regular file. `mv -f` replaces it.
ok "...having REPLACED the link rather than written through it" no "$([ -L "$RM/state/teardown" ] && echo yes || echo no)"
ok "...leaving a regular file the keeper can actually see" yes "$([ -f "$RM/state/teardown" ] && echo yes || echo no)"
# And the end-to-end proof, which is what the route actually cost: the seats really do go.
ok "the seats go, which the symlink used to prevent for ever" yes "$(wait_file "$MARK/m/reaped-a" "$PATIENCE")"
ok "...both of them" yes "$([ -e "$MARK/m/reaped-b" ] && echo yes || echo no)"
ok "the keeper exits" gone "$(wait_gone "$KM" "$PATIENCE")"
# No temp file left behind by the rename.
ok "...leaving no .teardown temp behind" no "$(ls "$RM"/state/.teardown.* >/dev/null 2>&1 && echo yes || echo no)"

# A LINK TO A REGULAR FILE is the shape that discriminates, and the earlier version of this case
# used /dev/null for it — which cannot: writing through /dev/null leaves it a character device, so
# `[ -c /dev/null ]` is true either way and the check passed against the unfixed code. Point the
# link at a file whose CONTENT can be inspected instead.
RM2="$COUNCIL_TEST_ROOT/t26m2"
mkroom_faked "$RM2" m2 a b
KM2=$(kpid_of "$RM2/state/keeper.pid")
VICTIM="$COUNCIL_TEST_ROOT/t26m2-victim"; printf 'do not clobber me\n' > "$VICTIM"
ln -sf "$VICTIM" "$RM2/state/teardown"
( . "$SKILL/lib/up.sh"; _keeper_teardown "$RM2" ); rc=$?
ok "a link to a regular file: the request is still made" 0 "$rc"
ok "...and the victim is untouched, not written through" "do not clobber me" "$(cat "$VICTIM")"
ok "...the link replaced by a real file" no "$([ -L "$RM2/state/teardown" ] && echo yes || echo no)"
ok "...and the seats go" yes "$(wait_file "$MARK/m2/reaped-a" "$PATIENCE")"

# A DIRECTORY at the destination, and a link to one. `mv file dir` does NOT replace the directory
# — it moves the file INSIDE it, at rc 0 — so the rename alone reports success while `[ -f ]`
# stays false for ever and nothing reaps. That is the same silent failure the rename was added to
# prevent, reached with `mkdir` instead of `ln -s`, and the bare `>` it replaced refused it with
# rc 2. Found in review of the rename itself.
for shape in dir symlink-to-dir; do
  RD="$COUNCIL_TEST_ROOT/t26m-$shape"
  mkroom_faked "$RD" "m-$shape" a b
  KD=$(kpid_of "$RD/state/keeper.pid")
  if [ "$shape" = dir ]; then
    mkdir "$RD/state/teardown"
  else
    mkdir "$COUNCIL_TEST_ROOT/t26m-otherdir-$shape"
    ln -sf "$COUNCIL_TEST_ROOT/t26m-otherdir-$shape" "$RD/state/teardown"
  fi
  ( . "$SKILL/lib/up.sh"; _keeper_teardown "$RD" ) 2>/dev/null; rc=$?
  ok "$shape at the marker path: REFUSED, not silently swallowed" 2 "$rc"
  ok "...and no temp left inside it" no \
     "$(ls "$RD"/state/teardown/.teardown.* >/dev/null 2>&1 && echo yes || echo no)"
  ok "...nor at its own name" no "$(ls "$RD"/state/.teardown.* >/dev/null 2>&1 && echo yes || echo no)"
  # The keeper must be left alone: a refused request is not a teardown. Once per shape, so this
  # is the wait the loop multiplies — `hold` makes it one second of polling instead of six of
  # sleeping, and reds at once on the shape that does slip through.
  hold 1 "$KD"
  ok "...the keeper is untouched, since nothing was asked of it" yes \
     "$([ -n "$KD" ] && kill -0 "$KD" 2>/dev/null && echo yes || echo no)"
  ok "...and nothing was reaped" no "$([ -e "$MARK/m-$shape/reaped-a" ] && echo yes || echo no)"
done

# ================================================================================================
printf '\nt26-decide-teardown: %s checks, %s failed\n' "$CHECKS" "$FAILURES"
[ "$FAILURES" = 0 ] || exit 1
echo "t26 PASS"
