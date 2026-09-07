#!/usr/bin/env bash
# run-all.sh — the shared escalation-policy test suite. Runs under `make check` and `make test`,
# and by hand:
#
#   bash shared/policy/tests/run-all.sh
#
# Every test is a pure read over the module's functions plus, for the mailbox, a throwaway
# `git init` repo — no live agent, no network, no touching the real mailbox. Fast and pure, which
# is why it gates every commit rather than living in `make test` alone.
#
# Both ways this suite could silently stop running are now gated, and it is worth knowing which
# check owns which: a test file under this directory that is missing from the `tests` array below
# reds `scripts/check.sh` check 10, and this runner disappearing from the Makefile — or this suite
# disappearing from check.sh's $GATED_SUITES, which is what makes check 10 visit it at all — reds
# check 12. It was gated by neither from the day it landed until #111.
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
