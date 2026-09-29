#!/usr/bin/env bash
# t20-mailbox-fifo.sh — a FIFO planted in the shared mailbox cannot hang shipyard's writers or its
# glob readers (#253). Council's half is its t29; this is the same defect on shipyard's side.
#
# Every child can write `.git/ship-escalations/`, and shipyard's scripts used to open paths in it
# with a plain `>` and hand every glob match to jq. A FIFO in place of any of them blocked the open
# for as long as nothing read it: the report tick never returned and the monitor went quiet about
# the whole fleet, and a directive was never typed. Each case below plants a FIFO where a writer
# writes or where a glob reads, runs the script under a bound, and asserts that it RETURNED and
# still produced what it is for.
#
# Case 7 is the FIFO's neighbour (#197): a record jq cannot PARSE, which every reader used to skip
# in silence. Each reader must now name it, and must not let it cost another record its line.
#
# The rig is t13's and t16's: exported shell functions shadow `git` and `tmux`, which works where a
# fake binary on PATH does not, because shipyard-lib.sh prepends the system PATH.
#
# NOT COVERED, named so a green run is not read as more:
#   * the read residual #246 deferred — a regular file swapped for a FIFO between a reader's
#     `[ -f ]` and its open. A race inside a few instructions that no fixture can hit on purpose;
#     it is named at each reader and in SKILL.md.
#   * `shipyard-ask.sh`'s entry write: its `-e` probe steps over a FIFO already at the next free
#     name (case 6 pins that), so only a FIFO swapped in after the probe reaches the write, and this
#     file plants none there. `shipyard-answer.sh`'s old temp name was `$F.tmp.$$`, which this
#     file does not predict. Both writes now go through policy_mailbox_write, covered directly by
#     shared/policy's t-policy.
#   * `slot_unsettled` / `slot_unsettled_files` (the teardown hold) run only on the merged-slot
#     path; their non-regular-file arm is not driven here.
#   * the `[ -f ]` in ask's `answer_of` and in `shipyard_json_set`: each is reached only by a FIFO
#     swapped in over a record that was regular a moment earlier (during `--wait`'s sleep, or
#     between a caller's own check and the update). Not driven here, though it could be: the
#     shadowed `tmux capture-pane` runs inside tell's confirm loop, after its record is written and
#     before the delivery update, so it could swap the record for a FIFO; a shadowed `sleep` would
#     do the same for `--wait`.
#   * the launcher's writes (protocol, launcher, launch record): no test drives
#     shipyard-launch.sh end to end (t9 says the same), so they are covered only by reading.
#
# MUTATION CHECK, run by hand when this file changes: put back a plain `>` for any report-* write,
# the tell `.txt` write, or drop the `[ -f ]` prefilter from slot_pending, shipyard-escalations.sh,
# `shipyard-answer.sh --list` or `shipyard-tell.sh --list`, and that site's case reports HUNG.
set -uo pipefail
export LC_ALL=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$DIR/.." && pwd)"
REPORT="$SKILL_DIR/shipyard-report.sh"
TELL="$SKILL_DIR/shipyard-tell.sh"
ESC="$SKILL_DIR/shipyard-escalations.sh"
ANSWER="$SKILL_DIR/shipyard-answer.sh"
ASK="$SKILL_DIR/shipyard-ask.sh"

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}
# Reads the whole input rather than `grep -q`, which under pipefail can report a SIGPIPE'd writer.
has() { case "$1" in *"$2"*) printf yes ;; *) printf no ;; esac; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/t20-mailbox-fifo.XXXXXXXX") || exit 1
FAKE_ROOT="$TMP/repo"; FAKE_GIT="$TMP/gitdir"; MB="$FAKE_GIT/ship-escalations"
mkdir -p "$FAKE_ROOT/.claude/worktrees/ship-41/.pipeline-state" "$MB"
printf '{"pr_number":901,"state":"impl-review"}\n' >"$FAKE_ROOT/.claude/worktrees/ship-41/.pipeline-state/PR-901.json"
: > "$MB/container-tmux"
export FAKE_ROOT FAKE_GIT

git() {
  case "${1:-} ${2:-}" in
    "rev-parse --show-toplevel")  printf '%s\n' "$FAKE_ROOT"; return 0 ;;
    "rev-parse --git-common-dir") printf '%s\n' "$FAKE_GIT";  return 0 ;;
    "remote get-url")             printf 'https://github.com/example/example.git\n'; return 0 ;;
  esac
  return 0
}
tmux() {
  case "${1:-}" in
    list-windows) case "$*" in *window_index*) printf '1 ship-41\n' ;; *) printf '1 ship-41\n' ;; esac; return 0 ;;
    has-session)  return 0 ;;
    capture-pane) printf '⏺ impl review round 1, awaiting the verifier\n' ; return 0 ;;
  esac
  return 0
}
gh() { printf 'OPEN\n'; return 0; }
export -f git tmux gh

FIFOS=()
plant() { rm -rf "$1"; mkfifo "$1" && FIFOS+=("$1"); } # <path>
# Unblock and remove everything planted so far, after every case, so each case stands alone: a FIFO
# left by one would hang the next on the old code and the mutation check could not name the site.
unplant() {
  local f
  if [ "${#FIFOS[@]}" -gt 0 ]; then
    for f in "${FIFOS[@]}"; do [ -p "$f" ] && { : <>"$f"; rm -f "$f"; }; done
  fi
  FIFOS=()
}
trap 'unplant; rm -rf "$TMP"' EXIT

# bounded <secs> <cmd>... — the command's output then `rc=<n>`, or `HUNG` when it had not returned
# within <secs>. No timeout(1): stock macOS ships none. A hung run leaves a descendant blocked in
# open(2) that killing the job does not reach, so every planted FIFO is then opened read-write once,
# which pairs with the blocked opener and lets it finish instead of outliving the suite.
BOUND_OUT="$TMP/bounded.out"
bounded() {
  local secs="$1" pid i=0 f; shift
  "$@" >"$BOUND_OUT" 2>&1 & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge $(( secs * 10 )) ]; then
      kill "$pid" 2>/dev/null
      if [ "${#FIFOS[@]}" -gt 0 ]; then
        for f in "${FIFOS[@]}"; do [ -p "$f" ] && : <>"$f"; done
      fi
      wait "$pid" 2>/dev/null
      printf 'HUNG'
      return 0
    fi
    sleep 0.1; i=$((i + 1))
  done
  wait "$pid"; i=$?
  cat "$BOUND_OUT"; printf '\nrc=%s' "$i"
}
returned() { case "$1" in *HUNG) printf no ;; *) printf yes ;; esac; }
regular() { [ -f "$1" ] && [ ! -p "$1" ] && printf yes || printf no; }
# The bound tells a hung opener from a slow one, and a hung opener never returns, so any finite
# bound separates them: it costs its full length only on a real hang. 20 s was once exceeded by a
# case that passed alone, under a full parallel run, so it is sized for a loaded box, not a quiet one.
# What a real hang costs is the bound once per bounded call, so a regression that hangs every
# opener takes this file minutes, not seconds, to red. It still reds.
SECS=60

report() {
  SHIPYARD_MOTION_INTERVAL=0.01 SHIPYARD_STALL_SECS=100000 SHIPYARD_AUTODOWN=0 \
    SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t20ex bash "$REPORT" "$@" 41
}

# --- 1. every report-* file the tick writes ------------------------------------------------------
printf '\n── report writes ──\n'
report >/dev/null 2>&1   # seed: the stall table only exists once a tick has rendered a row
for name in report-sig report-stall report-tick report-merged report-episodes; do
  plant "$MB/$name"
  o=$(bounded "$SECS" report)
  ok "a FIFO at $name: the report returns"   yes "$(returned "$o")"
  ok "...and prints the table"               yes "$(has "$o" '| 41 |')"
  ok "...and $name is a regular file again"  yes "$(regular "$MB/$name")"
  unplant
done

# --- 2. the glob slot_pending counts -------------------------------------------------------------
printf '\n── report glob read ──\n'
plant "$MB/41-9.json"
o=$(bounded "$SECS" report)
ok "a FIFO matching the slot's escalation glob: the report returns" yes "$(returned "$o")"
ok "...and prints the table"                                          yes "$(has "$o" '| 41 |')"
unplant

# A real pending escalation beside it, for the viewers below.
printf '{"id":"41-1","slot":"41","kind":"question","text":"which one","status":"pending","notified":false}\n' >"$MB/41-1.json"

# --- 3. shipyard-escalations.sh ------------------------------------------------------------------
printf '\n── escalations viewer ──\n'
plant "$MB/41-8.json"
o=$(bounded "$SECS" bash "$ESC")
ok "a FIFO matching the mailbox glob: the viewer returns" yes "$(returned "$o")"
ok "...and still shows the real escalation"              yes "$(has "$o" '41-1')"
unplant

# --- 4. shipyard-answer.sh --list and the answer write --------------------------------------------
printf '\n── answer ──\n'
plant "$MB/41-8.json"
o=$(bounded "$SECS" bash "$ANSWER" --list)
ok "a FIFO matching the glob: --list returns" yes "$(returned "$o")"
ok "...and lists the real escalation"         yes "$(has "$o" '41-1')"
unplant
o=$(bounded "$SECS" bash "$ANSWER" --no-tell 41-1 "take the first")
ok "the answer is written"                    yes "$(has "$o" 'answered 41-1')"
ok "...onto the record"                       answered "$(jq -r .status "$MB/41-1.json" 2>/dev/null)"
ok "...leaving no temp file behind"           0 "$(ls -A "$MB" | grep -c 'tmp\|policy-write')"

# --- 5. shipyard-tell.sh: the directive's .txt, which the -e probe never looked at ----------------
printf '\n── tell ──\n'
tell() {
  SHIPYARD_TELL_SETTLE_DELAY=0.01 SHIPYARD_TELL_CONFIRM_SECS=1 SHIPYARD_TELL_CONFIRM_INTERVAL=0.2 \
    SHIPYARD_MOTION_INTERVAL=0.01 SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t20ex \
    bash "$TELL" "$@"
}
plant "$MB/directive-41-1.txt"
o=$(bounded "$SECS" tell 41 "a directive")
ok "a FIFO at the directive's .txt: tell returns" yes "$(returned "$o")"
ok "...and records the directive"                 yes "$(regular "$MB/directive-41-1.json")"
# Guarded: on the old code the FIFO is still there, and a bare `cat` of it would hang the suite.
ok "...with its text in the .txt"                 "a directive" \
   "$([ "$(regular "$MB/directive-41-1.txt")" = yes ] && cat "$MB/directive-41-1.txt")"
unplant
plant "$MB/directive-99-1.json"
o=$(bounded "$SECS" tell --list)
ok "a FIFO matching the directive glob: --list returns" yes "$(returned "$o")"
ok "...and lists the real directive"                    yes "$(has "$o" 'directive-41-1')"
unplant

# --- 6. shipyard-ask.sh: a FIFO at the next free name is stepped over ----------------------------
printf '\n── ask ──\n'
plant "$MB/41-2.json"
o=$(SHIPYARD_SLOT=41 bounded "$SECS" bash "$ASK" --kind notice "a milestone")
ok "a FIFO at the next free id: ask returns" yes "$(returned "$o")"
ok "...and lands on the id after it"         yes "$(regular "$MB/41-3.json")"
unplant

# --- 7. a record jq cannot READ is shown, not skipped (#197) -------------------------------------
# The FIFO's neighbour: a peer-written file that every reader used to skip in silence. The readers'
# filter printed an empty string for a truncated record, for one that is not JSON and for an empty
# file, and the allow-list took that for "a record of another kind" — so a corrupted question
# vanished from every view while its child waited. Each reader must now name it, and must not let
# it cost any OTHER record its line.
printf '\n── unreadable records ──\n'
printf '{"id":"41-10","slot":"41","kind":"question","text":"still here","status":"pending","notified":false}\n' >"$MB/41-10.json"
printf '{"kind":"question","status":"pending"' >"$MB/41-5.json"   # truncated
printf 'not json at all\n' >"$MB/41-6.json"
: >"$MB/41-7.json"                                               # empty: jq prints nothing, exits 0
o=$(bounded "$SECS" bash "$ESC")
ok "the full view names a truncated record"      yes "$(has "$o" 'unreadable record] `41-5.json`')"
ok "...and a non-JSON one"                       yes "$(has "$o" 'unreadable record] `41-6.json`')"
ok "...and an empty one"                         yes "$(has "$o" 'unreadable record] `41-7.json`')"
ok "...and still shows the real question"        yes "$(has "$o" '41-10')"
ok "...and the unreadable one is no question"    0   "$(printf '%s' "$o" | grep -c '\[question\] `41-5`')"
# --new: once each, then silent; the full view stays the backstop.
o=$(bounded "$SECS" bash "$ESC" --new)
ok "--new pushes the unreadable records"         yes "$(has "$o" 'unreadable record] `41-6.json`')"
o=$(bounded "$SECS" bash "$ESC" --new)
ok "...once: the next --new is silent"           "rc=0" "$(printf '%s' "$o" | tr -d '\n')"
printf 'broken differently\n' >"$MB/41-6.json"
o=$(bounded "$SECS" bash "$ESC" --new)
ok "a record rewritten into other bytes is news again" yes "$(has "$o" 'unreadable record] `41-6.json`')"
ok "...alone"                                    no  "$(has "$o" '41-5.json')"
o=$(bounded "$SECS" bash "$ESC")
ok "the full view still shows all of them"       yes "$(has "$o" '41-5.json')"
# A forged seen-file decides nothing about a readable record.
printf 'garbage\n%s\n' "$(printf '41-11.json\tx')" >"$MB/report-unreadable"
printf '{"id":"41-11","slot":"41","kind":"question","text":"new one","status":"pending","notified":false}\n' >"$MB/41-11.json"
o=$(bounded "$SECS" bash "$ESC" --new)
ok "a forged seen-file cannot hide a new question" yes "$(has "$o" '41-11')"
# The name is written by whoever wrote the file: it must not forge a line of its own.
bad_name=$(printf '41-12\n### forged')
printf 'x' >"$MB/$bad_name.json"
o=$(bounded "$SECS" bash "$ESC")
ok "a crafted name cannot start a line"          0   "$(printf '%s' "$o" | grep -c '^### forged')"
rm -f "$MB/$bad_name.json"
o=$(bounded "$SECS" bash "$ANSWER" --list)
ok "answer --list gives it a row"                yes "$(has "$o" 'UNREADABLE')"
o=$(bounded "$SECS" bash "$ANSWER" --no-tell 41-5 "an answer")
ok "answering it says why it cannot"             yes "$(has "$o" 'cannot be read as a record')"
ok "...and fails"                                yes "$(has "$o" 'rc=1')"
printf 'junk' >"$MB/directive-41-9.json"
o=$(bounded "$SECS" tell --list)
ok "tell --list gives a bad directive a row"     yes "$(has "$o" 'UNREADABLE')"
rm -f "$MB/directive-41-9.json"
o=$(bounded "$SECS" report)
# The whole cell: the mark is added beside the pending count, never in its place.
ok "the report's esc column marks the slot"      yes "$(has "$o" '| ⚠️ 2 ❓ 3 |')"
ok "...and the report appends the names"         yes "$(has "$o" 'unreadable record] `41-5.json`')"
# A record whose valid JSON is followed by garbage: jq prints the prefix before failing, and that
# prefix must not count it as pending as well as unreadable.
printf '{"id":"41-8","slot":"41","kind":"question","status":"pending"} x' >"$MB/41-8.json"
o=$(bounded "$SECS" report)
ok "trailing garbage counts once, as unreadable" yes "$(has "$o" '| ⚠️ 2 ❓ 4 |')"
# Two objects in one file: every reader's filter prints two lines and matches nothing, so unless
# it is called unreadable it is counted nowhere at all.
printf '{"kind":"question","status":"pending"}{"kind":"question","status":"pending"}' >"$MB/41-9.json"
o=$(bounded "$SECS" report)
ok "two objects in one file count as unreadable"  yes "$(has "$o" '| ⚠️ 2 ❓ 5 |')"
rm -f "$MB/41-5.json" "$MB/41-6.json" "$MB/41-7.json" "$MB/41-8.json" "$MB/41-9.json"
# Once every unreadable record is gone the seen-file forgets them, so the same bytes coming back —
# an empty file, whose checksum never changes — are pushed again.
bounded "$SECS" bash "$ESC" --new >/dev/null
: >"$MB/41-7.json"
o=$(bounded "$SECS" bash "$ESC" --new)
ok "a record repaired then broken again is pushed again" yes "$(has "$o" 'unreadable record] `41-7.json`')"
rm -f "$MB/41-7.json"

if [ "$FAILURES" -eq 0 ]; then printf 't20-mailbox-fifo: %d checks, all passed\n' "$CHECKS"; exit 0; fi
printf 't20-mailbox-fifo: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"; exit 1
