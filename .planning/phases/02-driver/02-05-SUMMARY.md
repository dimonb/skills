# SUMMARY — 02-05 · suites in the gate (SHIPPED)

**Requirements:** GATE-01 (gate stays green + extended), and closes concern C7 (ungated suites).
**Plan:** issue **#84** (+ decision 84-1, answered A+B under delegation). **Ship:** PR **#85** →
merged `c984d97`.

## Decision 84-1 (answered by me)
Measured: driver ~1.7s, shipyard ~20s, council-fast ~117s, and **no CI**. Chose **A+B**:
- A: generalize the registration check (was council-only check 10) to all 3 suites — catches "a
  test file stops being executed" at commit time, statically, fast.
- B: also run the fast driver suite INSIDE `make check` (its runtime gated every commit).
- New `make test` runs the 3 fast subsets (~2.5 min), by hand like `make check-test`.
- **CI (option C) deferred** as its own decision for the soon-public repo (follow-up).

## What shipped
- `scripts/check.sh` generalized; `make check` now runs the driver suite + registration checks,
  stays fast (**~3.7–4.6s**). `Makefile` gains `make test`. `scripts/check-test.sh` gains
  kill-tests for the new arms (**check-test 79/0**). AGENTS.md/README document which target runs
  what and the honest limitation (shipyard/council RUNTIME errors are caught by `make test`, not
  `make check`).

## Verification
- ship review: 3 blockers in the test-of-the-test fixed; round 2 clean.
- Re-verified on head: `make check` runs the driver suite (59 checks) fast; `make check-test`
  79/0, self-restored clean.

## Result
No suite is silently ungated. **Phase 2 COMPLETE — all 5 tasks in prod (#77/#79/#81/#83/#85).**
