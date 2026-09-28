#!/usr/bin/env bash
# t31 — a bell rung at a room with no live keeper leaks nothing, and loses no message (#209).
#
# `c_ring` is a detached writer. It used to open the peer's fifo WRITE-ONLY, which blocks in open(2)
# until some process holds a read end. The keeper holds every bell for the life of a room, so in a
# healthy room that returned at once; in a room with no live keeper and the peer not in `recv`, the
# writer parked in open(2) for good, holding every fd it inherited — including a caller's `$( )`
# pipe, so a captured ringing verb never returned. It now opens the fifo read-write, which does not
# block. This file pins the three things that change rests on:
#
#   A. nothing is left parked: no writer is waiting on the fifo, and none is still running;
#   B. the dropped wake-up costs no message: the peer's next `recv` still reads it, at once;
#   C. the one ring path that creates a regular file (a fifo removed between the `[ -p ]` gate and
#      the open) hangs nothing either — `recv` refuses that file and polls.
#
# Needs bash >= 5 for `$EPOCHREALTIME` and `{fd}` redirections. Stock macOS starts scripts under
# bash 3.2, so re-exec into a modern one, the same guard t26 and t19 use.
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ] && [ -z "${T31_BASH_REEXEC:-}" ]; then
  for _c in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash bash; do
    _p=$(command -v "$_c" 2>/dev/null) || continue
    _v=$("$_p" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null) || continue
    [ "${_v:-0}" -ge 5 ] && exec env T31_BASH_REEXEC=1 "$_p" "$0" "$@"
  done
  echo "t31: needs bash >= 5, this one is ${BASH_VERSION:-unknown}." >&2
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
wait_file() { local f="$1" n="${2:-50}" i; for ((i=0;i<n;i++)); do [ -e "$f" ] && { echo yes; return; }; sleep 0.1; done; echo no; }
wait_gone() { local p="$1" n="${2:-50}" i; for ((i=0;i<n;i++)); do kill -0 "$p" 2>/dev/null || { echo gone; return; }; sleep 0.1; done; echo alive; }
ms() { local t=${EPOCHREALTIME/./}; echo $(( 10#$t / 1000 )); }
# Processes whose command line carries <token>: the ringing verb and every writer it forked, since
# a forked subshell keeps its parent's argv. Filtered with awk over `ps -A`, never `pgrep`, which
# AGENTS.md says why.
count_token() { ps -A -o command= 2>/dev/null | awk -v t="$1" 'index($0, t) && !/awk/ {n++} END {print n + 0}'; }
# Release any writer parked in open(2) on <fifo> by opening a read end, and say whether one was:
# a parked writer completes its open the moment a reader exists and writes its byte. Bounded, and
# it is also the cleanup — a writer left parked would outlive this file by days.
drain_parked() { # <fifo> -> "parked" or "none"
  local r got=none
  exec {r}<>"$1" || { echo none; return; }
  read -r -t 0.5 -N 1 -u "$r" _ 2>/dev/null && got=parked
  while read -r -t 0.2 -N 1 -u "$r" _ 2>/dev/null; do :; done
  exec {r}<&-
  echo "$got"
}

# ================================================================================================
echo "--- A. a ring at a keeperless room leaves no writer behind ---"
RA="$COUNCIL_TEST_ROOT/t31a"
mkroom "$RA" a b
export COUNCIL_ROOM="$RA" ROOM="$RA"
echo "Does a ring leak?" > "$RA/agenda.md"
KA=$(read -r v _ < "$RA/state/keeper.pid"; echo "$v")
kill_keeper "$RA/state/keeper.pid"
ok "the keeper is gone before the ring" gone "$(wait_gone "$KA" 50)"
# b is not in `recv`, so with the keeper gone nothing holds b's bell — ONCE THE KEEPER'S `sleep`
# HAS GONE TOO. That child inherited every bell fd and outlives the keeper by up to one poll
# period; t26 case F records the same orphan making a keeperless fixture pass on a leaked fd. So
# wait out three periods before ringing. Measured: without this wait the case stays green against
# the old write-only ring, which is the mutation it exists to catch.
keeper_orphans_gone() { sleep "$(awk -v p="${COUNCIL_KEEPER_POLL_INTERVAL:-5}" 'BEGIN { print p * 3 }')"; }
keeper_orphans_gone
TOKA="t31-ring-$$-a"
DONEA="$COUNCIL_TEST_ROOT/t31a.done"
# The ringing verb, CAPTURED — the capture is what never returned while a writer was parked, since
# the writer inherits the substitution's pipe. Backgrounded under a watchdog so a regression reds
# this line in seconds instead of hanging the file until the runner's ceiling.
( out=$(COUNCIL_ROOM="$RA" COUNCIL_ME=a bash "$CLI" send --act msg --refs '[]' "$TOKA"); rc=$?
  printf '%s %s\n' "$rc" "${out:+printed}" > "$DONEA" ) &
RINGER=$!
ok "a captured ringing verb returns" yes "$(wait_file "$DONEA" 50)"
ok "...having sent the message (a holds the opening floor)" 0 "$(cut -d' ' -f1 "$DONEA" 2>/dev/null)"
sleep 0.3   # let a detached writer that is going to exit, exit
ok "no process of that ring is still alive" 0 "$(count_token "$TOKA")"
ok "...and none is parked on the peer's fifo" none "$(drain_parked "$RA/bell/b.fifo")"
kill "$RINGER" 2>/dev/null; wait "$RINGER" 2>/dev/null

# ================================================================================================
echo "--- B. the wake-up that was dropped costs no message ---"
# The byte case A rang had nobody to hold it, so it is gone. The bell only WAKES a `recv`, and
# `recv` drains the lanes before its first wait — so b's next `recv` must return the message at
# once, not after a bell-wait interval and not at its timeout.
t0=$(ms)
outb=$(COUNCIL_ROOM="$RA" COUNCIL_ME=b bash "$CLI" recv --timeout 5 2>/dev/null); rc=$?
t1=$(ms)
ok "b's next recv returns the message" 0 "$rc"
ok "...which is the one rung for" yes "$(grep -q -- "$TOKA" <<<"$outb" && echo yes || echo no)"
# 2 s is far above a drain and far below the 5 s timeout, so the bound tells the two apart.
ok "...without waiting for its timeout" yes "$([ $((t1 - t0)) -lt 2000 ] && echo yes || echo "no ($((t1 - t0)) ms)")"

# ================================================================================================
echo "--- C. a fifo removed between the gate and the open hangs nothing ---"
# `1<>` creates a regular file at a missing path, as the old `>` did. `c_ring`'s `[ -p ]` gate
# returns before that for a missing bell; the only way to land there is the fifo vanishing in the
# instant after the gate. That instant is built here, deterministically, by shadowing `[` with a
# function that removes the fifo right after answering the gate's own question — the code under
# test is not touched.
RC="$COUNCIL_TEST_ROOT/t31c"
mkroom "$RC" a b
kill_keeper "$RC/state/keeper.pid"
keeper_orphans_gone
DONEC="$COUNCIL_TEST_ROOT/t31c.done"
( export COUNCIL_ROOM="$RC"
  . "$SKILL/lib/lib.sh"
  [() { builtin [ "$@"; local r=$?
        if builtin [ "$1" = -p ] && builtin [ "$r" = 0 ]; then rm -f "$2"; fi
        return "$r"; }
  c_ring b
  : > "$DONEC" ) &
RINGC=$!
ok "the ring returns" yes "$(wait_file "$DONEC" 50)"
sleep 0.2
ok "...and leaves a regular file where the fifo was" yes \
   "$([ -f "$RC/bell/b.fifo" ] && [ ! -p "$RC/bell/b.fifo" ] && echo yes || echo no)"
errc="$COUNCIL_TEST_ROOT/t31c.err"
t0=$(ms)
COUNCIL_ROOM="$RC" COUNCIL_ME=b bash "$CLI" recv --timeout 1 >/dev/null 2>"$errc"; rc=$?
t1=$(ms)
ok "recv over that file says it is polling instead" yes "$(grep -q 'not a fifo' "$errc" && echo yes || echo no)"
ok "...and returns at its timeout rather than hanging" yes "$([ $((t1 - t0)) -lt 4000 ] && echo yes || echo "no ($((t1 - t0)) ms)")"
kill "$RINGC" 2>/dev/null; wait "$RINGC" 2>/dev/null

printf '\nt31-ring-keeperless: %s checks, %s failed\n' "$CHECKS" "$FAILURES"
[ "$FAILURES" = 0 ]
