.PHONY: check check-test test

# The gate; must be green before every commit. Runs the static checks (scripts/check.sh) and then
# every pure, fast suite — driver, flow, adapters, policy, knobs — so a regression in any of them
# reds a commit. Whole target measured at 8.9s wall, warm and otherwise idle (gate 2.4s; driver
# 1.3s, flow 2.3s, adapters 1.9s, policy 0.9s, knobs 0.1s), and more under load — re-measured at
# 8.9s after #203 added check 13, so that check costs nothing worth recording. The figure lives
# here and not in a prose log because a wall-clock number recorded elsewhere goes stale silently
# and then gets used to justify a decision — so re-measure it here when you add a suite, rather
# than adjusting it by arithmetic.
# The shipyard and council suites are too slow for a per-commit gate; `make test` runs those.
# What `make check` gates for EVERY suite in $GATED_SUITES, statically, are the two ways a suite
# can silently stop running — separate classes, separate checks: a test file that stops being
# listed in its run-all.sh reds at scripts/check.sh check 10, and a runner that no recipe below
# invokes, or a suite missing from check.sh's $GATED_SUITES so check 10 never visits it, reds at
# check 12.
check:
	@bash scripts/check.sh
	@bash shared/driver/tests/run-all.sh
	@bash shared/flow/tests/run-all.sh
	@bash shared/adapters/tests/run-all.sh
	@bash shared/policy/tests/run-all.sh
	@bash shared/knobs/tests/run-all.sh

# Every suite's fast subset — the five `make check` runs, plus shipyard and council (without
# council's slow `--full` load and latency runs). Run by hand to verify a change for real, like
# `make check-test`. This is where a shipyard or council suite RUNTIME error surfaces — `make
# check` does not run those two (only their registration and invocation are gated at commit time;
# every other suite runs there in full).
#
# MEASURED at 7:50 wall with the load average between ~6 and ~51 during the run, most of it other
# work on the same box. Taken for #269, which added and grew several shipyard and council files, on
# the tree with both of its pull requests applied. A quiet box will be faster and a busier one
# slower. The figure before it was 5:29 at load ~8 to ~20, and before that 2:10 at load 14; none of
# the three is comparable to another. The per-file figures below are the ones to compare. It was
# 12-13 min at ~28% CPU before #203, and BOTH halves of that changed:
#
#   * the sleeping is gone. The suites used to wait on three production constants a faked backend
#     does not need — the report's motion diff, the keeper's poll, and `tell`'s settle delay — and
#     those are knobs now, set by the suites and unchanged in production. Three test files were
#     also holding a command substitution open on a backgrounded `sleep` (see #109); that was 60s
#     in each of two of them;
#   * the files of each slow suite now run CONCURRENTLY, so the wall clock is the LONGEST FILE
#     plus scheduling rather than the sum. That makes the figure below depend on the slowest file
#     and on the core count, which the old one did not — `COUNCIL_TEST_JOBS=1` and
#     `SHIPYARD_TEST_JOBS=1` restore the old serial behaviour if you need the old shape back.
#
# So the thing to watch is no longer the total: it is whether a file you are adding lands in the
# top few. The longest file is `t19-occupant`, at ~143s alone at load ~24, with `t17-autodown`
# (~43s) and `t16-tell-knobs` (~35s) timed in the same sitting. It was ~115s after #290 and ~102s
# before it, at loads not recorded, so the rise mixes load with #269's three added compaction runs;
# tracing compact.sh puts those at ~13s, run side by side, the longest because it waits out the
# loop's five-second poll. Most of its time is shipyard-compact.sh's fixed sleeps, paid once per run of that
# script. t16 is close to irreducible: the remaining time is three confirmation windows whose
# DURATIONS are what its assertions check.
#
# AND THE TARGET IS NOT MET, SO SAY SO HERE RATHER THAN LEAVE IT TO BE INFERRED. #203 wanted
# `make check` + `make test` comfortably under a minute; at #203's time they were ~2:20 together,
# against the earlier 2:10 figure, and a figure taken on a quiet box is what would settle it now. The remaining
# lever is that this recipe runs the two slow suites ONE AFTER THE OTHER even though each now
# fans out internally — overlapping them would cost roughly the longer of the two instead of the
# sum. It was not taken: each already fans out to min(nproc, 8), so running both at once
# oversubscribes the box, and this change has already measured what an oversubscribed box does
# to this suite (see the keeper-period note in council's tests/_helpers.sh). That is a judgement,
# not a measurement — if someone measures it and it holds, the minute is reachable.
#
# The figure said "~2-3 min" for a long time and went stale silently, which is the failure
# AGENTS.md warns about: re-measure this line when you add or grow a suite, and do not adjust it
# by arithmetic. It has now gone stale twice inside one change, and #203 was expected to be the
# most likely thing to make it stale again. If you are adding or growing a test, this line is part
# of your change. AGENTS.md points here rather than carrying its own number, so this is the place
# to update. CI runs the same target on every push and pull request.
test:
	@bash shared/driver/tests/run-all.sh
	@bash shared/flow/tests/run-all.sh
	@bash shared/adapters/tests/run-all.sh
	@bash shared/policy/tests/run-all.sh
	@bash shared/knobs/tests/run-all.sh
	@bash plugins/shipyard/skills/shipyard/tests/run-all.sh
	@bash plugins/council/skills/council/tests/run-all.sh

# Prove the gate's assertions actually fire. Needs a clean working tree.
check-test:
	@bash scripts/check-test.sh
