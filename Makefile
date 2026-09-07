.PHONY: check check-test test

# The gate; must be green before every commit. Runs the static checks (scripts/check.sh, ~3-4s)
# and then the driver, flow and adapter suites, which are fast enough to gate every commit — so a
# regression in any of the three reds a commit. Whole target measured at 6-10s wall depending on
# machine load, which is why the figure lives here and not in a prose log: a wall-clock number
# recorded elsewhere goes stale silently and then gets used to justify a decision.
# The shipyard and council suites are too slow for a per-commit gate; `make test` runs those.
# What `make check` DOES gate for those five suites, statically, is registration: a test file that
# stops being listed in its run-all.sh reds here (scripts/check.sh check 10), so a suite cannot
# silently stop running. shared/policy/tests is in NO target and NO gate — see AGENTS.md.
check:
	@bash scripts/check.sh
	@bash shared/driver/tests/run-all.sh
	@bash shared/flow/tests/run-all.sh
	@bash shared/adapters/tests/run-all.sh

# The test suites' fast subsets: driver, flow, adapters, shipyard, and council (without its slow
# `--full` load and latency runs). Run by hand to verify a change for real (~2-3 min), like `make
# check-test`. This is where a shipyard or council suite RUNTIME error surfaces — `make check` does
# not run those two (only their registration, and the driver, flow and adapter suites, are gated
# at commit time).
test:
	@bash shared/driver/tests/run-all.sh
	@bash shared/flow/tests/run-all.sh
	@bash shared/adapters/tests/run-all.sh
	@bash plugins/shipyard/skills/shipyard/tests/run-all.sh
	@bash plugins/council/skills/council/tests/run-all.sh

# Prove the gate's assertions actually fire. Needs a clean working tree.
check-test:
	@bash scripts/check-test.sh
