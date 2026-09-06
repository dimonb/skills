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
# no keeper, which silently loses every bell rung at it — worse than the leak. Cases C and E pin
# both edges; A and B pin the step-down itself.
#
# No real agent consoles: ct_kill is faked so a reap leaves a marker (the t16/t15/t13 argument — a
# harness must not depend on a live backend). The positive control for the reap path — an owner
# death DOES reap — is t16 case A; case D here asserts only that a SUPERSEDED keeper does not.
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
# step-down needs a ceiling comfortably past that.
wait_gone() { local p="$1" n="${2:-120}" i; for ((i=0;i<n;i++)); do kill -0 "$p" 2>/dev/null || { echo gone; return; }; sleep 0.1; done; echo alive; }
wait_file() { local f="$1" n="${2:-60}" i; for ((i=0;i<n;i++)); do [ -e "$f" ] && { echo yes; return; }; sleep 0.1; done; echo no; }
alive()     { kill -0 "$1" 2>/dev/null && echo alive || echo gone; }

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
ok "first keeper started" alive "$(alive "${k1:-0}")"
rm -rf "$ROOM_A"
k2=$(mkroom "$ROOM_A" a b); track "$k2"
ok "the rebuild started a different keeper" yes "$([ -n "$k2" ] && [ "$k2" != "$k1" ] && echo yes || echo no)"
ok "the rebuilt room's pid file names the new keeper" "$k2" "$(read_pid "$ROOM_A/state/keeper.pid")"
ok "the old keeper stepped down" gone "$(wait_gone "$k1" 120)"
ok "the new keeper is still keeping the room" alive "$(alive "${k2:-0}")"

# ---------------------------------------------------------------------------------------------
echo "── case B: the step-down is the PID FILE, not the directory (no gap to race) ──"
# Case A removes the directory for an instant, so a pass there could in principle come from the
# OLD trigger — a keeper that happened to poll inside the gap. This case leaves the directory in
# place throughout and reproduces the rest of a rebuild: the pid file is cleared and a second
# keeper claims it. Nothing but the pid file can end the first one here, so the check has teeth
# that do not depend on timing.
ROOM_B="$ROOT/room-b"
b1=$(mkroom "$ROOM_B" a b); track "$b1"
ok "first keeper started" alive "$(alive "${b1:-0}")"
rm -f "$ROOM_B/state/keeper.pid"          # `_keeper_ensure` would otherwise see b1 alive and return
b2=$(ensure "$ROOM_B" a b); track "$b2"
ok "a second keeper claimed the room" yes "$([ -n "$b2" ] && [ "$b2" != "$b1" ] && echo yes || echo no)"
ok "the room directory never went away" yes "$([ -d "$ROOM_B" ] && echo yes || echo no)"
ok "the superseded keeper stepped down" gone "$(wait_gone "$b1" 120)"
ok "the claiming keeper is still there" alive "$(alive "${b2:-0}")"

# ---------------------------------------------------------------------------------------------
echo "── case C: a missing, empty, '0' or malformed pid file does NOT stop a healthy keeper ──"
# The narrowness of the trigger, and the half that is easy to get wrong: each of these says nothing
# about another keeper. `0` is t9g's deliberate case; the empty and missing shapes are what a
# rebuild looks like for the instant before its keeper's pid is written. The fifth room is the
# positive control — a file naming the keeper ITSELF must not stop it either, so a pass here cannot
# come from the check being dead. All five run in parallel against one wait, which has to outlast a
# poll interval to mean anything.
declare -A C_ROOMS=()
c_shapes=(missing empty zero malformed self)
for s in "${c_shapes[@]}"; do
  C_ROOMS[$s]=$(mkroom "$ROOT/room-c-$s" a b); track "${C_ROOMS[$s]}"
  ok "room-c-$s came up with a keeper" alive "$(alive "${C_ROOMS[$s]:-0}")"
done
rm -f  "$ROOT/room-c-missing/state/keeper.pid"
: >    "$ROOT/room-c-empty/state/keeper.pid"
printf '0'   > "$ROOT/room-c-zero/state/keeper.pid"
printf 'abc' > "$ROOT/room-c-malformed/state/keeper.pid"
# room-c-self is left exactly as `_keeper_ensure` wrote it.
sleep 7                                   # longer than the five-second poll, so every keeper looked
for s in "${c_shapes[@]}"; do
  ok "a '$s' pid file left the keeper running" alive "$(alive "${C_ROOMS[$s]:-0}")"
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
ok "the --hold keeper started" alive "$(alive "${d1:-0}")"
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
wait "$e_loop" 2>/dev/null

# E2: the real replacement path, end to end — `_keeper_ensure` over a stale pid file must leave a
# keeper that is still there a poll later.
#
# Be clear about what this does and does not catch, because a check believed to have teeth it does
# not have is worse than no check. It pins the OUTCOME of the documented `relaunch`-after-`down`
# path. It does NOT reproduce the race that `rm -f "$keep"` closes: the parent's remaining work
# after the fork is three statements and no fork of its own, while the newborn must open every bell
# fifo and then fork a command substitution before its first read — so the parent wins essentially
# always, and this case passes even against a build with the clear removed (measured). The clear is
# kept on the ARGUMENT, not on this evidence: E1 above shows any name that is not the newborn's is
# a step-down, so on the one scheduling in which the newborn does read first the room is left with
# no keeper at all and silently loses every bell. Cheap guard, unbounded failure.
declare -A E_ROOMS=()
for i in 1 2 3; do
  p=$(mkroom "$ROOT/room-e2-$i" a b); track "$p"
  kill "$p" 2>/dev/null; wait_gone "$p" 60 >/dev/null
  E_ROOMS[$i]=$(ensure "$ROOT/room-e2-$i" a b); track "${E_ROOMS[$i]}"
  ok "replacement $i is named in the pid file" "${E_ROOMS[$i]}" "$(read_pid "$ROOT/room-e2-$i/state/keeper.pid")"
done
sleep 7                                   # past a poll, so a newborn that read the stale pid is gone
for i in 1 2 3; do
  ok "replacement $i survived its predecessor's stale pid" alive "$(alive "${E_ROOMS[$i]:-0}")"
done

# ---------------------------------------------------------------------------------------------
echo "── case F: removing the room directory still ends the keeper (unchanged) ──"
# The historical trigger, and normal teardown. t16 case C pins it for a detached room too; it is
# repeated here because this file is what would break it.
ROOM_F="$ROOT/room-f"
f1=$(mkroom "$ROOM_F" a b); track "$f1"
ok "keeper started" alive "$(alive "${f1:-0}")"
rm -rf "$ROOM_F"
ok "keeper exits when the room directory is removed" gone "$(wait_gone "$f1" 120)"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then echo "t19 PASS ($CHECKS checks)"; else echo "t19 FAIL ($FAILURES/$CHECKS)"; exit 1; fi
