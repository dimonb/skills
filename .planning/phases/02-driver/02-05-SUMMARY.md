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
**Phase 2 COMPLETE — all 5 tasks in prod (#77/#79/#81/#83/#85).**

**CORRECTION (made at #111).** This section claimed "No suite is silently ungated." That was true
of the suites that existed when it was written, and false from #96 onward: the policy module
shipped its suite into no Makefile target and into no entry of check 10's list, so it ran in NO
automated invocation for four phases and a test dropped from it would have reddened nothing. Found
by the #104 child while reviewing its own change; closed by #111.

Two things this got wrong, both worth keeping:
* The claim was about a **state**, not an invariant, and nothing made it stay true. What #111 adds
  is the missing invariant — check 12 asserts every runner on disk is BOTH invoked by a Makefile
  target and present in check 10's list, so a future suite cannot be wired in half way.
* Its root cause was sanctioned, not accidental: `.planning/codebase/TESTING.md` offered a phase
  the choice to "wire its tests into the gate **or** state the manual run in its SUMMARY". The
  second branch is how a suite comes to run nowhere.
