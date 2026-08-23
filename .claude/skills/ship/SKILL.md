---
name: ship
description: Drive a GitHub Issue/PR end-to-end through this repo's pipeline on github.com (repo dimonb/skills) — create the Issue, open the OpenSpec spec PR, review the spec with a fresh-context subagent, apply the implementation, review code+security with subagents, archive in-branch, and stop at ready-to-merge for the human. Self-driven: it runs its own review passes and never waits for an external reviewer.
---

# ship — drive an Issue/PR through the pipeline

`ship` takes one piece of dimonb/skills work from an idea (or a half-done PR) to a **merge-ready** PR, in one session, unattended. It is **self-driven**: it runs its review passes **itself, as subagents**, applies their findings, and stops at the merge line for the human.

It targets **GitHub** `github.com`, repo **`dimonb/skills`**, default/target branch **`main`**. It delegates the heavy spec/code work to the bundled OpenSpec skills (`/opsx:propose`, `/opsx:apply`, `/opsx:verify`, `/opsx:archive`) and the review work to review subagents (§5); it only orchestrates the pipeline.

> **It does NOT merge.** `AGENTS.md` forbids self-merging without the user's go-ahead, and that rule is unchanged by self-driven review — a review pass ship ran on its own work is not a second pair of eyes, it is a better first pair. `ship` therefore always ends at `ready-to-merge` and hands over. The `merge` flag exists only for a user who explicitly grants the go-ahead at invocation.

> **There is no `/review` skill in this repo any more, and no stage waits for one.**
> `ship` used to park in `await-spec-review` / `await-impl-review` until a separate
> `/review` session left a footprint on the PR. Nothing ever started that session
> automatically, so a child would sit in a stage that looks exactly like healthy waiting
> — green board, no escalation — **forever**. Both the waits and the skill are gone; the
> review work moved into §5. A human who wants an independent pass over a big change
> still has one: their own eyes at the merge line, which is where every run now ends.

> **This repo is GitHub-native.** `origin` = `git@github.com:dimonb/skills.git`. Two account gotchas, both critical:
> - The local **SSH key may authenticate as a GitHub identity *without* access** to this repo (a common multi-account setup) — `git push` over SSH then fails with `Repository not found`.
> - All write access goes through whatever account is currently active in `gh`; that account must have repo access. `gh` PR/api ops use the active *keyring* account, but git *transport* (push) must go over **HTTPS with gh's credentials**, not SSH (§2.1).
> - A set `GITHUB_TOKEN` overrides the keyring account — `unset GITHUB_TOKEN` everywhere.

> **AGENTS.md is law here.** Never commit/push to `main` (except docs-only); branch as `feat/`,`fix/`,`docs/`,`chore/`,`refactor/`,`test/`; run `make check` before every non-docs commit; one logical change per commit (Conventional Commits); **archive the OpenSpec change in the SAME PR before merge**; do not self-merge without the user's go-ahead.

---

## 0. `--help` / synopsis (handle FIRST, before anything else)

**If the argument is `--help`, `-h`, or `help`: print the block below verbatim and STOP. Do not touch git, gh, or any state file.**

```
ship — drive a dimonb/skills Issue/PR through the pipeline to a merge-ready PR.
Self-driven: runs its own spec + code + security review passes as subagents.
It never merges — it stops at ready-to-merge and hands over to the human.

USAGE
  ship "<free-text description>"   Create a new Issue (asks to confirm), then propose + spec PR.
  ship #N                          Start from an existing Issue N (propose spec PR, or continue its PR).
  ship pr N | ship !N              Continue an existing PR by number.
  ship <PR-url> | ship <issue-url> Same, resolved from the URL.
  ship                             Resolve from the current branch/worktree.
  ship --help                      Show this help.

FLAGS
  merge           Merge once the gate passes. This IS the user's go-ahead — pass it only
                  when the user said so in this invocation. Default: stop and hand over.
  no-create       Never create an Issue; abort if none is found.
  effort <level>  Effort for the review subagents and local checks (default: max).

PIPELINE (one branch + one PR per change; "Closes #N")
  need-issue -> issue-ready -> spec-review -> apply -> impl-review
             -> archive -> ready-to-merge -> (human merges) -> done
                (fix + re-review, at most 3 rounds per review stage)

  Stage labels are decoration for the board, never a handshake:
    pipe::spec -> pipe::apply -> pipe::archived

BEHAVIOR
  - Reviews itself: a fresh-context subagent reviews the spec before any code is written,
    and code-review + security-review subagents run over the branch diff before archive.
  - A review stage that still has blocking findings after 3 fix rounds STOPS the run and
    reports them. That bound is the only thing standing in for a human reviewer — honor it.
  - Never merges on its own review, and never self-approves. Merge needs the user.
  - All human prompts happen at invocation time; scheduled re-wakes run unattended.
  - Idempotent + re-entrant: safe to re-run; state in .pipeline-state/ISSUE-<n>.json.
```

---

## 1. When to use / input forms

Use when the user wants to push a piece of dimonb/skills work forward — from nothing, from an Issue, or from a half-done PR. Accepted inputs (resolved in §3):

- **Free text** (`ship "add typing indicator"`) — no Issue yet → create one (§7.A).
- **Issue**: `#N` or an issue URL (`.../issues/N`) → propose, or continue its PR.
- **PR**: `pr N`, `!N`, or a PR URL (`.../pull/N`) → continue that PR.
- **No argument** → resolve from the current git branch/worktree.

Convention: for `ship`, **`#N` is an Issue and `pr N`/`!N` is a PR**. A *bare* number is ambiguous — do not guess; ask whether it is an `#issue` or a `pr`.

Optional flags: `merge`, `no-create`, `effort <level>` (see §0).

---

## 2. Setup & preconditions (run at the START of every shell block)

Shell env does NOT persist between Bash calls; the active `gh` account persists globally. Re-set the env guard in **every** block; switch the account once:

```bash
unset GITHUB_TOKEN
```

Once per run:

```bash
unset GITHUB_TOKEN
export REPO=dimonb/skills
git remote get-url origin                              # must contain dimonb/skills
ME=$(gh api user --jq .login)                          # the active gh account; never hard-code it
echo "ME=$ME"
gh repo view "$REPO" >/dev/null 2>&1 || echo "WARN: active gh account ($ME) cannot access $REPO"
```

If `$ME` is empty, or the active account cannot access the repo, STOP and ask the user to point `gh` at an account with repo access (`gh auth switch`). Whatever account is active becomes `$ME` for ALL authorship/assignment checks — resolve it, never hard-code a login. Always pass `--repo "$REPO"` / `repos/$REPO/...`.

### 2.1 Pushing (the SSH trap)

`origin` is SSH, which may resolve to a GitHub identity *without* repo access. **Push over HTTPS with gh's credentials** instead — never permanently rewrite `origin`, just override per-push:

```bash
unset GITHUB_TOKEN
git -c credential.helper='!gh auth git-credential' \
  push https://github.com/dimonb/skills.git <branch>:<branch>
```

`gh pr create` and every `gh api` call already use the active gh account; only the raw `git push` transport needs this override.

### 2.2 Pre-commit checks (AGENTS.md, non-negotiable for non-docs commits)

Before EVERY non-docs commit:

```bash
make check
```

All three must pass. Docs-only changes (paths all under `docs/**`, or `AGENTS.md` alone) are exempt — and may even go straight to `main`; everything else lands through a PR on a feature branch. If a non-docs check is intentionally skipped for a WIP commit, say so in the message and to the user.

---

## 3. Resolve the entry point & detect current state

### 3.1 Classify the argument

1. `--help`/`-h`/`help` → §0.
2. `#N` / issue URL → **Issue path** (§3.2).
3. `pr N` / `!N` / PR URL → **PR path** (§3.3).
4. Free text (not a number, no `#`/`pr`) → **need-issue** (§7.A); the text is the description.
5. No argument → resolve from the current branch (§3.4).
6. Bare number with no prefix → ambiguous; ask `#issue` or `pr`, do not guess.

### 3.2 Issue path — does a PR/branch already exist?

Inspect linked PRs from BOTH the GraphQL closing-references and a body search; union & de-dupe by number:

```bash
unset GITHUB_TOKEN; export REPO=dimonb/skills
gh issue view N --repo "$REPO" --json number,state,assignees,title,url
gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){closedByPullRequestsReferences(first:30,includeClosedPrs:true){nodes{number state url}}}}}' -F o=dimonb -F r=skills -F n=N
gh pr list --repo "$REPO" --state open --search "N in:body" --json number,headRefName,url
```

- If an **open PR targeting `main`** is linked → switch to the **PR path** (§3.3); never open a duplicate.
- If a **branch** exists but no PR → reuse that branch (checkout, then continue from whatever stage its tree implies).
- If **nothing** linked → state is `issue-ready` (§7.B).
- Issue assignee: if unassigned or already us → assign self before any local work (`gh issue edit N --repo "$REPO" --add-assignee "@me"`). If assigned to **someone else** → STOP and clarify; do not take it over (`AGENTS.md`).

### 3.3 PR path — read detail and detect the stage

```bash
unset GITHUB_TOKEN; export REPO=dimonb/skills
gh pr view N --repo "$REPO" --json state,isDraft,headRefName,baseRefName,author,headRefOid,labels,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup,url
```

- `.state != OPEN` (MERGED/CLOSED) → report in chat and stop; do not resurrect.
- `.author.login != $ME` → this PR belongs to someone else. `ship` drives **our own** work; if asked to advance someone else's PR, clarify first.

Detect the pipeline stage from changed paths + labels (implementation code lives outside `openspec/`):

```bash
unset GITHUB_TOKEN; export REPO=dimonb/skills
PATHS=$(gh pr view N --repo "$REPO" --json files --jq '.files[].path')
if   [ -z "$PATHS" ];                                  then STAGE=unknown
elif printf '%s\n' "$PATHS" | grep -qv '^openspec/';   then STAGE=implementation
else STAGE=spec; fi
echo "STAGE=$STAGE"
```

Map to a driver state. **Reviews are cheap and idempotent, so when in doubt, re-run the review rather than assume it happened** — a re-run of a clean stage just confirms and advances, whereas a wrongly-skipped one ships unreviewed work:

| Detected | Driver state |
|---|---|
| spec, no `spec-review` round recorded clean in the state file | `spec-review` |
| spec, last `spec-review` round clean at this head | `apply` |
| implementation, code committed after `reviews.impl.head` | `impl-review` |
| implementation, `impl-review` clean and only archive commits since | `archive` / `ready-to-merge` |

The state file (§4) is the record of which rounds ran and at which head. **What
invalidates a round is unreviewed CODE landing after it, not the head moving** — the
archive commit (§7.F) moves the head by design and is exempt. Comparing the recorded
head to the current one directly would make the pipeline loop `impl-review` → `archive`
→ `impl-review` until `max_iterations`, because §7.F always pushes after §7.E stamps.

If the OpenSpec artifacts changed after a clean spec round, the spec round is stale —
re-run §7.C. Implementation moving the head does not stale it.

### 3.4 Current-branch resolution (no argument)

```bash
unset GITHUB_TOKEN; export REPO=dimonb/skills
BR=$(git rev-parse --abbrev-ref HEAD)
gh pr list --repo "$REPO" --head "$BR" --state open --json number,url
```

- One open PR → PR path (§3.3).
- No PR but `openspec/changes/<id>/` exists in the tree → a local proposal never pushed/opened → resume at the push+open-PR tail of §7.B.
- Nothing → ask what to ship.

---

## 4. State file

Path: `.pipeline-state/ISSUE-<n>.json` (git-ignored). Keyed by Issue number when known, else by PR number (`PR-<n>.json`) until the Issue is linked. Re-entrancy: if `phase=="working"` and it started <10 min ago, another active run is in flight — exit.

```json
{
  "issue": 42,
  "pr_number": 11,
  "me": "<active-gh-login>",
  "branch": "feat/add-typing-indicator",
  "change_slug": "add-typing-indicator",
  "base_branch": "main",
  "state": "need-issue|issue-ready|spec-review|apply|impl-review|archive|ready-to-merge|done",
  "phase": "working|waiting|done",
  "phase_started_at": "2026-06-22T10:00:00Z",
  "last_head_sha": "819f7d74...",
  "iteration": 1,
  "max_iterations": 40,
  "deadline": "2026-06-23T10:00:00Z",
  "monitor_task_id": "...",
  "next_wakeup_reason": "ship-issue-42-tick",
  "reviews": {
    "spec": { "head": "819f7d74...", "rounds": 1, "clean": true, "open": [] },
    "impl": {
      "head": "a1b2c3d4...", "rounds": 2, "clean": false,
      "open": [
        { "id": "impl-2", "file": "lib/foo.ts", "line": 42, "severity": "blocking",
          "summary": "…", "status": "open|fixed|withdrawn", "note": "why deferred" }
      ]
    }
  },
  "flags": { "merge": false, "no_create": false, "effort": "max" }
}
```

`iteration` / `deadline` are enforced FIRST on every wake (§6) so the loop can never run forever.

---

## 5. The review subagents — what actually clears each stage

`ship` reviews its own work. Nothing external clears a stage; a stage clears when a
review round comes back with **no blocking findings**.

> **The reviewer MUST be a subagent with its own fresh context, never this session
> reading back its own work.** That is the whole mechanism. A session that just wrote
> a proposal has every assumption in it already loaded and will confirm them; a
> subagent handed only the artifacts and an adversarial brief has to derive them, and
> derives different ones. This is not ceremony — an external pass over a small spec PR
> in this repo returned three blocking race-condition findings that the session which
> wrote that spec had not seen.

| Stage | Engine | Brief |
|---|---|---|
| `spec-review` | one general-purpose subagent, fresh context | §5.1 |
| `impl-review` | `/code-review <effort>` + `/security-review`, run concurrently | §5.2 |

Both stages obey the same **bounded fix loop** (§5.3).

### 5.1 Spec review (before any code exists)

Run ONE subagent over the OpenSpec artifacts of the change — `proposal.md`,
`design.md`, `tasks.md` and every delta under `specs/<capability>/` — plus the linked
Issue and the CURRENT `openspec/specs/<capability>/spec.md` the delta modifies. Give it
the paths, not your summary of them; a summary is the thing being reviewed.

Brief it to report, each with severity + file + a one-line fix:

- scope drift — does the change do what the Issue asked, no more and no less;
- deltas that are incoherent, incomplete, or contradict the requirement they modify;
- **requirements the change makes moot but leaves standing** — a rule about a path that
  no longer exists rots silently;
- concurrency, ordering and partial-failure cases the proposal does not state a
  behaviour for (the most productive question to ask a spec, by this repo's record);
- premature implementation detail in a proposal, and missing behaviour in a delta;
- OpenSpec format errors (scenario headings are exactly four `####`, slug is plain
  kebab-case with no date prefix).

Tell it to return an EMPTY list if clean, and that inventing a nitpick to look diligent
is a failure, not thoroughness.

### 5.2 Code + security review (after implementation, before archive)

Two independent read-only passes over the branch diff. Run their ANALYSIS
**concurrently**, then handle both result sets together:

```
/code-review <effort>       # default max
/security-review
```

Security findings this repo has actually shipped, worth naming in the brief: a guard
test that passes because the fake makes its own assertion true; a green check that
proves nothing because the mutation was never applied to the CALL SITE; and any secret,
token or session file about to be committed — that last one is always blocking.

### 5.3 The bounded fix loop — 3 rounds, then STOP

Per review stage: review → fix the blocking findings → re-review the new head. At most
**3** rounds.

**Findings must survive the round they were raised in.** Each round is a fresh-context
reviewer, so a finding nobody carries forward simply vanishes: round 2's reviewer never
saw round 1's list, and a stage would clear the moment a reviewer happens not to
re-raise something that was never fixed. Silence is not resolution.

So every finding gets an **id** (`<stage>-<n>`) and a `status` in `state.reviews[stage].open`
(§4), and each subsequent round's brief carries the still-open ones verbatim, with this
instruction to the reviewer:

> For each carried finding, return exactly one of: **fixed** (and say what fixed it),
> **still open** (and say why the change does not address it), or **withdrawn** (and say
> why you no longer believe it). You may not leave one unaddressed, and not mentioning
> one does NOT retire it.

- A finding you **disagree with** is not fixed by ignoring it: record it `status: open`
  with your rationale in `note`, carry it forward, and let the next round's reviewer
  rule on it. Only a reviewer withdraws a finding — never the author.
- If blocking findings remain after the third round, **STOP** (§5.4 says what STOP has
  to leave behind). Do not archive, do not merge, do not quietly downgrade them to
  non-blocking.
- Record every round in `state.reviews` (§4): head sha, round count, whether clean, and
  the finding list with each one's status.

**This bound is the only thing standing in for a human reviewer.** Softening it — a
fourth round, a finding reclassified to get past the gate, a finding allowed to lapse
because nobody restated it — removes the last check between an unreviewed change and
`main`. Honor it strictly.

### 5.4 Leave a record on the PR — and a BLOCKER when you stop

There is no second identity to talk to, so do NOT open inline threads and reply to
yourself. After each review stage **ends** — cleanly or at the round-3 stop — post
**one** PR comment recording it: which passes ran, at which head sha, how many rounds,
what was found, what was fixed, and every finding left open with its rationale.
Authored fresh, English, neutral voice, no AI self-attribution.

**A round-3 stop must also leave a blocker GitHub itself renders**, not just prose:

```bash
unset GITHUB_TOKEN; export REPO=dimonb/skills
gh pr ready N --repo "$REPO" --undo      # convert to draft
```

Draft is the right mechanism because §10 already requires `.isDraft == false`, so it is
an *enforced* stop rather than a note someone has to read. Without it a stopped run
leaves a PR with green checks, no threads and no review state — which looks exactly like
a finished one. The old two-identity flow got this for free: unresolved reviewer threads
and withheld approval both show up in the merge box. Self-driven review has to put that
signal there deliberately.

Undo it (`gh pr ready N`) only when the findings are actually addressed.

A stage that reports nothing is indistinguishable from a stage that never ran — the
exact failure this pipeline was rebuilt to remove.

### 5.5 Optional `pipe::*` labels (board decoration, never a handshake)

`ship` may set `pipe::spec`, `pipe::apply`, `pipe::archived` to make the board
readable. They gate nothing and their absence never blocks anything.

```bash
unset GITHUB_TOKEN; export REPO=dimonb/skills
gh label create "pipe::spec" --repo "$REPO" --color BFD4F2 2>/dev/null || true   # create-on-demand
gh pr edit N --repo "$REPO" --remove-label "pipe::spec" --add-label "pipe::apply"
```

---

## 6. Wait & react — the loop

`ship` needs two runtime capabilities, bound to whatever this environment exposes:

| Capability | This environment (Claude Code) | Generic fallback |
|---|---|---|
| re-wake (one-shot timer) | **`ScheduleWakeup`** (`delaySeconds` 300–600, re-pass the `ship <iid-or-issue>` prompt) | one-shot mode: one pass per manual `ship` invocation |
| watch (between wakes) | **`Monitor`** background until-loop + `TaskStop` to end it | skip — rely on re-wake polling only |

If neither exists, **degrade to one-shot mode**: do exactly one pass (advance one step or report the current wait), tell the user what it's waiting on and to re-run `ship`. Never busy-loop; **foreground `sleep` is blocked**.

When a re-wake is used: pick a gentle 5–10 min delay; the scheduled run re-enters the skill with no memory, so re-read `.pipeline-state/...`, re-set the gh env + `$ME`, and re-invoke `ship <iid-or-issue>`. Back off on HTTP 429.

The loop ends by simply **not** scheduling the next re-wake. On each wake, in order:

1. **Enforce bounds first.** Load state. If `iteration >= max_iterations` OR `now > deadline` OR the PR is merged → stop the watch, do NOT schedule another re-wake, post one comment ("ship loop ended — manual follow-up needed (bound reached)."), set `state` accordingly, stop. Else `iteration++`.
2. Re-set gh env; `git fetch origin main` + the source branch; re-read PR `.headRefOid`, `.labels`, review threads, reviews, checks.
3. Re-detect the driver state (§3.3) from the state file's recorded review rounds and the current head (§5). The head may have advanced, which invalidates a round recorded against the old one, or a human may have opened a thread (§8).
4. Dispatch to the matching state handler in §7. A handler is either a **wait** (schedule next re-wake, keep watching) or a **work burst** (advance, push, then move to the next wait).
5. Persist state after the pass. Schedule the next re-wake only if not `done`.

> **Autonomy boundary:** human prompts (confirm Issue creation; clarify a foreign assignee/PR; resolve a genuinely ambiguous choice) happen only in the **interactive** invocation. A scheduled wake that hits such a point must NOT block — it stops, posts a short note / leaves a clear state, and waits for a human-initiated `ship` re-run. Everything else (propose, apply, archive) runs unattended.
>
> The **merge go-ahead** is the one that is granted once and then persists: `flags.merge`
> is written to the state file at invocation (§4), so a later scheduled wake may act on
> it without asking again. That is intended — the user granted it for this run — but be
> precise about what it means: the flag records a go-ahead the user gave **at the start
> of this run**, not one given at the moment of merging. A wake must never SET the flag,
> only read it.

---

## 7. The state machine

> **Always delegate the spec/code work to the OpenSpec skills — never hand-roll OpenSpec artifacts, slugs, or the archive move by editing files directly.** `ship` only orchestrates; each stage drives the matching skill (this repo canonicalizes the `/opsx:*` commands per `AGENTS.md`; the `/openspec-*` skills are equivalent aliases):
>
> | Stage / situation | OpenSpec skill | Why |
> |---|---|---|
> | Fuzzy idea, unclear requirements | **`/opsx:explore`** | Think the change through before writing a proposal. |
> | Create the change + all artifacts at once | **`/opsx:propose`** | One-step proposal (proposal/design/tasks/delta specs). Default at `issue-ready`. |
> | Step-by-step instead of one shot | **`/opsx:new`** then **`/opsx:continue`** | Start a change and add the next artifact one at a time. |
> | Generate everything fast, no stepping | **`/opsx:ff`** | Fast-forward all artifacts needed for implementation. |
> | A proposal exists but an artifact is missing/partial | **`/opsx:continue`** | Create the next missing artifact rather than rewriting. |
> | Implement the tasks | **`/opsx:apply`** | Work through `tasks.md`, checking boxes. The `apply` stage. |
> | Confirm impl matches the artifacts before archiving | **`/opsx:verify`** | Gate before archive — catches drift between code and spec/tasks. |
> | Sync delta specs into `openspec/specs/` | **`/opsx:sync`** | (Part of archive; standalone only to sync without archiving.) |
> | Archive a finished change | **`/opsx:archive`** | Sync + move to `changes/archive/`. The `archive` stage — **in-branch, before merge** (`AGENTS.md`). |
> | Archive several parallel changes | **`/opsx:bulk-archive`** | Rare; multiple changes at once. |
>
> Useful CLI underneath: `openspec list`, `openspec status --change "<slug>" --json`, `openspec validate`, `openspec archive`.

### 7.A — `need-issue` (interactive only)

Runs in the first interactive burst, while the human is present.

1. `gh issue list --repo "$REPO" --search "<keywords>"` — avoid duplicating an existing Issue.
2. If the idea is fuzzy or under-specified, run **`/opsx:explore`** first to clarify scope before drafting — a sharper Issue makes a sharper proposal.
3. Draft the Issue (title + body, **English**, per `AGENTS.md`). Show it and **ask one confirmation** ("create this Issue?"). Respect `no-create` (abort instead). General prior approval does NOT count — ask here.
4. On yes:
   ```bash
   unset GITHUB_TOKEN; export REPO=dimonb/skills
   gh label list --repo "$REPO" --limit 200          # reuse a near-match; do not invent a synonym
   gh issue create --repo "$REPO" --title "<title>" --assignee "@me" \
     --label "<kind>" --label "area:<x>" \
     --body-file /tmp/issue-body.md
   ```
   (Body via `--body-file`/stdin — never embed escaped `\n` in a quoted arg; it publishes literally.)

   **Labels are mandatory, not decoration** (`AGENTS.md`: "an unlabelled issue is an
   incomplete issue"): at least one **kind** (`bug`, `enhancement`, `documentation`,
   `dependencies`, `security`, `epic`) and one **`area:`** (`area:auth`, `area:api`,
   `area:infra`, `area:ci`, `area:media`, `area:ai`, `area:privacy`, `area:ui`), plus a
   **`severity:`** for anything security-related. Check the existing list first and reuse
   a near-match; if a genuinely new one is needed, create it with a colour and a
   description per `AGENTS.md`, and mention it in the report. The `pipe::*` labels do NOT
   count — they are board decoration (§5.5).
5. Capture the new Issue number; fall straight through to §7.B.

### 7.B — `issue-ready` → propose + open the spec PR

1. Assign the Issue to us if not already (§3.2).
2. **Branch from `main` in a worktree** (`AGENTS.md`). Use a Conventional-Commit-style prefix: `feat/`,`fix/`,`docs/`,`chore/`,`refactor/`,`test/`. Never work on `main`.
   ```bash
   git switch -c feat/<short-description> origin/main
   ```
   > Worktree note (`AGENTS.md`): a fresh worktree does NOT inherit `.env.local`. Before running the app from one, symlink it from the root checkout: `main="$(git worktree list --porcelain | awk '/^worktree /{print $2; exit}')"; ln -s "$main/.env.local" .env.local`.
3. Generate the OpenSpec change via **`/opsx:propose`** — `proposal.md`, `design.md`, `tasks.md`, delta specs under `specs/<capability>/`. (Step through with `/opsx:new` + `/opsx:continue`, or one-shot with `/opsx:ff`; run `/opsx:explore` first if requirements are unclear.) Slug = plain **kebab-case, NO date prefix** (`openspec archive` adds the date). Scenario headings use **exactly four** `####`.
4. **`openspec validate --all --strict`** — fix until clean. `--all`, not the bare form: CI runs `openspec validate --specs --strict`, which gates the published specs only and does **not** look at in-flight changes (`AGENTS.md`). A ship spec PR is entirely an in-flight change, so nothing in CI would catch a broken delta — this is the only gate it gets.
5. Commit the OpenSpec artifacts. **`openspec/**` is NOT a docs-only path** — `AGENTS.md` exempts `docs/**`, `infra/docs/**` and `AGENTS.md` alone, and nothing else — so the check trio (§2.2) applies. It is cheap on a spec-only commit; run it. If you deliberately skip it, say so **as a skip** in the commit message and to the user (§2.2), never as an exemption. Push the branch over HTTPS (§2.1).
6. Open the PR (single PR for the whole change):
   ```bash
   unset GITHUB_TOKEN; export REPO=dimonb/skills
   gh pr create --repo "$REPO" --base main --head "<branch>" \
     --title "<title>" --assignee "@me" \
     --label "<kind>" --label "area:<x>" \
     --body-file /tmp/pr-body.md   # body ends with: Closes #N
   gh pr edit <new-number> --repo "$REPO" --add-label "pipe::spec" 2>/dev/null || true
   ```
   Use **`Closes #N`** from the start. Body in English via file. Carry the SAME kind and
   `area:` labels as the Issue — a PR is labelled under the same rule (`AGENTS.md`), and
   `pipe::spec` does not satisfy it. **No "Generated with Claude Code" footer or any AI
   self-attribution.**
7. Verify the Issue and the PR are both assigned to us.
8. Persist `state=spec-review`; → §7.C. There is nothing to wait for — do not schedule a re-wake here.

> Idempotency: before step 3, re-scan linked PRs/branches (§3.2) and the state file. If a spec PR already exists, do NOT create another — jump to §7.C.

> **The re-wake machinery (§6) now exists for ONE thing: waiting on CI.** Every other
> stage is work, and work does not need a timer. If a pass ends by scheduling a re-wake
> without a check actually running, the state was mis-read.

### 7.C — `spec-review` → review the spec, then advance

Run the spec review subagent (§5.1) over the change's artifacts. Then:

- **Blocking findings** → fix them in the OpenSpec artifacts (via the `/opsx:*` skills,
  never by hand), `openspec validate`, commit, push, and re-review the new head.
  At most 3 rounds (§5.3).
- **Clean** → post the round record (§5.4), set `reviews.spec = {head, rounds, clean:true}`,
  label `pipe::apply`, → §7.D.
- **Still blocking after 3 rounds** → STOP at this stage and report (§5.3).

There is nothing to wait for here. This stage is WORK, not a wait — if you find yourself
scheduling a re-wake from it, you have mis-read the state.

### 7.D — `apply` → implement

1. Re-set env; ensure the worktree is at the PR head.
2. Implement the tasks via **`/opsx:apply`**, checking off `tasks.md` as you go. **Read the relevant `openspec/specs/<capability>/spec.md` before writing code** (`AGENTS.md`).
3. Verify locally before pushing: **`make check`** (§2.2). Add `make check` / `make check` when the change warrants it. Fix until green.
4. Run **`/opsx:verify`** to confirm the implementation matches the proposal/tasks/delta specs (every box checked, no drift) before pushing. Fix any gap.
5. Commit (one logical change per commit, Conventional Commits); push over HTTPS (§2.1).
6. Label: `--remove-label "pipe::spec" --add-label "pipe::apply"` (best-effort).
7. Persist `state=impl-review`; → §7.E.

### 7.E — `impl-review` → review the code, then advance

1. Ensure the branch is pushed and CI has been given the head (checks may still be
   running; the review does not depend on them).
2. Run `/code-review <effort>` and `/security-review` concurrently over the branch diff
   (§5.2).
3. **Blocking findings** → fix, run the check trio (§2.2), commit, push, re-review the
   new head. At most 3 rounds (§5.3).
4. **Clean** → post the round record (§5.4), set `reviews.impl = {head, rounds, clean:true}`,
   → §7.F.
5. **Still blocking after 3 rounds** → STOP and report (§5.3).

Checks must be green before §7.G, but a red check is a fix to make, not a review to wait
on — treat it as another blocking finding in the current round.

### 7.F — `archive` → fold the archive into the SAME PR

Per `AGENTS.md`, the archive lives in the implementation PR, **before merge**, not a follow-up.

1. **`/opsx:archive <slug>`** (= `openspec archive <slug>`): it runs the sync step (delta specs → `openspec/specs/`) and moves `openspec/changes/<slug>/` → `openspec/changes/archive/<slug>/`. Don't sync or move by hand.
2. `make check`; commit (`docs(openspec): archive <slug>`); push (§2.1).
3. Optional label `pipe::archived`.
4. → §7.G (`ready-to-merge`).

> Re-review note: the archive push moves the head. An archive commit is a mechanical
> `/opsx:archive` move plus the specs it syncs, so it does NOT require a fresh code
> review round — but it MUST be green, and CI re-runs `openspec-validate --specs --strict`
> on the post-archive specs. If the archive commit turns out to carry anything beyond the
> sync+move (it should not), that is real code and it goes back through §7.E.

### 7.G — `ready-to-merge` → hand off / merge

Run the **final-push gate** (`AGENTS.md`): no unresolved blocking threads, no substantive unanswered questions. Then apply the merge gate (§10).

**Default behavior: STOP here and hand over.** `AGENTS.md` forbids self-merging without
the user's go-ahead, and a review `ship` ran on its own work is not a substitute for it.
Post a comment recording the end state — spec and implementation reviewed (rounds and
head shas), archived, checks green, anything deliberately deferred — and end the loop
with `state=ready-to-merge`.

Say what is holding, not that everything is fine: "holding for the go-ahead" is the
status. Do not phrase it in a way that invites someone to read a clean self-review as an
approval.

If `merge` IS set — meaning the user granted the go-ahead in this invocation — **and**
the merge gate (§10) fully passes:

```bash
unset GITHUB_TOKEN; export REPO=dimonb/skills
gh pr merge N --repo "$REPO" --squash --delete-branch
```

`Closes #N` auto-closes the Issue on merge; verify it closed (else `gh issue close N --repo "$REPO"`). This repo merges via **squash** (history shows `… (#N)` squash titles). Then `state=done`, stop the watch, do NOT schedule another re-wake.

---

## 8. Threads opened by a human

`ship` opens no threads and has nobody to answer. But a **human** may still comment on
the PR or open an inline thread, and that is the one review input that outranks
everything in §5.

- On every pass, enumerate review threads and comments **authored by anyone other than
  `$ME`**. Any unresolved one is BLOCKING and is handled before advancing a stage.
- Reply into the thread with the fix or the rationale; **never resolve it** — the human
  who opened it resolves it.
  ```bash
  unset GITHUB_TOKEN; export REPO=dimonb/skills
  gh api --method POST "repos/$REPO/pulls/N/comments/COMMENT_ID/replies" -f body="$(cat /tmp/reply.md)"
  ```
- Enumerate via GraphQL (`reviewThreads.nodes[].comments.nodes[0].author.login`), skip
  resolved/outdated, paginate fully.
- A human thread that is still open at the merge gate stops the merge (§10), even if
  every subagent round came back clean. A person asking a question is not noise to route
  around.

Threads authored by `$ME` are our own round records (§5.4) and never block anything.

---

## 9. Confirmation gates & autonomy

- **Create Issue** — interactive confirm (§7.A). `no-create` skips creation entirely.
- **Foreign assignee / foreign PR** — clarify, never take over (§3).
- **Ambiguous bare number** — ask `#issue` vs `pr`.
- **Merge** — NOT automatic, ever, on our own review. Requires the `merge` flag, which
  means the user granted the go-ahead in this invocation (`AGENTS.md`). A clean
  self-review is not a go-ahead and must never be treated as one.
- **Blocking findings surviving 3 rounds** — stop and report (§5.3); never push past it.
- **Production / deploy** — never trigger a production deploy; staging auto-deploys via ArgoCD on merge to `main`, which is fine, but don't `kubectl apply`/patch ArgoCD-owned state.
- A scheduled wake never blocks on a human: if it reaches a gate that needs one, it stops cleanly and waits for the next interactive `ship`.

---

## 10. Merge gate (ALL must hold)

```bash
unset GITHUB_TOKEN; export REPO=dimonb/skills
gh pr view N --repo "$REPO" --json state,isDraft,mergeable,mergeStateStatus,reviewDecision,headRefOid \
  --jq '{state,isDraft,mergeable,mergeStateStatus,reviewDecision}'

# checks green (exit 0 = all pass)
gh pr checks N --repo "$REPO"

# no open thread opened by ANYONE else — i.e. by a HUMAN (GraphQL)
gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100){nodes{isResolved comments(first:1){nodes{author{login}}}}}}}}' \
  -F o=dimonb -F r=skills -F n=N \
  --jq --arg me "$ME" '[.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved==false and .comments.nodes[0].author.login != $me)] | length'   # must be 0
```

- `.state==OPEN`, `.isDraft==false`, `.mergeable==MERGEABLE`, no conflicts (`mergeStateStatus` not `DIRTY`).
- Checks **green** at the current head (`gh pr checks` exit 0). Pending ⇒ wait; failing ⇒ do not merge.
  A green run must belong to the head being merged — after any push, re-read the checks;
  an older run's result says nothing about the new head (`AGENTS.md`).
- **Both review stages clean, and nothing unreviewed has landed since.**
  `reviews.spec.clean` and `reviews.impl.clean` are true, and **every commit after
  `reviews.impl.head` is an archive commit** (§7.F) — i.e. the `/opsx:archive` move and
  the specs it syncs, nothing else.
  Do NOT require `reviews.impl.head == <merge head>`: §7.F pushes the archive commit
  *after* §7.E stamps that head, so equality can never hold and the gate would be
  unsatisfiable. What the rule is protecting against is *unreviewed code* landing after
  a clean round, and an archive commit is not that. If anything beyond the sync+move is
  in those commits, it IS unreviewed code — back to §7.E.
  `reviews.spec.head` is never compared to the merge head at all: the spec round is
  about the OpenSpec artifacts, and implementation is *supposed* to move the head past
  it. What invalidates it is the ARTIFACTS changing (§7.C), not the head.
- No open thread opened by a human (§8).
- The archive is already in the diff (`openspec/changes/archive/<slug>/` present).
- The `merge` flag is set — i.e. **the user granted the go-ahead when this run was
  started** (it persists in the state file for the run, §6). Nothing ship produced itself
  can substitute for it: not a clean review, not a green board, not an empty finding
  list. A run may only ever READ this flag; nothing in the pipeline sets it. Absent it,
  stop at ready-to-merge (§7.G).
- **`gh pr merge --auto` is NOT a gate in this repo** (`AGENTS.md`): no check is
  configured as *required*, so `--auto` has nothing to wait on and merges immediately.
  It has already merged a PR whose run was still in progress. Poll until nothing is
  `PENDING`/`QUEUED`/`IN_PROGRESS`, then merge.

---

## 11. Guardrails (honor verbatim)

- **gh account**: every run starts with `unset GITHUB_TOKEN`; resolve `$ME` from the active gh account and verify it can access the repo (§2) — if not, stop and ask the user to `gh auth switch` to an account with access. Never hard-code a login. Always `--repo dimonb/skills`. Never use `glab`.
- **Push over HTTPS, not SSH** (§2.1): `git -c credential.helper='!gh auth git-credential' push https://github.com/dimonb/skills.git <branch>:<branch>` — the SSH key may resolve to an identity without repo access. Never permanently rewrite `origin`.
- **Never commit/push to `main`** except docs-only (`docs/**` or `AGENTS.md`); always branch with a Conventional-Commit prefix. Never self-approve; never self-merge without the user's go-ahead — a clean self-review is not one.
- **Run checks before every non-docs commit** (`AGENTS.md`): `make check` — all green. State explicitly if any is skipped.
- **one-PR staged flow**: one branch + one PR for the whole change; `Closes #N`; **review the spec before writing any code** (§7.C) — the point of the spec stage is that the review happens while changing course is still cheap; the **archive goes into the same PR before merge** (never a follow-up); don't merge before the archive is in.
- **no-claude-attribution**: no Issue/PR body, comment, reply, commit, or label may contain "Generated with Claude(/ Code)", "Co-Authored-By", a reaction/thumbs footer, gratuitous emoji, or any Claude/Anthropic self-attribution. Author all outward-facing text fresh in a neutral voice.
- **English everywhere** (`AGENTS.md`): all Issue/PR bodies, comments, and OpenSpec artifacts in English. Multiline via `--body-file`/stdin/heredoc — never escaped `\n` in a quoted arg.
- **Assignment discipline**: assign the Issue to us before any local work; assign the related PR to us; verify both before the final push. Don't reassign away from another owner without an explicit request.
- **review-with-a-fresh-context-subagent, never inline** (§5): the session that wrote the artifact cannot review it — it already believes every assumption in it. Hand the reviewer the paths and an adversarial brief, not a summary.
- **the 3-round bound is the gate** (§5.3): blocking findings surviving three rounds stop the run. Never take a fourth round, never reclassify a finding to get past it, and never let one lapse because the next reviewer did not restate it — carry open findings forward by id.
- **a STOP must leave an enforced blocker, not just prose** (§5.4): convert the PR to draft. A stopped run that looks identical to a finished one is the failure this pipeline exists to prevent.
- **label every Issue and PR** (`AGENTS.md`): one kind + one `area:` (+ `severity:` for security work), checked against `gh label list` first. `pipe::*` does not count.
- **never-resolve-a-human's-review-thread** (§8): reply with the fix or the rationale; the person who opened it resolves it.
- **fetch-main-before-pr-work**: `git fetch origin main` before each pass; branches merge fast.
- **edit-in-worktree-not-main**: operate in the current worktree; branch from `main`; bring `.env.local` in before running the app from a worktree.
- **Read the spec before implementing** (`AGENTS.md`): read `openspec/specs/<capability>/spec.md` (and the change's proposal/design/delta) before writing or modifying code.
- **Delegate to the OpenSpec skills, don't hand-roll**: `/opsx:explore`, `/opsx:propose` (or `/opsx:new`+`/opsx:continue`, or `/opsx:ff`), `/opsx:apply`, `/opsx:verify`, `/opsx:archive`. Never create slugs, edit artifacts, or do the archive move by hand.
- **Spec first**: the OpenSpec change comes FIRST, then implementation — never code first and document after. Skip-OpenSpec only for tiny, low-risk, no-spec-impact fixes (typos, formatting, comments); when in doubt, use the Issue+OpenSpec flow.
- **Archive in-branch before merge** (`AGENTS.md`): `/opsx:archive <slug>` lands in the SAME PR as the implementation, before merge — not a follow-up PR.
- **Autonomy boundary**: human prompts only in the interactive invocation; scheduled wakes never block (§6, §9).
- **Bounds**: enforce `max_iterations` and `deadline` as the FIRST action on every wake.
- **Resilience**: suffix watch/poll gh calls with `|| true`, validate non-empty JSON before parsing, skip a tick on failure, back off on 429. Foreground `sleep` is blocked — drive cadence with `ScheduleWakeup`/`Monitor`; degrade to one-shot if absent. Never busy-loop.
- **Cluster safety** (`AGENTS.md`): never perform any direct or indirect cluster op that can cause data loss; the cluster is GitOps-managed by ArgoCD — change state by merging to `main`, not `kubectl apply`/`edit`/`patch`.

---

## 12. Appendix — command reference

Every block assumes `unset GITHUB_TOKEN; export REPO=dimonb/skills` and an active gh account with repo access.

```bash
# Identity (resolve the active account; verify repo access)
gh api user --jq .login; gh repo view "$REPO" >/dev/null && echo OK

# Issue: detail / linked PRs / create / assign / close
gh issue view N --repo "$REPO" --json number,state,assignees,title,url
gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){closedByPullRequestsReferences(first:30,includeClosedPrs:true){nodes{number state url}}}}}' -F o=dimonb -F r=skills -F n=N
gh issue list --repo "$REPO" --search "<keywords>"
gh label list --repo "$REPO" --limit 200
gh issue create --repo "$REPO" --title "<t>" --assignee "@me" --label "<kind>" --label "area:<x>" --body-file /tmp/issue-body.md
gh issue edit N --repo "$REPO" --add-assignee "@me"
gh issue close N --repo "$REPO"

# PR: detail / files / from branch / create / labels / merge
gh pr view N --repo "$REPO" --json state,isDraft,headRefName,baseRefName,author,headRefOid,labels,reviewDecision,mergeable,mergeStateStatus,statusCheckRollup,url
gh pr view N --repo "$REPO" --json files --jq '.files[].path'
gh pr list --repo "$REPO" --head "<branch>" --state open --json number,url
gh pr create --repo "$REPO" --base main --head "<branch>" --title "<t>" --assignee "@me" --label "<kind>" --label "area:<x>" --body-file /tmp/pr-body.md
gh pr ready N --repo "$REPO" --undo    # convert to draft: the round-3 STOP blocker (§5.4)
gh pr edit N --repo "$REPO" --remove-label "pipe::spec" --add-label "pipe::apply"
gh pr merge N --repo "$REPO" --squash --delete-branch

# Review threads / reviews / checks (read)
gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){pullRequest(number:$n){reviewThreads(first:100){nodes{id isResolved comments(first:1){nodes{author{login}}}}}}}}' -F o=dimonb -F r=skills -F n=N
gh api --method POST "repos/$REPO/pulls/N/comments/COMMENT_ID/replies" -f body="$(cat /tmp/reply.md)"
gh api "repos/$REPO/pulls/N/reviews" --jq '.[] | {user: .user.login, state}'
gh pr checks N --repo "$REPO"

# Sync working tree + push (HTTPS, not SSH)
git fetch origin main
gh pr checkout N --repo "$REPO"
git -c credential.helper='!gh auth git-credential' push https://github.com/dimonb/skills.git <branch>:<branch>

# Local checks (before every non-docs commit)
make check

# OpenSpec lifecycle (delegated; opsx is canonical per AGENTS.md)
openspec validate --all --strict     # --all: CI's --specs --strict does NOT gate in-flight changes
openspec status --change "<slug>" --json
openspec archive "<slug>"
#   /opsx:explore  /opsx:propose  /opsx:new  /opsx:continue  /opsx:ff
#   /opsx:apply  /opsx:verify  /opsx:sync  /opsx:archive  /opsx:bulk-archive
```
