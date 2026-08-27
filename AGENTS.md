# AGENTS.md — law for this repo

Binding on every agent and every human working here. Where this file and a skill disagree,
this file wins.

## What this repo is

A **portable skills/plugin repository**: agent skills packaged so that the same checkout can
be installed as a plugin marketplace by **Claude Code** and by **Codex**. It ships nothing
machine-specific and nothing company-private, and it is intended to become a public GitHub
repository.

Layout, and the one rule that holds it together:

```
.claude-plugin/marketplace.json      Claude Code marketplace manifest
.agents/plugins/marketplace.json     Codex marketplace manifest
plugins/<plugin>/
  .claude-plugin/plugin.json         both manifests, one shared skills tree
  .codex-plugin/plugin.json
  skills/<skill>/SKILL.md            the REAL file — a plugin may hold several skills
.claude/skills/<skill>  -> symlink into plugins/
.agents/skills/<skill>  -> symlink into plugins/
```

**One source of truth per skill.** The packaged copy under `plugins/` is the only real file;
the two project skill directories hold symlinks so that a session opened here gets the
packaged skills without a second copy in git. `make check` enforces this.

**What the gate does and does not see under the two project skill directories.** It enforces the
rule above over **committed** content: a tracked entry there must be a symlink into `plugins/`,
and a packaged skill's own two link paths are asserted staged or not, because those paths are the
repo's. Anything else you keep there untracked — a scratch directory, a local skill of your own,
whatever another tool left behind — is your business: **checks 1, 2 and 5 ignore it**, so its
frontmatter, its name and its scripts are not the gate's concern, and it draws a note rather than
a failure. The two repo-wide scans still read it, deliberately: a leak or a non-Latin script reds
the gate wherever it sits, including in a file you never meant to commit.

That carve-out costs no coverage of anything this repo ships, because everything it ships lives
under `plugins/`, which is checked in full, untracked files included. Failing on incidental local
state only ever blocked unrelated commits. One consequence worth knowing: `make check-test`
restores with `git checkout --`, so it refuses to run at all while any untracked file sits under
the paths it guards — `make check` is fine, but move your scratch directory before running the
other one.

## No spec-artifact stage

This repo keeps **no per-change spec artifact** — no spec tool, no design doc, no proposal
directory. A change is an issue, a branch, and a pull request. Design discussion belongs in
the issue and the PR description, where it is next to the thing it describes.

That is a deliberate choice for a repository of markdown and shell, and it is exactly what
the bundled `ship` skill discovers and adapts to. The property that matters — an
independent, adversarial review before the work is accepted — is not skipped: it moves
wholly into the review passes over the diff, where a scope axis checks the change against
what the issue asked for.

Do not introduce a spec-artifact stage here without changing this section first.

## Rule zero: everything here is generic

**This repository ships generic skills.** Nothing tied to one machine, one company, one
project, one forge or one person belongs in a tracked file — not as a value, not as a
default, not as an example, not in a comment, and not hashed or split up to hide it.

The test to apply to every line before committing it: *would this still be correct in someone
else's repository, on someone else's machine, in another timezone, on the other forge?* If
not, it is not generic, and it goes.

Two things this rule does **not** forbid, because a published package cannot exist without
them: the **publisher's identity** where a manifest requires it (`author`, `homepage`,
`repository`, the marketplace name, the copyright line), and **this repository's own
coordinates** in its install instructions. Those describe who ships the thing, not the
machine it was built on. Everything else is in scope, including comments and examples.

Machine- or person-specific configuration is an **environment variable, never a default**. A
hardcoded default for a personal tool-config directory is both a leak and a functional bug:
everyone else's run silently points at a directory that does not exist.

The leak gate is subject to this rule too, and that shapes what it can be. It carries only
*structural* patterns — absolute home paths, personal config-directory shapes, e-mail
addresses, token and key shapes, hardcoded timezones — which are wrong in anybody's repo, and
it depends on no untracked file. It deliberately does **not** carry a list of anyone's private
names: guarding a private name belongs to the machine that knows it, as a global hook or a
secret-scanner config, not to one repository's gate. Writing such a list into the gate would
also publish it, which is the failure it was meant to prevent.

So the gate catches the *shapes*, and rule zero — absolutely, by judgement, on every line —
catches the names.

## The two skills, and how they relate

**`ship`** drives one change end to end: issue, branch, implementation, its own review
battery, hand-off. It works on GitHub or GitLab and discovers the repo it is pointed at
rather than assuming one.

**`shipyard`** runs a fleet of `ship` sessions — one background terminal and one git worktree
per change — and carries their escalations back to the human. It launches `/ship` and nothing
else, so it is useless without it. In Claude Code that dependency is declared in its manifest
(`"dependencies": ["ship"]`, which the CLI resolves); **Codex has no equivalent field**, so
there it holds only because the docs say so.

The **escalation mailbox** lives in the shared git directory, at `.git/ship-escalations/`, so
the same path resolves from the main worktree and from every child worktree, and it is never
committed. That directory and the `ship-<slot>` terminal and worktree prefix kept their names
through the `sh` → `shipyard` rename **on purpose**: they are the protocol between a watcher
and a `/ship` child, not this skill's own surface, and renaming either would orphan the
mailbox of a run already in flight.

## How work happens here

One change is one issue, one branch, one pull request:

```
issue -> branch -> PR -> the review battery over the diff -> ready-to-merge -> a human merges
```

The review battery is `ship`'s own: read-only subagents on parallel axes, every blocking
finding put to a skeptic that tries to refute it, and a bounded number of fix rounds. Nothing
external clears a stage, and no stage waits on an actor nobody starts. What ends a change is a
**human merging it** — a clean self-review is a better first pair of eyes, never a second one.

Design discussion belongs in the issue and the PR description. There is no spec artifact
(above).

## How to add a skill

A plugin may hold **several** skills, so a new skill usually joins an existing plugin rather
than creating one. Either way:

1. `plugins/<plugin>/skills/<skill>/SKILL.md` — frontmatter `name` must equal the directory
   name. Scripts and `references/` live beside it.
2. For a **new** plugin only: `plugins/<plugin>/.claude-plugin/plugin.json` and
   `.codex-plugin/plugin.json`, both named after the directory; the Codex one needs
   `"skills": "./skills/"`. Add a `README.md` — it travels with the plugin when installed.
3. Both dogfooding symlinks: `.claude/skills/<skill>` and `.agents/skills/<skill>`, each
   pointing at `../../plugins/<plugin>/skills/<skill>`.
4. For a **new** plugin only: register it in **both** marketplace manifests —
   `.claude-plugin/marketplace.json` and `.agents/plugins/marketplace.json`. The gate fails if
   the two disagree or if either disagrees with `plugins/` on disk.
5. `make check`.

## How to verify a change for real

```bash
make check        # the gate
make check-test   # proves the gate's assertions actually fail when violated
```

Then install it the way a user would, from this clone, in whichever agents the change affects
(exact commands are in the README):

```bash
claude plugin marketplace add .  &&  claude plugin install <plugin>@dimonb-skills
codex  plugin marketplace add .  &&  codex  plugin add     <plugin>@dimonb-skills
```

**Tear both down afterwards** — remove the plugin and then the marketplace in each CLI. A
local marketplace left registered points at a working-tree path: it shadows the published
version, and it breaks outright once the branch or worktree goes away.

A claim that something installs, or that a command exists, is only worth making after running
it. Say in the change which parts you verified by running and which you reasoned about.

## Rules

* **Never commit or push to `main`** except docs-only changes (`README.md`, `AGENTS.md`,
  anything under `docs/`). Everything else lands through a pull request on a branch named
  `feat/`, `fix/`, `docs/`, `chore/`, `refactor/` or `test/`.
* **`make check` must pass before every commit.** Extend it as the repo grows: a rule this
  file states and the gate cannot check is a rule that quietly stops holding.
* **One logical change per commit**, Conventional Commits.
* **Every issue and pull request carries labels** — one kind (`bug`, `enhancement`,
  `documentation`, `security`) and one `area:`. Reuse an existing label; report anything you
  create.
* **Do not self-merge without the user's go-ahead.** A clean self-review is a better first
  pair of eyes, not a second one.
* **No attribution footers of any kind** in commits, pull requests, issues, comments or
  changelog entries. No "generated with", no co-author trailer, no reaction footer. Author
  all outward-facing text fresh, in a neutral voice.
* **English everywhere** — issues, pull requests, comments, code, docs. Multiline bodies go
  through a file, never an escaped newline inside a quoted argument. `make check` enforces the
  *script*: a non-Latin character fails the gate, in an untracked file as much as a tracked one
  (the leak check has the same reach, and for the same reason). Latin-script prose that is
  not English it cannot see, so that half is judgement — and a whole plugin once shipped its
  protocol and its decision records in another language before anything said so.
* **Rule zero, restated as a commit rule:** no absolute home paths, no personal e-mail
  addresses, no internal hostnames, no private project names or slugs, no internal issue or
  merge-request numbers, no tokens or credentials of any kind. `make check` enforces the
  structural cases; judgement covers the rest. **Every example is a placeholder** — an
  anecdote's lesson is generic, its identifiers are not, so keep the lesson and invent the
  identifiers.
* **Rule zero also governs commit messages, PR and issue bodies, and comments** — not just
  tracked files. A commit message cannot be scrubbed later without rewriting history, so a
  private name used to *explain* removing a private name undoes the removal permanently. Name
  the shape of the thing, never the thing.
* **If the gate cannot check a rule, say so where the rule is stated.** A rule this file
  states and the gate cannot see is carried by judgement alone; pretending otherwise is how a
  green gate gets read as coverage. Adding a check is better than adding a caveat — and a new
  check needs a probe in `check-test.sh`, or it may be vacuous and nothing will ever say so.
* **A skill's documented behaviour must match the skill.** These files are read by agents as
  instructions, so a stale copy of a command, a flag, or a state name is not a documentation
  bug — it is a defect that makes an agent do the wrong thing confidently. Prefer pointing at
  the authoritative place over copying from it.
