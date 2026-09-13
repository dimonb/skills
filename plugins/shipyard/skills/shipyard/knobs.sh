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
#   * A LEADING ZERO ABORTS THE CALLER. `08` is a run of digits, so an all-digits test admits it —
#     and then `$(( … + secs ))` reads it as octal, which is not an error bash returns but one it
#     DIES on: `value too great for base`, mid-expansion, killing a non-interactive shell. Both
#     callers reach that arithmetic AFTER the message has been typed and submitted, so the operator
#     gets a raw bash error, no delivery verdict, and a documented next move that types a second
#     copy onto the first. That is precisely the harm the confirm-poll exists to prevent, in the
#     code that implements it.
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

# knob_uint <value> <default> — a whole number, for a window in seconds.
#
# Echoes the effective value. Exit 0 when the caller's value was used as given, 1 when the default
# was substituted — so the caller prints its own message naming its own variable, and this file
# holds no skill's vocabulary.
#
# `0` IS VALID and is not a fallback: a window of zero means "take one post-send sample and
# decide", which is a legitimate setting and one both suites use to keep their poll cases fast.
#
# Unusable is: empty, any non-digit (a typo, a sign, a space, `1e3`, a decimal point), or a run of
# digits long enough to overflow the arithmetic it feeds — 10+ digits, where no legitimate window
# lives anyway. The length check comes BEFORE the normalisation, because `$(( 10#… ))` on an
# oversized value dies exactly like the octal case it is here to prevent.
knob_uint() {
  local v="${1:-}" d="${2:-}"
  case "$v" in
    ''|*[!0-9]*) printf '%s' "$d"; return 1 ;;
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
# Echoes the effective value. Exit 0 when the caller's value was used as given, 1 when the default
# was substituted.
#
# Usable is: digits and at most one `.`, carrying at least one NON-ZERO digit, and short enough
# for `sleep` to accept. Everything else falls back — which covers a bare `.` (which makes `sleep`
# error every iteration), every spelling of zero (which makes it a no-op), and a value above
# INT_MAX, which `sleep` refuses outright and which therefore spins AND floods stderr with usage
# lines that bury the verdict. That last one has a non-zero digit, so the shape test alone does not
# catch it; it is why the length cap is here too rather than only on the window.
#
# The cap is on the DIGIT COUNT, not on the value: this is a decimal string, and comparing it
# numerically would mean forking or losing the fraction.
knob_interval() {
  local v="${1:-}" d="${2:-}"
  case "$v" in
    *[!0-9.]*|*.*.*) printf '%s' "$d"; return 1 ;;   # not a plain decimal
    *[1-9]*)         : ;;                            # has a non-zero digit — the only usable shape
    *)               printf '%s' "$d"; return 1 ;;   # every spelling of zero, and a bare `.`
  esac
  [ "${#v}" -le 9 ] || { printf '%s' "$d"; return 1; }
  printf '%s' "$v"
  return 0
}
