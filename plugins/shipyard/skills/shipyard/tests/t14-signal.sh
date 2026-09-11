#!/usr/bin/env bash
# t14-signal.sh — when may an EMPTY answer end the watch?
#
# PROVENANCE. `shipyard-report.sh` exits 0 to mean "everything shipped, stop watching", and the
# Step 2 loop breaks on it. That claim was reachable from an ABSENCE: two children were mid-review
# with open PRs when the agterm control socket failed a single probe, `auto` re-resolved to tmux
# for that one tick, a tmux session named after the repo held no ship windows, and the tick printed
# "no live ship terminals ... all changes shipped — exiting monitor". Supervision ended for good.
# The report was right about what it saw and wrong about what seeing nothing MEANS.
#
# WHAT THIS FILE PINS, and the third is what keeps the fix honest:
#   1. an empty answer that could not be corroborated never exits 0 — by BOTH routes into that
#      exit, the discovery branch and the named-slot tail, since they are separate code paths that
#      make the identical false claim;
#   2. the two facts corroboration rests on: `shipyard_slots` reports whether the container
#      ANSWERED (not merely what it said), and the container pin's own name records which backend
#      this fleet was launched on;
#   3. THE DESIGNED TERMINATION STILL WORKS. The monitor is armed once with a fixed slot list and
#      the supervisor tears children down one at a time, so the last teardown leaving zero
#      terminals is how a healthy run ENDS. A fix that made "found nothing" suspicious in general
#      would make every finished fleet monitor itself forever — a worse bug than the one being
#      closed, and silent in the opposite direction.
#
# Section 4 executes the real script, for the reason t13-wait.sh measured: `grep -Fc` over source
# lines asserts that a line exists and nothing about reachability or branch bodies, and six of
# seven semantic mutations survived that idiom.
#
# COST: three cases (4d's control and 4e) need a LIVE slot and so pay the report's 3s motion diff
# each; measured ~13s for the file. That is why it sits in `make test` and not the per-commit gate.
# The live cases are not optional — a torn-down fleet always prints a terminal report, so only a
# slot in flight can show that --only-changed still filters at all.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$DIR/.." && pwd)"
REPORT="$SKILL_DIR/shipyard-report.sh"

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}

T14TMP=$(mktemp -d "${TMPDIR:-/tmp}/t14-signal.XXXXXXXX") || exit 1
trap 'rm -rf "$T14TMP"' EXIT

# --------------------------------------------- 1. which backend was this fleet launched on?
# A pure function over the pin directory. Sourced in a subshell per case because the driver caches
# its backend at source time, which is exactly the "decide once per process" property under test.
PINDIR="$T14TMP/pins"; mkdir -p "$PINDIR"
pinned_elsewhere() { # <backend> -> "<answer>|<rc>"
  local be="$1" out rc=0
  out=$( export SHIPYARD_BACKEND="$be"
         . "$SKILL_DIR/shipyard-backend.sh" >/dev/null 2>&1
         DRV_CONTAINER_PIN_DIR="$PINDIR"
         shipyard_backend_pinned_elsewhere ) || rc=$?
  printf '%s|%s' "$out" "$rc"
}

ok "no pin at all -> nothing to disagree with" "|1" "$(pinned_elsewhere tmux)"

: > "$PINDIR/container-tmux"
ok "the pin names the backend we resolved"     "|1" "$(pinned_elsewhere tmux)"
# THE INCIDENT, as a unit: the fleet is on agterm and this process resolved tmux.
rm -f "$PINDIR/container-tmux"; : > "$PINDIR/container-agterm"
ok "pinned on agterm, resolved tmux"     "agterm|0" "$(pinned_elsewhere tmux)"
ok "...and the reverse is not a disagreement"  "|1" "$(pinned_elsewhere agterm)"
# Both present: this mailbox has launched on each, so neither choice is looking in the wrong place.
# Reporting a disagreement here would alarm on a legitimate history and teach the operator to
# ignore the block — the failure mode AGENTS.md names as costing more than the bug it guards.
: > "$PINDIR/container-tmux"
ok "both pinned -> no disagreement (tmux)"     "|1" "$(pinned_elsewhere tmux)"
ok "both pinned -> no disagreement (agterm)"   "|1" "$(pinned_elsewhere agterm)"
# A pin directory that does not exist must read as "nothing launched", never as a disagreement.
ok "a missing pin dir is not a disagreement"   "|1" \
   "$( export SHIPYARD_BACKEND=tmux
       out=$( . "$SKILL_DIR/shipyard-backend.sh" >/dev/null 2>&1
              DRV_CONTAINER_PIN_DIR="$T14TMP/nope"
              shipyard_backend_pinned_elsewhere ) || rc=$?
       printf '%s|%s' "$out" "${rc:-0}" )"

# --- unpin clears EVERY backend's pin -------------------------------------------------------
# It runs only after the fleet is PROVEN empty, and a proven-empty fleet has no backend. Leaving
# the other file behind was invisible until this change read those names: a stale `container-agterm`
# would make every later tmux tick report a disagreement with a fleet that no longer exists.
( export SHIPYARD_BACKEND=tmux
  . "$SKILL_DIR/shipyard-backend.sh" >/dev/null 2>&1
  DRV_CONTAINER_PIN_DIR="$PINDIR"
  shipyard_container_unpin ) >/dev/null 2>&1
ok "unpin removes both pins, not just the resolved one" "0" \
   "$(ls -1 "$PINDIR" 2>/dev/null | grep -c 'container-')"

# --------------------------------------------- 2. did the container ANSWER?
# `shipyard_slots`' exit status is the first half of corroboration, and it is a contract two
# callers already depend on — shipyard-down.sh refuses to drop the pin without it. The agterm arm
# used to be a bare pipeline whose status was `sed`'s, i.e. 0 whichever way the tree call went; it
# only worked because both callers happened to set `pipefail`. These cases run WITHOUT pipefail on
# purpose, so a return to that shape reds here rather than waiting for a third caller.
slots_rc() { # <backend> <fake-def> -> "<slots>|<rc>"
  local be="$1" fake="$2" out rc=0
  out=$( set +o pipefail
         export SHIPYARD_BACKEND="$be" SHIPYARD_WORKSPACE=t14ws SHIPYARD_SESSION=t14ex
         . "$SKILL_DIR/shipyard-backend.sh" >/dev/null 2>&1
         eval "$fake"
         shipyard_slots 2>/dev/null ) || rc=$?
  printf '%s|%s' "$(printf '%s' "$out" | tr '\n' ',')" "$rc"
}

# EVERY FAKE IS HOISTED INTO A VARIABLE, and that is not style. Under stock macOS /bin/bash 3.2 a
# single-quoted argument inside `"$( … )"` loses its grouping, so a fake containing `{…,…}` — which
# any JSON tree does — is then BRACE-EXPANDED: `ok` received five arguments, `slots_rc` ran three
# times on fragments, and the intended tree never reached shipyard_slots. Two checks below failed
# on 3.2 and passed on bash 5, which is the worst shape a test can have in this repo: `make test`
# reds on the platform the fleet runs on while ubuntu CI stays green. A `$(…)` on an assignment's
# right-hand side is not brace-expanded, so hoisting fixes it. Keep it that way.
AT_DEAD='agtermctl() { return 1; }'
AT_BADSHAPE='agtermctl() { printf "{\"ok\":false}\n"; }'
AT_EMPTY='agtermctl() { printf "{\"ok\":true,\"result\":{\"tree\":{\"workspaces\":[{\"name\":\"t14ws\",\"sessions\":[]}]}}}\n"; }'
AT_TWO='agtermctl() { printf "{\"ok\":true,\"result\":{\"tree\":{\"workspaces\":[{\"name\":\"t14ws\",\"sessions\":[{\"id\":\"a\",\"name\":\"ship-7\"},{\"id\":\"b\",\"name\":\"ship-8\"}]}]}}}\n"; }'
TM_DEAD='tmux() { echo "error connecting to server" >&2; return 1; }'
TM_ABSENT='tmux() { echo "can'\''t find session: t14ex" >&2; return 1; }'

# agterm: a control socket that does not answer `tree` is NOT an empty workspace.
r=$(slots_rc agterm "$AT_DEAD")
ok "agterm: a dead tree call is a failure, not an empty container" "|1" "$r"
# ...and neither is a tree whose shape fails the assertion inside _shipyard_at_sessions.
r=$(slots_rc agterm "$AT_BADSHAPE")
ok "agterm: a malformed tree is a failure too" "|1" "$r"
# The honest empty answer: a valid tree in which our workspace holds no sessions. THIS is the check
# the brace-expansion bug silently inverted — a mangled fake also yields rc 1, so the two negative
# checks above would have passed vacuously had their fakes carried a comma too.
r=$(slots_rc agterm "$AT_EMPTY")
ok "agterm: a valid tree with no sessions is empty, rc 0" "|0" "$r"
r=$(slots_rc agterm "$AT_TWO")
ok "agterm: sessions are still enumerated" "7,8|0" "$r"

# tmux: a server that cannot be reached fails; a session that is simply absent is honestly empty,
# because a tmux session dying takes its children with it.
r=$(slots_rc tmux "$TM_DEAD")
ok "tmux: an unreachable server is a failure" "|1" "$r"
r=$(slots_rc tmux "$TM_ABSENT")
ok "tmux: an absent session is honestly empty" "|0" "$r"

# --------------------------------------------- 3./4. THE REPORT, EXECUTED
# The rig is t13-wait.sh's: exported shell functions shadow `git`, `tmux` and `gh`, which works
# where a fake binary on PATH does not, because shipyard-lib.sh prepends the system PATH.
FAKE_ROOT="$T14TMP/repo"; FAKE_GIT="$T14TMP/gitdir"; MB="$FAKE_GIT/ship-escalations"
FLAKY="$T14TMP/flaky-calls"
mkdir -p "$FAKE_ROOT/.claude/worktrees/ship-41/.pipeline-state" "$MB"
export FAKE_ROOT FAKE_GIT FLAKY
git() {
  case "${1:-} ${2:-}" in
    "rev-parse --show-toplevel")  printf '%s\n' "$FAKE_ROOT"; return 0 ;;
    "rev-parse --git-common-dir") printf '%s\n' "$FAKE_GIT";  return 0 ;;
    "remote get-url")             printf 'https://github.com/example/example.git\n'; return 0 ;;
  esac
  return 0
}
# TMUX_MODE picks what the backend does this run: `empty` (reachable, no ship windows), `down`
# (the server cannot be reached at all) or `live` (one working child).
#
# The two `-F` formats are answered separately because they are different questions asked by
# different callers: shipyard_slots enumerates with `#{window_name}` alone, while drv_target needs
# `#{window_index} #{window_name}` to build its handle. A fake that answered both with one shape
# silently made the row-building path unreachable, so 4e could not have failed.
tmux() {
  case "${1:-}" in
    list-windows)
      case "${TMUX_MODE:-empty}" in
        down) echo "error connecting to server" >&2; return 1 ;;
        live) case "$*" in *window_index*) printf '1 ship-41\n' ;; *) printf 'ship-41\n' ;; esac ;;
        flaky)
          # Answer the FIRST call (the pre-loop enumeration) and fail every one after it, which is
          # a socket dying while the tick is in its slow per-slot work. The counter lives in a file
          # because each call runs in its own subshell.
          n=$(cat "$FLAKY" 2>/dev/null); n=$(( ${n:-0} + 1 )); printf '%s\n' "$n" >"$FLAKY"
          if [ "$n" = 1 ]; then printf 'ship-41\n'; return 0; fi
          echo "error connecting to server" >&2; return 1 ;;
      esac
      return 0 ;;
    has-session)  [ "${TMUX_MODE:-empty}" = live ] && return 0; return 1 ;;
    capture-pane) printf 'spec review round 2, awaiting the verifier\n'; return 0 ;;
  esac
  return 0
}
gh() { printf 'OPEN\n'; return 0; }
export -f git tmux gh

run_report() { # <tmux-mode> [args...]; prints the report, then a last line "rc=<n>"
  local mode="$1" out rc=0; shift
  : >"$FLAKY"    # the flaky counter is per-run, never carried between cases
  out=$( TMUX_MODE="$mode" SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t14ex \
         bash "$REPORT" "$@" 2>/dev/null ) || rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
rc_of() { printf '%s' "$1" | sed -n 's/^rc=//p' | tail -1; }

rm -f "$MB"/container-*

# --- 3. THE HONEST EMPTY ANSWER STILL ENDS THE WATCH ----------------------------------------
# Checked BEFORE the failure cases on purpose: a fix that simply stopped exiting 0 would pass every
# check in section 4 and break the only way a healthy run terminates.
out=$(run_report empty)
ok "discovery, reachable, nothing there -> exit 0" 0 "$(rc_of "$out")"
ok "...and says so in the old words"               1 "$(printf '%s' "$out" | grep -c 'no live ship terminals')"
ok "...with no alarm"                              0 "$(printf '%s' "$out" | grep -c 'NO SIGNAL')"

# The designed termination: the loop names its slots, the supervisor has torn them all down.
: > "$MB/container-tmux"
out=$(run_report empty 41 42)
ok "named slots, all torn down, backend answered -> exit 0" 0 "$(rc_of "$out")"
ok "...and the monitor is told to stop"                     1 \
   "$(printf '%s' "$out" | grep -c 'nothing in flight (all merged/closed) — monitor stopped')"
ok "...with no alarm"                                       0 "$(printf '%s' "$out" | grep -c 'NO SIGNAL')"

# --- 4. AN UNCORROBORATED EMPTY ANSWER NEVER ENDS THE WATCH ---------------------------------
# 4a. THE INCIDENT ITSELF: the fleet is pinned on agterm, this tick resolved tmux, and the tmux
#     container is empty for entirely correct reasons.
rm -f "$MB"/container-*; : > "$MB/container-agterm"
out=$(run_report empty)
ok "4a: pinned elsewhere -> NOT exit 0"    1 "$(rc_of "$out")"
ok "4a: ...raises the block"               1 "$(printf '%s' "$out" | grep -c '🛑 NO SIGNAL')"
ok "4a: ...naming the fleet's backend"     1 "$(printf '%s' "$out" | grep -c 'this fleet was launched on agterm')"
ok "4a: ...and never claims completion"    0 "$(printf '%s' "$out" | grep -c 'no live ship terminals')"
# The block's CLASS-SELECTED remedy is its only actionable content, and nothing pinned it: with the
# class hardcoded, or the whole `case` deleted, every check above stayed green while an `elsewhere`
# tick told the operator to go and check a socket that is working perfectly.
ok "4a: ...and prescribes the pin, not a socket check" 1 \
   "$(printf '%s' "$out" | grep -c 'SHIPYARD_BACKEND=agterm')"
ok "4a: ...and does NOT prescribe the unreachable remedy" 0 \
   "$(printf '%s' "$out" | grep -c 'agtermctl version')"

# 4b. The backend could not be asked at all. The container pin agrees here, so this is the half a
#     pinned backend would NOT have caught — the socket answers `version` and fails on `tree`.
rm -f "$MB"/container-*; : > "$MB/container-tmux"
out=$(run_report down)
ok "4b: unreachable -> NOT exit 0"         1 "$(rc_of "$out")"
ok "4b: ...raises the block"               1 "$(printf '%s' "$out" | grep -c '🛑 NO SIGNAL')"
ok "4b: ...saying the backend did not answer" 1 \
   "$(printf '%s' "$out" | grep -c 'did not answer when asked which terminals exist')"
ok "4b: ...and prescribes the socket check, not the pin" 1 \
   "$(printf '%s' "$out" | grep -c 'agtermctl version')"
ok "4b: ...and offers the second cause, whose socket answers fine" 1 \
   "$(printf '%s' "$out" | grep -c 'agtermctl tree --json')"

# 4c. THE SECOND ROUTE. Named slots skip the discovery branch entirely, render every row as
#     `⛔ no terminal`, count nothing in flight and reach the tail — an identical false completion
#     by a different code path, which is why it needs its own case rather than a shared assertion.
out=$(run_report down 41 42)
ok "4c: named slots, unreachable -> NOT exit 0" 1 "$(rc_of "$out")"
ok "4c: ...raises the block"                    1 "$(printf '%s' "$out" | grep -c '🛑 NO SIGNAL')"
ok "4c: ...and does NOT print monitor stopped"  0 \
   "$(printf '%s' "$out" | grep -c 'monitor stopped')"
ok "4c: ...and says so where the count used to go" 1 \
   "$(printf '%s' "$out" | grep -c 'cannot tell what is in flight')"

# 4c2. THE SAME ROUTE, THE OTHER CLASS — and this one is the incident's own shape. 4a proves the
#      pin disagreement only at the DISCOVERY exit; the documented Step 2 loop passes slot numbers
#      (`--only-changed <slot> ...`), so the named-slot tail is the PRODUCTION route and was pinned
#      for `unreachable` alone. Measured gap: narrowing the tail guard to `[ "$ENUM_RC" != 0 ]` —
#      i.e. dropping the pin half of corroboration — left the whole suite green while a tmux-
#      resolved tick over an agterm fleet printed "monitor stopped" and exited 0. That is #61
#      verbatim, through the very route the operator actually runs.
rm -f "$MB"/container-*; : > "$MB/container-agterm"
out=$(run_report empty 41 42)
ok "4c2: named slots, pinned elsewhere -> NOT exit 0" 1 "$(rc_of "$out")"
ok "4c2: ...raises the block"                         1 "$(printf '%s' "$out" | grep -c '🛑 NO SIGNAL')"
ok "4c2: ...and does NOT print monitor stopped"       0 \
   "$(printf '%s' "$out" | grep -c 'monitor stopped')"

# 4c3. CORROBORATION IS RE-ASKED, NOT SAMPLED ONCE. The row loop is the slow part of a tick, so a
#      backend that answers the enumeration and dies during it used to leave the pre-loop status
#      stale and reassuring: the tick enumerated a live slot, failed every addr lookup, rendered
#      `⛔ no terminal`, counted nothing in flight and exited 0 — #61 by a timing route. `flaky`
#      serves the first list-windows and fails afterwards, which is exactly that shape.
rm -f "$MB"/container-*; : > "$MB/container-tmux"
out=$(run_report flaky)
ok "4c3: a backend that dies mid-tick -> NOT exit 0"  1 "$(rc_of "$out")"
ok "4c3: ...and does NOT print monitor stopped"       0 \
   "$(printf '%s' "$out" | grep -c 'monitor stopped')"

# 4d. --only-changed must not swallow it, for the reason the STALLED block bypasses the filter:
#     silence is what made the original defect invisible. The first run seeds the signature so the
#     second WOULD be silent on state alone — without that ordering this check cannot fail.
rm -f "$MB/report-sig"
run_report down --only-changed 41 42 >/dev/null
out=$(run_report down --only-changed 41 42)
ok "4d: --only-changed still prints the block" 1 "$(printf '%s' "$out" | grep -c '🛑 NO SIGNAL')"
ok "4d: ...and still refuses to exit 0"        1 "$(rc_of "$out")"
# The control, and it must use a LIVE slot: a terminal report is always printed by design, so a
# torn-down fleet cannot show that --only-changed still works. With a child in flight and the pin
# agreeing, an identical repeat has nothing to say — which is what makes 4d evidence about the
# alarm rather than about the filter having quietly stopped working.
rm -f "$MB"/container-*; : > "$MB/container-tmux"; rm -f "$MB/report-sig"
run_report live --only-changed 41 >/dev/null
out=$(run_report live --only-changed 41)
ok "4d: a corroborated repeat is still silent"  0 "$(printf '%s' "$out" | grep -c 'ship status')"

# 4e. The header names the resolved backend whenever it differs, on every such tick and not only on
#     the ones that refuse — in the incident the header was the only visible trace of the swap, and
#     nobody reads a header for a word that is normally constant. A live slot, so the table prints.
rm -f "$MB"/container-*; : > "$MB/container-agterm"
out=$(run_report live)
ok "4e: the header flags the disagreement"  1 \
   "$(printf '%s' "$out" | grep -c 'but this fleet was launched on `agterm`')"
ok "4e: ...and live work still exits 1"     1 "$(rc_of "$out")"
ok "4e: ...without the NO SIGNAL block, which is only about an EMPTY answer" 0 \
   "$(printf '%s' "$out" | grep -c 'NO SIGNAL')"

if [ "$FAILURES" -eq 0 ]; then
  printf 't14-signal: %d checks, all passed\n' "$CHECKS"; exit 0
fi
printf 't14-signal: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"; exit 1
