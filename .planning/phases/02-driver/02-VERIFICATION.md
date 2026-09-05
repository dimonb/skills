# VERIFICATION — Phase 2: Extract the driver

Requirement coverage. **Phase COMPLETE** — all shipped to prod.

| Req | Statement | Covered by | Status |
|-----|-----------|------------|--------|
| DRV-01 | Backend-agnostic session control (`drv_*` over agterm/tmux) | #79 driver body; verified by t-driver (59 checks) | ✅ |
| DRV-02 | Agent-agnostic via adapters | #79 fixes the `drv_*` interface; per-kind **adapter unification deferred** (still `adapters/<kind>.sh` in council, `shipyard-agent.sh` in shipyard) | 🟡 partial |
| DRV-03 | Normalized signal read (AgentSignal) | #79 `drv_signal` — MINIMAL (liveness + idle/busy); full dispositions are Phase 3 (ESC) | 🟡 minimal, by design |
| DRV-04 | One driver replaces two copies | #79 body + #81 (council) + #83 (shipyard); no backend function defined twice | ✅ |
| MIG-01 | Skill surface unchanged for users | #81, #83 — verbs/entrypoints unchanged; council 21/21, shipyard suite green | ✅ |
| MIG-02 | Shared code one home, gate-enforced | #77 — canonical + vendored copies + check 11 (drift), check-test 79/0 | ✅ |
| MIG-03 | Incremental, test-guarded rollout | driver → council → shipyard → gate, each behind its own green suite | ✅ |
| GATE-01 | `make check`/`make check-test` green + extended | green on every merge; strengthened by #85 (suites in gate) | ✅ |
| GATE-02 | Generic-only (rule zero) | #77 review caught + fixed a `.planning` leak in the driver comment | ✅ |
| GATE-03 | Portable Claude Code + Codex | vendored-copy mechanism exists BECAUSE Codex has no cross-plugin dep; both manifests unchanged | ✅ |
| GATE-04 | English, conventional commits, labels | all PRs conventional + labelled; no attribution footers | ✅ |

## Deferred (tracked, not omitted)
- **DRV-02 adapter unification** — folding the per-kind adapter seam across both skills was left to
  a later change; the `drv_*` interface is done and each skill keeps its current adapter. Raise as
  a follow-up if/when the adapter duplication actually bites.
- **DRV-03 full AgentSignal dispositions** — Phase 3 (ESC) work; #79 only implements the minimal
  read the migration needed.

**Exit:** Phase 2 requirements met (DRV-02/03 partial by explicit design, tracked above).
Merges: #77 `6685ecd`, #79 `911d3db`, #81 `6fd1c08`, #83 `05cf692`, #85 `c984d97`.
