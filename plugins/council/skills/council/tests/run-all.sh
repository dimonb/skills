#!/usr/bin/env bash
# run-all.sh — the council test suite. Fast ones by default; `--full` adds the load and
# latency runs, which take minutes and are sensitive to what else is on the machine.
#
# `make test` runs this suite's fast subset (no `--full`), alongside the driver, flow, adapter,
# policy and shipyard suites. Two things are gated, both in scripts/check.sh: check 10 requires
# every test file under this directory to appear in a `tests` array below (the default one, or the
# `--full` one), so none silently stops running; and check 12 requires this suite to be named in
# $GATED_SUITES and its runner to be named by a Makefile recipe, so the suite as a whole cannot
# stop running either.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL=0; [ "${1:-}" = "--full" ] && FULL=1
# One root for the whole run — see the header of _helpers.sh for why a path fixed by the test's
# own name could not survive a second suite. The suite always makes its own root and removes it;
# an inherited COUNCIL_TEST_ROOT is NOT honoured here. To keep rooms for inspection, export it and
# run a single test, which _helpers.sh then does not own and does not remove.
#
# EACH TEST NOW GETS ITS OWN SUBDIRECTORY of it rather than the root itself, because the files run
# CONCURRENTLY below. The root stays one directory per run, which is what the trap needs and what
# isolates this run from a second suite; the per-test level is what stops two files that both
# reach for a fixed name inside it — `$COUNCIL_TEST_ROOT/ship-escalations`, which _helpers.sh
# points POLICY_MAILBOX_DIR at, is written by several and named identically by all of them — from
# reading each other's writes. Run serially this changes nothing.
mkdir -p "${TMPDIR:-/tmp}/council-test" || exit 1
RUN_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/council-test/run.XXXXXXXX") || exit 1
# Remove the root on every exit path except SIGKILL, which nothing can catch. Bash runs an EXIT
# trap when the shell dies on an untrapped fatal signal too, so this covers a killed run; INT and
# TERM are deliberately NOT trapped, because a trapped signal is deferred until the current
# foreground command returns and would make a kill wait for the test in progress. Room keepers
# poll `while [ -d "$room" ]`, so this is what reaps the ones a killed test could not stop
# itself, and nothing else ever will: no later run reuses this root's name. It removes the whole
# run root, so every per-test subdirectory below goes with it.
trap 'rm -rf "$RUN_ROOT"' EXIT

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

tests=(t4-conflict.sh t7-roundtable.sh t8-graph.sh t11-decision.sh t14-verbs.sh t5-converge.sh t6-stuck.sh t9-lap.sh t9b-untrusted.sh t9c-room-inputs.sh t9d-lane-provenance.sh t9e-author-identity.sh t9f-decided-needs-record.sh t9g-degrades-loudly.sh t9h-roster-order.sh t3-token.sh t13-relaunch.sh t15-term-adapter.sh t16-keeper-canary.sh t17-esc-mailbox.sh t18-flow-admission.sh t19-keeper-rebuild.sh t20-global-options.sh t21-say.sh t22-blocked.sh t23-decide-announces.sh t24-relaunch-absence.sh t25-opening-position.sh t26-decide-teardown.sh t27-monitor.sh)
[ "$FULL" = 1 ] && tests+=(t1-order.sh t2-latency.sh t2b-wake.sh t2c-bell.sh)
# --- the files run CONCURRENTLY -----------------------------------------------------------------
# What makes this safe is the per-test root above plus the fact that each file builds its own
# rooms, fifos and fake binaries and names its own terminal sessions. That is the property to
# check before adding a file that does not — a new test reaching for a path outside its own
# `$COUNCIL_TEST_ROOT` is the way this stops being true.
#
# COUNCIL_TEST_JOBS overrides the width; 1 restores the old serial behaviour exactly, which is
# what to reach for when interleaved work makes a flake hard to read. The cap exists because a
# room is several concurrent shells per participant, so this suite saturates a box faster than
# its core count suggests — and a saturated box does not produce a clean "too slow" failure here,
# it produces an asymmetric protocol failure that reads as a transport bug (see $NICE above, which
# is the other half of the same defence and still applies to every worker).
#
# OUTPUT IS BUFFERED PER FILE and printed whole, in the order of the array above, so a failure
# reads exactly as it did when this loop was serial, and the per-test ceiling below still reports
# against the file it fired on.
#
# DUPLICATED, not shared with the shipyard runner, and deliberately: the two are not one algorithm
# — this one wraps each file in `timeout` and `nice` and has a `--full` arm, that one has neither
# — so what would be shared is scheduling boilerplate rather than an answer to a question both
# ask. It also keeps this suite runnable from an installed plugin, which has no repo `scripts/`
# beside it. Scope checked today: these two runners and no other. If a THIRD runner needs the same
# scheduling, or if these two converge so the differences above go away, move it to `shared/`.
NPROC=$( { command -v nproc >/dev/null 2>&1 && nproc; } || sysctl -n hw.ncpu 2>/dev/null || echo 4 )
JOBS="${COUNCIL_TEST_JOBS:-$NPROC}"
case "$JOBS" in ''|*[!0-9]*) JOBS=1 ;; esac
[ "$JOBS" -ge 1 ] || JOBS=1
[ "$JOBS" -le 8 ] || JOBS=8

OUTDIR="$RUN_ROOT/.out"; mkdir -p "$OUTDIR" || exit 1

i=0
for t in "${tests[@]}"; do
  # `jobs -pr` counts what is still running; read inside `$( )`, which is a subshell that inherits
  # the job table for reporting, so the count is this shell's (the same idiom, measured, as the
  # EXIT trap in _helpers.sh). `wait -n` would be tidier and is bash 4.3+; this spelling needs
  # nothing newer than the rest of the runner.
  while [ "$(jobs -pr | wc -l)" -ge "$JOBS" ]; do sleep 0.05; done
  (
    COUNCIL_TEST_ROOT="$RUN_ROOT/${t%.sh}"
    mkdir -p "$COUNCIL_TEST_ROOT" || exit 1
    export COUNCIL_TEST_ROOT
    if [ -n "$TIMEOUT_BIN" ]; then
      # -k: a test that ignores the TERM still goes, ten seconds later.
      # nice OUTSIDE timeout: the ceiling inherits the priority and passes it on, and a niced
      # `timeout` still fires on schedule — it sleeps, it does not spin.
      ${NICE[@]+"${NICE[@]}"} "$TIMEOUT_BIN" -k 10 "$PER_TEST_SECS" bash "$DIR/$t" >"$OUTDIR/$i.out" 2>&1; st=$?
    else
      ${NICE[@]+"${NICE[@]}"} bash "$DIR/$t" >"$OUTDIR/$i.out" 2>&1; st=$?
    fi
    printf '%s' "$st" >"$OUTDIR/$i.rc"
  ) &
  i=$((i + 1))
done
wait

rc=0
i=0
for t in "${tests[@]}"; do
  printf '\n──── %s ────\n' "$t"
  cat "$OUTDIR/$i.out" 2>/dev/null
  # A missing .rc means the worker itself died (killed, out of memory). That is a failure, and one
  # that would otherwise be reported as a pass over a file whose output is also missing.
  st=$(cat "$OUTDIR/$i.rc" 2>/dev/null) || st=""
  case "$st" in
    0)       ;;
    124|137) echo "TIMED OUT after ${PER_TEST_SECS}s: $t"; rc=1 ;;
    *)       echo "FAILED: $t"; rc=1 ;;
  esac
  i=$((i + 1))
done
printf '\n%s\n' "$([ $rc = 0 ] && echo 'all tests passed' || echo 'THERE ARE FAILURES')"
exit $rc
