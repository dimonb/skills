#!/usr/bin/env bash
# t10 — the continuity watcher reaps on OWNER DEATH (canary fd + process group), issue #90.
#
# The detached (nohup) continuity watcher used to outlive its launcher unconditionally: nothing
# tied it to a live owner, so if the parent shipyard session died WITHOUT a clean teardown the
# watcher was reparented to launchd and polled on. This proves the added, OPT-IN trigger
# (_SHIPYARD_CONTINUITY_OWNER_HOLD): a caller holds the write end of a canary pipe, the watcher
# inherits the read end IN ITS OWN PROCESS GROUP, and the caller's death — for ANY reason, SIGKILL
# included — is seen as EOF, on which the watcher reaps itself and exits. No real Codex parent and
# no real agterm: a fake `agtermctl` keeps the watched session "present" so the ONLY thing that ends
# the watcher is the canary. This is the shipyard-side mirror of council's t16 (issue #89).
#
# NOTE ON SCOPE: shipyard's own launchers are transient and never arm this — the production
# owner-death path is the agterm-session mode (untouched here). This test drives the owner-hold
# mechanism with a FAKED long-lived owner, exactly as the issue's acceptance asks.
#
# Needs bash >= 5 for what IT uses: `read -t` with a fractional timeout, {fd} redirections, and
# `exec {var}>&-` (close the fd whose NUMBER is that variable's value). Stock macOS starts scripts
# under bash 3.2, so re-exec into a modern bash — the same guard council's t16 uses.
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ] && [ -z "${T10_BASH_REEXEC:-}" ]; then
  for _c in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash bash; do
    _p=$(command -v "$_c" 2>/dev/null) || continue
    _v=$("$_p" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null) || continue
    [ "${_v:-0}" -ge 5 ] && exec env T10_BASH_REEXEC=1 "$_p" "$0" "$@"
  done
  echo "t10: needs bash >= 5, this one is ${BASH_VERSION:-unknown}." >&2
  exit 70
fi

set -uo pipefail
export LC_ALL=C
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
[ -f "$SKILL_DIR/shipyard-continuity.sh" ] || { echo "t10: cannot find shipyard-continuity.sh under $SKILL_DIR" >&2; exit 1; }

ROOT=$(mktemp -d) || exit 1
WATCHERS=()   # every watcher we spawn: they detach and reparent, so the trap reaps them
OWNERS=()     # owners block on `wait`; a failed case could leave one running too
DAEMONS="$ROOT/daemons.pids"; : > "$DAEMONS"   # case C's faked-daemon sleeps record their pids here
cleanup() {
  local p
  for p in ${OWNERS[@]+"${OWNERS[@]}"};   do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done
  for p in ${WATCHERS[@]+"${WATCHERS[@]}"}; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done
  [ -f "$DAEMONS" ] && while read -r p; do [ -n "$p" ] && kill -9 "$p" 2>/dev/null; done < "$DAEMONS"
  rm -rf "$ROOT"
}
trap cleanup EXIT

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}
wait_file() { local f="$1" n="${2:-60}" i; for ((i=0;i<n;i++)); do [ -e "$f" ] && { echo yes; return; }; sleep 0.1; done; echo no; }
wait_gone() { local p="$1" n="${2:-60}" i; for ((i=0;i<n;i++)); do kill -0 "$p" 2>/dev/null || { echo gone; return; }; sleep 0.1; done; echo alive; }
# The owner-death reap (owner killed -> canary write end closes -> watcher's read EOFs -> it reaps
# and exits) is GUARANTEED to happen; the only question is when, and under concurrent load (a full
# `make test`, CI) the detached watcher can be scheduled late. So the canary-reap waits use a
# generous bound: it still fails on a genuine never-reap (a leaked watcher runs forever), it just
# gives scheduling jitter ample headroom instead of a tight 12s window that flaked under load.
REAP_WAIT=600   # 60s at 0.1s/poll — generous, not a real deadline; a true leak still fails it
pgid_of() { ps -o pgid= -p "$1" 2>/dev/null | tr -d ' '; }

# A fake `agtermctl` that keeps the watched session PRESENT with a benign, action-free screen, so
# the real watcher loops forever on its inter-poll canary wait and the canary is the only thing that
# can end it. (`command -v jq` uses the real jq; the watcher pipes this JSON through it.)
FAKEBIN="$ROOT/bin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/agtermctl" <<'FAKE_EOF'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "session text")
    printf '%s\n' '{"ok":true,"result":{"text":"› Ask Codex to do anything"}}' ;;
  "tree "*|"tree")
    printf '%s\n' '{"ok":true,"result":{"tree":{"idleMs":9999,"workspaces":[{"name":"w","sessions":[{"id":"t10-parent","name":"n"}]}]}}}' ;;
  *) : ;;
esac
exit 0
FAKE_EOF
chmod +x "$FAKEBIN/agtermctl"

# An owner process: arm the owner-hold canary and start the REAL detached watcher through the real
# `shipyard_continuity_start` (nohup launch mode), record the pids/pgids, then hold the canary write
# end open FORKLESS with `wait` — exactly what a long-lived owner would do. Killing this process
# closes the write end, which is the owner-death the watcher watches for.
OWNER="$ROOT/owner.sh"
cat > "$OWNER" <<'OWNER_EOF'
#!/usr/bin/env bash
set -uo pipefail; export LC_ALL=C
SKILL_DIR="$1"; STATE="$2"; MARK="$3"; FAKEBIN="$4"
. "$SKILL_DIR/shipyard-continuity.sh"
export PATH="$FAKEBIN:$PATH"
export _SHIPYARD_CONTINUITY_DIR="$STATE"
export _SHIPYARD_CONTINUITY_LAUNCH_MODE=nohup
export _SHIPYARD_CONTINUITY_OWNER_HOLD=1
export _SHIPYARD_CONTINUITY_POLL_SECS=0.1
export _SHIPYARD_CONTINUITY_STALE_SECS=60
export CODEX_SESSION_ID=t10-thread AGTERM_ENABLED=1
export AGTERM_SESSION_ID=t10-parent AGTERM_SOCKET=t10-sock AGTERM_WINDOW_ID=t10-win AGTERM_PANE=primary
if ! shipyard_continuity_start agterm >>"$MARK/start.log" 2>&1; then
  printf 'start-failed\n' > "$MARK/error"; exit 1
fi
pidfile=$(find "$STATE" -name 'continuity-*.pid' -print -quit)
wpid=$(awk '{print $1}' "$pidfile" 2>/dev/null)
printf '%s' "$$"   > "$MARK/owner.pid"
ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ' > "$MARK/owner.pgid"
printf '%s' "$wpid" > "$MARK/watcher.pid"
[ -n "$wpid" ] && ps -o pgid= -p "$wpid" 2>/dev/null | tr -d ' ' > "$MARK/watcher.pgid"
printf 'up\n' > "$MARK/ready"
wait   # hold the canary write end open until killed
OWNER_EOF

# ---------------------------------------------------------------------------------------------
echo "── case A: owner SIGKILLed → the detached watcher reaps itself and exits ──"
MARK_A="$ROOT/A"; mkdir -p "$MARK_A"; STATE_A="$ROOT/state-a"; mkdir -p "$STATE_A"
"$BASH" "$OWNER" "$SKILL_DIR" "$STATE_A" "$MARK_A" "$FAKEBIN" &
OWNERS+=("$!")
ok "owner came up" yes "$(wait_file "$MARK_A/ready" 120)"
[ -f "$MARK_A/error" ] && sed -n '1,60p' "$MARK_A/start.log"
wpid_a=$(cat "$MARK_A/watcher.pid" 2>/dev/null); opid_a=$(cat "$MARK_A/owner.pid" 2>/dev/null)
[ -n "$wpid_a" ] && WATCHERS+=("$wpid_a")
ok "watcher started" yes "$([ -n "$wpid_a" ] && echo yes || echo no)"
ok "watcher is alive before the kill" yes "$(kill -0 "$wpid_a" 2>/dev/null && echo yes || echo no)"
ok "watcher is in its own process group" yes \
   "$([ -n "$(cat "$MARK_A/watcher.pgid" 2>/dev/null)" ] && [ "$(cat "$MARK_A/watcher.pgid")" != "$(cat "$MARK_A/owner.pgid")" ] && echo yes || echo no)"
kill -9 "$opid_a" 2>/dev/null
ok "watcher exited after owner SIGKILL" gone "$(wait_gone "$wpid_a" "$REAP_WAIT")"
ok "no watcher state left behind" "" "$(find "$STATE_A" -mindepth 1 ! -name continuity-generation -print 2>/dev/null)"

# ---------------------------------------------------------------------------------------------
echo "── case B: a signal to the OWNER's process group does not directly reach the watcher ──"
# Launch the owner as its OWN group leader (set -m). A group-directed signal then hits the owner
# but NOT the watcher, which start_owner_hold_locked put in a separate group — so the watcher's
# death must come from the canary EOF, proving the isolation that lets it survive a Ctrl-C / closed
# pane long enough to reap.
MARK_B="$ROOT/B"; mkdir -p "$MARK_B"; STATE_B="$ROOT/state-b"; mkdir -p "$STATE_B"
set -m
"$BASH" "$OWNER" "$SKILL_DIR" "$STATE_B" "$MARK_B" "$FAKEBIN" &
opid_b=$!
set +m
OWNERS+=("$opid_b")
ok "owner came up (own group)" yes "$(wait_file "$MARK_B/ready" 120)"
wpid_b=$(cat "$MARK_B/watcher.pid" 2>/dev/null); [ -n "$wpid_b" ] && WATCHERS+=("$wpid_b")
opgid_b=$(pgid_of "$opid_b")
ok "owner is its own group leader" "$opid_b" "$opgid_b"
ok "watcher group differs from owner group" yes \
   "$([ -n "$(cat "$MARK_B/watcher.pgid" 2>/dev/null)" ] && [ "$(cat "$MARK_B/watcher.pgid")" != "$opgid_b" ] && echo yes || echo no)"
kill -TERM -- "-$opgid_b" 2>/dev/null
ok "watcher exited after owner-group SIGTERM (via EOF, not the group signal)" gone "$(wait_gone "$wpid_b" "$REAP_WAIT")"

# ---------------------------------------------------------------------------------------------
echo "── case C: a launched child must not inherit the canary write end (the #89 footgun) ──"
# The bug this guards: the watcher (a launched child of the owner) inheriting the canary WRITE end
# would make it a writer too, so the owner's death would NEVER EOF the read. start_owner_hold_locked
# closes the write end for the launch. Model a launched child with a `sleep` that holds its inherited
# fds and ask whether the owner's write end is the ONLY writer left: if it is, dropping it EOFs the
# read; if the child kept a copy, the read times out. The control (no close) exhibits the very leak
# the fix removes, so the check has teeth.
canary_probe() { # <close-wfd:1|0> <pidfile> -> eof|timeout|data
  local close="$1" pidfile="$2" cr cw boot rc r d f
  d=$(mktemp -d); f="$d/.canary"; mkfifo "$f"
  exec {boot}<>"$f"; exec {cr}<"$f"; exec {cw}>"$f"; exec {boot}>&-; rm -f "$f"; rmdir "$d" 2>/dev/null
  if [ "$close" = 1 ]; then ( exec {cw}>&-; sleep 30 & echo "$!" >> "$pidfile" )   # child WITHOUT the write end
  else                      ( sleep 30 & echo "$!" >> "$pidfile" ); fi             # child WITH the write end (bug)
  exec {cw}>&-                       # owner death: drop the only intended writer
  if read -t 3 -u "$cr" _ 2>/dev/null; then r=data; else rc=$?; if [ "$rc" -le 128 ]; then r=eof; else r=timeout; fi; fi
  exec {cr}<&-
  printf '%s' "$r"
}
fix_r=$(canary_probe 1 "$DAEMONS")
ctl_r=$(canary_probe 0 "$DAEMONS")
for _d in $(cat "$DAEMONS" 2>/dev/null); do kill "$_d" 2>/dev/null; done
ok "with the write end closed for the child, owner death => EOF" eof "$fix_r"
ok "control: a child inheriting the write end => owner death times out" timeout "$ctl_r"

# ---------------------------------------------------------------------------------------------
echo "── case D: shipyard_continuity_terminate_pid reaps the whole group when told to ──"
. "$SKILL_DIR/shipyard-continuity.sh"   # for the function under test, in THIS shell
MARK_D="$ROOT/D"; mkdir -p "$MARK_D"
set -m
( sleep 60 & echo "$!" > "$MARK_D/child.pid"; wait ) &
leader=$!
set +m
ok "group leader came up" yes "$(wait_file "$MARK_D/child.pid" 60)"
child=$(cat "$MARK_D/child.pid" 2>/dev/null); [ -n "$child" ] && DAEMONS_D="$child"
ok "leader is its own group leader" "$leader" "$(pgid_of "$leader")"
shipyard_continuity_terminate_pid "$leader" 1 >/dev/null 2>&1 || true
ok "the group leader is reaped" gone "$(wait_gone "$leader" 60)"
ok "the group child is reaped too" gone "$(wait_gone "$child" 60)"

set -m
( sleep 60 & echo "$!" > "$MARK_D/child2.pid"; wait ) &
leader2=$!
set +m
ok "control leader came up" yes "$(wait_file "$MARK_D/child2.pid" 60)"
child2=$(cat "$MARK_D/child2.pid" 2>/dev/null)
shipyard_continuity_terminate_pid "$leader2" >/dev/null 2>&1 || true
ok "without the group flag the leader is still reaped" gone "$(wait_gone "$leader2" 60)"
ok "control: without the group flag a child survives" alive "$(wait_gone "$child2" 5)"
[ -n "${child2:-}" ] && kill -9 "$child2" 2>/dev/null

# ---------------------------------------------------------------------------------------------
echo "── case E: no owner-death reaping path reads \$PPID (acceptance) ──"
# $PPID stays legitimately in shipyard_continuity_set_current_pid (the lifecycle-LOCK owner probe,
# out of scope for #90). What must be zero is $PPID in the OWNER-DEATH REAPING path: the watch loop,
# its canary helpers, and the owner-hold launch — all of which decide reaping from canary EOF, never
# from a reparented process's parent. Strip comments first, or a comment EXPLAINING the absence of
# $PPID would be flagged as its presence.
reap_src=$(sed -n \
  -e '/^shipyard_continuity_watch() {/,/^}/p' \
  -e '/^shipyard_continuity_owner_gone() {/,/^}/p' \
  -e '/^shipyard_continuity_reap_group() {/,/^}/p' \
  -e '/^shipyard_continuity_start_owner_hold_locked() {/,/^}/p' \
  "$SKILL_DIR/shipyard-continuity.sh")
ok "the reaping path was actually extracted" yes "$([ -n "$reap_src" ] && echo yes || echo no)"
ok "reaping path (comments stripped) reads no PPID" 0 \
   "$(printf '%s\n' "$reap_src" | sed 's/#.*//' | grep -c 'PPID')"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then echo "t10 PASS ($CHECKS checks)"; else echo "t10 FAIL ($FAILURES/$CHECKS)"; exit 1; fi
