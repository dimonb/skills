# ship

Drives **one** change end-to-end through a repository's pipeline — issue, spec (only where
the repo keeps one), implementation, its own review passes, then hand-off or merge — in one
session, unattended. On GitHub or GitLab.

```
/ship "add a typing indicator"    a new change from an idea (asks to confirm the issue)
/ship #42                         start from, or continue, issue 42
/ship pr 108                      continue pull request 108
/ship !108                        continue merge request 108
/ship                             resolve from the current branch
/ship --help                      the full synopsis
```

Flags: `merge` / `no-merge`, `no-create`, `effort <level>`, `max-rounds <n>`, `soft-bounds`.

## What makes it different from "please open a PR"

**It reviews its own work, and the review is real.** Every review pass runs as *read-only
subagents* — never in the session's own context, because a reviewer that shares the author's
context inherits the author's blind spots. Several axes run in parallel (correctness,
security, conformance to what was asked, the repo's conventions, and whether CI actually
covers what changed), then **every blocking finding faces a skeptic whose job is to refute
it**. Only what survives gets fixed. Refuted findings are dropped rather than "fixed anyway
to be safe", which is how a clean diff acquires unexplained code.

**Nothing waits on an actor nobody starts.** There is no reviewer skill, no approval gate,
and no stage that parks until someone shows up. That is deliberate: on a forge where the
reviewer and the author are the same account, an approval can never arrive, so waiting for
one is an infinite wait — and a stage that waits on nobody looks *exactly* like healthy
waiting from the outside. A stage clears when a review round returns no blocking finding,
within a declared round budget.

**The round budget is the gate.** Blocking findings that survive the budget stop the run,
convert the PR/MR to **draft**, and report. Draft is the point: the merge gate already
refuses a draft, so a stopped run is enforced rather than merely noted. Without it, a stopped
run leaves a change with green checks and no review state — indistinguishable from a finished
one.

**It never merges on its own review.** Merging needs either the repo's stated policy or an
explicit go-ahead in the invocation. A clean self-review is a better first pair of eyes, not
a second one.

## It discovers your repo — nothing is hardcoded

| Fact | Discovered from |
|---|---|
| Forge, host, project path | the `origin` remote |
| Default / target branch | the remote's HEAD, then the forge API |
| Branch naming convention | `AGENTS.md` / `CLAUDE.md` / `CONTRIBUTING.md`, else what the repo already does |
| Check and test commands | `Makefile` targets, `package.json` scripts, or the repo's own instructions |
| Spec artifact stage | whether a spec tool's tree and CLI are present, or a design-doc convention is stated |
| Merge policy | the `merge` / `no-merge` flag, else the repo's stated law, else stop and hand over |

A fact that cannot be discovered is asked about, never guessed and never defaulted to a value
copied from some other project.

**No spec tooling is required.** If your project already runs one, `ship` uses that path and
delegates to the tool's own skills. If it does not, the spec stage simply does not exist and
the pipeline runs issue → implementation → review → hand-off. Either way the change gets an
independent adversarial review before it is accepted.

## Structure

```
skills/ship/SKILL.md                    the pipeline, the review engine, the guardrails
skills/ship/references/forge-github.md  gh mechanics + GitHub-only traps
skills/ship/references/forge-gitlab.md  glab mechanics + GitLab-only traps
```

A run detects the forge once and reads **exactly one** reference file. The core never names
`gh` or `glab`, and neither reference file repeats a pipeline state name — the repo's gate
asserts that, because a second copy of an enum is a copy that goes stale, and a supervisor
believing in a stage that does not exist is how a real stall reads as business as usual.

## Requirements

- `git`, and the forge CLI for your forge: `gh` (GitHub) or `glab` (GitLab), authenticated as
  an account with write access to the repo.
- An agent host that can spawn subagents. Without one, the review engine has nothing to run
  the axes in, and the skill's central guarantee is gone.
- Optionally the bundled `/code-review` and `/security-review` skills, which the axes invoke
  *inside themselves* as analysis engines. When one cannot start, the axis says so and covers
  the surface from its charter instead — a pass that did not run is never reported as one
  that did.

To run many changes at once, see the [`shipyard`](../shipyard) plugin.
