# TESTING — test structure and practices

## council — `tests/`
- `run-all.sh`, `_helpers.sh`, and **21** `t*.sh` (t1, t2, t2b, t2c, t3, t4, t5, t6, t7, t8, t9, t9b–t9h, t11, t13, t14).
- Runner: fast subset by default, `--full` adds load/latency runs (`run-all.sh:1-3,56-57`); per-test `timeout(1)` ceiling (`:29-31,61-73`), `nice` (`:40-43`), own mktemp root reaped via keeper poll (`:12-21`).

## shipyard — `tests/`
- `run-all.sh`, `_helpers.sh`, and **7** `t*.sh` (t1-totals, t2-window, t3-probe, t4-band, t5-agent, t6-codex-ctx, t7-continuity) — `run-all.sh:33-34`.
- Runner: plain loop (`run-all.sh:36-40`).

## The gate DOES run these tests — and gates three ways that a suite could stop running

Superseded. This section used to read "The gate does NOT run these tests", and its sanctioned
alternative — a phase "should also either wire its tests into the gate **or state the manual run
in its SUMMARY**" — is the loophole that produced #111: `shared/policy/tests` took the second
option and ran in no automated invocation at all from the day it landed. The option was not an
oversight; it was offered here. It is withdrawn: **wiring in is the only acceptable outcome**, and
the gate now enforces it rather than asking.

Current state, in `scripts/check.sh`:

- `$GATED_SUITES` names the six gated suites once. Check 10 walks it and requires every test file
  on disk to be registered in its runner's `tests` array.
- Check 12 asserts the two converse directions against the runners it finds on disk: each must be
  named by a `Makefile` recipe (so a suite cannot run nowhere), and each must appear in
  `$GATED_SUITES` (so a suite cannot be `make`-wired yet never registration-checked).
- `make check` RUNS driver, flow, adapters and policy; `make test` adds shipyard and council; CI
  runs `make check`, `make check-test` and `make test`.

**Consequence for this project:** "green tests" no longer means a manual per-phase run. Adding a
suite means two edits — `$GATED_SUITES` and a `Makefile` recipe — and the gate reds until both are
done. Checks 9's temp-path scan remains council-specific by design.

## Practice to match
- New behaviour lands with a `t*.sh` beside the existing ones; a new gate rule gets a probe in
  `check-test.sh` (else it may be vacuous).
