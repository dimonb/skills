# skills

Agent skills for driving real work through a repository's pipeline, packaged so that **the
same checkout installs as a plugin marketplace in both Claude Code and Codex**.

Two plugins:

| Plugin | What it does |
|---|---|
| **[`ship`](plugins/ship)** | Drives **one** change end-to-end — issue, implementation, its own review passes, hand-off or merge — on GitHub or GitLab. It reviews its own work with read-only subagents and adversarially verifies every finding, so no stage ever waits on an external reviewer. |
| **[`shipyard`](plugins/shipyard)** | Runs `ship` in background terminals and supervises a **fleet** of them: one git worktree per change, a status table on a timer, stall and context-ceiling watchdogs, and every question or architectural decision carried back to the session you are sitting in. |

`shipyard` launches `ship` and nothing else, so install `ship` too if you want the fleet.
Neither Claude Code nor Codex can declare a plugin-to-plugin dependency, so that is a
documented requirement rather than an enforced one.

Nothing here requires any other tool to be installed. `ship` **discovers** the repository it
is pointed at — forge, default branch, branch naming, check commands, whether the project
keeps a spec artifact, and whether it is allowed to merge — so it adapts to a repo instead of
asking the repo to adapt to it.

---

## Install — Claude Code

```bash
claude plugin marketplace add dimonb/skills
claude plugin install ship@dimonb-skills
claude plugin install shipyard@dimonb-skills
```

`marketplace add` also takes a local path or an HTTPS URL, and `--scope user|project|local`
decides where the marketplace is declared (default: `user`). Then:

```bash
claude plugin list                      # what is installed
claude plugin details ship@dimonb-skills   # component inventory + token cost
claude plugin update ship@dimonb-skills
claude plugin uninstall ship@dimonb-skills
claude plugin marketplace remove dimonb-skills
```

## Install — Codex

```bash
codex plugin marketplace add dimonb/skills
codex plugin add ship@dimonb-skills
codex plugin add shipyard@dimonb-skills
```

`marketplace add` takes a local path, `owner/repo[@ref]`, or an HTTPS/SSH git URL, plus
`--ref <ref>` and repeatable `--sparse <path>`. Then:

```bash
codex plugin list                       # everything the configured marketplaces offer
codex plugin marketplace list
codex plugin marketplace upgrade        # refresh git marketplace snapshots
codex plugin remove ship@dimonb-skills
codex plugin marketplace remove dimonb-skills
```

## Install from a local clone

Both CLIs accept a path, which is the quickest way to try a change before pushing it:

```bash
git clone https://github.com/dimonb/skills && cd skills
claude plugin marketplace add .   &&  claude plugin install ship@dimonb-skills
codex  plugin marketplace add .   &&  codex  plugin add     ship@dimonb-skills
```

---

## Layout

```
.claude-plugin/marketplace.json      Claude Code marketplace manifest
.agents/plugins/marketplace.json     Codex marketplace manifest

plugins/<plugin>/
  .claude-plugin/plugin.json         the two manifests, over one shared skills tree
  .codex-plugin/plugin.json
  README.md                          the plugin's own doc — travels with it when installed
  skills/<skill>/SKILL.md            the real file; a plugin may hold several skills

.claude/skills/<skill>  -> symlink into plugins/     so a session opened HERE
.agents/skills/<skill>  -> symlink into plugins/     gets the packaged skills

scripts/check.sh        the repo gate            (make check)
scripts/check-test.sh   proof the gate fires     (make check-test)
```

**One source of truth per skill.** The packaged copy under `plugins/` is the only real file;
the two project skill directories hold symlinks, so working in this repo exercises exactly
what an install ships. `make check` fails if a second copy of a `SKILL.md` ever appears.

A plugin directory carries **both** agents' manifests. Neither agent objects to the other's,
so one directory serves both from one skills tree.

---

## What was verified, and what is convention

The plugin formats here were not written from memory. They were confirmed against the Claude
Code and Codex installations on the machine this repo was built on — each agent's own
authoring guide, manifest spec, and real shipped examples — and then the layout was
**installed for real, in both agents**, from a throwaway scaffold of exactly this shape:

- `claude plugin validate` accepts both the marketplace manifest and a plugin manifest;
  `marketplace add` → `install` → `details` shows the plugin's skills discovered from
  `plugins/<p>/skills/<skill>/SKILL.md`, with no `skills` key needed in the manifest.
- `codex plugin marketplace add <path>` reads `.agents/plugins/marketplace.json` at that
  root; `codex plugin add` installs, and the installed copy contains
  `skills/<skill>/SKILL.md`. The Codex manifest **does** need `"skills": "./skills/"`.
- Both marketplace manifests use `./plugins/<name>` relative to the repo root.

One thing here is **convention rather than proof**: that Codex reads project-scoped skills
from `<repo>/.agents/skills/`. It is consistent across the local Codex layout — `.agents/` is
Codex's sibling of `.claude/`, and Codex's own curated marketplace keeps its skills at
`.agents/skills/` — but no CLI command lists discovered project skills, so it could not be
demonstrated by running something. Dogfooding does not depend on it: the marketplace path to
the same skills is verified, and the symlink is additive.

## Working on this repo

```bash
make check        # the gate — must be green before every commit
make check-test   # proves each of the gate's assertions actually fails when violated
```

`make check-test` exists because a gate that has never failed can be vacuous and look
identical to one that works. It injects one violation per assertion and requires a failure.
Writing it found three real bugs on the first run — including a broken symlink that slipped
past an `[ -e ]` test, and a denylist that never saw untracked files.

[`AGENTS.md`](AGENTS.md) is the law for this repo and is binding on agents and humans alike.

## Licence

MIT — see [LICENSE](LICENSE).
