# knobs.sh — reading an operator-set POLL KNOB safely, shared by shipyard and council.
#
# SOURCE OF TRUTH: shared/knobs/knobs.sh. Do NOT edit the vendored copies under
# plugins/*/skills/*/ — edit here, then run `scripts/sync-driver.sh`. The repo gate
# (scripts/check.sh, check 11) fails if any copy drifts from this file.
#
# Source only, never execute. Sourced into a shell that may run `set -u`, so every optional
# variable is read as `${VAR:-}`. Pure: no forks, no state, no I/O — a caller prints its own
# diagnostic, in its own vocabulary, from the exit status.
#
# WHAT THIS IS FOR. Both skills confirm a message landed by SAMPLING the recipient's turn state
# over a bounded window: `shipyard tell` and `council say` each read a window in whole seconds and
# an interval as a decimal, then poll. Both knobs are operator-set, and an unusable value in
# either FAILS OPEN in a way that is worse than the bug the poll exists to fix — which is why they
# are validated at all, and why the validation is here rather than twice.
#
# THE TWO DEFECTS THIS EXISTS TO PREVENT, both of which shipped, in both skills, and neither of
# which the previous validations caught:
#
#   * A LEADING ZERO BREAKS THE POLL. `08` is a run of digits, so an all-digits test admits it —
#     and then `$(( … + secs ))` reads it as octal and fails with `value too great for base`.
#     MEASURED, because the first three descriptions of this in the tree were all wrong and each
#     was written confidently: bash does NOT die on that expansion. At script top level it prints
#     the error, leaves the assignment EMPTY and carries on — so `shipyard tell` went to
#     `[ "$(date +%s)" -lt "" ]`, which errors too, breaking the loop after ONE sample: the
#     single-sleep behaviour the poll exists to replace, restored silently. Inside a FUNCTION the
#     rest of the function is abandoned, so `council say` returned with no verdict at all. Two
#     different failures, neither of them a dead shell, and both reached AFTER the message has been
#     typed and submitted — which is what makes them matter, because the operator's next move is to
#     re-send, typing a second copy onto the first.
#
#   * A ZERO INTERVAL SPINS, AND ZERO HAS MANY SPELLINGS. `sleep 00` returns immediately, so the
#     bounded poll becomes a fork storm against a live child's terminal — measured at 119 captures
#     in a two-second window. Both callers previously rejected zero by ENUMERATING it
#     (`0|0.|0.0|.0`), which missed `00`, `000`, `0.00`, `.00` and `000.000`. The repo's rule for
#     this shape is to remove the enumerable form rather than extend the list, so the test below
#     asks whether a non-zero digit is present — which is every spelling of zero at once, however
#     many zeros and dots it is written with.
#
# WHY IT HAS ITS OWN MODULE. Reading a knob is neither backend knowledge (that is shared/driver,
# which knows agterm from tmux) nor per-agent-kind knowledge (that is shared/adapters, which knows
# what a client renders). Putting it in either because it is nearby is the mistake this repo has
# already recorded: the module that owns the KIND of knowledge is the right home, not the closest
# one.
#
# WHAT IS DELIBERATELY NOT HERE. The poll LOOP itself — sample, fold, census — is now the same
# algorithm in both callers over the same two `adp_*` predicates, with different prose. That is a
# real duplication and a change of its own on released code; it is filed, not started here.

# A version marker, bumped when the body changes, so sync + the drift gate stay easy to prove.
_KNOB_VERSION=1

# AN UNSET KNOB IS NOT AN UNUSABLE ONE, and the difference is the whole reason these return a
# status. Callers pass `${VAR:-}`, so "the operator set nothing" and "the operator set rubbish"
# both arrive here as an empty string — and the first version of this module answered 1 to both,
# which made every caller print a warning on the DEFAULT path: every directive, every hand-off,
# every resume, complaining about a variable nobody had touched. An alarm on the commonest healthy
# path is one an operator learns to ignore, which would have cost more than the bug this module
# fixes. So EMPTY returns the default at status 0 — silently, because nothing is wrong — and only
# a value the operator actually typed and got wrong returns 1.

# knob_uint <value> <default> — a whole number, for a window in seconds.
#
# Echoes the effective value. Exit 0 when there is nothing to complain about — the value was used
# as given, or none was set; exit 1 only when a value WAS set and could not be used. The caller
# prints its own message naming its own variable, so this file holds no skill's vocabulary.
#
# `0` IS VALID and is not a fallback: a window of zero means "take one post-send sample and
# decide", which is a legitimate setting and the one council's `t21-say.sh` poll cases use to stay
# fast. (Only council's suite sets it today — checked, rather than written as "both".)
#
# Unusable is: any non-digit (a typo, a sign, a space, `1e3`, a decimal point), or a run of digits
# too long to be a plausible window — 10+ digits, i.e. over thirty years in seconds. The cap is
# NOT there to stop an arithmetic failure: `$(( 10#… ))` on a twenty-digit value wraps silently at
# status 0 rather than erroring, which is measured and is why this sentence no longer claims
# otherwise. It is there so an implausible value cannot leave the poll running long past anything
# an operator meant.
knob_uint() {
  local v="${1:-}" d="${2:-}"
  [ -n "$v" ] || { printf '%s' "$d"; return 0; }   # nothing set — the default, quietly
  case "$v" in
    *[!0-9]*) printf '%s' "$d"; return 1 ;;
  esac
  [ "${#v}" -le 9 ] || { printf '%s' "$d"; return 1; }
  # `10#` forces base ten, so `08` is eight rather than a fatal expansion. Normalising rather than
  # rejecting is deliberate: a leading zero is a typo with an obvious intent, and honouring it is
  # friendlier than refusing it. `10#0` is 0, which the clause above says is legitimate.
  printf '%s' "$((10#$v))"
  return 0
}

# knob_interval <value> <default> — a decimal, for a sleep between samples.
#
# Echoes the effective value. Exit 0 when there is nothing to complain about — used as given, or
# none set; exit 1 only when a value WAS set and could not be used.
#
# Usable is: digits and at most one `.`, carrying at least one NON-ZERO digit, and short enough for
# `sleep` to accept. Everything else falls back — which covers a bare `.` (which makes `sleep`
# error every iteration), every spelling of zero (which makes it a no-op), and a value above
# INT_MAX, which `sleep` refuses outright and which therefore spins AND floods stderr with usage
# lines that bury the verdict. That last one HAS a non-zero digit, so the shape test alone does not
# catch it; it is why there is a length cap here as well as on the window.
#
# THE CAP IS ON THE STRING'S LENGTH, dot included, which is coarser than it sounds and is stated
# plainly rather than as "digits": `0.12345678` is ten characters and gets refused even though
# 0.12 seconds is a perfectly sensible interval. That is the cost of not forking to compare a
# decimal numerically, and it is accepted because the values an operator actually wants here are
# one or two decimal places. Widen it if that ever bites; do not describe it as something it is not.
knob_interval() {
  local v="${1:-}" d="${2:-}"
  [ -n "$v" ] || { printf '%s' "$d"; return 0; }   # nothing set — the default, quietly
  case "$v" in
    *[!0-9.]*|*.*.*) printf '%s' "$d"; return 1 ;;   # not a plain decimal
    *[1-9]*)         : ;;                            # has a non-zero digit — the only usable shape
    *)               printf '%s' "$d"; return 1 ;;   # every spelling of zero, and a bare `.`
  esac
  [ "${#v}" -le 9 ] || { printf '%s' "$d"; return 1; }
  printf '%s' "$v"
  return 0
}
