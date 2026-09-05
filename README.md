# skills

Agent skills for driving real work through a repository's pipeline, packaged so that **the
same checkout installs as a plugin marketplace in both Claude Code and Codex**.

Three plugins:

| Plugin | What it does |
|---|---|
| **[`ship`](plugins/ship)** | Drives **one** change end-to-end — issue, implementation, its own review passes, hand-off or merge — on GitHub or GitLab. It reviews its own work with read-only subagents and adversarially verifies every finding, so no stage ever waits on an external reviewer. |
| **[`shipyard`](plugins/shipyard)** | Runs `ship` in background terminals and supervises a **fleet** of them: one git worktree per change, a status table on a timer, stall and context-ceiling watchdogs, and every question or architectural decision carried back to the session you are sitting in. |
| **[`council`](plugins/council)** | Puts several agent sessions — Claude Code, Codex, Antigravity — in one **room** to argue a single question: they speak in turn, objections must reference what they object to and are closed mechanically, and the room writes a decision record when it converges or an honest `unresolved` one when it does not. |

`council` stands alone — it needs neither of the other two, only the CLIs of the agents you
want in the room.

`shipyard` launches `ship` and nothing else. In Claude Code that is declared —
`shipyard`'s manifest carries `"dependencies": ["ship"]`, so the CLI resolves it. Codex has
no equivalent, so there it is a documented requirement: install `ship` too.

**No spec tooling is required** by anything here — `ship` adapts to whatever the repo already
uses, or to nothing. It does need `git` and the CLI for your forge; `shipyard` also needs
`jq` and a terminal backend. Each plugin's README lists its own prerequisites.

`ship` **discovers** the repository it is pointed at — forge, default branch, branch naming, check commands, whether the project
keeps a spec artifact, and whether it is allowed to merge — so it adapts to a repo instead of
asking the repo to adapt to it.

---

## Install — Claude Code

```bash
claude plugin marketplace add dimonb/skills
claude plugin install ship@dimonb-skills
claude plugin install shipyard@dimonb-skills
claude plugin install council@dimonb-skills
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
codex plugin add council@dimonb-skills
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

## Using them

Once installed, each plugin is a skill the agent invokes by name. Claude Code uses `/skill`;
Codex uses `$skill`. One line starts the workflow, and the details live in the plugin's own
README, which travels with the install.

```
/ship "add a typing indicator"     one change, end to end: issue, implementation, its own
                                   review passes, then hand-off or merge
/ship #42                          start from, or continue, an existing issue
/ship pr 108   ·   /ship !108      pick up an existing pull request / merge request

/shipyard 108 104                  the same, several changes at once — one terminal and one
                                   worktree each, supervised, questions carried back to you
/shipyard "add X to Y"             a brand-new change from an idea
/shipyard 108 no-merge             extra ship flags pass through verbatim
```

Use the same arguments as `$ship` and `$shipyard` in Codex. A shipyard child matches the
runtime that invoked it: Codex launches Codex, while Claude Code launches Claude Code.

`council` is driven by its script rather than by a single argument, because a room outlives
one turn:

```bash
council.sh up --scenario debate --agents claude,codex,agy "Sync or async delivery?"
council.sh status                  # whose turn, what is on the table, what is still open
council.sh decide                  # write the decision record and close the room
```

Two things worth knowing before the first run:

* **`ship` and `shipyard` run from the main worktree of a git repository**, with the CLI for
  your forge already authenticated (`gh` or `glab`). `ship` then discovers the rest — forge,
  default branch, branch naming, check commands, merge policy — from the repo itself.
* **`shipyard` launches `ship` and nothing else**, so `ship` has to be installed too. Claude
  Code resolves that itself; in Codex, install it yourself.

To confirm an install took, `claude plugin details <plugin>@dimonb-skills` lists the skills
the plugin actually exposes.

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
what an install ships. `make check` fails if a second copy of a `SKILL.md` appears anywhere
outside `plugins/`, tracked or not — with those two directories the one exception, where only a
**committed** entry counts. An untracked entry you keep there is local state, and checks 1, 2 and
5 ignore it: it is not in the repository and cannot reach a clone. (The leak and English scans
still read it, wherever it sits.) A packaged skill's own two link paths are the other exception,
and are asserted whether or not they have been staged.

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
make check        # the gate — static checks plus the fast driver suite; green before every commit
make test         # all three suites' fast subsets (driver, shipyard, council); run by hand
make check-test   # proves each of the gate's assertions actually fails when violated
```

The gate checks that every shell script parses and that every `SKILL.md` has frontmatter whose
`name` matches its directory — over tracked files everywhere, and over untracked ones everywhere
except the two project skill directories, whose untracked contents are local state the repo does
not own (a packaged skill is untracked in the moment between writing it and `git add`, which is
why the reach stops there and not sooner); that each plugin has both manifests, valid and named
after its
directory, with at least one skill; that marketplace entries resolve and that **both**
manifests offer the same plugins as `plugins/` on disk; that every packaged skill is
symlinked for both agents, with the link resolving inside `plugins/` and no second copy of
any `SKILL.md` committed there — a packaged skill's own two link paths are repo-owned, so those
are asserted staged or not, while any other untracked entry there is local state and only draws a
note; that no per-forge reference file carries a copy of the pipeline state enum
and no state exists without a handler; that no non-generic string is present; that no tracked
file carries non-Latin script (untracked ones too, like the leak scan); that no council test
names the shared temp parent — a grep
for the shape a test copied from an older checkout carries, not a proof about where its rooms
are built; and that every test on disk, in each suite (driver, shipyard, council), appears in the
list its `run-all.sh` actually walks, so a test cannot land and then silently stop running. Beyond
those static checks, `make check` also runs the fast driver suite itself, so a driver-suite
regression reds a commit; the slower shipyard and council suites run under `make test`, and `make
check` gates only their registration (above). CI (`.github/workflows/ci.yml`) then runs all three —
`make check`, `make check-test` and `make test` — on every push to `main` and every pull request,
so those suites' runtime errors surface in CI; locally, where `make check` stays fast, they still
surface at `make test` time rather than at commit time.

`make check-test` exists because a gate that has never failed can be vacuous and look
identical to one that works. It proves every assertion in the gate — a clean baseline, then each
assertion's violation injected one at a time (each probe aiming to fire only the assertion it
names), plus the cases that require the gate to stay **green**; it prints the running total as
`assertions proven: N`. Every failure path in `check.sh` now has one, including
every arm that fires when a matcher errors, or finds nothing to inspect, instead of finding a
violation — an unprobed arm of that kind reports success having inspected nothing, which is
indistinguishable from a clean run.

The green cases are the same defect seen from the other side. A check that reds on state the repo
does not own blocks every commit until that state is moved, and nothing about a red gate says
which of the two kinds it is; one such false positive is what made check 5 index-driven. Where a
green result alone would not be evidence, `expect_pass` also takes a message the gate must still
print, or one it must **not** — an exit status cannot tell a check that correctly ignored
something from a check that is gone, nor a note that is correctly withheld from one that vanished.
`check-test.sh` is authoritative for which probes carry which.

Where two arms are layered so that the outer one reds for the inner — a missing runner means
no test list, and no test list means every test reads as unregistered — the probe passes the
expected message to `expect_fail` and is failed as `WRONG ARM` without it. Asserting only
that *something* reddened would keep reporting a pass over an assertion that had been
deleted, which is how both of check 10's diagnostic arms were vacuous when first written.

Five arms still have no kill test, named here rather than left to be found: delete the `fail`
for `no name:`, `plugin has no skills/ directory`, `plugin has no skills/<skill>/SKILL.md`,
`missing marketplace manifest` or `invalid JSON` (marketplace), and the probe that names it still
reds — on a neighbouring assertion — so `make check-test` reports it caught over an assertion
that no longer exists. Every one is pre-existing and each needs its own pin, so they are tracked
as an issue rather than fixed alongside an unrelated change. The list `check-test.sh` keeps above
`expect_fail` is the authoritative one; this paragraph is a summary of it and nothing more.

Writing and re-running it has found six real bugs
so far, including a broken symlink that slipped past an `[ -e ]` test, a leak check that never
saw untracked files, a state/handler check that passed because `spec` is a prefix of
`spec-review`, and probes of its own that fired the wrong check and so proved nothing.

If you add a check, add its probe. An assertion with no probe can be vacuous, and a green
`make check-test` would certify it anyway.

### The leak check

It carries only **structural** patterns — absolute home paths, personal config-directory
shapes, e-mail addresses, token and key shapes, hardcoded timezones — the things that are
wrong in anybody's repository, with no dependency on any untracked file. It deliberately does
not carry anyone's private names: guarding a private name belongs to the machine that knows
it, as a global hook or a secret-scanner config, and writing such a list into a public gate
would publish the very thing it was meant to protect.

One trap if you add patterns: **`git grep -E` does not support `\b`**. It matches a literal
`b`, so `\bfoo\b` matches "bfoob" and *not* "foo" — silently inverting your pattern. Plain
`grep -E` does support it, which is exactly how this bites. Write `(^|[^a-z])foo([^a-z]|$)`.

[`AGENTS.md`](AGENTS.md) is the law for this repo and is binding on agents and humans alike.
Its first rule is that everything here is generic.

## Licence

MIT — see [LICENSE](LICENSE).
