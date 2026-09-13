#!/usr/bin/env bash
# t23 — `relaunch` establishes what it is about to destroy (#152).
#
# `relaunch` closes a seat and starts a fresh one, so a participant's entire reading of the
# argument rides on one question: is that seat really gone? It used to ask nothing at all, which
# on a blipped `COUNCIL_BACKEND=auto` probe made it a DUPLICATOR — the kill reaches an empty
# container on the wrong backend and prints nothing, the live seat's launcher and protocol are
# overwritten under it, and a SECOND agent starts for the same peer name.
#
# What is NOT tested here, deliberately. The classification is the shared driver's
# (`drv_absence_class`) and `shared/driver/tests` owns it; `say`'s reading of the same verdict is
# t21's. This file owns only the DISPOSITION: which class refuses, which continues, that a refusal
# leaves NOTHING behind, and that the corroborated case says nothing at all — an alarm on the
# healthy path is one the operator learns to ignore.
#
# The CALL SITE is asserted twice over, because a check that is tested only through its own
# function stays green when the caller stops calling it. Here the real `council_relaunch` runs, so
# every case is a call-site test; and t13 runs the shipped verb against a backend that cannot
# answer, where the `unreachable` note is the visible trace of this check happening at all.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_helpers.sh
. "$DIR/_helpers.sh"
REAL_SKILL="$SKILL"

ROOT="$COUNCIL_TEST_ROOT/t23"; rm -rf "$ROOT"; mkdir -p "$ROOT" || exit 1
REPO="$ROOT/repo"; mkdir -p "$REPO"

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}
has() { printf '%s' "$1" | grep -q -- "$2" && printf yes || printf no; }

# --- a real room ------------------------------------------------------------------------------
# Built by the real `up`, like t13 and for t13's reason: half of what `relaunch` reads is what
# `up` wrote — the recorded cwd, which agent plays the seat, the scenario the protocol is rendered
# from. A hand-built roster would pin a fixture only this file believes in. A backend name that
# cannot resolve, so nothing here can reach a terminal even if a check being asserted on were
# missing; the shadow below chooses its own backend for the cases that need one.
export COUNCIL_BACKEND=none-for-tests
( cd "$REPO" && git init -q . && bash "$CLI" --room r --me codex up \
    --scenario debate --agents claude,codex --cwd . "is that seat really gone?" ) >"$ROOT/up.log" 2>&1
ROOM="$REPO/.git/council/r"
[ -f "$ROOM/roster.json" ] || { echo "t23 FAIL: up did not create a room; output was:"; cat "$ROOT/up.log"; exit 1; }
ROOM_KEEPERS+=("$ROOM/state/keeper.pid")     # reaped by _helpers.sh's EXIT trap
export COUNCIL_ROOM="$ROOM" ROOM="$ROOM"
SNAME="council-r-claude"                     # what ct_name renders for this room and seat

# --- the shadow skill, i.e. the faked terminal --------------------------------------------------
# `relaunch` reads five things out of `$SKILL`: the scenario, the channel protocol, the adapters,
# council.sh and lib/. So the shadow is the real skill with ONE file replaced — everything else is
# a symlink to the shipped thing, and the shipped `term.sh` is not replaced but SOURCED and then
# narrowly overridden. That keeps `ct_name`, `ct_absence_class` and `ct_pins_elsewhere` real, over
# the room's real pin directory, so the session-name spelling on both sides of the `listed`
# comparison is production's and cannot silently drift apart (the driver warns that a mismatch
# turns that arm off with nothing to catch it).
SHADOW="$ROOT/shadow"; mkdir -p "$SHADOW/lib"
for e in "$REAL_SKILL"/*; do
  case "${e##*/}" in lib|tests) ;; *) ln -s "$e" "$SHADOW/${e##*/}" ;; esac
done
for e in "$REAL_SKILL"/lib/*; do
  case "${e##*/}" in term.sh) ;; *) ln -s "$e" "$SHADOW/lib/${e##*/}" ;; esac
done
SESSIONS="$ROOT/sessions"                    # what ct_sessions prints
SESSIONS_RC="$ROOT/sessions-rc"              # ...and the status it exits with
KILLED="$ROOT/killed"                        # every ct_kill call, one peer per line
LAUNCHED="$ROOT/launched"                    # every ct_launch call, likewise
cat >"$SHADOW/lib/term.sh" <<SHADOWEOF
# The shipped terminal, with only the verbs that would touch a live backend replaced. Pinned to
# tmux because \`auto\` would resolve against whatever is running on the developer's machine and
# make the pin cases mean something different there than in CI.
COUNCIL_BACKEND=tmux
. "$REAL_SKILL/lib/term.sh"
ct_sessions()  { cat "$SESSIONS" 2>/dev/null; return "\$(cat "$SESSIONS_RC" 2>/dev/null || printf 0)"; }
# rc 1 by default: "closed nothing", which is what a dead seat looks like on tmux — and, before
# this change, also what the wrong backend looked like.
ct_kill()      { printf '%s\n' "\$1" >>"$KILLED"; return "\${FAKE_KILL_RC:-1}"; }
ct_launch()    { printf '%s\n' "\$1" >>"$LAUNCHED"; return 0; }
ct_container() { printf 'fake-container'; }
SHADOWEOF

# --- the real code under test -------------------------------------------------------------------
SKILL="$REAL_SKILL"
# shellcheck source=../lib/lib.sh
. "$REAL_SKILL/lib/lib.sh"
# shellcheck source=../lib/up.sh
. "$REAL_SKILL/lib/up.sh"

# Every case in its own subshell: `c_peers` memoises the roster per shell, and the driver caches
# the backend it resolved at source time.
run_relaunch() { # <arg>... -> stdout+stderr, then a last line "rc=<n>"
  local out rc=0
  out=$( SKILL="$SHADOW" council_relaunch "$@" 2>&1 ) || rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
rc_of() { printf '%s' "$1" | sed -n 's/^rc=//p' | tail -1; }
# The pins live where production writes them — in the room — so nothing here has to spell
# `container-<backend>` differently from the driver that reads it.
reset() { rm -f "$SESSIONS" "$SESSIONS_RC" "$KILLED" "$LAUNCHED" "$ROOM"/state/container-*; }
lines() { [ -s "$1" ] && printf 'yes' || printf 'no'; }

# ====================================================== 1. THE CORROBORATED CASE SAYS NOTHING
# The backend answered, the pin agrees, and the seat is not in the list: the absence is
# established and there is nothing to warn about. This is the commonest healthy path, and an
# alarm here would be the kind an operator learns to scroll past — which costs more than the
# defect it was added for.
printf '\n── an absence the backend corroborates ──\n'
reset; : >"$ROOM/state/container-tmux"; : >"$SESSIONS"; printf '0\n' >"$SESSIONS_RC"
out=$(run_relaunch claude)
ok "1: a corroborated absence relaunches"      0    "$(rc_of "$out")"
ok "1: ...having launched the seat"            yes  "$(lines "$LAUNCHED")"
ok "1: ...and says nothing about absence"      no   "$(has "$out" 'note —')"
ok "1: ...and certainly does not refuse"       no   "$(has "$out" 'refusing')"

# ====================================================== 2. UNREACHABLE: WARN, DO NOT REFUSE
# The operator named this seat and asked for it back. A question the backend would not answer is
# not authority to refuse a documented recovery — but it does mean the close below cannot tell a
# dead seat from a live one, and the operator has to be told that before it happens.
printf '\n── the backend did not answer ──\n'
reset; : >"$ROOM/state/container-tmux"; : >"$SESSIONS"; printf '1\n' >"$SESSIONS_RC"
out=$(run_relaunch claude)
ok "2: an unanswered question still relaunches" 0   "$(rc_of "$out")"
ok "2: ...having launched the seat"            yes  "$(lines "$LAUNCHED")"
ok "2: ...naming what went unanswered"         yes  "$(has "$out" 'did not answer when asked')"
ok "2: ...and saying the close proves nothing" yes  "$(has "$out" 'prints nothing')"
# Asserting the class alone would leave the whole `case` arm deletable: the lines above it print
# for every class.
ok "2: ...not the ALIVE reading"               no   "$(has "$out" 'ALIVE')"

# ====================================================== 3. LISTED: THE SEAT IS ALIVE
# An ordinary reason to be here — "killed to pick up new permissions" — so this states what is
# about to happen rather than refusing it. The sentence is council's own: the driver's `why` ends
# "it is the per-session lookup that failed", which is `say`'s conclusion drawn from a lookup
# `say` made and this verb never makes. Printing it would claim something relaunch never
# established, which is the defect #148 closed.
printf '\n── the backend still lists the seat ──\n'
reset; : >"$ROOM/state/container-tmux"; printf '%s\n' "$SNAME" >"$SESSIONS"; printf '0\n' >"$SESSIONS_RC"
out=$(run_relaunch claude)
ok "3: a live seat still relaunches"           0    "$(rc_of "$out")"
ok "3: ...having launched the seat"            yes  "$(lines "$LAUNCHED")"
ok "3: ...saying the seat is ALIVE"            yes  "$(has "$out" 'ALIVE')"
ok "3: ...and naming the session it saw"       yes  "$(has "$out" "still lists .$SNAME")"
ok "3: ...and what closing it costs"           yes  "$(has "$out" 'reading of the argument')"
ok "3: ...without claiming say's lookup"       no   "$(has "$out" 'per-session lookup')"
ok "3: ...and not the unreachable reading"     no   "$(has "$out" 'did not answer when asked')"

# ====================================================== 4. ELSEWHERE: REFUSE, AND LEAVE NOTHING
# THE INCIDENT. The backend answered and the container is empty — for the entirely correct reason
# that this process resolved the other backend. Only the pin can catch it: reachability is fine
# and the list is honestly empty, so every other fact agrees that the seat is gone.
#
# A refusal has to leave the room EXACTLY as it found it, and that is asserted four ways, because
# each of the four is a separate way this verb destroys a seat: no kill, no launch, no rewritten
# inputs, and no keeper started. The last one is what pins the check's POSITION — put it a line
# lower, after `_keeper_ensure`, and only that assertion reds.
printf '\n── the room was launched on the other backend ──\n'
reset; : >"$ROOM/state/container-agterm"; : >"$SESSIONS"; printf '0\n' >"$SESSIONS_RC"
printf '\nINJECTED-LAUNCHER\n' >>"$ROOM/state/launch-claude.sh"
printf '\nINJECTED-PROTOCOL\n' >>"$ROOM/protocol-claude.md"
kill_keeper "$ROOM/state/keeper.pid" -9
keeper_before=$(cat "$ROOM/state/keeper.pid" 2>/dev/null)
out=$(run_relaunch claude)
ok "4: a room pinned elsewhere is refused"     4    "$(rc_of "$out")"
ok "4: ...killing nothing"                     no   "$(lines "$KILLED")"
ok "4: ...launching nothing"                   no   "$(lines "$LAUNCHED")"
ok "4: ...leaving the launcher untouched"      yes  "$(has "$(cat "$ROOM/state/launch-claude.sh")" 'INJECTED-LAUNCHER')"
ok "4: ...leaving the protocol untouched"      yes  "$(has "$(cat "$ROOM/protocol-claude.md")" 'INJECTED-PROTOCOL')"
ok "4: ...and starting no keeper"              "$keeper_before" "$(cat "$ROOM/state/keeper.pid" 2>/dev/null)"
ok "4: ...saying it refused"                   yes  "$(has "$out" 'refusing')"
ok "4: ...naming the backend it was launched on" yes "$(has "$out" 'launched on agterm')"
ok "4: ...and what it would have cost"         yes  "$(has "$out" 'TWO agents')"
# The remedy must name the backend to PIN. "Pin it" with no value is an instruction the operator
# cannot follow without reading the source, and this is the line that needed `ct_pins_elsewhere`
# to be its own verb at all — the class above is read through a command substitution, so the pin
# directory the driver resolved in there never reached this shell.
ok "4: ...with the pin to set"                 yes  "$(has "$out" 'COUNCIL_BACKEND=agterm')"
ok "4: ...and what it means if pinning fails" yes  "$(has "$out" 'really gone')"
ok "4: ...and not another class's reading"     no   "$(has "$out" 'did not answer when asked')"

printf '\nt24-relaunch-absence: %s checks, %s\n' "$CHECKS" \
  "$([ "$FAILURES" = 0 ] && echo 'all passed' || echo "$FAILURES FAILED")"
[ "$FAILURES" = 0 ]
