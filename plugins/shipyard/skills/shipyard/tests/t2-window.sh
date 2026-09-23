#!/usr/bin/env bash
# t2-window.sh — ctx_window: the inference, and the override that must beat it.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_helpers.sh
. "$DIR/_helpers.sh"

# --- the inference: smallest known size that fits the peak ---------------------------------
ok "peak 0 -> smallest"            "200000"  "$(ctx_window 0)"
ok "peak just under the boundary"  "200000"  "$(ctx_window 199999)"
ok "peak exactly on the boundary"  "200000"  "$(ctx_window 200000)"
ok "peak one over -> next size up" "1000000" "$(ctx_window 200001)"
ok "peak well over"                "1000000" "$(ctx_window 461514)"
ok "peak at the top of the list"   "1000000" "$(ctx_window 1000000)"
# Past everything known: return the largest rather than invent a size. ctx_probe turns the
# resulting >100% into the `?` band; see t3.
ok "peak past the whole list"      "1000000" "$(ctx_window 1000001)"

# --- ctx_window_unproven: was that window a DEDUCTION, or a CHOICE between listed sizes? -----
# The inference proves upward and only upward. A peak that has not passed the smallest listed
# size has ruled nothing out, so "smallest that fits" picked one candidate out of several; once
# the peak has passed it, that size is excluded and the next one up is a deduction. ctx_probe
# withholds a glyph in the first case (see t3), so this predicate is what decides where the alarm
# is allowed to speak — and a defect in it is silent in BOTH directions: too wide and the column
# stops warning a child that really is filling up, too narrow and #228's false alarm comes back.
unproven() { ctx_window_unproven "$1" && echo yes || echo no; }
ok "peak 0 has ruled nothing out"         "yes" "$(unproven 0)"
ok "peak just under the smallest size"    "yes" "$(unproven 199999)"
ok "peak exactly on the smallest size"    "yes" "$(unproven 200000)"
ok "peak one over -> the next size is a deduction" "no" "$(unproven 200001)"
ok "peak well over"                       "no"  "$(unproven 461514)"
# Past the whole list the peak is well clear of the smallest size, so the window is settled as
# far as this predicate is concerned. ctx_probe's >100% branch speaks for that reading instead;
# this one must stay out of its way.
ok "peak past the whole list"             "no"  "$(unproven 1000001)"

# --- THE BOUNDARY IS THE SMALLEST LISTED SIZE, NOT THE LAST ENTRY ---------------------------
# The first draft asked "is ctx_window's answer not the last entry?". On a two-entry list that is
# the same predicate; on a longer one it is not, and the difference blinds the fleet — only the
# topmost class could ever be proven, so APPENDING a size unproved every child below the new top.
# Measured on that draft: with 2000000 appended, a real `90% · 900k` crit became a bare `?`. The
# report's own block prints "add the size to CTX_WINDOWS" as a remedy, so the instrument would
# have been instructing the edit that blinded it. The trigger was a source edit, so no shipped
# list was ever affected — the shape was the defect, and this is what pins the fix.
_saved_windows=("${CTX_WINDOWS[@]}")
CTX_WINDOWS=(200000 1000000 2000000)
ok "a third entry leaves the middle class proven"  "no"  "$(unproven 900000)"
ok "...and the class above it"                     "no"  "$(unproven 1500000)"
ok "...while the smallest size still bounds"       "yes" "$(unproven 162000)"
# The length guard: with one entry there is no second candidate, so nothing is ever unproven.
# Without it every reading below the sole window would be, and the column would withhold wholesale.
CTX_WINDOWS=(200000)
ok "a single-entry list is never unproven"         "no"  "$(unproven 5000)"
ok "...at any peak"                                "no"  "$(unproven 199999)"
CTX_WINDOWS=("${_saved_windows[@]}")
ok "the list was restored for what follows" "200000 1000000" "${CTX_WINDOWS[*]}"

# A STATED window is never a guess — the operator said what it is, and nothing here re-opens it.
ok "override, peak below the whole list"  "no"  "$(SHIPYARD_CTX_WINDOW=1000000 unproven 5000)"
ok "override, peak above it"              "no"  "$(SHIPYARD_CTX_WINDOW=100000 unproven 900000)"
# A MALFORMED override is not a stated window. ctx_window ignores it and infers, so this must
# report the inference's state too — otherwise the operator's already-dead escape hatch would
# ALSO silently switch the guard off, and the column would go quiet for a reason nobody can see.
for bad in "1M" "1000k" "0" "abc"; do
  ok "malformed override '$bad' is not a stated window" "yes" "$(SHIPYARD_CTX_WINDOW="$bad" unproven 5000)"
done

# --- CTX_WINDOWS must stay ascending, or "smallest that fits" silently stops being true -----
prev=0; ascending=yes
for w in "${CTX_WINDOWS[@]}"; do
  [ "$w" -gt "$prev" ] || ascending=no
  prev=$w
done
ok "CTX_WINDOWS is ascending" "yes" "$ascending"

# --- the override wins unconditionally, INCLUDING DOWNWARDS ---------------------------------
ok "override above the peak"  "400000" "$(SHIPYARD_CTX_WINDOW=400000 ctx_window 300000)"
ok "override below the peak"  "400000" "$(SHIPYARD_CTX_WINDOW=400000 ctx_window 461514)"
# The load-bearing one: a window smaller than anything listed. No inference may overrule it.
ok "override below the whole list" "100000" "$(SHIPYARD_CTX_WINDOW=100000 ctx_window 461514)"
ok "override above the whole list" "2000000" "$(SHIPYARD_CTX_WINDOW=2000000 ctx_window 1500000)"

# --- a malformed override is REFUSED OUT LOUD, never silently ignored -----------------------
# A silently dead escape hatch is worse than none: the operator believes the band they are
# looking at is the one they configured.
#
# The warning lives in ctx_check_env, NOT in ctx_window, and that split is load-bearing rather
# than tidiness — see the comment above ctx_check_env. ctx_window runs once per slot, two
# command substitutions deep, so it must stay SILENT: a warning there cannot be suppressed, and
# a "have I warned yet" flag there cannot survive its own subshell.
for bad in "1M" "1000k" "0" "-5" " 400000" "abc" "400_000"; do
  got=$(SHIPYARD_CTX_WINDOW="$bad" ctx_window 100000 2>/dev/null)
  ok "malformed override '$bad' falls back to the inference" "200000" "$got"
  warn=$(SHIPYARD_CTX_WINDOW="$bad" ctx_check_env 2>&1 >/dev/null | head -1)
  case "$warn" in
    warning:*"$bad"*) ok "malformed override '$bad' warns on stderr" "yes" "yes" ;;
    *)                ok "malformed override '$bad' warns on stderr" "yes" "no: [$warn]" ;;
  esac
  warn=$(SHIPYARD_CTX_WINDOW="$bad" ctx_window 100000 2>&1 >/dev/null)
  ok "malformed override '$bad' is silent in ctx_window" "" "$warn"
done

# An UNSET override must not warn — only a set-but-invalid one.
warn=$(ctx_check_env 2>&1 >/dev/null)
ok "unset override is silent" "" "$warn"
# Nor may a VALID one.
warn=$(SHIPYARD_CTX_WINDOW=400000 ctx_check_env 2>&1 >/dev/null)
ok "valid override is silent" "" "$warn"

# --- THE WARNING FIRES ONCE PER PROCESS, NOT ONCE PER SLOT ----------------------------------
# The regression this block exists for, and the reason the check is a function of its own.
# An earlier fix put a "have I warned yet" flag INSIDE ctx_window. It was inert:
# shipyard-report.sh reaches it as $(ctx_window ...) nested in $(ctx_probe ...), so the flag was
# assigned in a grandchild shell that exited immediately. It measured as fixed only because it
# was measured with DIRECT calls — 15 of those warn once, while 15 probes through the real call
# shape warned 15 times, before and after the flag alike.
#
# Every assertion above also runs in its own command substitution, so none of them can tell the
# two apart. This one drives the shape shipyard-report.sh actually uses, in ONE shell, and counts.
# The drive REPORTS WHAT IT DID on stdout, and the assertions below check that too. Without it
# this test cannot tell "15 probes produced no warning" from "no probes ran at all" — both read
# as zero — so a renamed ctx_probe, a pane fixture that returns before ctx_window, or a syntax
# error after the first line would all leave it green while measuring nothing. That is the
# "reports success having asserted nothing" shape scripts/check.sh guards against by counting
# what it inspected; the count and the last probe result are this suite's version of that.
drive='
  . "$1/shipyard-ctx.sh"
  export CLAUDE_CONFIG_DIR=/nonexistent-so-the-probe-falls-through-to-the-pane
  ctx_check_env
  n=0
  for t in 1 2 3; do for s in 1 2 3 4 5; do
    read -r a b <<<"$(ctx_probe "$s" "accept edits 860000 tokens")"
    n=$((n+1))
  done; done
  printf "%s %s %s\n" "$n" "${a:-}" "${b:-}"
'
out=$(SHIPYARD_CTX_WINDOW=1M bash -c "$drive" _ "$SKILL_DIR" 2>"$CTX_TEST_DIR/drive.err")
n=$(grep -c '^warning:' "$CTX_TEST_DIR/drive.err")
ok "15 probes in one shell warn exactly once" "1" "$n"
# ...and the probes actually ran, and actually reached ctx_window. 860000 against an inferred
# 1000000 window is 86%; if ctx_probe returned early the band would be empty instead.
#
# THE FIGURE IS ABOVE THE SMALLEST LISTED WINDOW ON PURPOSE. The evidence this block needs is a
# PERCENTAGE — that is what proves the probe got as far as ctx_window rather than returning on
# an earlier branch. A figure below the smallest listed size now renders `?` at this band
# (ctx_window_unproven, t3), which ctx_probe also reaches after ctx_window but which the `?` at
# the top of the list produces too, so it would no longer tell those apart.
ok "the drive really ran 15 probes"          "15"          "$(printf '%s' "$out" | cut -d' ' -f1)"
ok "the drive's probes really banded"        "86"          "$(printf '%s' "$out" | cut -d' ' -f2)"

# --- THE CALL SITE ITSELF, not just the callee ----------------------------------------------
# The fix above moved the warning out of ctx_window and into ctx_check_env, which only helps if
# shipyard-report.sh actually calls it, ONCE, outside the per-slot loop. Nothing else asserts
# that: deleting the call, or moving it back inside the loop, leaves every other check here
# green — which is the same "the mutation was never applied to the call site" shape that let the
# original defect ship. So the call site is pinned here explicitly.
report="$SKILL_DIR/shipyard-report.sh"
ok "shipyard-report.sh calls ctx_check_env once" "1" "$(grep -c '^ctx_check_env$' "$report")"
call_line=$(grep -n '^ctx_check_env$' "$report" | cut -d: -f1)
loop_line=$(grep -n '^for slot in ' "$report" | cut -d: -f1)
if [ -n "$call_line" ] && [ -n "$loop_line" ] && [ "$call_line" -lt "$loop_line" ]; then
  ok "the call is above the per-slot loop" "yes" "yes"
else
  ok "the call is above the per-slot loop" "yes" "no: call=$call_line loop=$loop_line"
fi

# --- THE DECLARED WINDOW: evidence, where there used to be only a guess --------------------
# The transcript names the model WITH its window marker in an `attachment` record, so a 1M child
# no longer has to wait for its peak to cross 200000 before the column stops bounding it. What
# this block pins is the SHAPE of that reading, because every part of it is a way to get it wrong
# silently: a parse that takes the first record instead of the last follows a switched model
# backwards; one that treats a bare id as the small window turns the absence of evidence into a
# fact; one that dies on a half-written final line takes the whole column down with it.
f=$(transcript declared-1m)
usage_record 10 300 120000 0 >> "$f"
model_record "claude-opus-5-5[1m]" >> "$f"
ok "a marked id declares the large window" "1000000" "$(ctx_declared_window "$f")"

# READ IN ONE DIRECTION ONLY. A default-window session carries no suffix, and neither would a
# future model whose default is large, so a bare id must yield NOTHING rather than 200000 — the
# inference then handles it exactly as before. Reading it as the small window would be the same
# guess wearing the clothes of a fact, in the direction that under-warns.
f=$(transcript declared-bare)
model_record "claude-opus-5" "Opus 5" >> "$f"
ok "an unmarked id declares nothing" "" "$(ctx_declared_window "$f")"
f=$(transcript declared-none)
usage_record 10 300 120000 0 >> "$f"
ok "no model record at all declares nothing" "" "$(ctx_declared_window "$f")"

# THE LAST RECORD WINS. A session whose model is switched mid-run writes another record, and the
# newest is the model the NEXT request runs on — the one the percentage is about. Taking the first
# would pin a 1M child to a window it left, or keep asserting 1M after a switch down.
f=$(transcript declared-switched)
model_record "claude-opus-5-5[1m]" >> "$f"
usage_record 10 300 120000 0 >> "$f"
model_record "claude-opus-5" "Opus 5" >> "$f"
ok "a switch away from the marked model is followed" "" "$(ctx_declared_window "$f")"
f=$(transcript declared-switched-up)
model_record "claude-opus-5" "Opus 5" >> "$f"
model_record "claude-opus-5-5[1m]" >> "$f"
ok "...and a switch towards it" "1000000" "$(ctx_declared_window "$f")"

# A TRANSCRIPT IS READ WHILE IT IS BEING WRITTEN, so the final line is regularly a partial one.
# `fromjson?` must swallow it; without that the column would blink out for exactly as long as the
# child is mid-write, which is most of the time it matters.
f=$(transcript declared-torn)
model_record "claude-opus-5-5[1m]" >> "$f"
printf '{"type":"assistant","message":{"usage":{"input_tok' >> "$f"
ok "a half-written final line is survived" "1000000" "$(ctx_declared_window "$f")"

# --- PRECEDENCE: override > declared > inference ---------------------------------------------
# The middle rank is the new one and the only one in question. Above it, the operator's stated
# window must still win IN BOTH DIRECTIONS — the escape hatch exists for a size nobody's evidence
# names, and evidence that could overrule it would close the hatch silently.
ok "declared beats the inference"        "1000000" "$(ctx_window 5000 1000000)"
ok "declared where the inference agreed" "1000000" "$(ctx_window 461514 1000000)"
ok "override beats declared, upwards"    "2000000" "$(SHIPYARD_CTX_WINDOW=2000000 ctx_window 5000 1000000)"
ok "override beats declared, DOWNWARDS"  "100000"  "$(SHIPYARD_CTX_WINDOW=100000 ctx_window 5000 1000000)"
# A malformed declared value is not evidence, for the same reason a malformed override is not a
# stated window: it falls through rather than scaling anything against a garbage figure.
for bad in "1M" "1000k" "0" "abc" ""; do
  ok "malformed declared '$bad' falls back to the inference" "200000" "$(ctx_window 5000 "$bad")"
done

# A DECLARED WINDOW IS SETTLED, so the `?` band and its bound are not for it. This is the half
# that actually removes the false alarm: a 1M child early in its life sits below 200000, which
# unproven() calls a guess, and the bound then renders `<=84% · 169k` for a child at 16%.
unproven_d() { ctx_window_unproven "$1" "$2" && echo yes || echo no; }
ok "declared leaves the ? band"          "no"  "$(unproven_d 5000 1000000)"
ok "...at any peak below the smallest"   "no"  "$(unproven_d 199999 1000000)"
ok "no declaration still bounds"         "yes" "$(unproven 199999)"
ok "malformed declared still bounds"     "yes" "$(unproven_d 199999 abc)"

# --- THE CALL SITE, BEHAVIOURALLY -----------------------------------------------------------
# This file's own recurring lesson: a callee fixed and a call site left alone leaves every other
# check here green. ctx_probe must read the declaration AND pass it to both functions, so this
# drives the real path — the transcript lookup ctx_claude_transcript computes from $ROOT and
# CLAUDE_CONFIG_DIR — rather than asserting on the source text. 169365 tokens is the reading that
# prompted the change: `? <=84%` before, `16%` after.
probe_dir="$CTX_TEST_DIR/callsite"
wt="$probe_dir/root/.claude/worktrees/ship-p1"
mkdir -p "$wt"
# pwd -P as the function does it: on macOS the temp root is itself a symlink, and a slug built
# from the unresolved path names a directory the lookup will never visit.
wt_real=$(cd "$wt" && pwd -P)
slug=$(printf '%s' "$wt_real" | sed 's/[^A-Za-z0-9]/-/g')
mkdir -p "$probe_dir/cfg/projects/$slug"
pf="$probe_dir/cfg/projects/$slug/session.jsonl"
usage_record 165 200 169000 0 > "$pf"     # 169365, below the smallest listed window
probe() {
  ROOT="$probe_dir/root" CLAUDE_CONFIG_DIR="$probe_dir/cfg" ctx_probe p1 ""
}
ok "without a declaration the probe bounds it" "? <=84% · 169k" "$(probe)"
model_record "claude-opus-5-5[1m]" >> "$pf"
ok "with one it reads plainly"                 "16 16% · 169k"  "$(probe)"
# And the operator still outranks the evidence at the call site, not only in the callee.
ok "the override still wins through the probe" "84 84% · 169k" "$(SHIPYARD_CTX_WINDOW=200000 probe)"


done_ t2-window
