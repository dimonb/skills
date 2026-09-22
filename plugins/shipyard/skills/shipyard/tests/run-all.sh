#!/usr/bin/env bash
# run-all.sh - the shipyard script suite. Run by hand:
#
#   bash plugins/shipyard/skills/shipyard/tests/run-all.sh
#
# Two things are gated, both in scripts/check.sh. Check 10 requires every test file here to appear
# in the single-line `tests` array below, so a test cannot silently stop being run; check 12
# requires this suite to be named in $GATED_SUITES and its runner to be named by a Makefile recipe,
# so the suite as a whole cannot stop running either. The suite itself runs under `make test` (not
# `make check` — it is minutes rather than seconds, so its RUNTIME errors surface there, not at
# commit time). No wall-clock figure is quoted here on purpose: the one that used to be went stale
# by a factor of four without anything saying so, and a stale number gets used to justify a
# decision. The Makefile measures what `make check` costs, because that is the one under a budget.
# check 9's temp-room grep stays council-specific.
#
# Most tests are pure functions over fixture files and environment variables. The continuity
# suite also starts one short detached watcher against a fake `agtermctl`, proves idempotency,
# and reaps it through the real lifecycle cleanup. Two files deliberately drop the fixture rule
# for their ASSERTIONS, each because the defect it closes IS git's answer, so a faked git would
# only replay the belief under test: t12 (the teardown gate — real repositories, real squash
# merges, real worktrees) and t17 Part A (what `worktree remove` actually does — a real bare
# origin, a real clone and real registered worktrees, faking only the terminal backend). t5 and
# t6 also shell out to real git, but only as scaffolding: neither asserts anything about what
# git answered. Those are the files checked when this sentence was last written, and nothing in
# the gate keeps the list complete — read the files rather than trusting the sentence.
#
# Updating it is part of whatever change adds the next one. It read "t12 is the one deliberate
# exception" until t17 landed, and the change that ADDED the second exception is the one that
# left it claiming there was none — the repeat defect AGENTS.md names by name.
#
# SCOPE IS DELIBERATELY NARROW, and the rule is about PROVENANCE, not about counting: every
# property asserted here traces to a defect this code actually shipped or a live failure this
# repository is closing. Boundary tables expand those properties into multiple cheap checks;
# that expansion is not padding, and the count is not the contract. Do not add a property that
# has no defect behind it: a suite longer than the code it guards stops being run.
#
# WHAT IS NOT COVERED, so that a green run is never read as more than it is: on the CLAUDE side,
# `ctx_claude_transcript` has no test — the project-directory slug, the newest-by-mtime choice,
# the exclusion of subagent transcripts and the CLAUDE_CONFIG_DIR/CLAUDE_HOME resolution are all
# unguarded. t3 reaches `ctx_probe`'s transcript branch by REPLACING that lookup with a fixture
# path, so what it proves is the logic downstream of it — which of `cur`/`peak` feeds the window
# assignment — and nothing about how the file is found. The CODEX lookup is different: t6 drives
# `ctx_codex_transcript` against a real fixture tree, so that half IS covered, while the codex
# arm's FALL-THROUGH (no rollout, or a rollout with no token_count event, which lands a codex
# child on the claude inference) is covered by nothing.
#
# The two halves of the ctx column that live in shipyard-report.sh — the `❓` block's per-cause
# dispatch and `sig_band`, neither of which can be unit-tested because that file cannot be sourced
# — are driven by t13's section D through its faked backend, and both were mutation-checked when
# they landed. What t1-t4 pin is shipyard-ctx.sh's pure functions; do not read a green ctx suite as
# covering the report's rendering of them. The continuity suite uses recorded screen
# shapes and a fake terminal CLI; it does not exercise a real control socket or prove a future
# Codex build renders the same markers. Mutate any uncovered path and this suite still passes.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# One single-line array: the gate (scripts/check.sh check 10) reads registrations from a
# single-line `tests` array and reds loudly if a test file here is not listed, so a test cannot
# silently stop running. Splitting this across lines hides the tail from that extraction.
tests=(t1-totals.sh t2-window.sh t3-probe.sh t4-band.sh t5-agent.sh t6-codex-ctx.sh t7-continuity.sh t8-backend-adapter.sh t9-admission.sh t10-continuity-canary.sh t11-slot-graph.sh t12-down-gate.sh t13-wait.sh t14-signal.sh t15-iid-fallback.sh t16-tell-knobs.sh t17-autodown.sh)

# --- the files run CONCURRENTLY -----------------------------------------------------------------
# Every file here builds its own fixture root under `mktemp -d` and removes it, fakes its own
# backend, and names its own terminal session, so no two share mutable state — which is what makes
# this safe and is the property to check before adding a file that does not.
#
# SHIPYARD_TEST_JOBS overrides the width; 1 restores the old serial behaviour exactly, which is
# what to reach for when interleaved work makes a flake hard to read. The cap exists because these
# are not CPU-bound — they wait on child processes and on `sleep` — so more workers than cores
# still helps, but not without limit, and an unbounded fan-out on a box already driving a fleet is
# how a suite becomes the reason its own assertions fail.
#
# OUTPUT IS BUFFERED PER FILE and printed whole, in the order of the array above, so a failure
# reads exactly as it did when this loop was serial. Interleaving the lines live would be faster
# to write and much worse to read.
#
# DUPLICATED, not shared with the council runner, and deliberately: the two runners are not one
# algorithm — that one wraps each file in `timeout` and `nice` and has a `--full` arm, this one has
# neither — so what would be shared is scheduling boilerplate, not an answer to a question both
# ask. It also keeps this suite runnable from an installed plugin, which has no repo `scripts/`
# beside it. Scope checked today: these two runners and no other. If a THIRD runner needs the same
# scheduling, or if these two converge so the differences above go away, move it to `shared/`.
#
# `jobs -pr` counts what is still running. It is read inside `$( )`, which is a subshell — the job
# table is inherited for reporting, so the count is this shell's (measured in the council helpers'
# EXIT trap, same idiom). `wait -n` would be tidier and is bash 4.3+; this stays on the 3.2-safe
# spelling because nothing else in this runner needs a newer shell.
NPROC=$( { command -v nproc >/dev/null 2>&1 && nproc; } || sysctl -n hw.ncpu 2>/dev/null || echo 4 )
JOBS="${SHIPYARD_TEST_JOBS:-$NPROC}"
case "$JOBS" in ''|*[!0-9]*) JOBS=1 ;; esac
[ "$JOBS" -ge 1 ] || JOBS=1
[ "$JOBS" -le 8 ] || JOBS=8

OUTDIR=$(mktemp -d "${TMPDIR:-/tmp}/shipyard-tests.XXXXXXXX") || exit 1
trap 'rm -rf "$OUTDIR"' EXIT

i=0
for t in "${tests[@]}"; do
  while [ "$(jobs -pr | wc -l)" -ge "$JOBS" ]; do sleep 0.05; done
  ( bash "$DIR/$t" >"$OUTDIR/$i.out" 2>&1; printf '%s' "$?" >"$OUTDIR/$i.rc" ) &
  i=$((i + 1))
done
wait

rc=0
i=0
for t in "${tests[@]}"; do
  printf '\n──── %s ────\n' "$t"
  cat "$OUTDIR/$i.out" 2>/dev/null
  # A missing .rc means the worker itself died (killed, out of memory) — which is a failure, and
  # one that would otherwise be reported as a pass over a file whose output is also missing.
  st=$(cat "$OUTDIR/$i.rc" 2>/dev/null) || st=""
  if [ "$st" != 0 ]; then printf 'FAILED: %s\n' "$t"; rc=1; fi
  i=$((i + 1))
done
printf '\n%s\n' "$([ $rc = 0 ] && echo 'all tests passed' || echo 'THERE ARE FAILURES')"
exit $rc
