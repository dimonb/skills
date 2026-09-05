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
  comment; under-probed check 11 arms). Model default switched to `claude-opus-4-8` (Fable was
  over-thinking and stalling; note: lost the `[1m]` 1M-context — Opus is 200k, autocompact covers it).
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
- **NOW: Phase 3 + Phase 4 in parallel (2-slot cap):** Phase 3 ESC policy = issue **#94** (slot 94);
  Phase 4 FLOW guard core = issue **#95** (slot 95). Both foundation pieces, independent. Expect
  design escalations (I answer internal-design ones).
- **Deferred:** DRV-02 adapter unification; FLOW-03/04/05 (migrate each skill onto the guard) are
  later issues after the guard core.
- **GSD record now COMPLETE and current.** Backfilled: `phases/01-stop-the-bleeding/`
  (CONTEXT + 01-01-SUMMARY + 01-VERIFICATION); `phases/02-driver/` per-task SUMMARY for 02-02..05
  + 02-VERIFICATION. Convention (both phase CONTEXTs): the **GitHub issue is the atomic plan**
  (AGENTS.md forbids a spec-artifact stage), a per-task SUMMARY records what shipped, VERIFICATION
  maps requirements → PRs. Loop per task: issue (plan) → ship execute+review → I verify → merge →
  SUMMARY. STATE is the live session-memory.
- **Deferred follow-up:** CI (GitHub Actions) — flagged during #84, its own decision for the
  soon-public repo; not yet raised to the user as an issue.
- **Remaining after Phase 1:** Phase 3 (ESC policy), Phase 4 (FLOW guard).
- **Lesson:** keep `.planning/` Latin-only — the gate's check 8 scans untracked files for non-Latin
  script; a quoted Russian phrase in STATE.md reddened local make check (fixed).
- **Pattern in use:** ship child (Opus) drives each issue → PR → its review battery →
  ready-to-merge; I verify (make check on head + child's report) and squash-merge per the
  ship-to-prod go-ahead; decisions I can own (internal design) I answer, relaying only
  user-impacting ones.
- **Autonomous decisions on record:** canonical in `shared/driver/`; bash baseline ≥5 re-exec;
  tests wired into the gate as behaviour lands; driver is a behaviour-preserving superset.
- **Repo law reminder:** every change keeps `make check` green; issue → branch → PR → human
  merges; no spec-artifact stage — this `.planning/` is planning only, untracked.
