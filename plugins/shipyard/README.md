# shipyard

A shipyard is where many ships are built at once. This skill runs the repo's own
[`ship`](../ship) skill in background terminals and supervises a fleet of them: **one
terminal and one git worktree per change**, a status table on a timer, and — because there is
no human inside a background session — every question and every architectural decision
carried back to the session you are sitting in.

```

Use `/shipyard` in Claude Code and `$shipyard` in Codex. The child runtime matches the
runtime that invoked the skill: Claude Code launches Claude Code, while Codex launches Codex.
/shipyard 108 104           continue two existing PRs/MRs, in parallel
/shipyard "#42"             start from issue 42
/shipyard "add X to Y"      a brand-new change from an idea
/shipyard 108 no-merge      extra ship flags pass through verbatim
/shipyard                   no arguments: monitor the sessions that already exist
```

Run it from the **main worktree** of a git repo.

## Requires `ship`

`shipyard` launches exactly one thing: the matching runtime's `ship` skill. It is not a
pipeline of its own and knows nothing about the stages. Install the [`ship`](../ship) plugin,
or provide your own `/ship` skill in Claude Code or `$ship` skill in Codex. In Claude Code the
dependency is declared in this plugin's manifest, so the CLI resolves it; Codex has no
equivalent field, so there it is a documented requirement only.

## What it actually gives you

**A terminal per change, addressed by slot.** A slot is the key of a terminal plus a worktree
— the number for an existing issue/PR/MR, a slug for a free-text idea. Numeric slots are
deduplicated (two agents in one worktree collide); text slots get a numeric suffix.

**A launch this machine cannot take is refused before it starts.** Each launch clears an
admission gate first — a **concurrency cap** (`SHIPYARD_MAX_SLOTS`, default 2 live `ship-*`
slots) and, on macOS, a **memory-pressure floor** (`SHIPYARD_MEM_MIN_FREE_PCT`, default 10%
free, read from `memory_pressure`). Over either limit and the launch is refused, with a
distinct exit code and a message naming the gate, the current value versus the limit, and the
env var to override it — no worktree or terminal is created. This exists because an uncapped
fleet once drove a 16 GB machine into swap until macOS recycled the whole GUI login session;
the gate is that "stop the bleeding" check, not a scheduler. Where `memory_pressure` is
unavailable the memory gate is a no-op, never a hard failure. `SHIPYARD_DRY=1` reports the
gate's decision without enforcing it.

**Two backends behind one abstraction.** [agterm](https://github.com/umputun/agterm) sessions
when an agterm app is answering its control socket, tmux windows otherwise, selected by
`SHIPYARD_BACKEND=agterm|tmux|auto`. Every terminal operation goes through a single script, so
a slot behaves identically on either; when neither is available the skill refuses rather than
"starting" work it cannot see or type into.

**A monitor that stays quiet until something happens.** The status table reports running
versus idle from a snapshot diff rather than spinner glyphs, and `--only-changed` keeps it
silent until a state, stage, escalation count, ctx band or terminal presence actually moves.

**A Codex parent that survives transient model-capacity stops.** When shipyard is launched
from Codex in agterm, the first live child also starts one idempotent continuity watcher for
the parent session, even when a child-runtime override selects Claude. A root capacity banner
gets one `resume`; eight seconds later the watcher
queues `/goal resume`, including during an active turn, because agterm supports steering.
Indented tool output cannot imitate the banner, service lines and stale `Working` scrollback
do not hide it, and a later observably distinct banner or intervening submitted turn re-arms
the guard. Byte-identical scrollback replacements between polls have no cursor or generation
in the current agterm text API, so the guard conservatively avoids replaying an unchanged screen.
The current input prompt
is the common-case safety boundary: an existing user draft blocks submission. The watcher checks
the prompt immediately before text, sends text and Return as separate actions, and re-reads the
prompt plus user-activity clock before Return; activity delays Return, and a mismatch cancels it
without erasing input. The current agterm control API has no atomic conditional insert or submit,
so a keystroke can still race between either check and its following write. In that narrow window
the inputs can concatenate, and the watcher can alter or submit the combined line. This guard
reduces routine collisions; it does not claim absolute draft isolation. Claude parents and tmux
runs are unchanged.

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

**A diagnosis order for a child that looks stuck.** Several different failures wear one face:
a child at its context ceiling, one compacted and never resumed, one that left its own next
instruction unsubmitted in the input box, and one healthily waiting on CI all read the same
from the table. So the order is fixed — **git first** (it says what the child *produced*; the
pane says only what it *intended*), then the directive channel, and only then compaction. The
status table prints that order next to any slot it flags as stalled.

**A context reading you can trust.** The `ctx` column is read from the child's own transcript,
not scraped from its terminal — a child running subagents shows no session figure on screen at
all, so the pane goes blind exactly when the child is deepest in work. It shows a percentage
beside the raw token count, and says so explicitly when it *cannot* scale the number rather
than guessing.

**Compaction that puts the child back to work**, for when it is actually needed. The client's
own autocompact handles ordinary growth on its own; what it does not do is rescue a session
already past the line, or resume one afterwards. And compacting alone is only half the job: a
compacted child comes back with an empty context and then *sits idle* — the same signature as
the stall you just cured. So compaction and resume are one operation, and hard constraints that
must outlive a compaction go into a standing-orders file rather than a message, because a
message dies with the context that held it.

## Files

| file | role |
|---|---|
| `shipyard-agent.sh` | select and launch the child runtime that matches the parent |
| `shipyard-backend.sh` | the agterm/tmux abstraction — every terminal operation goes through it |
| `shipyard-lib.sh` | mailbox paths, slot resolution, payload input, the child env preamble |
| `shipyard-continuity.sh` | automatic capacity retry and paused-goal continuity for a Codex parent in agterm |
| `shipyard-launch.sh` | start a child: slot, protocol, launcher, container |
| `shipyard-admission.sh` | the pre-launch admission gate: concurrency cap + macOS memory-pressure |
| `shipyard-report.sh` | the status table, stall watchdog, sidebar glyphs |
| `shipyard-ctx.sh` | the ctx column: reads a child's transcript, infers its window, bands it |
| `tests/run-all.sh` | the shipyard script suite — runs under `make test`; its registration is gated by `make check` |
| `shipyard-escalations.sh` | the escalation view (`--new` for a fast monitor) |
| `shipyard-ask.sh` | child side: raise a question / decision / notice |
| `shipyard-answer.sh` | parent side: answer one |
| `shipyard-tell.sh` | parent side: speak first, into the child's terminal |
| `shipyard-compact.sh` | compact a child **and** put it back to work |
| `shipyard-down.sh` | teardown after a merge, including the last parent continuity watcher |

Every script runs by hand from a shell too.

## Two names that are deliberately not `shipyard`

The escalation mailbox directory (`ship-escalations`) and the terminal/worktree slot prefix
(`ship-<slot>`) are named after `ship`, not after this skill. They are the protocol between a
parent watcher and a `/ship` child, and renaming either would orphan the mailbox of a run
already in flight.

## What a child is allowed to do — read this before your first run

A child is an **autonomous agent session with automatic approval review**, working in a git
worktree of your repository and pushing to your forge, with no human in its terminal. Claude
Code uses `--permission-mode auto`; Codex uses `--approve-for-me`. A background session that
stops to ask permission is a background session that sits idle until someone notices.

What keeps that safe is the pairing, so do not break it:

- the child runs `/ship` in Claude Code or `$ship` in Codex, which escalates anything risky or irreversible instead of deciding
  — and `ship`'s own guardrails forbid force-pushing, history rewriting, branch deletion
  beyond the merge convention, and merging without an explicit policy or go-ahead;
- **you** are the human it escalates to. If you launch children and stop reading the
  escalations, you have removed the only judgement in the loop.

Run it with `SHIPYARD_DRY=1` the first time: that prints everything a child would get and
starts nothing.

## Requirements

- `git`, `bash`, `jq`, and either an agterm app or `tmux`.
- A `ship` skill in the repo — see above.
- The CLI matching the parent runtime on `PATH`: `claude` for Claude Code or `codex` for Codex.
- `gh` or `glab`, authenticated, for the status table's forge lookups. `GH_CONFIG_DIR` is
  honoured from your environment when set and otherwise left to `gh` — there is no default
  pointing at anyone's machine. `GITLAB_HOST` defaults to the host in the `origin` remote.

Environment knobs: `SHIPYARD_AGENT`, `SHIPYARD_BACKEND`, `SHIPYARD_WORKSPACE`, `SHIPYARD_SESSION`,
`SHIPYARD_ENV_PASS`, `SHIPYARD_ENV_SCRUB`, `SHIPYARD_SLOT`, `SHIPYARD_FORCE`, `SHIPYARD_DRY`,
`SHIPYARD_MAX_SLOTS`, `SHIPYARD_MEM_MIN_FREE_PCT`, `SHIPYARD_STALL_SECS`, `SHIPYARD_CTX_WINDOW`,
`SHIPYARD_TELL_MAXLINE`, `SHIPYARD_ASK_TIMEOUT`.

`SHIPYARD_MAX_SLOTS` (default `2`) and `SHIPYARD_MEM_MIN_FREE_PCT` (default `10`) are the two
admission-gate knobs — the concurrency cap and the macOS free-memory floor a launch must clear.
See **A launch this machine cannot take** above.

`SHIPYARD_CTX_WINDOW` pins the context window, in tokens as a plain integer, that the `ctx`
percentage is measured against. Without it the window is inferred from the largest total the
child's transcript has ever carried — a request that carried N tokens cannot have run on a
window smaller than N — and the override beats that inference in both directions.

Three more are worth knowing about. `SHIPYARD_AGENT=auto|codex|claude` defaults to matching the
parent runtime; set it explicitly only when invoking the scripts from a shell with no parent
agent identity. `SHIPYARD_ENV_PASS` **replaces** the set of variables copied from your session
into a child — the runtime-specific default is `CODEX_HOME` or `CLAUDE_HOME CLAUDE_CONFIG_DIR`.
Name those again if you still want them, or the child may resolve a different config directory
and get different skills. `SHIPYARD_ENV_SCRUB` overrides the set removed from the child; the
defaults strip both runtimes' session identities, including Claude Code's messaging socket.
Override that one only if you know why. `SHIPYARD_DRY=1` prints everything a child would get
and starts nothing.
