#!/usr/bin/env bash
# run-all.sh — the shipyard-ctx.sh suite. Run by hand:
#
#   bash plugins/shipyard/skills/shipyard/tests/run-all.sh
#
# NOT wired into `make check`. The gate's checks 9 and 10 register the COUNCIL tests specifically
# (check 9's assertion is a grep for council's own temp-room shape), so generalising them is more
# than a couple of lines and would mean editing scripts/check.sh in the same breath as it changed
# under another PR. That gap is written down in issue #58 rather than papered over here: these
# tests are real, they are fast, and nothing yet forces anyone to run them.
#
# Everything under test is a pure function over a file and two environment variables, so this
# needs no process machinery, no network and no fixtures outside its own mktemp dir.
#
# SCOPE IS DELIBERATELY NARROW: seven assertions, and each one has already caught a real defect
# in this code — six from the round of review that produced these files, plus the band that round
# added. Assertions that have not demonstrated they catch something were left out on purpose,
# because a suite padded with them takes longer to read than the code and stops being run.
# What is therefore NOT covered, and is carried by comment alone: the project-directory slug
# ctx_transcript derives, and the exclusion of subagent transcripts.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tests=(t1-totals.sh t2-window.sh t3-probe.sh t4-band.sh)

rc=0
for t in "${tests[@]}"; do
  printf '\n──── %s ────\n' "$t"
  bash "$DIR/$t" || rc=1
done
printf '\n%s\n' "$([ $rc = 0 ] && echo 'all tests passed' || echo 'THERE ARE FAILURES')"
exit $rc
