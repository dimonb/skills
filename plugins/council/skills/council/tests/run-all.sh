#!/usr/bin/env bash
# run-all.sh — the council test suite. Fast ones by default; `--full` adds the load and
# latency runs, which take minutes and are sensitive to what else is on the machine.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL=0; [ "${1:-}" = "--full" ] && FULL=1
tests=(t4-conflict.sh t7-roundtable.sh t8-graph.sh t14-verbs.sh t5-converge.sh t6-stuck.sh t3-token.sh t9-relaunch.sh)
[ "$FULL" = 1 ] && tests+=(t1-order.sh t2-latency.sh t2b-wake.sh t2c-bell.sh)
rc=0
for t in "${tests[@]}"; do
  printf '\n──── %s ────\n' "$t"
  bash "$DIR/$t" || { echo "FAILED: $t"; rc=1; }
done
printf '\n%s\n' "$([ $rc = 0 ] && echo 'all tests passed' || echo 'THERE ARE FAILURES')"
exit $rc
