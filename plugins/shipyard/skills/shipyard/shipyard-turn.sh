#!/usr/bin/env bash
# shipyard-turn.sh — is the child mid-TURN, and did what we just typed start one? Source only.
#
# Its own file for the same reason `shipyard-ctx.sh` is one: everything here is a pure function
# over a captured screen, so the suite sources it and asserts every verdict without a terminal, a
# control socket or a repo. `shipyard-lib.sh` sources it, so anything that already sources the lib
# has these. Nothing here forks a backend call or reads the environment.
#
# THE MARKER IS SPELLED ONCE, HERE. It used to be spelled four times across two scripts, which is
# the shape that lets a client rename it and have half the callers keep working. Both child kinds
# shipyard admits render it today: Claude Code puts it in the footer while a turn runs, and Codex
# carries it inside its `• Working (1m 08s · …)` service line — which is why this is
# shipyard's own constant and not a per-kind adapter query. THE SEAM, for the day a kind stops
# rendering it: move these predicates behind `adp_*` in `shared/adapters` (which already owns
# per-kind knowledge) and read the slot's kind from the launch record, which already carries it.
# Do not add a second constant here.
#
# Kept bash-3.2 clean — no arrays, no `${var^^}`, no `local -n` — so a stock /bin/bash can source
# it as a subprocess without the driver's bash-5 baseline coming along.
SHIPYARD_TURN_MARKER='esc to interrupt'

# The hint the client shows when a message lands mid-turn and is taken for the next one.
SHIPYARD_QUEUED_MARKER='queued message'

# shipyard_turn_running <screen> — 0 while a turn is in flight.
#
# A SUBSTRING test, deliberately: on Claude Code the marker sits in a footer line among other
# hints, and on Codex it sits inside a `• Working (…)` service line. Anchoring it to a whole line
# would match neither.
shipyard_turn_running() {
  printf '%s' "$1" | grep -qF -- "$SHIPYARD_TURN_MARKER"
}

# shipyard_turn_state <screen> — queued | running | idle | unknown, in that precedence.
#
# `unknown` IS NOT `idle`, and the difference is load-bearing. An empty capture is what a failed
# read returns as well as what a blank screen returns, and letting it count as idle would let
# `shipyard_delivery_verdict` conclude `delivered` from a turn that was already running before we
# typed a thing. That is the exact false positive this file exists to remove, so an unreadable
# screen contributes no evidence at all.
#
# `queued` outranks `running` because the two markers coexist: the queued hint only ever appears
# while a turn is in flight, and it is the more specific answer.
shipyard_turn_state() {
  if [ -z "$1" ]; then printf 'unknown'
  elif printf '%s' "$1" | grep -qF -- "$SHIPYARD_QUEUED_MARKER"; then printf 'queued'
  elif shipyard_turn_running "$1"; then printf 'running'
  else printf 'idle'
  fi
}

# shipyard_delivery_verdict <pre-send-state> [<post-send-state> ...]
#   -> delivered | queued | unconfirmed
#
# What this replaced: a before/after screen DIFF. That diff could not answer the question it was
# asked. Typing changes the screen whether or not the Return took, so the diff was non-empty
# either way and a directive left sitting UNSENT in the input box reported as `delivered`. The
# parent then believed the child had been told, and the child read as `⏸ idle/wait` with `esc —`,
# which is the signature of a healthy child waiting on something. It happened twice in one night,
# on two different slots, and both times the directive was discovered unsent only because the
# child's later behaviour did not reflect it.
#
# The evidence used instead is a STATE, not a change: a turn marker that was ABSENT and is now
# PRESENT means a turn started, and nothing but our own submit could have started it. Hence
# `seen_idle` — `delivered` requires an idle observation first, and the pre-send sample is allowed
# to supply it. A child that was ALREADY mid-turn therefore cannot yield `delivered` from the turn
# marker alone; its positive signal is the client's queued hint. Should that turn end and a new one
# start inside the window, the fold sees idle-then-running and says `delivered`, which is the same
# conclusion by the same rule.
#
# The pre-send sample is scanned for NOTHING ELSE: a `queued` hint already on screen belongs to an
# earlier send and is not evidence about this one.
#
# WHAT `unconfirmed` DOES AND DOES NOT RULE OUT — stated here because this is where the word is
# defined. It says: no turn was observed to start, and the client never said it had queued
# anything. It does NOT prove the directive was not delivered. A turn that started AND finished
# between two samples looks identical, and so does one on a child whose screen could not be read
# (`unknown` contributes nothing, by design). What it DOES mean is that the text may be sitting
# unsent in the input box — the one case worth an operator's eyes. The bias is deliberate:
# re-sending on a false `unconfirmed` is cheap and visible, believing a false `delivered` is
# neither. Sampling densely is what keeps the false case rare, so the caller polls rather than
# sleeping once; a fourth verdict to name the residual would be fuzzier than these three are.
shipyard_delivery_verdict() {
  local state seen_idle=0
  [ "${1:-}" = idle ] && seen_idle=1
  shift 2>/dev/null || true
  for state in "$@"; do
    case "$state" in
      queued)  printf 'queued';  return 0 ;;
      running) [ "$seen_idle" = 1 ] && { printf 'delivered'; return 0; } ;;
      idle)    seen_idle=1 ;;
    esac
  done
  printf 'unconfirmed'
}
