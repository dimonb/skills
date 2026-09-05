#!/usr/bin/env bash
# run-all.sh — the shared escalation-policy test suite. Run by hand:
#
#   bash shared/policy/tests/run-all.sh
#
# Every test is a pure read over the module's functions plus, for the mailbox, a throwaway
# `git init` repo — no live agent, no network, no touching the real mailbox. The suite runs
# standalone today; the shared-module gate that runs and registration-checks shared/driver/'s
# suite is being generalized to iterate every shared/<mod>/, which then wires this one in too.
# The `tests` array below is the single registration list that generalization reads.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tests=(t-policy.sh)

rc=0
for t in "${tests[@]}"; do
  printf '\n──── %s ────\n' "$t"
  bash "$DIR/$t" || rc=1
done
printf '\n%s\n' "$([ $rc = 0 ] && echo 'all tests passed' || echo 'THERE ARE FAILURES')"
exit $rc
