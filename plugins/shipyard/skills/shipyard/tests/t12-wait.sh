#!/usr/bin/env bash
# t12-wait.sh — WHY a motionless child is not moving, asked before the stall clock is consulted
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
#   1. the classification: a child that CANNOT move (a stated capacity wait), one nobody ASKED to
#      move (finished at its hand-off, or blocked on a human), and a turn that died on a transport
#      fault, each get their own answer — and every answer's action text refuses compaction;
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
SLEPT='API Error: Your computer went to sleep mid-response'

# --------------------------------------------- 1. WAS NOT ASKED — terminal by design
# The phase comes from the DECLARED slot graph, which already computes `concluded` for
# ready-to-merge / merged / closed. Read from there rather than re-tested here, so there is one
# authority for "this change is over" and not a second copy in the stall path.
ok "a concluded slot is finished, not stalled" "attention/finished/✅ finished" \
   "$(state3 "$IDLE" concluded ready-to-merge)"
ok "...whatever its stage says"                "attention/finished/✅ finished" \
   "$(state3 "$IDLE" concluded done)"
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
# A transport fault is the one announced cause that DOES want a person — policy escalates it rather
# than parking it — and it still must not want compaction. Keeping these two apart is the reason the
# disposition comes from the shared policy module instead of from a local guess.
ok "a dead turn wants a nudge, not a park" "attention/error/⚠️ turn died" \
   "$(state3 "$SLEPT" in-review apply)"

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
compaction_hits=0
for row in "concluded|ready-to-merge|$IDLE" "in-review|needs-human|$IDLE" \
           "in-review|impl-review|$LIMIT" "in-review|apply|$CAP" "in-review|apply|$SLEPT"; do
  ph=${row%%|*}; rest=${row#*|}; st=${rest%%|*}; scr=${rest#*|}
  a=$(action "$scr" "$ph" "$st")
  [ -n "$a" ] || { compaction_hits=$((compaction_hits + 1)); continue; }   # an empty action is a silent row
  case "$a" in
    *compact.sh*|*'/compact'*|*'compact '*[Ii]'t'*) compaction_hits=$((compaction_hits + 1)) ;;
  esac
done
ok "no action prescribes compaction, and none is empty" 0 "$compaction_hits"
# And each one says so out loud, so an operator reading the block is told rather than left to infer
# it from an absence.
ok "every action says NOT to compact" 5 \
   "$(for row in "concluded|ready-to-merge|$IDLE" "in-review|needs-human|$IDLE" \
                 "in-review|impl-review|$LIMIT" "in-review|apply|$CAP" "in-review|apply|$SLEPT"; do
        ph=${row%%|*}; rest=${row#*|}; st=${rest%%|*}; scr=${rest#*|}
        action "$scr" "$ph" "$st"
      done | grep -ci 'do not compact')"

# --------------------------------------------- 5. the wiring is load-bearing
ok "report.sh asks why before the clock" 1 \
   "$(grep -Fc 'shipyard_wait_state "$b" "$phase" "$stage"' "$REPORT")"
ok "...only of a motionless child" 1 \
   "$(grep -Fc 'if [ "$run" = "⏸ idle/wait" ]; then' "$REPORT")"
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

# --------------------------------------------- 6. the interpreter floor
# report.sh now sources shared/policy in-process (through shipyard-lib.sh) and runs on stock macOS
# /bin/bash, which is 3.2. Parse BOTH under the real /bin/bash and run the policy table there, so a
# bash-4+ construct added to the shared module later cannot silently break status reporting.
#
# WORTH LESS THAN IT LOOKS WHERE /bin/bash IS NEWER: on Linux CI /bin/bash is 5.x and these three
# checks pass vacuously. They bite on the platform the fleet actually runs on, which is the one
# that ships 3.2 — and `t-policy.sh` states the same caveat for the module's own floor assertion.
ok "shipyard-lib.sh parses under /bin/bash" 0 \
   "$(/bin/bash -n "$SKILL_DIR/shipyard-lib.sh" >/dev/null 2>&1; echo $?)"
ok "shipyard-report.sh parses under /bin/bash" 0 \
   "$(/bin/bash -n "$REPORT" >/dev/null 2>&1; echo $?)"
ok "the policy table answers under /bin/bash" "park|reprobe" \
   "$(/bin/bash -c ". '$SKILL_DIR/policy.sh'; policy_dispose rate_limited")"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 't12-wait: %d checks, all passed\n' "$CHECKS"
  exit 0
fi
printf 't12-wait: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"
exit 1
