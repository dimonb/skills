# VERIFICATION — Phase 4: FLOW guard

**Core COMPLETE** (issue #95 → PR #97 → `4ba98ba`). Migrations (FLOW-03/04/05) are open, tracked.

| Req | Statement | Covered by | Status |
|-----|-----------|------------|--------|
| FLOW-01 | Declared step-graph the interpreter reads (no skill branch) | `flow.sh` `flow_node`/`flow_run`; node fields enter/done_when/on_done/on_block; t-flow | ✅ |
| FLOW-02 | Mechanical transitions only (no model in the loop) | fixed `done_when` vocabulary {signal,artifact,budget,check}; `check` is deterministic; STRUCTURAL, tested | ✅ |
| FLOW-03 | shipyard as a one-node graph (drive one agent via `flow_run`) | — | 🔲 open — a decision (see below) |
| FLOW-04 | council as a turn-cycle graph | #98 → #99 → `3e333ea` (via the `flow_phase` authority mode; t18 pins the race retired) | ✅ shipped |
| FLOW-05 | Multi-agent turn-taking | reframed — see below | 🟡 largely subsumed |

## Also delivered (beyond FLOW-01/02)
- **C1 gate generalization**: one shared-module drift gate iterates every `shared/<mod>/`
  (driver/flow/policy) — verified on final main (each copy drift reds). Retires the duplicate check.
- **t10-continuity-canary** made robust under make-test/CI load (the flake #92's CI exposed).

## Open tails (tracked)
- **FLOW-03 (shipyard as a one-node graph, `flow_run`)** — the remaining migration. Weaker
  justification than FLOW-04 had: shipyard has no barrier-race class to retire; its monitor+escalate
  supervision already works, so FLOW-03 buys mainly *consistency* (both skills visibly on the guard),
  and it is **dogfooding** (it migrates the tool that runs the fleet). A scope decision is due:
  worth the dogfooding risk for consistency, or leave shipyard's supervision as-is and call the guard
  adopted where it earns its keep (council)?
- **FLOW-05 (drive N agents in gated turns) — reframed / largely subsumed.** The 98-1 decision
  established that council uses the `flow_phase` AUTHORITY mode, not a drive loop: the guard already
  gates N seats' turns via the declared graph, while seats stay autonomous. Literally *driving* N
  agents as puppets is against council's lock-free, autonomous-seat design (rejected as Option B).
  So "multi-agent turn-taking" is achieved by FLOW-04's authority mode; FLOW-05-as-drive-N is not a
  goal unless a future use case needs puppet-driven agents.
- DRV-02 adapter unification (from Phase 2) still open.

**Exit:** FLOW-01/02 (core) ✅, FLOW-04 (council) ✅, FLOW-05 subsumed by the authority mode. The
guard is *used* (council). Only FLOW-03 (shipyard) remains, as a value-vs-dogfooding-risk decision.
