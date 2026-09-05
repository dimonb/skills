# INTEGRATIONS — external services and interfaces

- **agterm** (via `agtermctl`) — primary terminal backend for both skills: create sessions,
  type stdin, capture text, close, focus. council `lib/term.sh`; shipyard `shipyard-backend.sh`,
  `shipyard-continuity.sh`. Requires `jq` to parse `agtermctl tree --json`.
- **tmux** — alternate backend for both, behind the same API. AGTERM_* env is scrubbed before a
  tmux server is born so it doesn't leak into everything it spawns (`term.sh:94-95`,
  `shipyard-backend.sh:357-359`).
- **Agent CLIs** — launched as consoles, run **with approvals off** (see CONCERNS): council
  `adapters/{claude,codex,agy}.sh`; shipyard `shipyard-agent.sh`.
- **git worktrees** — shipyard runs each child in its own worktree (`shipyard-launch.sh`);
  the escalation mailbox is under `git rev-parse --git-common-dir` so it resolves identically
  from every worktree (`shipyard-lib.sh:23-28`). council does not create worktrees.
- **Forge (GitHub / GitLab)** — only shipyard, and only in `shipyard-report.sh`
  (`gh pr view` `:143`, `glab mr view` `:150`); the actual pipeline forge work is delegated to
  the `/ship` child. council touches no forge.

## Interface the shared driver must preserve
The driver's contract is exactly the union of the agterm and tmux operations both skills already
use: `launch / type / submit / capture / target / kill / focus`, plus backend-select and the
AGTERM_* scrub. Nothing new is integrated; the driver just stops being two copies.
