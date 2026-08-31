#!/usr/bin/env bash
# t9g — room values that are read in a way which assumes they are well-formed, and the LOUD
# behaviour that replaced each quiet one. t9b covers a lane message and t9c the room's numeric
# files; these are neither a message nor a number reaching arithmetic.
#
#   state/keeper.pid -> `kill`   a `0` there means "every process in the sender's process
#                                group", which is the supervisor's session, not the room. And
#                                `kill -0 0` SUCCEEDS, so the reader that checks whether a
#                                keeper is alive believes one is, never starts a real keeper,
#                                and every bell in the room is silently lost.
#   bell/<me>.fifo   -> `exec`   `exec 3<>` succeeds on a regular file, and the read that
#                                follows returns at EOF instead of sleeping — so recv spins
#                                for its whole timeout instead of waiting.
#   the room's state -> `decide` both of decide's reads degrade to EMPTY rather than to an
#                                error, and every renderer treats empty as "nothing to say".
#                                The record — the room's one durable output — was written at
#                                rc 0 with a blank verdict and "(there were no objections)".
#   a peer's sent_ms -> STALL    the floor's age comes from the holder's own clock, so one
#                                message stamped in 1970 raised a stall of half a century on
#                                the ONE alarm a supervisor is told to act on.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
R="$COUNCIL_TEST_ROOT/t9g-degrades-loudly"; rm -rf "$R"
export COUNCIL_ROOM="$R" ROOM="$R"
fail=0

fresh() { rm -rf "$R"; mkroom "$R" a b; echo "Does the room fail loudly?" > "$R/agenda.md"; }

# --- 1. the pid gate itself -----------------------------------------------------
# A table, because the whole point is that `kill` can only ever be handed a positive integer.
# `0` is the one that signals a process group; the rest are ordinary ways a pid file goes bad
# — an interrupted start, a copied room, a hand-edited file. The ten-digit ceiling is about
# the arithmetic rather than about plausibility: past it `$(( ))` wraps a 64-bit integer and
# can land on somebody else's live pid.
fresh
pidgate() { # <file-content> <expected: the pid, or empty>
  printf '%s' "$1" > "$R/state/probe.pid"
  local got
  got=$( SKILL="$SKILL"; . "$SKILL/lib/up.sh"; _keeper_pid "$R/state/probe.pid" )
  if [ "$got" = "$2" ]; then echo "ok   pid file '$1' -> '${got:-(nothing)}'"
  else echo "FAIL pid file '$1' -> '$got', wanted '${2:-(nothing)}'"; fail=1; fi
}
pidgate '0'                     ''
pidgate ''                      ''
pidgate '-1'                    ''
pidgate 'abc'                   ''
pidgate '12 34'                 ''
pidgate '99999999999999999999'  ''
pidgate '4321'                  '4321'
pidgate '010'                   '10'

# --- 2. a `0` pid file must not pass for a live keeper --------------------------
# `_keeper_ensure` is idempotent by design and `relaunch` leans on that: `down` kills the
# keeper, so a seat brought back up in a torn-down room would otherwise look perfectly healthy
# while every bell rung at it went nowhere. `kill -0 0` returning 0 is exactly that state.
fresh
kill_keeper "$R/state/keeper.pid"
printf '0' > "$R/state/keeper.pid"
( SKILL="$SKILL"; . "$SKILL/lib/up.sh"; _keeper_ensure "$R" a b ) >/dev/null 2>&1
kp=$(cat "$R/state/keeper.pid" 2>/dev/null)
case "$kp" in
  ''|*[!0-9]*|0) echo "FAIL a '0' keeper.pid passed for a live keeper (pid file now '$kp')"; fail=1 ;;
  *) if kill -0 "$kp" 2>/dev/null; then echo "ok   a '0' keeper.pid started a real keeper (pid $kp)"
     else echo "FAIL keeper.pid holds $kp but no such process"; fail=1; fi ;;
esac

# --- 3. tearing a room down must not signal the caller's process group ----------
# The regression this pins would kill the test that is running, so the call is made from a
# background subshell under `set -m`, which puts it in a process group of its own: a `kill 0`
# inside it then reaches only that group, and `wait` reports it as a signal death rather than
# taking the suite with it. A backend name that cannot resolve keeps `council_down`'s terminal
# half inert — nothing here may close a real terminal that happens to be named `a`.
fresh
real=$(cat "$R/state/keeper.pid" 2>/dev/null)
printf '0' > "$R/state/keeper.pid"
set -m
( export COUNCIL_ROOM="$R" COUNCIL_BACKEND=none-for-tests
  SKILL="$SKILL"; ROOM="$R"
  . "$SKILL/lib/up.sh"
  council_down ) >/dev/null 2>&1 &
dpid=$!
wait "$dpid"; drc=$?
set +m
if [ "$drc" = 0 ]; then echo "ok   down over a '0' keeper.pid signalled nothing (rc 0)"
else echo "FAIL down over a '0' keeper.pid died with rc $drc — it signalled its own process group"; fail=1; fi
# Put the real keeper's pid back so the suite's cleanup can still reap it.
[ -n "$real" ] && printf '%s' "$real" > "$R/state/keeper.pid"

# --- 4. a bell that is no longer a fifo polls, it does not spin -----------------
# Nothing repairs a bell: `_mkroom` writes one only where there is no `-p`, and it does not run
# again over a live room. An archive-and-restore, or any copy that does not preserve fifos,
# produces this. The note on stderr is the assertion that the fallback branch was taken; the
# CPU figure corroborates it. Measured over an identical 3-second `recv`, child user/sys:
# 0.038/0.070 with a real fifo, 0.868/1.683 with a regular file in its place, 0.060/0.103 with
# the fallback. The ceiling below is deliberately loose: a loaded box gives a spinning process
# LESS cpu, not more, so a tight bound would be the flaky half of this test rather than the
# sharp one.
fresh
TIMEFORMAT='%3U %3S'
cpu_of_recv() { # -> "user sys" for one 3-second recv as b
  { time COUNCIL_ME=b bash "$CLI" recv --timeout 3 >/dev/null 2>"$R/recv.err"; } 2>&1
}
c1=$(cpu_of_recv)
if grep -q 'not a fifo' "$R/recv.err"; then
  echo "FAIL a real fifo was reported as not a fifo"; fail=1
else
  echo "ok   a real fifo waited on the bell with no complaint (cpu $c1)"
fi
rm -f "$R/bell/b.fifo"; : > "$R/bell/b.fifo"
c2=$(cpu_of_recv)
if grep -q 'not a fifo' "$R/recv.err"; then
  echo "ok   a bell that is not a fifo said so on stderr"
else
  echo "FAIL a bell that is not a fifo was opened silently"; fail=1
fi
spin=$(printf '%s\n' "$c2" | awk '{ print ($1 + $2 > 1.2) ? "yes" : "no" }')
if [ "$spin" = no ]; then echo "ok   a bell that is not a fifo polled instead of spinning (cpu $c2)"
else echo "FAIL a bell that is not a fifo spun for the whole timeout (cpu $c2)"; fail=1; fi

# --- 5. no record is written from a state that could not be computed ------------
# `_graph` is stubbed rather than provoked with a malformed message, and that is the point:
# the guard's contract is "the state could not be read", not "this particular field was of the
# wrong type". Every malformed value fixed elsewhere in this change reached `decide` through
# exactly this door, and the next one will too.
fresh
say_floor propose '[]' "Adopt the thing." >/dev/null
say_floor object '["a-1"]' "This breaks the thing." >/dev/null
( export COUNCIL_ROOM="$R" COUNCIL_ME=a
  SKILL="$SKILL"
  . "$SKILL/lib/lib.sh"
  . "$SKILL/lib/verbs.sh"
  _graph() { return 1; }
  v_decide --force ) >/dev/null 2>&1
vrc=$?
if [ "$vrc" != 0 ] && [ ! -e "$R/board/decision.md" ]; then
  echo "ok   decide refused an uncomputable room and wrote no record (rc $vrc)"
else
  echo "FAIL decide wrote a record from a state it could not compute (rc $vrc)"; fail=1
fi

# --- 6. a room that CAN be computed still gets its record -----------------------
# The guard above must refuse a broken read, not refuse to close a room. Without this the
# whole skill could pass section 5 by never writing a record at all.
COUNCIL_ME=a bash "$CLI" decide --force >/dev/null 2>&1
if grep -q "This breaks the thing" "$R/board/decision.md" 2>/dev/null; then
  echo "ok   an ordinary room still writes a record naming its objection"
else
  echo "FAIL an ordinary room no longer writes a usable record"; fail=1
fi

# --- 7. a held floor older than the room is a wrong clock, not a stall ----------
# The held time is `now - sent_ms` of the last turn-consuming message, and `sent_ms` is
# whatever the seat that sent it wrote. A value that predates the room cannot be a wait, so it
# is reported as the clock problem it is, naming the seat — and NOT clamped to something
# smaller, which could slip under the threshold and hide a stall that is real.
stale_turn() { # a proposal whose sent_ms is one millisecond after the epoch
  jq -n '{id:"a-1",from:"a",lamport:9,deps:{},act:"propose",refs:[],to:["*"],
          hand:false,turn:0,round:null,text:"a proposal from 1970",created_at:"test",sent_ms:1}' \
    > "$R/lane/a/000001.json"
  printf '1' > "$R/state/a.seq"
}
fresh; stale_turn
al=$(bash "$CLI" status 2>/dev/null | sed -n 's/^alarms://p')
case "$al" in
  *"clock is wrong"*) case "$al" in
      *STALL*) echo "FAIL a wrong clock raised a STALL as well:$al"; fail=1 ;;
      *) echo "ok   a held time older than the room read as a wrong clock, not a stall" ;;
    esac ;;
  *) echo "FAIL a held time older than the room was not reported as a clock problem:$al"; fail=1 ;;
esac

# A room that records no creation time cannot tell the two apart, and must keep its previous
# behaviour exactly rather than start reporting a problem it cannot see. That is what lets a
# room created before `created_ms` existed go on working.
fresh; stale_turn
jq 'del(.created_ms)' "$R/roster.json" > "$R/r.tmp" && mv "$R/r.tmp" "$R/roster.json"
al=$(bash "$CLI" status 2>/dev/null | sed -n 's/^alarms://p')
case "$al" in
  *STALL*) echo "ok   a room with no recorded creation time kept the plain stall threshold" ;;
  *) echo "FAIL a room with no recorded creation time lost the stall alarm:$al"; fail=1 ;;
esac

# And an ordinary room raises neither: the branch must not fire on every room that has spoken.
fresh
say_floor propose '[]' "An ordinary proposal." >/dev/null
al=$(bash "$CLI" status 2>/dev/null | sed -n 's/^alarms://p')
case "$al" in
  *STALL*|*"clock is wrong"*) echo "FAIL an ordinary room raised a floor-age alarm:$al"; fail=1 ;;
  *) echo "ok   an ordinary room raised no floor-age alarm" ;;
esac

[ "$fail" = 0 ] && echo "t9g PASS" || echo "t9g FAIL"
exit $fail
