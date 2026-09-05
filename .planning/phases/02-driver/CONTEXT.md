# CONTEXT — Phase 2: Extract the driver

GSD discuss-phase. Decisions taken autonomously (the user delegated them), grounded in the
codebase map and the spike result.

## Implementation decisions

1. **Canonical location = `shared/driver/agent-driver.sh` (repo root, build input).**
   Neutral (privileges neither plugin), not itself a shipped skill. Vendored into each plugin by
   `scripts/sync-driver.sh`; gate check 11 enforces no drift. Proven by the spike (commit
   `236bd20`, `check-test` green). Alternative homes (inside a plugin, a dedicated core plugin)
   were rejected as either asymmetric or heavier for no gain.

2. **Bash baseline = ≥ 5, re-exec'd — as council already does (`council.sh:26-38`).**
   The driver uses associative arrays / `read` niceties freely. shipyard is written for 3.2
   today; task 02-04 must confirm shipyard tolerates a ≥ 5 driver (it invokes the driver as
   functions, not as a 3.2 interpreter of the driver's own body, so the risk is low). Recorded as
   a verify step, not an assumption.

3. **Tests wired into the gate as behaviour lands (closes C7).** Today neither skill's
   `tests/run-all.sh` runs under `make check` (`shipyard/tests/run-all.sh:6-10`). Each migration
   task that changes behaviour also wires the relevant tests into the gate (or its SUMMARY states
   the manual run). Prefer wiring in — `AGENTS.md:172-173`.

4. **The driver is a SUPERSET that reproduces each skill's exact behaviour.** CORRECTION (found
   by the #78 child, verified in code): both backends append `-ai` to the agterm workspace
   **identically** (`term.sh:57-58`, `shipyard-backend.sh:139,143`) — the earlier claim that only
   council did was wrong. The REAL differences are the repo-key `:`→`_` transform (shipyard only),
   the pin-file location (`$ROOM/state` vs the shipyard mailbox), the override env (shipyard has
   `SHIPYARD_WORKSPACE`/`SESSION`, council none), and shipyard's extra surface
   (`shipyard_note`/`notify`/`container_prune`/`slot_addr`). The merge preserves both current
   container names exactly and exposes these differences (plus the `-ai` suffix) as caller-set
   vars. No behaviour change ships in Phase 2 — it is pure extraction.

5. **Migration is validated by the skills' own tests, not by inspection.** A migrated call site
   is correct only when that skill's `tests/run-all.sh` is green. council (21 tests) is migrated
   first because it has the richer suite; shipyard (7 tests) second.

## Open items carried forward

- The `drv_signal` normalization (AgentSignal) is scoped to Phase 2 only far enough to replace
  today's ad-hoc reads; the full escalation dispositions are Phase 3 (ESC-*).
- Per-agent adapters (`adapters/<kind>.sh`) stay where they are for now; unifying the adapter
  seam across both skills is folded into 02-03/02-04 as each skill's launch path moves.
