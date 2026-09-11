#!/usr/bin/env bash
# t13-wait.sh — WHY a motionless child is not moving, asked before the stall clock is consulted
# (`shipyard_wait_state` in shipyard-lib.sh, and its wiring in shipyard-report.sh).
#
# PROVENANCE. The stall watchdog measures motionlessness and concludes death, and it fired three
# times on healthy children: a pair sitting out a usage limit, a change parked at its hand-off with
# every review round clean and a last line reading "holding for your go-ahead", and a fleet the
# operator had paused for four days, which printed "motionless for 5420 min (ctx 44% · 446k). A
# child does not idle this long on its own." Each block ended at a compaction step, i.e. at
# discarding live working context to cure a condition the child did not have.
#
# WHAT THIS FILE PINS, and the order matters because the third is the one that keeps the fix honest:
#   1. the classification: a child that CANNOT move (a stated capacity wait) and one nobody ASKED
#      to move (finished at its hand-off, or blocked on a human) each get their own answer — and
#      every answer's action text refuses compaction. TWO states, not more: section 2 says why a
#      third, a turn dead on a transport fault, was deleted rather than guessed at;
#   2. the wiring is LOAD-BEARING (the #99 lesson): report.sh really asks, really exempts, and puts
#      the class in the --only-changed signature so the state is news exactly once;
#   3. A GENUINELY STUCK CHILD STILL ALARMS. The job was to make that block rarer and RIGHT, not
#      quieter, so an unexplained idle slot must still reach it — including one whose screen merely
#      MENTIONS a banner, which is the normal case here since the fleet's own directives discuss
#      this very defect.
#
# It also pins the interpreter floor, because this change made report.sh source the shared policy
# module in-process: report.sh runs on stock macOS /bin/bash 3.2, so a bash-4+ construct anywhere
# in that source chain breaks status reporting on the platform the fleet runs on.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$DIR/.." && pwd)"
REPORT="$SKILL_DIR/shipyard-report.sh"
# shellcheck source=../shipyard-lib.sh
. "$SKILL_DIR/shipyard-lib.sh"

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}

# The three fields a report row needs, and the rc, in one readable token.
state3() { shipyard_wait_state "$1" "$2" "$3" | cut -f1-3 | tr '\t' '/'; }
rc_of()  { shipyard_wait_state "$1" "$2" "$3" >/dev/null 2>&1; echo $?; }
action() { shipyard_wait_state "$1" "$2" "$3" | cut -f4; }

IDLE='Waiting on the pipeline'
LIMIT='⚠ Usage limit reached · continuing automatically at 2am'
CAP='⚠ Selected model is at capacity. Please try a different model.'
SLEPT='⚠ API Error: Your computer went to sleep mid-response'
# The adapter's anchor is an allow-list of leading client-status glyphs, not "column one" — because
# one kind renders its OWN prose at column one, so a child writing about this very defect would
# otherwise classify itself and silence its own alarm. `t-wait.sh` owns that property in full; what
# matters here is that the joiner inherits it, which the STUCK section below pins.
PROSE='⏺ the watchdog fires on a usage limit and prescribes compaction'

# --------------------------------------------- 1. WAS NOT ASKED — terminal by design
# The phase comes from the DECLARED slot graph, which already computes `concluded` for
# ready-to-merge / merged / closed. Read from there rather than re-tested here, so there is one
# authority for "this change is over" and not a second copy in the stall path.
ok "a concluded slot is finished, not stalled" "attention/finished/✅ finished" \
   "$(state3 "$IDLE" concluded ready-to-merge)"
ok "...and when its stage says done too"       "attention/finished/✅ finished" \
   "$(state3 "$IDLE" concluded done)"
# BUT THE PHASE ALONE IS NOT ENOUGH, and this pair is the reason. `_syg_concluded` is
# `merged|closed OR stage = ready-to-merge`, so a merged forge state reaches it on its own — and a
# ship session OUTLIVES ITS FIRST MR wherever a repo lands a spec change before its implementation.
# Exempting on the phase alone disarmed the clock for a child that was still working, which is the
# incident report.sh's own comment records as measured: two green signals while the session sat with
# an unsubmitted line in its box.
ok "a merged PR with work still in flight is NOT exempt" 1 \
   "$(rc_of "$IDLE" concluded impl-review)"
ok "...nor mid-apply"                                    1 \
   "$(rc_of "$IDLE" concluded apply)"
# needs-human is the one ship state the graph deliberately leaves as `active`, and before this it
# appeared in no script at all — so a child that had finished and was correctly waiting for a person
# got "A child does not idle this long on its own".
ok "needs-human is a person's move, not a stall" "attention/needs_human/🙋 needs you" \
   "$(state3 "$IDLE" in-review needs-human)"

# --------------------------------------------- 2. CANNOT MOVE — a stated capacity wait
ok "a usage limit is a self-healing wait" "wait/rate_limited/⏳ rate-limited" \
   "$(state3 "$LIMIT" in-review impl-review)"
ok "model-at-capacity is a self-healing wait" "wait/overloaded/⏳ overloaded" \
   "$(state3 "$CAP" in-review apply)"
# TWO SCREEN-READ STATES, NOT FIVE. An earlier version also claimed a transport fault ("the turn
# died, nudge it"), which read well and rested on nothing — no capture shows which glyph a client
# renders that behind. An exemption that cannot be evidenced is worth less than not having it, so it
# was deleted rather than narrowed, and such a child now falls through to the stall path, whose
# remedy order opens with exactly the nudge it needs.
ok "a transport fault is NOT classified" 1 "$(rc_of "$SLEPT" in-review apply)"

# --------------------------------------------- 3. STUCK still alarms
ok "an unexplained idle slot has no answer here" 1 "$(rc_of "$IDLE" in-review impl-review)"
ok "...and returns nothing at all"               "" "$(state3 "$IDLE" in-review impl-review)"
# The adversarial case, and the reason the adapter anchors rather than substring-matching: a screen
# that merely QUOTES a banner must not buy an exemption. Built with the composer glyph in column
# one, where an unanchored read would believe it.
ok "a banner quoted in the input box stays STUCK" 1 \
   "$(rc_of '❯ the watchdog fires on Usage limit reached and prescribes compaction' in-review impl-review)"
ok "a banner in indented transcript content stays STUCK" 1 \
   "$(rc_of '  it printed ⚠ Usage limit reached in the last line column' in-review impl-review)"
# The one that is not merely theoretical: a child working on THIS issue writes these phrases in its
# own prose, at column one behind its assistant glyph. If the joiner ever exempts that, every such
# child becomes permanently unalarmable.
ok "a child's own prose about the defect stays STUCK" 1 "$(rc_of "$PROSE" in-review impl-review)"
# A context ceiling is NOT answered here on purpose: `policy_dispose context_full` is `compact`, and
# compaction is exactly the decision the existing stall path already governs by the ctx band. So no
# arm here may shadow it — an unknown disposition falls through rather than inventing a verdict.
ok "no shape maps to a compaction verdict" 0 \
   "$(for p in "$IDLE" "$LIMIT" "$CAP" "$SLEPT"; do
        shipyard_wait_state "$p" in-review apply 2>/dev/null | cut -f2
      done | grep -c 'context_full')"

# --------------------------------------------- 4. NO ANSWER MAY PRESCRIBE COMPACTION
# The single property the whole issue is about. Every action line an operator can be shown, checked
# for the two ways compaction is ever PRESCRIBED — the script and the slash command — because a
# remedy offered as covering both branches of a guess is how two healthy sessions nearly lost ~85k
# and ~180k tokens of live context. Matching a bare "compact" would be useless here: every action
# deliberately contains the words "Do NOT compact", which is the check below.
# EVERY row an operator can be shown. Kept as one list, used by both checks, so a state added later
# cannot be covered by one and missed by the other.
ANSWERED_ROWS="concluded|ready-to-merge|$IDLE
in-review|needs-human|$IDLE
in-review|impl-review|$LIMIT
in-review|apply|$CAP"
compaction_hits=0
while IFS= read -r row; do
  [ -n "$row" ] || continue
  ph=${row%%|*}; rest=${row#*|}; st=${rest%%|*}; scr=${rest#*|}
  a=$(action "$scr" "$ph" "$st")
  [ -n "$a" ] || { compaction_hits=$((compaction_hits + 1)); continue; }   # an empty action is a silent row
  case "$a" in
    *compact.sh*|*'/compact'*|*'compact '*[Ii]'t'*) compaction_hits=$((compaction_hits + 1)) ;;
  esac
done <<EOF
$ANSWERED_ROWS
EOF
ok "no action prescribes compaction, and none is empty" 0 "$compaction_hits"
# And each one says so out loud, so an operator reading the block is told rather than left to infer
# it from an absence.
ok "every action says NOT to compact" "$(printf '%s\n' "$ANSWERED_ROWS" | grep -c .)" \
   "$(while IFS= read -r row; do
        [ -n "$row" ] || continue
        ph=${row%%|*}; rest=${row#*|}; st=${rest%%|*}; scr=${rest#*|}
        action "$scr" "$ph" "$st"
      done <<EOF | grep -ci 'do not compact'
$ANSWERED_ROWS
EOF
)"

# --------------------------------------------- 5. the wiring is load-bearing
ok "report.sh asks why before the clock" 1 \
   "$(grep -Fc 'shipyard_wait_state "$b" "$phase" "$stage"' "$REPORT")"
ok "...only of a motionless child with nothing pending" 1 \
   "$(grep -Fc 'if [ "$run" = "⏸ idle/wait" ] && [ "$pend" = 0 ]; then' "$REPORT")"
ok "an answered slot never reaches STALLED" 1 \
   "$(grep -Fc 'if [ -n "$wait_kind" ]; then' "$REPORT")"
ok "the class is in the --only-changed signature" 1 \
   "$(grep -Fc 'SIG+=("$slot|$mr_label|term=1|$state|$stage|$pend|$band|$wait_class")' "$REPORT")"
ok "the stall clock restarts across an unwatched gap" 1 \
   "$(grep -Fc '{ [ "$GAP" != 0 ] || [ -n "$wait_kind" ]; } && since="$now_epoch"' "$REPORT")"
ok "a gap breaks --only-changed silence" 1 \
   "$(grep -Fc '[ "$GAP" = 0 ] && [ -n "$SIGFILE" ]' "$REPORT")"
ok "both new blocks are printed" 2 \
   "$(grep -cE '^    echo "### (⏳ WAITING|🙋 WAITING FOR YOU)' "$REPORT")"
# The sidebar glyph, which no execution here can reach: shipyard_note is a no-op on the tmux backend
# the rig uses, so this is grep-only by necessity. ONLY needs_human may override the graph verdict —
# FLOW-03 states that `concluded` keeps `completed`, and painting a finished slot `blocked` from its
# first idle tick would break that. Mirrors t11-slot-graph.sh, which pins the else branch already.
ok "only needs_human overrides the graph's glyph" 1 \
   "$(grep -Fc 'elif [ "$wait_class" = needs_human ]; then shipyard_note "$slot" blocked' "$REPORT")"
# THE SENTENCE THAT WAS THE BUG. It was written as the alarm's justification and it is the one
# assumption that failed — a child idles exactly that long when it cannot move, or when nobody
# asked it to. It must not come back, in the script or in the skill's own text.
ok "the false justification is gone from the report" 0 \
   "$(grep -Fc 'A child does not idle this long on its own' "$REPORT")"
ok "...and from the skill's text" 0 \
   "$(grep -Fc 'A child does not idle this long on its own' "$SKILL_DIR/SKILL.md")"
# The loud block itself survives, which is the point of note 4: rarer and right, not quieter.
ok "the STALLED block still exists" 1 "$(grep -Fc '### 🛑 STALLED' "$REPORT")"
ok "...and still bypasses --only-changed" 1 "$(grep -Fc '[ "${#STALLED[@]}" -eq 0 ]' "$REPORT")"

# --------------------------------------------- 6. THE REPORT, EXECUTED
# WHY THIS SECTION EXISTS, and it is the most important one in the file. Section 5 above pins the
# wiring with `grep -Fc` over exact source lines, which is this repo's established idiom — and a
# review of this very change measured what that idiom is worth by mutating the report: SIX of seven
# semantic mutations shipped with all checks green. Inverting the supervision-gap comparison (the
# change's headline fix) — green. Deleting the tick stamp — green. Routing ATTENTION rows into the
# WAITING block, so a child explicitly waiting for a human is filed under "nothing to do" — green.
# Transposing the label and action fields — green. Dropping `run="$wait_label"`, so the documented
# session column never changes — green. Adding one `wait_line=""` after the pinned call, killing the
# whole classification while every grepped byte stayed put — green. Only deleting the grepped text
# itself reds. So `grep -Fc` asserts that a line EXISTS, and nothing about reachability, ordering,
# branch bodies, or `if` versus `elif`. Read section 5 as "the call site has not been renamed", not
# as "the wiring works".
#
# This section executes the real script instead. The rig is the one t7-continuity.sh already uses:
# exported shell functions shadow `git`, `tmux` and `gh`, which works where a fake binary on PATH
# does not because shipyard-lib.sh prepends the system PATH over anything a test puts in front.
#
# COST, stated because someone will want it back: the report sleeps 3s per slot for its motion diff,
# so three slots over two runs is ~18s. That is why this suite is in `make test` and not in the
# per-commit gate, and it is the price of the six mutations above going red.
if [ "${SHIPYARD_T13_SKIP_EXEC:-}" = 1 ]; then
  printf '  skip executed-report section (SHIPYARD_T13_SKIP_EXEC=1)\n'
else
T13TMP=$(mktemp -d "${TMPDIR:-/tmp}/t13-report.XXXXXXXX") || exit 1
trap 'rm -rf "$T13TMP"' EXIT
FAKE_ROOT="$T13TMP/repo"; FAKE_GIT="$T13TMP/gitdir"
mkdir -p "$FAKE_ROOT" "$FAKE_GIT/ship-escalations"
for s in 41 42 43; do mkdir -p "$FAKE_ROOT/.claude/worktrees/ship-$s/.pipeline-state"; done
# 41: rate-limited mid-review. 42: stopped at needs-human. 43: mid-review, announcing nothing.
printf '{"pr_number":901,"state":"impl-review"}\n'  >"$FAKE_ROOT/.claude/worktrees/ship-41/.pipeline-state/PR-901.json"
printf '{"pr_number":902,"state":"needs-human"}\n'  >"$FAKE_ROOT/.claude/worktrees/ship-42/.pipeline-state/PR-902.json"
printf '{"pr_number":903,"state":"impl-review"}\n'  >"$FAKE_ROOT/.claude/worktrees/ship-43/.pipeline-state/PR-903.json"
export FAKE_ROOT FAKE_GIT
git() {
  case "${1:-} ${2:-}" in
    "rev-parse --show-toplevel")  printf '%s\n' "$FAKE_ROOT"; return 0 ;;
    "rev-parse --git-common-dir") printf '%s\n' "$FAKE_GIT";  return 0 ;;
    "remote get-url")             printf 'https://github.com/example/example.git\n'; return 0 ;;
  esac
  return 0
}
# drv_target builds "<container>:<window-index>", so the capture fake keys on the index.
tmux() {
  case "${1:-}" in
    list-windows) printf '1 ship-41\n2 ship-42\n3 ship-43\n'; return 0 ;;
    has-session)  return 0 ;;
    capture-pane)
      case "$*" in
        *t13ex:1*) printf 'ran the check suite\n⚠ Usage limit reached · continuing automatically at 2am\n' ;;
        *t13ex:2*) printf '⏺ Blockers posted on the PR. Holding for a human.\n' ;;
        *)         printf '⏺ spec review round 2, awaiting the verifier\n' ;;
      esac
      return 0 ;;
  esac
  return 0
}
gh() { printf 'OPEN\n'; return 0; }
export -f git tmux gh
run_report() {  # <stall-secs> [extra args...]; prints the whole report
  local ss="$1"; shift
  SHIPYARD_STALL_SECS="$ss" SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t13ex \
    bash "$REPORT" "$@" 41 42 43 2>/dev/null
}

# --- run A: an ordinary tick. Seeds the stall clocks that runs A2 and B depend on, and renders the
# classification. No gap, so nothing may be announced as one.
printf '%s\n' "$(date +%s)" >"$FAKE_GIT/ship-escalations/report-tick"
outA=$(run_report 1800)
ok "A: no gap is claimed on an ordinary tick" 0 \
   "$(printf '%s' "$outA" | grep -c 'supervision resumed after')"
# The classification itself, rendered by the real script.
ok "A: the rate-limited slot says so in its row" 1 \
   "$(printf '%s' "$outA" | grep -c '^| 41 .*⏳ rate-limited')"
ok "A: ...and appears under WAITING"             1 \
   "$(printf '%s' "$outA" | grep -A3 '### ⏳ WAITING' | grep -c '^- `41`')"
ok "A: ...with the evidence line printed"        1 \
   "$(printf '%s' "$outA" | grep -c 'Evidence: ⚠ Usage limit reached')"
ok "A: the needs-human slot says so in its row"  1 \
   "$(printf '%s' "$outA" | grep -c '^| 42 .*🙋 needs you')"
ok "A: ...and appears under WAITING FOR YOU"     1 \
   "$(printf '%s' "$outA" | grep -A3 '### 🙋 WAITING FOR YOU' | grep -c '^- `42`')"
# The two blocks must not be interchangeable: a needs-human child is NOT "nothing to do".
ok "A: needs-human is NOT under WAITING"         0 \
   "$(printf '%s' "$outA" | sed -n '/### ⏳ WAITING —/,/^$/p' | grep -c '^- `42`')"
ok "A: the rate-limited slot is NOT under WAITING FOR YOU" 0 \
   "$(printf '%s' "$outA" | sed -n '/### 🙋 WAITING FOR YOU/,/^$/p' | grep -c '^- `41`')"
ok "A: neither block ever prescribes compaction" 0 \
   "$(printf '%s' "$outA" | sed -n '/### ⏳ WAITING —/,$p' | grep -c 'shipyard-compact.sh')"

# --- run A2: the SUPERVISION GAP, and this ordering is what makes the assertion mean something.
# Run A has just seeded stall clocks, and the threshold here is 1s while ~9s of wall time has
# passed — so WITHOUT the rebase slot 43 would cross it and alarm. Nothing stalling is therefore
# evidence the clocks restarted, not an artefact of a fresh mailbox. (The previous version of this
# check ran first against an empty mailbox, where no clock had accumulated and it could not fail.)
printf '%s\n' "$(( $(date +%s) - 345600 ))" >"$FAKE_GIT/ship-escalations/report-tick"
outA2=$(run_report 1)
ok "A2: the gap is announced"               1 "$(printf '%s' "$outA2" | grep -c 'supervision resumed after')"
ok "A2: ...with a plausible figure"         1 "$(printf '%s' "$outA2" | grep -c 'resumed after 5760 min')"
ok "A2: a restarted clock cannot be stalled" 0 "$(printf '%s' "$outA2" | grep -c '🛑 STALLED')"

# --- run B: no gap now, and a 1s threshold, so the slot announcing NOTHING must alarm.
# An open escalation is also written for slot 42 first, so the `pend` guard is exercised rather
# than only grepped: an escalated slot must be classified by nothing and stalled by nothing.
cat >"$FAKE_GIT/ship-escalations/42-1.json" <<'ESCEOF'
{"id":"42-1","slot":"42","kind":"question","text":"which option?","context":"",
 "worktree":"","created_at":"2026-09-11T00:00:00Z","status":"pending","notified":false,
 "answer":null,"answered_at":null}
ESCEOF
printf '%s\n' "$(date +%s)" >"$FAKE_GIT/ship-escalations/report-tick"
outB=$(run_report 1)
ok "B: no gap is claimed"                   0 "$(printf '%s' "$outB" | grep -c 'supervision resumed after')"
ok "B: the escalated slot is classified by nothing" 0 \
   "$(printf '%s' "$outB" | sed -n '/### 🙋 WAITING FOR YOU/,/^$/p' | grep -c '^- `42`')"
ok "B: ...and its row shows the escalation instead" 1 \
   "$(printf '%s' "$outB" | grep -c '^| 42 .*⚠️ 1')"
ok "B: ...and it is not stalled either"     0 \
   "$(printf '%s' "$outB" | sed -n '/🛑 STALLED/,/^$/p' | grep -c '^- `42`')"
# THE POINT OF THE WHOLE CHANGE: rarer and right, not quieter.
ok "B: the unexplained slot IS stalled"     1 \
   "$(printf '%s' "$outB" | grep -A1 '🛑 STALLED' | grep -c '^- `43`')"
ok "B: ...and the loud block kept its remedy order" 1 \
   "$(printf '%s' "$outB" | grep -c '1. GIT FIRST')"
ok "B: the rate-limited slot is NOT stalled" 0 \
   "$(printf '%s' "$outB" | sed -n '/🛑 STALLED/,/^$/p' | grep -c '^- `41`')"
ok "B: the rate-limited slot still reports"  1 \
   "$(printf '%s' "$outB" | grep -c '^- `41`')"

# --- run C: --only-changed is silent when nothing moved, which is what makes suppressing the
# stall block for a classified slot cost the operator nothing.
#
# It also pins THE TICK STAMP ITSELF, at no extra run. A SENTINEL goes in first — recent enough that
# no gap is claimed, but distinguishable — and the report must overwrite it with its own epoch. The
# earlier version of this section could not see the stamp at all, because every run pre-wrote the
# file and nothing ever read it back: deleting the stamp outright, or moving it back above the loop,
# both shipped with all checks green while this file claimed otherwise.
tick_sentinel=$(( $(date +%s) - 5 ))
printf '%s\n' "$tick_sentinel" >"$FAKE_GIT/ship-escalations/report-tick"
outC=$(run_report 100000 --only-changed)
ok "C: an unchanged tick prints nothing" 0 "$(printf '%s' "$outC" | grep -c .)"
tick_after=$(cat "$FAKE_GIT/ship-escalations/report-tick" 2>/dev/null)
ok "C: the report stamped its own tick" yes \
   "$([ -n "$tick_after" ] && [ "$tick_after" != "$tick_sentinel" ] && echo yes || echo no)"
ok "C: ...with a current epoch, not a stale one" yes \
   "$([ -n "$tick_after" ] && [ "$tick_after" -gt "$tick_sentinel" ] 2>/dev/null && echo yes || echo no)"
unset -f git tmux gh
fi

# WHERE the stamp happens is a source-ORDER property, and no execution here can see it: both
# placements stamp the file, and the difference only shows when a run dies mid-loop. Pinned the way
# t7-continuity.sh pins its own ordering constraint, and labelled as what it is — an assertion about
# the text's order, not about behaviour. It matters because stamping early lets an interrupted run
# CONSUME the gap without rebasing any clock, which silently restores the unjustified figure.
# THE ANCHOR IS THE SLOT LOOP'S `done`, not the file's first one — which is what the first version
# of this check got wrong. `grep -n '^done$' | head -1` returns an unrelated earlier loop near the
# top of the file, so the comparison was true for ANY placement of the stamp, including the one it
# exists to forbid. Measured: with that anchor, moving the stamp back above the slot loop still
# passed. Both anchors are asserted non-empty, so renaming either reds this instead of quietly
# making it vacuous again.
slot_loop_line=$(grep -n '^for slot in "${SLOTS\[@\]}"; do' "$REPORT" | head -1 | cut -d: -f1)
loop_end_line=$(awk -v s="${slot_loop_line:-0}" 'NR > s && /^done$/ { print NR; exit }' "$REPORT")
tick_line=$(grep -n '^\[ -n "$TICKFILE" \] && printf' "$REPORT" | head -1 | cut -d: -f1)
ok "the slot loop and its end were both located" yes \
   "$([ -n "$slot_loop_line" ] && [ -n "$loop_end_line" ] && echo yes || echo no)"
ok "the tick stamp was located"                  yes \
   "$([ -n "$tick_line" ] && echo yes || echo no)"
ok "the tick is stamped after the slot loop, not before" yes \
   "$([ -n "$tick_line" ] && [ -n "$loop_end_line" ] && [ "$tick_line" -gt "$loop_end_line" ] && echo yes || echo no)"

# --------------------------------------------- 7. the interpreter floor
# report.sh sources shared/policy in-process (through shipyard-lib.sh) and runs on stock macOS
# /bin/bash, which is 3.2. These EXECUTE rather than parse, because a review of this change measured
# that `bash -n` is nearly empty as a floor assertion: under the real /bin/bash 3.2.57 a `${v^^}`, a
# `declare -A` and a `mapfile` are ALL accepted by `-n` and by sourcing — only CALLING the function
# fails. So the two `-n` checks this section used to carry would have caught none of the three
# constructs their own comment named.
#
# WORTH LESS THAN IT LOOKS WHERE /bin/bash IS NEWER: on Linux CI /bin/bash is 5.x and these pass
# vacuously. They bite on the platform the fleet actually runs on, which is the one that ships 3.2 —
# t-policy.sh states the same caveat and prints the version so a reader can tell which run they have.
floor() { /bin/bash -c ". '$SKILL_DIR/shipyard-lib.sh' >/dev/null 2>&1; $1" 2>/dev/null; }
ok "the joiner runs under /bin/bash: a capacity wait" "wait" \
   "$(floor "shipyard_wait_state '⚠ Usage limit reached' in-review apply | cut -f1")"
ok "...a concluded slot"                              "attention" \
   "$(floor "shipyard_wait_state '' concluded ready-to-merge | cut -f1")"
ok "...and an unexplained one returns rc 1"           "1" \
   "$(floor "shipyard_wait_state 'nothing' in-review apply >/dev/null; echo \$?")"
ok "the policy table answers under /bin/bash" "park|reprobe" \
   "$(/bin/bash -c ". '$SKILL_DIR/policy.sh'; policy_dispose rate_limited")"
# The report is still only PARSE-checked there: executing it needs the whole rig above, which
# section 6 does under the test's own interpreter. Said plainly rather than implied.
ok "shipyard-report.sh at least parses under /bin/bash" 0 \
   "$(/bin/bash -n "$REPORT" >/dev/null 2>&1; echo $?)"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 't13-wait: %d checks, all passed\n' "$CHECKS"
  exit 0
fi
printf 't13-wait: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"
exit 1
