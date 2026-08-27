#!/usr/bin/env bash
# _helpers.sh — shared rig for the shipyard-ctx.sh suite. Source only, never execute.
#
# Everything under test is a PURE function over a file and two environment variables, so this
# needs none of the process machinery a council test needs: no rooms, no fifos, no reaping. What
# it does need is isolation from the machine's real transcripts, so every fixture is built under
# a per-test `mktemp -d` that the test removes on exit.
set -uo pipefail

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../shipyard-ctx.sh
. "$SKILL_DIR/shipyard-ctx.sh"

CTX_TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/shipyard-ctx-test.XXXXXXXX") || exit 1
trap 'rm -rf "$CTX_TEST_DIR"' EXIT

# The filesystem is isolated by the mktemp above, but the ENVIRONMENT is not, and every function
# under test reads this one variable. Both SKILL.md and the README tell an operator to set it —
# so without this, the suite fails on the machine of exactly the person the escape hatch exists
# for: measured, an exported SHIPYARD_CTX_WINDOW=400000 turns 8 checks red for no real reason.
# A suite that cries wolf on a correctly configured machine is one nobody runs. Per-case overrides
# all live inside their own command substitutions, so unsetting it here costs nothing.
unset SHIPYARD_CTX_WINDOW

FAILURES=0
CHECKS=0

# ok <label> <expected> <actual>
ok() {
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"
    FAILURES=$((FAILURES + 1))
  fi
}

# done_ <suite name> — the exit status every test file ends on.
done_() {
  if [ "$FAILURES" -eq 0 ]; then
    printf '%s: %d checks, all passed\n' "$1" "$CHECKS"
    return 0
  fi
  printf '%s: %d checks, %d FAILED\n' "$1" "$CHECKS" "$FAILURES"
  return 1
}

# --- fixture builders ---------------------------------------------------------------------
# usage_record <input> <cache_creation> <cache_read> <output> [model]
# One transcript line of the shape the client actually writes.
usage_record() {
  printf '{"type":"assistant","message":{"model":"%s","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":%s}}}\n' \
    "${5:-claude-opus-5}" "$1" "$2" "$3" "$4"
}

# synthetic_record — the client's OWN all-zero record, written when a turn never reached the API
# ("You've hit your session limit", "API Error: 500", "Connection closed mid-response"). Verbatim
# shape, including isApiErrorMessage: this is the record that made a frozen child read `0% · 0`.
synthetic_record() {
  printf '{"type":"assistant","message":{"model":"<synthetic>","usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":0}},"isApiErrorMessage":true}\n'
}

# transcript <name> — path to a new empty fixture transcript.
transcript() { local p="$CTX_TEST_DIR/$1.jsonl"; : > "$p"; printf '%s' "$p"; }
