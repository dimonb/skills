#!/usr/bin/env bash
# t9 — putting one seat back up.
#
# What this test can and cannot reach: `relaunch` ends in ct_launch, which spawns a real
# agent in a real terminal, so the launch itself belongs to a live room and not to a suite
# that has to run on a headless box. What IS testable here is everything in front of it —
# the checks that decide whether a launch should be attempted at all, and the keeper, which
# is the piece that decides whether a relaunched seat can hear anything.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
R="${TMPDIR:-/tmp}/council-test/t9"; rm -rf "$R"
mkroom "$R" a b
export COUNCIL_ROOM="$R" ROOM="$R"
fail=0

# A backend name that cannot resolve, so nothing here can spawn a terminal even if one of
# the checks being asserted on were missing. A test whose safety depends on the code under
# test being correct is not a test of that code.
export COUNCIL_BACKEND=none-for-tests

OUT=""
want() { # <exit> <what> <cmd>... ; leaves the output in $OUT
  local w="$1" what="$2"; shift 2
  local rc
  OUT=$("$@" 2>&1); rc=$?
  [ "$rc" = "$w" ] && return 0
  echo "FAIL $what: expected exit $w, got $rc"; printf '%s\n' "$OUT"; fail=1; return 1
}
says() { # <pattern> <what>
  printf '%s\n' "$OUT" | grep -qi -- "$1" || { echo "FAIL $2; output was:"; printf '%s\n' "$OUT"; fail=1; }
}

# --- the roster is the authority on who has a seat -------------------------------
if want 2 "a peer that is not in the room" bash "$CLI" relaunch nosuch; then
  says 'not in this room' "the message does not say the peer is unknown"
  says 'a, b'             "the error does not name the roster"
fi
want 2 "no peer named at all" bash "$CLI" relaunch
want 2 "two peers at once"    bash "$CLI" relaunch a b
want 2 "an unknown option"    bash "$CLI" relaunch a --nope

# --- a seat with no launcher is the chair's own, and says so ---------------------
if want 3 "a peer with no launcher" bash "$CLI" relaunch a; then
  says '--me' "the message does not explain why there is no launcher"
fi

# From here on `a` has a launcher, so the checks behind it become reachable.
printf '#!/usr/bin/env bash\ntrue\n' > "$R/state/launch-a.sh"; chmod +x "$R/state/launch-a.sh"

# --- cwd comes from the roster or from the caller, never from a guess ------------
if want 2 "a room with no recorded cwd" bash "$CLI" relaunch a; then
  says '--cwd' "the message does not offer --cwd"
fi
if want 2 "a cwd that does not exist" bash "$CLI" relaunch a --cwd "$R/no-such-dir"; then
  says 'no such directory' "the message does not name the missing directory"
fi

# With a cwd in hand the only thing left is the terminal — and reaching that failure is what
# proves the checks above were the only thing standing between the caller and a launch.
jq --arg c "$R" '.cwd = $c' "$R/roster.json" > "$R/roster.tmp" && mv "$R/roster.tmp" "$R/roster.json"
if want 1 "a room with no terminal backend" bash "$CLI" relaunch a; then
  says 'backend' "the failure does not blame the backend"
fi

# --- the keeper is put back, because `down` killed it ----------------------------
# A seat restarted into a room whose keeper is dead looks perfectly healthy and hears
# nothing: a bell rung at a participant that is not at that instant inside `recv` is lost.
keep="$R/state/keeper.pid"
old=$(cat "$keep")
# -9, not the default: the keeper sits in a foreground `sleep`, and bash defers a catchable
# signal until that child returns — a plain kill would appear to do nothing for 5 seconds.
kill -9 "$old" 2>/dev/null
for _i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$old" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$old" 2>/dev/null; then
  echo "FAIL could not kill the keeper for the test (pid $old)"; fail=1
else
  bash "$CLI" relaunch a >/dev/null 2>&1
  new=$(cat "$keep" 2>/dev/null)
  if [ -z "$new" ] || ! kill -0 "$new" 2>/dev/null; then
    echo "FAIL relaunch left the room without a keeper (was $old, now ${new:-none})"; fail=1
  else
    echo "keeper restarted: $old -> $new"
  fi
fi

[ "$fail" = 0 ] && echo "t9 PASS" || echo "t9 FAIL"
exit $fail
