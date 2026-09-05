# STRUCTURE — file inventory

## council — `plugins/council/skills/council/` (SKILL.md 612 lines / 39.5 KB)

- `council.sh` — entrypoint; bash≥5 re-exec; verb dispatch.
- `lib/lib.sh` — transport: lanes, Lamport clocks, cursors, bell, floor, turn conflicts.
- `lib/verbs.sh` — send / recv / claims / verdict / status / decide.
- `lib/up.sh` — room creation, roster, protocols, launchers, **keeper**, relaunch, down.
- `lib/term.sh` — terminal backend abstraction (agterm|tmux) — **the driver, copy A**.
- `lib/claims.jq` — jq program: argument graph + objection-closure rules (mechanical closure).
- `adapters/{claude,codex,agy}.sh` — per-CLI launch command + notes — **the adapter seam**.
- `protocol/_channel.md` — channel rules handed to every participant.
- `scenarios/{debate,freeform,review}.md` — roles per scenario.
- `tests/` — `run-all.sh`, `_helpers.sh`, 21 `t*.sh`.

## shipyard — `plugins/shipyard/skills/shipyard/` (SKILL.md 765 lines / 48 KB)

- `shipyard-backend.sh` — terminal backend abstraction (agterm|tmux) — **the driver, copy B**.
- `shipyard-launch.sh` — start a child ship in its own terminal + worktree; write protocol+launcher.
- `shipyard-continuity.sh` — Codex-parent **supervisor/watcher** lifecycle (`watch`/`watch-foreground`).
- `shipyard-lib.sh` — shared helpers; defines the **mailbox** (`:20-32`).
- `shipyard-agent.sh` — child-agent (codex|claude) exec abstraction.
- `shipyard-report.sh` — one markdown status table for a set of children (forge calls live here).
- `shipyard-escalations.sh` — parent: surface child escalations from the mailbox.
- `shipyard-ask.sh` — child: raise question/decision/notice into the mailbox.
- `shipyard-answer.sh` / `shipyard-tell.sh` — parent reply / unsolicited directive.
- `shipyard-compact.sh` — compact a child and resume.
- `shipyard-ctx.sh` — child context-window usage.
- `shipyard-down.sh` — tear a slot down (terminal + worktree) then lifecycle cleanup.
- `tests/` — `run-all.sh`, `_helpers.sh`, 7 `t*.sh`.

## Map to the three layers being extracted

| Layer | council | shipyard |
|---|---|---|
| **Driver** (DRV) | `lib/term.sh` + `adapters/*.sh` | `shipyard-backend.sh` + `shipyard-agent.sh` |
| **Guard / flow** (FLOW) | `lib/up.sh` keeper + `lib/lib.sh` turn logic + `claims.jq` | `shipyard-continuity.sh` watcher |
| **Policy / escalation** (ESC) | room self-report (no human mailbox) | `shipyard-{ask,answer,tell,escalations}.sh` + mailbox |
