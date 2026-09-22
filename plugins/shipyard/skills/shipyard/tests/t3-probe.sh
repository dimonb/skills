#!/usr/bin/env bash
# t3-probe.sh — ctx_probe's output shapes and ctx_band's reading of them.
#
# The assertion that earns this file: the alarm must not switch OFF as the number goes UP.
# ctx_probe once returned the same `-` sentinel for "nothing measured" and for "larger than any
# window I know", so ctx_band mapped both to `ok` — and with an override of 400000, 400001 tokens
# banded crit while 450000 banded ok, with no glyph, sitting next to healthy rows.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_helpers.sh
. "$DIR/_helpers.sh"

# ctx_probe reads a transcript through ctx_claude_transcript, which needs $ROOT and a project dir; the
# shapes below are exercised through the PANE fallback instead, which reaches the identical
# window/percentage/banding code with no filesystem setup.
#
# On the pane path `peak` is assigned from `cur`, so nothing ABOVE can distinguish which of the
# two feeds ctx_window. The block at the END of this file can: it reaches ctx_probe's transcript
# branch by replacing the LOOKUP with a fixture path, leaving ctx_totals and the window logic to
# run for real. What stays uncovered there is how the file is FOUND on the claude path — the
# project-directory slug, the newest-by-mtime choice, the subagent exclusion and the
# CLAUDE_CONFIG_DIR/CLAUDE_HOME resolution. (The codex lookup is covered for real by t6.) See
# run-all.sh's uncovered list, which says the same and must stay in step with this.
ROOT="$CTX_TEST_DIR/norepo"

probe() { ctx_probe nosuchslot "$1" 2>/dev/null; }
# band_of <pane text> — the band a row would actually get.
band_of() { local p; read -r p _ <<<"$(probe "$1")"; ctx_band "$p"; }

# --- nothing measurable is "—", never 0% ----------------------------------------------------
ok "empty pane -> em-dash"        "- —" "$(probe '')"
ok "empty pane bands ok"          "ok"  "$(band_of '')"
ok "only per-turn counters -> em-dash" "- —" "$(probe '8m 6s · ↓ 84.4k tokens')"

# --- the footer percentage form needs no window at all --------------------------------------
ok "footer percentage passes through" "98 98%" "$(probe '  98% context used  ')"
ok "footer percentage bands crit"     "crit"   "$(band_of '98% context used')"

# --- the footer token form goes through the same inference ----------------------------------
ok "footer token total -> pct and raw" "62 62% · 628k" "$(probe '/clear to save 628k tokens')"

# --- NEVER a percentage above 100 -----------------------------------------------------------
# The percentage is computed with awk's `printf "%d"`, which TRUNCATES, so the changeover is at
# 101% of the window rather than at the first token past it: 400001/400000 still renders "100%",
# which is not a percentage above 100 and is not a lie. What must never happen is a reading in
# that region going quiet, so the sweep below asserts the property rather than a guessed boundary.
ok "exactly 100% still prints a percentage" \
   "100 100% · 400k" "$(SHIPYARD_CTX_WINDOW=400000 probe '400000 tokens')"
ok "a hair over still prints 100%, not 101%" \
   "100 100% · 400k" "$(SHIPYARD_CTX_WINDOW=400000 probe '400001 tokens')"
ok "clearly over prints the bare figure" \
   "? 450k" "$(SHIPYARD_CTX_WINDOW=400000 probe '450000 tokens')"

# No reading anywhere across the changeover may band `ok`, and none may print >100%.
sweep_ok=""; sweep_over=""
for t in 390000 399999 400000 400001 402000 404000 410000 450000 800000 1600000; do
  read -r p _ <<<"$(SHIPYARD_CTX_WINDOW=400000 probe "$t tokens")"
  [ "$(ctx_band "$p")" = ok ] && sweep_ok="$sweep_ok $t"
  case "$p" in ''|-|'?') ;; *) [ "$p" -gt 100 ] 2>/dev/null && sweep_over="$sweep_over $t" ;; esac
done
ok "nothing at or past the ceiling bands ok" "" "$sweep_ok"
ok "no reading prints a percentage above 100" "" "$sweep_over"

# --- THE REGRESSION: over the ceiling must not read as healthy ------------------------------
ok "just under the ceiling bands crit" "crit" "$(SHIPYARD_CTX_WINDOW=400000 band_of '390000 tokens')"
ok "at the ceiling bands crit"         "crit" "$(SHIPYARD_CTX_WINDOW=400000 band_of '400000 tokens')"
ok "OVER the ceiling does not band ok" "unknown" "$(SHIPYARD_CTX_WINDOW=400000 band_of '450000 tokens')"
ok "far over the ceiling does not band ok" "unknown" "$(SHIPYARD_CTX_WINDOW=400000 band_of '900000 tokens')"
# With no override at all, past the top of CTX_WINDOWS.
ok "past the whole window list is unknown" "unknown" "$(band_of '1400000 tokens')"

# --- AN UNPROVEN WINDOW MAY NOT RAISE A GLYPH (#228) ----------------------------------------
# A glyph is an assertion. Before a claude child's peak passes the smallest listed window nothing
# has been ruled out — the same token count is a comfortable fraction of one listed window and an
# emergency against another — so the column prints `?` and a bound against the smallest listed
# size still consistent with the peak, instead of choosing between them.
#
# What it replaces, measured on one child: 162k read `🛑 81% · 162k` and cleared only when the
# peak crossed 200k, so a 1M child alarmed through its ordinary early life. An alarm on the
# common path is one the operator learns to ignore, and this one invited compacting a healthy
# child mid-review — discarding live context to cure a condition it did not have.
ok "the #228 reading is no longer an alarm" "? <=81% · 162k" "$(probe '162000 tokens')"
ok "...and it bands unknown, never ok"      "unknown"        "$(band_of '162000 tokens')"

# THE BOUND IS PRINTED, NOT WITHHELD, and it is what makes the permanent case livable. A child
# whose real window IS the smallest listed size can never settle it (its peak cannot exceed its
# own window), so it never leaves this branch — and it is the DEFAULT deployment, since nothing
# pins a model at launch. A bare `?` would leave that operator with an unscaled number for the
# child's whole life; the bound is true, needs no configuration act, and is actionable on sight.
ok "the bound is exact at the boundary"  "? <=100% · 200k" "$(probe '200000 tokens')"
ok "...and one token under"              "? <=99% · 199k"  "$(probe '199999 tokens')"
ok "a mid-range unproven reading is bounded" "? <=92% · 185k" "$(probe '185000 tokens')"

# It is an UPPER bound, so it must be taken against the SMALLEST still-consistent window — the
# largest percentage any listed candidate could produce. Taken against any other it would either
# understate (and reassure about a child at its ceiling) or exceed what the evidence supports.
# 162000 is 81% of 200000 and 16% of 1000000; the bound is the 81.
ok "the bound uses the smallest consistent window" "81" \
   "$(read -r _ b <<<"$(probe '162000 tokens')"; printf '%s' "${b#<=}" | sed 's/%.*//')"

# BELOW the band nothing changes: every listed candidate agrees the child is fine there, so the
# ordinary reading stands. That is what confines `?` to readings which would otherwise raise a
# glyph — NOT what makes it rare. It is not rare: it is the standing state of any child whose peak
# has not settled the window, and permanent for one whose window is the smallest listed size. Only
# the past-the-list cause is rare (see the bound note above ctx_window).
ok "an unproven reading below the band prints normally" "50 50% · 100k" "$(probe '100000 tokens')"
ok "...and bands ok"                                    "ok"            "$(band_of '100000 tokens')"
ok "one token under the threshold still prints"         "64 64% · 129k" "$(probe '129999 tokens')"

# It resolves itself once the peak passes the smallest listed size — WHICH ONLY A CHILD ON A
# LARGER WINDOW CAN DO. 200001 is a reading a 200k child cannot produce, so this pair pins the
# self-resolving population and NOT the other one: a child whose real window IS the smallest
# listed size never leaves the bounded state, because its peak cannot exceed its own window. That
# is why the bound is printed rather than withheld, and it is asserted above, not assumed here.
ok "past the smallest window the percentage returns" "20 20% · 200k" "$(probe '200001 tokens')"
ok "...and bands ok"                                 "ok"            "$(band_of '200001 tokens')"

# A PROVEN window still alarms. The quiet above must not have been bought by switching the alarm
# off: a child really at 90% of a window the evidence established is the case this column exists
# for, and it is the reading that would be silently lost if the guard were too wide.
ok "a proven window still crits" "90 90% · 900k" "$(probe '900000 tokens')"
ok "...and bands crit"           "crit"          "$(band_of '900000 tokens')"

# A STATED window is never unproven, in EITHER direction — the operator said what it is.
ok "override alarms below the smallest listed size" "81 81% · 162k" \
   "$(SHIPYARD_CTX_WINDOW=200000 probe '162000 tokens')"
ok "...and bands crit"                              "crit" \
   "$(SHIPYARD_CTX_WINDOW=200000 band_of '162000 tokens')"
ok "override resolves the #228 reading outright"    "16 16% · 162k" \
   "$(SHIPYARD_CTX_WINDOW=1000000 probe '162000 tokens')"

# The footer PERCENTAGE form needs no window at all, so none of this touches it: the client did
# the scaling, and there is nothing to be unproven about.
ok "footer percentage still alarms" "crit" "$(band_of '98% context used')"

# --- "WOULD THIS RAISE A GLYPH?" IS ONE QUESTION WITH ONE OWNER ---------------------------
# ctx_probe asks ctx_band whether the reading would raise a glyph, rather than comparing against
# CTX_WARN_PCT itself. The first draft did compare directly, and it was correct only while the
# two thresholds stayed in order: the case below skipped the guard at 86 (below a warn threshold
# of 90) and then banded crit (at or above a crit threshold of 80), asserting a percentage
# against a window nothing established — the one thing this branch exists to forbid. Reachable by
# a config edit and by no test, which is why it is pinned here.
ok "out-of-order thresholds cannot slip past the guard" "unknown" \
   "$(p=$(CTX_WARN_PCT=90 CTX_CRIT_PCT=80 probe '172188 tokens'); CTX_WARN_PCT=90 CTX_CRIT_PCT=80 ctx_band "${p%% *}")"

# The guarded region still follows the thresholds, in both directions. Raising the warn threshold
# ALONE does not narrow it — 86 is still at or above the crit threshold, so the band is still a
# glyph and the guard still fires. Both have to move, which is the point of asking ctx_band
# instead of one constant: the guarded region is the glyph region by construction, not by a
# comparison that happens to agree with it.
ok "raising only the warn threshold does not narrow it" "? <=86% · 172k" \
   "$(CTX_WARN_PCT=90 probe '172188 tokens')"
ok "raising both narrows the suppression" "86 86% · 172k" \
   "$(CTX_WARN_PCT=90 CTX_CRIT_PCT=95 probe '172188 tokens')"
ok "lowering the warn threshold widens it" "? <=50% · 100k" \
   "$(CTX_WARN_PCT=40 probe '100000 tokens')"
ok "no bare band threshold remains in the source" "0" \
   "$(grep -cE '\-ge (65|80)\b' "$SKILL_DIR/shipyard-ctx.sh")"

# --- APPENDING A WINDOW SIZE MUST NOT BLIND THE FLEET -------------------------------------
# ctx_window_unproven measures against the SMALLEST listed size. An earlier draft measured
# against the LAST, which meant only the topmost class could ever be proven — so appending an
# entry silently unproved every child below the new top, and the report's own UNSCALED block
# prints "add the size to CTX_WINDOWS" as a remedy, making the instrument instruct the edit that
# blinded it. Measured on that draft: appending 2000000 turned `90 90% · 900k` into a bare `?`.
# The trigger was a source edit, so no shipped list was affected — the shape was the defect.
# The list is swapped in THIS shell and restored after, rather than inside a subshell: `ok`
# accumulates CHECKS and FAILURES, and a subshell would discard both — so a failure in here would
# be invisible unless the count were re-added by hand, which is the enumerable shape that rots.
_saved_windows=("${CTX_WINDOWS[@]}")

CTX_WINDOWS=(200000 1000000 2000000)
ok "appending a size keeps a proven crit"          "90 90% · 900k"  "$(probe '900000 tokens')"
ok "appending a size keeps a proven warn"          "65 65% · 650k"  "$(probe '650000 tokens')"
ok "...and resolves the reading it was added for"  "62 62% · 1240k" "$(probe '1240000 tokens')"
ok "the smallest size still bounds the young"      "? <=81% · 162k" "$(probe '162000 tokens')"

# A ONE-ENTRY list has nothing to be unproven against — the sole window is the only candidate, so
# the ordinary reading stands. Without the length guard in ctx_window_unproven, every reading
# below that window would be bounded instead and the whole column would withhold at once.
CTX_WINDOWS=(200000)
ok "a single-entry list never withholds" "81 81% · 162k" "$(probe '162000 tokens')"

CTX_WINDOWS=("${_saved_windows[@]}")
ok "the list was restored for what follows" "200000 1000000" "${CTX_WINDOWS[*]}"

# --- the two "we do not know" sentinels must stay distinguishable ---------------------------
read -r p1 d1 <<<"$(probe '')"
read -r p2 d2 <<<"$(probe '1400000 tokens')"
ok "nothing-measured and out-of-range differ" "different" \
   "$([ "$p1" = "$p2" ] && echo same || echo different)"
ok "out-of-range display carries the raw figure" "1400k" "$d2"
ok "nothing-measured display is the em-dash"     "—"     "$d1"

# --- read -r splits every shape the way the report's call site does -------------------------
# The bounded shape is in this list because the report does more than render its display: it
# DISPATCHES on it (`case "$disp" in '<='*`) to choose which remedy the operator is told. If the
# split ever left a leading token before the `<=`, every bounded slot would silently fall to the
# other arm and be told to add a CTX_WINDOWS entry — the one remedy that cannot clear a bound, and
# which moves the guard's boundary if the entry is below the current smallest. So the parse the
# report depends on is pinned here, by the loop that claims to cover every shape.
for pane in '' '98% context used' '628k tokens' '1400000 tokens' '162000 tokens'; do
  read -r pct disp <<<"$(probe "$pane")"
  ok "split yields a non-empty band key for [${pane:-empty}]" "yes" "$([ -n "$pct" ] && echo yes || echo no)"
  ok "split yields a non-empty display for [${pane:-empty}]"  "yes" "$([ -n "$disp" ] && echo yes || echo no)"
done
read -r _ disp <<<"$(probe '162000 tokens')"
ok "the bounded display survives the split with its <= intact" "bound" \
   "$(case "$disp" in '<='*) echo bound ;; *) echo "other: [$disp]" ;; esac)"

# --- WHICH of cur/peak feeds the window question — the one case that tells them apart --------
# Everything above runs through the PANE fallback, where ctx_probe assigns peak from cur, so no
# assertion there can distinguish the two. What these cases guard is `win=$(ctx_window "$peak")`,
# the assignment the whole reading is scaled by. The case that separates them is the ordinary
# one — the client's own autocompact drops `cur` sharply and leaves `peak` where it was — and
# reading the CURRENT total there would let the inferred window bounce back down with it and
# re-band a healthy child, which is the defect `peak` was introduced to prevent. Mutating that
# assignment to `cur` reds these two.
#
# THEY DO NOT GUARD ctx_window_unproven's OWN ARGUMENT — that is guarded separately, below.
#
# Two drafts of this comment were wrong in opposite directions, and both are worth recording. The
# first said these cases guarded the predicate's argument; they do not. The second said "no case
# can red it, because the two are indistinguishable for every reachable input" — a claim about a
# SOLUTION SPACE, which is the shape AGENTS.md names as the worse one, and it was false. It held
# only of the shipped DATA: 65% of 1000000 already exceeds 200000, so any reading that reaches the
# guard has `cur` past the smaller size too, and `peak >= cur` always. Move the list and the two
# separate immediately — see the case below, which does exactly that.
#
# WHAT THIS FAKES, and what it therefore does not prove: `ctx_claude_transcript` is replaced, so
# the project-directory slug, the newest-by-mtime choice and the config-directory resolution stay
# exactly as uncovered as run-all.sh says they are. Only the lookup is faked — ctx_totals and the
# window logic under test run for real over a real fixture file.
ctx_claude_transcript() { printf '%s' "$FAKE_TRANSCRIPT"; }

# Autocompacted: the session peaked at 900000 (which rules the smallest window out) and now
# carries 140000. The window question is settled by the peak, so this prints a percentage.
FAKE_TRANSCRIPT=$(transcript compacted)
usage_record 10 300 899690 0 >> "$FAKE_TRANSCRIPT"
usage_record 10 300 139690 0 >> "$FAKE_TRANSCRIPT"
ok "cur and peak really differ in the fixture" "140000 900000" "$(ctx_totals "$FAKE_TRANSCRIPT")"
ok "the peak settles the window, not the current total" "14 14% · 140k" "$(probe '')"
ok "...and it bands ok"                                 "ok"            "$(band_of '')"

# The mirror: a session whose peak has ruled nothing out, at a current total high enough to
# alarm. Same current figure as above, and it reads differently — which is the whole point.
# NOT called "young": on a 200k window this is every session, not an early phase of one.
FAKE_TRANSCRIPT=$(transcript unsettled)
usage_record 10 300 179690 0 >> "$FAKE_TRANSCRIPT"
usage_record 10 300 139690 0 >> "$FAKE_TRANSCRIPT"
ok "an unsettled peak bounds rather than measures" "? <=70% · 140k" "$(probe '')"
ok "...and it bands unknown"                       "unknown"        "$(band_of '')"

# --- THE PREDICATE'S OWN ARGUMENT: peak, not cur -------------------------------------------
# This is the case an earlier comment here said could not exist. It cannot be built on the shipped
# list, because 65% of the larger size already exceeds the smaller one — but that is a property of
# the DATA, not of the code, and bringing the two sizes closer separates them at once.
#
# With CTX_WINDOWS=(200000 300000), peak=250000 and cur=195000: ctx_window(peak) is 300000 and the
# percentage is 65, so the guard is reached. The peak has passed 200000, so the window IS settled
# and the ordinary reading is correct. A predicate reading `cur` instead would see 195000 <= 200000,
# call it unsettled, and withhold the band from a child whose window the evidence had already
# established — the alarm going quiet on a reading that was earned.
CTX_WINDOWS=(200000 300000)
FAKE_TRANSCRIPT=$(transcript settled-but-low-current)
usage_record 10 300 249690 0 >> "$FAKE_TRANSCRIPT"
usage_record 10 300 194690 0 >> "$FAKE_TRANSCRIPT"
ok "cur and peak straddle the smallest size" "195000 250000" "$(ctx_totals "$FAKE_TRANSCRIPT")"
ok "a settled peak measures, even with cur below the smallest size" "65 65% · 195k" "$(probe '')"
ok "...and bands warn, not unknown"                                 "warn"          "$(band_of '')"
CTX_WINDOWS=("${_saved_windows[@]}")
ok "the list was restored at the end" "200000 1000000" "${CTX_WINDOWS[*]}"

done_ t3-probe
