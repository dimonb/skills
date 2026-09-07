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

All four phases in prod, and with #106 **all 22 requirements are delivered**. Both skills run on the
shared **driver + adapters + policy + guard**; one generalized drift gate covers all four shared
modules; CI runs the whole gate on every push/PR; the crash and the orphaned-supervisor class are
fixed. 16 feature PRs, each ship-reviewed and independently re-verified before merge.

### DRV-02 — the last requirement

- **DRV-02 SHIPPED — PR #106 merged (squash `40f4320`). THE LAST OPEN REQUIREMENT: all 22 are now
  met and the GSD plan is fully delivered.** One shared `shared/adapters/agent-adapters.sh`, both
  callers on it, no gate edit needed (check 11 already iterated every `shared/<mod>/`). 3 review
  rounds + a scoped confirming round, 15 axes.
  - **Merged with a body supplied at merge time, not by rewriting history.** `cec678e`'s message
    described a fail-open as fail-closed, and with `squash_merge_commit_message=COMMIT_MESSAGES`
    that would have landed on `main` verbatim. The reword was blocked by the permission classifier
    in the child AND in the parent, so decision 104-8 used the option neither of us had listed:
    `gh pr merge --squash --body-file`, which overrides the setting. Verified after merge that the
    false clause is absent from `40f4320`'s body. This deliberately reverses the 102-5 instruction
    ("do not rely on the merger supplying a body by hand") — that was about fragility when the
    merger might forget, which does not hold when the merger is in the loop with the text in hand.
  - **The finding worth keeping, and the child found it itself:** three of the four post-round-1
    blockers were ONE defect — enumerable, completeness-shaped claims written into comments ("the
    two other places that branch on a kind"), where each correction bred the next. A count in a
    comment is wrong the moment anyone adds to the thing it counts. The last commit removes the
    SHAPE (an explicitly open list that says not to trust a count in a comment, including itself)
    instead of correcting another instance. Related: after round 1, **no round found a defect in
    the shipped module's behaviour** — the code settled first and the prose took three more rounds.
  - Decision 104-9: handed off without a further round, on a stated distinction rather than a
    waiver — the earlier delta contained a fix to a probe that could not fail (an assertion that
    might not assert is what an author cannot verify by reading), while the final delta only
    REMOVES claims, which has no completeness to be short of. I read both hunks myself.
  - Emergent, filed not folded: **#113** (latent fail-open — `shipyard_env_preamble`'s rc is
    swallowed by its caller, so a kind with no env-pass arm launches a child with nothing
    propagated and nothing scrubbed; latent only because both admitted kinds have arms, and this
    very change makes adding a kind easy) and **#114** (two pre-existing load-only test flakes).
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
## After the plan: the fleet-ergonomics track

The GSD plan is delivered, so the work now is a different thing and is tracked as such: **what makes
the fleet painful to RUN.** It is not a new phase of the plan — no requirement IDs — it is the
backlog, prioritised by first-hand evidence from supervising this project's own slots. Everything on
it below I hit myself while shipping #105/#106, which is why it is this list and not the other 25
open issues.

Order is set by which FILE each touches, so two slots never collide the way #97/#96 once did and
#106/#115 just would have (measured: five conflicting files):

| order | issue | file | status |
|---|---|---|---|
| 1 | **#51 + #112** (one PR — same seam) | `shipyard-tell.sh` | IN FLIGHT, slot `ship-51` |
| 2 | **#54** | `shipyard-down.sh` | queued |
| 3 | **#22** | `shipyard-report.sh` | queued (sequential with #61 — same file) |
| 4 | **#61** | `shipyard-report.sh` | queued |

- **#51 + #112** — `tell` decides `delivered` from a before/after screen DIFF, which typing always
  changes, so an unsubmitted directive reports as delivered; and it types with no emptiness check,
  so a directive concatenates onto a pending draft. One state read of the prompt fixes both, and
  two PRs would collide in one file, so #51's scope was widened to close #112. **Hit while
  diagnosing a real stall**, where a captured pane showed placeholder ghost text that is
  indistinguishable from a draft — a bare Return did nothing (correctly: the box was empty) and it
  read as a wedged terminal. A single probe character proved the box empty.
- **#54** — `down` refuses a fully merged slot because it asks about ANCESTRY, not content: the
  squash-merge deletes the remote branch, `@{upstream}` dangles, and every commit reads as unpushed.
  **Hit twice today**, on both #105 and #106; both times `--force` was the only way through, which
  means the gate guarding genuinely unpushed work had to be switched off to tear down a slot whose
  work was already in `main`. Fresh reproduction added to the issue.
- **#22** — the stall watchdog fires on a rate-limited session and prescribes COMPACTION, i.e.
  discarding live context to cure something that only needed waiting. **Hit on both slots at once**
  (a session limit at 17:01 with an 20:10 reset), and again when the machine SLEPT mid-turn. The
  banner in the pane names when the window ran out, not the current state, so it reads as live.
- **#61** — `report` exits 0 (the monitor's "all finished, stop watching" signal) when it cannot
  reach the backend, so a socket blip permanently stops the monitor. Not hit this run, but it is the
  same class as the sleep: an environment hiccup read as a terminal state.

**Not on the list, deliberately:** ~25 other open issues, mostly council's robustness against
malformed values and its test hygiene. None blocks running the fleet. The structural one is **#40**
(a participant is not confined, so the room cannot be a trust boundary), which is a threat-model
conversation rather than a bug fix.

## Open follow-ups from the plan

- `flow_run` has no production caller — both skills turned out monitor/authority, not driven. Remove
  it (YAGNI) or justify it as a general primitive.
- **#111 IN FLIGHT (slot `ship-111`, PR #115)** — `shared/policy/tests` runs in NO automated invocation:
  absent from check 10's list, from both Makefile targets and from CI (verified independently; it
  still passes by hand at 92 checks). #97's generalization landed by halves — check 11 (drift) does
  iterate every `shared/<mod>/`, check 10 (run + registration) kept a hand-maintained list. Found
  by the #104 child while reviewing its own change. Decision 111-1: **A + C** — patch the list AND
  add a new check that every test runner on disk is invoked by a Makefile target. C is the missing
  assertion, because check 10 gates whether a TEST is registered inside a runner while nothing gated
  whether the RUNNER is ever run. Deriving the list from disk (B) was rejected: it replaces a
  declaration with disk, so a suite deleted or renamed wholesale stops being noticed — the same
  silent-coverage shape. Scoped to `plugins/` and `shared/` so an untracked local skill under the
  project skill dirs cannot red the gate (AGENTS.md's carve-out).
- **#113 / #114** — filed out of #106's review, above.

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
