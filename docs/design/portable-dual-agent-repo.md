# Design — portable dual-agent skills/plugin repo

Status: proposed · Closes #1

This is the design artifact for the change that turns this bootstrap seed into a portable
agent-skills repository. It is reviewed before any implementation lands (this repo's law:
design doc on the branch, spec-reviewed, then code — see `AGENTS.md`).

---

## 1. Why

The repo currently holds skills at `.claude/skills/` and nothing else: no plugin packaging,
no README, no per-agent marketplace manifest. Two problems follow.

1. **It installs nowhere.** A skill under `.claude/skills/` is visible only to a Claude Code
   session opened in *this* checkout. Nobody else can install it, and Codex cannot see it at
   all.
2. **The `ship` skill is another project's skill.** It is a copy of a GitHub-native variant
   with that project's repo coordinates, check commands, branch conventions and prose still
   baked in. It works here only because someone mechanically substituted the repo name.

The change makes the repo installable by both agents from one checkout, and replaces the
borrowed `ship` with one skill that discovers its own project and forge.

## 2. What ships

Six deliverables, tracked in #1. Restated here as the acceptance surface:

| # | Deliverable | Done when |
|---|---|---|
| D1 | Dual-agent plugin layout | Both CLIs install a plugin from this checkout, verified by running them |
| D2 | Launcher skill packaged as `shipyard` | `sh` renamed throughout; plugin installs; backend/mailbox/warnings intact |
| D3 | One universal `ship` | Forge-agnostic, project-agnostic, behaviour-configurable, spec-engine-agnostic |
| D4 | Zero machine/company specifics | `scripts/check.sh` gate fails on any denylisted token; tree is clean |
| D5 | README | Install commands for both agents, taken from the local CLIs; a doc per skill |
| D6 | Dogfooding | Both agents' project skill dirs point at the packaged copies; no duplicated `SKILL.md` |

## 3. Layout

```
.claude-plugin/marketplace.json          Claude Code marketplace manifest
.agents/plugins/marketplace.json         Codex marketplace manifest

plugins/ship/
  .claude-plugin/plugin.json
  .codex-plugin/plugin.json
  README.md
  skills/ship/SKILL.md
  skills/ship/references/forge-github.md
  skills/ship/references/forge-gitlab.md

plugins/shipyard/
  .claude-plugin/plugin.json
  .codex-plugin/plugin.json
  README.md
  skills/shipyard/SKILL.md
  skills/shipyard/shipyard-*.sh

.claude/skills/ship     -> ../../plugins/ship/skills/ship
.claude/skills/shipyard -> ../../plugins/shipyard/skills/shipyard
.agents/skills/ship     -> ../../plugins/ship/skills/ship
.agents/skills/shipyard -> ../../plugins/shipyard/skills/shipyard

AGENTS.md  CLAUDE.md  README.md  LICENSE  Makefile  scripts/check.sh
```

### 3.1 Verified facts this layout rests on

Established by running the CLIs on a throwaway scaffold of exactly this shape, then removing
every trace of it:

- `claude plugin validate <repo>` accepts the root `.claude-plugin/marketplace.json`.
- `claude plugin validate plugins/<p>` accepts the plugin manifest.
- `claude plugin marketplace add <local path>` then `claude plugin install <p>@<market>`
  installs, and `claude plugin details` lists the plugin's skills — so Claude Code discovers
  `plugins/<p>/skills/<skill>/SKILL.md` with no explicit `skills` key in the manifest.
- `codex plugin marketplace add <local path>` reads `.agents/plugins/marketplace.json` at the
  given root; `codex plugin add <p>@<market>` installs, and the installed cache contains
  `skills/<skill>/SKILL.md`.
- A plugin directory carrying **both** `.claude-plugin/plugin.json` and
  `.codex-plugin/plugin.json` is accepted by both agents; neither objects to the other's
  manifest.

Reasoned but **not** verified: that Codex reads project-scoped skills from
`<repo>/.agents/skills/`. The convention is consistent across the local Codex layout
(`.agents/` is Codex's sibling of `.claude/`, and Codex's own curated marketplace checkout
keeps its skills at `.agents/skills/`), but no CLI command lists discovered project skills,
so it cannot be proven by running something. Dogfooding does not depend on it: the
marketplace path to the same skills is verified, and the README says which is which.

### 3.2 Constraints the layout must keep satisfying

- **One source of truth per `SKILL.md`.** The packaged copy under `plugins/` is the only real
  file; `.claude/skills/` and `.agents/skills/` hold symlinks. Two tracked copies of one
  skill is the failure this rules out.
- **A plugin may hold many skills.** `plugins/<p>/skills/` is a directory of skills, and
  nothing in the manifests, the gate, or the README may assume one skill per plugin.
- **Plugin-to-plugin dependencies cannot be declared.** Neither CLI supports it (no
  `dependencies` key appears in any real plugin manifest in the official Claude marketplace).
  `shipyard` therefore states its dependency on `ship` in prose — its description and its
  README — and nowhere else.

## 4. `shipyard` — the rename

The launcher keeps every behaviour and changes its name. `sh` shadowed the `sh` binary and
said nothing to a reader browsing a public marketplace.

**Renamed:** skill directory, frontmatter `name:`, the documented invocation
(`/shipyard 108 104`), the script prefix `sh-*.sh` → `shipyard-*.sh`, every internal
cross-reference between those scripts, and the prose.

**Deliberately not renamed**, because they belong to `ship` rather than to the launcher:

- the escalation mailbox directory `.git/ship-escalations/`;
- the terminal session and worktree slot prefix `ship-<slot>`.

Renaming either would orphan the mailbox of any run already in flight.

**Preserved verbatim in substance:** the agterm/tmux backend abstraction (every terminal
operation goes through one script; the skill never calls `agtermctl` or `tmux` directly), the
mailbox/escalation protocol and its three message kinds, the child-environment warnings (a
child inherits neither this session's environment nor its skills), and every failure-mode
warning the file carries.

**Rewritten:** anything referring to the retired review skills. The launcher launches one
thing — `ship` — and `ship` reviews itself, so no companion reviewer session is started,
waited for, or mentioned as if it existed.

## 5. `ship` — one universal skill

Merged from the two real variants: a GitLab-native one that reviews itself and merges, and a
GitHub-native one that reviews itself and stops at ready-to-merge. Everything they share is
the core; everything they disagree about becomes either a discovered fact or a per-forge
reference file.

### 5.1 Structure

```
skills/ship/SKILL.md                     the pipeline, the review engine, the guardrails
skills/ship/references/forge-github.md   gh mechanics + GitHub-only gotchas
skills/ship/references/forge-gitlab.md   glab mechanics + GitLab-only gotchas
```

The core detects the forge once during setup and reads exactly one reference file. Rationale:
a blended single file puts two near-identical-but-not-identical procedures side by side,
which is where a stale copy of a state name comes from — a failure mode both source variants
warn about explicitly. Splitting them also keeps each forge's expensive, specific gotchas
verbatim instead of paraphrased into a shared paragraph.

### 5.2 What the core owns

- Input forms and entry-point resolution (free text, issue, PR/MR, current branch).
- The state machine and its single canonical list of state names.
- The subagent self-review engine: parallel review axes, adversarial verification of every
  candidate finding, deduplication, origin classification, bounded fix rounds, the ledger
  that binds a clean verdict to a head sha.
- The autonomy boundary: which prompts require a human and which never block.
- Guardrails.

### 5.3 What a forge reference file owns

Only mechanics and quirks: identity resolution, the push path, opening and reading a
PR/MR, review threads and comments, checks/pipeline status, labels, assignment, merge, and
the traps specific to that forge. Both sources' warnings are carried over verbatim — among
them the SSH key that authenticates as an identity without repo access (so pushes go over
HTTPS with the CLI's own credential helper), the auto-merge flag that merges immediately when
no check is configured as required, the CLI version whose `api` subcommand has no `--jq` and
whose `mr create` has no `--description-file`, and the forge that forbids self-approval.

### 5.4 Discovery — nothing about the project is hardcoded

Everything the two sources baked in becomes a lookup, performed at the start of a run:

| Fact | Discovered from |
|---|---|
| Forge, host, project path | `git remote get-url origin` |
| Default/target branch | the remote's HEAD, falling back to the forge API |
| Branch naming convention | `AGENTS.md` / `CLAUDE.md`, else the Conventional-Commit prefixes |
| Check/test commands | `Makefile` targets, `package.json` scripts, `AGENTS.md` |
| Spec engine | presence of a spec tool's tree and CLI |
| Merge policy | flag, else repo policy stated in `AGENTS.md` |

A fact that cannot be discovered is asked about (interactively) or escalated — never guessed,
and never defaulted to a value copied from another project.

### 5.5 Behaviour is configurable, not opinionated

The two sources disagree on the single most consequential question — whether ship merges its
own work. That disagreement becomes configuration:

- `merge` / `no-merge` as flags;
- otherwise the repo's own stated policy in `AGENTS.md`;
- otherwise the safe default: stop at ready-to-merge and hand over.

A clean self-review is never treated as a merge authorization by itself.

### 5.6 Spec engine: detected, not required

If the project already runs a spec tool (its tree is present and its CLI is on PATH), the
spec stage drives that tool and the archive stage runs. If not, the spec stage produces a
design doc on the branch and there is no archive stage. Both paths get the same independent
adversarial spec review before any code is written — that review, not the artifact format, is
the property worth keeping. Consequence: ship requires no spec tooling to be installed, and
this repo (which has no spec tool) runs the second path.

### 5.7 What must not survive the merge

- Any stage that waits on an actor nothing starts. Both sources warn about this; one of them
  documents it costing whole nights. No `await-*` state, no external reviewer, no wait for an
  approval that cannot arrive because reviewer and author are the same account.
- Any review-by-authorship detection. Reviewer and author share one identity, so a filter
  keyed on "written by someone else" excludes the very reviewer it waits for.
- Any borrowed project coordinate, check command, internal URL, or issue number.

## 6. The gate — `scripts/check.sh`

Extended, keeping what it already does (shell syntax, `SKILL.md` frontmatter, manifest JSON
validity, home-path leakage). Added:

1. **Denylist.** Absolute home paths, personal e-mail addresses, internal hostnames, private
   project slugs, internal issue/MR numbers and URLs, and credential-shaped strings. Matched
   case-insensitively over tracked files, with the gate's own pattern list excluded from its
   own scan.
2. **Manifest/skill agreement.** Every plugin directory has both manifests; each manifest's
   `name` equals its directory name; every plugin in a marketplace manifest resolves to an
   existing directory; every skill's frontmatter `name` equals its directory name.
3. **Dogfooding integrity.** Every entry under `.claude/skills/` and `.agents/skills/` is a
   symlink that resolves inside `plugins/`; no tracked regular file duplicates a packaged
   `SKILL.md`.
4. **Forge-reference drift.** Every state name in ship's core appears in neither forge
   reference file, so a state enum cannot be copied into a forge file and go stale there.

The gate runs on every commit (`make check`) and must be green before each.

## 7. README

States what the repo is, shows the layout, and gives copy-pasteable install instructions for
both agents with the exact syntax taken from the local CLIs. Because openspec-style spec
tooling is not required by anything here, the README does not present any spec tool as a
prerequisite; the ship doc mentions in one paragraph that a project already running one gets
that path automatically.

A short doc per skill lives with the plugin it belongs to (`plugins/<p>/README.md`), so it
travels with the plugin when installed.

## 8. Migration

1. Move `.claude/skills/sh/*` → `plugins/shipyard/skills/shipyard/` with the rename applied.
2. Write the universal `ship` into `plugins/ship/skills/ship/` with its two reference files;
   delete the borrowed variant at `.claude/skills/ship/`.
3. Delete the 11 vendored third-party spec-tool skills from `.claude/skills/`. They are not
   this repo's work, the tool that owns them installs them itself for both agents, and
   republishing a third party's distribution in a public repo is drift waiting to happen.
4. Add both marketplace manifests, both plugin manifests, the symlinks, the README, and the
   LICENSE.
5. Extend `scripts/check.sh`; update `AGENTS.md` to state this repo's actual law.
6. Verify installability by running both CLIs against the real checkout, then remove the test
   state.

`AGENTS.md` changes in a docs commit: the spec-tool-specific clause is replaced by this
repo's real rule (design doc on the branch, spec-reviewed before implementation). Every other
rule stands.

## 9. Risks

| Risk | Mitigation |
|---|---|
| The universal `ship` loses a hard-won warning while being merged | Every warning in either source is carried into the core or its forge file; the spec review is briefed to hunt for dropped ones specifically |
| A symlink breaks a clone on a platform that does not follow them | Git stores them as symlinks; the gate asserts they resolve, so a broken one fails `make check` rather than silently degrading |
| The Codex project-skills path is wrong | The verified marketplace path is the documented one; the symlink is additive, and the README states which is proven and which is convention |
| A denylist pattern is too broad and blocks legitimate prose | Patterns are anchored and the gate excludes its own pattern list; a false positive fails loudly rather than silently rewriting anything |
| The rename orphans an in-flight run's mailbox | The mailbox directory and slot prefix are explicitly not renamed |
