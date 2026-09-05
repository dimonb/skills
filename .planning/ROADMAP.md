# ROADMAP — Shared agent-harness core

> Phase-based delivery. Sequenced by **risk and payback**: the two incident fixes ship first
> (they stand alone and remove the real pain), then extraction runs from lowest-risk
> de-duplication (driver) to the highest-cost generalisation (the flow guard).
>
> Status: **in progress** · 4 phases · 22 requirements mapped · all P0 covered.
> `GATE-01…04` apply to **every** phase and are not repeated per row.
>
> **Execution order note:** Phase **2** ran first (its sharing mechanism was the one unknown that
> could sink the unification — de-risked with a spike, then shipped). Then the user chose Phase
> **1**. So the timeline is 2 → 1; phase numbers are priority, not sequence.

### Task status (all execution via shipyard + ship, each ship-reviewed + independently verified)

**Phase 2 — Extract the driver — COMPLETE (in prod)**
| Task | Req | Issue → PR → merge | State |
|------|-----|--------------------|-------|
| 02-01 mechanism | MIG-02, DRV-04 | — → #77 → `6685ecd` | ✅ |
| 02-02 driver body | DRV-01/02/03 | #78 → #79 → `911d3db` | ✅ |
| 02-03 council migration | DRV-04, MIG-01 | #80 → #81 → `6fd1c08` | ✅ |
| 02-04 shipyard migration | DRV-04, MIG-01/03 | #82 → #83 → `05cf692` | ✅ |
| 02-05 suites in gate | GATE-01 (C7) | #84 → #85 → `c984d97` | ✅ |

**Phase 1 — Stop the bleeding — COMPLETE (in prod)**
| Task | Req | Issue → PR → merge | State |
|------|-----|--------------------|-------|
| 01-01 admission gate | LOAD-01/02/03 | #86 → #87 → `dd996eb` | ✅ |
| 01-02 keeper reaping (council) | LIFE-01/02/04 | #88 → #89 → `413193b` | ✅ |
| 01-03 watcher reaping (shipyard) | LIFE-03 | #90 → #93 → `ea6ed4c` | ✅ |

**Follow-up SHIPPED (ran parallel to 01-03):** CI (GitHub Actions) — issue #91 → PR **#92** →
`090ab52`. `.github/workflows/ci.yml` runs make check + check-test + test on push/PR (green Linux +
macOS). Getting the suites onto Linux caught + fixed **2 latent portability bugs** (shipyard
`ctx_mtime` BSD `stat -f`; council `t3-token` wall-clock wedge race → now turn-count deterministic).
Decision 91-3 (mine): Option A (fix them in-PR), bounded fallback to B — A worked, no rabbit hole.

**Phase 3 (ESC policy) and Phase 4 (FLOW guard)** — not started; a scope steer is due after Phase 1.

Deferred follow-ups tracked: CI (GitHub Actions, from #84), DRV-02 adapter unification, DRV-03 full
AgentSignal dispositions (→ Phase 3), shipyard-side LIFE-03.

## Phases

| # | Phase | Goal | Requirements |
|---|-------|------|--------------|
| 1 | Stop the bleeding | Make a fleet run un-crashable and kill the orphan-supervisor class — independent of any unification. | LOAD-01, LOAD-02, LOAD-03, LIFE-01, LIFE-02, LIFE-03, LIFE-04 |
| 2 | Extract the driver | One shared agent-console module (backend + adapters + normalized signal); both skills call it. Pure de-duplication. | DRV-01, DRV-02, DRV-03, DRV-04, MIG-01, MIG-02 |
| 3 | Extract escalation policy | One disposition table for blocking signals; both skills route through it; auto-approval is default-deny. | ESC-01, ESC-02, ESC-03, ESC-04 |
| 4 | Flow guard | A graph interpreter; express shipyard (one node) and council (turn cycle) as graphs and migrate onto it. | FLOW-01, FLOW-02, FLOW-03, FLOW-04, FLOW-05, MIG-03 |

## Phase notes

**Phase 1 — Stop the bleeding.** Highest payback, lowest architectural cost. Adds a
memory-aware admission cap and paced recovery to the existing fleet, and the canary /
process-group reaping to both the shipyard supervisor and the council keeper. Ships value
even if phases 2–4 never happen. This is the "off the starship" phase: small guards, not a
new runtime.

**Phase 2 — Extract the driver.** De-duplicates `council/lib/term.sh` and
`shipyard-backend.sh` into one module carrying the `AgentSignal` read. Low risk because
behaviour is preserved; the win is one place for backend, adapters, and signals. Decides and
records where shared code lives (MIG-02) — the one genuinely new structural question, given
the repo's per-plugin, one-source-of-truth layout.

**Phase 3 — Extract escalation policy.** Small and self-contained: lift the disposition table
out of both skills. Carries the two safety-critical requirements — default-deny
auto-approval (ESC-02) and trustworthy rate-limit timing (ESC-03).

**Phase 4 — Flow guard.** The largest and last, because it holds the real generalisation cost:
one interpreter that drives both a single agent to completion and N agents in gated turns.
Council's turn-taking moves off per-reader barriers into the guard, retiring the race class.
Done only after 1–3 have paid for themselves.

## Sequencing rationale

- Phases 1 is deliverable **without** committing to the unification at all — if the appetite
  for the rest fades, the machine is still safe and supervisors still reap cleanly.
- Each later phase is independently shippable behind its own tests (MIG-03); no big-bang.
- The order climbs the risk curve: dedup (2) → small shared policy (3) → the engine (4).
