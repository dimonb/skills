# CONVENTIONS — the rules every change must obey

From `AGENTS.md` (`CLAUDE.md` is just `@AGENTS.md`). These shape every plan automatically.

- **`make check` gate before every commit**, and extend it as rules are added — `AGENTS.md:169,172-173,198-201`; targets `Makefile:4-9` (`scripts/check.sh`, `scripts/check-test.sh`). A rule the gate can't see must get a probe in `check-test.sh` or a stated caveat.
- **One source of truth per skill.** The real file lives under `plugins/`; `.claude/skills/<skill>` and `.agents/skills/<skill>` are symlinks into it; the gate enforces this — `AGENTS.md:26-44,133-141`. → **MIG-02**: shared code needs one decided home, not a copy per plugin.
- **Rule zero — everything generic.** No machine/company/person/forge-specific value, default, example, or comment in tracked files or commit messages; personal config is an env var, never a default — `AGENTS.md:61-90,188-197`. → **GATE-02**.
- **Conventional Commits, one logical change per commit; branch prefixes `feat/ fix/ docs/ chore/ refactor/ test/`; never commit to `main` except docs** — `AGENTS.md:168-173`.
- **Labels** — every issue/PR: one kind (`bug|enhancement|documentation|security`) + one `area:` — `AGENTS.md:174-176`.
- **No spec-artifact stage** — `AGENTS.md:47-58`. This `.planning/` is planning only and stays untracked; the change still ships issue → branch → PR.
- **No attribution footers**; **English everywhere, multiline via a file**; **no self-merge without go-ahead**; **docs must match the skill** — `AGENTS.md:179-187,177-178,202-205`.
- **Portable across Claude Code and Codex** — both marketplace manifests must agree; Codex has **no cross-plugin dependency field** (`AGENTS.md:98-102`), which is *why* the backend is copied today (`term.sh:9-11`). → **GATE-03 / MIG-02** must solve sharing without a Codex dependency mechanism.

## Coding patterns observed (match these)

- Defensive shell: refuse malformed input loudly (`_keeper_pid` rejecting `0`/empty/octal, `up.sh:31-39`); guard `kill` against `0`.
- Heavy inline documentation of *why* (the footgun each guard prevents) — keep that density.
- jq for all JSON; `LC_ALL=C`; multi-statement `local` to avoid `set -u` read-before-assign.
