#!/usr/bin/env bash
# t30 — `down` establishes which backend the seats are on before it closes anything (#171), and
# removes the monitors' memory of the room from the mailbox (#200).
#
# `down` is `relaunch`'s twin (t24): on a blipped `COUNCIL_BACKEND=auto` probe it looks in the
# other backend's container, which is empty for entirely correct reasons, so it closes nothing and
# prints nothing. It also killed the keeper, and `--purge` then deleted the container pin and the
# launch record, the only records of where the still-running seats are. A room reopened under the
# same name then held two agents per peer name, and nothing could tell.
#
# What is NOT tested here, as in t24: the classification is the shared driver's
# (`drv_absence_class`) and `shared/driver/tests` owns it. This file owns the DISPOSITION: that
# `elsewhere` refuses and leaves everything, that the other classes continue, and that the
# healthy path says nothing. The real `council_down` runs in every case, so each is a call-site
# test.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_helpers.sh
. "$DIR/_helpers.sh"
REAL_SKILL="$SKILL"

ROOT="$COUNCIL_TEST_ROOT/t30"; rm -rf "$ROOT"; mkdir -p "$ROOT" || exit 1
REPO="$ROOT/repo"; mkdir -p "$REPO"

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}
has() { grep -q -- "$2" <<<"$1" && printf yes || printf no; }
lines() { [ -s "$1" ] && printf 'yes' || printf 'no'; }
present() { [ -e "$1" ] && printf 'yes' || printf 'no'; }

# --- a real room, as t24 builds it ---------------------------------------------------------------
# A backend name that cannot resolve, so nothing here can reach a terminal even if a check being
# asserted on were missing; the shadow below chooses its own backend.
export COUNCIL_BACKEND=none-for-tests
( cd "$REPO" && git init -q . && bash "$CLI" --room r --me codex up \
    --scenario debate --agents claude,codex --cwd . "is it safe to take this room down?" ) >"$ROOT/up.log" 2>&1
ROOM="$REPO/.git/council/r"
[ -f "$ROOM/roster.json" ] || { echo "t30 FAIL: up did not create a room; output was:"; cat "$ROOT/up.log"; exit 1; }
ROOM_KEEPERS+=("$ROOM/state/keeper.pid")     # reaped by _helpers.sh's EXIT trap
export COUNCIL_ROOM="$ROOM" ROOM="$ROOM"

# --- the shadow skill: the shipped term.sh, sourced, with only the backend calls replaced -------
SHADOW="$ROOT/shadow"; mkdir -p "$SHADOW/lib"
for e in "$REAL_SKILL"/*; do
  case "${e##*/}" in lib|tests) ;; *) ln -s "$e" "$SHADOW/${e##*/}" ;; esac
done
for e in "$REAL_SKILL"/lib/*; do
  case "${e##*/}" in term.sh) ;; *) ln -s "$e" "$SHADOW/lib/${e##*/}" ;; esac
done
SESSIONS="$ROOT/sessions"; SESSIONS_RC="$ROOT/sessions-rc"; KILLED="$ROOT/killed"
cat >"$SHADOW/lib/term.sh" <<SHADOWEOF
COUNCIL_BACKEND=tmux
. "$REAL_SKILL/lib/term.sh"
ct_sessions() { cat "$SESSIONS" 2>/dev/null; return "\$(cat "$SESSIONS_RC" 2>/dev/null || printf 0)"; }
ct_kill()     { printf '%s\n' "\$1" >>"$KILLED"; return 1; }
SHADOWEOF

# --- the real code under test, with what council.sh sources for `down` ---------------------------
SKILL="$REAL_SKILL"
# shellcheck source=../lib/lib.sh
. "$REAL_SKILL/lib/lib.sh"
# shellcheck source=../lib/verbs.sh
. "$REAL_SKILL/lib/verbs.sh"
# shellcheck source=../lib/policy.sh
. "$REAL_SKILL/lib/policy.sh"
# shellcheck source=../lib/up.sh
. "$REAL_SKILL/lib/up.sh"
# For `lr_file` only, to find the record where production writes it; `down` gets it through term.sh.
# shellcheck source=../lib/launch-record.sh
. "$REAL_SKILL/lib/launch-record.sh"

run_down() { # <arg>... -> stdout+stderr, then a last line "rc=<n>"
  local out rc=0
  out=$( SKILL="$SHADOW" council_down "$@" 2>&1 ) || rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
rc_of() { printf '%s' "$1" | sed -n 's/^rc=//p' | tail -1; }

# The mailbox files `down` must keep or remove, at the paths production reads them from.
SIGF=$(_status_sigfile) || { echo "t30 FAIL: no status signature path"; exit 1; }
EPF=$(_stall_epfile alarms) || { echo "t30 FAIL: no stall record path"; exit 1; }
LRF=$(lr_file) || { echo "t30 FAIL: no launch record path"; exit 1; }
seed() { # the room's evidence and the monitors' memory, as a live room would have them
  rm -f "$SESSIONS" "$SESSIONS_RC" "$KILLED" "$ROOM"/state/container-*
  printf 'sig\n' > "$SIGF"; printf 'ep\n' > "$EPF"
  [ -f "$LRF" ] || printf '{}\n' > "$LRF"
}
keeper_up() { _keeper_live "$ROOM/state/keeper.pid" >/dev/null && printf yes || printf no; }
[ "$(keeper_up)" = yes ] || { echo "t30 FAIL: up started no keeper; the refusal cases need one"; exit 1; }

# ====================================================== 1. ELSEWHERE, PLAIN: REFUSE, LEAVE EVERYTHING
# The backend answered, the container is honestly empty, and the pin says the seats were launched
# on the other backend. A refusal must leave the room exactly as it was: no close attempted, the
# keeper still up, and the evidence in place. The keeper assertion pins the check's POSITION: move
# it below the keeper kill and only that one reds.
printf '\n── plain down, room launched on the other backend ──\n'
seed; : >"$ROOM/state/container-agterm"; : >"$SESSIONS"; printf '0\n' >"$SESSIONS_RC"
out=$(run_down)
ok "1: a room pinned elsewhere is refused"        4    "$(rc_of "$out")"
ok "1: ...closing nothing"                        no   "$(lines "$KILLED")"
ok "1: ...leaving the keeper up"                  yes  "$(keeper_up)"
ok "1: ...and the pin"                            yes  "$(present "$ROOM/state/container-agterm")"
ok "1: ...and the monitors' memory"               yes  "$(present "$SIGF")"
ok "1: ...saying it refused"                      yes  "$(has "$out" 'refusing')"
ok "1: ...naming the backend it was launched on"  yes  "$(has "$out" 'launched on agterm')"
ok "1: ...with the pin to set"                    yes  "$(has "$out" 'COUNCIL_BACKEND=agterm')"
ok "1: ...and not claiming the room is down"      no   "$(has "$out" 'room kept')"

# ====================================================== 2. ELSEWHERE, --purge: THE EVIDENCE SURVIVES
# THE INCIDENT. `--purge` deleted the pin (inside the room) and the launch record (in the mailbox),
# so nothing could later tell that seats were still running for this room.
printf '\n── down --purge, room launched on the other backend ──\n'
seed; : >"$ROOM/state/container-agterm"; : >"$SESSIONS"; printf '0\n' >"$SESSIONS_RC"
out=$(run_down --purge)
ok "2: a purge of a room pinned elsewhere is refused" 4 "$(rc_of "$out")"
ok "2: ...leaving the room"                       yes  "$(present "$ROOM/roster.json")"
ok "2: ...and the pin"                            yes  "$(present "$ROOM/state/container-agterm")"
ok "2: ...and the launch record"                  yes  "$(present "$LRF")"
ok "2: ...and the keeper up"                      yes  "$(keeper_up)"
ok "2: ...saying what the purge would have cost"  yes  "$(has "$out" 'only records of which backend')"
ok "2: ...and that nothing was deleted"           yes  "$(has "$out" 'nothing was deleted')"

# ====================================================== 3. UNREACHABLE: WARN AND CONTINUE
# The operator asked for a teardown, and a backend that will not answer is not authority to refuse
# it. It does mean the closes cannot reach it, and the operator is told so before they run.
printf '\n── the backend did not answer ──\n'
seed; : >"$ROOM/state/container-tmux"; : >"$SESSIONS"; printf '1\n' >"$SESSIONS_RC"
out=$(run_down)
ok "3: an unanswered question still takes the room down" 0 "$(rc_of "$out")"
ok "3: ...trying every seat"                      yes  "$(lines "$KILLED")"
ok "3: ...naming what went unanswered"            yes  "$(has "$out" 'did not answer when asked')"
ok "3: ...and saying the closes prove nothing"    yes  "$(has "$out" 'cannot reach any seat')"
ok "3: ...and not refusing"                       no   "$(has "$out" 'refusing')"

# ====================================================== 4. CORROBORATED: SAY NOTHING, FORGET THE MONITORS
# The commonest healthy path. No note, and the monitors' memory of the room is removed (#200), so a
# room reopened under this name starts both monitors fresh. The kept room keeps its launch record:
# it is the evidence the next read checks the teardown against.
printf '\n── a teardown the backend corroborates ──\n'
seed; : >"$ROOM/state/container-tmux"; : >"$SESSIONS"; printf '0\n' >"$SESSIONS_RC"
out=$(run_down)
ok "4: a corroborated teardown succeeds"          0    "$(rc_of "$out")"
ok "4: ...trying every seat"                      yes  "$(lines "$KILLED")"
ok "4: ...saying nothing about absence"           no   "$(has "$out" 'note —')"
ok "4: ...removing the status signature"          no   "$(present "$SIGF")"
ok "4: ...and the STALL firing record"            no   "$(present "$EPF")"
ok "4: ...keeping the launch record"              yes  "$(present "$LRF")"
ok "4: ...and the room"                           yes  "$(has "$out" 'room kept')"

# ====================================================== 5. CORROBORATED --purge: EVERYTHING GOES
printf '\n── a purge the backend corroborates ──\n'
seed; : >"$ROOM/state/container-tmux"; : >"$SESSIONS"; printf '0\n' >"$SESSIONS_RC"
out=$(run_down --purge)
ok "5: a corroborated purge succeeds"             0    "$(rc_of "$out")"
ok "5: ...deleting the room"                      no   "$(present "$ROOM")"
ok "5: ...and the launch record"                  no   "$(present "$LRF")"
ok "5: ...and the status signature"               no   "$(present "$SIGF")"

printf '\nt30-down-absence: %s checks, %s\n' "$CHECKS" \
  "$([ "$FAILURES" = 0 ] && echo 'all passed' || echo "$FAILURES FAILED")"
[ "$FAILURES" = 0 ]
