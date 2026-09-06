# SUMMARY — 04-02 · shipyard on the flow guard (FLOW-03, SHIPPED)

**Requirement:** FLOW-03. **Plan:** issue **#100** (+ decision 100-1, answered Option B under
delegation). **Ship:** PR **#101** → merged `e05b410`. The last migration.

## Decision 100-1 (answered by me): Option B — `flow_phase`, not `flow_run`
The issue's framing assumed `flow_run` (drive one agent) fit shipyard. The child's grounded analysis
showed it does not: shipyard MONITORS an autonomous child (an authority read of "which phase / is it
terminal"), it does not step-drive it. `flow_run` was rejected on three mechanical grounds —
it parks legitimately-idle children (a ship child idles on CI and on escalation answers), it BLOCKS
a shell inside what must be a non-blocking all-slots snapshot (needing a new persistent per-slot
driver = not behaviour-preserving), and it keys completion on `drv_signal` while shipyard's terminal
is forge-state + terminal-absence. A hybrid (C) was rejected as decorative (the #99 lesson).

## What shipped
- `shipyard-slot-graph.sh` (167 lines) — the supervision lifecycle (`launched` → `in-review` →
  `concluded`) declared as data, decoupled from ship's internal stage enum; every `done_when` a
  mechanical `check` over an existing reader (FLOW-02 holds).
- `shipyard-report.sh` (+34) now derives the slot phase, the sidebar glyph verdict and the
  loop-terminal condition from that ONE declared authority — replacing the scattered if/elif.
  **Load-bearing, not decorative** (report.sh:248-255, :319).
- `tests/t11-slot-graph.sh` (118 lines). **Zero shared-module change** (`flow_phase` already existed
  from #99) — no drift.

## Verification
- CI green on the PR (make check + check-test + test, 5m14s). `make check` green on head and on
  merged main. shipyard t1..t11 + council green (via CI).
- **Dogfooding check passed:** `shipyard-report.sh` — the script the live supervisor's monitors run —
  still produces its table correctly on the migrated shipyard, on merged main.

## Result
Both skills now sit on the shared driver + policy + guard. **Phase 4 complete; the unification is
done.** Emergent finding recorded as a follow-up: with both skills on `flow_phase`, the guard's
`flow_run` drive mode has no production caller — the original "drive agents" premise did not hold;
both skills are monitor/authority. Decide separately whether to remove it (YAGNI) or keep it as a
justified general primitive.
