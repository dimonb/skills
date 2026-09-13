.PHONY: check check-test test

# The gate; must be green before every commit. Runs the static checks (scripts/check.sh) and then
# every pure, fast suite — driver, flow, adapters, policy, knobs — so a regression in any of them
# reds a commit. Whole target measured at 8.9s wall, warm and otherwise idle (gate 2.4s; driver
# 1.3s, flow 2.3s, adapters 1.9s, policy 0.9s, knobs 0.1s), and more under load. The figure lives
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

# The test suites' fast subsets: driver, flow, adapters, policy, shipyard, and council (without
# council's slow `--full` load and latency runs). Run by hand to verify a change for real
# (~2-3 min), like `make check-test`. This is where a shipyard or council suite RUNTIME error
# surfaces — `make check` does not run those two (only their registration and invocation are gated
# at commit time; the other four suites run there in full).
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
