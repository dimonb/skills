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
ok "a session limit is rate_limited too" rate_limited \
   "$(cls "⚠ You've hit your session limit · resets at 20:10")"
ok "a model-at-capacity banner is overloaded" overloaded \
   "$(cls '⚠ Selected model is at capacity. Please try a different model.')"

# THE SERVICE BULLET IS NOT AN ANCHOR, and these two pin why it was removed rather than narrowed.
# One kind renders its own prose AND every one of its tool calls behind that bullet in column one —
# `shipyard_continuity_is_service_line` enumerates `• Ran `/`• Explored`/`• Edited ` off a real
# capture precisely because `'• '*` alone proves nothing. So a child in this repo grepping for the
# phrase, which is the normal case here and not an adversarial one, bought a permanent exemption.
ok "a bullet tool-call line carrying the phrase is refused" "" \
   "$(cls '• Ran grep -rn "usage limit" plugins/')"
ok "a bullet prose line carrying the phrase is refused" "" \
   "$(cls '• The watchdog fires on a usage limit and prescribes compaction')"
# And the specific line an earlier version pinned as a POSITIVE. It is chrome: the same repo file
# lists it beside `• Working`, i.e. among the lines that say nothing about the turn — it reports
# resets REMAINING, so a child showing it is not blocked at all.
ok "the remaining-resets chrome line is not a wait" "" \
   "$(cls '• You have 5 usage limit resets left')"

# A transport fault has NO observed glyph, so there is no arm for it at all. Both forms are refused,
# and that is the intended outcome rather than a gap: such a child falls through to the caller's
# stall path, whose remedy order opens with the nudge it needs. Widen from a capture, never from
# reasoning — which is exactly how the two defects above were introduced.
ok "a slept-mid-response fault is not classified, bare" "" \
   "$(cls 'API Error: Your computer went to sleep mid-response')"
ok "...nor behind the banner glyph"                     "" \
   "$(cls '⚠ API Error: Your computer went to sleep mid-response')"

# --- 2. nothing announced -> nothing, so the caller's stall path still owns the slot -------
ok "an ordinary idle frame yields no class" "" "$(cls 'Waiting for the pipeline to finish')"
ok "an empty screen yields no class"        "" "$(cls '')"
ok "no class is rc 1, not rc 0 with empty output" 1 \
   "$(adp_wait_class 'nothing to see' >/dev/null 2>&1; echo $?)"
ok "a class is rc 0" 0 \
   "$(adp_wait_class '⚠ Usage limit reached' >/dev/null 2>&1; echo $?)"

# --- 3. the evidence line comes back with the class ---------------------------------------
# The report PRINTS this in the WAITING row, so an operator can see which line bought the exemption
# instead of taking the verdict on trust — which matters most for the one case the staleness rule
# below cannot fully rule out.
ok "the deciding line is returned after the class" '⚠ Usage limit reached · at 2am' \
   "$(adp_wait_class '⚠ Usage limit reached · at 2am' | cut -f2)"

# --- 4. A BANNER GOES STALE the moment the client speaks again ----------------------------
# THE DEFECT THIS PINS, and it is the one an operator cannot see: "the last banner wins" is not
# enough. A child that hit a limit, resumed when the window reset, worked, and THEN genuinely wedged
# still has the banner inside the visible capture — and being motionless now does not make an
# hour-old banner current. Classifying it parks the slot, rebases its stall clock every tick and
# reports "resumes on its own. Do not nudge": the 8.5-hour silent stall, with a reassurance on top.
#
# The rule is mirrored from `shipyard_continuity_capacity_state`, which already counts banners since
# the last non-service line on the Codex parent path. Both progress glyphs are captured fixtures.
resumed_claude='⚠ Usage limit reached · continuing automatically at 2am
⏺ Resumed. Opening the PR next.'
resumed_codex='⚠ Selected model is at capacity. Please try a different model.
• Ran make check'
ok "a banner the client spoke after is stale (assistant glyph)" "" "$(cls "$resumed_claude")"
ok "a banner the client spoke after is stale (service bullet)"  "" "$(cls "$resumed_codex")"
# The converse, or the rule would be indistinguishable from "never classify anything": progress
# BEFORE the banner does not clear it, because the banner is then the newest thing said.
ok "progress ABOVE a banner leaves it live" rate_limited \
   "$(cls '⏺ Working on the review round.
⚠ Usage limit reached · continuing automatically at 2am')"
# And the composer is not progress — a draft sitting unsubmitted is the stall silhouette itself,
# not evidence the child moved on.
ok "a composer line below a banner does not clear it" rate_limited \
   "$(cls '⚠ Usage limit reached · continuing automatically at 2am
❯ next: run make check')"
# Two banners, the later one winning, with no progress between them.
ok "the later of two live banners wins" overloaded \
   "$(cls '⚠ Usage limit reached · continuing automatically at 2am
⚠ Selected model is at capacity. Please try a different model.')"

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
#
# THE GLYPH IS WRITTEN OUT, NOT DERIVED, and that is a correction of this very rig. It used to
# extract it with `sed -n 's/^\(.\) [A-Z].*/\1/p'` — but this file sets LC_ALL=C, so `.` matches one
# BYTE and the glyph is three, meaning the pattern could never match an assistant line at all. It
# matched an indented tool line instead and yielded a literal SPACE. The builder then rewrote an
# indented line, and the vacuity guard — computed from the same wrong value — passed. So the check
# labelled "a child's OWN prose" was testing indentation, which three other checks already cover:
# with the loose anchor restored in a scratch copy, it still passed. A guard built from the same
# expression as the thing it guards is not a guard, which is this repo's own lesson about vacuous
# checks, and it survived because both halves were wrong in the same direction.
assistant_glyph='⏺'
# Guard 1: the capture really does render assistant prose in column one behind that glyph. If a
# recapture ever changes it, this reds instead of quietly testing nothing.
ok "the capture renders assistant prose in column one" 1 \
   "$([ "$(grep -c "^${assistant_glyph} " "$FIX/pane-claude-running.txt")" -gt 0 ] && echo 1 || echo 0)"
# `index($0,g)==1` rather than `substr($0,1,1)==g`: substr is byte-wise under LC_ALL=C too, so it
# could never equal a three-byte glyph — the same trap one layer down.
prose=$(awk -v g="$assistant_glyph" '
    BEGIN { hit = 0 }
    index($0, g) == 1 && hit == 0 { print g " the watchdog fires on a usage limit and prescribes compaction"; hit = 1; next }
    { print }
  ' "$FIX/pane-claude-running.txt")
# Guard 2: the built line carries the phrase AND begins with the real glyph in column one. The
# second half is what a degenerate extraction could satisfy before; a space now fails it.
ok "the prose screen carries the phrase behind the glyph" 1 \
   "$(printf '%s\n' "$prose" | grep -c "^${assistant_glyph} the watchdog fires on a usage limit")"
ok "...and that line does not start with whitespace" 0 \
   "$(printf '%s\n' "$prose" | grep -c '^[[:space:]].*the watchdog fires on a usage limit')"
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
