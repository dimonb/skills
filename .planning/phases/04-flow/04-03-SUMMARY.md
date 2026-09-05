# SUMMARY — 04-03 · council on the flow guard (FLOW-04, SHIPPED)

**Requirement:** FLOW-04. **Plan:** issue **#98** (+ decision 98-1, answered Option C under
delegation). **Ship:** PR **#99** → merged `3e333ea`.

## Decision 98-1 (answered by me): Option C
The child's analysis surfaced the core tension: `flow_run` drives ONE agent and blocks on its
liveness, but council is decentralised/lock-free (N autonomous seats, turn admission is a pure
function of the shared log re-derived by every reader — that re-derivation IS the #74 barrier-race
class). Three shapes: A (room conductor runs flow_run — rejected: new mutable truth vs council's
lock-free design), B (per-seat flow_run drives each agent — rejected: that is FLOW-05's drive-N and
turns autonomous seats into puppets), **C (the declared graph is the single turn-admission
AUTHORITY the transport consults; barrier stays a pure log function; no drive loop)** — chosen.
Q2: yes, add a generic session-less predicate-eval entry point to the shared flow module.

## What shipped
- `shared/flow/flow.sh` gains **`flow_phase`** — a session-less AUTHORITY mode: evaluate a declared
  graph's mechanical predicates as the single authority, no agent bound. Generic (shipyard's
  FLOW-03 will use the other mode, `flow_run`). Synced to both vendored copies; generalized gate green.
- `plugins/council/skills/council/lib/room-graph.sh` — council's turn cycle as a declared graph.
- `lib/lib.sh`: scattered `[ "$(c_barrier)" = open ]` across readers → named predicates
  `c_round_open`/`c_round_closed`; `c_barrier` unchanged (pure log function), called as often as before.
- `tests/t18-flow-admission.sh` — pins the race class cannot recur.

## Verification (independently, on head and merged main)
- CI green on the PR (make check + check-test + test, 4m47s, Linux). `make check` green.
- **room-graph is load-bearing** (a review round-1 blocker was "graph declared but no production
  caller" — fixed): `flow_phase` is the authority mode, consulted.
- **t7 PASS** (barrier preserved) and **t18 PASS**: "the opening gate is one authority — overriding
  c_barrier moves the accessors and c_phase together" and "a wedged seat and a caught-up seat agree
  (the phase is the log's, not the reader's)" — the #74 class is retired structurally.

## Result
council's turn cycle is now one declared graph authority; the per-reader barrier-race class is gone,
behaviour preserved. The guard now serves BOTH modes — `flow_run` (drive one agent) and `flow_phase`
(authority) — which is the real two-skill unification.
