#!/usr/bin/env bash
# t19 — the keeper steps down when its room is REBUILT AT THE SAME PATH, issue #102.
#
# The keeper used to poll only `[ -d "$room" ]`. `rm -rf` a room and build another at that path
# (which is what `_mkroom` after a removal does, and what the suite's own tests do between cases)
# wipes `state/keeper.pid` and forks a SECOND keeper — while the first, back from its sleep to find
# its directory there again, keeps polling. One leaked forever-process per rebuild, each holding
# its bell fifos open. Measured before the fix: both keepers alive seven seconds after a rebuild,
# and only removing the directory ended them.
#
# The trigger added for that is deliberately narrow, and the narrowness is the hard part: the
# keeper steps down ONLY when the pid file names ANOTHER keeper — a different positive pid. A file
# that is missing, empty or malformed says nothing about another keeper and must NOT stop a healthy
# one (t9g writes `0` into it on purpose, and the instant between a rebuild's `mkdir` and its
# keeper's pid being written has the same shape). Reading either as "stop" would leave a room with
# no keeper, which silently loses every bell rung at it — worse than the leak.
#
#   A  the issue's literal scenario: rm -rf then rebuild leaves exactly one keeper
#   B  the same with NO directory gap, so only the pid file can end the first keeper
#   C  missing / empty / `0` / malformed never stop a healthy keeper
#   D  a superseded `--hold` keeper steps down and reaps NOTHING
#   E  the rule holds for a dead pid too, and a replacement survives its predecessor's claim
#   F  removing the directory still ends the keeper, unchanged
#   G  superseded DURING the canary read, the EOF must not reap either (+ a reaping control)
#   H  the clear in `_keeper_ensure`, on the schedule that needs it
#
# No real agent consoles: ct_kill is faked so a reap leaves a marker (the t16/t15/t13 argument — a
# harness must not depend on a live backend). t16 case A is the end-to-end control that an owner
# death DOES reap; G2 is the same control at this file's own level, so D and G1 asserting a
# negative against that fake cannot pass because the fake never fires.
#
# Needs bash >= 5 for what IT and up.sh use ({fd} redirections, $BASHPID, `read -t`). Stock macOS
# starts scripts under bash 3.2, so re-exec into a modern bash — the guard council.sh and t16 use.
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ] && [ -z "${T19_BASH_REEXEC:-}" ]; then
  for _c in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash bash; do
    _p=$(command -v "$_c" 2>/dev/null) || continue
    _v=$("$_p" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null) || continue
    [ "${_v:-0}" -ge 5 ] && exec env T19_BASH_REEXEC=1 "$_p" "$0" "$@"
  done
  echo "t19: needs bash >= 5, this one is ${BASH_VERSION:-unknown}." >&2
  exit 70
fi

set -uo pipefail
export LC_ALL=C
SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
[ -f "$SKILL/lib/up.sh" ] || { echo "t19: cannot find up.sh under $SKILL" >&2; exit 1; }

ROOT=$(mktemp -d) || exit 1
KEEPERS=()   # every keeper we spawn, reaped in the trap: they detach and reparent, so nothing
OWNERS=()    # else would. Owners block on `wait`, so a failed case could leave one running too.
cleanup() {
  local p
  for p in ${OWNERS[@]+"${OWNERS[@]}"};  do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done
  for p in ${KEEPERS[@]+"${KEEPERS[@]}"}; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done
  rm -rf "$ROOT"
}
trap cleanup EXIT

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}
# Poll for a pid to be gone, up to <deciseconds>. The keeper polls every five seconds, so a
# step-down needs a ceiling comfortably past that. t16 uses 80-100 for the same waits; 120 is
# strictly more generous, and `wait_gone` self-stretches under load because each turn forks a
# `sleep`, so the headroom grows on exactly the loaded box that would need it.
#
# BOTH refuse an empty pid, and that is load-bearing rather than defensive. `kill -0 ""` is an
# error, but the tempting `"${pid:-0}"` spelling turns a missing capture into `kill -0 0`, which
# addresses the caller's own process group and SUCCEEDS — so an assertion that no keeper exists
# would read `alive` and pass. That is the same `0` footgun `_keeper_pid`'s header in the file
# under test spends three paragraphs on, and it would have made cases C, E2 and F green against a
# build that started no keeper at all. Empty is not a live process: say so loudly.
no_pid() { echo "no-pid"; }
wait_gone() { local p="$1" n="${2:-120}" i; [ -n "$p" ] || { no_pid; return; }; for ((i=0;i<n;i++)); do kill -0 "$p" 2>/dev/null || { echo gone; return; }; sleep 0.1; done; echo alive; }
wait_file() { local f="$1" n="${2:-60}" i; for ((i=0;i<n;i++)); do [ -e "$f" ] && { echo yes; return; }; sleep 0.1; done; echo no; }
alive()     { [ -n "$1" ] || { no_pid; return; }; kill -0 "$1" 2>/dev/null && echo alive || echo gone; }

# The pid reader, duplicated here rather than taken from lib/up.sh ON PURPOSE — `_keeper_pid` is
# one of the things this file asserts about, and a harness whose reading depends on the code under
# test being correct is not a test of that code (_helpers.sh makes the same argument for
# kill_keeper). Ten digits at most, so `$(( ))` cannot wrap into somebody else's live pid.
read_pid() { # <pid-file> -> a positive integer, or nothing and rc 1
  local v=""
  [ -s "$1" ] || return 1
  read -r v < "$1" 2>/dev/null
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#v}" -le 10 ] || return 1
  v=$((10#$v)); [ "$v" -gt 0 ] || return 1
  printf '%s' "$v"
}

# Build a room (no terminals, no canary) in a subshell and print its keeper's pid. The subshell
# exits; the keeper detaches and reparents, exactly as a real detached room's does.
mkroom() { # <room> <peer>... -> keeper pid on stdout
  local room="$1"; shift
  ( SKILL="$SKILL"; . "$SKILL/lib/up.sh"; _mkroom "$room" "$@" ) >/dev/null 2>&1
  read_pid "$room/state/keeper.pid"
}
# Run `_keeper_ensure` again on an existing room, as `relaunch` does. Prints the new keeper's pid.
ensure() { # <room> <peer>... -> keeper pid on stdout
  local room="$1"; shift
  ( SKILL="$SKILL"; . "$SKILL/lib/up.sh"; _keeper_ensure "$room" "$@" ) >/dev/null 2>&1
  read_pid "$room/state/keeper.pid"
}
track() { [ -n "${1:-}" ] && KEEPERS+=("$1"); return 0; }

# ---------------------------------------------------------------------------------------------
echo "── case A: a room rebuilt at the same path leaves exactly one keeper ──"
# The issue's literal scenario, end to end: `rm -rf` then build again at the same path.
ROOM_A="$ROOT/room-a"
k1=$(mkroom "$ROOM_A" a b); track "$k1"
ok "first keeper started" alive "$(alive "$k1")"
rm -rf "$ROOM_A"
k2=$(mkroom "$ROOM_A" a b); track "$k2"
ok "the rebuild started a different keeper" yes "$([ -n "$k2" ] && [ "$k2" != "$k1" ] && echo yes || echo no)"
# Deliberately NOT `ok … "$k2" "$(read_pid <file>)"`: `mkroom` returns `read_pid` of that very
# file, so comparing the two compares the file with itself and holds even when it names nothing.
# Ask instead for the property that matters — the room's claim points at a process that is running.
ok "the rebuilt room's pid file names a LIVE keeper" alive "$(alive "$(read_pid "$ROOM_A/state/keeper.pid")")"
ok "the old keeper stepped down" gone "$(wait_gone "$k1" 120)"
ok "the new keeper is still keeping the room" alive "$(alive "$k2")"

# ---------------------------------------------------------------------------------------------
echo "── case B: the step-down is the PID FILE, not the directory (no gap to race) ──"
# Case A removes the directory for an instant, so a pass there could in principle come from the
# OLD trigger — a keeper that happened to poll inside the gap. This case leaves the directory in
# place throughout and reproduces the rest of a rebuild: the pid file is cleared and a second
# keeper claims it. Nothing but the pid file can end the first one here, so the check has teeth
# that do not depend on timing.
ROOM_B="$ROOT/room-b"
b1=$(mkroom "$ROOM_B" a b); track "$b1"
ok "first keeper started" alive "$(alive "$b1")"
rm -f "$ROOM_B/state/keeper.pid"          # `_keeper_ensure` would otherwise see b1 alive and return
b2=$(ensure "$ROOM_B" a b); track "$b2"
ok "a second keeper claimed the room" yes "$([ -n "$b2" ] && [ "$b2" != "$b1" ] && echo yes || echo no)"
ok "the room directory never went away" yes "$([ -d "$ROOM_B" ] && echo yes || echo no)"
ok "the superseded keeper stepped down" gone "$(wait_gone "$b1" 120)"
ok "the claiming keeper is still there" alive "$(alive "$b2")"

# ---------------------------------------------------------------------------------------------
echo "── case C: a missing, empty, '0' or malformed pid file does NOT stop a healthy keeper ──"
# The narrowness of the trigger, and the half that is easy to get wrong: each of these says nothing
# about another keeper. `0` is t9g's deliberate case; the empty and missing shapes are what a
# rebuild looks like for the instant before its keeper's pid is written. All five run in parallel
# against one wait, which has to outlast a poll interval to mean anything.
#
# Be exact about what the fifth room controls for, because these are assert-ALIVE rows and every
# one of them also passes with the step-down deleted outright: it is cases A, B, D and E1 that
# prove the check is live, not this case. What `self` NAMES is a check that reads the wrong
# process — `$$` in place of `$BASHPID` is the forking shell, not the keeper. It is not the only
# row that would catch that: at birth every room's pid file names its own keeper, so such a slip
# kills every keeper immediately and reds most of this file, case C's other four rows included.
# `self` is where the mistake is written down, not a unique detector of it.
declare -A C_ROOMS=()
c_shapes=(missing empty zero malformed self)
for s in "${c_shapes[@]}"; do
  C_ROOMS[$s]=$(mkroom "$ROOT/room-c-$s" a b); track "${C_ROOMS[$s]}"
  ok "room-c-$s came up with a keeper" alive "$(alive "${C_ROOMS[$s]}")"
done
rm -f  "$ROOT/room-c-missing/state/keeper.pid"
: >    "$ROOT/room-c-empty/state/keeper.pid"
printf '0'   > "$ROOT/room-c-zero/state/keeper.pid"
printf 'abc' > "$ROOT/room-c-malformed/state/keeper.pid"
# room-c-self is left exactly as `_keeper_ensure` wrote it.
sleep 7                                   # longer than the five-second poll, so every keeper looked
for s in "${c_shapes[@]}"; do
  ok "a '$s' pid file left the keeper running" alive "$(alive "${C_ROOMS[$s]}")"
done

# ---------------------------------------------------------------------------------------------
echo "── case D: a superseded --hold keeper reaps NOTHING ──"
# The destructive mistake this must not make. A `--hold` keeper reaps every participant terminal
# when its owner dies (t16 case A). Stepping down is the opposite situation: the room at this path
# now belongs to the keeper that superseded us, and `ct_kill` resolves ITS terminals from $ROOM —
# so a reap here would close the new room's terminals, turning a leaked process into a room torn
# down under its owner.
#
# Both of the OTHER triggers are ruled out here, so a step-down can only be the pid file. The
# directory is asserted present throughout. And the owner blocks in `wait` on the keeper, which is
# its only child — so it holds the canary write end for the keeper's entire life and the read
# cannot EOF before the keeper is already gone. (That same `wait` is why the owner is not checked
# for liveness afterwards: it returns the moment the keeper exits, and a direct child that has
# exited is a zombie `kill -0` still reports as alive.)
MARK_D="$ROOT/D"; mkdir -p "$MARK_D"; ROOM_D="$ROOT/room-d"
OWNER="$ROOT/owner.sh"
cat > "$OWNER" <<'OWNER_EOF'
#!/usr/bin/env bash
set -uo pipefail; export LC_ALL=C
SKILL="$1"; ROOM="$2"; MARK="$3"; shift 3; PEERS=("$@")
. "$SKILL/lib/up.sh"
ct_kill() { : > "$MARK/reaped-$1"; }        # no real backend — record the close
_KEEPER_OWNER_HOLD=1
_mkroom "$ROOM" "${PEERS[@]}" || exit 1
unset _KEEPER_OWNER_HOLD
printf '%s' "$(_keeper_pid "$ROOM/state/keeper.pid" || true)" > "$MARK/keeper.pid"
printf 'up\n' > "$MARK/ready"
wait                                        # hold the canary write end open until killed
OWNER_EOF
"$BASH" "$OWNER" "$SKILL" "$ROOM_D" "$MARK_D" a b &
d_owner=$!; OWNERS+=("$d_owner")
ok "the --hold owner came up" yes "$(wait_file "$MARK_D/ready" 100)"
d1=$(cat "$MARK_D/keeper.pid" 2>/dev/null); track "$d1"
ok "the --hold keeper started" alive "$(alive "$d1")"
rm -f "$ROOM_D/state/keeper.pid"
d2=$(ensure "$ROOM_D" a b); track "$d2"
ok "a second keeper claimed the room" yes "$([ -n "$d2" ] && [ "$d2" != "$d1" ] && echo yes || echo no)"
ok "the room directory never went away" yes "$([ -d "$ROOM_D" ] && echo yes || echo no)"
ok "the superseded --hold keeper stepped down" gone "$(wait_gone "$d1" 120)"
ok "it reaped no terminal on the way out" no \
   "$(if [ -e "$MARK_D/reaped-a" ] || [ -e "$MARK_D/reaped-b" ]; then echo yes; else echo no; fi)"
kill -9 "$d_owner" 2>/dev/null

# ---------------------------------------------------------------------------------------------
echo "── case E: a stale pid file does not kill the keeper started to replace it ──"
# `relaunch` after `down` is exactly this: `down` kills the keeper and leaves its pid on disk, then
# `_keeper_ensure` starts a replacement — the path that function's header says it exists to serve.
# The pid there is DEAD, but the rule is "a different positive pid", not "a live one" (a keeper
# cannot ask whether another process is a keeper, and `kill -0` also fails on EPERM). E1 pins that
# rule directly; E2 then pins that `_keeper_ensure` clears the stale claim before forking, without
# which the rule would make every replacement keeper step down on its predecessor's pid.
ROOM_E="$ROOT/room-e"
e1=$(mkroom "$ROOM_E" a b); track "$e1"
kill "$e1" 2>/dev/null
ok "the old keeper is dead, its pid still on disk" gone "$(wait_gone "$e1" 60)"
ok "the pid file still names it" "$e1" "$(read_pid "$ROOM_E/state/keeper.pid")"

# E1: drive _keeper_loop itself, so what is measured is the rule and not a fork race. The file
# names a different, DEAD pid; the loop must return rather than keep the room. Its return is
# observed through a MARKER and not through `kill -0`: this subshell is a direct child of the test
# shell, so once it exits it is a zombie until reaped — and `kill -0` on a zombie SUCCEEDS, which
# would read as "still keeping the room" forever. Every other process here is a keeper forked
# inside a subshell that then exited, so it reparents and `kill -0` tells the truth about it.
E1_DONE="$ROOT/e1.stepped-down"
( SKILL="$SKILL"; . "$SKILL/lib/up.sh"
  _keeper_loop "$ROOM_E" "$ROOM_E/state/keeper.pid" "" a b; printf 'yes' > "$E1_DONE" ) >/dev/null 2>&1 &
e_loop=$!; track "$e_loop"
ok "a loop whose file names another pid steps down, dead or not" yes "$(wait_file "$E1_DONE" 60)"
# Kill BEFORE reaping, and never `wait` on it bare. On the failure path the loop is still polling a
# room whose directory is right there, so a bare `wait` blocks forever: the run records the FAIL,
# then hangs — no summary, no EXIT trap, keepers and $ROOT left behind — until run-all.sh's ceiling
# group-kills it ten minutes later, and only if timeout(1) is installed, which stock macOS lacks.
# Measured on a build with the step-down removed. A signal first turns that into a six-second red.
# On the success path the pid is an unreaped child, so the kill is a harmless no-op.
kill "$e_loop" 2>/dev/null; wait "$e_loop" 2>/dev/null

# E2: the real replacement path, end to end — `_keeper_ensure` over a stale pid file must leave a
# keeper that is still there a poll later.
#
# Be clear about what this does and does not catch, because a check believed to have teeth it does
# not have is worse than no check. It pins the OUTCOME of the documented `relaunch`-after-`down`
# path on the ordinary schedule, where the parent rewrites the pid file long before the newborn
# first reads it — so it passes with or without the `rm -f "$keep"` that makes that safe (measured).
# CASE H is the one that pins the clear, by forcing the other schedule.
declare -A E_ROOMS=()
for i in 1 2 3; do
  p=$(mkroom "$ROOT/room-e2-$i" a b); track "$p"
  kill "$p" 2>/dev/null; wait_gone "$p" 60 >/dev/null
  E_ROOMS[$i]=$(ensure "$ROOT/room-e2-$i" a b); track "${E_ROOMS[$i]}"
  # Against `$p`, the predecessor captured before the kill — not against the pid file, which is
  # where `ensure` read this value from and would therefore always agree with it.
  ok "replacement $i took the claim off its dead predecessor" yes \
     "$([ -n "${E_ROOMS[$i]}" ] && [ "${E_ROOMS[$i]}" != "$p" ] && echo yes || echo no)"
done
sleep 7                                   # past a poll, so a newborn that read the stale pid is gone
for i in 1 2 3; do
  ok "replacement $i survived its predecessor's stale pid" alive "$(alive "${E_ROOMS[$i]}")"
done

# ---------------------------------------------------------------------------------------------
echo "── case F: removing the room directory still ends the keeper (unchanged) ──"
# The historical trigger, and normal teardown. t16 case C pins it for a detached room too; it is
# repeated here because this file is what would break it.
ROOM_F="$ROOT/room-f"
f1=$(mkroom "$ROOM_F" a b); track "$f1"
ok "keeper started" alive "$(alive "$f1")"
rm -rf "$ROOM_F"
ok "keeper exits when the room directory is removed" gone "$(wait_gone "$f1" 120)"

# ---------------------------------------------------------------------------------------------
echo "── case G: superseded DURING the canary read, the EOF must not reap either ──"
# Case D supersedes a `--hold` keeper and lets it notice at the top of the loop. This is the other
# schedule, and the one the top-of-body guard cannot reach: the keeper is already blocked inside
# `read -t 5` when it is superseded, so it arrives at the EOF branch with the reap armed and the
# room no longer its own. Reaping there would close the SUCCESSOR's terminals.
#
# Driven at `_keeper_loop` directly with a canary this test owns, because the ordering has to be
# exact rather than likely: the loop announces it is running, then we change the pid file and drop
# the only writer, both inside the five seconds its read is blocked. G2 is the control — same
# mechanism, pid file left naming the loop itself — and it must still REAP, so a pass in G1 cannot
# come from a reap path that is simply broken.
canary_eof() { # <mark-dir> <pid-file-content: "self"|a pid> <n> -> prints reaped|clean
  local mark="$1" who="$2" cr cw boot d f room="$ROOT/room-g-$3"
  # `_keeper_loop` needs only the directory and the pid path — it opens no bell fifo itself (that
  # is `_keeper_ensure`'s subshell) — so build the room by hand and fork no keeper but the one
  # under test.
  mkdir -p "$mark" "$room/state"
  d=$(mktemp -d); f="$d/.canary"; mkfifo "$f"
  exec {boot}<>"$f"; exec {cr}<"$f"; exec {cw}>"$f"; exec {boot}>&-; rm -f "$f"; rmdir "$d" 2>/dev/null
  ( exec {cw}>&-                                          # THE fd that decides this test: the loop
    # inherits every fd open here, and a copy of the WRITE end in the loop's own process would keep
    # the pipe's write side open forever, so dropping the test's copy below would never EOF and the
    # control case would poll for good. `_keeper_ensure` closes it for the same reason (t16 case D).
    SKILL="$SKILL"; . "$SKILL/lib/up.sh"
    ct_kill() { : > "$mark/reaped-$1"; }
    printf '%s' "$BASHPID" > "$room/state/keeper.pid"     # at entry the room is ours
    printf 'in\n' > "$mark/running"
    _keeper_loop "$room" "$room/state/keeper.pid" "$cr" a b
    printf 'yes' > "$mark/returned" ) >/dev/null 2>&1 &
  local lp=$! ret
  # Deliberately NOT `track "$lp"`. `canary_eof` is only ever called inside `$( )`, so the append
  # would land in the command substitution's own copy of KEEPERS and never reach the EXIT trap —
  # a registration that reads as a safety net while being none, which is worse than no net. What
  # actually reaps this child is the bounded wait and the `kill` below, on both paths.
  wait_file "$mark/running" 60 >/dev/null
  [ "$who" = self ] || printf '%s' "$who" > "$room/state/keeper.pid"   # superseded mid-read
  exec {cw}>&-                                            # the owner dies: EOF on the read
  # Bounded, and on a MARKER rather than a bare `wait` — E1 sixty lines up takes the same care and
  # for the same reason: a loop that stops returning would otherwise hang the run to run-all.sh's
  # ceiling instead of reddening. E1's remedy does not transfer verbatim, though. Signalling first
  # would race G2's reap and destroy the control, so the marker is written AFTER `_keeper_loop`
  # returns — by then any ct_kill has already run and the counts below are complete. The child is
  # only signalled once that marker (or the ceiling) says the loop is done with it.
  ret=$(wait_file "$mark/returned" 150)
  kill "$lp" 2>/dev/null; wait "$lp" 2>/dev/null
  exec {cr}<&-
  rm -rf "$room"
  # A loop that never came back is neither outcome, and says so rather than borrowing one.
  [ "$ret" = yes ] || { echo "loop-never-returned"; return; }
  if [ -e "$mark/reaped-a" ] || [ -e "$mark/reaped-b" ]; then echo reaped; else echo clean; fi
}
ok "superseded mid-read, the EOF reaps nothing" clean "$(canary_eof "$ROOT/G1" 999999 1)"
ok "control: not superseded, the EOF still reaps" reaped "$(canary_eof "$ROOT/G2" self 2)"

# ---------------------------------------------------------------------------------------------
echo "── case H: _keeper_ensure clears a stale claim before forking (provoked) ──"
# The window E2 could not reach, opened deliberately. `set` is a regular builtin, so a function of
# that name defined in the caller wins — and on this path only the PARENT runs `set +m`, between
# the fork and the `echo` that rewrites the pid file. Holding it there for two seconds guarantees
# the newborn reads the file first, which is the schedule that decides whether `rm -f "$keep"`
# matters. Without that line the newborn finds its dead predecessor's pid, steps down, and the room
# is left with NO keeper — every bell rung at it lost, in silence.
ROOM_H="$ROOT/room-h"
h0=$(mkroom "$ROOM_H" a b); track "$h0"
kill "$h0" 2>/dev/null                       # `down` kills the keeper and LEAVES its pid on disk
ok "the predecessor is dead, its pid still on disk" gone "$(wait_gone "$h0" 60)"
ok "the stale claim is there to be misread" "$h0" "$(read_pid "$ROOM_H/state/keeper.pid")"
( SKILL="$SKILL"; . "$SKILL/lib/up.sh"
  set() { command sleep 2; builtin set "$@"; }
  _keeper_ensure "$ROOM_H" a b ) >/dev/null 2>&1
h1=$(read_pid "$ROOM_H/state/keeper.pid"); track "$h1"
ok "a replacement was forked and claimed the room" yes \
   "$([ -n "$h1" ] && [ "$h1" != "$h0" ] && echo yes || echo no)"
sleep 6                                      # past a poll: a newborn that read the stale pid is gone
ok "the replacement survived the provoked window" alive "$(alive "$h1")"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then echo "t19 PASS ($CHECKS checks)"; else echo "t19 FAIL ($FAILURES/$CHECKS)"; exit 1; fi
