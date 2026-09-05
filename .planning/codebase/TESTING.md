# TESTING — test structure and practices

## council — `tests/`
- `run-all.sh`, `_helpers.sh`, and **21** `t*.sh` (t1, t2, t2b, t2c, t3, t4, t5, t6, t7, t8, t9, t9b–t9h, t11, t13, t14).
- Runner: fast subset by default, `--full` adds load/latency runs (`run-all.sh:1-3,56-57`); per-test `timeout(1)` ceiling (`:29-31,61-73`), `nice` (`:40-43`), own mktemp root reaped via keeper poll (`:12-21`).

## shipyard — `tests/`
- `run-all.sh`, `_helpers.sh`, and **7** `t*.sh` (t1-totals, t2-window, t3-probe, t4-band, t5-agent, t6-codex-ctx, t7-continuity) — `run-all.sh:33-34`.
- Runner: plain loop (`run-all.sh:36-40`).

## ⚠️ The gate does NOT run these tests
- shipyard's runner says so explicitly: the gate's checks 9/10 are council-specific and
  generalising them is tracked in an issue; "nothing yet forces anyone to run them"
  (`shipyard/tests/run-all.sh:6-10`).
- **Consequence for this project:** "green tests" (GATE-01, MIG-03 acceptance) means the
  relevant `tests/run-all.sh` is **invoked explicitly** in each phase — `make check` alone will
  not exercise the new driver/guard/policy. A phase that adds behaviour should also either wire
  its tests into the gate or state the manual run in its SUMMARY. Prefer wiring in
  (`AGENTS.md:172-173`: extend the gate rather than add a caveat).

## Practice to match
- New behaviour lands with a `t*.sh` beside the existing ones; a new gate rule gets a probe in
  `check-test.sh` (else it may be vacuous).
