#!/usr/bin/env bash
# run-all.sh — the shared owner-canary test suite. Runs under `make check` and `make test`, and by
# hand:
#
#   bash shared/canary/tests/run-all.sh
#
# One process, one FIFO, no terminal, no repo and no backend: fast and pure enough to gate every
# commit rather than living in `make test` alone.
#
# Both ways this suite could silently stop running are gated: a test file under this directory that
# is missing from the `tests` array below reds `scripts/check.sh` check 10, and this runner
# disappearing from the Makefile — or this suite disappearing from check.sh's $GATED_SUITES, which
# is what makes check 10 visit it at all — reds check 12.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tests=(t-canary.sh)

rc=0
for t in "${tests[@]}"; do
  printf '\n──── %s ────\n' "$t"
  bash "$DIR/$t" || rc=1
done
printf '\n%s\n' "$([ $rc = 0 ] && echo 'all tests passed' || echo 'THERE ARE FAILURES')"
exit $rc
