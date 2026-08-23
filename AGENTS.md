# AGENTS.md — law for this repo

Seed version, written at bootstrap. Whoever works here first should replace it with the
real thing; until then these rules hold.

## What this repo is

A **portable skills/plugin repository**: agent skills packaged so the same checkout can be
installed as a plugin marketplace by **Claude Code** and by **Codex**. It ships nothing
machine-specific — no absolute home paths, no personal hostnames, no internal project
coordinates. It is intended to become a **public** GitHub repo (`dimonb/skills`).

## Rules

* Never commit or push to `main` (docs-only excepted). Branch as `feat/`, `fix/`, `docs/`,
  `chore/`, `refactor/`, `test/`.
* `make check` must pass before every commit.
* One logical change per commit, Conventional Commits.
* Archive the OpenSpec change in the SAME PR before merge.
* Do not self-merge without the user's go-ahead.
* No attribution footers of any kind in commits, PRs, or issues.
* **Nothing machine-specific in tracked files** — no `/Users/...`, no personal e-mail, no
  internal hostnames, no private project slugs. `make check` enforces the obvious cases;
  judgement covers the rest.
