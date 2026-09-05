.PHONY: check check-test test

# The gate. Static and fast (~2s); must be green before every commit. Runs the static checks
# (scripts/check.sh) and then the driver suite, which is fast enough to gate every commit — so a
# driver-suite regression reds a commit. The shipyard and council suites are too slow for a
# per-commit gate; `make test` runs those. What `make check` DOES gate for all three suites,
# statically, is registration: a test file that stops being listed in its run-all.sh reds here
# (scripts/check.sh check 10), so a suite cannot silently stop running.
check:
	@bash scripts/check.sh
	@bash shared/driver/tests/run-all.sh

# The test suites' fast subsets: driver, shipyard, and council (without its slow `--full` load and
# latency runs). Run by hand to verify a change for real (~2-3 min), like `make check-test`. This
# is where a shipyard or council suite RUNTIME error surfaces — `make check` does not run those two
# (only their registration, and the driver suite, are gated at commit time).
test:
	@bash shared/driver/tests/run-all.sh
	@bash plugins/shipyard/skills/shipyard/tests/run-all.sh
	@bash plugins/council/skills/council/tests/run-all.sh

# Prove the gate's assertions actually fire. Needs a clean working tree.
check-test:
	@bash scripts/check-test.sh
