#!/usr/bin/env bash
# run-all.sh — the shared-driver test suite. Run by hand:
#
#   bash shared/driver/tests/run-all.sh
#
# NOT wired into `make check`. Generalising the gate's council-specific test registration
# (scripts/check.sh checks 9 and 10) to cover other suites is tracked separately in
# dimonb/skills#58; until then, as with the shipyard suite, these tests are real and fast but
# nothing yet forces a run. Every test is a pure read over environment variables and two faked
# CLIs (agtermctl, tmux) — no live terminal, no network.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tests=(t-driver.sh)

rc=0
for t in "${tests[@]}"; do
  printf '\n──── %s ────\n' "$t"
  bash "$DIR/$t" || rc=1
done
printf '\n%s\n' "$([ $rc = 0 ] && echo 'all tests passed' || echo 'THERE ARE FAILURES')"
exit $rc
