#!/usr/bin/env bash
# t13 — putting one seat back up.
#
# Unlike t1-t8 this builds its room with the real `council.sh up` rather than `_mkroom`,
# because half of what `relaunch` reads is what `up` wrote: the recorded cwd, which agent
# plays each seat, and the scenario the protocol is rendered from. A hand-built roster would
# test relaunch against a fixture only this file believes in, and the producer side would be
# covered by nothing — remove `cwd:$cwd` from `up` and every room in the world stops being
# relaunchable, with a green suite.
#
# What it cannot reach is the launch itself: ct_launch spawns a real agent in a real
# terminal. Everything in front of that is here, including the regeneration, which happens
# before the launch is attempted and is therefore fully testable headlessly.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"

# A private root per run. The rest of the suite shares one fixed path per test name, which
# makes two concurrent runs delete each other's rooms; that is filed separately, and there is
# no reason for a new test to add another instance of it.
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/council-t13.XXXXXX") || { echo "t13 FAIL: no temp dir"; exit 1; }
REPO="$ROOT/repo"; mkdir -p "$REPO"
fail=0
cleanup() {
  [ -n "${ROOM:-}" ] && [ -s "$ROOM/state/keeper.pid" ] && kill -9 "$(cat "$ROOM/state/keeper.pid")" 2>/dev/null
  rm -rf "$ROOT"
}
trap cleanup EXIT

# A backend name that cannot resolve, so nothing here can spawn a terminal even if a check
# being asserted on were missing. A test whose safety depends on the code under test being
# correct is not a test of that code.
export COUNCIL_BACKEND=none-for-tests

OUT=""
# Every command runs under a deadline. `timeout` is coreutils and not on a stock macOS, so
# this is a watchdog rather than a dependency. It matters: the defect this file exists partly
# to pin is an option parser that SPINS instead of failing, and without a cap a regression
# would hang the suite rather than fail it — the worst way for a test to report a bug.
run_capped() { # <seconds> <cmd>...
  local secs="$1"; shift
  local o="$ROOT/.out"
  "$@" >"$o" 2>&1 &
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
  run_capped 10 "$@"; rc=$?
  [ "$rc" = "$w" ] && return 0
  [ "$rc" = 137 ] && { echo "FAIL $what: HUNG (killed after 10s), expected exit $w"; fail=1; return 1; }
  echo "FAIL $what: expected exit $w, got $rc"; printf '%s\n' "$OUT"; fail=1; return 1
}
says() { printf '%s\n' "$OUT" | grep -qi -- "$1" || { echo "FAIL $2; output was:"; printf '%s\n' "$OUT"; fail=1; }; }
no_say() { printf '%s\n' "$OUT" | grep -qi -- "$1" && { echo "FAIL $2"; fail=1; }; return 0; }

# --- build a real room -----------------------------------------------------------
# `--me codex` leaves that seat without a launcher, which is how `up` records "this one is
# the human" — so one room covers both the regeneration path (claude) and the seat that has
# no terminal to restart (codex). A relative --cwd on purpose: the roster must hold the
# resolved path, not the string.
( cd "$REPO" && git init -q . && bash "$CLI" --room r --me codex up \
    --scenario debate --agents claude,codex --cwd . "does the seat come back?" ) >"$ROOT/up.log" 2>&1
ROOM="$REPO/.git/council/r"
if [ ! -f "$ROOM/roster.json" ]; then
  echo "FAIL up did not create a room; output was:"; cat "$ROOT/up.log"; echo "t13 FAIL"; exit 1
fi
export COUNCIL_ROOM="$ROOM"

# --- what `up` recorded, which is what relaunch depends on -----------------------
REPO_P=$(cd "$REPO" && pwd -P)
got=$(jq -r '.cwd // "<missing>"' "$ROOM/roster.json")
[ "$got" = "$REPO_P" ] || { echo "FAIL up recorded cwd '$got', expected the resolved '$REPO_P'"; fail=1; }
case "$got" in /*) ;; *) echo "FAIL the recorded cwd is not absolute: $got"; fail=1 ;; esac
[ "$(jq -r '.peers[] | select(.name=="claude") | .kind' "$ROOM/roster.json")" = claude ] \
  || { echo "FAIL the roster does not record which agent plays claude"; fail=1; }
[ -f "$ROOM/state/launch-claude.sh" ] || { echo "FAIL up wrote no launcher for claude"; fail=1; }
[ -f "$ROOM/state/launch-codex.sh" ] && { echo "FAIL up wrote a launcher for the --me seat"; fail=1; }

# --- the roster is the authority on who has a seat -------------------------------
if want 2 "a peer that is not in the room" bash "$CLI" relaunch nosuch; then
  says 'not in this room' "the message does not say the peer is unknown"
  says 'claude, codex'    "the error does not name the roster"
fi
want 2 "no peer named at all" bash "$CLI" relaunch
want 2 "two peers at once"    bash "$CLI" relaunch claude codex
want 2 "an unknown option"    bash "$CLI" relaunch claude --nope

# A dangling option value must FAIL, not spin. `${2:-}` plus `shift 2` silently declines to
# shift with one argument left, and the loop then never terminates: 100% CPU, no output,
# forever, in the verb most likely to be run unattended.
if want 2 "a dangling --cwd" bash "$CLI" relaunch claude --cwd; then
  says 'needs a directory' "the message does not say --cwd wants a value"
fi

# --- the seat the human took has no terminal to restart --------------------------
if want 3 "the --me seat" bash "$CLI" relaunch codex; then
  says '--me' "the message does not explain why there is no launcher"
fi

# --- cwd: recorded, overridable, resolved, never guessed -------------------------
if want 2 "a cwd that does not exist" bash "$CLI" relaunch claude --cwd "$ROOT/no-such-dir"; then
  says 'no such directory' "the message does not name the missing directory"
fi

# --- regeneration: the stored inputs are rewritten, not re-run -------------------
# Both files live in the room, and every participant is handed the room as a writable root,
# so a seat's launcher and system prompt are writable by the agents it is arguing with.
# relaunch must not carry either forward.
printf '\necho INJECTED-LAUNCHER\n'   >> "$ROOM/state/launch-claude.sh"
printf '\nINJECTED-PROTOCOL\n'        >> "$ROOM/protocol-claude.md"
# Reaching ct_launch (exit 1, no backend) is what proves regeneration ran BEFORE the launch
# rather than not at all.
want 1 "a room with no terminal backend" bash "$CLI" relaunch claude \
  && says 'backend' "the failure does not blame the backend"
grep -q 'INJECTED-LAUNCHER' "$ROOM/state/launch-claude.sh" \
  && { echo "FAIL relaunch carried a tampered launcher forward instead of regenerating it"; fail=1; }
grep -q 'INJECTED-PROTOCOL' "$ROOM/protocol-claude.md" \
  && { echo "FAIL relaunch carried a tampered protocol forward instead of regenerating it"; fail=1; }
# ...and what it wrote is the real thing, not an empty file.
grep -q "COUNCIL_ME=claude" "$ROOM/state/launch-claude.sh" \
  || { echo "FAIL the regenerated launcher does not export the peer"; fail=1; }
grep -q "cd $REPO_P" "$ROOM/state/launch-claude.sh" \
  || { echo "FAIL the regenerated launcher does not cd to the recorded cwd"; fail=1; }
[ -x "$ROOM/state/launch-claude.sh" ] || { echo "FAIL the regenerated launcher is not executable"; fail=1; }
grep -q 'council.sh' "$ROOM/protocol-claude.md" \
  || { echo "FAIL the regenerated protocol is not the channel protocol"; fail=1; }
grep -q '__ME__' "$ROOM/protocol-claude.md" \
  && { echo "FAIL the regenerated protocol still holds an unrendered placeholder"; fail=1; }

# --cwd overrides the recorded value, and it is what the launcher cds to.
mkdir -p "$ROOT/elsewhere"
ELSE_P=$(cd "$ROOT/elsewhere" && pwd -P)
want 1 "an overridden cwd" bash "$CLI" relaunch claude --cwd "$ROOT/elsewhere"
grep -q "cd $ELSE_P" "$ROOM/state/launch-claude.sh" \
  || { echo "FAIL --cwd did not reach the regenerated launcher's cd line"; fail=1; }

# --- the keeper is put back, because `down` killed it ----------------------------
# A seat restarted into a room whose keeper is dead looks perfectly healthy and hears
# nothing: a bell rung at a participant not at that instant inside `recv` is lost.
keep="$ROOM/state/keeper.pid"
old=$(cat "$keep")
kill -9 "$old" 2>/dev/null      # -9 so the test cannot race the keeper's own exit
for _i in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$old" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$old" 2>/dev/null; then
  echo "FAIL could not kill the keeper for the test (pid $old)"; fail=1
else
  run_capped 10 bash "$CLI" relaunch claude
  new=$(cat "$keep" 2>/dev/null)
  if [ -z "$new" ] || ! kill -0 "$new" 2>/dev/null; then
    echo "FAIL relaunch left the room without a keeper (was $old, now ${new:-none})"; fail=1
  else
    echo "keeper restarted: $old -> $new"
  fi
fi

[ "$fail" = 0 ] && echo "t13 PASS" || echo "t13 FAIL"
exit $fail
