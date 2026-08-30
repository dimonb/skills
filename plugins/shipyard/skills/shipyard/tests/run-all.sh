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
# Everything under test is a pure function over a file and two environment variables, so this
# needs no process machinery, no network and no fixtures outside its own mktemp dir.
#
# SCOPE IS DELIBERATELY NARROW, and the rule is about PROVENANCE, not about counting: every
# property asserted here traces to a defect this code actually shipped — six from the round of
# review that produced these files, plus the band that round added. They are expanded into ~57
# checks because boundaries and the malformed-override table are cheap to enumerate once the
# property is there; that expansion is not padding, and the count is not the contract. Do not add
# a property that has no defect behind it: a suite longer than the code it guards stops being run.
#
# WHAT IS NOT COVERED, so that a green run is never read as more than it is — `ctx_transcript` has
# no test at all, and neither does `ctx_probe`'s transcript branch. Specifically unguarded: the
# project-directory slug, the newest-by-mtime choice, the exclusion of subagent transcripts, the
# CLAUDE_CONFIG_DIR/CLAUDE_HOME resolution, and which of `cur`/`peak` feeds ctx_window (the pane
# path the tests use sets them equal). Mutate any of those and this suite still passes.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tests=(t1-totals.sh t2-window.sh t3-probe.sh t4-band.sh t5-agent.sh t6-codex-ctx.sh)

rc=0
for t in "${tests[@]}"; do
  printf '\n──── %s ────\n' "$t"
  bash "$DIR/$t" || rc=1
done
printf '\n%s\n' "$([ $rc = 0 ] && echo 'all tests passed' || echo 'THERE ARE FAILURES')"
exit $rc
