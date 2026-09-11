#!/usr/bin/env bash
# t-turn — the shared turn-state read and the delivery verdict (agent-adapters.sh).
#
# PROVENANCE. Every property here traces to one shipped defect: the parent's directive channel
# decided that a message had landed from a before/after screen DIFF. Typing always changes the
# screen, so the diff was non-empty whether or not the submit took, and a directive left sitting
# UNSENT in the input box reported as delivered — twice in one night on two different slots, each
# time leaving a child that read as healthy and idle. The fix is an ANCHORED state read, sampled.
#
# WHY THE FIXTURES ARE REAL CAPTURES. The anchor is a claim about what real clients render, and
# both ways of getting it wrong are invisible without evidence: too loose restores the false
# confirmation, too tight makes a healthy running turn read as not-running, so the commonest
# healthy path alarms and an operator learns to ignore the signal. So the screens under test are
# live captures of both admitted kinds — see fixtures/panes.notes for how each was taken and which
# single one is derived rather than verbatim.
#
# The four ADVERSARIAL fixtures are the point of the file. Each one carries the turn marker
# somewhere the anchor must refuse to read it, and each corresponds to a way the old unanchored
# search was fooled:
#   * the marker inside the composer's first line (a typed, unsubmitted directive);
#   * the marker inside a WRAPPED continuation of that line — the case an anchor most easily
#     misjudges, because the continuation carries no glyph of its own;
#   * the marker WELDED out of two fragments by the caller's flatten-to-one-line step, which is
#     how a multi-line directive that merely mentions the two words produces the literal;
#   * the marker as indented transcript content — a child displaying this repo's own source, the
#     case that otherwise poisons a slot permanently.
#
# Everything under test is a pure function over a captured screen, so this needs no terminal, no
# control socket and no repo: it sources the module and calls it.
#
# WHAT IS NOT COVERED, so a green run is never read as more than it is:
#   * No end-to-end run of the CALLERS. The scripts that use these functions source a lib that
#     prepends the system PATH, so a faked backend CLI cannot stay authoritative; driving a whole
#     script needs the exported-shell-function rig the shipyard continuity suite uses, and that is
#     a change of its own. So the mapping from the `unconfirmed` verdict to its caller's exit code
#     is asserted by nothing here.
#   * No fixture for a queued render on the second kind's composer. That kind renders its queued
#     hint as a service line, which IS covered; whether it ever uses the composer for it was not
#     observed and nothing here claims it.
#   * These are captures of the clients as they render today. Nothing here proves a future build
#     renders the same shapes — that is what pinning them in one place buys.
set -uo pipefail
export LC_ALL=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$DIR/../agent-adapters.sh"
FIX="$DIR/fixtures"
[ -f "$MOD" ] || { echo "t-turn: cannot find agent-adapters.sh at $MOD" >&2; exit 1; }
# shellcheck source=../agent-adapters.sh
. "$MOD"

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}

pane() { # <fixture-name> — the fixture's text, or a loud failure if it is missing
  local p="$FIX/pane-$1.txt"
  [ -f "$p" ] || { echo "t-turn: missing fixture $p" >&2; exit 1; }
  cat "$p"
}
state_of() { adp_turn_state "$(pane "$1")"; }

# --- 1. the real states, per kind ------------------------------------------------------------
# One kind carries the marker in its footer, the other in a column-one service line. Neither uses
# the other's home, which is what lets ONE kind-less predicate serve both.
printf '\n── real renders ──\n'
ok "first kind, mid-turn, reads running"      running "$(state_of claude-running)"
ok "first kind, idle at the composer"         idle    "$(state_of claude-idle)"
ok "second kind, mid-turn, reads running"     running "$(state_of codex-running)"
ok "second kind, idle at the composer"        idle    "$(state_of codex-idle)"
# The client says it took the message for the next turn. On this kind the hint is the composer
# PLACEHOLDER, so it renders only while the box is empty.
ok "first kind, queued mid-turn"              queued  "$(state_of claude-queued)"

# --- 2. the adversarial fixtures — all must read as NOT running ------------------------------
printf '\n── our own text, and file content, are not evidence ──\n'
ok "a typed unsubmitted directive is not a turn"        idle "$(state_of claude-draft)"
ok "…nor is its wrapped continuation"                   idle "$(state_of claude-draft-welded)"
ok "…on the second kind either"                         idle "$(state_of codex-draft-welded)"
ok "the marker as indented transcript content"          idle "$(state_of claude-content)"
# And the predicate agrees with the state read on the same screens.
running_of() { if adp_turn_running "$(pane "$1")"; then printf 'yes'; else printf 'no'; fi; }
ok "predicate: running on the first kind's footer"      yes "$(running_of claude-running)"
ok "predicate: running on the second kind's service line" yes "$(running_of codex-running)"
ok "predicate: not running on a typed draft"            no  "$(running_of claude-draft)"
ok "predicate: not running on transcript content"       no  "$(running_of claude-content)"
ok "predicate: not running on an empty capture"         no  "$(running_of claude-idle)"

# --- 3. unreadable is NOT idle ----------------------------------------------------------------
# An empty capture is what a FAILED read returns as well as what a blank screen returns. Calling
# it idle would let the fold below read a turn that was already running as one our send started.
printf '\n── unreadable vs idle ──\n'
ok "an empty capture reads unknown"           unknown "$(adp_turn_state "")"
ok "a blank but non-empty screen reads idle"  idle    "$(adp_turn_state '   ')"

# --- 4. the verdict fold ----------------------------------------------------------------------
printf '\n── delivery verdict ──\n'
# THE SHIPPED DEFECT: the screens differ (typing put our text in the box) yet no turn started.
ok "the shipped false positive"                    unconfirmed "$(adp_delivery_verdict idle idle)"
ok "and it stays so however long we sample"        unconfirmed "$(adp_delivery_verdict idle idle idle idle)"
ok "no post-send sample at all"                    unconfirmed "$(adp_delivery_verdict idle)"
ok "idle then a turn is delivered"                 delivered   "$(adp_delivery_verdict idle running)"
ok "a turn appearing a few samples in"             delivered   "$(adp_delivery_verdict idle idle running)"
ok "the queued hint mid-turn"                      queued      "$(adp_delivery_verdict running queued)"
# A child already mid-turn cannot yield `delivered` from the turn marker alone: the marker never
# went absent, so nothing distinguishes its own turn from one our submit started.
ok "mid-turn throughout, no hint"                  unconfirmed "$(adp_delivery_verdict running running running)"
ok "a turn ending and a new one starting"          delivered   "$(adp_delivery_verdict running idle running)"
# An unreadable pre-send frame supplies no baseline, so a turn seen afterwards proves nothing.
ok "unknown pre-state cannot confirm"              unconfirmed "$(adp_delivery_verdict unknown running)"
ok "a later idle does supply the baseline"         delivered   "$(adp_delivery_verdict unknown idle running)"
# BOTH positive verdicts need absent-then-present. A queued hint already on screen belongs to an
# earlier send: it persists while its queue is non-empty, so the first post-send sample would
# otherwise re-supply it and decide — which was a live false positive.
ok "a stale queued hint cannot confirm"            unconfirmed "$(adp_delivery_verdict queued queued)"
ok "…however many samples it persists for"         unconfirmed "$(adp_delivery_verdict queued queued queued)"
ok "…but a hint that APPEARS after one does"       queued      "$(adp_delivery_verdict queued running queued)"
# Reachable, and pinned because it proves the pre-send slot is read for the baseline only.
ok "a pre-send hint that then clears"              unconfirmed "$(adp_delivery_verdict queued idle)"
ok "the first decisive sample wins"                delivered   "$(adp_delivery_verdict idle running queued)"

# --- 5. the marker is spelled ONCE ------------------------------------------------------------
# The point of moving this into the shared engine was deduplication: the literal used to be
# spelled four times across two of one skill's scripts. It is spelled once now, in the canonical
# module — plus exactly the vendored copies targets.txt lists, which the drift check holds
# byte-identical. That is the vendoring design, not a second spelling.
printf '\n── one spelling ──\n'
REPO="$(cd "$DIR/../../.." && pwd)"
expected="shared/adapters/agent-adapters.sh"
while IFS= read -r t; do
  case "$t" in ''|\#*) continue ;; esac
  expected="$expected
$t"
done < "$REPO/shared/adapters/targets.txt"
# Scope: PRODUCTION shell only. `*.sh` under any `tests/` directory is exempt because screen
# fixtures have to contain the string — and coupling another suite's fixtures to this constant
# would be worse than the duplication, since it would tie the terminal-backend suite to the
# per-agent-kind module for no gain. Documentation prose is exempt for the same kind of reason: it
# legitimately tells an operator what to look for on a screen.
# `--include` must precede `--`, or `--` ends option parsing and it is read as a FILE to search.
actual=$(cd "$REPO" && grep -rlF --include='*.sh' -- "$ADP_TURN_MARKER" . 2>/dev/null \
  | sed 's#^\./##' | grep -v '/tests/' | sort)
ok "the turn marker is spelled only in the canonical module and its vendored copies" \
   "$(printf '%s\n' "$expected" | sort | tr '\n' ' ')" "$(printf '%s\n' "$actual" | tr '\n' ' ')"

# The value pin, and the one place this file spells the markers out on purpose: they are observed
# client UI, and a typo silently switches every check above off, because they all build their
# expectations from the fixtures rather than from the constants.
ok "the turn marker is what the clients render"  'esc to interrupt'         "$ADP_TURN_MARKER"
ok "the composer queued hint, common prefix"     'Press up'                 "$ADP_QUEUED_BOX_HINT"
ok "the service-line queued header, common prefix" 'Messages to be submitted' "$ADP_QUEUED_BLOCK_HINT"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 't-turn: %d checks, all passed\n' "$CHECKS"
  exit 0
fi
printf 't-turn: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"
exit 1
