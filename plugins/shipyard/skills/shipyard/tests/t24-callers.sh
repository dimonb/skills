#!/usr/bin/env bash
# t24-callers.sh — the caller scripts' delivery contract, driven end to end (#119).
#
# PROVENANCE. `shared/adapters` holds the turn-state read and the delivery verdict as pure
# functions, and its suite asserts them. What the CALLERS do with the answer — the exit code a
# supervisor acts on, the field written onto the mailbox record, the sentence an operator reads, the
# guard that keeps compaction from interrupting a live turn — was asserted by nothing. Measured when
# #119 was filed: inverting compact's mid-turn guard, turning tell's `exit 6` into `exit 0`,
# deleting tell's pre-send sample and deleting answer.sh's exit-6 branch each left every suite
# green. Each of those four is a kill test for a check below, and each was re-run as a mutation when
# this file landed.
#
# WHAT THIS FILE PINS:
#   A. tell: `delivered` and `queued` are exit 0, `unconfirmed` is exit 6, and each verdict is the
#      `delivery` field tell writes onto its directive record; the unconfirmed warning carries the
#      sampled census; a verdict the shared module did not produce is exit 1, never success; the
#      "(in reply to …)" line is a directive's, never a `--submit`'s; a record's peer-written
#      `.slot` is refused after the escalation id resolves to it; and SHIPYARD_MOTION_INTERVAL
#      reaches the two-read no-agent check (3 when unset).
#   B. answer.sh on a record the child does not poll: its closing words for each outcome of the
#      tell it hands off to, and its own exit-9 hint.
#   C. compact: the three-state mid-turn guard sends nothing while a turn runs, is queued, or the
#      pane cannot be read; tell's exit 6 becomes compact's through the resume; an invalid slot is
#      exit 2; and the interval reaches its no-agent check too.
#   D. the one-line slot-name refusals of down and report: `7/ --force` touches no worktree, a
#      directory with an invalid name is a quoted `INVALID SLOT NAME` row of `--list`, and the
#      report refuses a bad name with exit 1, never the monitor's stop signal 0.
#
# WHAT IS NOT HERE, and why:
#   * the confirm-window and interval knob validation is t16's, over this same rig;
#   * `--submit`'s own verdicts and the repeat refusal are t18's, the no-agent refusal t19's;
#   * `autodown_consider`'s own slot check in shipyard-report.sh is reached by no test and cannot be
#     from a report run: the argv check (D below) refuses a bad name before it, and `shipyard_slots`
#     filters one out of the enumeration. It is a second line nothing can reach today.
#
# The rig is t18's and t19's: exported shell functions shadow `git`, `tmux` and `sleep`. An
# exported function beats PATH lookup, which is why this works although shipyard-lib.sh prepends
# the system PATH. The screens are committed live captures from shared/adapters, not text written
# here, so what the fake shows is what a real client rendered. No live terminal, no network.
set -uo pipefail
export LC_ALL=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$DIR/.." && pwd)"
PANES="$(cd "$SKILL_DIR/../../../.." && pwd)/shared/adapters/tests/fixtures"
[ -f "$PANES/pane-claude-idle.txt" ] || { echo "t24: cannot find the pane fixtures at $PANES" >&2; exit 1; }

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}
has() { grep -q -- "$2" <<<"$1" && printf yes || printf no; }
hasF() { grep -qF -- "$2" <<<"$1" && printf yes || printf no; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/t24-callers.XXXXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

FAKE_ROOT="$TMP/repo"; FAKE_GIT="$TMP/gitdir"; MB="$FAKE_GIT/ship-escalations"
KEYS="$TMP/keys"; SLEEPS="$TMP/sleeps"; CALLS="$TMP/calls"
mkdir -p "$FAKE_ROOT" "$MB"
: > "$MB/container-tmux"        # pinned where we resolve, so no `elsewhere` refusal
export FAKE_ROOT FAKE_GIT KEYS SLEEPS CALLS

# The slots: 41 a live agent, 42 a terminal whose agent is gone (a shell on both reads). Nothing
# else is listed, so any other slot is an answered, corroborated absence.
git() {
  printf 'git %s\n' "$*" >> "$CALLS"
  case "${1:-} ${2:-}" in
    "rev-parse --show-toplevel")  printf '%s\n' "$FAKE_ROOT"; return 0 ;;
    "rev-parse --git-common-dir") printf '%s\n' "$FAKE_GIT";  return 0 ;;
    "remote get-url")             printf 'https://github.com/example/example.git\n'; return 0 ;;
  esac
  return 0
}
# The screen: FAKE_BEFORE until the keys log shows a Return pressed after FAKE_ON was typed (any
# Return when FAKE_ON is unset), then FAKE_AFTER — then FAKE_RESUMED once the resume brief a
# compaction sends has been typed and submitted. An empty FAKE_BEFORE is an unreadable capture.
fake_stage() {
  local on="${FAKE_ON:-}"
  if [ -n "${FAKE_RESUMED:-}" ] && sed -n '/You were compacted/,$p' "$KEYS" 2>/dev/null | grep -q 'Enter$'; then
    echo 2; return; fi
  if [ -z "$on" ]; then grep -q 'Enter$' "$KEYS" 2>/dev/null && { echo 1; return; }
  elif grep -qF -- "$on" "$KEYS" 2>/dev/null; then echo 1; return; fi
  echo 0
}
tmux() {
  printf 'tmux %s\n' "$*" >> "$CALLS"
  case "${1:-}" in
    list-windows) case "$*" in *window_index*) printf '1 ship-41\n2 ship-42\n' ;; *) printf 'ship-41\nship-42\n' ;; esac; return 0 ;;
    has-session)  return 0 ;;
    send-keys)    shift; printf '%s\n' "$*" >> "$KEYS"; return 0 ;;
    display-message) case "$*" in *t24ex:2*) printf '0 zsh\n' ;; *) printf '0 claude\n' ;; esac; return 0 ;;
    capture-pane)
      case "$(fake_stage)" in
        2) cat "$FAKE_RESUMED" ;;
        1) cat "${FAKE_AFTER:-$FAKE_BEFORE}" ;;
        *) [ -n "${FAKE_BEFORE:-}" ] && cat "$FAKE_BEFORE" ;;
      esac
      return 0 ;;
  esac
  return 0
}
# Every sleep is logged with its argument, so a caller's interval is observable. A sub-second one is
# really slept — tell's poll is bounded by the clock, and a no-op would spin it — and a longer one is
# not: compact's fixed waits and the mid-turn guard's ten-second step cost this file nothing.
sleep() {
  printf '%s\n' "$*" >> "$SLEEPS"
  case "${1:-}" in 0.*|.*) command sleep "$1" ;; *) command sleep 0.01 ;; esac
}
export -f git tmux sleep fake_stage

P() { printf '%s/pane-%s.txt' "$PANES" "$1"; }
# run <script> <args...> -> output, then a last line "rc=<n>". The fake's screens come from the caller's env.
# T24_NO_MOTION=1 runs it with SHIPYARD_MOTION_INTERVAL unset, which is the production default.
run() {
  local script="$1" out rc=0; shift
  local -a motion=(SHIPYARD_MOTION_INTERVAL="${SHIPYARD_MOTION_INTERVAL:-0.01}")
  [ -z "${T24_NO_MOTION:-}" ] || motion=(-u SHIPYARD_MOTION_INTERVAL)
  : > "$KEYS"; : > "$SLEEPS"; : > "$CALLS"
  out=$( env "${motion[@]}" SHIPYARD_TELL_SETTLE_DELAY=0.01 SHIPYARD_TELL_CONFIRM_SECS=1 SHIPYARD_TELL_CONFIRM_INTERVAL=0.2 \
             SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t24ex \
         bash "${T24_SKILL:-$SKILL_DIR}/$script" "$@" 2>&1 ) || rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
rc_of() { printf '%s' "$1" | sed -n 's/^rc=//p' | tail -1; }
typed() { grep -c -- ' -l ' "$KEYS" | tr -d ' '; }
sent()  { grep -c . "$KEYS" | tr -d ' '; }
delivery_of() { jq -r '.delivery // "<none>"' "$MB/$1.json" 2>/dev/null; }
latest_directive() { # the newest directive record of slot 41, by its number
  ls "$MB" | sed -n 's/^\(directive-41-[0-9]*\)\.json$/\1/p' | sort -t- -k3 -n | tail -1
}
notice() { printf '{"id":"%s","slot":"%s","kind":"notice","text":"n","status":"pending"}\n' "$1" "${2:-41}" >"$MB/$1.json"; }

# ================================================================= A. tell
printf '\n── A. tell: each verdict is its exit code and its record ──\n'
# A turn that starts on the Return. The pre-send sample is what supplies the idle observation here:
# the first post-send sample is already running, so without it no idle-then-running is ever seen
# and this reads unconfirmed — the "delete the pre-send sample" mutation of #119.
out=$(FAKE_BEFORE=$(P claude-idle) FAKE_AFTER=$(P claude-running) run shipyard-tell.sh 41 "verdict one")
ok "delivered is exit 0"                         0          "$(rc_of "$out")"
ok "...says delivered"                           yes        "$(has "$out" '^told ship-41 .* delivered$')"
ok "...and writes delivered onto the record"     delivered  "$(delivery_of "$(latest_directive)")"
# Mid-turn at the send, and the client then renders its queued hint. Pre-send `running` is the
# non-queued observation a queued verdict needs, so the pre-send sample is load-bearing here too.
out=$(FAKE_BEFORE=$(P claude-running) FAKE_AFTER=$(P claude-queued) run shipyard-tell.sh 41 "verdict two")
ok "queued is exit 0"                            0          "$(rc_of "$out")"
ok "...says the child will take it next"         yes        "$(has "$out" 'queued; the child is mid-turn and will take it next')"
ok "...and writes queued onto the record"        queued     "$(delivery_of "$(latest_directive)")"
# Idle before and after: no turn ever starts.
out=$(FAKE_BEFORE=$(P claude-idle) run shipyard-tell.sh 41 "verdict three")
ok "unconfirmed is exit 6, not 0"                6          "$(rc_of "$out")"
ok "...says the text may sit unsent in the box"  yes        "$(has "$out" 'THE TEXT MAY BE SITTING UNSENT IN THE INPUT BOX')"
ok "...naming the evidence it sampled"           yes        "$(has "$out" 'Sampled: idle x[0-9]*\.')"
ok "...and writes unconfirmed onto the record"   unconfirmed "$(delivery_of "$(latest_directive)")"

printf '\n── A. tell: no verdict from the shared module is never success ──\n'
# The `*)` arm: reachable only when the shared module did not answer. A copy of the skill whose
# vendored adapters' poll fails is that state; the control run on the unmodified skill above is
# what keeps this from passing on a failure of some other kind.
cp -R "${T24_SKILL:-$SKILL_DIR}" "$TMP/skill-nopoll"
printf '\nadp_delivery_poll() { return 2; }\n' >> "$TMP/skill-nopoll/agent-adapters.sh"
out=$(T24_SKILL="$TMP/skill-nopoll" FAKE_BEFORE=$(P claude-idle) FAKE_AFTER=$(P claude-running) \
      run shipyard-tell.sh 41 "verdict four")
ok "an empty verdict is exit 1"                  1          "$(rc_of "$out")"
ok "...saying the verdict could not be read"     yes        "$(has "$out" 'could not read a delivery verdict')"
ok "...and never recording delivered"            no         "$( [ "$(delivery_of "$(latest_directive)")" = delivered ] && echo yes || echo no )"

printf '\n── A. tell: the reply line, and a peer-written slot ──\n'
notice 41-7
out=$(FAKE_BEFORE=$(P claude-idle) FAKE_AFTER=$(P claude-running) run shipyard-tell.sh 41-7 "a reply")
ok "a directive by escalation id is sent"        0          "$(rc_of "$out")"
ok "...and says what it replies to"              yes        "$(hasF "$out" '(in reply to 41-7 — that record is not polled')"
out=$(FAKE_BEFORE=$(P claude-idle) FAKE_AFTER=$(P claude-running) run shipyard-tell.sh 41-7 --submit)
ok "--submit by escalation id is sent"           0          "$(rc_of "$out")"
ok "...and replies to nothing, so says nothing"  no         "$(hasF "$out" '(in reply to')"
# A record's `.slot` is written by whoever wrote the record, so it is checked after resolving.
printf '{"id":"41-8","slot":"../41","kind":"notice","text":"n","status":"pending"}\n' >"$MB/41-8.json"
before=$(ls "$MB" | grep -c '^directive-')
out=$(FAKE_BEFORE=$(P claude-idle) run shipyard-tell.sh 41-8 "via a planted slot")
ok "a record naming an invalid slot is exit 2"   2          "$(rc_of "$out")"
ok "...typing nothing"                           0          "$(sent)"
ok "...and recording nothing"                    "$before"  "$(ls "$MB" | grep -c '^directive-')"

printf '\n── A. tell: the motion interval reaches the no-agent check ──\n'
# `drv_no_agent` falls back to one second on an argument it cannot use, so a dropped argument keeps
# every run green and only slower — while the operator's knob, and the production 3s, are ignored.
out=$(SHIPYARD_MOTION_INTERVAL=0.37 FAKE_BEFORE=$(P claude-idle) run shipyard-tell.sh 42 "to nobody")
ok "a dead agent is refused"                     8          "$(rc_of "$out")"
ok "...after a gap of the knob's value"          1          "$(grep -cx '0.37' "$SLEEPS")"
out=$(T24_NO_MOTION=1 FAKE_BEFORE=$(P claude-idle) run shipyard-tell.sh 42 "to nobody")
ok "...and of 3s with the knob unset"            1          "$(grep -cx '3' "$SLEEPS")"

# ================================================================= B. answer.sh
printf '\n── B. answer.sh on a record the child does not poll ──\n'
notice 41-11
out=$(FAKE_BEFORE=$(P claude-idle) FAKE_AFTER=$(P claude-running) run shipyard-answer.sh 41-11 "answer one")
ok "delivered: exit 0"                           0          "$(rc_of "$out")"
ok "...through the window, which said delivered" yes        "$(has "$out" 'delivered$')"
ok "...leaving the record unwritten"             pending    "$(jq -r .status "$MB/41-11.json")"
notice 41-12
out=$(FAKE_BEFORE=$(P claude-running) FAKE_AFTER=$(P claude-queued) run shipyard-answer.sh 41-12 "answer two")
ok "queued: exit 0"                              0          "$(rc_of "$out")"
ok "...through the window, which said queued"    yes        "$(has "$out" 'queued; the child is mid-turn')"
notice 41-13
out=$(FAKE_BEFORE=$(P claude-idle) run shipyard-answer.sh 41-13 "answer three")
# The exit-6 branch of #119: without it an unconfirmed send reads as a child that could not be
# reached, and the operator is told nobody will read an answer that may be sitting in the box.
ok "unconfirmed: says it was sent but not confirmed" yes    "$(hasF "$out" 'the directive was sent but NOT confirmed (see above) — also recording the answer on 41-13')"
ok "...closing on the box to check"              yes        "$(hasF "$out" 'directive it was delivered as is UNCONFIRMED (see above), so check the child')"
ok "...never on a child that could not be reached" no       "$(hasF "$out" 'could not')"
ok "...and recording the answer as the belt"     answered   "$(jq -r .status "$MB/41-13.json")"
notice 43-1 43
out=$(FAKE_BEFORE=$(P claude-idle) run shipyard-answer.sh 43-1 "answer four")
ok "a gone slot: says it could not reach the child" yes     "$(hasF "$out" 'could not reach the child — recording the answer on 43-1 anyway')"
ok "...closing on an audit copy nobody will read" yes       "$(hasF "$out" 'nobody is going to read this. It is an audit copy only.')"
ok "...and recording it"                         answered   "$(jq -r .status "$MB/43-1.json")"
notice 41-14
out=$(FAKE_BEFORE=$(P claude-idle) run shipyard-answer.sh --no-tell 41-14 "answer five")
ok "--no-tell: says nothing was delivered"       yes        "$(hasF "$out" 'nothing was delivered (--no-tell)')"
ok "...and types nothing"                        0          "$(sent)"
printf '{"id":"41-15","slot":"41","kind":"question","text":"q","status":"pending"}\n' >"$MB/41-15.json"
out=$(FAKE_BEFORE=$(P claude-idle) run shipyard-answer.sh 41-15 "answer six")
ok "a polled question: the pickup claim"         yes        "$(hasF "$out" 'the child session will pick it up within ~5s')"
ok "...with nothing typed"                       0          "$(sent)"
# Exit 9: tell's own refusal, printed in the same run, already contains `--again 41-16 `, so only a
# string answer.sh alone prints proves its hint is there.
notice 41-16
FAKE_BEFORE=$(P claude-idle) run shipyard-answer.sh 41-16 "answer seven" >/dev/null
out=$(FAKE_BEFORE=$(P claude-idle) run shipyard-answer.sh 41-16 "answer seven")
ok "a repeat: exit 9"                            9          "$(rc_of "$out")"
ok "...with answer.sh's own hint"                yes        "$(hasF "$out" "the child in reply to 41-16 (see above)")"

# ================================================================= C. compact
printf '\n── C. compact never drives a pane mid-turn ──\n'
# Its first key is Escape, which interrupts a running turn. A turn, a queued message and an
# unreadable pane each wait, and at the timeout it gives up having sent NOTHING.
for st in running queued; do
  out=$(FAKE_BEFORE=$(P "claude-$st") run shipyard-compact.sh 41 --no-resume --timeout 1)
  ok "$st: exit 5"                               5          "$(rc_of "$out")"
  ok "...having sent nothing, not even Escape"   0          "$(sent)"
done
out=$(FAKE_BEFORE= run shipyard-compact.sh 41 --no-resume --timeout 1)
ok "an unreadable pane: exit 5 too"              5          "$(rc_of "$out")"
ok "...having sent nothing"                      0          "$(sent)"
ok "...and saying it did not interrupt"          yes        "$(has "$out" 'not interrupting it')"

printf '\n── C. compact inherits the resume'"'"'s verdict ──\n'
out=$(FAKE_BEFORE=$(P claude-idle) FAKE_ON=/compact FAKE_AFTER=$(P claude-compacted) \
      run shipyard-compact.sh 41 --timeout 30)
ok "an unconfirmed resume is compact's exit 6"   6          "$(rc_of "$out")"
ok "...after the compaction itself finished"     yes        "$(has "$out" '^compacted after')"
out=$(FAKE_BEFORE=$(P claude-idle) FAKE_ON=/compact FAKE_AFTER=$(P claude-compacted) FAKE_RESUMED=$(P claude-running) \
      run shipyard-compact.sh 41 --timeout 30)
ok "a delivered resume is exit 0"                0          "$(rc_of "$out")"
ok "...and the brief was typed"                  yes        "$(has "$(cat "$KEYS")" 'You were compacted')"

printf '\n── C. compact refuses a bad slot, and passes the interval ──\n'
out=$(FAKE_BEFORE=$(P claude-idle) run shipyard-compact.sh 'a|b' --no-resume --timeout 1)
ok "an invalid slot is exit 2"                   2          "$(rc_of "$out")"
ok "...sending nothing"                          0          "$(sent)"
out=$(SHIPYARD_MOTION_INTERVAL=0.37 FAKE_BEFORE=$(P claude-idle) run shipyard-compact.sh 42 --no-resume --timeout 1)
ok "a dead agent is refused"                     8          "$(rc_of "$out")"
ok "...after a gap of the knob's value"          1          "$(grep -cx '0.37' "$SLEEPS")"
out=$(T24_NO_MOTION=1 FAKE_BEFORE=$(P claude-idle) run shipyard-compact.sh 42 --no-resume --timeout 1)
ok "...and of 3s with the knob unset"            1          "$(grep -cx '3' "$SLEEPS")"

# ================================================================= D. down and report
printf '\n── D. the slot-name refusals of down and report ──\n'
mkdir -p "$FAKE_ROOT/.claude/worktrees/ship-7" "$FAKE_ROOT/.claude/worktrees/ship-a.b"
# Without the check, `7/` resolves through wt_of onto slot 7's real worktree, and --force removes it.
out=$(run shipyard-down.sh 7/ --force)
ok "down '7/' --force is refused"                1          "$(rc_of "$out")"
ok "...naming the rule"                          yes        "$(has "$out" 'refusing the slot name')"
ok "...removing no worktree"                     0          "$(grep -c 'worktree remove' "$CALLS")"
ok "...closing no terminal"                      0          "$(grep -c 'kill-window' "$CALLS")"
ok "...and slot 7's worktree is still there"     yes        "$( [ -d "$FAKE_ROOT/.claude/worktrees/ship-7" ] && echo yes || echo no )"
out=$(run shipyard-down.sh --list)
ok "--list shows an invalid directory, unmanaged" 1         "$(printf '%s\n' "$out" | grep -c '^a\.b .*present .*INVALID SLOT NAME (not managed)$')"
ok "...and a valid one as a slot"                0          "$(printf '%s\n' "$out" | grep -c '^7 .*INVALID SLOT NAME')"
out=$(run shipyard-report.sh 'a|b')
ok "the report refuses a bad slot with exit 1, never 0" 1   "$(rc_of "$out")"
ok "...naming the rule"                          yes        "$(has "$out" 'refusing the slot name')"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 't24-callers: %d checks, all passed\n' "$CHECKS"
  exit 0
fi
printf 't24-callers: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"
exit 1
