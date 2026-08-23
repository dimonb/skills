---
name: ship
description: "Drive one change end-to-end through a repo's pipeline — issue, spec, implementation, its own review passes, hand-off or merge — on GitHub or GitLab, in one session, unattended. Self-driven: every review pass runs as read-only subagents with adversarial verification of each finding, and nothing ever waits on an external reviewer. Repo coordinates, default branch, check commands, spec engine and merge policy are discovered from the repo, never hardcoded."
---

# ship — drive one change to a merge-ready PR/MR

`ship` takes one piece of work from an idea (or a half-done PR/MR) to a **merge-ready**
change, in one session, unattended. It is **self-driven**: it runs its review passes
**itself, as subagents**, applies what survives verification, and then either hands over or
merges according to the repo's policy.

Three rules define its character.

1. **All review happens in subagents — never in ship's own context.** ship orchestrates,
   applies fixes, and talks to the forge. It does not read the diff *in order to review it*.
   A reviewer that shares the author's context inherits the author's blind spots, and its
   context is polluted by the work it just produced; an independent agent starting from the
   diff alone is not. (ship reads code constantly while implementing — the ban is on
   reviewing in-context.)
2. **Nothing external ever clears a stage.** There is no reviewer skill, no approval gate,
   no stage that waits for a second actor. A stage clears when a review round comes back
   with no blocking findings, inside a declared round budget.
3. **Nothing about the project is hardcoded.** Forge, host, repo path, default branch,
   branch naming, check commands, spec engine and merge policy are all *discovered* (§2). A
   fact that cannot be discovered is asked about or escalated — never guessed, and never
   defaulted to a value copied from some other project.

Two files sit beside this one. Read **exactly one** of them, chosen by the forge you
detect in §2.1:

| Forge | Reference file |
|---|---|
| GitHub | `references/forge-github.md` |
| GitLab | `references/forge-gitlab.md` |

Every forge CLI invocation in this skill lives there. The core never names `gh` or `glab`.

---

## 0. `--help` / synopsis (handle FIRST, before anything else)

**If the argument is `--help`, `-h`, or `help`: print the block below verbatim and STOP. Do
not touch git, the forge CLI, or any state file.**

```
ship — drive one change through this repo's pipeline to a merge-ready PR/MR.
Self-driven: runs its own spec + code + security review passes as read-only subagents,
adversarially verifies every finding, and never waits for an external reviewer.
Works on GitHub and GitLab; discovers the repo's own conventions rather than assuming any.

USAGE
  ship "<free-text description>"   Start a new change from an idea (asks to confirm).
  ship #N                          Start from / continue existing issue N.
  ship pr N | ship !N | ship mr N  Continue an existing PR/MR by number.
  ship <url>                       Same, resolved from an issue/PR/MR URL.
  ship                             Resolve from the current branch/worktree.
  ship --help                      Show this help.

FLAGS
  merge | no-merge   Override the repo's merge policy for this run. `merge` IS the user's
                     go-ahead — pass it only when the user said so in this invocation.
  no-create          Never create an issue; abort if none is found.
  effort <level>     Review depth: low|medium|high|xhigh|max (default: max).
  max-rounds <n>     Fix rounds per review stage before escalating (default: 3).
  soft-bounds        On hitting max_iterations/deadline, nudge once and keep going
                     instead of stopping. Default is a HARD stop.

PIPELINE (one branch + one PR/MR per change)
  need-issue -> issue-ready -> spec-review -> apply -> impl-review
             -> archive -> ready-to-merge -> done
                                          -> needs-human   (blockers survived the budget)

  `spec-review` and `archive` are SKIPPED in a repo that keeps no spec artifact
  (§2.5). Stage labels on the PR/MR are decoration for the board, never a handshake.

BEHAVIOR
  - Reviews itself: a fresh-context battery reviews the spec before any code is written,
    and correctness/security/conformance/conventions/gates axes review the branch diff
    before hand-off. Every blocking finding faces a skeptic that tries to refute it.
  - A review stage whose blocking findings survive max-rounds STOPS the run, converts the
    PR/MR to draft, and reports. That budget is the only thing standing in for a human
    reviewer — honor it.
  - Merges only where repo policy or the `merge` flag allows it. A clean self-review is
    never a merge authorization by itself, and ship never self-approves.
  - All human prompts happen at invocation time; scheduled re-wakes run unattended.
  - Idempotent + re-entrant: safe to re-run; state in .pipeline-state/.
```

---

## 1. When to use / input forms

Use when the user wants to push one piece of work forward — from nothing, from an issue, or
from a half-done PR/MR. Accepted inputs (resolved in §3):

- **Free text** (`ship "add a typing indicator"`) — no issue yet → §7.A.
- **Issue**: `#N` or an issue URL → §3.2.
- **PR/MR**: `pr N`, `mr N`, `!N`, or a PR/MR URL → §3.3.
- **No argument** → resolve from the current branch/worktree (§3.4).

`#N` is always an **issue**; `pr N` / `mr N` / `!N` is always a **PR/MR**. A **bare number
is ambiguous** — do not guess, ask which one is meant. (A caller that knows the answer
should pass the marker; the launcher skill `shipyard` preserves it for exactly this reason.)

Optional flags: `merge`, `no-merge`, `no-create`, `effort <level>`, `max-rounds <n>`,
`soft-bounds`.

---

## 2. Discovery — learn the repo before touching it

Run this ONCE per run, before anything else, and write every answer into the state file
(§4) so a scheduled re-wake does not have to re-derive it. **Shell environment does not
persist between tool calls**, so the forge env guard from the reference file must be
re-applied in *every* block that calls the forge CLI.

### 2.1 Forge, host and repo coordinates

```bash
git remote get-url origin
```

Classify the host: a `github.com` or GitHub-Enterprise host ⇒ **GitHub**; a `gitlab.com` or
self-hosted GitLab host ⇒ **GitLab**. Anything else ⇒ STOP and ask; do not improvise a
third forge. Then **read the matching reference file** and follow its Identity section to
resolve `$ME` (the account the forge CLI is currently authenticated as) and to confirm that
account can write to this repo. If `$ME` is empty or has no access, STOP and ask the user to
point the CLI at an account that does — never hard-code a login, and never proceed with a
broken identity.

Extract the project coordinates from the remote URL (owner/repo for GitHub, the full
namespace path or numeric id for GitLab) and record them. Every later call passes them
explicitly rather than relying on the CLI's cwd inference.

### 2.2 Default / target branch

```bash
git symbolic-ref --quiet refs/remotes/origin/HEAD    # e.g. refs/remotes/origin/main
git remote show origin | sed -n 's/.*HEAD branch: //p'
```

Fall back to the forge API's default-branch field (reference file). Record it. **Never
assume `main`** — plenty of repos are on `master`, `develop` or `trunk`, and branching from
the wrong base makes a diff that carries other people's merged work.

### 2.3 Branch naming convention

Read `AGENTS.md`, then `CLAUDE.md`, then `CONTRIBUTING.md` for a stated convention. Absent
one, look at what the repo actually does:

```bash
git for-each-ref --format='%(refname:short)' --sort=-committerdate refs/remotes/origin | head -30
```

Absent both, use Conventional-Commit prefixes (`feat/`, `fix/`, `docs/`, `chore/`,
`refactor/`, `test/`). Record the chosen shape.

### 2.4 Check and test commands

The commands that must be green before every commit. Discover, in order:

1. An explicit statement in `AGENTS.md` / `CLAUDE.md` ("run X before every commit").
2. A `Makefile` — `make -qp | awk -F: '/^[a-zA-Z0-9_-]+:/{print $1}' | sort -u`, then prefer
   targets named `check`, `lint`, `test`, `verify`, `ci`.
3. `package.json` scripts, `pyproject.toml`, `Cargo.toml`, `go.mod`, etc.

Record the exact command line. Two rules that have each cost a silent green:

- **A command that exits 0 having run nothing is worse than a failure.** After the first
  invocation, look at the output and confirm it actually did the work — a filter or glob
  that matched nothing typically exits 0. If a runner takes a selector, verify the selector
  matched.
- **Docs-only changes may be exempt** from the check trio where the repo says so. Take the
  exemption from the repo's own text, not from the shape of the diff.

### 2.5 Spec engine — detected, never required

Does this repo keep a **spec artifact** per change?

- A spec tool's tree plus its CLI on PATH (for example an `openspec/` directory and the
  `openspec` binary) ⇒ **spec-engine repo**. The `spec` stage produces that tool's
  artifacts through its own skills, and the `archive` stage runs.
- A stated design-doc convention in `AGENTS.md` (a directory of design docs, one per
  change) ⇒ **design-doc repo**. The `spec` stage writes that doc on the branch; there is no
  archive stage.
- Neither ⇒ **no-spec repo**. `spec`, `spec-review` and `archive` are skipped entirely and
  the pipeline runs `issue-ready → apply → impl-review → ready-to-merge`.

Record which. **Do not install a spec tool, do not initialise one, and do not invent a spec
artifact a repo has not asked for.** The property worth protecting is that a design gets an
independent adversarial review while changing course is still cheap — where the repo keeps
no design artifact, that review moves entirely to `impl-review` and the scope axis there
carries it.

Where a spec engine IS present, always delegate to its own skills rather than hand-rolling
its artifacts, slugs or archive move. For `openspec` that is `/opsx:*` (equivalently
`/openspec-*`): `explore` to think a fuzzy idea through, `propose` for a one-shot proposal
(or `new` + `continue` to step through, or `ff` to fast-forward), `apply` to work the task
list, `verify` to catch drift before archiving, `archive` to sync and move. Never create a
slug or perform the archive move by editing files.

### 2.6 Merge policy

Whether ship may merge its own work. First match wins:

1. The `merge` / `no-merge` flag passed in **this invocation**.
2. The repo's own stated policy — `AGENTS.md` / `CONTRIBUTING.md`. "Do not self-merge
   without the user's go-ahead" means `no-merge`; a repo that explicitly delegates merging
   to the pipeline means `merge`.
3. **Default: `no-merge`.** Stop at `ready-to-merge` and hand over.

Record it in `flags.merge`. A run may only ever READ that flag — **nothing in the pipeline
sets it.** It records a go-ahead the user gave at the start of the run, not one inferred at
the moment of merging, and a clean self-review is never a substitute for it.

### 2.7 Repo law

Read `AGENTS.md` (and `CLAUDE.md`) in full and treat it as binding for the rest of the run:
commit granularity and message style, protected branches, assignment discipline, working
language, attribution rules, anything about labels. Where this skill and the repo's law
disagree, **the repo's law wins** — say so and follow it.

---

## 3. Resolve the entry point & detect current state

### 3.1 Classify the argument

1. `--help`/`-h`/`help` → §0.
2. `#N` / issue URL → issue path (§3.2).
3. `pr N` / `mr N` / `!N` / PR-MR URL → PR/MR path (§3.3).
4. Free text → `need-issue` (§7.A); the text is the description.
5. No argument → current branch (§3.4).
6. Bare number → ambiguous; ask. Do not guess.

### 3.2 Issue path — does a PR/MR or branch already exist?

Use the reference file's "linked PRs/MRs for an issue" queries — on both forges, take the
**union** of the structured link query and a body/description text search, de-duped by
number. One query alone misses links the other finds.

- An **open PR/MR targeting the default branch** already linked → switch to §3.3. Never open
  a duplicate.
- A **branch** exists but no PR/MR → check it out and continue from whatever stage its tree
  implies.
- **Nothing** linked → `issue-ready` (§7.B).

Assignment: if the issue is unassigned or already ours, claim it before any local work. If
it is assigned to **someone else**, STOP and clarify — do not take over another person's
work.

### 3.3 PR/MR path — read detail and detect the stage

Read the PR/MR through the reference file's detail query, capturing at least: state, draft
flag, source and target branch, author, head sha, labels, mergeability, and check/pipeline
status.

- Not open (merged/closed) → report and stop; do not resurrect. If a state file exists, this
  is the loop's terminal state: stop the watch, set `state=done`, schedule nothing more.
- Author is not `$ME` → this PR/MR belongs to someone else. `ship` drives **our own** work;
  if asked to advance somebody else's, clarify first.
- Otherwise claim the assignee (idempotent) so the board shows who is shipping it.

**Stage detection.** Where the repo has a spec engine or design-doc convention, the spec
artifact lives at a known path (the spec tool's tree, or the design-doc directory) and
implementation lives elsewhere:

```bash
# <artifact-prefix> = the spec artifact directory discovered in §2.5
NONSPEC=$(printf '%s\n' "$PATHS" | grep -v "^<artifact-prefix>/" || true)
if   [ -z "$PATHS" ];   then STAGE=unknown
elif [ -n "$NONSPEC" ]; then STAGE=implementation
else                         STAGE=spec; fi
```

Avoid `grep -qv` for this test — a SIGPIPE race can misreport it. Capture the non-artifact
lines and test for emptiness, as above. In a no-spec repo every non-empty diff is
`implementation`. An unknown/empty diff ⇒ ask; never guess.

Map to a driver state using the **review ledger** (§5.10) — a stage is cleared by *our own*
clean round, never by anything external:

| Detected | Driver state |
|---|---|
| spec diff, no clean spec round recorded | `spec-review` |
| spec diff, clean spec round recorded and the artifacts unchanged since | `apply` |
| implementation diff, code landed after the last clean impl round | `impl-review` |
| implementation diff, clean impl round, archive due and not in the diff | `archive` |
| implementation diff, clean impl round, archive in the diff or not applicable | `ready-to-merge` |
| any stage, blockers survived `max-rounds` | `needs-human` |

**What invalidates a round is unreviewed CODE landing after it, not the head moving.** The
archive commit (§7.F) moves the head by design and is exempt; so is a pure fix push, which
earns a *scoped* re-review rather than a fresh battery (§5.10). Comparing the recorded head
to the current one directly would loop `impl-review → archive → impl-review` until the
iteration bound, because the archive always pushes after the impl round stamps its head.

Reviews are cheap and idempotent, so **when genuinely in doubt, re-run the review rather
than assume it happened.** A re-run of a clean stage confirms and advances; a wrongly
skipped one ships unreviewed work.

### 3.4 Current-branch resolution (no argument)

Ask the forge for an open PR/MR whose source branch is the current one.

- One open → §3.3.
- None, but a spec artifact for an unopened change exists in the tree → a local proposal
  that was never pushed → resume at the push-and-open tail of §7.B.
- Nothing → ask what to ship.

---

## 4. State file

Path: `.pipeline-state/<KEY>.json`, git-ignored (add `.pipeline-state/` to `.gitignore` if
missing). `<KEY>` is `ISSUE-<n>` when an issue is known, else `PR-<n>` / `MR-<n>`, else
`CHANGE-<slug>` before anything is opened; migrate the file when the better key appears.

**Re-entrancy:** if `phase == "working"` and it started less than 10 minutes ago, another
run is in flight — exit.

```json
{
  "issue": 42,
  "pr_number": 11,
  "me": "<login of the authenticated account>",
  "forge": "github|gitlab",
  "repo": "<owner/repo or namespace/path>",
  "project_id": "<numeric id, GitLab>",
  "base_branch": "<discovered default branch>",
  "branch": "feat/add-typing-indicator",
  "change_slug": "add-typing-indicator",
  "spec_engine": "openspec|design-doc|none",
  "spec_artifact_prefix": "openspec/changes|docs/design|null",
  "check_cmd": "make check",
  "state": "need-issue|issue-ready|spec-review|apply|impl-review|archive|ready-to-merge|needs-human|done",
  "phase": "working|waiting|done",
  "phase_started_at": "2026-08-23T10:00:00Z",
  "last_head_sha": "819f7d74...",
  "iteration": 1,
  "max_iterations": 200,
  "deadline": "2026-08-24T10:00:00Z",
  "bound_nudge_sent": false,
  "monitor_task_id": "...",
  "next_wakeup_id": "ship-42-tick",
  "flags": { "merge": false, "no_create": false, "effort": "max", "max_rounds": 3, "soft_bounds": false },

  "reviews": {
    "spec": {
      "head": "819f7d74...", "rounds": 1, "clean": true, "mode": "delta",
      "axes": ["spec-completeness", "spec-architecture", "spec-security", "spec-scope-fit"],
      "candidates": 7, "confirmed": 3, "fixed": 3, "optional": 4,
      "open": []
    },
    "impl": {
      "head": "a1b2c3d4...", "rounds": 2, "clean": false, "mode": "delta+sweep",
      "security_engine": "ran|unavailable", "security_engine_reason": "…",
      "open": [
        { "id": "impl-2", "fp": "sha256(...)", "file": "lib/foo.ts", "line": 42,
          "severity": "blocking", "category": "correctness", "origin": "original",
          "summary": "…", "failure_scenario": "…",
          "status": "open|fixed|withdrawn", "note": "why it is still open" }
      ]
    }
  },
  "swept": [ { "trigger": 1, "sha": "819f7d74...", "note": "drops a column that encoded authorization" } ],
  "external_threads_grace": { "since": "2026-08-23T10:30:00Z", "thread_ids": ["abc"] }
}
```

`reviews` is the **gate ledger**: only a `clean` entry, un-invalidated per §3.3/§5.10,
clears a stage. `iteration` / `deadline` are enforced FIRST on every wake (§6).

---

## 5. The review engine (subagents only)

This is the heart of the skill and the thing that replaces an external reviewer. It runs on
the spec (§7.C, where a spec stage exists) and on the implementation (§7.E), plus a scoped
pass on the archived head (§7.F).

### 5.1 Principles (honor verbatim)

- **Subagents review; ship never reviews in its own context.** One independent agent per
  axis. ship writes the charters, dedupes, verifies, fixes, and posts.
- **Review subagents are strictly READ-ONLY.** End every charter with: *do not edit files,
  do not run git write commands, do not touch the forge CLI, do not install anything, do not
  check out another ref — return findings only.* Parallel writers in one worktree corrupt
  each other; ship applies every fix itself, sequentially.
- **Run the axes concurrently** — dispatch the whole battery in ONE message so they run in
  parallel. They are read-only over the same tree and cannot conflict.
- **Barrier before acting.** Do not start fixing until every axis of the round has returned.
  Otherwise dedupe is impossible and ship edits code a still-running axis is reading.
- **A finding is not a fact until it is verified** (§5.5). Unverified findings cause churn:
  ship "fixes" a non-bug, the diff grows, and the next round reviews the noise.
- **Every confirmed blocker is either fixed or escalated.** Never merged over, never
  silently downgraded.

**Runtime binding.** Name the capability abstractly; bind it to whatever the host exposes.

| Capability | Claude Code | Generic fallback |
|---|---|---|
| review subagent | the agent tool, general-purpose type; several calls in one message ⇒ concurrent | any independent-context agent primitive |
| deep engines inside an axis | `/code-review <effort>`, `/security-review`, invoked **inside** the axis subagent | the axis charter alone |

The bundled `/code-review` and `/security-review` skills are **analysis engines** and belong
**inside** the corresponding axis subagent, never in ship's main context. **Never pass
`--comment` or `--fix`** — they post to the forge and append an attribution footer. If an
engine result cites a URL from the wrong forge, rewrite it before it goes anywhere.

### 5.2 Spec-stage battery (4 axes, parallel)

Only where a spec stage exists (§2.5). Context every axis gets: the change slug, the
artifact paths, the branch diff against the base branch, the originating issue, and the
**current** spec the change modifies. Give the reviewer the paths, not your summary of them
— a summary is the thing being reviewed.

| Axis | Charter |
|---|---|
| `spec-completeness` | Does every requirement in the proposal have a matching spec delta with testable scenarios, and vice versa? Is the task list covering every requirement, with no orphan task and no task no requirement justifies? Are the acceptance scenarios *observable behaviour* rather than intentions? Does the spec tool's own validator pass strictly? Format rules exactly as the tool states them (slug shape, heading depth). |
| `spec-architecture` | Is the design sound **against this codebase**? Does it fit the existing module boundaries, or duplicate/contradict a capability already specified? Is there a materially simpler approach? Rollout, migration and back-compat risk; failure modes; blast radius. Name the strongest alternative and why it loses. |
| `spec-security` | Threat-model the **design**, before code exists — a diff-based engine is near-useless here, so reason from the proposal: authN/authZ changes, tenant isolation, secrets and personal-data flow, new external surface and its input trust boundary, rate and abuse limits, audit trail, supply-chain cost of any proposed dependency. Flag anything the spec leaves implicit that code will therefore get wrong. |
| `spec-scope-fit` | Repo conventions and scope: the repo's law, working language, naming rules, and any convention the change touches. Scope creep against the originating issue **in both directions** — bloat, and requirements quietly dropped. **No premature implementation code**: does the branch already carry code it should not have at the spec stage? |

Also brief every spec axis to hunt three specific things: **deltas that contradict the
requirement they modify**; **requirements the change makes moot but leaves standing** (a rule
about a path that no longer exists rots silently); and **concurrency, ordering and
partial-failure cases the proposal states no behaviour for** — historically the most
productive question to ask any spec.

**End every charter — spec and implementation alike — with the anti-noise clause:** *return
an EMPTY array if the change is clean on your axis, and say so. Inventing a nitpick to look
diligent is a failure, not thoroughness.* The §5.4 normalization rules stop an invented
finding from *gating*, but not from being raised, verified and acted on, and that churn is
what the round budget is paying for.

### 5.3 Implementation-stage battery (5 axes, parallel)

Context every axis gets: the diff against the base branch, the spec artifacts if any, the
PR/MR title and description, the effort level, and the findings already confirmed in earlier
rounds so it does not re-report them.

| Axis | Charter |
|---|---|
| `impl-correctness` | The diff-scoped bug hunt: logic errors, off-by-one, null/undefined, async races, error paths, resource leaks, regressions in touched code. May invoke **`/code-review <effort>`** inside itself and fold its findings in. Every blocking claim needs a concrete failure scenario. |
| `impl-security` | **Attempts `/security-review` inside itself and reports whether it actually ran** (see below), then covers the surface regardless: authorization on every new route and query, tenant/owner scoping, secrets in code, config, CI or logs, injection (SQL, command, template, prompt), SSRF and caller-supplied URLs, unsafe deserialization, new dependencies, data exposed to a client that should not see it. For an infrastructure diff also network exposure, policy gaps, role scope, and secret delivery. Plus the three shapes below, which have each shipped for real. |

Three defects that have actually reached a default branch, and are therefore named in the
`impl-security` charter explicitly rather than left to the reviewer's imagination:

- **A guard test that passes because the fake makes its own assertion true.** The test runs,
  goes green, and proves nothing. Distinct from a runner that selects nothing (§2.4): here the
  test genuinely executed.
- **A green check that proves nothing because the mutation was never applied to the CALL
  SITE.** The definition changed, the caller did not, and the check exercised the definition.
- **A secret, token, credential or session file about to be committed.** This one is
  **always blocking** — an explicit exception to every normalization rule in §5.4: it is
  blocking with no failure scenario, at any confidence, and it may not be downgraded to
  optional. Nothing else in this skill is unconditional.
| `impl-spec-conformance` | Code against the spec artifacts, **both directions**: every requirement satisfied by the code; no shipped behaviour no requirement describes; no unchecked task whose work is genuinely absent. In a no-spec repo this axis becomes *code against the issue*: does the change do what was asked, no more and no less? |
| `impl-conventions` | The repo's own conventions as discovered in §2.7 — style, structure, localization parity, formatting of user-facing text, dead or debug code, stray markers, commented-out blocks, and **no AI/assistant attribution anywhere in the diff**. |
| `impl-gates-coverage` | What actually runs in CI versus what changed — is any part of this change unverified by construction? Does every component with a test entry point appear in the pipeline that should run it? Does the change need manual or browser verification? Are the discovered check commands sufficient evidence for *this* diff, and did they actually run green on *this* head? |

**The security engine may be unable to start, and that must be visible.** Both source
lineages of this skill record the same failure: `/security-review` derives its target from
the working directory and dies when the session is rooted above the repository, and it can
also die resolving a shell interpolation before its body loads. Neither is correctable from
inside a session. So the axis charter ends with: *"Report `security_engine: ran|unavailable`
with a one-line reason as the first line of your report. If it is `unavailable`, cover the
whole security surface above yourself — the axis still has to happen."* ship records that
value per round in the ledger and it decides the note's shape (§5.9). The measured failure
this closes: one change where the engine died on its first invocation and **84 subsequent
rounds carried no security analysis at all, with nothing anywhere saying so.**

**`security_engine` is re-established from each round's axis report and NEVER inherited.** An
engine can become available between rounds, or stop being — and a stale `unavailable` carried
forward keeps a working engine switched off for the rest of the change, which is the same
silence this clause exists to close.

### 5.4 Finding contract and normalization

Instruct every axis to emit a single JSON array as the last thing in its report:

```json
[
  {
    "axis": "impl-security",
    "severity": "blocking|optional",
    "category": "correctness|security|spec-drift|convention|operability|coverage",
    "file": "path/to/file",
    "line": 42,
    "summary": "one sentence stating the defect",
    "failure_scenario": "concrete inputs/state -> wrong output/crash (REQUIRED when blocking)",
    "suggested_fix": "one or two sentences",
    "confidence": 0
  }
]
```

Normalization ship applies on receipt — deterministic, no judgement needed:

- **`blocking` without a concrete `failure_scenario` ⇒ downgraded to `optional`.** "This
  looks risky" is not a defect.
- **A `failure_scenario` whose trigger is a hypothetical FUTURE edit ⇒ `optional`.** The
  scenario must fail against something that exists: the current head, a documented rollout
  step, or a failure this repo has actually had. *"If someone later writes it this other
  way"*, *"a copy-pasted flag would pass this check"* are latent, not live — and
  demonstrating one reproducibly does not promote it, because what was reproduced is a file
  that does not exist. On one measured change, 22 of 66 findings in a single category were
  exactly this shape; each cost a fix, and each fix added lines the next round then reviewed.
- `confidence < 60` ⇒ `optional`.
- **blocking** = a real defect that must be fixed before hand-off: correctness bug, security
  issue, data loss, broken contract, behaviour-changing spec drift, a gate that would fail —
  failing *live*, per the clause above.
- **optional** = advisory: nitpick, style, naming, "consider…", micro-perf, refactor idea,
  low-confidence note. Optional findings NEVER gate anything and are never fixed under time
  pressure — batch and post them (§5.9).
- **Dedupe across axes** by `(file, line ±3, category)` and by summary similarity. Two axes
  finding one defect is one finding: keep the better failure scenario, union the axes.
  Dedupe is ship's own bookkeeping, not review — doing it in ship's context is fine.
- **Fingerprint** each survivor as `sha256(file|line|category|normalized-summary)` and carry
  it in the ledger, so later rounds and later wakes recognise it.

### 5.5 Adversarial verification (a skeptic per blocking finding)

Every **blocking** candidate goes to a fresh verifier subagent whose job is to **refute** it.
Optional findings are not verified — they are never acted on anyway.

Verifier charter: *"Here is a claimed defect: `<finding>`. Read the actual code at that
location and its callers. Try to refute it. Construct the concrete failure path — specific
inputs or state producing the specific wrong result. If you cannot construct one (the guard
exists elsewhere, the input is impossible, the caller already handles it, the code path is
dead), the verdict is REFUTED. Read-only: do not edit anything."*

```json
{ "fp": "…", "verdict": "CONFIRMED|REFUTED", "reason": "one sentence",
  "corrected_severity": "blocking|optional", "corrected_fix": "…" }
```

- One verifier per finding, all dispatched in ONE message. Above ~8 candidates, batch about
  4 findings per verifier to keep the fan-out sane.
- **REFUTED ⇒ dropped**, recorded in the counts only. Do not "fix it anyway to be safe" —
  that is how a clean diff acquires unexplained code.
- **CONFIRMED with `corrected_severity: optional` ⇒ treated as optional.**
- The verifier's `corrected_fix` beats the finder's `suggested_fix` when they disagree: the
  verifier read the code with the defect already in hand.
- Where a finding could fail in more than one way, give each verifier a distinct lens
  (correctness, security, does-it-reproduce) rather than running identical skeptics —
  diversity catches failure modes redundancy cannot.

### 5.6 Origin classification

Classify each finding **at the moment it is confirmed** — cheap now, unreconstructable later
(a scheduled wake starts with no memory beyond the state file):

- `origin: original` — the defect sat in code the change itself wrote.
- `origin: fix` — the defect sat in code written during an earlier review round.

§5.8 trigger 3 is computed from this.

### 5.7 Rounds, convergence, and escalation

```
round 1: full battery      -> dedupe -> verify -> fix -> check -> commit + push
round 2: scoped battery     -> dedupe -> verify -> fix -> check -> commit + push
round 3: …
```

- **Round 1** runs the full battery for the stage.
- **Round N > 1 is scoped**: the fix diff since the last round — pass it to an engine as a
  commit range (`--range <last-round-sha>..HEAD`, undocumented but working; **the engine
  echoes the range back, so read the scope out of the result and confirm it took**). A range
  flag that is silently ignored reverts every later round to a full-diff review while you
  believe you scoped, which is how the unscoped 22.1 h path gets paid for by accident. Plus a
  regression re-check of every finding confirmed earlier, plus any
  axis whose sweep trigger newly fired (§5.8). Do not re-run the whole battery over an
  unchanged region: it costs the same and finds the same nothing. The measured spread is
  roughly fourfold — the one run that scoped its engine calls spent 1.9 h over 27 rounds,
  while the unscoped worst case spent 22.1 h over 83.
- **A failed round is not a round.** An axis that returns an error instead of findings (an
  overloaded API, an empty report, "cannot start") reviewed nothing: do not increment the
  counter, do not clear the axis, never record `clean` from it, and do not immediately
  re-fire it — back off, or run the axis's own charter and record that instead. Six
  consecutive overload errors minutes apart were once all counted as rounds: half an hour,
  zero diff read. **Judge the body, not the duration** — a fast "no findings" over a
  one-commit range is a legitimate result.
- **Axes clear individually, and a cleared axis stays cleared until its own files change.**
  Head movement re-opens only the axes whose files it touched. Without this, every fix push
  re-arms the whole battery and the stage cannot converge.
- **The stage clears when a round returns zero confirmed blocking findings.** Record it
  against the head sha and move on. A clean round is a snapshot of that round, **not proof
  the diff is clean** — the same engine over the same bytes disagrees with itself at
  multi-thousand-line scale (one measured case: round 63 clean, round 64 four new findings
  in a file untouched between them). So `max-rounds` is the real stop condition; never
  substitute "keep going until a round comes back clean", and never spend a round hoping to
  confirm a previous clean one.
- **Findings must survive the round they were raised in.** Each round is a fresh-context
  reviewer, so a finding nobody carries forward simply vanishes — round 2's reviewer never
  saw round 1's list, and a stage would clear the moment a reviewer happens not to re-raise
  something that was never fixed. **Silence is not resolution.** Every finding gets an `id`
  and a `status` in the ledger, and each later round's brief carries the still-open ones
  verbatim with this instruction:

  > For each carried finding, return exactly one of: **fixed** (and say what fixed it),
  > **still open** (and say why the change does not address it), or **withdrawn** (and say
  > why you no longer believe it). You may not leave one unaddressed, and not mentioning one
  > does NOT retire it.

  A finding **you disagree with** is not fixed by ignoring it: record it `open` with your
  rationale in `note`, carry it forward, and let the next round's reviewer rule on it. **Only
  a reviewer withdraws a finding — never the author.**
- **Fixes are ship's own work**, applied sequentially in the worktree. After fixing, re-run
  the discovered check commands, commit, and push — that push is the head the next round
  reviews.
- **A fix changes the defective lines and nothing more.** It does not add a CI gate, a
  runbook section, or a paragraph of comment explaining itself — that is new machinery, it
  enters the next round's scope, and it is how one measured diff went from 2 970 to 5 900
  lines and bought 66 extra findings on a gate the review itself had written. A finding that
  can only be answered with new machinery is a **new change**: one line in the backlog.
  **Watch the diff size across rounds** — a diff growing while under review is this rule
  being broken.
- **Prose is ONE pass, after the code stops moving.** Docs, spec artifacts, task lists,
  comments and any archived copy get a single claims-versus-implementation check at the end
  of the stage, not an axis in every round. Run against a moving implementation, that class
  re-opens on every fix — 53 findings' worth on one change, all of the shape "the comment
  claims what the code does not". Exception: a false statement in prose *this* round just
  wrote is fixed in place, and that fix alone does not re-arm a round.
- **Once a change is already applied and running** (an infrastructure change rolled out
  mid-flight), only two axes stay admissible: does the written record disagree with what is
  actually deployed, and does this break a *repeat* rollout, a rebuild, or onboarding.
  Everything else is a backlog line. On one change, 55 of 85 rounds reviewed code that was
  already live.
- **Non-convergence** — round `max-rounds` still has confirmed blockers: do **not** hand off
  as ready, do **not** loosen the bar, do **not** take a fourth round, and never reclassify a
  finding to get past the gate. Write them to the ledger as open, set `state=needs-human`,
  post ONE record listing them (file:line, failure scenario, why unfixed), **leave the
  enforced blocker of §5.9**, stop scheduling re-wakes, and report. Nothing external will
  change this state, so polling is pointless — a human re-runs `ship` after deciding.
- A confirmed blocker ship *chooses* not to fix (a product or architecture call, not a code
  question) takes the same path: `needs-human`.

**This budget is the only thing standing in for a human reviewer.** Softening it removes the
last check between an unreviewed change and the default branch.

### 5.8 Delta versus whole-head sweep (the seam blindness)

Everything above reviews a **diff**. A diff review is structurally blind to one class of
defect — **an interaction between something the change altered and something it did not** —
because the other half of the pair never appears in the diff. A **sweep** reviews the
checked-out head as a system. It is orthogonal, not a replacement: when a trigger fires, run
BOTH.

**Triggers** (properties of the change, not a round counter):

1. **The change removes or redefines something global** — a column that encoded
   authorization, the meaning of a role, a package boundary, a shared config key. Review
   scope becomes "everyone who relied on it", which is not the diff. Fires on the FIRST pass.
2. **A merge or rebase brought in code written against the old model.** Review the merge as
   its own change — reconstruct the mechanical result (`git merge-tree --write-tree <ours>
   <theirs>`, git ≥ 2.38) and diff it against what was committed to isolate hand-made
   resolutions — then sweep the combined state.
3. **Findings have shifted from the change's own code to its fixes** — a round posts **at
   least one** confirmed finding and every one is `origin: fix`. The non-empty requirement is
   load-bearing: a quiet round satisfies "only fix" vacuously.
4. **A fix touched deployment, configuration, or schema** — no test coverage by
   construction; failure mode is "green in CI, dead in production".

**Sweep axes** (additional subagents, same read-only rules):

| Axis | Charter |
|---|---|
| `sweep-callers` | Grep every removed or redefined identifier across the WHOLE tree — charts, manifests, CI config, specs, READMEs — not just source. Who else read what this change deleted? |
| `sweep-siblings` | Every route, handler or query **of the class this change gated**, including the ones it never touched. A guard present in one file of a class and absent in its siblings is the most repeated defect shape there is. |
| `sweep-runtime` | Does it come up on a clean environment? Required secrets nothing seeds, deploy ordering, migration ordering, update strategy. |
| `sweep-docs` | Live docs, comments and specs still asserting the old model — grep the premise, not just the noun. A comment whose justification expired is often a guard that silently turned off. |

**Latch it — sweep once per triggering EVENT, not once per round.** Record in `swept` the sha
swept and which trigger served it. Re-fire: triggers 1, 2 and 4 only when the code they are
about changes again (4 on the next fix touching deployment/config/schema, not on every push);
trigger 3 only after a later round confirms an `origin: original` finding. Name the mode as a
fixed token: `mode: delta` or `mode: delta+sweep`.

An engine that is diff-scoped **cannot** perform a sweep; the sweep axes are their own
subagents.

### 5.9 What gets posted, and the enforced blocker on a stop

ship authors the change, so **its own review findings do not become resolvable threads** — a
thread ship opens and ship resolves is pure noise, and on a forge where reviewer and author
share one identity it is also indistinguishable from a real review. The record is a comment,
and it is terse.

**One review record per stage per head**, authored fresh in a neutral voice, no engine output
pasted in, no AI self-attribution:

```
Review (impl) — mode: delta — axes: correctness, security, spec-conformance, conventions, gates.
Round 1: 7 candidates -> 3 confirmed, fixed in 4f2a1c9. Round 2: clean.
Security (engine): no issues found in this diff.
Optional (non-blocking): 4 — listed below, no action required.
```

- Keep it to **four lines or so**: counts and the mode token, not finding contents.
- The security line **names which lens produced the verdict**, from `security_engine`:
  - `ran` + nothing found → `Security (engine): no issues found in this diff.`
  - `unavailable` + nothing found → `Security (charter): no issues found in this diff — the
    engine could not start (<one-line reason>); the axis was covered by the review subagent.`
    **A pass that did not run is never reported as one that did** — this is the single claim
    the record may never make.
  - findings in either case → `Security (<engine|charter>): N finding(s), fixed in <sha>`.
- **Optional findings**: batch them ALL into ONE comment (`file:line` plus one line each),
  ending "No action required." Never one comment per nit.
- **Escalated blockers**: one comment listing each with `file:line`, the failure scenario, and
  why it is unfixed.
- Embed a hidden marker for idempotency — `<!-- ship-review:stage=<stage>:sha=<head> -->` —
  and check for it before posting so a re-entered pass never double-posts.
- Multiline bodies always go through a **file**, never an escaped `\n` inside a quoted
  argument (it publishes literally). The reference file has the exact invocation.

**A stop must leave a blocker the forge itself renders**, not just prose. Convert the PR/MR to
**draft** (reference file has the command). Draft is the right mechanism because the merge
gate already requires not-draft, so it is an *enforced* stop rather than a note someone has
to read. Without it, a stopped run leaves a change with green checks, no threads and no
review state — which looks exactly like a finished one. Undo it only when the findings are
actually addressed.

**A stage that reports nothing is indistinguishable from a stage that never ran.** Post the
record even when the stage was clean on the first round.

### 5.10 The ledger and head freshness

A verdict is bound to a **head sha**.

- After each stage clears, record `{stage, head, rounds, mode, axes, counts, clean:true}`.
- The merge gate (§10) requires a clean entry with nothing unreviewed landed after it.
- **Fix-only head advance**: a push carrying only this stage's own review fixes needs its own
  clean entry for the new sha — but that entry is **earned by a scoped round, not a fresh
  full battery**. Re-run only the axes whose files the push touched; untouched axes carry
  their clearance forward. Treating every fix push as a fresh full battery is the loop that
  does not converge — it is what turned one change into 85 engine runs.
- **Archive-only head advance** (§7.F): when the diff between the last clean-reviewed sha and
  the new head is solely the archive move plus the specs it syncs, do NOT re-run the battery
  — run ONE `final-archive` subagent (charter: *the synced specs match the change's deltas;
  the change directory moved wholesale with nothing dropped; the validator and the check
  commands are green; no code changed in this commit*) and record it as `stage: final`. If
  anything **outside** that pattern changed, that is real code: re-run the impl battery
  scoped to it.
- The spec entry's head is **never** compared to the merge head: the spec round is about the
  artifacts, and implementation is *supposed* to move the head past it. What invalidates it is
  the **artifacts** changing.

---

## 6. Wait & react — the loop

With no approval gate, ship mostly *works* rather than waits. The only real waits are a
**running CI pipeline** and an **open thread from another person** (§8). The loop machinery
exists because CI takes minutes and a scheduled wake is how ship survives a session ending.

Two runtime capabilities, named abstractly:

| Capability | Claude Code | Generic fallback |
|---|---|---|
| re-wake (one-shot timer) | `ScheduleWakeup`, or a one-time scheduled agent for a fresh session | one-shot: one pass per manual `ship` invocation |
| watch (between wakes) | a background until-loop, stopped when done | skip — rely on re-wake polling |

If neither exists, **degrade to one-shot mode**: do exactly one pass, say what it is waiting
on and that re-running `ship` continues it. Never busy-loop; **foreground `sleep` is
blocked** regardless.

**The re-wake machinery exists for ONE thing: waiting on CI.** Every other stage is work, and
work does not need a timer. If a pass ends by scheduling a re-wake without a check actually
running, the state was mis-read.

A scheduled run may be a **fresh session with no memory**, so its payload must be
self-contained: re-read the state file, redo §2's env guard and `$ME`, and re-invoke
`ship <target>`. Back off on rate limiting. **Schedule the next re-wake defensively** —
reuse one fixed id so each call upserts the same one-shot, and set it as early in the pass as
is safe, so a mid-pass crash still leaves a queued continuation. Stop creating it only on a
terminal state.

On each wake, in order:

1. **Enforce bounds FIRST.** Load state. If the PR/MR is merged or closed → stop the watch,
   schedule nothing, set `state=done`, stop. If `state == needs-human` → do not schedule;
   report and stop. If `iteration >= max_iterations` or `now > deadline`: with
   `soft_bounds`, post ONE nudge (guarded by `bound_nudge_sent`) and keep going; **by
   default, stop** — post one comment saying the loop ended on a bound and that manual
   follow-up is needed, and schedule nothing. Otherwise `iteration++`.
2. Redo the env guard; fetch the base branch and the source branch; re-read head sha, labels,
   threads, comments, checks.
3. Re-detect the driver state (§3.3) against the ledger (§5.10).
4. Dispatch to the §7 handler. A handler is either a **work burst** or a short **wait**.
5. Persist state. Schedule the next re-wake only if not terminal.

> **Autonomy boundary:** human prompts — confirming a brand-new issue or change, clarifying a
> foreign assignee or PR/MR, resolving a genuinely ambiguous input — happen only in the
> **interactive** invocation. A scheduled wake that reaches one must NOT block: it stops,
> leaves a clear state and a short note, and waits for a human-initiated re-run. Everything
> else runs unattended.

---

## 7. The state machine

### 7.A — `need-issue` (interactive only)

1. Search existing issues for near-duplicates before creating one.
2. If the idea is fuzzy and a spec engine offers an explore mode, use it to sharpen scope
   first — a sharper issue makes a sharper change.
3. Draft the issue (title + body, in the repo's working language). Show it and **ask one
   confirmation**. Respect `no-create` (abort instead). General prior approval does not
   count — ask here.
4. On yes, create it assigned to `$ME`, with labels. **Labels are not decoration** where the
   repo requires them: check the existing label list first and reuse a near-match; create a
   new one only when genuinely missing, and report anything created. Pipeline/stage labels do
   not satisfy a labelling requirement.
5. Capture the number; fall through to §7.B.

Where the repo tracks issues differently — an umbrella issue with a checklist, or no issues
at all — follow the repo's convention: reference the issue in the PR/MR description with the
form that repo uses (a closing keyword only when this change really closes it), and tick its
checklist after a merge. Neither is automated; skipping it makes the board drift from reality.

### 7.B — `issue-ready` → open the change

1. Claim the issue (§3.2).
2. **Branch from a freshly fetched base branch.** Never branch off a local base you have not
   just updated.
   ```bash
   git fetch origin <base>
   git switch -c "<branch>" origin/<base>
   git rev-list --left-right --count origin/<base>...HEAD   # expect "0 <n>" — never behind
   ```
   Name it per §2.3. Never work on the base branch. If the repo runs worktrees, note that a
   fresh worktree does not inherit untracked local config — bring it over before running the
   app from one.
3. **Spec-engine or design-doc repo** → produce the spec artifact (§2.5) via the tool's own
   skills, run its validator strictly, and commit. Run the validator over **in-flight
   changes** as well as published specs: a CI job that validates only published specs does
   not look at a change that has not landed, so this is the only gate that artifact gets.
   **No-spec repo** → skip to §7.D; there is nothing to open a spec-only change with, so the
   PR/MR is opened at the end of the first implementation burst instead.
4. Run the discovered check commands before committing (§2.4). A spec artifact is not
   automatically a docs-only change — take that exemption from the repo's text, not from the
   file extension. If a check is deliberately skipped for a work-in-progress commit, say so
   **as a skip**, in the commit message and to the user.
5. Push, then open the PR/MR: single PR/MR for the whole change, targeting the base branch,
   assigned to `$ME`, carrying the same labels as the issue, body from a **file**, and the
   issue reference in the form §7.A settled on.
6. Verify both the issue and the PR/MR are assigned to us.
7. `state=spec-review` (or `apply` in a no-spec repo). Nothing to wait for — do not schedule
   a re-wake here.

> Idempotency: before step 3, re-scan linked PRs/MRs and the state file. If one already
> exists, do NOT create another.

### 7.C — `spec-review` (work burst, subagents)

Skipped entirely in a no-spec repo.

1. Ensure the worktree is at the head; fetch the base branch.
2. Dispatch the spec battery (§5.2) in one message → barrier → dedupe → verify (§5.5).
3. Fix confirmed blockers **in the artifacts, through the spec tool's skills** where one
   exists, not by hand-editing. Re-validate, commit, push.
4. Scoped rounds (§5.7) until a round returns no confirmed blocker, or escalate at
   `max-rounds`.
5. Post the record (§5.9). Record the clean verdict.
6. `state=apply` → §7.D.

This stage is WORK, not a wait. If you find yourself scheduling a re-wake from it, you have
mis-read the state.

### 7.D — `apply` → implement

1. Ensure the worktree is at the head.
2. **Read the relevant existing spec and the change's own artifacts before writing code**,
   where they exist. Implement, checking off the task list as you go.
3. Verify locally before pushing: the discovered check commands (§2.4), plus the test suite
   of every component the diff touches, plus whatever the repo's law demands as evidence. For
   user-visible behaviour, exercise it for real and record the outcome on the PR/MR. Fix
   until green.
4. Where a spec engine offers a verify step, run it to confirm the implementation matches the
   artifacts (every task checked, no drift) before pushing. Fix any gap. This is ship's own
   gate; the independent look comes from `impl-spec-conformance` in §7.E.
5. Commit — one logical change per commit, in the repo's message style. Push.
6. In a no-spec repo, this is where the PR/MR gets opened if it does not exist yet (§7.B
   steps 5–6).
7. `state=impl-review` → §7.E.

### 7.E — `impl-review` (work burst, subagents)

1. Ensure the worktree is at the head; fetch the base branch — **a stale base produces
   phantom findings.**
2. Evaluate the §5.8 triggers **before dispatching** (trigger 1 can be true on this very
   first pass) and consult `swept` so a latched trigger does not re-fire.
3. Dispatch the impl battery plus any sweep axes in one message → barrier → dedupe → verify →
   classify origin (§5.6).
4. Fix every confirmed blocker sequentially in ship's own context. Re-run the check commands
   and the touched components' tests; commit; push.
5. Scoped rounds (§5.7) until clean, or escalate at `max-rounds` → `needs-human`.
6. Post the stage record plus the batched optional comment (§5.9). Record the clean verdict
   and any sweep.
7. `state=archive` (spec-engine repo) or `ready-to-merge` → §7.F / §7.G.

CI must be green before §7.G, but **a red check is a fix to make, not a review to wait on** —
treat it as another blocking finding in the current round.

> Ordering discipline: **the head that gets handed off must be a head that was reviewed.**
> Every fix push invalidates the previous verdict, which is exactly why the loop is
> "fix → push → re-review the fix diff" and not "fix everything, then declare clean".

### 7.F — `archive` → fold it into the SAME PR/MR

Only in a spec-engine repo whose law puts the archive in the implementation change.

1. Run the spec tool's archive step — it syncs the deltas into the published specs and moves
   the change directory. Do not sync or move by hand.
2. Run the validator and the check commands; commit; push.
3. Final check on the archived head (§5.10): one `final-archive` subagent, or a scoped impl
   round if the commit carried anything beyond the sync-and-move.
4. → §7.G.

### 7.G — `ready-to-merge` → hand off, or merge

Run the repo's own final-push checklist, then the merge gate (§10).

**Where policy says `no-merge` (the default): STOP here and hand over.** Post a record of the
end state — what was reviewed, at which heads, how many rounds, checks green, anything
deliberately deferred — and end the loop with `state=ready-to-merge`. Say what is *holding*,
not that everything is fine: "holding for the go-ahead" is the status. Do not phrase it in a
way that invites someone to read a clean self-review as an approval.

**Where policy says `merge`** and the gate fully passes: merge with the strategy the repo
uses, delete the source branch if that is the convention, verify the issue closed (close it
explicitly if the reference did not do it), then `state=done`, stop the watch, schedule
nothing more.

If the forge refuses the merge because the **project** requires approvals, do NOT attempt to
self-approve or work around it — and do NOT sit there polling. That is a project-configuration
gate that only a person can clear, so it is the same terminal path as any blocker ship will
not fix: report it, post one comment asking for the approval, set `state=needs-human`, and
schedule nothing more. Polling an approval that reviewer-equals-author can never produce is
the infinite wait §10 exists to rule out, and it presents as a healthy green board.

### 7.H — `needs-human`

Terminal until a human acts. The blockers are in the ledger, the record is posted, the PR/MR
is draft (§5.9). Schedule nothing; report and stop.

---

## 8. Threads and comments from other people

`ship` opens no threads of its own and has nobody to answer. But a **person** may comment,
and that is the one review input that outranks everything in §5.

- On every pass, enumerate threads and comments authored by anyone other than `$ME`. Any
  unresolved one is **blocking** and is handled before advancing a stage.
- **Never detect a review by authorship in the other direction.** Where reviewer and author
  share one identity, a filter keyed on "written by someone else" excludes the very reviewer
  it waits for. Our own review records are identified by their hidden marker (§5.9), not by
  who wrote them.
- Reply into the thread with the fix or the rationale; **never resolve it** — the person who
  opened it resolves it, not even to unblock a merge, no exceptions.
- **Read non-threaded comments too.** A plain comment does not appear in any thread count, so
  a human "hold this, I want to look" would otherwise be invisible to the gate. Classify each
  non-self comment on the current head:
  - **objection** — it names a hold or an actionable gate ("do not merge", "hold", "waiting
    on", a concern with no reply). Treat it as a blocker: address it if it is in scope, reply
    with evidence, and **escalate to a human rather than merging** if it is a judgement call.
  - **advisory** — informational or a nit with no gate ⇒ does not block; reply if a reply adds
    anything. A note reporting that a *tool* could not start is an advisory about the
    environment, not a hold — do not misclassify it.
  - **none** — nothing to do.
- **Stalemate.** A thread we cannot resolve, whose substance we have already fixed and
  replied to, can otherwise block forever. Start a grace window at the reply
  (`external_threads_grace`). If it is still open after ~15 wakes with no activity from the
  other person, stop polling: post ONE comment ("fixed in `<sha>`, awaiting <user> to
  resolve"), set `state=needs-human`, and report.

Threads and comments authored by `$ME` are our own records and never block anything.

---

## 9. Confirmation gates & autonomy

- **Create an issue / start a brand-new change** — interactive confirm (§7.A). `no-create`
  skips creation entirely.
- **Foreign assignee or foreign PR/MR** — clarify, never take over.
- **Ambiguous bare number** — ask which kind.
- **Merge** — only per §2.6. A clean self-review is not a go-ahead and must never be treated
  as one. Never self-approve.
- **Blocking findings surviving `max-rounds`** — stop and report (§5.7); never push past it.
- **Production deploys** — never trigger one. Where merging triggers a deployment by
  configuration, that is the repo's pipeline doing its job; do not reach around it by hand,
  and never mutate state a deployment system owns.
- A scheduled wake never blocks on a human: at a gate that needs one it stops cleanly and
  waits for the next interactive run.

---

## 10. Merge gate (ALL must hold)

There is **no approval requirement** and there cannot be one: the reviewer and the author are
the same account, so an approved state can never arrive and waiting for it is an infinite
wait. The gate is instead: green CI, nobody else objecting, the archive in (where
applicable), our own review clean on the head being merged, and an explicit policy that
allows merging at all.

1. Open, **not draft**, mergeable, no conflicts.
2. **Checks green at the current head.** Pending ⇒ wait; failing ⇒ do not merge. A green run
   must belong to the head being merged — after any push, re-read the checks; an older run's
   result says nothing about a new head.
3. **Both review stages clean, with nothing unreviewed landed since** (§5.10). The archive
   commit is exempt; anything beyond the sync-and-move is unreviewed code and goes back to
   §7.E. Never require the recorded impl head to *equal* the merge head — the archive pushes
   after the impl round stamps its head, so that equality can never hold and the gate would
   be unsatisfiable.
4. **No open blocking finding** in the ledger.
5. **No open thread and no objection comment from another person** (§8).
6. The archive is already in the diff, where the repo requires it.
7. The discovered check commands green on this head, plus whatever evidence the repo's law
   asks for.
8. **Policy allows the merge** (§2.6). Nothing ship produced itself substitutes for it: not a
   clean review, not a green board, not an empty finding list.

**Do not use an "auto-merge" flag as a gate.** Where no check is configured as *required*, an
auto-merge flag has nothing to wait on and merges immediately — it has already merged a
change whose run was still in progress. Poll until nothing is pending or running, then merge.

---

## 11. Guardrails (honor verbatim)

- **Discover, never assume** (§2): forge, host, coordinates, base branch, branch naming,
  check commands, spec engine, merge policy. A value copied from another project is a bug.
- **Forge env guard in every shell block** that calls the forge CLI; resolve `$ME` from the
  authenticated account and verify write access; never hard-code a login. Details per forge
  live in the reference file — read exactly the one for the forge you detected.
- **Never commit or push to the base branch** except where the repo's law explicitly allows
  it (typically docs-only). Always branch, from a freshly fetched base.
- **Run the discovered checks before every commit** the repo requires them for, and state
  explicitly if any is skipped. Confirm a runner actually ran something rather than exiting 0
  over an empty selection.
- **Review only in subagents** (§5.1), strictly read-only, dispatched concurrently, with a
  barrier before ship edits anything.
- **Verify before fixing** (§5.5). Refuted means dropped — never "fix it anyway to be safe".
- **Bounded, scoped rounds; `max-rounds` is the stop condition, not "until clean"** (§5.7).
  Blocking requires a *live* failure. A fix touches the defective lines and adds no new
  machinery. Prose gets one pass after the code freezes. A failed round is not a round.
  Findings carry forward by id, and only a reviewer withdraws one.
- **A stop leaves an enforced blocker** (§5.9): convert to draft. A stopped run that looks
  identical to a finished one is the failure this pipeline exists to prevent.
- **A pass that did not run is never reported as one that did** (§5.3, §5.9).
- **Delta review is blind to seams — sweep when a trigger fires, not on a round counter**
  (§5.8), and latch each trigger.
- **The handed-off head must be a reviewed head** (§5.10).
- **Never resolve another person's thread** (§8); reply with the fix or the rationale.
- **Never self-approve; never merge without policy** (§2.6, §10).
- **No AI/assistant attribution anywhere**: not in an issue, PR/MR, comment, reply, commit,
  label, or changelog entry. No "generated with", no co-author trailer, no reaction footer,
  no gratuitous emoji. Author all outward-facing text fresh in a neutral voice.
- **Working language** per the repo's law; multiline bodies always through a file, never an
  escaped `\n` in a quoted argument.
- **Assignment discipline**: claim the issue before local work and the PR/MR when driving it;
  never reassign away from another owner without an explicit request.
- **Fetch the base branch before every pass and every review round** — a stale base produces
  phantom findings.
- **Delegate to the spec tool's own skills** where one exists; never hand-roll its artifacts,
  slugs or archive move. Spec first, then implementation — never code first and document
  after. Skip the spec flow only for genuinely no-behaviour-change work, and when in doubt,
  do not skip it.
- **Autonomy boundary**: human prompts only in the interactive invocation (§6, §9).
- **Bounds enforced FIRST on every wake** (§6).
- **Resilience**: suffix poll calls so a failure does not abort the pass, validate non-empty
  output before parsing, skip a tick on failure, back off on rate limiting. Foreground
  `sleep` is blocked — drive cadence with the re-wake primitive; degrade to one-shot if
  absent. Never busy-loop.
- **Never take a destructive or irreversible action on a whim**: no force-push, no history
  rewrite, no branch or tag deletion beyond the merge convention, no direct mutation of state
  a deployment system owns. Where a human is reachable, ask; where not, escalate.

---

## 12. Appendix — forge-independent commands

```bash
# Discovery (§2)
git remote get-url origin
git symbolic-ref --quiet refs/remotes/origin/HEAD
git remote show origin | sed -n 's/.*HEAD branch: //p'
git for-each-ref --format='%(refname:short)' --sort=-committerdate refs/remotes/origin | head -30
make -qp | awk -F: '/^[a-zA-Z0-9_-]+:/{print $1}' | sort -u        # candidate make targets

# Branch + sync
git fetch origin <base>
git switch -c "<branch>" origin/<base>
git rev-list --left-right --count origin/<base>...HEAD             # expect "0 <n>"

# Review inputs (what the axis subagents are pointed at)
git diff origin/<base>...HEAD                 # the change as a whole
git diff <last-round-sha>...HEAD              # the fix diff, for a scoped round (§5.7)
git merge-tree --write-tree <ours> <theirs>   # isolate hand-made merge resolutions (§5.8)
git diff --stat origin/<base>...HEAD          # watch the diff size across rounds (§5.7)

# Forge operations: see references/forge-github.md or references/forge-gitlab.md
```
