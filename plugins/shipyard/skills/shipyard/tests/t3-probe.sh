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

# ctx_probe reads a transcript through ctx_transcript, which needs $ROOT and a project dir; the
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

done_ t3-probe
