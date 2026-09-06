# STATE — session memory

- **Mode:** brownfield onboarding (GSD Core methodology, applied by hand — no GSD CLI installed).
- **Project:** shared agent-harness core for shipyard and council (`PROJECT.md`).
- **Where we are:** setup artifacts drafted — `PROJECT.md`, `REQUIREMENTS.md`, `ROADMAP.md`.
  Codebase map in `.planning/codebase/` grounded from a repo scan of both skills.
- **Requirements:** 22 mapped across 4 phases; all P0 covered (`ROADMAP.md`).
- **Spike done (branch `spike/shared-driver`, local, uncommitted):** MIG-02 / C1 is answered.
  One canonical `shared/driver/agent-driver.sh` is vendored into both plugins by
  `scripts/sync-driver.sh`; `check.sh` gained **check 11**, which reds on drift, a missing copy,
  a missing canonical, or an empty target list. All four arms verified manually; `make check`
  green. Two probes added to `check-test.sh` (runs once the spike is committed — its clean-tree
  guard blocks on untracked files). **Conclusion: the sharing mechanism works — Phases 2–4 are
  unblocked.**
- **02-01 SHIPPED TO PROD:** PR **#77 merged** to `main` (squash `6685ecd`) via shipyard/Opus.
  ship's impl-review found + fixed 2 real blockers (a rule-zero `.planning` leak in the driver
  comment; under-probed check 11 arms). Model default switched off Fable (it was over-thinking and
  stalling) to Opus; now `opus[1m]` (Opus 5, 1M). CORRECTION to an earlier note here: the switch did
  NOT cost the 1M window, and the recurring "ctx 92-99%" alarms were shipyard's ctx column inferring
  a 200k window for a young 1M session — the 92%->20% jumps were that inference resolving past 200k,
  not autocompact. `SHIPYARD_CTX_WINDOW=1000000` makes the column read true from the first turn.
- **02-02 SHIPPED:** PR **#79 merged** (squash `911d3db`) — real drv_* body (superset of both
  backends) + `shared/driver/tests/`. 0 blockers on review. On the #78 decision I confirmed the
  API myself (delegated): the child caught a spec error — both backends append `-ai` identically
  (not council-only); differences (repo-key `:`→`_`, pin location, override env) go to caller vars.
- **02-03 SHIPPED:** PR **#81 merged** (squash `6fd1c08`) — council `term.sh` delegates to drv_*,
  behaviour-preserving; council suite 21/21 + new t15 mapping test green on merged main. Review
  caught a stale SKILL.md doc, fixed.
- **02-04 SHIPPED:** PR **#83 merged** (squash `05cf692`) — shipyard backend delegates to drv_*;
  shipyard suite green incl. new t8-backend-adapter (24 checks); monitors verified working on the
  migrated backend. **Driver de-duplication COMPLETE — both skills run on one shared driver.**
- **GSD position — Phase 2 extraction DONE (in prod):** #77 mechanism, #79 body, #81 council,
  #83 shipyard. Four squash-merges to main, each ship-reviewed (Opus) + independently re-verified.
- **02-05 SHIPPED:** PR **#85 merged** (`c984d97`) — make check runs the driver suite + a
  registration check generalized to all 3 suites, stays fast (~3.7s); new `make test`;
  check-test 79/0. **PHASE 2 COMPLETE (all 5 tasks in prod: #77/#79/#81/#83/#85).**
- **LOAD SHIPPED:** PR **#87 merged** (`dd996eb`) — `shipyard-admission.sh` gate before launch:
  refuses when live slots at cap (`SHIPYARD_MAX_SLOTS`, default 2) or under macOS memory pressure
  (floor 10%), before any worktree/terminal. t9-admission (42 checks). Verified live: dry launch
  at 0/2 slots + 46% free = admitted. **The desktop-recycle crash is fixed.** Fleet safe to run 2.
- **LIFE SHIPPED / task 01-02:** PR **#89 merged** (`413193b`) — `council up --hold` + fifo canary;
  keeper reaps participant terminals on owner-EOF; no `$PPID`. Review caught 2 real blockers
  (tmux fd inheritance = the predicted footgun; canary-bootstrap fd-exhaustion hang), both fixed +
  regression-tested. t16 (26 checks) incl. the with/without-guard fd proof. **Phase 1 is
  council-complete (LOAD ✅ + LIFE ✅).** Note: the 5/6-axis "stall" was a session rate-limit
  (disguised), unblocked by a nudge after the reset.
- **PHASE 1 CLOSED / task 01-03:** PR **#93 merged** (`ea6ed4c`) — shipyard watcher opt-in canary +
  process group on the detached path, `$PPID`-free reaping (t10, 21 checks). Decision 90-1 (mine):
  shipyard has no long-lived owner, so the canary is opt-in; agterm-session path stays the
  production owner-death guarantee (honest docs). **Phase 1 done: LOAD #87 + LIFE council #89 +
  LIFE shipyard #93.**
- **CI SHIPPED:** PR **#92 merged** (`090ab52`) — `.github/workflows/ci.yml` runs the whole gate on
  push/PR (Linux + macOS). Caught + fixed 2 latent portability bugs (`ctx_mtime` `stat -f`,
  `t3-token` wall-clock race → turn-count). Decision 91-3 (mine): Option A, bounded — worked.
- **GSD adopted + tracked:** `.planning/` is now committed (`3853950`); AGENTS.md rewritten to
  reconcile GSD with the no-per-change-spec rule (plan-phase output = the issue) and `.planning/`
  added to the docs-only-to-main allowlist.
- **Phase 3 + Phase 4 core SHIPPED (ran parallel, 2-slot cap):**
  - Phase 3 ESC policy — #94 → PR **#96** → `f47f15a`. One shared `policy_dispose` table
    (default-deny, rate-limit-from-usage, council mailbox). Decision 94-1 coordination: no bespoke
    drift check, rely on #97's generalized gate.
  - Phase 4 FLOW guard core — #95 → PR **#97** → `4ba98ba`. Interpreter over a declared step-graph,
    fixed mechanical `done_when` vocabulary. Decision 95-1 (mine): A1+B1+C1 — incl. **generalize
    the shared-module drift gate** to iterate every `shared/<mod>/` (now covers driver+flow+policy).
    Also made t10 robust under load.
  - Merge order #97 → #96 (verified by a local trial-merge: 0 conflicts, generalized gate covers
    policy). Both children hit a shared account **rate-limit** mid-run (2 parallel Opus) — nudged
    back after reset; lesson: the cap guards memory, not API quota.
- **FLOW-04 SHIPPED (council on the guard):** #98 → PR **#99** → `3e333ea`. Decision 98-1 (mine):
  Option C — a session-less `flow_phase` AUTHORITY mode added to the shared guard; council's turn
  cycle is a declared graph, the barrier stays a pure log function consulted as one authority,
  the #74 race retired (t18: a wedged seat and a caught-up seat agree). The guard now serves both
  modes — `flow_run` (drive one agent) and `flow_phase` (authority). **The guard is now USED.**
- **FLOW-03 SHIPPED (shipyard on the guard):** #100 → PR **#101** → `e05b410`. Decision 100-1 (mine):
  Option B — `flow_phase` authority, not `flow_run` (rejected: parks idle children, blocks a
  non-blocking snapshot, wrong completion axis). report derives phase+glyph+terminal from the
  declared graph; dogfood check passed (the live monitors still work on the migrated shipyard).

## PROJECT COMPLETE

All four phases in prod. Both skills run on the shared **driver + policy + guard**; one generalized
drift gate covers all three shared modules; CI runs the whole gate on every push/PR; the crash and
the orphaned-supervisor class are fixed. 13 feature PRs, each ship-reviewed and independently
re-verified before merge.

**Open follow-ups (optional, none blocking):**
- `flow_run` has no production caller — both skills turned out monitor/authority, not driven. Remove
  it (YAGNI) or justify it as a general primitive.
- DRV-02 adapter unification.
- Two stale worktrees from the pre-cap incident still on disk: `ship-3` (feat/ci-gate), `ship-41`
  (fix/council-suite-cleanup-enforced).

- **Repo law reminder:** every change keeps `make check` green; issue → branch → PR → human merges.
  `.planning/` is TRACKED (since `3853950`) and is the project-planning record, never a per-change
  spec gate — AGENTS.md "Planning with GSD, and no per-change spec artifact".
