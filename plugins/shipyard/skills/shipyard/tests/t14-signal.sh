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
#      closed, and silent in the opposite direction;
#   4. THE SAME DISTINCTION PER SLOT (section 5). `shipyard-tell.sh` and `shipyard-compact.sh` read
#      one slot's missing terminal as a dead child, which is the same inference over the same two
#      facts — so they classify through the same function, and each maps the answer onto its own
#      exit (3 gone, 7 unresolved). A supervisor told "gone" tears the slot down, so this door out
#      of the defect ends in a destructive act rather than in silence.
#
# Section 4 executes the real script, for the reason t13-wait.sh measured: `grep -Fc` over source
# lines asserts that a line exists and nothing about reachability or branch bodies, and six of
# seven semantic mutations survived that idiom.
#
# COST: five report RUNS across three cases (4d's control twice, 4e, 4e2 twice) use a LIVE slot and
# so pay the report's 3s motion diff each; measured 14-16s for the file, varying with machine and
# load. That is why it sits in `make test` and not the per-commit gate. The live runs are not
# optional — a torn-down fleet always prints a terminal report, so only a slot in flight can show
# that --only-changed still filters at all.
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

# --- unpin clears ONLY the backend it proved empty -------------------------------------------
# THE REGRESSION THIS PINS was written by this very change and had to be reverted twice. Reading a
# pin's NAME as evidence makes a leftover pin look like litter, so unpin was widened to clear every
# backend's — which deletes the evidence the report reads and lets the next blip exit 0 over live
# children. What the caller proved is that the backend it RESOLVED is empty; it learned nothing
# about the other one, so the other one's pin must survive. Both directions, because a rule that
# holds in one is not a rule.
unpin_leaves() { # <resolved backend> -> what is still pinned, sorted
  ( export SHIPYARD_BACKEND="$1"
    . "$SKILL_DIR/shipyard-backend.sh" >/dev/null 2>&1
    DRV_CONTAINER_PIN_DIR="$PINDIR"
    shipyard_container_unpin ) >/dev/null 2>&1
  ls -1 "$PINDIR" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//'
}

rm -f "$PINDIR"/container-*; : > "$PINDIR/container-agterm"
ok "unpin resolved as tmux leaves the agterm pin alone" "container-agterm" "$(unpin_leaves tmux)"
ok "...and resolved as agterm then clears it"           ""                 "$(unpin_leaves agterm)"
rm -f "$PINDIR"/container-*; : > "$PINDIR/container-tmux"
ok "unpin resolved as agterm leaves the tmux pin alone"  "container-tmux"  "$(unpin_leaves agterm)"
ok "...and resolved as tmux then clears it"              ""                "$(unpin_leaves tmux)"
# Both pinned: still only the proved-empty one goes. This is the case whose first patch was
# circular — the other pin looks invisible to the disagreement check only while this one sits
# beside it, and this call is about to remove that.
rm -f "$PINDIR"/container-*; : > "$PINDIR/container-agterm"; : > "$PINDIR/container-tmux"
ok "both pinned: unpin still clears only the resolved one" "container-agterm" "$(unpin_leaves tmux)"
rm -f "$PINDIR"/container-*

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
# ...and neither is a tree whose shape fails the assertion inside `drv_sessions` (shared/driver,
# where the agterm arm moved when council became a second caller).
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
        blip)
          # The NARROWER shape: answer the enumeration, fail only the row loop's lookup, then
          # recover in time for the tail's re-ask. The status alone says "corroborated" and the
          # tick would stop the loop — while the re-ask is listing the slot it just called gone.
          n=$(cat "$FLAKY" 2>/dev/null); n=$(( ${n:-0} + 1 )); printf '%s\n' "$n" >"$FLAKY"
          if [ "$n" = 2 ]; then echo "error connecting to server" >&2; return 1; fi
          case "$*" in *window_index*) printf '1 ship-41\n' ;; *) printf 'ship-41\n' ;; esac ;;
        halfblind)
          # The per-slot form of `blip`, and it needs no call counter because the two questions have
          # DIFFERENT SHAPES: drv_target asks with `#{window_index} #{window_name}` and
          # shipyard_slots with `#{window_name}` alone, so failing only the former reproduces a
          # per-slot lookup failing while the enumeration answers — deterministically, whatever
          # order the calls happen in.
          case "$*" in
            *window_index*) echo "error connecting to server" >&2; return 1 ;;
            *)              printf 'ship-41\n' ;;
          esac ;;
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
# Presence, not a line COUNT. The class-remedy checks below are about whether a piece of advice was
# printed at all; counting lines makes them assert how the prose happens to wrap, so re-flowing a
# sentence onto two lines reds a check whose property never changed. That already happened once.
has() { printf '%s' "$1" | grep -q -- "$2" && printf yes || printf no; }

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
ok "4a: ...and prescribes the pin, not a socket check"    yes "$(has "$out" 'SHIPYARD_BACKEND=agterm')"
# BOTH halves of the unreachable remedy, not just the first: the second-cause line leaking into
# this arm would tell an operator whose socket is demonstrably healthy to go and inspect the tree,
# which is the misdirection the per-class assertions exist to prevent.
ok "4a: ...and does NOT prescribe the unreachable remedy" no  "$(has "$out" 'agtermctl version')"
ok "4a: ...nor its second cause"                         no  "$(has "$out" 'agtermctl tree --json')"

# 4b. The backend could not be asked at all. The container pin agrees here, so this is the half a
#     pinned backend would NOT have caught — the socket answers `version` and fails on `tree`.
rm -f "$MB"/container-*; : > "$MB/container-tmux"
out=$(run_report down)
ok "4b: unreachable -> NOT exit 0"         1 "$(rc_of "$out")"
ok "4b: ...raises the block"               1 "$(printf '%s' "$out" | grep -c '🛑 NO SIGNAL')"
ok "4b: ...saying the backend did not answer" 1 \
   "$(printf '%s' "$out" | grep -c 'did not answer when asked which terminals exist')"
ok "4b: ...and prescribes the socket check, not the pin"  yes "$(has "$out" 'agtermctl version')"
ok "4b: ...and offers the second cause, whose socket answers fine" yes \
   "$(has "$out" 'agtermctl tree --json')"
ok "4b: ...and does NOT prescribe the elsewhere remedy"   no  "$(has "$out" 'SHIPYARD_BACKEND=')"

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
# ANCHOR THE FIXTURE, or this case can go vacuous without saying so: rc 1 and no "monitor stopped"
# are also what plain `down` produces, so a fake that stopped answering the FIRST call would turn
# 4c3 into a duplicate of 4b while still looking like it guards the timing route. Asserting the row
# proves the tick really did enumerate the slot before the backend went away.
ok "4c3: ...having really enumerated the slot first"  yes "$(has "$out" '^| 41 .*⛔ no terminal')"

# 4c4. THE NARROWER BLIP, and it is why the re-ask keeps its ANSWER and not just its status. Here
#      the backend fails only the row-loop lookup and has recovered by the tail, so the status says
#      "corroborated" while the very same call lists the slot this tick just rendered `⛔ no
#      terminal`. Reproduced before the fix: rc 0 and "monitor stopped" over a live child. The
#      contradiction is the evidence, and it is matched PER SLOT — a bare "the list is non-empty"
#      test would let an unrelated ship-* terminal block the designed termination forever.
out=$(run_report blip)
ok "4c4: enumerated but unresolvable -> NOT exit 0"   1 "$(rc_of "$out")"
ok "4c4: ...and does NOT print monitor stopped"       0 \
   "$(printf '%s' "$out" | grep -c 'monitor stopped')"
ok "4c4: ...and names the contradiction"              yes "$(has "$out" 'still listed by the backend')"
ok "4c4: ...having rendered that very slot as gone"   yes "$(has "$out" '^| 41 .*⛔ no terminal')"

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

# 4e2. A disagreement is news on EVERY tick it holds, not once. It is kept out of the --only-changed
#      signature and put in the suppression condition for exactly that reason, and without this case
#      removing that clause left the whole suite green: 4e runs without --only-changed, so nothing
#      exercised the filter against a standing disagreement. The first run seeds the signature, so
#      the second would be silent on state alone.
rm -f "$MB/report-sig"
run_report live --only-changed 41 >/dev/null
out=$(run_report live --only-changed 41)
ok "4e2: a standing disagreement re-announces on every tick" 1 \
   "$(printf '%s' "$out" | grep -c 'but this fleet was launched on `agterm`')"

# --------------------------------------------- 5. THE SAME QUESTION, ONE SLOT AT A TIME
# PROVENANCE. `shipyard-tell.sh` and `shipyard-compact.sh` resolve ONE slot's terminal and, finding
# none, both said "the child is gone" — the inference section 4 refuses one level up, reached
# through a different door. `shipyard_target` resolves against whatever backend THIS process picked,
# and `auto` picks per process, so during a socket blip the fact established is "no terminal on the
# backend I resolved". A supervisor told its child died tears the slot down or relaunches it, and
# teardown takes the worktree with it — so this one ends in a destructive action rather than in
# silence.
#
# Executed, not grepped, for t13-wait.sh's reason: a `grep -Fc` over source lines asserts that a
# line exists and nothing about which branch reaches it.
#
# The three classes are already unit-tested above (sections 1 and 2 own the two facts they rest on);
# what sections 5a-5d add is that each script MAPS them onto a distinct exit and distinct words.
TELL="$SKILL_DIR/shipyard-tell.sh"
COMPACT="$SKILL_DIR/shipyard-compact.sh"

run_script() { # <script> <tmux-mode> -> combined output, then a last line "rc=<n>"
  local script="$1" mode="$2" out rc=0
  out=$( TMUX_MODE="$mode" SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t14ex \
         bash "$script" 41 "a directive" 2>&1 ) || rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}

# 5a. THE CORROBORATED ABSENCE STILL READS AS A DEATH, and it is checked first for section 3's
#     reason: a fix that simply stopped saying "gone" would pass every case below while removing
#     the answer an operator needs on the commonest path — a child that really was torn down.
rm -f "$MB"/container-*; : > "$MB/container-tmux"
out=$(run_script "$TELL" empty)
ok "5a: backend answered, slot absent -> exit 3" 3   "$(rc_of "$out")"
ok "5a: ...and says the child is gone"           yes "$(has "$out" 'the child is gone')"
ok "5a: ...naming the backend that answered"     yes "$(has "$out" 'the tmux backend answered')"

# 5b. THE INCIDENT, per slot: the fleet is on agterm, this run resolved tmux, and the tmux
#     container is empty for entirely correct reasons. The backend ANSWERED, so section 2's half of
#     corroboration is satisfied and only the pin can catch this one.
rm -f "$MB"/container-*; : > "$MB/container-agterm"
out=$(run_script "$TELL" empty)
ok "5b: pinned elsewhere -> exit 7, not 3"       7   "$(rc_of "$out")"
ok "5b: ...and refuses to call the child gone"   no  "$(has "$out" 'the child is gone')"
ok "5b: ...saying instead that it cannot tell"   yes "$(has "$out" 'cannot tell whether')"
ok "5b: ...and warning off the teardown"         yes "$(has "$out" 'do NOT tear')"
# The remedy must name the backend to pin, not just that one exists: "pin it" with no value is an
# instruction the operator cannot follow without reading the source.
ok "5b: ...with the pin to set"                  yes "$(has "$out" 'SHIPYARD_BACKEND=agterm')"

ok "5b: ...and not the OTHER class's remedy"     no  "$(has "$out" 'agtermctl version')"

# 5c. The other half: the backend did not answer at all. No pin disagreement here, so this case
#     fails if reachability is ever dropped in favour of the pin check alone.
rm -f "$MB"/container-*; : > "$MB/container-tmux"
out=$(run_script "$TELL" down)
ok "5c: unreachable backend -> exit 7"           7   "$(rc_of "$out")"
ok "5c: ...and refuses to call the child gone"   no  "$(has "$out" 'the child is gone')"
ok "5c: ...naming what went unanswered"          yes "$(has "$out" 'did not answer when asked')"
# THE CLASS-SELECTED REMEDY IS THE ONLY ACTIONABLE CONTENT, and asserting the class alone leaves
# its whole `case` arm deletable with the suite green — the lines above all print BEFORE the case.
# 4a/4b pin their remedies in both directions for exactly this reason; 5b pinned its counterpart
# and this one did not, so the arm an operator with a dead backend depends on was unguarded.
ok "5c: ...and prescribes the backend check"     yes "$(has "$out" 'agtermctl version')"
ok "5c: ...and not the OTHER class's remedy"     no  "$(has "$out" 'SHIPYARD_BACKEND=agterm')"

# 5e. THE NARROWEST BLIP, and the one that survived the first version of this fix: `drv_target`
#     makes its OWN backend call, so it can fail while the enumeration answers — and then both
#     corroborating facts agree and a slot the backend HAS JUST LISTED is called gone, at exit 3,
#     which Step 4 sends to recovery. Keeping the enumeration's ANSWER and not merely its status is
#     what catches it; `shipyard-report.sh` guards the same contradiction one level up (4c4), and
#     this is its per-slot twin. Reproduced against the pre-fix code as exit 3 + "the child is gone".
rm -f "$MB"/container-*; : > "$MB/container-tmux"
out=$(run_script "$TELL" halfblind)
ok "5e: listed but unresolvable -> exit 7"       7   "$(rc_of "$out")"
ok "5e: ...and refuses to call the child gone"   no  "$(has "$out" 'the child is gone')"
ok "5e: ...naming the contradiction"             yes "$(has "$out" 'still lists ship-41')"
# The fixture must really be half-blind, or 5e silently degrades into a duplicate of 5c: a fake
# that failed BOTH forms would also yield rc 7, from `unreachable`, while looking like this case.
ok "5e: ...from the listed class, not unreachable" no "$(has "$out" 'did not answer when asked')"
out=$(run_script "$COMPACT" halfblind)
ok "5e: compact reaches it too -> exit 7"        7   "$(rc_of "$out")"

# 5d. `shipyard-compact.sh` reaches the same refusal through its own exit mapping — a separate line
#     of code making the identical claim, which is why it is asserted separately rather than assumed
#     from the shared helper. Both directions, because a split that holds in one is not a split.
rm -f "$MB"/container-*; : > "$MB/container-tmux"
out=$(run_script "$COMPACT" empty)
ok "5d: compact, corroborated absence -> exit 3" 3   "$(rc_of "$out")"
ok "5d: ...and says the child is gone"           yes "$(has "$out" 'the child is gone')"
rm -f "$MB"/container-*; : > "$MB/container-agterm"
out=$(run_script "$COMPACT" empty)
ok "5d: compact, pinned elsewhere -> exit 7"     7   "$(rc_of "$out")"
ok "5d: ...and refuses to call the child gone"   no  "$(has "$out" 'the child is gone')"

# 5f. THE CALLER THAT BRANCHES ON THE EXIT, which had no executed test of any kind. `answer.sh`
#     shells out to tell.sh and splits its status three ways (0 / 6 / else). A new code landing in
#     that `else` is not a wording problem: the arm stamps `.status="answered"`, and `.status` is
#     what the branch gate tests, so a CONSUMED record answered during a blip stops being routed
#     through the terminal at all. Following exit 7's own remedy — clear the backend, re-run — then
#     delivers NOTHING to a live child while printing a ~5s pickup. Measured end to end before the
#     fix; the pair below is that measurement, and it is why the arm returns before the write.
ANSWER="$SKILL_DIR/shipyard-answer.sh"
REC="$MB/41-9.json"
new_record() {  # a `decision` the child has already consumed — the case SKILL.md Step 4 names
  printf '%s\n' '{"id":"41-9","slot":"41","kind":"decision","text":"t","status":"done","answer":null}' >"$REC"
}
run_answer() {  # <tmux-mode> -> combined output, then "rc=<n>"
  local mode="$1" out rc=0
  out=$( TMUX_MODE="$mode" SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t14ex \
         bash "$ANSWER" 41-9 "the decision" 2>&1 ) || rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
status_of() { jq -r '.status' "$REC" 2>/dev/null; }

rm -f "$MB"/container-*; : > "$MB/container-agterm"      # pinned elsewhere -> tell.sh exits 7
new_record
out=$(run_answer empty)
ok "5f: answer.sh surfaces the unresolved slot as 7"  7      "$(rc_of "$out")"
# `nobody is going to read this` and not `could not be reached`: the latter is WRAPPED across two
# echo calls (`...and could` / `not be reached, so...`), so a single-line grep for it can never
# match and the check would pass with the whole arm deleted. Caught by mutating the arm out — which
# is the only thing that distinguishes a guard from a decoration.
ok "5f: ...and does NOT claim nobody will read it"   no      "$(has "$out" 'nobody is going to read this')"
# THE LOAD-BEARING ONE. If the record is stamped `answered` here, the re-run below cannot work —
# and nothing in the output would say so.
ok "5f: ...leaving the record untouched for the re-run" done "$(status_of)"

# The remedy actually working is the property, not just the refusal being printed: same command,
# backend question cleared, child live -> it must reach the terminal. Without 5f's first half this
# check passes vacuously (a fresh record would route through anyway), so the two are one case.
rm -f "$MB"/container-*; : > "$MB/container-tmux"
rm -f "$MB"/directive-41-*.json "$MB"/directive-41-*.txt
out=$(run_answer live)
ok "5f: ...and the re-run then reaches the child"     0      "$(rc_of "$out")"
ok "5f: ...having really sent a directive"            yes    "$(ls "$MB"/directive-41-*.json >/dev/null 2>&1 && printf yes || printf no)"
rm -f "$REC" "$MB"/directive-41-*.json "$MB"/directive-41-*.txt
rm -f "$MB"/container-*

if [ "$FAILURES" -eq 0 ]; then
  printf 't14-signal: %d checks, all passed\n' "$CHECKS"; exit 0
fi
printf 't14-signal: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"; exit 1
