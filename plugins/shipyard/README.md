# shipyard

A shipyard is where many ships are built at once. This skill runs the repo's own
[`/ship`](../ship) skill in background terminals and supervises a fleet of them: **one
terminal and one git worktree per change**, a status table on a timer, and — because there is
no human inside a background session — every question and every architectural decision
carried back to the session you are sitting in.

```
/shipyard 108 104           continue two existing PRs/MRs, in parallel
/shipyard "#42"             start from issue 42
/shipyard "add X to Y"      a brand-new change from an idea
/shipyard 108 no-merge      extra ship flags pass through verbatim
/shipyard                   no arguments: monitor the sessions that already exist
```

Run it from the **main worktree** of a git repo.

## Requires `ship`

`shipyard` launches exactly one thing: `/ship`. It is not a pipeline of its own and knows
nothing about the stages. Install the [`ship`](../ship) plugin, or provide your own `/ship`
skill. Neither Claude Code nor Codex can declare a plugin-to-plugin dependency, so this is a
documented requirement rather than an enforced one.

## What it actually gives you

**A terminal per change, addressed by slot.** A slot is the key of a terminal plus a worktree
— the number for an existing issue/PR/MR, a slug for a free-text idea. Numeric slots are
deduplicated (two agents in one worktree collide); text slots get a numeric suffix.

**Two backends behind one abstraction.** [agterm](https://github.com/umputun/agterm) sessions
when an agterm app is answering its control socket, tmux windows otherwise, selected by
`SHIPYARD_BACKEND=agterm|tmux|auto`. Every terminal operation goes through a single script, so
a slot behaves identically on either; when neither is available the skill refuses rather than
"starting" work it cannot see or type into.

**A monitor that stays quiet until something happens.** The status table reports running
versus idle from a snapshot diff rather than spinner glyphs, and `--only-changed` keeps it
silent until a state, stage, escalation count or terminal presence actually moves.

**Watchdogs for the two failure modes that look like health.** A background agent parked on
CI and a background agent that has *died* have the same shape — idle, no escalation, green
board. So the report tracks how long each slot has been motionless and prints a loud stall
block that bypasses `--only-changed`, and it surfaces each child's context usage, because a
session at its context ceiling stops accepting turns silently. One ran that way for eight and
a half hours before anyone noticed; both watchdogs exist because of it.

**A mailbox, not a guessing game.** A background session has no human in it, so it escalates
instead of deciding: `question` and `decision` block until you answer, `notice` is
fire-and-forget. Records live in a mailbox inside the shared git directory, so the same path
resolves from the main worktree and from every child worktree, and it is never committed.
You answer with one command and the child picks it up within seconds — you never type into its
terminal for a question it asked.

**A way to speak first.** The mailbox is child-initiated, so it cannot carry a reply to a
`notice` or anything the child never asked about. For that there is a directive channel that
types into the child's terminal, records what was sent, and reports whether it was delivered
or queued.

**Compaction that puts the child back to work.** A long change will reach its context
ceiling. Compacting alone is only half the job: a compacted child comes back with an empty
context and then *sits idle* — the same signature as the stall you just cured. So compaction
and resume are one operation, and hard constraints that must outlive a compaction go into a
standing-orders file rather than a message, because a message dies with the context that held
it.

## Files

| file | role |
|---|---|
| `shipyard-backend.sh` | the agterm/tmux abstraction — every terminal operation goes through it |
| `shipyard-lib.sh` | mailbox paths, slot resolution, payload input, the child env preamble |
| `shipyard-launch.sh` | start a child: slot, protocol, launcher, container |
| `shipyard-report.sh` | the status table, stall watchdog, sidebar glyphs |
| `shipyard-escalations.sh` | the escalation view (`--new` for a fast monitor) |
| `shipyard-ask.sh` | child side: raise a question / decision / notice |
| `shipyard-answer.sh` | parent side: answer one |
| `shipyard-tell.sh` | parent side: speak first, into the child's terminal |
| `shipyard-compact.sh` | compact a child **and** put it back to work |
| `shipyard-down.sh` | teardown, after a merge |

Every script runs by hand from a shell too.

## Two names that are deliberately not `shipyard`

The escalation mailbox directory (`ship-escalations`) and the terminal/worktree slot prefix
(`ship-<slot>`) are named after `ship`, not after this skill. They are the protocol between a
parent watcher and a `/ship` child, and renaming either would orphan the mailbox of a run
already in flight.

## Requirements

- `git`, `bash`, `jq`, and either an agterm app or `tmux`.
- A `/ship` skill in the repo — see above.
- An agent CLI on `PATH` that the launcher can start a child with.

Environment knobs: `SHIPYARD_BACKEND`, `SHIPYARD_WORKSPACE`, `SHIPYARD_SESSION`,
`SHIPYARD_ENV_PASS`, `SHIPYARD_FORCE`, `SHIPYARD_DRY`, `SHIPYARD_STALL_SECS`,
`SHIPYARD_TELL_MAXLINE`, `SHIPYARD_ASK_TIMEOUT`. `SHIPYARD_DRY=1` prints everything a child
would get and starts nothing.
