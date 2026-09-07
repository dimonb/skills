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
  **STALE FIGURE — annotated at #104, not rewritten.** The ~3.7s above was true when written: the
  gate then ran ONE suite. The flow suite landed after it (2.4s) and check.sh itself grew to ~3.5s,
  so `make check` measures **~6.0-6.5s idle** (three warm runs on the main worktree) and 7.6-8.7s
  on a loaded machine. I keyed a speed rule for #104 to the 3.7s number and the child caught it by
  measuring instead of trusting it. **Lesson: a wall-clock figure in a prose log is a fact with an
  expiry date nothing enforces — never key a rule off a remembered one.** The rule is: measure
  before and after, report both WITH the load conditions, justify the delta.
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
- **DRV-02 adapter unification — IN FLIGHT as issue #104** (slot `ship-104`, PR **#106**, round 3).
  Decisions taken under delegation: 104-1 one canonical `shared/adapters/agent-adapters.sh` with
  per-kind `case` branches and `ADP_*` knobs (Options 2 and 3 rejected — the gate and
  `sync-driver.sh` both require EXACTLY ONE `*.sh` per module, so a file-per-kind module is
  impossible by contract, not by taste); the protocol mode is DERIVED per kind and exposed as a
  read-only query, never an input knob; `ADP_APPROVAL=sandboxed|full` with council pinned
  `sandboxed` and shipyard `full`, because this is the one place a behaviour-preserving refactor
  could silently move a security posture. 104-2 (the child's correction, accepted): "byte-identical
  rendering" was MY over-specification and is unsatisfiable once one module owns one quoting
  function — the real criterion is SAME ARGV, proven against fixtures captured from `main` BEFORE
  the renderers changed (a test that regenerates both sides proves nothing). Retiring the dynamic
  `source adapters/$kind.sh` also closes the plant-a-plausibly-named-file hole council had
  documented as measured-and-left-standing.
- **#111 IN FLIGHT (slot `ship-111`)** — `shared/policy/tests` runs in NO automated invocation:
  absent from check 10's list, from both Makefile targets and from CI (verified independently; it
  still passes by hand at 92 checks). #97's generalization landed by halves — check 11 (drift) does
  iterate every `shared/<mod>/`, check 10 (run + registration) kept a hand-maintained list. Found
  by the #104 child while reviewing its own change.
- **#112 filed (beside #51)** — `shipyard-tell.sh` types with no emptiness check, so a directive
  concatenates onto a child's unsubmitted draft; #51 is the same seam's false `delivered`. Both
  want the state read of the prompt that #51 prescribes.

**Stale-worktree cleanup — DONE, with a salvage.** `ship-3` was empty (its branch `feat/ci-gate`
long since superseded by the merged CI work) and was removed. `ship-41` was NOT dead: it held an
unpushed commit plus five files of uncommitted work. That WIP was committed verbatim and the branch
pushed to `origin/fix/council-suite-cleanup-enforced` before the worktree was removed, so nothing was
lost. Only `main` remains as a worktree. Two independent valuable pieces were identified there,
both verified still absent from `main`, and each filed as its own issue rather than cherry-picked
(the tree has moved under them — #89 rewrote the keeper loop):
- **#102 SHIPPED:** PR **#105** merged (squash `b02ba4f`). 3 review rounds + a verification pass,
  0 blocking findings open; `t19` at 43 checks with every mutation row measured against the merged
  tree. Three message-only history rewrites, each one an application of the rule set at 102-5
  (review branch, sole author, tree byte-identical, `--force-with-lease`), never a fresh decision.
  Two lessons worth keeping: a claim repeated in three places is ONE claim with three copies, and
  the first amend fixing only the flagged copy is what let the stale figures survive two rounds;
  and mutation testing via `git checkout origin/main -- <file>` leaves the pre-fix file STAGED, so
  an `--amend` there silently commits a revert of the fix (caught, not suffered). Four pre-existing
  defects found by its siblings sweep went to #107/#108/#109/#110, none folded into the diff.
- **#102 (as filed)** — a keeper whose room was rebuilt at the same path never
  steps down: it watches only `[ -d "$room" ]`, so the old keeper survives a `down`+`up` cycle as a
  leaked process holding open fifos. Fix: watch the pid file and step down only when it names
  ANOTHER positive pid — missing/empty/malformed is deliberately NOT a stop reason (t9g writes `0`).
- **#103 CLOSED as a duplicate of #41.** I filed it from the salvaged branch without checking the
  backlog, and #41 predates it, is richer, and even reserves the same `t12-*` number. What the
  salvage adds is now recorded on #41: the work is already IMPLEMENTED on that branch (a working
  `t12-cleanup.sh`, so this is porting, not writing), and #41's deferred-signal figure of "60s vs
  0s" is really **20s vs 0s** — the delay is the length of the foreground command, not a constant.
  **Process lesson: search the backlog before filing.** Two of the three issues I opened from the
  salvage duplicated existing ones (#103→#41), and a third had a pre-existing twin (#112 beside
  #51). A fleet supervisor filing from a child's findings sees the finding, not the backlog.

- **Repo law reminder:** every change keeps `make check` green; issue → branch → PR → human merges.
  `.planning/` is TRACKED (since `3853950`) and is the project-planning record, never a per-change
  spec gate — AGENTS.md "Planning with GSD, and no per-change spec artifact".
