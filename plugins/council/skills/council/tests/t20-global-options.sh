#!/usr/bin/env bash
# t20 — council.sh's global option loop terminates on a dangling option value.
#
# `--room` and `--me` are accepted before or after the verb, by a loop that shifts twice past
# each. Written as `${2:-}` + `shift 2` that loop CANNOT TERMINATE when the option is the last
# word: the default expansion suppresses the unbound-variable abort `set -u` gives every other
# option arm in this skill, and `shift 2` with one positional left fails and shifts nothing, so
# `$#` never falls. `council.sh status --room` then spins at 100% CPU, printing nothing, until
# something kills it — and `status` and `verdict` are exactly the verbs a supervisor runs
# unattended, where a silent infinite hang reads as a wedged room rather than as a typo.
#
# Reachable by ordinary means: copying a documented form without substituting the value, or
# writing `--room $r` unquoted with `$r` empty, which makes the word disappear.
#
# WHAT THIS FILE PINS IS TERMINATION, not the wording. Every probe runs under a watchdog and
# asserts the exit code first: a regression that prints a proper error and THEN spins is caught
# here, where a test that only grepped the message would pass it. The message assertions come
# second, and they are about the failure being loud enough to act on — which option was short.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"

R="$COUNCIL_TEST_ROOT/t20"; rm -rf "$R"; mkdir -p "$R/repo" || exit 1
fail=0

# A real git repo, because `--room <name>` resolves against the repo's shared git dir. Nothing
# here creates a room: naming one that does not exist is what proves the VALUE reached
# ROOM_NAME, since the refusal quotes the resolved path.
( cd "$R/repo" && git init -q . ) >/dev/null 2>&1 \
  || { echo "t20 FAIL: could not make a test repo"; exit 1; }

# Every probe under a deadline. `timeout` is coreutils and not on a stock macOS, so this is a
# watchdog rather than a dependency — and without a cap the regression this file exists for
# would HANG the suite instead of failing it, which is the worst way for a test to report a bug.
OUT=""
run_capped() { # <seconds> <cmd>...
  local secs="$1"; shift
  local o="$R/.out"
  ( cd "$R/repo" && "$@" ) >"$o" 2>&1 &
  local p=$!
  ( sleep "$secs"; kill -9 "$p" 2>/dev/null ) &
  local w=$!
  wait "$p"; local rc=$?
  kill "$w" 2>/dev/null; wait "$w" 2>/dev/null
  OUT=$(cat "$o" 2>/dev/null)
  return $rc
}
want() { # <exit> <what> <cmd>... ; leaves the output in $OUT
  local w="$1" what="$2"; shift 2
  local rc
  run_capped 5 "$@"; rc=$?
  [ "$rc" = "$w" ] && return 0
  [ "$rc" = 137 ] && { echo "FAIL $what: HUNG (killed after 5s), expected exit $w"; fail=1; return 1; }
  echo "FAIL $what: expected exit $w, got $rc"; printf '%s\n' "$OUT"; fail=1; return 1
}
says() { printf '%s\n' "$OUT" | grep -qi -- "$1" || { echo "FAIL $2; output was:"; printf '%s\n' "$OUT"; fail=1; }; }

# --- a dangling value must fail, loudly and fast ---------------------------------
# The two forms from the report, verbatim. Exit 2 is this script's usage-error code, the same
# one an unknown verb and a missing COUNCIL_ME already use.
if want 2 "status --room with no room name" bash "$CLI" status --room; then
  says 'room'  "the refusal does not name --room as the option that was short"
  says 'needs' "the refusal does not say the option wants a value"
fi
if want 2 "verdict --me with no peer name" bash "$CLI" verdict --me; then
  says 'me'    "the refusal does not name --me as the option that was short"
  says 'needs' "the refusal does not say the option wants a value"
fi

# The same options with no verb at all, which is a different path through the loop: `VERB` is
# still empty when the short option is read.
want 2 "a bare --room" bash "$CLI" --room
want 2 "a bare --me"   bash "$CLI" --me

# --- the guard must not fire when the value IS there ------------------------------
# A fix that rejected every `--room` would pass every assertion above. These pin the other
# direction: the operand is consumed, it lands where it is read, and the verb still parses on
# either side of it.
#
# `no such room` is the proof the value landed — the message quotes the resolved path, so it
# can only name `pinned-room` if that word became ROOM_NAME rather than being read as a verb.
if want 1 "--room <name> before the verb" bash "$CLI" --room pinned-room status; then
  says 'no such room'  "a named room that does not exist was not reported as missing"
  says 'pinned-room'   "the option's value did not reach the room resolver"
fi
if want 1 "--room <name> after the verb" bash "$CLI" status --room pinned-room; then
  says 'pinned-room'   "the value is read before the verb but not after it"
fi
# `--me` takes its value and gets out of the way: `help` short-circuits before any room is
# resolved, so exit 0 here means the peer name was consumed rather than treated as the verb.
want 0 "--me <peer> with a value" bash "$CLI" --me alice help
want 0 "--room <name> --me <peer> together" bash "$CLI" --room pinned-room --me alice help

[ "$fail" = 0 ] && echo "t20 PASS" || echo "t20 FAIL"
exit $fail
