---
name: shipyard
description: "shipyard: run the repo's /ship skill in background terminals (agterm sessions when available, tmux windows otherwise) and supervise them. Use when one or more changes should each be driven end to end by their own background Claude session, with a status table every 10 minutes, stall and context-ceiling watchdogs, and questions or architectural decisions escalated back to this session. Requires a /ship skill in the repo — it launches nothing else, and the stage names come from that skill, not from here."
---

# shipyard: run ship in background terminals, monitor it, answer its escalations

A shipyard is where many ships are built at once. This skill runs the repo's own
**`/ship`** skill on your work, one change at a time in parallel: every change gets its
own terminal and its own git worktree, a background monitor posts a markdown status table
every 10 minutes and stops itself once everything is merged/closed, and — because
there is no human inside a child terminal — the child escalates every question and
every architectural decision **up to this session**, waits for your answer, and only
then acts on it.

**`shipyard` launches exactly one thing: `/ship`.** It is not a pipeline of its own and it
knows nothing about the stages — `/ship` owns all of them and takes a free-text idea, a
`#N` issue, or an MR/PR number as its argument. `shipyard` only starts it, watches it, and
carries its questions to you. The repo must provide that skill; if it does not, `shipyard`
has nothing to run. In Claude Code that dependency is declared in this plugin's manifest
(`"dependencies": ["ship"]`), so the CLI resolves it; Codex has no equivalent field, so
there the requirement lives in prose only.

Skill arguments:
* `/shipyard 108 104` — continue existing MRs/PRs by number;
* `/shipyard "#42"` — start from an existing issue;
* `/shipyard "add X to Y"` — a brand-new change from a free-text idea, handed to `/ship` as-is;
* `/shipyard 108 no-merge` — extra ship flags (`no-merge`, `merge`, `effort <level>`) go through verbatim;
* `/shipyard` — no arguments: monitor-only over the ship terminals that already exist (Step 0).

Run it from the **main worktree** of a git repo.

## Backends: auto → agterm, else tmux

A child needs a terminal the parent can read from and type into. Two provide that, and
everything in this skill goes through one abstraction (`shipyard-backend.sh`), so a slot
behaves identically on either:

| | agterm (preferred by `auto`) | tmux (fallback) |
|---|---|---|
| container | workspace **`<your workspace>-ai`** | session `<repo>` |
| a child | session `ship-<slot>` | window `ship-<slot>` |
| worktree | `.claude/worktrees/ship-<slot>` | same |
| addressed by | session UUID | `<session>:<index>` |
| sidebar glyph | yes — `active`/`blocked`/`completed` | none |

Select with `SHIPYARD_BACKEND=agterm|tmux|auto`. The default is **`auto`**: agterm whenever an
agterm app is answering its control socket, else tmux. When **neither** is available `shipyard`
stops with an error naming both — it has no third way to reach a child, and a skill that
"starts" work it cannot see or type into is worse than one that refuses. A misspelled
`SHIPYARD_BACKEND` gets its own error rather than the not-installed one.

### Which workspace children land in

Children go **beside the work**: the agterm workspace the parent watcher is sitting in,
plus `-ai`. Launch from workspace `myproject` and they appear in `myproject-ai`. The suffix
keeps them out of the workspace you keep your own tabs in, and it never stacks — launching
from inside `myproject-ai` (a child starting a sibling) stays `myproject-ai`.

Resolution order, first hit wins:

1. `SHIPYARD_WORKSPACE` (agterm) / `SHIPYARD_SESSION` (tmux) — an explicit override;
2. the name **pinned** at the first launch, in `<mailbox>/container-<backend>`;
3. freshly derived — the parent's workspace `-ai`, or `<repo>-ai` when there is no agterm
   around (a plain shell, cron, another terminal). tmux is always `<repo>`, unchanged, so
   ship windows keep sharing one session with your own.

**Step 2 is the load-bearing one.** The derived name depends on *where the caller was
sitting*, so re-deriving it later — a report run from another workspace, a script run from
inside a child — would name a different container and honestly report that it holds no
children. That is the worst thing a monitor can do, so the name is written down at the
first launch and every later script reads it. `shipyard-down.sh` erases the pin once the last
child is gone, so the next run picks a fresh workspace; to repoint sooner, delete
`<mailbox>/container-<backend>` or pass `SHIPYARD_WORKSPACE`.

A caveat that comes with reading the environment: `AGTERM_*` is inherited by every
descendant, long-lived daemons included. A launch driven from a process that some *other*
session started resolves that session's workspace. The pin means you find out once, at
launch, in the line it prints — not three hours later.

On agterm you also get a state glyph per child in the sidebar. Each report tick paints
it (`blocked` + blink = it is waiting on YOU, `completed` = merged/closed/ready-to-merge,
`active` otherwise) and the child's protocol tells it to keep its own glyph current, so
the board is readable at a glance without the table.

**Do not call `agtermctl` or `tmux` directly from this skill's flow.** Every script
here goes through `shipyard-backend.sh`; reaching around it is how one backend silently stops
being supported.

## The child's Claude identity — `CLAUDE_HOME` / `CLAUDE_CONFIG_DIR`

**A child does not inherit this session's environment.** agterm spawns it from the app
(the GUI environment) and tmux spawns it from a server whose environment was frozen
whenever that server happened to start. Either way, nothing you have set here reaches it
by itself, and the child's login profile then supplies whatever value it likes.

That matters for exactly the variables that decide *which Claude the child is*:
`CLAUDE_HOME` and `CLAUDE_CONFIG_DIR` select the config dir, hence the skills, settings
and memory it loads. A parent running under a non-default config dir whose child falls
back to the profile default gets a child with **different skills — possibly no `/ship`
at all**, which surfaces as a child that starts, looks healthy, and does something else
entirely.

So `shipyard-launch.sh` writes a **launcher script** and re-asserts those variables inside it,
*after* the login profile has run:

* propagated (only when set here): `CLAUDE_HOME`, `CLAUDE_CONFIG_DIR` — extend with
  `SHIPYARD_ENV_PASS="VAR1 VAR2"`;
* scrubbed always: `CLAUDECODE`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_SESSION_ID`,
  `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_PID`, `CLAUDE_CODE_MESSAGING_SOCKET`,
  `CLAUDE_CODE_MESSAGING_TOKEN`, `CLAUDE_EFFORT`, `SHIPYARD_SLOT` — these are *this* session's
  identity, and handing a child the parent's messaging socket points it at the parent's
  own IPC channel.

Launch prints the propagated set (`env: CLAUDE_HOME=… CLAUDE_CONFIG_DIR=…`) and records
it in `<mailbox>/launch-<slot>.json`. **Read that line.** If a child is behaving as if it
has the wrong skills, the answer is usually there — and if a value drifted after launch
(you changed config dirs mid-flight), the fix is to re-launch the slot, not to patch the
running child: the variable was read at startup.

`SHIPYARD_BACKEND=tmux` additionally scrubs `AGTERM_*` before the tmux server is born. A server
started from inside an agterm session captures those and hands them to every process it
ever spawns, so a child's status hook would report against whichever session happened to
start tmux.

## A slot

A **slot** is the key of a terminal + worktree. For an existing MR/PR/issue it is the
number (`108`, `!108`, `#42`, or a URL — all collapse to the number, and the `#`/`pr`
marker is preserved because a bare number is ambiguous to a GitHub-native `/ship`). For
a new change from free text it is a slug of that text, cut to 28 chars (Cyrillic
collapses away, so the slug can end up short — that is fine, it is only a name). A
duplicate numeric slot is refused (two Claudes in one worktree collide); a duplicate
text slot gets a `-2` suffix.

## Step 0. `/shipyard` with no arguments — monitor only

Ship has no "inbox" (work comes from a human, not from the forge), so the no-argument
mode is just the report: `bash <SKILL>/shipyard-report.sh` with no arguments finds every
`ship-*` terminal in the container by itself. Then go to Step 2 (same monitor, no slot
list in the command).

## Step 1. Launch (with dedup)

For each target in the arguments:

```bash
bash <SKILL>/shipyard-launch.sh <number | "#42" | "idea text"> [ship flags...]
```

The script checks we are in a git repo and not in `$HOME`, computes the slot, writes the
escalation protocol and the launcher for that child, creates the container if missing,
and prints `SLOT:<slot>` as its last line — **record the slots, the report needs them**
(for free text the slot is not your argument, and a repeat launch may have suffixed it).

Exit codes: `0` started, `3` a terminal for that numeric slot already exists (do not
start a duplicate — look inside with the command the error prints), `1`/`2`
environment/argument error.

What it launches:

```
claude -w ship-<slot> --effort max -n ship-<slot> --permission-mode auto \
  --remote-control ship-<slot> --append-system-prompt "$(cat <mailbox>/protocol-<slot>.md)" \
  '/ship <target> [flags]'
```

**`--permission-mode auto` is deliberate, and it is the child's whole risk posture.** A
background session that stops to ask permission is a background session that sits idle until
someone notices, so a child gets its tools auto-granted: it works in a worktree of the repo
and pushes to the forge with no human in its terminal. What makes that acceptable is the
pairing — `/ship` escalates anything risky or irreversible rather than deciding, and the
parent watcher is the human it escalates to. Launching children and then not reading their
escalations removes the only judgement in the loop. Say this out loud to anyone you set this
up for; it is the one property of the skill that is not recoverable after the fact.

`SHIPYARD_DRY=1` prints the slot, the protocol path, the propagated env and the whole launcher
without starting anything — use it when you are unsure what a child will get.

The primary path for anything needing a human is the escalation mailbox (Step 3);
`shipyard-tell.sh` (Step 4) is the way back when the child did not ask. `--remote-control` is
left on as a manual escape hatch for a human at another client — it has no send-side CLI,
so do not plan on driving it from here.

## Step 2. Monitor every 10 minutes

`<SKILL>/shipyard-report.sh [<slot> ...]` builds the report:
* running-vs-idle from a snapshot DIFF (two captures 3s apart), not spinner glyphs;
* the MR/PR number of a text slot is read from `.pipeline-state/*.json` inside the
  worktree — before it exists the column says `no MR yet`;
* `MR state / stage` — forge state plus ship's own pipeline stage;
* `esc` — open escalations for that slot, and the full escalation block is appended
  under the table;
* on agterm, it also repaints each child's sidebar glyph;
* whole report in one block → Monitor batches it into one notification;
* exit 0 = nothing in flight **and** no open escalation → stop the loop; exit 1 = work
  is still open.

Arm the status monitor (`Monitor`, `persistent: true`), substituting the slots:

```bash
SCRIPT=<SKILL>/shipyard-report.sh
while true; do
  bash "$SCRIPT" --only-changed <slot> [<slot> ...] && { echo "__all changes shipped — exiting monitor__"; break; }
  sleep 594   # 594 + ~6s for two 3-second captures ≈ 10 min
done
```

`--only-changed` is what makes this monitor liveable. Ship spends much of its life parked
in `⏸ idle/wait` on a pipeline or a self-review round, so without it the loop emits the
same table every 10 minutes for hours and the real events drown in it. With it the tick
is silent until the MR state, the pipeline stage, the escalation count, the MR number or
the terminal's presence actually moves — and the terminal report is always printed. Drop
the flag only when you want a heartbeat for its own sake.

**`--only-changed` cannot hide a stall.** Silence and death have the same shape here: a
child that hit its context ceiling, or that was compacted and never told to resume, sits
`⏸ idle/wait` with `esc —` while NOTHING changes — so a change-triggered monitor says
nothing at all. One ran that way for **8.5 hours**. The report therefore tracks how long
each slot has been motionless and prints a loud `🛑 STALLED` block, bypassing
`--only-changed`, once an idle slot with no open escalation has not moved for 30 minutes
(`SHIPYARD_STALL_SECS` to tune). Treat that block as an alarm, not as a status line.

Arm the **fast escalation monitor** too — 10 minutes is too slow for a child that is
blocked on a question:

```bash
SCRIPT=<SKILL>/shipyard-escalations.sh
while true; do
  bash "$SCRIPT" --new
  sleep 45
done
```

`--new` prints only escalations not shown yet (and marks them), so this monitor stays
silent until something actually needs you. Description: "ship escalations (fast)".

* Both scripts are separate files, so edits land on the next iteration — unlike an
  inline `while` body, which bash caches (editing a running monitor does nothing;
  `TaskStop` and re-arm).
* The status monitor exits by itself when `shipyard-report.sh` returns 0. Stop either one
  manually with `TaskStop`.

**Mirror what the monitors emit as a normal message.** Monitor events arrive as system
`task-notification`s (the "NOT USER INPUT" banner) — the client collapses them and the
user does not see them, so anything not reprinted in an ordinary reply never reached
them. Surface an escalation immediately (see Step 3).

But mirror **changes, not ticks**. `--only-changed` already keeps the monitor quiet, so
in practice every table that arrives is worth reprinting. If you do get an unchanged
table anyway (heartbeat mode, a `⏸`/`▶️` flip, an escalation count settling back to 0),
do not reprint it — a wall of identical tables buries the one line that matters. Say
nothing, or fold it into one short sentence when the user asks. `⏸ idle/wait` on `apply`
or `archive` (work in progress, or CI still green-lighting the head) is a normal resting
state of a healthy ship session, not news.

**Know which stages can resolve themselves and which cannot.** `/ship` is **self-driven**:
it runs every review pass itself, as subagents, so a review stage is WORK, not a wait —
nothing external needs launching, ever.

**Do not trust this paragraph for the state names.** The bundled `/ship` uses
`need-issue`, `issue-ready`, `spec-review`, `apply`, `impl-review`, `archive`,
`ready-to-merge`, `needs-human`, `done` — with the spec-review and archive stages skipped in
a repo that keeps no spec artifact. But a repo may carry its own `/ship`, and this file is a
copy of nothing: **read the state enum in the `/ship` you are actually running.**

`ready-to-merge` resolves itself only where repo policy lets ship merge; where it does not,
a child parked there is finished and waiting for the human. `needs-human` never resolves
itself anywhere. Both are news; the rest are not.

Two lessons from how this file was wrong before, kept because the failure shape recurs:

* It named a stage that existed in no version of `ship` and called it a normal resting
  state. Believing in a stage absent from the skill's own state enum is how a real stall
  reads as business as usual. That is why the enum above comes with the instruction to go
  and check it — a copy of an enum is a copy, and copies rot.
* When `ship` still had a stage that waited on an external reviewer, nothing started that
  reviewer automatically. A child sat in that stage with `esc —` and a green board,
  indistinguishable from healthy waiting, until a human noticed. **If a stage waits on a
  second actor, check that something actually starts that actor.** A wait nobody
  satisfies is invisible from outside. The bundled `/ship` has no such stage left, by
  design; if you point `shipyard` at a `/ship` that does, that stage is the first place to
  look when a child goes quiet.

## Step 3. Answer escalations (this is the point of the skill)

A child session has no human. Its questions, its architectural decisions, its blockers
all land in a shared mailbox at `.git/ship-escalations/` (inside the **common** git dir,
so the same path resolves from the main worktree and from every `ship-*` worktree; never
committed).

When an escalation arrives:

1. **Surface it to the user right away** — do not sit on it, the child is blocked.
   Reprint the block as a normal message. For a `question` or `decision` with clear
   options, `AskUserQuestion` is the right tool here (the human IS in this session);
   put the child's recommendation first.
2. Write the answer back:
   ```bash
   bash <SKILL>/shipyard-answer.sh <id> "<the answer / the decision>"
   ```

   **For anything longer than a line, or containing backticks or `$(...)`, pass a file
   instead — `@<path>`, or `@-` for stdin:**

   ```bash
   bash <SKILL>/shipyard-answer.sh <id> @"$BODY"  # BODY=$(mktemp)
   ```

   The payload is a shell ARGUMENT, so your own shell expands it before the script runs:
   in a double-quoted string `` `foo` `` is command substitution and `$(x)` / `$VAR`
   expand. An identifier in backticks is replaced by the output of *running* it — usually
   nothing. The record is then written and looks fine, minus the words that mattered.
   This is not theoretical: it has eaten a term out of a child's escalation ("the two
   overlapped and&nbsp;&nbsp;could not dedupe them") and out of a parent's decision
   ("#N IS THE TRAP.&nbsp;&nbsp;inside a transaction is rejected"). Both read as merely
   clumsy rather than corrupted, which is exactly what makes it expensive to notice.

   `shipyard-tell.sh` takes `@file` / `@-` too, and the child side has `--context-file` /
   `--text-file` on `shipyard-ask.sh`. Reach for them by default for technical content; the
   literal argument is for short one-liners.
   The child picks the answer up within ~5s and continues — for a `question` or a
   `decision` you never type into its terminal.
3. `bash <SKILL>/shipyard-answer.sh --list` shows every escalation and its status.

Kinds, and what the child is instructed to escalate:

| kind | blocking | what it is |
|------|----------|------------|
| `question` | yes | anything needing a human: ambiguous or conflicting requirements, missing acceptance criteria, the shape of a free-text change before a spec can be written, a blocker it cannot clear (auth, permissions, red pipeline, review findings it disagrees with), anything risky or irreversible (prod, data migrations, secrets, force-push, CI/CD) |
| `decision` | yes | an **architectural / design decision**: module boundaries, data model or schema, a new dependency or service, API/contract shape, migration or rollout strategy, sync vs async — anything expensive to reverse. Escalated **before** it is written into the design/spec artifacts, and `--context` (options + trade-offs + recommendation) is mandatory |
| `notice` | no | milestones: MR/PR opened, a review pass posted blocking findings, pipeline failed, change archived, merged, child stopped |

Anything else in the mailbox (`directive`, `launch`) is **not** an escalation — the
viewers allow-list the three kinds above, so a new record type can never masquerade as an
open question that nobody can answer.

Do not answer a `decision` on the user's behalf. Relay it, get the call, pass it back
verbatim — that is the whole reason it was escalated instead of decided in the child.

## Step 4. Speak first — `shipyard-tell.sh`

The mailbox is a **child-initiated** channel: the child creates a record and polls it, you
fill in the answer. That covers `question` and `decision` and nothing else. It does NOT
carry:

* a reply to a **`notice`** — fire-and-forget by construction, the child never polls it,
  so `shipyard-answer.sh` on a notice writes an answer that is read by nobody;
* a reply to a record already **`done`** — the child consumed its answer and moved on;
* anything **you** want to say that the child never asked about: "also fix the MR
  description", "don't merge yet", "the other session already pushed that".

For those, the channel that reaches a running child is its own terminal — Claude Code
takes a typed message and queues it if it is mid-turn:

```bash
bash <SKILL>/shipyard-tell.sh <slot | escalation-id> "<the directive>"
```

It records the directive in the mailbox (`directive-<slot>-<n>.json` + `.txt`), flattens
it to one line (a literal newline would submit early), sends it, and reports
`delivered` / `queued` / `unconfirmed` from a before/after screen diff. A long directive
is written to the `.txt` and the child is told to read that file. An escalation id is
accepted and resolves to its slot, so you can answer the notice you were just shown with
the id you were shown. Exit 3 = no live terminal for that slot (the child is gone).

`shipyard-answer.sh` knows this: on a `notice` or a `done` record it does **not** pretend to
have answered — it hands the text to `shipyard-tell.sh` and says so. `--no-tell` forces the old
write-the-record-only behaviour.

The child's protocol tells it that a `[supervisor directive]` message is the human's
instruction, authoritative over its current plan, and to send a `notice` back when done.

Directives are `kind: directive`, `status: sent` — the report's `esc` column and the fast
monitor both skip them, so telling a child something never looks like an open escalation.
`bash <SKILL>/shipyard-tell.sh --list` shows what you have sent.

## Step 5. Compact a child BEFORE it hits its context ceiling

A ship child accumulates context for as long as it works, and a long change will reach
the ceiling. What makes this dangerous is the failure mode: the session does not crash
and does not say anything. It **silently stops accepting turns** — you type, the text
sits in the input box, nothing happens. In the report it reads as `⏸ idle/wait` with
`esc —`, which is exactly what a healthy child waiting on CI looks like. One ran that way
for **8.5 hours** overnight before it was noticed.

**The tell is the `ctx` column**, and the footer states it in one of TWO forms — the
client changed this under us, silently. Older builds print a session token total, which
the report bands as `⚠️` from 400k and `🛑` from 550k; current ones print a percentage
(`98% context used`), banded `⚠️` from 65% and `🛑` from 80%. The percentage is preferred
when both are present, because it needs no assumption about the model's window size —
the token thresholds hardcode one, and on a 1M-token model they are simply wrong.

Reading only the token form is not a cosmetic gap: this column showed `—` for a whole
night while a child sat at 98%, so the one signal this step depends on was switched off
by a rename, with no error anywhere. The footer also starts showing
`/clear to save NNNk tokens` — that hint means the ceiling is close, not that `/clear` is
the answer.

**Act on `⚠️`, do not wait for `🛑`.** Compaction needs working room; at the ceiling it is
itself an API call that may fail or retry for a long time.

**Use `shipyard-compact.sh` — it does BOTH halves.** Compaction is a slash command in the TUI,
so the mailbox cannot carry it (`shipyard-tell.sh` prefixes and flattens its payload into a
`[supervisor directive]` message, which is not the same thing). And on its own it is only
half the job:

> **A compacted child comes back with an empty context and then SITS IDLE.** It does NOT
> resume by itself. Compacting and walking away leaves a child that reports no escalation,
> looks perfectly healthy, and does nothing — the same signature as the ceiling stall you
> just cured.

```bash
bash <SKILL>/shipyard-compact.sh <slot>                        # compact, wait, then resume
bash <SKILL>/shipyard-compact.sh <slot> --resume-file <path>   # with your own resume brief
bash <SKILL>/shipyard-compact.sh <slot> --no-resume            # only if you will drive it yourself
```

**Constraints the child must not lose belong in a standing-orders file**, not in a
directive. A directive is a message: it lives in the child's context and dies with the
next compaction, so a hard rule delivered that way ("do not merge — the human wants to
check it locally first") is silently lifted by the very operation meant to keep the child
working. Write it to `<mailbox>/standing-orders-<slot>.md`, tell the child to re-read that
file after every compaction and before any irreversible action, and `shipyard-compact.sh` will
point every resume brief at it automatically.

Prefer `--resume-file` for a long change: a resume brief that names where the child
actually is (HEAD, pushed state, task count — read from git, not from its own last
summary) stops it re-deriving the whole change from scratch on an empty context.

Exit 5 means the child was still mid-turn when the wait ran out: `shipyard-compact.sh` will NOT
drive a terminal during a turn, because the Escape it sends to clear the input box is
INTERRUPT while one is running — it would kill the work in flight. Re-run when idle.

Exit 4 means no `Compacted` marker appeared before the timeout — the session is past the
point of accepting even a slash command. Then recover the way a dead child is recovered: a
FRESH session on the SAME worktree plus a written handoff file. Check `git status` and
`git log origin/<default-branch>..HEAD` there first — a stalled child has usually committed and pushed
more than its last notice reported, so nothing is lost. **`/clear` is never the answer** —
it throws away exactly what you are trying to keep.

If you drive the terminal by hand instead, three facts that each cost a wrong diagnosis:

* **`Escape` clears the input box.** Do not erase with backspace — past the start of the
  line it restores a PREVIOUS draft, so a box you believe you emptied comes back
  populated. `C-u` is UNDO here, not clear-line.
* **Submission is `Enter` on some builds and `KPEnter` on others**, and a session AT its
  ceiling refuses both. `shipyard_submit <slot> alt` sends the second form. Try one, look, try
  the other.
* **Confirm by the FOOTER flipping to `esc to interrupt`**, never by the box looking
  empty — a capture can hand back a stale frame.

## Step 6. Teardown, after a merge

MERGE (or close) is the only teardown signal. Never tear a slot down early: a child
re-wakes itself and continues after long idle pauses, and the worktree goes with it.

```bash
bash <SKILL>/shipyard-down.sh --list        # what exists and whether it is safe
bash <SKILL>/shipyard-down.sh <slot>        # close the terminal, remove the worktree, prune
bash <SKILL>/shipyard-down.sh <slot> --force
```

It refuses a slot with uncommitted changes or with commits not in its upstream, and says
what to look at; `--force` overrides both. It removes the worktree with a DOUBLE `-f` (one
for dirty, one for locked — a single `-f` fails on a lock with a message that reads like a
permissions problem), prunes, and on agterm drops the `-ai` workspace — plus its pinned
name — once it holds no ship sessions. The change's feature branch can go afterwards
(`git branch -d <branch>` — `-d` refuses an unmerged branch, which is what you want after a CLOSE rather than a merge).

## What the table shows

| column | meaning |
|--------|---------|
| slot | terminal/worktree key (number or slug) |
| MR | `!<number>` once the MR/PR exists |
| term | tmux window index, or the agterm session-id prefix |
| session | ▶️ running / ⏸ idle-wait (snapshot diff) / ⛔ no terminal |
| MR state / stage | forge state (opened/merged/closed) + ship's pipeline stage |
| esc | open escalations for this slot |
| ctx | child context usage; `⚠️` ≥65% / ≥400k, `🛑` ≥80% / ≥550k — compact it (Step 5) |
| last line | last meaningful line of the screen |

⏸ idle-wait is **normal** for ship: it waits on CI or on a self-review round and re-wakes
itself. Never read idle as "it died" — the only completion signal is a merged (or closed)
MR. A child blocked on an escalation also looks idle; the `esc` column is what tells you it
is waiting on *you*. A child that has hit its context ceiling ALSO looks idle, with
`esc —`; the `ctx` column is what tells you it has stopped accepting turns rather than
waiting for something (Step 5). `/ship` never waits for an approval, so a session parked
for a long stretch with a green pipeline and no escalation is worth a look — check its
stage for `needs-human` or `ready-to-merge`.

## There is no companion reviewer session

This skill once had a twin that ran a separate `/review` session against each push, and the
two coordinated only through forge state. **That pairing is retired.** `/ship` reviews its
own work with subagents, so a `shipyard` run needs nothing beside it, and starting a second
session to review the first does nothing for the pipeline.

The reason to say so out loud: the retired design is the one that produced this skill's
worst failure — a child parked in a stage that waited for a reviewer nobody had started,
looking exactly like a healthy wait. If you ever find yourself launching a second session
to unblock the first, that is the bug, not the fix.

Children of other kinds can still share one container: a slot is keyed by name
(`ship-<slot>`), so unrelated sessions in the same workspace or tmux session do not
collide with it.

## Files

| file | role |
|------|------|
| `shipyard-backend.sh` | the agterm/tmux abstraction — every terminal operation goes through it |
| `shipyard-lib.sh` | mailbox paths, slot resolution, payload input, the child env preamble |
| `shipyard-launch.sh` | start a child: slot, protocol, launcher, container |
| `shipyard-report.sh` | the status table + stall watchdog + sidebar glyphs |
| `shipyard-escalations.sh` | the escalation view (`--new` for the fast monitor) |
| `shipyard-ask.sh` | CHILD side: raise a question / decision / notice |
| `shipyard-answer.sh` | PARENT side: answer one |
| `shipyard-tell.sh` | PARENT side: speak first, into the child's terminal |
| `shipyard-compact.sh` | compact a child AND put it back to work |
| `shipyard-down.sh` | teardown after a merge |

## Reminders

* Do not tear a terminal/worktree down before the MR is actually merged — ship re-wakes
  itself and continues after an idle pause (Step 6).
* glab: `OAUTH_TOKEN` must be unset (the scripts do that themselves); the host comes from
  the origin remote.
* The scripts are runnable by hand from a shell too — nothing here needs the skill runtime
  to be useful.
* The mailbox directory (`.git/ship-escalations/`) and the slot prefix (`ship-<slot>`) are
  named after `ship`, not after this skill, and that is deliberate: they are the protocol
  between a parent watcher and a `/ship` child, so a rename here must not touch them. A
  live run's mailbox is the one place where renaming would orphan work already in flight.
