#!/usr/bin/env bash
# run-all.sh — the council test suite. Fast ones by default; `--full` adds the load and
# latency runs, which take minutes and are sensitive to what else is on the machine.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL=0; [ "${1:-}" = "--full" ] && FULL=1
# One root for the whole run, exported so every test builds its rooms inside it — see the header
# of _helpers.sh for why a path fixed by the test's own name could not survive a second suite.
# The suite always makes its own root and removes it; an inherited COUNCIL_TEST_ROOT is NOT
# honoured here. To keep rooms for inspection, export it and run a single test, which _helpers.sh
# then does not own and does not remove.
mkdir -p "${TMPDIR:-/tmp}/council-test" || exit 1
COUNCIL_TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/council-test/run.XXXXXXXX") || exit 1
export COUNCIL_TEST_ROOT
# Remove the root on every exit path except SIGKILL, which nothing can catch. Bash runs an EXIT
# trap when the shell dies on an untrapped fatal signal too, so this covers a killed run; INT and
# TERM are deliberately NOT trapped, because a trapped signal is deferred until the current
# foreground command returns and would make a kill wait for the test in progress. Room keepers
# poll `while [ -d "$room" ]`, so this is what reaps the ones a killed test could not stop
# itself, and nothing else ever will: no later run reuses this root's name.
trap 'rm -rf "$COUNCIL_TEST_ROOT"' EXIT

# A ceiling, not a deadline. A slow test under load finishes far inside it; a wedged one is
# REPORTED as a failure rather than becoming a process nobody is waiting for. Wedged tests have
# been found holding their fifos hours after the suite that started them had exited, and a hang
# that vanishes silently is worse than a red run because it reads as if the test never ran.
# The cap needs timeout(1) — GNU coreutils, which a stock macOS does not ship — so its absence is
# announced rather than passed over: without it the suite runs exactly as it did before.
TIMEOUT_BIN=$(command -v timeout || command -v gtimeout || true)
PER_TEST_SECS="${COUNCIL_TEST_TIMEOUT:-600}"
[ -n "$TIMEOUT_BIN" ] || echo "note: no timeout(1) on PATH — a wedged test will not be capped"
# --foreground keeps the test in this shell's process group, so a terminal Ctrl-C still reaches
# it. Without it timeout puts the test in a group of its own, and an interrupt kills the runner
# while the test survives detached — the exact orphan this ceiling exists to prevent. Probed
# rather than assumed, since not every timeout(1) has the flag.
TIMEOUT_ARGS=(-k 10)
[ -n "$TIMEOUT_BIN" ] && "$TIMEOUT_BIN" --foreground 1 true 2>/dev/null \
  && TIMEOUT_ARGS=(--foreground -k 10)

tests=(t4-conflict.sh t7-roundtable.sh t8-graph.sh t11-decision.sh t14-verbs.sh t5-converge.sh t6-stuck.sh t3-token.sh t13-relaunch.sh)
[ "$FULL" = 1 ] && tests+=(t1-order.sh t2-latency.sh t2b-wake.sh t2c-bell.sh)
rc=0
for t in "${tests[@]}"; do
  printf '\n──── %s ────\n' "$t"
  if [ -n "$TIMEOUT_BIN" ]; then
    # -k: a test that ignores the TERM still goes, ten seconds later.
    "$TIMEOUT_BIN" "${TIMEOUT_ARGS[@]}" "$PER_TEST_SECS" bash "$DIR/$t"; st=$?
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
