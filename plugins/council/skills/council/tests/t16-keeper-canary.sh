#!/usr/bin/env bash
# t16 — the keeper reaps on OWNER DEATH (the canary fd + `up --hold`), issue #88.
#
# The room keeper used to die on exactly one trigger: its room DIRECTORY going away (an explicit
# `down`, or `--purge`). Nothing tied it to a live owner, so an abandoned `--hold`-style room left
# an immortal keeper polling forever with its bell fifos held open. This proves the added trigger:
# a `--hold` room's owner holds the write end of a canary pipe, the keeper inherits the read end,
# and the owner's death — for ANY reason, SIGKILL included — is seen as EOF, on which the keeper
# closes every participant terminal and exits. No real agent consoles: ct_kill is faked to record
# which peers were closed (the t15/t13 argument — a harness must not depend on a live backend).
#
# The driver's baseline interpreter is bash >= 5 (read -t, {fd} redirections, EPOCHREALTIME). Stock
# macOS starts scripts under bash 3.2, so re-exec into a modern bash, the guard council.sh uses.
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ] && [ -z "${T16_BASH_REEXEC:-}" ]; then
  for _c in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash bash; do
    _p=$(command -v "$_c" 2>/dev/null) || continue
    _v=$("$_p" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null) || continue
    [ "${_v:-0}" -ge 5 ] && exec env T16_BASH_REEXEC=1 "$_p" "$0" "$@"
  done
  echo "t16: needs bash >= 5, this one is ${BASH_VERSION:-unknown}." >&2
  exit 70
fi

set -uo pipefail
export LC_ALL=C
SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
[ -f "$SKILL/lib/up.sh" ] || { echo "t16: cannot find up.sh under $SKILL" >&2; exit 1; }

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
# Poll for a file to appear, up to <deciseconds> tenths of a second. Prints "yes"/"no".
wait_file() { local f="$1" n="${2:-60}" i; for ((i=0;i<n;i++)); do [ -e "$f" ] && { echo yes; return; }; sleep 0.1; done; echo no; }
# Poll for a pid to be gone, up to <deciseconds>. Prints "gone"/"alive".
wait_gone() { local p="$1" n="${2:-60}" i; for ((i=0;i<n;i++)); do kill -0 "$p" 2>/dev/null || { echo gone; return; }; sleep 0.1; done; echo alive; }
pgid_of() { ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '; }

# An owner process: build a room whose keeper carries the canary (`_KEEPER_OWNER_HOLD=1`), fake
# ct_kill so a reap leaves a marker per peer, record the pids/pgids, then hold the write end open
# FORKLESS with `wait` — exactly what `council_up --hold` does at its tail. Killing this process
# closes the write end, which is the owner-death the keeper watches for.
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
kpid=$(_keeper_pid "$ROOM/state/keeper.pid" || true)
printf '%s' "$$"   > "$MARK/owner.pid"
ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ' > "$MARK/owner.pgid"
printf '%s' "$kpid" > "$MARK/keeper.pid"
[ -n "$kpid" ] && ps -o pgid= -p "$kpid" 2>/dev/null | tr -d ' ' > "$MARK/keeper.pgid"
printf 'up\n' > "$MARK/ready"
wait                                        # hold the canary write end open until killed
OWNER_EOF

# ---------------------------------------------------------------------------------------------
echo "── case A: owner SIGKILLed → keeper reaps every terminal and exits ──"
MARK_A="$ROOT/A"; mkdir -p "$MARK_A"; ROOM_A="$ROOT/room-a"
"$BASH" "$OWNER" "$SKILL" "$ROOM_A" "$MARK_A" alice bob &
OWNERS+=("$!")
ok "owner came up" yes "$(wait_file "$MARK_A/ready" 80)"
kpid_a=$(cat "$MARK_A/keeper.pid" 2>/dev/null); opid_a=$(cat "$MARK_A/owner.pid" 2>/dev/null)
[ -n "$kpid_a" ] && KEEPERS+=("$kpid_a")
ok "keeper started" yes "$([ -n "$kpid_a" ] && echo yes || echo no)"
ok "keeper is alive before the kill" yes "$(kill -0 "$kpid_a" 2>/dev/null && echo yes || echo no)"
# It is in its OWN process group — the whole point of `set -m` in _keeper_ensure.
ok "keeper is in its own process group" yes \
   "$([ -n "$(cat "$MARK_A/keeper.pgid" 2>/dev/null)" ] && [ "$(cat "$MARK_A/keeper.pgid")" != "$(cat "$MARK_A/owner.pgid")" ] && echo yes || echo no)"
# No terminal has been closed yet — the owner is still alive.
ok "no reap while the owner lives" no "$([ -e "$MARK_A/reaped-alice" ] && echo yes || echo no)"
kill -9 "$opid_a" 2>/dev/null
ok "keeper exited after owner SIGKILL" gone "$(wait_gone "$kpid_a" 80)"
ok "reaped alice" yes "$(wait_file "$MARK_A/reaped-alice" 5)"
ok "reaped bob"   yes "$(wait_file "$MARK_A/reaped-bob" 5)"

# ---------------------------------------------------------------------------------------------
echo "── case B: a signal to the OWNER's process group does not reach the keeper ──"
# Launch the owner as its OWN group leader (set -m), so a group-directed signal hits the owner
# (and any child in its group) but NOT the keeper, which _keeper_ensure put in a separate group —
# and NOT this test, which is in yet another. That isolation is exactly what lets the keeper
# survive a Ctrl-C / closed-pane signal long enough to see the EOF and reap.
MARK_B="$ROOT/B"; mkdir -p "$MARK_B"; ROOM_B="$ROOT/room-b"
set -m
"$BASH" "$OWNER" "$SKILL" "$ROOM_B" "$MARK_B" x y z &
opid_b=$!
set +m
OWNERS+=("$opid_b")
ok "owner came up (own group)" yes "$(wait_file "$MARK_B/ready" 80)"
kpid_b=$(cat "$MARK_B/keeper.pid" 2>/dev/null); [ -n "$kpid_b" ] && KEEPERS+=("$kpid_b")
opgid_b=$(pgid_of "$opid_b")
ok "owner is its own group leader" "$opid_b" "$opgid_b"
ok "keeper group differs from owner group" yes \
   "$([ -n "$(cat "$MARK_B/keeper.pgid" 2>/dev/null)" ] && [ "$(cat "$MARK_B/keeper.pgid")" != "$opgid_b" ] && echo yes || echo no)"
# Signal the owner's GROUP (negative pid). Safe: the keeper and this test are in other groups.
kill -TERM -- "-$opgid_b" 2>/dev/null
ok "keeper exited after owner-group SIGTERM" gone "$(wait_gone "$kpid_b" 80)"
ok "reaped x" yes "$(wait_file "$MARK_B/reaped-x" 5)"
ok "reaped y" yes "$(wait_file "$MARK_B/reaped-y" 5)"
ok "reaped z" yes "$(wait_file "$MARK_B/reaped-z" 5)"

# ---------------------------------------------------------------------------------------------
echo "── case C: WITHOUT --hold the room is detached, exactly as before ──"
# A starter builds a room with NO canary (no _KEEPER_OWNER_HOLD), records the keeper pid, then
# EXITS. The keeper must outlive it (directory-bound life) and must NOT reap any terminal; only
# removing the room directory ends it — the historical behaviour this change must not disturb.
MARK_C="$ROOT/C"; mkdir -p "$MARK_C"; ROOM_C="$ROOT/room-c"
STARTER="$ROOT/starter.sh"
cat > "$STARTER" <<'START_EOF'
#!/usr/bin/env bash
set -uo pipefail; export LC_ALL=C
SKILL="$1"; ROOM="$2"; MARK="$3"; shift 3; PEERS=("$@")
. "$SKILL/lib/up.sh"
ct_kill() { : > "$MARK/reaped-$1"; }
_mkroom "$ROOM" "${PEERS[@]}" || exit 1     # no _KEEPER_OWNER_HOLD → detached keeper, no canary
_keeper_pid "$ROOM/state/keeper.pid" > "$MARK/keeper.pid" || true
printf 'up\n' > "$MARK/ready"
START_EOF
"$BASH" "$STARTER" "$SKILL" "$ROOM_C" "$MARK_C" p q &
ok "starter came up" yes "$(wait_file "$MARK_C/ready" 80)"
wait "$!" 2>/dev/null                        # the starter EXITS; the keeper is on its own now
kpid_c=$(cat "$MARK_C/keeper.pid" 2>/dev/null); [ -n "$kpid_c" ] && KEEPERS+=("$kpid_c")
ok "keeper started" yes "$([ -n "$kpid_c" ] && echo yes || echo no)"
sleep 1
ok "keeper survives the starter's exit" yes "$(kill -0 "$kpid_c" 2>/dev/null && echo yes || echo no)"
ok "detached keeper reaps nothing" no "$([ -e "$MARK_C/reaped-p" ] && echo yes || echo no)"
rm -rf "$ROOM_C"                              # the directory-bound death trigger, unchanged
ok "keeper exits when the room directory is removed" gone "$(wait_gone "$kpid_c" 90)"

# ---------------------------------------------------------------------------------------------
echo "── case E: a launched backend daemon does not inherit the canary write end ──"
# The bug this guards: a backend that cold-starts a DAEMON (the tmux server, on first use) has
# that daemon inherit every fd open in the owner shell — so if it retained the canary WRITE end
# the keeper would NEVER see owner death (measured on tmux 3.x: the read never EOFs). council_up
# launches through _ct_launch_owned, which closes that fd for the launch. Model the daemon with a
# `sleep` that holds its inherited fds — a faithful stand-in for "a launched process that keeps
# its fds open" — and ask whether the owner's write end is the ONLY writer left after the launch:
# if it is, dropping it EOFs the read; if the daemon kept a copy, the read times out. The control
# (no guard) exhibits the very leak the guard removes, so the check has teeth.
canary_probe() { # <expose-wfd:1|0> <pidfile> -> prints eof|timeout|data
  . "$SKILL/lib/up.sh"
  local expose="$1" pidfile="$2" cr cw boot rc r d f
  d=$(mktemp -d); f="$d/.canary"; mkfifo "$f"
  exec {boot}<>"$f"; exec {cr}<"$f"; exec {cw}>"$f"; exec {boot}>&-; rm -f "$f"; rmdir "$d" 2>/dev/null
  ct_launch() { sleep 30 & echo "$!" >> "$pidfile"; return 0; }   # faked daemonizing backend
  if [ "$expose" = 1 ]; then _KEEPER_CANARY_WFD="$cw"; else unset _KEEPER_CANARY_WFD; fi
  _ct_launch_owned peerA /tmp /dev/null
  exec {cw}>&-                       # owner death: drop the only intended writer
  if read -t 3 -u "$cr" _ 2>/dev/null; then r=data; else rc=$?; if [ "$rc" -le 128 ]; then r=eof; else r=timeout; fi; fi
  exec {cr}<&-
  printf '%s' "$r"
}
PIDS_E="$ROOT/E.pids"; : > "$PIDS_E"
fix_r=$(canary_probe 1 "$PIDS_E")
ctl_r=$(canary_probe 0 "$PIDS_E")
for _d in $(cat "$PIDS_E" 2>/dev/null); do kill "$_d" 2>/dev/null; done   # reap the faked daemons
ok "with the guard, a launched daemon does not hold the canary open (owner death => EOF)" eof "$fix_r"
ok "control: WITHOUT the guard the daemon does hold it (owner death => timeout)" timeout "$ctl_r"

# ---------------------------------------------------------------------------------------------
echo "── case D: no owner-liveness path reads \$PPID (acceptance) ──"
# Strip comments first: the canary comments MENTION $PPID to explain why the mechanism does not
# use it, and a naive grep would flag exactly the lines that promise its absence. What must be
# zero is $PPID in the CODE — reading a reparented process's parent tells you nothing on macOS.
ok "up.sh code (comments stripped) reads no PPID" 0 "$(sed 's/#.*//' "$SKILL/lib/up.sh" | grep -c 'PPID')"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then echo "t16 PASS ($CHECKS checks)"; else echo "t16 FAIL ($FAILURES/$CHECKS)"; exit 1; fi
