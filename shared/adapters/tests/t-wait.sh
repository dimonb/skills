#!/usr/bin/env bash
# t-wait — the wait/fault class a client ANNOUNCES (adp_wait_class in agent-adapters.sh).
#
# PROVENANCE. Every property here traces to a measured false alarm. shipyard's stall watchdog
# measures motionlessness and concludes death, and it fired three times on children that were
# perfectly healthy: a pair sitting out a usage limit, a change parked at its hand-off with every
# review round clean, and a fleet an operator had paused for four days, which produced a
# 5420-minute "STALLED" block. All three ended at a prescription whose last step is compaction —
# discarding live working context (446k tokens in the pause case) to cure a condition the child did
# not have. This function is the first half of the fix: it answers WHETHER the child announced a
# reason, so the caller can ask policy what to do about it instead of guessing.
#
# THE BIAS IS THE OPPOSITE OF THE TURN READ'S, and that is what most of this file pins. A shape
# MISSED here falls through to the caller's existing stall path, i.e. to today's behaviour; a shape
# matched too LOOSELY suppresses a real alarm on a genuinely wedged child. So every adversarial
# case below must read as NO class at all, and the one that matters most is a banner phrase sitting
# in the child's own input box — because the caller's own directives are about this very defect, so
# a screen quoting the banner is not a hypothetical here, it is the normal case.
#
# WHERE THE SCREENS COME FROM, honestly:
#   * the ADVERSARIAL screens are built from the live capture `fixtures/pane-claude-draft.txt` — a
#     real composer with a real WRAPPED continuation — by substituting banner words into the box
#     while leaving the glyph, the indentation and the frame exactly as captured. The builder
#     asserts the substitution took, so it cannot decay into a vacuous check.
#   * the POSITIVE screens are synthetic frames carrying VERBATIM banner lines: the words are real
#     (from the operator's own reports of the `last line` column, and from the Codex service-line
#     list `shipyard-continuity.sh` matches off a real capture), but their column-one placement is
#     inferred rather than observed. The module's header states that residual. Nothing here proves
#     a client renders these lines in column one; what it proves is that IF it does, they classify,
#     and that box and transcript placements never do.
set -uo pipefail
export LC_ALL=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$DIR/../agent-adapters.sh"
FIX="$DIR/fixtures"
[ -f "$MOD" ] || { echo "t-wait: cannot find agent-adapters.sh at $MOD" >&2; exit 1; }
# shellcheck source=../agent-adapters.sh
. "$MOD"

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}

# cls <screen> — just the class, so a check reads as the answer and not as the evidence line.
cls() { adp_wait_class "${1:-}" | cut -f1; }

# --- 1. the shapes that classify, and the class each maps to ------------------------------
# The class is the driver's AgentSignal vocabulary, NOT a word of this module's own, because the
# caller feeds it straight to policy_dispose. A wrong class here is a wrong disposition there.
ok "a capitalised usage-limit banner is rate_limited" rate_limited \
   "$(cls '⚠ Usage limit reached · continuing automatically at 2am')"
ok "a lowercase usage-limit service line is rate_limited" rate_limited \
   "$(cls '• You have 5 usage limit resets left')"
ok "a session limit is rate_limited too" rate_limited \
   "$(cls "⚠ You've hit your session limit · resets at 20:10")"
ok "a model-at-capacity banner is overloaded" overloaded \
   "$(cls '⚠ Selected model is at capacity. Please try a different model.')"
# A transport fault is NOT a capacity class, and the difference is the whole point: policy parks a
# capacity wait and escalates this, so the caller nudges instead of waiting — and neither compacts.
# NOTE what this does and does not establish. No capture shows which glyph a client puts this
# behind, so the arm fires only if it is the warning glyph, and in practice it may never fire. The
# pair below pins exactly that, rather than implying an unobserved rendering is covered.
ok "a slept-mid-response fault is error, not capacity" error \
   "$(cls '⚠ API Error: Your computer went to sleep mid-response')"
ok "...but bare at column one it is NOT eligible" "" \
   "$(cls 'API Error: Your computer went to sleep mid-response')"

# --- 2. nothing announced -> nothing, so the caller's stall path still owns the slot -------
ok "an ordinary idle frame yields no class" "" "$(cls 'Waiting for the pipeline to finish')"
ok "an empty screen yields no class"        "" "$(cls '')"
ok "no class is rc 1, not rc 0 with empty output" 1 \
   "$(adp_wait_class 'nothing to see' >/dev/null 2>&1; echo $?)"
ok "a class is rc 0" 0 \
   "$(adp_wait_class '⚠ Usage limit reached' >/dev/null 2>&1; echo $?)"

# --- 3. the evidence line comes back with the class ---------------------------------------
# The caller does not use it today, but a supervisor reading a report needs to see WHICH line
# decided — an alarm that cannot show its evidence is the defect this whole issue is about.
ok "the deciding line is returned after the class" '⚠ Usage limit reached · at 2am' \
   "$(adp_wait_class '⚠ Usage limit reached · at 2am' | cut -f2)"

# --- 4. THE LAST anchored match wins ------------------------------------------------------
# A screen can still show an older banner above newer output, so the live announcement is the most
# recent one. Pinned in both orders, or the check would pass on a first-match implementation too.
two_down='⚠ Usage limit reached · continuing automatically at 2am
⚠ API Error: Your computer went to sleep mid-response'
two_up='⚠ API Error: Your computer went to sleep mid-response
⚠ Usage limit reached · continuing automatically at 2am'
ok "fault below a banner -> the fault"  error        "$(cls "$two_down")"
ok "banner below a fault -> the banner" rate_limited "$(cls "$two_up")"

# --- 5. ADVERSARIAL: the box may never supply the evidence --------------------------------
# Built from the real composer capture. `boxed <first> <cont>` puts <first> after the captured box
# glyph and <cont> into the captured WRAPPED continuation line, keeping both renderings verbatim.
boxed() {
  awk -v first="$1" -v cont="$2" '
    BEGIN { done_box = 0 }
    done_box == 1 && /^  [^ ]/ { print "  " cont; done_box = 2; next }
    /^❯/ && done_box == 0      { print "❯ " first; done_box = 1; next }
    { print }
  ' "$FIX/pane-claude-draft.txt"
}
draft=$(boxed 'the watchdog fires on Usage limit reached and prescribes' 'compaction, which is the bug')
# VACUITY GUARD, first: if the fixture's shape ever changes so the substitution silently does
# nothing, the refusal below would pass over a screen carrying no banner at all — a check that
# proves nothing while looking green, which is the failure class this repo treats as a real defect.
ok "the adversarial screen really carries the phrase" 1 \
   "$(printf '%s\n' "$draft" | grep -c 'Usage limit reached')"
ok "...on a real box line, not in column one" 1 \
   "$(printf '%s\n' "$draft" | grep -c '^❯ .*Usage limit reached')"
ok "...and its wrapped continuation is still indented" 1 \
   "$(printf '%s\n' "$draft" | grep -c '^  compaction, which is the bug$')"
# Now the property.
ok "a banner TYPED in the box is not an announcement" "" "$(cls "$draft")"

# The same phrase as indented transcript content — a child displaying this repo's own source, or
# the issue text describing the defect. Same refusal, different placement.
ok "a banner as indented transcript content is refused" "" \
   "$(cls '  the report printed ⚠ Usage limit reached in its last line column')"
ok "a banner in a tool-output block is refused" "" \
   "$(cls '    ⚠ Usage limit reached · continuing automatically at 2am')"

# The other client's composer glyph, which is NOT the same character, so an arm that only knew the
# first kind's glyph would let this through — and that kind renders its service lines in column
# one, which is precisely where this must not be believed.
ok "a banner typed in the other kind's composer is refused" "" \
   "$(cls '› please read the Usage limit reached note in issue text')"

# --- 5b. ADVERSARIAL: THE CHILD'S OWN PROSE may never supply it either --------------------
# THE REGRESSION THAT EARNS THIS SECTION. The first version of the anchor took any column-one,
# non-composer line, on the stated grounds that transcript content is indented. That is true of tool
# output and FALSE of assistant prose: `pane-claude-running.txt` is a live capture of one kind
# writing its own sentences at column one behind its assistant glyph, with only the wrapped
# continuations indented. A child working on this very defect writes these phrases constantly, so
# the loose anchor let such a child classify ITSELF as rate-limited and silence its own alarm —
# a false clearance on a possibly-wedged slot, which is the one direction this must never fail in.
#
# Built from that capture, by substituting into its real assistant line, so the check is pinned to
# the rendering that actually fooled it rather than to a guess about one.
assistant_glyph=$(sed -n 's/^\(.\) [A-Z].*/\1/p' "$FIX/pane-claude-running.txt" | head -1)
ok "the capture really renders assistant prose in column one" 1 \
   "$([ -n "$assistant_glyph" ] && echo 1 || echo 0)"
prose=$(awk -v g="$assistant_glyph" '
    BEGIN { hit = 0 }
    substr($0,1,1) == g && hit == 0 { print g " the watchdog fires on a usage limit and prescribes compaction"; hit = 1; next }
    { print }
  ' "$FIX/pane-claude-running.txt")
# VACUITY GUARD before the property, same discipline as the box case above.
ok "the prose screen really carries the phrase in column one" 1 \
   "$(printf '%s\n' "$prose" | grep -c "^${assistant_glyph} the watchdog fires on a usage limit")"
ok "a child's OWN prose is not an announcement" "" "$(cls "$prose")"
# And the narrow version of the same thing, so the property is readable without the fixture rig.
ok "an assistant-glyph line carrying the phrase is refused" "" \
   "$(cls '⏺ I am reading the usage limit handling in the report')"
# The allow-list is what buys those: an arbitrary column-one line is NOT eligible just for being in
# column one. If this ever goes green with a leading letter, the deny-list has crept back in.
ok "a bare column-one sentence is not eligible" "" \
   "$(cls 'the session limit note is what issue 22 is about')"

# --- 6. the real captured panes announce nothing -------------------------------------------
# Every committed fixture is a healthy running, idle, drafting or queued child. If any of them
# classified, the caller would suppress the alarm on an ordinary slot — so this is the regression
# check for a future arm that is too loose.
for f in "$FIX"/pane-*.txt; do
  ok "no class from $(basename "$f")" "" "$(cls "$(cat "$f")")"
done

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 't-wait: %d checks, all passed\n' "$CHECKS"
  exit 0
fi
printf 't-wait: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"
exit 1
