# Onboarding SUMMARY

GSD brownfield onboarding, applied by hand to this repo (no GSD CLI installed).

## Setup artifacts

- `PROJECT.md` — what we're adding (shared agent-harness core), Validated existing capabilities,
  constraints discovered.
- `REQUIREMENTS.md` — 22 requirements: DRV / FLOW / ESC / LIFE / LOAD / MIG / GATE.
- `ROADMAP.md` — 4 phases, sequenced by risk/payback.
- `codebase/` — grounded map: STACK, STRUCTURE, ARCHITECTURE, CONVENTIONS, TESTING,
  INTEGRATIONS, CONCERNS (every claim carries a `file:line`).
- `STATE.md`, `config.json` — session memory and settings.

## One-paragraph read

`shipyard` and `council` are the same movement — a supervisor driving agent consoles in
agterm|tmux — differing only in the flow they enforce (shipyard: one node; council: a turn
cycle). Their terminal-backend code is duplicated by necessity, their supervisors orphan in
different ways, and nothing caps fleet concurrency. The project extracts one **driver**, one
**escalation policy**, and one **flow guard**, and adds process-lifetime reaping and a fleet
admission cap. It is de-duplication plus two incident fixes — not a new control-plane.

## Next command in the GSD loop

`discuss-phase 1` → `plan-phase 1` → execute. Here that means opening the **Phase-1** issues
(fleet admission cap + memory gate + paced recovery; owner-canary reaping for the shipyard
watcher and the council keeper), each as issue → branch → PR under the repo's flow.

## Decisions still open (for Phase-2 CONTEXT)

- Shared-driver **bash baseline** (≥ 5 vs 3.2) — C5.
- **Where shared code lives** given no Codex cross-plugin dependency — C1 / MIG-02.
- Whether to **wire tests into `make check`** as part of the work — C7 / GATE-01.
