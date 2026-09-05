# VERIFICATION — Phase 4: FLOW guard

**Core COMPLETE** (issue #95 → PR #97 → `4ba98ba`). Migrations (FLOW-03/04/05) are open, tracked.

| Req | Statement | Covered by | Status |
|-----|-----------|------------|--------|
| FLOW-01 | Declared step-graph the interpreter reads (no skill branch) | `flow.sh` `flow_node`/`flow_run`; node fields enter/done_when/on_done/on_block; t-flow | ✅ |
| FLOW-02 | Mechanical transitions only (no model in the loop) | fixed `done_when` vocabulary {signal,artifact,budget,check}; `check` is deterministic; STRUCTURAL, tested | ✅ |
| FLOW-03 | shipyard as a one-node graph | — | 🔲 open (later issue) |
| FLOW-04 | council as a turn-cycle graph | — | 🔲 open (later issue) |
| FLOW-05 | Multi-agent turn-taking | — | 🔲 open (later issue) |

## Also delivered (beyond FLOW-01/02)
- **C1 gate generalization**: one shared-module drift gate iterates every `shared/<mod>/`
  (driver/flow/policy) — verified on final main (each copy drift reds). Retires the duplicate check.
- **t10-continuity-canary** made robust under make-test/CI load (the flake #92's CI exposed).

## Open tails (tracked)
- FLOW-03/04/05 — express shipyard (one-node) and council (turn-cycle) as graphs and drive them on
  the interpreter; multi-agent turn-taking. These are the migration that makes the guard *used*;
  the core is behaviour-inert until then (nothing calls it yet).
- DRV-02 adapter unification (from Phase 2) still open.

**Exit (core):** FLOW-01/02 met; the interpreter is tested against a faked driver. The phase is not
fully closed until the migrations land — a scope steer is due on whether to do them now.
