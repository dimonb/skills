#!/usr/bin/env bash
# t21-continuity-fifo.sh — a FIFO planted in the continuity state dir cannot hang its writers (#256).
#
# The state dir defaults to the shared mailbox (`.git/ship-escalations/`), which every child can
# write. `shipyard-continuity.sh` used to open its files there with a plain `>` or `>>`, and a FIFO
# in place of one blocks that open for as long as nothing reads it. The worst was the stopping
# marker: a fixed name, written while `stop_all` holds the lifecycle lock, so the stopping parent
# wedged inside the lock and every later start or stop wedged behind it. t20 is the same defect on
# the report, ask, answer and tell writers; this file borrows its `bounded` rig. The driver's
# container pin, the fourth writer #256 names, is covered in shared/driver's t-driver.
#
# Each case plants a FIFO where a writer writes, runs the call under a bound, and asserts that it
# RETURNED and still did what it is for.
#
# NOT COVERED, named so a green run is not read as more:
#   * the start intent's own name: it carries the starter's pid, $RANDOM and the epoch, so a test
#     cannot plant at it before the write without racing it. Case 2 drives the helper the intent is
#     now written through, which is the same code path.
#   * the residual shared/policy names for policy_mailbox_write: a random temp name swapped for a
#     FIFO between `mktemp` and the shell's open of it. No fixture hits that on purpose.
#   * the owner probe's `sh -c 'printf … >"$1"'`, onto a name `mktemp` just made: that same residual.
#
# MUTATION CHECK, run by hand when this file changes: put back `>"$marker"` in stop_all or the
# `<path>.<token>.tmp.$$` temp in write_record, and that site's case reports HUNG. Put back the old
# nohup launch (`>>"$logfile"`, no temp) or `>>"${12}"` in the watch-foreground dispatch, and case 3
# or 4 reports a failed start instead: the WATCHER blocks on the log, and the starter gives up on it
# after its publication polls rather than hanging with it. A mutation that keeps the new rename and
# only restores the append stays green, because the rename has already replaced the FIFO.
set -uo pipefail
export LC_ALL=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$DIR/.." && pwd)"

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/t21-continuity-fifo.XXXXXXXX") || exit 1
STATE="$TMP/state"; mkdir -p "$STATE" "$TMP/bin"
export _SHIPYARD_CONTINUITY_DIR="$STATE"

# shellcheck source=../shipyard-continuity.sh
. "$SKILL_DIR/shipyard-continuity.sh"

FIFOS=()
plant() { rm -rf "$1"; mkfifo "$1" && FIFOS+=("$1"); } # <path>
unplant() {
  local f
  if [ "${#FIFOS[@]}" -gt 0 ]; then
    for f in "${FIFOS[@]}"; do [ -p "$f" ] && { : <>"$f"; rm -f "$f"; }; done
  fi
  FIFOS=()
}
trap 'unplant; shipyard_continuity_stop_all >/dev/null 2>&1; rm -rf "$TMP"' EXIT

# bounded <secs> <cmd>... — t20's: the command's output then `rc=<n>`, or `HUNG` when it had not
# returned within <secs>; a hung opener is released by opening every planted FIFO read-write once.
BOUND_OUT="$TMP/bounded.out"
bounded() {
  local secs="$1" pid i=0 f; shift
  "$@" >"$BOUND_OUT" 2>&1 & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge $(( secs * 10 )) ]; then
      kill "$pid" 2>/dev/null
      if [ "${#FIFOS[@]}" -gt 0 ]; then
        for f in "${FIFOS[@]}"; do [ -p "$f" ] && : <>"$f"; done
      fi
      wait "$pid" 2>/dev/null
      printf 'HUNG'
      return 0
    fi
    sleep 0.1; i=$((i + 1))
  done
  wait "$pid"; i=$?
  cat "$BOUND_OUT"; printf '\nrc=%s' "$i"
}
returned() { case "$1" in *HUNG) printf no ;; *) printf yes ;; esac; }
rc_of() { case "$1" in *HUNG) printf HUNG ;; *) printf '%s' "${1##*rc=}" ;; esac; }
regular() { [ -f "$1" ] && [ ! -p "$1" ] && printf yes || printf no; }
leftover() { ls -A "$STATE" | grep -c '\.tmp\.\|continuity-log\.' ; }
SECS=20

# A fake agtermctl just capable enough for a watcher to start and stay healthy: `session new` runs
# the command in the background, and every read fails, which the watcher tolerates (it heartbeats
# before it reads). FAKE_PLANT, when set, is a path `session new` replaces with a FIFO first — that
# is the window between the starter creating the log and the watcher opening it.
cat >"$TMP/bin/agtermctl" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "session new" ]; then
  shift 2
  command=""
  while [ "$#" -gt 0 ]; do
    case "$1" in --command) command="$2"; shift 2 ;; *) shift ;; esac
  done
  [ -n "$command" ] || exit 1
  if [ -n "${FAKE_PLANT:-}" ]; then rm -f "$FAKE_PLANT"; mkfifo "$FAKE_PLANT"; fi
  nohup /bin/bash -c "$command" </dev/null >/dev/null 2>&1 &
  printf '%s\n' guard-session
  exit 0
fi
[ "${1:-} ${2:-}" = "session close" ] && exit 0
exit 1
EOF
chmod +x "$TMP/bin/agtermctl"
PATH="$TMP/bin:$PATH"
CODEX_SESSION_ID=t21-codex AGTERM_ENABLED=1 AGTERM_SESSION_ID=t21-session
AGTERM_SOCKET="$TMP/socket" AGTERM_WINDOW_ID=t21-window AGTERM_PANE=primary
_SHIPYARD_CONTINUITY_POLL_SECS=0.05
export PATH CODEX_SESSION_ID AGTERM_ENABLED AGTERM_SESSION_ID AGTERM_SOCKET AGTERM_WINDOW_ID
export AGTERM_PANE _SHIPYARD_CONTINUITY_POLL_SECS
LOG="$STATE/continuity-t21-session.log"
PIDFILE="$STATE/continuity-t21-session.pid"

# --- 1. stop_all: the fixed-name stopping marker, written under the lifecycle lock ---------------
printf '\n── stop_all marker ──\n'
plant "$STATE/continuity-stopping"
o=$(bounded "$SECS" shipyard_continuity_stop_all)
ok "a FIFO at continuity-stopping: stop_all returns"  yes "$(returned "$o")"
ok "...with success"                                  0 "$(rc_of "$o")"
ok "...removing the marker"                           no "$([ -e "$STATE/continuity-stopping" ] && echo yes || echo no)"
ok "...and releasing the lifecycle lock"              no "$([ -L "$STATE/continuity-lifecycle.lock" ] && echo yes || echo no)"
unplant
o=$(bounded "$SECS" shipyard_continuity_stop_all)
ok "a stop after it is not wedged behind the lock"    0 "$(rc_of "$o")"

# --- 2. write_record: the old predictable temp name, and the target itself ----------------------
printf '\n── write_record ──\n'
# `$$` inside a backgrounded function is still this shell's pid, so the old temp name is exactly
# what a child reading the token and the pid out of the mailbox could plant.
plant "$STATE/continuity-rec.tok.tmp.$$"
o=$(bounded "$SECS" shipyard_continuity_write_record "$STATE/continuity-rec" tok "a value")
ok "a FIFO at the old temp name: write_record returns" yes "$(returned "$o")"
ok "...and writes the record"                          "tok a value" "$(cat "$STATE/continuity-rec" 2>/dev/null)"
unplant
plant "$STATE/continuity-rec"
o=$(bounded "$SECS" shipyard_continuity_write_record "$STATE/continuity-rec" tok "again")
ok "a FIFO at the record itself: write_record returns" yes "$(returned "$o")"
ok "...and the record is a regular file again"         yes "$(regular "$STATE/continuity-rec")"
ok "...leaving no temp file behind"                    0 "$(leftover)"
unplant
rm -f "$STATE/continuity-rec"

# --- 3. the watcher log, nohup launch: the starter's truncate and the watcher's appends ----------
printf '\n── watcher log (nohup) ──\n'
plant "$LOG"
o=$(_SHIPYARD_CONTINUITY_LAUNCH_MODE=nohup bounded "$SECS" shipyard_continuity_start agterm)
ok "a FIFO at the watcher log: start returns"  yes "$(returned "$o")"
ok "...with success"                           0 "$(rc_of "$o")"
ok "...and the log is a regular file again"    yes "$(regular "$LOG")"
pid=$(awk '{print $1}' "$PIDFILE" 2>/dev/null)
ok "...and the watcher is running"             yes "$([ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo yes || echo no)"
unplant
o=$(bounded "$SECS" shipyard_continuity_stop_all)
ok "...and stops cleanly"                      0 "$(rc_of "$o")"
ok "...leaving no temp file behind"            0 "$(leftover)"

# --- 4. the watcher log, agterm-session launch: the foreground watcher's own open ---------------
printf '\n── watcher log (agterm session) ──\n'
o=$(FAKE_PLANT="$LOG" bounded "$SECS" shipyard_continuity_start agterm)
FIFOS+=("$LOG")   # planted by the fake, so the bound's release must know it
ok "a FIFO at the log after the starter made it: start returns" yes "$(returned "$o")"
ok "...with success, the watcher having started"                0 "$(rc_of "$o")"
ok "...and the log is a regular file again"                     yes "$(regular "$LOG")"
unplant
o=$(bounded "$SECS" shipyard_continuity_stop_all)
ok "...and stops cleanly"                                       0 "$(rc_of "$o")"
ok "...leaving no temp file behind"                             0 "$(leftover)"

if [ "$FAILURES" -eq 0 ]; then printf 't21-continuity-fifo: %d checks, all passed\n' "$CHECKS"; exit 0; fi
printf 't21-continuity-fifo: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"; exit 1
