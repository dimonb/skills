#!/usr/bin/env bash
# run-all.sh — the council test suite. Fast ones by default; `--full` adds the load and
# latency runs, which take minutes and are sensitive to what else is on the machine.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL=0; [ "${1:-}" = "--full" ] && FULL=1
# One root for the whole run, exported so every test builds its rooms inside it. Without it a
# test owns a path fixed by its own name, and a second suite running at the same time deletes
# this one's rooms while it is mid-drain — the failure then lands on whichever test was
# unlucky, which is the worst shape for a suite whose job is to make a transport trustworthy.
mkdir -p "${TMPDIR:-/tmp}/council-test" || exit 1
COUNCIL_TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/council-test/run.XXXXXXXX") || exit 1
export COUNCIL_TEST_ROOT
# Remove the root on EVERY exit path, including a killed run. Room keepers poll
# `while [ -d "$room" ]`, so this is what reaps the ones a killed test could not stop itself,
# and nothing else ever will: no later run reuses this root's name.
trap 'rm -rf "$COUNCIL_TEST_ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# A ceiling, not a deadline. A slow test under load finishes far inside it; a wedged one is
# REPORTED as a failure rather than becoming a process nobody is waiting for. Wedged tests have
# been found holding their fifos hours after the suite that started them had exited, and a hang
# that vanishes silently is worse than a red run because it reads as if the test never ran.
TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || true)
PER_TEST_SECS="${COUNCIL_TEST_TIMEOUT:-600}"
[ -n "$TIMEOUT_BIN" ] || echo "note: no timeout(1) on PATH — a wedged test will not be capped"

tests=(t4-conflict.sh t7-roundtable.sh t8-graph.sh t11-decision.sh t14-verbs.sh t5-converge.sh t6-stuck.sh t3-token.sh t13-relaunch.sh)
[ "$FULL" = 1 ] && tests+=(t1-order.sh t2-latency.sh t2b-wake.sh t2c-bell.sh)
rc=0
for t in "${tests[@]}"; do
  printf '\n──── %s ────\n' "$t"
  if [ -n "$TIMEOUT_BIN" ]; then
    # -k: a test that ignores the TERM still goes, ten seconds later.
    "$TIMEOUT_BIN" -k 10 "$PER_TEST_SECS" bash "$DIR/$t"; st=$?
  else
    bash "$DIR/$t"; st=$?
  fi
  case "$st" in
    0)       ;;
    124|137) echo "TIMED OUT after ${PER_TEST_SECS}s: $t"; rc=1 ;;
    *)       echo "FAILED: $t"; rc=1 ;;
  esac
done
printf '\n%s\n' "$([ $rc = 0 ] && echo 'all tests passed' || echo 'THERE ARE FAILURES')"
exit $rc
