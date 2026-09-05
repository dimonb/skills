#!/usr/bin/env bash
# run-all.sh — the council test suite. Fast ones by default; `--full` adds the load and
# latency runs, which take minutes and are sensitive to what else is on the machine.
#
# `make test` runs this suite's fast subset (no `--full`), alongside the driver, flow and shipyard
# suites. Registration is gated: scripts/check.sh check 10 requires every test file under this
# directory to appear in a `tests` array below (the default one, or the `--full` one), so none
# silently stops running.
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

# Every test runs at a lower scheduling priority, and this is not politeness — it is what keeps
# the suite from being the reason its own assertions fail. A test room is a handful of concurrent
# shells per participant, so several suites at once (the normal case on a machine driving a fleet)
# saturate the box; and a saturated box does not produce a clean "too slow" failure, it produces
# an asymmetric protocol failure that reads as a transport bug. Niceness is inherited, so this
# covers each test's own children too. COUNCIL_TEST_NICE=0 turns it off for a timing measurement
# that wants the machine as it really is.
NICE=()
if [ "${COUNCIL_TEST_NICE:-10}" != 0 ] && command -v nice >/dev/null 2>&1; then
  NICE=(nice -n "${COUNCIL_TEST_NICE:-10}")
fi
# Deliberately NOT --foreground, though it is tempting. That flag keeps the test in this shell's
# process group so a terminal Ctrl-C reaches it — but it also stops timeout signalling the GROUP,
# and the group is the only thing that reaches a test wedged past its own cleanup. The EXIT trap
# in _helpers.sh now reaps the test's background jobs, SIGSTOPped ones included, so the two
# mechanisms overlap on every path where the test's shell still runs its trap — but a shell
# killed with SIGKILL runs nothing, and that is the case the group signal exists for. Measured
# before the trap covered them: with the flag the ceiling left 3 of 3 peers alive, one SIGSTOPped
# and reapable only by SIGKILL; without it, none.
# So the trade is bounded against unbounded. Leaving the flag off means a Ctrl-C kills the runner
# while the current test keeps going — but only until this same ceiling group-kills it. Turning it
# on means processes that outlive everyone, which is the failure the ceiling exists to prevent.

tests=(t4-conflict.sh t7-roundtable.sh t8-graph.sh t11-decision.sh t14-verbs.sh t5-converge.sh t6-stuck.sh t9-lap.sh t9b-untrusted.sh t9c-room-inputs.sh t9d-lane-provenance.sh t9e-author-identity.sh t9f-decided-needs-record.sh t9g-degrades-loudly.sh t9h-roster-order.sh t3-token.sh t13-relaunch.sh t15-term-adapter.sh t16-keeper-canary.sh t17-esc-mailbox.sh)
[ "$FULL" = 1 ] && tests+=(t1-order.sh t2-latency.sh t2b-wake.sh t2c-bell.sh)
rc=0
for t in "${tests[@]}"; do
  printf '\n──── %s ────\n' "$t"
  if [ -n "$TIMEOUT_BIN" ]; then
    # -k: a test that ignores the TERM still goes, ten seconds later.
    # nice OUTSIDE timeout: the ceiling inherits the priority and passes it on, and a niced
    # `timeout` still fires on schedule — it sleeps, it does not spin.
    ${NICE[@]+"${NICE[@]}"} "$TIMEOUT_BIN" -k 10 "$PER_TEST_SECS" bash "$DIR/$t"; st=$?
  else
    ${NICE[@]+"${NICE[@]}"} bash "$DIR/$t"; st=$?
  fi
  case "$st" in
    0)       ;;
    124|137) echo "TIMED OUT after ${PER_TEST_SECS}s: $t"; rc=1 ;;
    *)       echo "FAILED: $t"; rc=1 ;;
  esac
done
printf '\n%s\n' "$([ $rc = 0 ] && echo 'all tests passed' || echo 'THERE ARE FAILURES')"
exit $rc
