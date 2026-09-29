#!/usr/bin/env bash
# t-canary — seeing an owner's death on a FIFO canary (shared/canary/canary.sh).
#
# What this owns: the module's own answers, over a real FIFO, in one process — a held canary reads
# alive, an owner's close reads gone, a stray byte is not a death, a signalled sentinel is replaced
# rather than read as a death, the no-canary path is a plain wait, and `canary_sentinel_stop` ends
# the sentinel it started and nothing else.
#
# WHAT IS NOT COVERED, so a green run is never read as more than it is: the macOS select edge this
# module exists for (#275, #279). It is a timing race at roughly one run in fifty to one in four
# hundred, measured with instrumented loops recorded on the changes that found it, and it cannot
# happen at all on a platform without the edge, such as the Linux runner CI uses. A revert to a
# plain `read -t` on the canary passes this file. The call sites are asserted where they live:
# shipyard's t10-continuity-canary.sh and council's t16-keeper-canary.sh.
#
# Needs bash >= 4.4 for what the module uses; stock macOS starts scripts under bash 3.2, so re-exec
# into a modern bash, the guard the council suites use.
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ] && [ -z "${TCANARY_BASH_REEXEC:-}" ]; then
  for _c in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash bash; do
    _p=$(command -v "$_c" 2>/dev/null) || continue
    _v=$("$_p" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null) || continue
    [ "${_v:-0}" -ge 5 ] && exec env TCANARY_BASH_REEXEC=1 "$_p" "$0" "$@"
  done
  echo "t-canary: needs bash >= 5, this one is ${BASH_VERSION:-unknown}." >&2
  exit 70
fi
set -uo pipefail
export LC_ALL=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$DIR/../canary.sh"
[ -f "$MOD" ] || { echo "t-canary: cannot find canary.sh at $MOD" >&2; exit 1; }
# shellcheck source=../canary.sh
. "$MOD"

ROOT=$(mktemp -d) || exit 1

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}
alive() { kill -0 "$1" 2>/dev/null && echo alive || echo gone; }
# Poll for a pid to be gone, up to <deciseconds>.
wait_gone() { local p="$1" n="${2:-50}" i; for ((i=0;i<n;i++)); do kill -0 "$p" 2>/dev/null || { echo gone; return; }; sleep 0.1; done; echo alive; }

# A canary as both callers hold one: THIS shell has only the read end, and the write end is held by
# another process, the "owner", whose death is the thing to see. The owner must be another process,
# not a second fd here: a sentinel inherits every fd open in the shell that starts it, so a write
# end held here would make the sentinel a writer too, and no owner death could ever EOF the read —
# the trap both callers close their write end to avoid. Sets CR, OWNER and CPATH; the path is kept
# so a case can open a short-lived writer of its own AFTER the sentinel has started.
mkcanary() {
  local boot
  CPATH="$ROOT/canary.$1"
  mkfifo "$CPATH" || return 1
  exec {boot}<>"$CPATH" && exec {CR}<"$CPATH" || return 1
  ( exec {boot}>&- {CR}<&-; exec 3>"$CPATH"; : >"$CPATH.ready"; exec sleep 600 ) &
  OWNER=$!
  # The bootstrap is this shell's only writer; drop it once the owner's own write end is open.
  local i; for ((i=0;i<50;i++)); do [ -e "$CPATH.ready" ] && break; sleep 0.1; done
  [ -e "$CPATH.ready" ] || return 1
  exec {boot}>&-
}
owner_die() { kill -9 "$OWNER" 2>/dev/null; wait "$OWNER" 2>/dev/null; }
trap 'kill -9 "${OWNER:-}" 2>/dev/null; rm -rf "$ROOT"' EXIT

echo "── the owner holds the canary ──"
CANARY_SENTINEL_FD=""; CANARY_SENTINEL_PID=""
mkcanary a || { echo "t-canary FAIL: could not build a canary"; exit 1; }
canary_owner_gone "$CR" 0.2; rc=$?
ok "a held canary reads as the owner alive" 0    "$rc"
ok "...having started a sentinel"           yes  "$([ -n "$CANARY_SENTINEL_FD" ] && echo yes || echo no)"
ok "...whose pid it recorded"               yes  "$(case "$CANARY_SENTINEL_PID" in ''|*[!0-9]*) echo no ;; *) echo yes ;; esac)"
spid=$CANARY_SENTINEL_PID
ok "...and which is running"                alive "$(alive "$spid")"

echo "── a stray byte is not a death ──"
# A writer of this case's own, opened only now: the sentinel is already running, so it did not
# inherit it, and the owner stays the canary's one lasting writer.
exec {W2}>"$CPATH"; printf 'x\n' >&"$W2"; exec {W2}>&-
canary_owner_gone "$CR" 0.2; rc=$?
ok "a byte on the canary reads alive"       0    "$rc"
ok "...keeping the same sentinel"           "$spid" "$CANARY_SENTINEL_PID"

echo "── the owner dies ──"
owner_die
start=$SECONDS
canary_owner_gone "$CR" 5; rc=$?
ok "every writer gone reads as the owner gone" 1 "$rc"
# At once, not an interval late: the call was given five seconds and must not have used them.
ok "...at once, not after the interval"     yes  "$([ $((SECONDS - start)) -lt 3 ] && echo yes || echo no)"
ok "...forgetting a pid that has exited"    ""   "$CANARY_SENTINEL_PID"
ok "...and the sentinel is gone"            gone "$(wait_gone "$spid")"
canary_sentinel_stop
ok "stop after a death just closes the pipe" "" "$CANARY_SENTINEL_FD"
exec {CR}<&-; rm -f "$CPATH" "$CPATH.ready"

echo "── a signalled sentinel is replaced, not read as a death ──"
CANARY_SENTINEL_FD=""; CANARY_SENTINEL_PID=""
mkcanary b || { echo "t-canary FAIL: could not build a canary"; exit 1; }
canary_owner_gone "$CR" 0.1 >/dev/null; spid=$CANARY_SENTINEL_PID
kill -TERM "$spid" 2>/dev/null
ok "the sentinel was signalled"             gone "$(wait_gone "$spid")"
canary_owner_gone "$CR" 0.2; rc=$?
ok "its pipe ending without a line reads alive" 0 "$rc"
ok "...dropping the dead sentinel"          ""   "$CANARY_SENTINEL_FD"
canary_owner_gone "$CR" 0.2; rc=$?
ok "the next call starts a new sentinel"    yes  "$([ -n "$CANARY_SENTINEL_PID" ] && [ "$CANARY_SENTINEL_PID" != "$spid" ] && echo yes || echo no)"
ok "...and still reads the owner alive"     0    "$rc"

echo "── canary_sentinel_stop ends the sentinel while the owner lives ──"
spid=$CANARY_SENTINEL_PID
canary_sentinel_stop
ok "the sentinel is gone"                   gone "$(wait_gone "$spid")"
ok "...with its fd and pid cleared"         "/" "$CANARY_SENTINEL_FD/$CANARY_SENTINEL_PID"
ok "...and the owner untouched"             alive "$(alive "$OWNER")"
owner_die; exec {CR}<&-
# It signals only the pid it recorded, and never a value `kill` would widen: 0 is the caller's whole
# process group, and a leading-zero pid such as 01 is pid 1. `kill` is replaced by a recorder for
# this probe, in a subshell, so nothing is signalled whatever the guard does, and a value that got
# through shows up as the arguments it would have been handed.
refused=$( kill() { printf '%s;' "$*"; }
  for v in 0 01 00 1 -1 '' x12 '12 34'; do CANARY_SENTINEL_PID=$v; canary_sentinel_stop; done )
ok "a pid kill would widen is refused, not signalled" "" "$refused"
passed=$( kill() { printf '%s;' "$*"; }; CANARY_SENTINEL_PID=4242; canary_sentinel_stop )
ok "...while a plain pid is signalled"      "-TERM 4242;" "$passed"

echo "── no canary: a plain wait ──"
start=$SECONDS
canary_owner_gone "" 1; rc=$?
ok "no canary fd reads as keep looping"     0    "$rc"
ok "...after sleeping the interval"         yes  "$([ $((SECONDS - start)) -ge 1 ] && echo yes || echo no)"

echo "── nothing here reads \$PPID ──"
# Both callers decide an owner's death from canary EOF and never from a reparented process's
# parent, which reads as alive. Comments stripped, since the header explains that absence.
ok "the module (comments stripped) reads no PPID" 0 "$(sed 's/#.*//' "$MOD" | grep -c 'PPID')"

printf '\nt-canary: %s checks, %s\n' "$CHECKS" \
  "$([ "$FAILURES" = 0 ] && echo 'all passed' || echo "$FAILURES FAILED")"
[ "$FAILURES" = 0 ]
