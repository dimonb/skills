#!/usr/bin/env bash
# run-all.sh — the shared-driver test suite. Run by hand:
#
#   bash shared/driver/tests/run-all.sh
#
# Wired into the gate two ways (scripts/check.sh check 10, and the Makefile): every test file here
# must be registered in the `tests` array below or `make check` reds, so a test cannot silently
# stop running; and `make check` RUNS this suite (it is fast, ~2s), so a driver regression reds a
# commit. `make test` runs it too, alongside the flow, shipyard and council suites. Every test is a pure
# read over environment variables and two faked CLIs (agtermctl, tmux) — no live terminal, no network.
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
