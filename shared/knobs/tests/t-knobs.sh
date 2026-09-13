#!/usr/bin/env bash
# t-knobs — reading an operator-set poll knob safely (shared/knobs/knobs.sh).
#
# PROVENANCE. Every case here traces to a defect that SHIPPED, in both skills, past validation
# that was written specifically to prevent it:
#
#   * `08` passed an all-digits test and then failed the `$(( … ))` that consumed it, as octal.
#     MEASURED, because three earlier descriptions of this in the tree each said "kills the shell"
#     and none of them was right: at script top level bash prints the error and CONTINUES with an
#     empty assignment, so `shipyard tell` broke its poll after one sample; inside a function the
#     rest of the function is abandoned, so `council say` returned with no verdict. Both happen
#     after the message is already typed and submitted, which is what makes either one matter.
#   * zero was rejected by ENUMERATING its spellings (`0|0.|0.0|.0`), which missed `00`, `000`,
#     `0.00`, `.00` and `000.000`. Each makes `sleep` a no-op and the bounded poll a fork storm.
#   * a value above INT_MAX has a non-zero digit, so a shape test alone admits it — and `sleep`
#     refuses it outright, which spins AND floods stderr with usage lines that bury the verdict.
#
# So the two negative directions are BOTH asserted for both knobs. Too loose restores the broken
# poll or the spin; too tight refuses a setting an operator legitimately wants, and a knob that ignores
# what you set is worse than no knob.
#
# Everything under test is a pure function over two strings, so this needs no terminal, no repo and
# no backend: it sources the module and calls it.
#
# WHAT IS NOT COVERED, so a green run is never read as more than it is: what the CALLERS do with
# these values. That the window reaches a deadline and the interval reaches a `sleep` is asserted
# where each caller lives — `plugins/council/.../tests/t21-say.sh` section 4 and
# `plugins/shipyard/.../tests/t16-tell-knobs.sh`.
set -uo pipefail
export LC_ALL=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$DIR/../knobs.sh"
[ -f "$MOD" ] || { echo "t-knobs: cannot find knobs.sh at $MOD" >&2; exit 1; }
# shellcheck source=../knobs.sh
. "$MOD"

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}

# "<value>|<rc>" — the effective value and whether the default was substituted, in one string, so
# a case that returns the right number for the wrong reason cannot pass.
u() { local o rc=0; o=$(knob_uint "$1" 10) || rc=$?; printf '%s|%s' "$o" "$rc"; }
i() { local o rc=0; o=$(knob_interval "$1" 0.5) || rc=$?; printf '%s|%s' "$o" "$rc"; }

printf '\n── knob_uint: the window ──\n'
ok "a plain value is used as given"        "10|0" "$(u 10)"
ok "one digit"                             "5|0"  "$(u 5)"
# ZERO IS LEGITIMATE, not a fallback: it means "take one post-send sample and decide". council's
# t21-say.sh poll cases use it to stay fast — that suite and not, as an earlier version of this
# said, "both": no shipyard test sets a zero window.
ok "zero is a valid window, not a fallback" "0|0" "$(u 0)"
# THE OCTAL CASE. Not "rejected" — NORMALISED, because a leading zero is a typo with an obvious
# intent, and honouring it beats refusing it.
ok "a leading zero means base ten"         "8|0"  "$(u 08)"
ok "...and so does a longer one"           "10|0" "$(u 010)"
ok "...even spelled with many zeros"       "7|0"  "$(u 0000007)"
ok "...and all-zeros is still zero"        "0|0"  "$(u 000)"
# AN UNSET KNOB IS SILENT. `${VAR:-}` makes "set nothing" and "set rubbish" both arrive empty, and
# answering 1 to both made every caller warn on its DEFAULT path — a false alarm on every directive
# and every hand-off. rc 0 is the assertion that keeps that shut.
ok "unset is the default, QUIETLY"         "10|0" "$(u '')"
ok "a word falls back"                     "10|1" "$(u nonsense)"
ok "a decimal is not a whole number"       "10|1" "$(u 2.5)"
ok "a sign is not a digit"                 "10|1" "$(u +2)"
ok "...in either direction"                "10|1" "$(u -2)"
ok "whitespace falls back"                 "10|1" "$(u ' 2')"
ok "...on either side"                     "10|1" "$(u '2 ')"
ok "exponent notation falls back"          "10|1" "$(u 1e3)"
# The cap keeps the window PLAUSIBLE; it is not protecting the arithmetic. Measured: `$(( 10#… ))`
# on a twenty-digit value wraps silently at status 0 rather than erroring, so the version of this
# comment that said it "dies exactly like the octal case" was simply wrong.
ok "nine digits is still usable"           "999999999|0" "$(u 999999999)"
ok "ten digits falls back"                 "10|1" "$(u 1000000000)"
ok "...however many more"                  "10|1" "$(u 99999999999)"

printf '\n── knob_interval: the sleep between samples ──\n'
ok "the default shape is used as given"    "0.5|0"  "$(i 0.5)"
ok "a whole number is fine"                "1|0"    "$(i 1)"
ok "a leading dot is fine"                 ".5|0"   "$(i .5)"
ok "a small fraction is kept"              "0.05|0" "$(i 0.05)"
ok "...and a very small one"               "0.001|0" "$(i 0.001)"
# EVERY SPELLING OF ZERO, which is the point of testing the shape instead of listing instances.
# The first four are what the old enumeration caught; the rest are what it missed.
ok "zero falls back"                       "0.5|1" "$(i 0)"
ok "trailing-dot zero falls back"          "0.5|1" "$(i 0.)"
ok "zero point zero falls back"            "0.5|1" "$(i 0.0)"
ok "dot zero falls back"                   "0.5|1" "$(i .0)"
ok "double zero falls back"                "0.5|1" "$(i 00)"
ok "triple zero falls back"                "0.5|1" "$(i 000)"
ok "zero point double-zero falls back"     "0.5|1" "$(i 0.00)"
ok "dot double-zero falls back"            "0.5|1" "$(i .00)"
ok "zeros either side of the dot"          "0.5|1" "$(i 000.000)"
# A bare dot is not zero, but `sleep .` errors every iteration, which spins the same way.
ok "a bare dot falls back"                 "0.5|1" "$(i .)"
ok "unset is the default, QUIETLY"         "0.5|0" "$(i '')"
ok "a word falls back"                     "0.5|1" "$(i abc)"
ok "two dots falls back"                   "0.5|1" "$(i 1.2.3)"
ok "a sign falls back"                     "0.5|1" "$(i -1)"
# ABOVE INT_MAX: it HAS a non-zero digit, so the shape test admits it and only the length cap
# refuses it. `sleep` rejects it outright, so it spins and floods stderr.
ok "an oversized interval falls back"      "0.5|1" "$(i 9999999999)"
# Nine CHARACTERS, not nine digits — the cap counts the dot too. Spelled out because the honest
# cost of that is visible right here: a longer fraction like `0.12345678` is refused.
ok "nine characters is still usable"       "123456.78|0" "$(i 123456.78)"
ok "...and a tenth character is refused"   "0.5|1"       "$(i 0.12345678)"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 't-knobs: %d checks, all passed\n' "$CHECKS"
  exit 0
fi
printf 't-knobs: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"
exit 1
