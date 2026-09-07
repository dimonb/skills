#!/usr/bin/env bash
# t12 — the child's turn state and the delivery verdict (shipyard-turn.sh).
#
# PROVENANCE. Every property here traces to one shipped defect: `shipyard-tell.sh` decided
# `delivered` from a before/after screen DIFF. Typing always changes the screen, so the diff was
# non-empty whether or not the Return took, and a directive left sitting UNSENT in the input box
# reported as delivered. It happened twice in one night on two different slots, and both times the
# child then read as a healthy `⏸ idle/wait` with `esc —`. The fix is a STATE read of the turn
# marker, sampled; this file is that rule's table.
#
# Everything under test is a pure function over a captured screen, so this needs no terminal, no
# control socket, no repo and no fakes on PATH — it sources shipyard-turn.sh and calls it. That is
# why those functions live in their own file rather than in shipyard-lib.sh, which prepends the
# system PATH and resolves a container the moment it is sourced.
#
# FIXTURES ARE BUILT FROM THE CONSTANTS, never from a second copy of the marker text, so this suite
# cannot drift from the code it guards. The one deliberate exception is the value pin at the end:
# that check exists precisely to notice an edit to the constant, so it must spell the string out.
#
# WHAT IS NOT COVERED, so a green run is never read as more than it is:
#   * No end-to-end run of shipyard-tell.sh, so the mapping from the `unconfirmed` verdict to exit
#     6, and shipyard-answer.sh's branch on that 6, are NOT asserted here. Those scripts source
#     shipyard-lib.sh, which prepends the system PATH ahead of the caller's — so a faked agtermctl
#     or tmux cannot stay authoritative and the real one would talk to a live socket. t8 avoids
#     this by sourcing only shipyard-backend.sh; a rig that can drive a whole script is a change of
#     its own. Two of the three verdicts were instead exercised by hand against a throwaway tmux
#     session: `unconfirmed` (a pane that never renders the marker -> exit 6) and `delivered` (a
#     pane armed to render it on submit -> exit 0). `queued` was not, because arming a pane to show
#     that hint puts the hint's own text on screen before the send, which would make the check pass
#     off the fixture rather than off the behaviour.
#   * Nothing here proves a future client build still renders these markers. They are observed UI,
#     pinned in one place so that when one changes it is a one-line edit rather than a hunt.
#   * The poll cadence in shipyard-tell.sh (how often it samples, and hence how rare a false
#     `unconfirmed` is) is a property of that loop, not of this fold.
set -uo pipefail
export LC_ALL=C

SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TURN="$SKILL/shipyard-turn.sh"
[ -f "$TURN" ] || { echo "t12: cannot find shipyard-turn.sh at $TURN" >&2; exit 1; }
# shellcheck source=../shipyard-turn.sh
. "$TURN"

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}

# --- screen fixtures, assembled from the constants -------------------------------------------
# An idle client: prompt line, placeholder, footer hints, no turn marker anywhere.
IDLE_SCREEN=$(printf '%s\n%s\n%s\n' \
  '· Ran make check' \
  '› ' \
  '  ? for shortcuts                                              12.4k tokens')
# The same screen with our directive typed into the box and NOT submitted. This is the pair the
# old diff was asked to judge: it differs from IDLE_SCREEN, and nothing about a turn has changed.
DRAFT_SCREEN=$(printf '%s\n%s\n%s\n' \
  '· Ran make check' \
  '› [supervisor directive] stop, do not merge yet' \
  '  ? for shortcuts                                              12.4k tokens')
# Claude Code mid-turn: the marker sits in the footer among other hints.
CLAUDE_BUSY=$(printf '%s\n%s\n' \
  '✻ Cogitating… (18s)' \
  "  ? for shortcuts · $SHIPYARD_TURN_MARKER · 12.4k tokens")
# Codex mid-turn: the same marker, inside a service line rather than a footer. Both child kinds
# shipyard admits are covered by ONE predicate only because the test is a substring test.
CODEX_BUSY=$(printf '%s\n%s\n' \
  "• Working (1m 08s · $SHIPYARD_TURN_MARKER)" \
  '› ')
# Mid-turn AND the client says it took what we typed for the next turn. Both markers coexist:
# the hint only ever appears while a turn is in flight.
QUEUED_SCREEN=$(printf '%s\n%s\n%s\n' \
  '✻ Cogitating… (18s)' \
  "  $SHIPYARD_QUEUED_MARKER" \
  "  ? for shortcuts · $SHIPYARD_TURN_MARKER · 12.4k tokens")

# --- 1. shipyard_turn_state ------------------------------------------------------------------
printf '\n── turn state ──\n'
ok "an idle client reads idle"                    idle    "$(shipyard_turn_state "$IDLE_SCREEN")"
ok "an unsubmitted draft still reads idle"        idle    "$(shipyard_turn_state "$DRAFT_SCREEN")"
ok "a Claude footer marker reads running"         running "$(shipyard_turn_state "$CLAUDE_BUSY")"
ok "a Codex service-line marker reads running"    running "$(shipyard_turn_state "$CODEX_BUSY")"
ok "the queued hint outranks the turn marker"     queued  "$(shipyard_turn_state "$QUEUED_SCREEN")"
ok "the queued hint alone reads queued"           queued  "$(shipyard_turn_state "  $SHIPYARD_QUEUED_MARKER")"
# `unknown` is what an UNREADABLE screen contributes, and it must not be idle: an empty capture is
# what a failed read returns, and counting it as idle is what would let the fold below conclude
# `delivered` from a turn that was already running before anything was typed.
ok "an empty capture reads unknown"               unknown "$(shipyard_turn_state "")"
# The guard is emptiness, not blankness: a screen that really is blank is a real, idle screen.
ok "a blank but non-empty screen reads idle"      idle    "$(shipyard_turn_state '   ')"

# --- 2. shipyard_turn_running — the predicate shipyard-compact.sh uses ------------------------
# Its three call sites replaced inline greps for the same literal. The empty case matters: the old
# `grep -c … = 0` test read an unreadable pane as "no turn running", and that is preserved.
printf '\n── turn running ──\n'
running_of() { if shipyard_turn_running "$1"; then printf 'yes'; else printf 'no'; fi; }
ok "running on a Claude busy screen"  yes "$(running_of "$CLAUDE_BUSY")"
ok "running on a Codex busy screen"   yes "$(running_of "$CODEX_BUSY")"
ok "not running on an idle screen"    no  "$(running_of "$IDLE_SCREEN")"
ok "not running on a draft screen"    no  "$(running_of "$DRAFT_SCREEN")"
ok "not running on an empty capture"  no  "$(running_of "")"

# --- 3. shipyard_delivery_verdict — the fold that replaced the diff ---------------------------
printf '\n── delivery verdict ──\n'
# THE SHIPPED DEFECT, stated as the pair it was judged on. The two screens DIFFER — typing put our
# text in the box — and the old rule called that `delivered`. Both map to the same turn state, so
# the fold has no evidence a turn started and says so.
ok "the shipped false positive: differing screens, no turn" unconfirmed \
  "$(shipyard_delivery_verdict "$(shipyard_turn_state "$IDLE_SCREEN")" "$(shipyard_turn_state "$DRAFT_SCREEN")")"
ok "and it stays unconfirmed however long we sample" unconfirmed \
  "$(shipyard_delivery_verdict idle idle idle idle idle)"
ok "no post-send sample at all is unconfirmed"      unconfirmed "$(shipyard_delivery_verdict idle)"

ok "idle then a turn is delivered"                  delivered   "$(shipyard_delivery_verdict idle running)"
ok "a turn appearing a few samples in is delivered" delivered   "$(shipyard_delivery_verdict idle idle running)"
ok "the queued hint mid-turn is queued"             queued      "$(shipyard_delivery_verdict running queued)"
ok "queued wins as soon as it is seen"              queued      "$(shipyard_delivery_verdict running running queued)"
# A child already mid-turn cannot yield `delivered` from the marker alone — the marker never went
# absent, so nothing distinguishes its own turn from one our submit started. The client's hint is
# that case's positive signal, and without it the honest answer is `unconfirmed`.
ok "mid-turn throughout, no hint, is unconfirmed"   unconfirmed "$(shipyard_delivery_verdict running running running)"
# …unless that turn ends and a new one starts inside the window: idle-then-running is the same
# evidence by the same rule.
ok "a turn ending and a new one starting delivers"  delivered   "$(shipyard_delivery_verdict running idle running)"
# An unreadable pre-send screen supplies no baseline, so a turn seen afterwards proves nothing: it
# may have been running all along. This is the case that would otherwise re-create the false
# `delivered` the whole change is about.
ok "unknown pre-state cannot manufacture delivered" unconfirmed "$(shipyard_delivery_verdict unknown running)"
ok "a later idle does supply the missing baseline"  delivered   "$(shipyard_delivery_verdict unknown idle running)"
# A queued hint already on screen before we typed belongs to an EARLIER send. The pre-send sample
# is read for one thing only — whether the client was idle — so a stale hint is not evidence here.
ok "a pre-existing queued hint is not evidence"     unconfirmed "$(shipyard_delivery_verdict queued idle)"
# The first decisive sample wins; later samples cannot overturn it.
ok "the first decisive sample wins"                 delivered   "$(shipyard_delivery_verdict idle running queued)"

# --- 4. the marker is spelled exactly ONCE ---------------------------------------------------
# The point of shipyard-turn.sh is deduplication, so this asserts it rather than trusting it. It
# used to be spelled four times across shipyard-compact.sh and shipyard-report.sh, which is the
# shape that lets a client rename it and have half the callers keep working.
#
# Scope: the plugin's top-level shell only. `tests/` is excluded because fixtures must contain the
# string, and `.md` because SKILL.md legitimately tells an operator what to look for on a screen.
# The glob does include the vendored agent-driver.sh / agent-adapters.sh: if a shared module ever
# spells the marker, this reds, and that IS the seam worth being told about (see shipyard-turn.sh's
# header for where the predicates would move).
printf '\n── one spelling ──\n'
spelled_in=$(grep -lF -- "$SHIPYARD_TURN_MARKER" "$SKILL"/*.sh 2>/dev/null \
  | sed "s#^$SKILL/##" | sort | paste -sd, - | tr -d '\n')
ok "exactly one non-test file spells the turn marker" "shipyard-turn.sh" "$spelled_in"
occurrences=$(grep -hoF -- "$SHIPYARD_TURN_MARKER" "$SKILL"/*.sh 2>/dev/null | grep -c . | tr -d ' ')
ok "…and spells it exactly once"                      1 "$occurrences"

# The value pin, and the one place this file spells the marker out on purpose: the constant is
# observed client UI, and a typo in it silently switches every predicate above off while every
# other check here still passes (they all build their fixtures from the constant).
ok "the turn marker is the string the clients render" 'esc to interrupt' "$SHIPYARD_TURN_MARKER"
ok "the queued marker is the hint the client shows"   'queued message'   "$SHIPYARD_QUEUED_MARKER"

# --- done ------------------------------------------------------------------------------------
printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 't12-turn-delivery: %d checks, all passed\n' "$CHECKS"
  exit 0
fi
printf 't12-turn-delivery: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"
exit 1
