#!/usr/bin/env bash
# run-all.sh — the shared escalation-policy test suite. Run by hand:
#
#   bash shared/policy/tests/run-all.sh
#
# Every test is a pure read over the module's functions plus, for the mailbox, a throwaway
# `git init` repo — no live agent, no network, no touching the real mailbox.
#
# THIS SUITE IS GATED BY NOTHING, and that is worth knowing before you rely on it. The
# generalization this header used to promise landed only by halves: check 11 (the drift gate over
# vendored copies) really does iterate every shared/<mod>/ and covers shared/policy/, but the part
# that RUNS a suite and checks its registration — scripts/check.sh check 10, and the Makefile —
# took a hand-maintained list of five suite directories, and this one is not on it. So nothing
# runs these tests in `make check`, `make test` or CI, and a test dropped from the `tests` array
# below reds nothing. It is the one suite in the repo that can silently stop running.
#
# Wiring it in is a change of its own (check 10's loop, both Makefile targets, and a probe in
# scripts/check-test.sh, which every gated suite has). AGENTS.md states the same gap where the
# verification commands are documented.
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
