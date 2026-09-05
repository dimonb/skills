# PROJECT — Shared agent-harness core for shipyard and council

> GSD brownfield project. What we are **adding** to an existing repository, not a rebuild.
> Onboarded from the codebase map in `.planning/codebase/`.

## What we are adding

A single shared runtime that both `shipyard` and `council` sit on top of, so the two
skills stop each carrying their own copy of "launch an agent console, read its signals,
send it input, keep it supervised, tear it down." The runtime is three thin layers:

1. **Driver** — one backend-agnostic (agterm | tmux), agent-agnostic (claude | codex | agy)
   module that launches an agent console, reads a **normalized signal** from it, sends it
   input, and kills it. Agent-kind quirks live in per-agent adapters.
2. **Guard (flow)** — a small interpreter that drives an agent through a declared
   **graph of steps** (give goal → wait for a mechanical done-condition → collect artifact →
   transition). `shipyard`'s graph is one node; `council`'s is a turn-taking cycle.
3. **Policy (escalation)** — one table mapping each blocking signal to a disposition the
   guard applies: resolve autonomously (auto-approve a safe set, wait out a rate limit) or
   hand to the human via the escalation mailbox.

Underneath all three sits **process-lifetime plumbing** (own process group per run + an
inherited "canary" fd) so that when the owning guard dies for any reason, the whole agent
tree is reaped automatically — no orphaned supervisors reparented to launchd.

The move is deliberately **right-sized**: this is extraction and de-duplication of code that
already exists twice, plus two defect fixes drawn from a real incident — **not** a new
control-plane with its own database, socket protocol, or event-sourced state.

## Why (the two real pains)

- **A fleet run took the desktop down.** Running issues in parallel through `shipyard`
  drove a 16 GB machine to load 30–42 with < 2% free RAM; macOS recycled WindowServer, which
  tore down the whole GUI login session, and the supervisor then re-launched the fleet and
  fed the loop. Root cause: no admission cap and a storm-on-restart, not a bad kill line.
- **council races and orphaned supervisors.** council's coordination lives in POSIX shell
  across independent processes (barriers, pid files, `kill -0`), a class that keeps
  producing subtle bugs; and its keeper is a detached background subshell whose only death
  condition is "room directory removed," so an abandoned room leaves an immortal supervisor.

Both skills are, structurally, the same movement — background agents + a supervisor that
needs a live anchor — differing only in the flow graph. Unifying removes the duplication and
gives one place to fix lifetime, load, and escalation.

## Validated — existing capabilities detected in the codebase

Grounded in `.planning/codebase/`. These already exist and are **reused, not rebuilt**:

- **Terminal-backend abstraction, twice.** `council` in `plugins/council/skills/council/lib/term.sh`
  (`ct_launch` / `ct_type` / `ct_submit` / `ct_kill` / `ct_capture` / `ct_target`, agterm|tmux)
  and `shipyard` in `plugins/shipyard/skills/shipyard/shipyard-backend.sh` — the driver layer
  already exists in two divergent copies.
- **Per-agent adapters.** `plugins/council/skills/council/adapters/<kind>.sh` — the seam for
  claude/codex/agy specifics is already a pattern to lift.
- **A supervisor with a heartbeat/liveness model.** `shipyard-continuity.sh` (watch / start /
  terminate, heartbeat, lock/lease) — the guard's supervision half exists here.
- **A long-lived per-room keeper.** `plugins/council/skills/council/lib/up.sh` `_keeper_ensure`.
- **An escalation mailbox.** `.git/ship-escalations/` in the shared git dir, resolvable from
  every worktree — the destination for the policy layer's human hand-offs.
- **A repo gate.** `make check` / `make check-test` enforce structure, one-source-of-truth
  symlinks, and the generic-only rule; every change here must keep it green.

## Constraints discovered during onboarding

The codebase map (`.planning/codebase/CONCERNS.md`) surfaced four facts that reshape the plan:

- **Bash baseline mismatch (C5).** council requires bash ≥ 5 (`council.sh:26-38`); shipyard is
  written for 3.2 (`shipyard-continuity.sh:515-530`). The shared driver must pick one baseline
  (likely ≥ 5, re-exec'd) — a Phase-2 decision, not a detail.
- **No cross-plugin dependency in Codex (C1).** The backend is duplicated *because* a Codex
  plugin cannot import another's code. Sharing the driver needs a mechanism the Codex manifest
  cannot express — the central Phase-2 question (MIG-02).
- **Escalation asymmetry (C6).** shipyard has a human mailbox; council has none. Unifying the
  policy *adds* a mailbox path to council, it doesn't just rewire one.
- **Tests are outside the gate (C7).** Neither skill's `tests/run-all.sh` runs under
  `make check`. "Green tests" means invoking the runner per phase; prefer wiring it into the gate.

## Out of scope (explicitly)

- No database, no event-sourcing/snapshots, no socket protocol, no daemon control-plane.
- No new spec-artifact stage in the repo (AGENTS.md forbids it); this `.planning/` set is the
  planning surface, the change itself still ships as issue → branch → PR.
- No adoption of an external harness (Bernstein, majiayu000/harness, superharness). They stay
  reference architectures only.

## Success looks like

Both skills run on one driver and one policy; council's turn-taking is gated by a single
guard instead of per-reader barriers; a fleet run cannot exhaust the machine; and no
supervisor or agent survives the death of its owner. `make check` stays green throughout.
