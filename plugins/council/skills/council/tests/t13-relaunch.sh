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

# A private root per run. `COUNCIL_TEST_ROOT` is an optional override — nothing in the suite
# sets it yet — and otherwise we make our own. Never a path built from this test's own name:
# two concurrent runs then delete each other's rooms, which is what made a red t3 mean nothing
# for most of a day.
_own_root=""
if [ -z "${COUNCIL_TEST_ROOT:-}" ]; then
  COUNCIL_TEST_ROOT=$(mktemp -d) || { echo "t13 FAIL: no temp dir"; exit 1; }
  _own_root="$COUNCIL_TEST_ROOT"
fi
ROOT="$COUNCIL_TEST_ROOT/t13"
REPO="$ROOT/repo"; mkdir -p "$REPO"
fail=0
cleanup() {
  [ -n "${ROOM:-}" ] && kill_keeper "$ROOM/state/keeper.pid" -9
  rm -rf "$ROOT"
  # Only reap the root if we made it. A root handed down by a runner is that runner's to
  # remove, and taking it here would delete the other tests' rooms with it.
  [ -n "$_own_root" ] && rm -rf "$_own_root"
  return 0
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

# NO LAUNCHER MEANS NOTHING EXPORTS `COUNCIL_ME` FOR THAT SEAT, and a council command without
# it is a SUPERVISOR command — which the opening barrier deliberately does not withhold from.
# So in a roundtable room the seat a human took was handed the positions it owed one of its own
# against, by the `watch:` line this very function prints, on a healthy room. `up` has to say
# so, because the protocol file that seat reads tells every OTHER seat its environment is
# already exported.
grep -q -- "--me codex" "$ROOT/up.log" \
  || { echo "FAIL up did not tell the --me seat to pass --me on its own commands; output was:"; cat "$ROOT/up.log"; fail=1; }
grep -qi "reads included" "$ROOT/up.log" \
  || { echo "FAIL up did not say that the --me seat needs --me on READS, not only on send"; fail=1; }

# A relative --cwd resolved under an exported CDPATH, in its own throwaway room. `cd` searches
# CDPATH for an operand that does not start with `.` or `/`, and then ECHOES the directory it
# found — so a resolution that forgets `CDPATH=` captures TWO lines naming the WRONG
# directory. The launcher then carries `cd $'a\nb'` and the agent dies on launch with nothing
# logged, which is the single failure this skill spends the most words warning about.
mkdir -p "$REPO/sub" "$ROOT/decoy/sub"
( cd "$REPO" && CDPATH="$ROOT/decoy" bash "$CLI" --room cdp up \
    --scenario debate --agents claude,codex --cwd sub "cdpath" ) >"$ROOT/cdp.log" 2>&1
cdp=$(jq -r '.cwd // "<missing>"' "$REPO/.git/council/cdp/roster.json" 2>/dev/null)
[ "$cdp" = "$REPO_P/sub" ] \
  || { echo "FAIL a relative --cwd under CDPATH recorded '$cdp', expected '$REPO_P/sub'"; fail=1; }
[ "$(printf '%s' "$cdp" | wc -l | tr -d ' ')" = 0 ] \
  || { echo "FAIL the recorded cwd is more than one line: $cdp"; fail=1; }
ck="$REPO/.git/council/cdp/state/keeper.pid"
[ -s "$ck" ] && kill -9 "$(cat "$ck")" 2>/dev/null

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
# It got that far on the RECORDED cwd, not by falling through the missing-cwd branch — which
# would otherwise be an exit-2 path that never reaches regeneration at all.
no_say 'predates the recorded cwd' "relaunch did not use the cwd the roster recorded"
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

# --- the four paths regeneration opened, and closed ------------------------------
# `roster.json` lives in the room, so a participant can write it — and relaunch reads which
# adapter to SOURCE, which scenario to RENDER and which names to interpolate into a sed
# program out of it. Each of these ran for real before the values were checked. None of this
# is containment (a participant is unconfined either way — see SKILL.md); it removes the path
# a supervisor triggers by following the documented recovery.
tamper() { jq "$1" "$ROOM/roster.json" > "$ROOM/rt" && mv "$ROOM/rt" "$ROOM/roster.json"; }
restore_roster() { cp "$ROOT/roster.keep" "$ROOM/roster.json"; }
cp "$ROOM/roster.json" "$ROOT/roster.keep"

printf '#!/usr/bin/env bash\ntouch %s\nadapter_cmd() { printf "exec true\\n"; }\n' \
  "$ROOT/PWNED" > "$ROOM/pwn.sh"
tamper "$(printf '(.peers[] | select(.name=="claude") | .kind) = "%s"' \
  "../../../../../../../../../..$ROOM/pwn")"
want 2 "a roster naming a traversing adapter kind" bash "$CLI" relaunch claude \
  && says 'implausible agent kind' "the refusal does not name the kind"
[ -f "$ROOT/PWNED" ] && { echo "FAIL a roster-supplied adapter path was SOURCED"; fail=1; }
restore_roster

tamper '(.peers[] | select(.name=="claude") | .role) = "../../pwn"'
want 2 "a roster naming a traversing role" bash "$CLI" relaunch claude
restore_roster

tamper '.scenario = "../../pwn"'
want 2 "a roster naming a traversing scenario" bash "$CLI" relaunch claude \
  && says 'implausible scenario' "the refusal does not name the scenario"
restore_roster

tamper "$(printf '.order += ["zz#w %s/sedout"]' "$ROOT")"
# The refusal now comes from `c_peers`, the single reader of `.order`, rather than from
# relaunch's own `_plain_name` loop: the roster is rejected before any name reaches a path or
# the sed program. `_plain_name` is still there as an independent second statement of the rule,
# so this asserts the OUTCOME — refused at rc 2, announced, nothing written — and not which of
# the two said so, which is an internal detail that has now moved once.
want 2 "a peer name that breaks out of the sed program" bash "$CLI" relaunch claude \
  && says 'usable participant list' "the refusal does not say the roster was rejected"
ls "$ROOT"/sedout* >/dev/null 2>&1 && { echo "FAIL a crafted peer name reached sed as script"; fail=1; }
restore_roster

# `>` follows a symlink and `chmod +x` marks its target executable; the protocol path had no
# existence check at all, so a link there even CREATED the file it pointed at.
printf 'ORIGINAL\n' > "$ROOT/victim.txt"
rm -f "$ROOM/state/launch-claude.sh"; ln -s "$ROOT/victim.txt" "$ROOM/state/launch-claude.sh"
run_capped 10 bash "$CLI" relaunch claude
grep -q 'ORIGINAL' "$ROOT/victim.txt" \
  || { echo "FAIL a symlinked launcher was written through to its target"; fail=1; }
rm -f "$ROOM/protocol-claude.md"; ln -s "$ROOT/made-up.md" "$ROOM/protocol-claude.md"
run_capped 10 bash "$CLI" relaunch claude
[ -f "$ROOT/made-up.md" ] && { echo "FAIL a symlinked protocol created a file outside the room"; fail=1; }

# A roster whose `.order` is not an array. `jq '.order | index($p)'` looked like a membership
# test and SUBSTRING-matches on a string, while `.order[]` then errors and leaves the peer list
# empty — so one crafted string both admitted a traversing name and skipped every per-name
# check behind it. It is also a plain bug with nobody attacking: the protocol renders with no
# participants and the keeper comes back holding no fifos.
tamper '.order = "zz../../../../../../../elsewhere/targetzz"'
printf 'UNTOUCHED\n' > "$ROOT/victim2.txt"
want 2 "a roster whose participant list is not an array" bash "$CLI" relaunch claude \
  && says 'usable participant list' "the refusal does not name the roster"
grep -q 'UNTOUCHED' "$ROOT/victim2.txt" \
  || { echo "FAIL a non-array roster let relaunch write outside the room"; fail=1; }
restore_roster

# A parent directory swapped for a symlink: a rename cannot be redirected at the destination,
# but every write below a linked parent still lands elsewhere.
mv "$ROOM/state" "$ROOM/state-real" && ln -s "$ROOT/elsewhere" "$ROOM/state"
mkdir -p "$ROOT/elsewhere"
want 1 "a room whose state/ is a symlink" bash "$CLI" relaunch claude \
  && says 'symlink' "the refusal does not mention the symlink"
rm -f "$ROOM/state"; mv "$ROOM/state-real" "$ROOM/state"

# --- `up` must not create a room whose seats relaunch will refuse ----------------
# The producer and the consumer have to agree about what a name may be, or a room opens
# normally and then has no recovery verb — a failure that surfaces only in the emergency the
# verb exists for.
( cd "$REPO" && bash "$CLI" --room bad up --scenario debate --agents 'gpt5.1=codex,claude' "x" ) \
  >"$ROOT/bad.log" 2>&1
rc=$?
[ "$rc" = 2 ] || { echo "FAIL up accepted a participant name relaunch will refuse (exit $rc)"; fail=1; }
grep -q 'not a usable participant name' "$ROOT/bad.log" \
  || { echo "FAIL up's refusal does not name the problem; log:"; cat "$ROOT/bad.log"; fail=1; }
[ -d "$REPO/.git/council/bad" ] && { echo "FAIL up left a room behind after refusing"; fail=1; }

[ "$fail" = 0 ] && echo "t13 PASS" || echo "t13 FAIL"
exit $fail
