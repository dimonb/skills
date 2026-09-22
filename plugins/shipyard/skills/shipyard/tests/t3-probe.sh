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
# NOTHING HERE COVERS THE TRANSCRIPT BRANCH, and no other file does either — see run-all.sh's
# uncovered list. On this path `peak` is assigned from `cur`, so which of the two feeds
# ctx_window is not asserted anywhere in the suite.
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
# emergency against another — so the column prints `?` and the raw count instead of choosing.
#
# What it replaces, measured on one child: 162k read `🛑 81% · 162k` and cleared only when the
# peak crossed 200k, so a 1M child alarmed through its ordinary early life. An alarm on the
# common path is one the operator learns to ignore, and this one invited compacting a healthy
# child mid-review — discarding live context to cure a condition it did not have.
ok "the #228 reading is no longer an alarm" "? 162k"   "$(probe '162000 tokens')"
ok "...and it bands unknown, never ok"      "unknown"  "$(band_of '162000 tokens')"

# BELOW the band nothing changes, and that is the half that keeps `?` rare: every listed
# candidate agrees the child is fine there, so the ordinary reading stands and a child's early
# life is not painted `❓` on the way past.
ok "an unproven reading below the band prints normally" "50 50% · 100k" "$(probe '100000 tokens')"
ok "...and bands ok"                                    "ok"            "$(band_of '100000 tokens')"
ok "one token under the threshold still prints"         "64 64% · 129k" "$(probe '129999 tokens')"

# It resolves ITSELF once the peak settles the window. That is what makes this a narrow state
# rather than a permanent one, and it is why no operator action is REQUIRED to leave it.
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

# --- THE THRESHOLD IS ONE VALUE, READ BY BOTH --------------------------------------------
# ctx_probe withholds the glyph at CTX_WARN_PCT and ctx_band raises it at the same variable. A
# second literal 65 in either would keep every assertion above green while the guarded region
# drifted away from the alarm it guards on the next threshold change — the "mutation never
# applied to the call site" shape. Both halves are checked: the behaviour follows the variable,
# and no bare literal is left behind to stop it following.
ok "raising the threshold narrows the suppression" "86 86% · 172k" \
   "$(CTX_WARN_PCT=90 probe '172188 tokens')"
ok "lowering it widens the suppression"            "? 100k" \
   "$(CTX_WARN_PCT=40 probe '100000 tokens')"
ok "no bare band threshold remains in the source" "0" \
   "$(grep -cE '\-ge (65|80)\b' "$SKILL_DIR/shipyard-ctx.sh")"

# --- the two "we do not know" sentinels must stay distinguishable ---------------------------
read -r p1 d1 <<<"$(probe '')"
read -r p2 d2 <<<"$(probe '1400000 tokens')"
ok "nothing-measured and out-of-range differ" "different" \
   "$([ "$p1" = "$p2" ] && echo same || echo different)"
ok "out-of-range display carries the raw figure" "1400k" "$d2"
ok "nothing-measured display is the em-dash"     "—"     "$d1"

# --- read -r splits every shape the way the report's call site does -------------------------
for pane in '' '98% context used' '628k tokens' '1400000 tokens'; do
  read -r pct disp <<<"$(probe "$pane")"
  ok "split yields a non-empty band key for [${pane:-empty}]" "yes" "$([ -n "$pct" ] && echo yes || echo no)"
  ok "split yields a non-empty display for [${pane:-empty}]"  "yes" "$([ -n "$disp" ] && echo yes || echo no)"
done

# --- WHICH of cur/peak feeds the window question — the one case that tells them apart --------
# Everything above runs through the PANE fallback, where ctx_probe assigns peak from cur, so no
# assertion there can distinguish a guard reading the peak from one reading the current total.
# ctx_window_unproven made that distinction load-bearing: it gates a percentage derived from
# `cur` on a question about `peak`. The case that separates them is the ordinary one — the
# client's own autocompact drops `cur` sharply and leaves `peak` where it was — and reading the
# CURRENT total there would let the inferred window bounce back down with it and re-band a
# healthy child, which is the defect `peak` was introduced to prevent in the first place.
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

# The mirror: a young session whose peak has ruled nothing out, at a current total high enough
# to alarm. Same current figure as above, and it reads differently — which is the whole point.
FAKE_TRANSCRIPT=$(transcript young)
usage_record 10 300 179690 0 >> "$FAKE_TRANSCRIPT"
usage_record 10 300 139690 0 >> "$FAKE_TRANSCRIPT"
ok "an unsettled peak withholds the percentage" "? 140k"  "$(probe '')"
ok "...and it bands unknown"                    "unknown" "$(band_of '')"

done_ t3-probe
