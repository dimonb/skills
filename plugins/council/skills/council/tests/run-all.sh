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
tests=(t4-conflict.sh t7-roundtable.sh t8-graph.sh t11-decision.sh t14-verbs.sh t5-converge.sh t6-stuck.sh t3-token.sh t13-relaunch.sh)
[ "$FULL" = 1 ] && tests+=(t1-order.sh t2-latency.sh t2b-wake.sh t2c-bell.sh)
rc=0
for t in "${tests[@]}"; do
  printf '\n──── %s ────\n' "$t"
  bash "$DIR/$t" || { echo "FAILED: $t"; rc=1; }
done
printf '\n%s\n' "$([ $rc = 0 ] && echo 'all tests passed' || echo 'THERE ARE FAILURES')"
# The rooms are the only record of what a failure looked like, so keep them when one failed.
if [ $rc = 0 ]; then rm -rf "$COUNCIL_TEST_ROOT"
else echo "rooms kept for inspection: $COUNCIL_TEST_ROOT"; fi
exit $rc
