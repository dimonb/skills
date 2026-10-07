# shipyard

A shipyard is where many ships are built at once. This skill runs the repo's own
[`ship`](../ship) skill in background terminals and supervises a fleet of them: **one
terminal and one git worktree per change**, a status table on a timer, and — because there is
no human inside a background session — every question and every architectural decision
carried back to the session you are sitting in.

```

Use `/shipyard` in Claude Code and `$shipyard` in Codex. The child runtime matches the
runtime that invoked the skill: Claude Code launches Claude Code, while Codex launches Codex.
`SHIPYARD_AGENT=agy` launches Antigravity's `agy` instead, with the degradations SKILL.md lists
(no ctx figure, no delivery confirmation, no `/compact`, and a trust prompt to answer per child).
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
deduplicated (two agents in one worktree collide); text slots get a numeric suffix. When the
backend cannot say whether a slot is taken, the launch is refused rather than guessed. A slot
name must be letters, digits, `-` and `_`, starting with a letter or a digit, and short enough
for the agent's worktree-name limit (`shipyard_slot_check` in `shipyard-backend.sh` holds the
exact rule); anything else is refused before anything is created.

**A launch this machine cannot take is refused before it starts.** Each launch clears an
admission gate first — a **concurrency cap** (`SHIPYARD_MAX_SLOTS`, default 2 live `ship-*`
slots) and, on macOS, a **memory-pressure floor** (`SHIPYARD_MEM_MIN_FREE_PCT`, default 10%
free, read from `memory_pressure`). Over either limit and the launch is refused, with a
distinct exit code and a message naming the gate, the current value versus the limit, and the
env var to override it — no worktree or terminal is created. The gate exists because an
uncapped fleet once drove a 16 GB machine into swap until macOS recycled the whole GUI login
session; it is that "stop the bleeding" check, not a scheduler. A slot count the backend cannot
answer is refused as well, since an empty answer is not an empty fleet. Where `memory_pressure` is
unavailable the memory gate is a no-op, never a hard failure. `SHIPYARD_DRY=1` reports the
gate's decision without enforcing it.

**Two backends behind one abstraction.** [agterm](https://github.com/umputun/agterm) sessions
when an agterm app is answering its control socket, tmux windows otherwise, selected by
`SHIPYARD_BACKEND=agterm|tmux|auto`. Every terminal operation goes through a single script, so
a slot behaves identically on either; when neither is available the skill refuses rather than
"starting" work it cannot see or type into.

**A monitor that stays quiet until something happens.** The status table reports running
versus idle from a snapshot diff rather than spinner glyphs, and `--only-changed` keeps it
silent until a state, stage, escalation count, ctx band (including the bound's own band while the window is unpinned), terminal presence or the reason a
slot is motionless actually moves.

**...and that never mistakes silence for completion.** Exiting 0 is how the report tells the
monitor to stop watching, so it is earned rather than assumed: an empty answer ends the run only
when the terminal backend actually answered — asked again at the moment the decision is taken, not
sampled at the top of a tick — and, where a container pin survives to say so, when it was the
backend this fleet was launched on. A control socket that blips, or an `auto` choice that lands on
the other backend for one tick, raises a `🛑 NO SIGNAL` block and keeps the loop alive instead of
reporting that everything shipped. The same principle one level down decides that a motionless
child is not a dead one.

The pin half is a *disagreement* check, so it is only as good as the pin: a mailbox that never
launched a fleet through `shipyard-launch.sh`, or whose pin was deleted by hand, has nothing to
disagree with and falls back to the reachability half alone.

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

**And the alarm asks why before it fires.** Motionless is not the same as stuck: a child can
be unable to move (a capacity wait its client announced) or simply not have been asked (it is
finished, or stopped at `needs-human`). Those get their own row and their own block, never a
compaction prescription, and the stall clock also restarts after a gap in supervision, because
time nothing was watching is not motionlessness the report can attest to. Whatever is left —
idle, announcing no reason, at no stage that waits by design — still raises the loud block.
The skill's Step 2 has the table.

**A mailbox, not a guessing game.** A background session has no human in it, so it escalates
instead of deciding: `question` and `decision` block until you answer, `notice` is
fire-and-forget. Records live in a mailbox inside the shared git directory, so the same path
resolves from the main worktree and from every child worktree, and it is never committed.
You answer with one command and the child picks it up within seconds — you never type into its
terminal for a question it asked.

**A way to speak first.** The mailbox is child-initiated, so it cannot carry a reply to a
`notice` or anything the child never asked about. For that there is a directive channel that
types into the child's terminal, records what was sent, and then confirms delivery by polling
the child's own turn state — so a directive left sitting unsent in the input box comes back
`unconfirmed` and non-zero rather than reported as delivered.

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
| `shipyard-agent.sh` | select and launch the child runtime that matches the parent — which kinds shipyard admits, and what it hands the shared adapters |
| `agent-adapters.sh` | vendored copy of the shared per-agent-kind adapters (`shared/adapters/agent-adapters.sh`), shared with `council`: launch knowledge, plus the turn-state read and delivery verdict that confirm a directive actually landed |
| `shipyard-backend.sh` | the agterm/tmux abstraction — every terminal operation goes through it |
| `shipyard-lib.sh` | mailbox paths, slot resolution, payload input, the child env preamble |
| `shipyard-continuity.sh` | automatic capacity retry and paused-goal continuity for a Codex parent in agterm |
| `shipyard-launch.sh` | start a child: slot, protocol, launcher, container |
| `shipyard-admission.sh` | the pre-launch admission gate: concurrency cap + macOS memory-pressure |
| `shipyard-report.sh` | the status table, stall watchdog, sidebar glyphs, and the teardown of a finished slot |
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
Code uses `--permission-mode auto`; Codex uses `--approve-for-me`; agy uses
`--dangerously-skip-permissions`. A background session that
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
- **A bash 5 or newer on the machine**, at `/opt/homebrew/bin/bash`, `/usr/local/bin/bash` or
  `/usr/bin/bash`, or as the first `bash` on the `PATH` shipyard builds (`shipyard-lib.sh` puts
  Homebrew, MacPorts, `/usr/local/bin`, `/usr/bin` and `/bin` ahead of yours, so on a Mac a bash 5
  that lives only in a directory of your own `PATH` is not found — link it into one of those). The status report itself runs under macOS's stock
  `/bin/bash` 3.2, but the slot graph it consults for each live slot, `shipyard-slot-graph.sh`,
  re-executes itself in a bash >= 5 and refuses without one. On a stock Mac install one beside
  the system bash (`brew install bash`); do not replace `/bin/bash`. Without it the report still
  runs, but no slot's completion can be read: every live row says `completion unreadable`, its
  glyph stays `active`, and each report run prints one stderr line saying so.
- A `ship` skill in the repo — see above.
- The CLI matching the parent runtime on `PATH`: `claude` for Claude Code or `codex` for Codex
  (`agy` when `SHIPYARD_AGENT=agy`, with the repo's `ship` skill under `.agents/skills/`).
- `gh` or `glab`, authenticated, for the status table's forge lookups. `GH_CONFIG_DIR` is
  honoured from your environment when set and otherwise left to `gh` — there is no default
  pointing at anyone's machine. `GITLAB_HOST` defaults to the host in the `origin` remote.

Environment knobs: `SHIPYARD_AGENT`, `SHIPYARD_BACKEND`, `SHIPYARD_WORKSPACE`, `SHIPYARD_SESSION`,
`SHIPYARD_ENV_PASS`, `SHIPYARD_ENV_SCRUB`, `SHIPYARD_SLOT`, `SHIPYARD_FORCE`, `SHIPYARD_DRY`,
`SHIPYARD_EFFORT`, `SHIPYARD_MAX_SLOTS`, `SHIPYARD_MEM_MIN_FREE_PCT`, `SHIPYARD_STALL_SECS`,
`SHIPYARD_CTX_WINDOW`, `SHIPYARD_TELL_MAXLINE`, `SHIPYARD_TELL_CONFIRM_SECS`,
`SHIPYARD_TELL_CONFIRM_INTERVAL`, `SHIPYARD_TELL_DEDUPE_SECS`, `SHIPYARD_TELL_SETTLE_DELAY`,
`SHIPYARD_MOTION_INTERVAL`, `SHIPYARD_ASK_TIMEOUT`, `SHIPYARD_DOWN_FETCH`, `SHIPYARD_AUTODOWN`,
`SHIPYARD_AUTODOWN_TICKS`, `SHIPYARD_FORGE_TIMEOUT`.

`SHIPYARD_FORGE_TIMEOUT` (default 20, whole seconds) bounds each `gh`/`glab` call the status
report makes, so a hung forge client costs its deadline and the one cell it was asked for, not
the whole tick's report.

`SHIPYARD_TELL_DEDUPE_SECS` (default 600, `0` off) is how long `tell` refuses a directive that
repeats one already sent to the same slot with the same reply target, with exit 9; `--again` sends
it anyway.

The last two of the `TELL`/`MOTION` group are timing: `SHIPYARD_MOTION_INTERVAL` (default 3) is
how long the report waits between the two captures of its motion diff, paid once per live slot
per report, and `SHIPYARD_TELL_SETTLE_DELAY` (default 1) is how long `tell` waits between
typing a directive and submitting it, so the client registers the line first. Both exist so the
test suites can stop paying a wait a faked backend has no use for; the defaults are the
production values and are not changed by setting them.

`SHIPYARD_MAX_SLOTS` (default `2`) and `SHIPYARD_MEM_MIN_FREE_PCT` (default `10`) are the two
admission-gate knobs — the concurrency cap and the macOS free-memory floor a launch must clear.
See **A launch this machine cannot take** above.

`SHIPYARD_DOWN_FETCH` (default `1`) allows the teardown gate one `git fetch` of the base branch
per invocation, so a slot torn down seconds after its merge is not refused over a
remote-tracking ref this clone has simply not seen yet. Set it to `0` to keep teardown offline.

`SHIPYARD_AUTODOWN` (default `1`) lets the monitor finish a slot off for you: once its PR/MR has
read `merged` on `SHIPYARD_AUTODOWN_TICKS` consecutive ticks (default and minimum `2`), ship's own
stage is terminal, its terminal is gone (and the backend corroborates that) and no escalation is
open, the report calls `shipyard-down.sh` — unchanged, with no flags and never `--force` — which
removes the worktree. A slot whose terminal is still up is never torn down automatically, whatever
its screen shows; `shipyard-down.sh <slot>` stays the way to finish it. **The branch is never
touched**, so the work is recoverable from it either way. Anything the gate declines is named in
its own block with the exact command; a slot held by an open question gets its own block naming
the records that hold it. Set it to `0` to keep teardown entirely manual; that also makes a
no-argument `/shipyard` run non-destructive — though not inert: the report still writes its
mailbox bookkeeping (truncating the consecutive-merged counts — with the teardown off, all of
them), repaints sidebar glyphs, closes pending notices, and re-arms the Codex parent continuity
watcher.

`SHIPYARD_CTX_WINDOW` pins the context window, in tokens as a plain integer, that the `ctx`
percentage is measured against. Without it, a Codex child's window is read from its own rollout
when one resolves, and otherwise — as for every Claude child — it is inferred from the largest
total the transcript has ever carried, since a request that carried N tokens cannot have run on a
window smaller than N. The override beats all of that, in both directions.

**Pin it for a Claude fleet.** Nothing names the model when a child is launched, so where the
inference has not yet ruled anything out and the reading would otherwise raise a glyph, the column
shows a bound (`❓ <=92% · 185k`) rather than a percentage it cannot defend. That bound is taken
against the smallest size the report still considers possible, so it is the tightest reading its
own list allows — it is **not** a guarantee the child is below it, since a window smaller than
anything listed under-warns the same way an unpinned window always has. For a child whose window
*is* the smallest size the report knows, the bound is its permanent reading above the warn
threshold: a peak cannot exceed the window that carried it, so the ambiguity never resolves on its
own. Setting this variable replaces the bound with an exact band, for good.

`SHIPYARD_EFFORT` (unset by default) is an operator's explicit `--effort` level for a Claude
child. Unset, the child is launched with no such flag: how hard to think and how deep to review
are `ship`'s decisions, made after its discovery step, and `shipyard` does not pre-empt them.

Three more are worth knowing about. `SHIPYARD_AGENT=auto|codex|claude|agy` defaults to matching
the parent runtime; set it explicitly when invoking the scripts from a shell with no parent agent
identity, or to launch agy, which `auto` never picks. `SHIPYARD_ENV_PASS` **replaces** the set of variables copied from your session
into a child — the runtime-specific default is `CODEX_HOME` or `CLAUDE_HOME CLAUDE_CONFIG_DIR`
(nothing for agy).
Name those again if you still want them, or the child may resolve a different config directory
and get different skills. `SHIPYARD_ENV_SCRUB` overrides the set removed from the child; the
defaults strip the runtimes' session identities, including Claude Code's messaging socket.
Override that one only if you know why. `SHIPYARD_DRY=1` prints everything a child would get
and starts nothing.

## Known limits

Limits a review found and recorded rather than filed: each is reachable only by a later edit or an
unsupported setup, not by ordinary use. Each names what would make it a defect worth an issue.

- **KL-1 — t15's failing floor arm is exercised by no automated run.** When
  `SHIPYARD_TEST_BASH32` names an interpreter that is not a bash 3.x, t15 fails rather than
  skipping; the macOS CI job always names a real 3.2 and the Linux job never sets it, so no run
  takes that arm, and the floors in t-policy and t-adapters lean on it.
  `plugins/shipyard/skills/shipyard/tests/t15-iid-fallback.sh:487`. Found by the review of #336
  (#337). *Promote when* an edit to the failing arm itself or to the 3.x detection above it is
  proposed, or a macOS runner image whose `/bin/bash` is not 3.x is announced: then the arm needs a
  CI step asserting it fails.
- **KL-2 — the helpers the report spawns are measured under bash 5 in CI, not 3.2.** The report
  starts `shipyard-slot-graph.sh`, `shipyard-escalations.sh` and `shipyard-down.sh` as
  `bash <script>`, and `shipyard-lib.sh` puts the Homebrew prefix first on `PATH`, so wherever a
  bash 5 is installed there (the CI job, and a Homebrew or `/usr/local` install as the Requirements
  above describe) they run under it. A Mac with no bash 5 on that `PATH` runs them under 3.2,
  where the escalations block would vanish silently (its stderr goes to `/dev/null`) if that script ever used a bash-4 construct; it
  uses none today. `plugins/shipyard/skills/shipyard/shipyard-report.sh:2317`. Found by the review
  of #336 (#337). *Promote when* a bash-4 construct lands in `shipyard-escalations.sh` or
  `shipyard-down.sh`, or when bash 5 stops being a requirement.
- **KL-3 — the continuity watcher's start path is measured under bash 5, not 3.2.** For a Codex
  parent on agterm the report calls `shipyard_continuity_start` in-process, so under `/bin/bash`
  3.2. The macOS CI job runs t7 and t21 with their test bodies in the runner's bash 5, so only the
  watcher their fake agtermctl launches runs under 3.2; the job's other shipyard steps use the tmux
  backend, where the start path returns at once, and its shared-module steps never reach it. It
  uses no bash-4 construct today.
  `plugins/shipyard/skills/shipyard/shipyard-continuity.sh:1115`. Found by the review of #340.
  *Promote when* a bash-4 construct lands in that start path, or a Codex parent on agterm reports a
  watcher that never started.
- **KL-4 — the stall record's `fired_epoch` and `last_fired` guards are pinned by no case.** A
  leading-zero value in `report-stall`'s fourth or seventh field is refused through `stall_num`
  before it reaches arithmetic, but t13's E6b corrupts them together with `since`, and a refused
  `since` keeps the slot from stalling, so neither guard's own arithmetic is reached. Only a peer
  write to the mailbox puts such a value there; the report writes canonical epochs.
  `plugins/shipyard/skills/shipyard/shipyard-report.sh:1597`. Found by the review of #237.
  *Promote when* the report itself writes a zero-padded or non-canonical number into
  `report-stall`, or a slot is seen to lose its alarm over a malformed record.
- **KL-5 — the `report-tick` octal refusal and the stall table's string compare are pinned by no
  fixture.** A leading-zero tick is refused rather than read as octal (`08` would abort the whole
  report), and the stall table matches slot names as strings so `43` and `043` stay apart. No test
  writes such a tick or such a pair of rows. The tick is written only by the report, and launched
  slot names carry no leading zero. `plugins/shipyard/skills/shipyard/shipyard-report.sh:688` and
  `:1591`. Found by the review of #237. *Promote when* a writer other than the report stamps
  `report-tick`, or slot names can begin with a zero.
- **KL-6 — the owner-hold launch and two temp names are FIFO-tested by nothing.** t21's NOT COVERED
  header names them: a FIFO at the owner-hold launch's log, a temp name swapped between `mktemp` and
  its open, and the start intent's own name. The owner-hold launch is opt-in and no production path
  arms it (SKILL.md, on `_SHIPYARD_CONTINUITY_OWNER_HOLD`); the other two need a deliberate swap
  inside a race window. `plugins/shipyard/skills/shipyard/tests/t21-continuity-fifo.sh:15`. Found by
  the review of #259. *Promote when* a production caller arms the owner hold: then t21's case 3
  gains an owner-hold variant, holding the write end the way t10's owner script does.
- **KL-7 — the canary's direct-read fallback has no test.** When no sentinel can be started,
  `canary_owner_gone` reads the canary itself, as it did before #275. t-canary drives the sentinel
  path, including a signalled sentinel being replaced rather than read as a death, but nothing makes
  `canary_sentinel_start` fail: that takes descriptor or process exhaustion, on either caller (the
  owner-hold watcher here, and council's `up --hold` keeper since #343).
  `shared/canary/canary.sh:78`, vendored as this skill's `canary.sh`. Found by the review of #281,
  and narrowed once #343 added the signalled-sentinel case. *Promote when* a sentinel is observed
  failing to start, or `canary_sentinel_start` gains a failure an ordinary run can reach.
- **KL-8 — two continuity readers are driven only with the plain `› cmd` spelling.** The
  capacity-state `*)` arm and `shipyard_continuity_finish_owned`'s ownership check read the prompt
  through `_adp_box_content`, which also accepts an NBSP-separated or `❯` prompt; t7 drives that
  wider spelling for `prompt_empty` alone. The watcher runs for a Codex parent only, and Codex
  captures use `› ` with a plain space; the other spellings are the Claude client's.
  `plugins/shipyard/skills/shipyard/shipyard-continuity.sh:93` and `:269`. Found by the review of
  #290. *Promote when* continuity runs for a Claude parent, or a Codex capture shows an NBSP or `❯`
  prompt.
- **KL-9 — on the kind that echoes no command, a fast compaction under a stale finished line reads
  as a timeout.** A typed `/compact` does not retire an older `Context compacted` line there, so a
  compaction that finishes before `submit()`'s capture about three seconds later is never seen as
  new, and the run ends in exit 4 with no resume brief sent. It fails in the safe direction and the
  code says so. `plugins/shipyard/skills/shipyard/shipyard-compact.sh:107`. Found by the review of
  #290. *Promote when* a compaction of that kind that did finish is reported as exit 4, or one at
  the ceiling completes in under about three seconds. Closing it needs evidence from that client
  that a new compaction started, derived from a capture.
- **KL-10 — the owner-hold watcher with more than one wait slice per interval is run by no test.**
  The wait between polls is cut into slices of at most 0.25 s, and t10, the only suite that drives
  the owner hold, polls at 0.1 s, a single slice; the multi-slice pause itself is run by t7 on the
  default path. The owner hold is opt-in and no production path arms it.
  `plugins/shipyard/skills/shipyard/shipyard-continuity.sh:407`. Found by the review of #311.
  *Promote when* a production caller arms the owner hold: then a t10 case at a 0.6 s interval (three
  slices) asserts owner death is reaped and a ping is answered within one slice.
- **KL-11 — t7's synchronized-stop case pins the stop's longer lock wait only on a box fast enough.**
  The case holds a publishing start for a fixed 10 s, so a stop put back on a start's default lock
  wait reds it only while that default's polls finish inside 10 s; on a box loaded past that, the
  mutant survives. That loses coverage and never causes a false red. An evidence-ended hold was tried
  in #311 and reverted for its fork cost under load.
  `plugins/shipyard/skills/shipyard/tests/t7-continuity.sh:751`, against
  `plugins/shipyard/skills/shipyard/shipyard-continuity.sh:1176`. Found by the review of #311.
  *Promote when* someone lowers the stop's wait or the case's hold, or a mutation run by hand shows
  the mutant surviving on an idle box (no automated run applies it): then the hold ends on the stop
  giving up, counted without a fork per pass.
- **KL-12 — a per-slot verb can refuse because of a different slot in another container.** The
  `container` check scans every slot still in its worktree, so `down` or `tell` of slot A refuses
  when slot B sits in another container; the refusal names B, so it is louder, not wrong.
  `plugins/shipyard/skills/shipyard/shipyard-backend.sh:508`. Found by the review of #292.
  *Promote when* a supervisor acting on such a refusal tears down or relaunches the wrong slot.
- **KL-13 — the `container` check matches a terminal by name, not by handle.** Two repos launched
  from one agterm workspace share a container, so the other repo's same-named `ship-<slot>` can
  raise the refusal; the remedy warns about it, and matching on the recorded handle would remove it.
  `plugins/shipyard/skills/shipyard/shipyard-backend.sh:532`. Found by the review of #292.
  *Promote when* two repos sharing one workspace becomes a documented setup rather than an
  incidental one.
- **KL-14 — the `container` remedy arms are asserted by no test.** The report's `no_signal_block`
  arm, the launch refusal, the admission gate, `shipyard-down.sh --list`'s `?container`, and the
  agterm branch of `shipyard_container_remedy` are reached by no case; only the per-slot route
  through `shipyard_absence_report` is (t14 6f).
  `plugins/shipyard/skills/shipyard/shipyard-report.sh:233`, `shipyard-launch.sh:150`,
  `shipyard-admission.sh:120`, `shipyard-down.sh:128` and `shipyard-backend.sh:547`. Found by the
  review of #292. *Promote when* one of those arms prints the wrong remedy, or none.
- **KL-15 — the both-pinned remedy re-reads the pins after its caller has.** A caller that has just
  found both pins present calls `shipyard_elsewhere_remedy`, which reads them again; a mailbox write
  in the milliseconds between can switch it to the single-pin branch's launch wording, or to its
  one-line return with no clearing order. The caller's own header line still prints, so the operator
  is still told; only the remedy under it is thinner.
  `plugins/shipyard/skills/shipyard/shipyard-backend.sh:578`. Found by the review of #347.
  *Promote when* an operator reports a refusal or NOTE whose remedy was a single line, or the pins
  start being rewritten often enough for that window to matter: then the caller passes the pin state
  it read into the remedy.
