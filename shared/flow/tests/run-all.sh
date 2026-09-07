#!/usr/bin/env bash
# run-all.sh — the shared flow-guard test suite. Run by hand:
#
#   bash shared/flow/tests/run-all.sh
#
# Wired into the gate three ways (scripts/check.sh checks 10 and 12, and the Makefile): this
# suite must be named in check.sh's $GATED_SUITES and its runner must be named by a Makefile
# recipe, or check 12 reds; every test file here must be registered in the `tests` array below
# or check 10 reds, so a test cannot silently stop running; and `make check` RUNS this suite
# (it is fast, pure), so a flow regression reds a commit. `make test` runs it too, alongside the
# driver, adapter, policy, shipyard and council suites. Every test is a pure drive of a declared
# graph against a faked driver — no live terminal, no agent, no network.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tests=(t-flow.sh)

rc=0
for t in "${tests[@]}"; do
  printf '\n──── %s ────\n' "$t"
  bash "$DIR/$t" || rc=1
done
printf '\n%s\n' "$([ $rc = 0 ] && echo 'all tests passed' || echo 'THERE ARE FAILURES')"
exit $rc
