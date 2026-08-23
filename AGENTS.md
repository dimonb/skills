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

Machine- or person-specific configuration is an **optional local file or an environment
variable, never a default**. Two consequences that have already bitten:

* a hardcoded default for a personal tool-config directory is both a leak and a functional
  bug — everyone else's run silently points at a directory that does not exist;
* the leak gate's own pattern list is subject to this rule. It carries only *structural*
  patterns (absolute home paths, personal config-dir shapes, e-mail addresses, token and key
  shapes), which are wrong in anybody's repo. Names private to one person or project go in
  `scripts/denylist.local`, which is gitignored, optional, one extended-regex per line, and
  which `make check` reports loading so reduced coverage is stated rather than silent.

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
  through a file, never an escaped newline inside a quoted argument.
* **Rule zero, restated as a commit rule:** no absolute home paths, no personal e-mail
  addresses, no internal hostnames, no private project names or slugs, no internal issue or
  merge-request numbers, no tokens or credentials of any kind. `make check` enforces the
  structural cases; judgement covers the rest. **Every example is a placeholder** — an
  anecdote's lesson is generic, its identifiers are not, so keep the lesson and invent the
  identifiers.
* **A skill's documented behaviour must match the skill.** These files are read by agents as
  instructions, so a stale copy of a command, a flag, or a state name is not a documentation
  bug — it is a defect that makes an agent do the wrong thing confidently. Prefer pointing at
  the authoritative place over copying from it.
