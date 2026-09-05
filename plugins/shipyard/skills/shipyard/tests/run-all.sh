#!/usr/bin/env bash
# run-all.sh - the shipyard script suite. Run by hand:
#
#   bash plugins/shipyard/skills/shipyard/tests/run-all.sh
#
# Registration is gated: scripts/check.sh check 10 requires every test file here to appear in the
# single-line `tests` array below, so a test cannot silently stop being run. The suite itself
# runs under `make test` (not `make check` — at ~20s it is too slow for a per-commit gate, so its
# RUNTIME errors surface there, not at commit time). check 9's temp-room grep stays council-specific.
#
# Most tests are pure functions over fixture files and environment variables. The continuity
# suite also starts one short detached watcher against a fake `agtermctl`, proves idempotency,
# and reaps it through the real lifecycle cleanup. Nothing uses the network or fixtures outside
# its own mktemp directory.
#
# SCOPE IS DELIBERATELY NARROW, and the rule is about PROVENANCE, not about counting: every
# property asserted here traces to a defect this code actually shipped or a live failure this
# repository is closing. Boundary tables expand those properties into multiple cheap checks;
# that expansion is not padding, and the count is not the contract. Do not add a property that
# has no defect behind it: a suite longer than the code it guards stops being run.
#
# WHAT IS NOT COVERED, so that a green run is never read as more than it is — `ctx_transcript` has
# no test at all, and neither does `ctx_probe`'s transcript branch. Specifically unguarded: the
# project-directory slug, the newest-by-mtime choice, the exclusion of subagent transcripts, the
# CLAUDE_CONFIG_DIR/CLAUDE_HOME resolution, and which of `cur`/`peak` feeds ctx_window (the pane
# path the tests use sets them equal). The continuity suite uses recorded screen shapes and a
# fake terminal CLI; it does not exercise a real control socket or prove a future Codex build
# renders the same markers. Mutate any uncovered path and this suite still passes.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# One single-line array: the gate (scripts/check.sh check 10) reads registrations from a
# single-line `tests` array and reds loudly if a test file here is not listed, so a test cannot
# silently stop running. Splitting this across lines hides the tail from that extraction.
tests=(t1-totals.sh t2-window.sh t3-probe.sh t4-band.sh t5-agent.sh t6-codex-ctx.sh t7-continuity.sh t8-backend-adapter.sh)

rc=0
for t in "${tests[@]}"; do
  printf '\n──── %s ────\n' "$t"
  bash "$DIR/$t" || rc=1
done
printf '\n%s\n' "$([ $rc = 0 ] && echo 'all tests passed' || echo 'THERE ARE FAILURES')"
exit $rc
