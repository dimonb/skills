# CONTEXT — Phase 1: Stop the bleeding

GSD discuss-phase. Decisions taken (user delegated design calls; user explicitly chose Phase 1
after Phase 2 completed). Requirements: LOAD-01/02/03, LIFE-01/02/03/04.

## Execution-order note

Phase 2 (Extract the driver) was executed **before** this phase, out of ROADMAP order, on purpose:
the sharing mechanism was the one unknown that could sink the whole unification, so it was
de-risked first (a spike, then #77). The user then chose Phase 1 ("fixes the crash") as the next
phase. This is recorded so the phase numbering does not read as the execution timeline.

## Plan convention (GSD in a no-spec repo)

AGENTS.md forbids a per-change spec-artifact stage; design lives in the issue and the PR. So GSD's
plan-phase output here **is the GitHub issue** — each task's atomic plan is its issue body, not a
separate PLAN.md. The per-task SUMMARY.md records what shipped (issue + PR + requirements).

## Implementation decisions

1. **Pragmatic, not a daemon.** Phase 1 is the "off the starship" fix: a pre-launch admission
   **gate** in the existing `shipyard-launch.sh` path, and a **canary** added to the existing
   council keeper — NOT a new scheduler/coordinator/state-store. The larger warden design stays a
   north-star (see PROJECT.md out-of-scope).

2. **LOAD — admission gate (task 01-01, issue #86 → PR #87, shipped).**
   - Concurrency cap: refuse when live `ship-*` slots ≥ `SHIPYARD_MAX_SLOTS`. Default **2**, sized
     for ~16 GB, env-overridable.
   - Memory gate: refuse under macOS **memory pressure** (floor 10% free, env-overridable), not raw
     free pages. Non-macOS degrades gracefully, never a hard failure.
   - The refusal must precede any worktree/terminal creation and be actionable.

3. **LIFE — keeper reaping (task 01-02, issue #88, in flight).**
   - Owner liveness via an **inherited canary fd** (owner holds the write end; keeper detects EOF
     with `read -t`), **never `$PPID`/`kill -0`** (a reparented process reads as alive).
   - `council up --hold` — a foreground owner mode binding a room's life to the launching session;
     the detached/persistent mode stays the default.
   - On owner-EOF the keeper reaps every participant terminal and exits; keeper in its own process
     group; keep the existing `_keeper_pid` `0`/empty guard and the room-directory teardown path.
   - **shipyard-side reaping is deferred** to a later issue (its continuity guard has its own
     lifecycle; touching it while shipyard is orchestrating this work is higher dogfooding risk).

## Open item

- macOS has no subreapers/`PR_SET_PDEATHSIG`, so orphans cannot be reaped after the fact — the
  canary/process-group approach PREVENTS the escape rather than cleaning up. This constraint is
  why LIFE binds to an owner fd rather than polling liveness.
