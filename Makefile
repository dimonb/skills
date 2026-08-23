.PHONY: check check-test

# The gate. Must be green before every commit.
check:
	@bash scripts/check.sh

# Prove the gate's assertions actually fire. Needs a clean working tree.
check-test:
	@bash scripts/check-test.sh
