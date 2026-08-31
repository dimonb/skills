#!/usr/bin/env bash
# run-all.sh - the shipyard script suite. Run by hand:
#
#   bash plugins/shipyard/skills/shipyard/tests/run-all.sh
#
# NOT wired into `make check`. The gate's checks 9 and 10 register the COUNCIL tests specifically
# (check 9's assertion is a grep for council's own temp-room shape), so generalising them is more
# than a couple of lines and would mean editing scripts/check.sh in the same breath as it changed
# under another PR. That gap is written down in dimonb/skills#58 rather than papered over here:
# these tests are real, they are fast, and nothing yet forces anyone to run them.
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

tests=(t1-totals.sh t2-window.sh t3-probe.sh t4-band.sh t5-agent.sh t6-codex-ctx.sh
       t7-continuity.sh)

rc=0
for t in "${tests[@]}"; do
  printf '\n──── %s ────\n' "$t"
  bash "$DIR/$t" || rc=1
done
printf '\n%s\n' "$([ $rc = 0 ] && echo 'all tests passed' || echo 'THERE ARE FAILURES')"
exit $rc
