# SUMMARY — 04-01 · flow-guard interpreter core (SHIPPED)

**Requirements:** FLOW-01, FLOW-02 (+ the C1 gate generalization). **Plan:** issue **#95**
(+ decision 95-1, answered A1+B1+C1 under delegation). **Ship:** PR **#97** → merged `4ba98ba`.

## Decision 95-1 (answered by me): A1 + B1 + C1
- **A1** — graph is shell-declared (`flow_node`/`flow_run`, assoc arrays), mirroring the driver
  module; no parser.
- **B1** — `done_when` uses a FIXED vocabulary `{signal, artifact, budget, check}`; `check <cmd>`
  is the one general hatch (must be deterministic, model-free). This makes "no model in a
  transition" (FLOW-02) **structural**, not a convention.
- **C1** — generalize check 11 + sync so ONE shared-module drift gate iterates every `shared/<mod>/`
  (canonical = the lone `*.sh`, `targets.txt` lists copies, fail-closed) — retiring the
  "a copied check rots" duplication before a third shared module (policy) arrives.

## What shipped
- `shared/flow/flow.sh` (251 lines, vendored) — the interpreter over a declared step-graph:
  node fields `enter`/`done_when`/`on_done` (`goto:`/`close`/`emit:`)/`on_block` (→ policy). A
  default-deny `policy_dispose` stub seams to Phase 3 (real table drops in behind the same name).
- Generalized `scripts/check.sh` (check 11 → "shared module copy drifted from shared/<mod>/…"),
  `scripts/sync-driver.sh`, and `check-test.sh` probes.
- `shared/flow/tests/t-flow.sh` (264 lines) + an example graph. Also **made t10-continuity-canary
  robust under make-test load** (the flake CI exposed) and hardened interpreter error paths
  (empty `goto` errors instead of a false clean-close; non-numeric `FLOW_MAX_POLLS` fails closed).

## Scope
Interpreter core only. Migrating shipyard (one-node) and council (turn-cycle) onto it, and
multi-agent turn-taking, are FLOW-03/04/05 — separate later issues. Nothing calls the interpreter yet.

## Verification
- ship review: 5 axes + 2 sweep axes (the gate generalization), 0 confirmed blocking; check-test
  84/0; make test green. Independently: `make check` green on the head and on final main, and the
  generalized gate catches driver + flow + policy copy drift.

## Result
The flow guard exists as a shared, tested interpreter with mechanical transitions, and the
shared-module gate is now DRY across all three modules. Phase 4 CORE done; the migrations remain.
