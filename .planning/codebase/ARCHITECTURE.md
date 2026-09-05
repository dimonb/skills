# ARCHITECTURE — system design and patterns

Both skills are the **same movement**: a supervisor process drives one or more agent consoles
(claude | codex | agy) in a terminal backend (agterm | tmux), reads their output, sends them
input, and tears them down. They differ only in the flow they enforce.

## Driver (terminal-backend abstraction) — exists twice

One API, two backends, behind these calls (council `lib/term.sh` ↔ shipyard `shipyard-backend.sh`):

- **launch**: `ct_launch()` `term.sh:80-104` ↔ `shipyard_launch()` `shipyard-backend.sh:338-368`.
  Both: agterm `agtermctl session new … --wait --command "zsh -lc 'exec <launcher>'"`
  (`term.sh:88-90` / `backend:346-349`); tmux `new-window`/`new-session` with AGTERM_* scrubbed.
- **send**: `ct_type`/`ct_submit` `term.sh:111-120` ↔ `shipyard_type`/`shipyard_submit` `backend:302-322`.
- **read**: `ct_capture` `term.sh:106-110` ↔ `shipyard_capture` `backend:291-298`; address via
  `ct_target` `:67-78` ↔ `shipyard_target` `:222-235`.
- **kill**: `ct_kill` `term.sh:121-125` ↔ `shipyard_kill` `backend:371-378`.

Per-agent specifics are already a seam: council `adapters/{claude,codex,agy}.sh` (`adapter_cmd`),
shipyard `shipyard-agent.sh` (`shipyard_agent_exec`).

## Guard (flow) — divergent, by design

- **shipyard** = effectively **one node**: launch a child ship, let it run the `/ship` pipeline,
  the supervisor (`shipyard-continuity.sh` watch loop `:316-372`) only nudges it back after a
  capacity stop; teardown on MERGE/CLOSE.
- **council** = a **turn cycle**: opening barrier (positions at once), then gated turns with a
  floor / Lamport clock / cursors (`lib/lib.sh`), objections, and **mechanical** closure via
  `lib/claims.jq`. Signalling is out-of-band bells (`c_ring` `lib.sh:245`).

## Policy (escalation) — asymmetric

- **shipyard** has a real human mailbox: `<git-common-dir>/ship-escalations` (`shipyard-lib.sh:23-28`),
  child raises `question|decision|notice` (`shipyard-ask.sh`), parent surfaces
  (`shipyard-escalations.sh:26-41`) and replies (`shipyard-answer.sh`).
- **council has no human mailbox** — the room self-reports `decided|unresolved`
  (`board/decision.md`, `board/status`) and raises in-room alarms (`stuck`/`STALL`, `SKILL.md:162,531`).
  Unifying means giving council a path *to* the mailbox for needs-human signals — an additive change.

## Lifetime anchors — different, and both fragile

- **shipyard** anchors the watcher via a symlink lifecycle lock + a Bash-3.2 PPID probe
  (`shipyard-continuity.sh:492-715`), launched as an **agterm foreground session** because
  "Codex tool processes reap detached descendants … nohup alone cannot" (`:374-376`); a nohup
  fallback exists (`:783-805`).
- **council** anchors the keeper to the **room directory**: a detached `( … ) &` subshell that
  loops `while [ -d "$room" ]; do sleep 5; done` (`up.sh:70-72`) — no owner process, so an
  abandoned room outlives everything. `_keeper_pid` (`up.sh:31-39`) guards the `kill 0`/`kill -0 0`
  hazard documented at `up.sh:14-30`.

This asymmetry is exactly what LIFE-* unifies: one owner + canary + process-group reaping.
