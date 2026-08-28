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
    read -r a b <<<"$(ctx_probe "$s" "accept edits 172188 tokens")"
    n=$((n+1))
  done; done
  printf "%s %s %s\n" "$n" "${a:-}" "${b:-}"
'
out=$(SHIPYARD_CTX_WINDOW=1M bash -c "$drive" _ "$SKILL_DIR" 2>"$CTX_TEST_DIR/drive.err")
n=$(grep -c '^warning:' "$CTX_TEST_DIR/drive.err")
ok "15 probes in one shell warn exactly once" "1" "$n"
# ...and the probes actually ran, and actually reached ctx_window. 172188 against an inferred
# 200000 window is 86%; if ctx_probe returned early the band would be empty instead.
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

done_ t2-window
