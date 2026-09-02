---
name: council
description: "Run a multi-agent discussion room: several agent sessions (Claude Code, Codex, Antigravity) in background terminals argue one question by a strict protocol — speaking in turn, objecting with references, closing objections mechanically — and the room writes a decision record when it converges, or an honest unresolved one when it does not. Use when a design question deserves more than one model's opinion, or when a change should be argued by an author and a reviewer that are not the same session."
---

# council: a room where several agents argue one question

A **room** holds N participants (2, 3, 4 — the code does not care), each a real agent
session in its own terminal, plus you. They talk through files, take turns, and the room
ends by writing a **decision record** to its own board — or by saying plainly that it did
not converge and what is still open.

What makes it more than a group chat: **the outcome is computed, not declared**. An
objection is closed by a specific message, a proposal dies by a specific message, and
"we agree" means *no open objection and a full lap in which nobody added anything new*.
No participant can end the room by saying it feels resolved.

Those rules are author-gated — only an objection's own author withdraws it, only a
proposal's own author kills it — so **a message's author is derived, never believed**: every
reader takes it from the lane the file was read at and overwrites what the message says
about itself. A lane has exactly one writer, so the lane *is* the author. And the room is
closed only when its **decision record** has been written, never because a `decide` message
is present — a message says somebody ran `decide`, the record says it finished.

**One exception, and it is a real hole in the claim above: `overrule` is gated on nothing.**
Any participant can close any objection with it, and there is no chair (see the acts table
below). So "no participant can end the room by saying it feels resolved" holds for `decide`
and for a forged author, and does **not** hold for `overrule`.

## When to use it, and when not

Reach for it when a question benefits from a second and third *independent* model — a
design fork, a review of somebody's change, a decision that is expensive to reverse. Do
not reach for it to do work: a room is for argument. One agent doing the task is faster
than three agents discussing it, and a room with nothing to disagree about burns tokens
producing polite agreement.

## The room

```
<git-common-dir>/council/<room>/
  roster.json            participants, roles, mode, decision rule, turn budget, the cwd,
                         and created_ms — the room's creation instant, written once by `up`
                         (a room without it keeps the plain stall threshold)
  agenda.md              the question
  protocol-<peer>.md     what each participant was told (channel rules + its role)
  lane/<peer>/NNNNNN.json    ← exactly ONE writer per lane, ever
  cursor/<me>/<peer>         ← exactly ONE writer per cursor (me)
  bell/<peer>.fifo       the doorbell
  board/decision.md      the output; board/status holds decided|unresolved
  state/                 counters, launchers, the pinned terminal container, keeper pid
```

It lives in the **shared git dir** so one path resolves from every worktree of the repo,
git never tracks it, and `git clean` cannot eat a discussion in progress. That location
was itself decided by a council room (`debate`, three agents): the first proposal was
`.council/` in the working tree, and it was killed by the objection that this gives a
*separate* room per worktree.

## Transport: no locks anywhere

Three invariants replace every lock:

* one writer per lane, one writer per cursor, one writer per state file;
* every file lands by write-tmp-then-`rename`, so a reader never sees half a message;
* total order is `(lamport, from)` — `lamport` carried **inside** each message, `from`
  taken from the lane it was read at — so every reader derives the same sequence without
  asking anyone.

Reaction is a **doorbell**: a one-byte write into the recipient's fifo, which a sleeping
`recv` wakes on. Measured on the reference machine: the bell itself is **sub-millisecond** (0.3 ms median
from the write to a sleeping reader waking), and end-to-end delivery **~60 ms** — of which
25 ms is the sender publishing and 39 ms the reader parsing, i.e. `jq` spawns rather than
the wire. A poll loop would be 0–5 s. A keeper process holds every bell open read-write for the life of the room, so a
bell rung at a participant that is not currently listening is buffered rather than lost,
and the ring itself is backgrounded so a dead participant can never wedge a sender.
A bell that is no longer a fifo — an archive-and-restore of a room directory, or any copy
that does not preserve fifos — makes `recv` say so on stderr and fall back to a half-second
poll (not the 0–5 s figure above: `recv` passes its own interval), because `exec` succeeds on
a regular file and the read that follows would otherwise return at EOF instead of sleeping,
spinning for the whole timeout. Delivery latency is therefore unchanged; only CPU differs.

**Scan the inbox from the cursor upward, never by globbing the lane.** A lane is gapless
and single-writer, so probing `cursor+1, cursor+2, …` until the first missing file is
O(new). The globbing version was O(everything ever said), and it did not merely run slow:
readers fell behind, and **the order in which a participant received messages diverged
from the final transcript in ~30% of cases** under load. Fixing the scan took that from
`0/101/133` inversions to single digits — repeated runs of 510 messages from three
concurrent writers land anywhere between `0/0/0` and `0/4/5`. Inversions are not
structurally impossible; they shrink to whatever the readers' lag is, which is why the
number moves between runs and why nothing asserts it is zero. In turn-taking mode only one participant speaks at a
time, so they cannot arise; any future free-for-all mode needs an explicit stability rule.

## Turn discipline: a floor with no token

The speaker is `order[(turns mod N + lap) mod N]` — a pure function of the log, so there
is no token file to lose or duplicate, and the order rotates one step per lap so the same
participant is not always the anchor.

**But it is a function of the log you have READ.** A participant that has not drained a
lane counts fewer turns and can speak while somebody else legitimately holds the floor.
So every message carries the turn it claims, and of all messages claiming turn N the
lowest `(lamport, from)` keeps it; the others are demoted to out-of-turn — **kept in the
log**, never dropped — and their authors take the floor again. Deterministic, identical
for every reader, still no lock. (This hole was found by a Codex participant inside a
council room, in one turn; three transport tests had missed it.)

The floor is also checked **at stamp time, not before composing**. A participant that held
the floor a moment ago may have lost it while writing, and it would otherwise stamp the
next *free* turn — no duplicate for the settlement rule to catch, and the room quietly
stops being turn-taking from there on. Such a send is refused with exit 6; the participant
is told to drain and wait. (`skip` is exempt: it is spoken on somebody else's behalf.)
That check is what makes duplicate claims rare rather than routine — the settlement rule
still matters, because a `skip` can race the holder it is skipping.

A participant that goes silent does not freeze the room: once the floor holder is overdue,
**the next participant in order — and only that one** — may write a `skip`, which consumes
the missing turn and moves on.

Anything urgent can be said out of turn with `--hand`: only `object`, `clarify` and
`notice`, it consumes no turn and does not move the floor, and the next speaker must
answer it.

## Deliberation: what closes what

| act | meaning |
|---|---|
| `propose` | put something on the table |
| `amend --refs '["<proposal>","<objection>"]'` | a revision; referencing an objection **closes** it |
| `object --refs '["<id>"]'` | must name a specific id, or there is nothing to close |
| `concede --refs '["<id>"]'` | **the sender yields**: pointing at an objection accepts it, pointing at your own proposal withdraws it in favour of somebody else's |
| `withdraw` · `support` · `overrule` (**ungated — any participant**) · `msg` · `notice` · `skip` · `decide` | |

`concede` always means the same thing, and who sends it decides what falls: from the
objection's author it closes the objection; from the proposal's author it kills the
proposal — whether it points at an objection or at the proposal itself. An objection also
closes on `withdraw` by its author, on an `amend` that references it, or on an `overrule`.

**`overrule` is gated on nothing.** Any participant can close any objection with it, and
there is no chair: no roster field names one, no scenario assigns one, and no code checks
one. It was documented as the chair's act for a long time, which was simply not true of the
code. Whether a room should have a chair is a question about how a room is *governed* and
has not been decided — read this as a description of what the code does today, not as a
gap somebody is on their way to filling.

An `amend` belongs to **one** proposal — the first proposal-typed id it references; its
other refs are the objections it closes. (Referencing two proposals used to apply the
amendment to both, so a room displayed two participants proposing the same words.)

A barrier round puts **N proposals** on the table at once, one per participant, and
`ready-to-decide` wants exactly one. That is the work of the lap after the barrier: yield
the ones you no longer defend (`concede` your own), and fold what is worth keeping into
the survivor with `amend`. A roundtable room that never does this sits at
`deliberating` with N live proposals and no open objection, which reads as agreement and
is not.

**Verdicts** (`council.sh verdict`, and the alarms in `status`):

* `deliberating` — work in progress;
* `ready-to-decide` — no open objection, one live proposal, and a full lap with no new
  proposal, amendment or objection;
* `stuck` — a full lap went by, the objection is still open, nobody said anything new.
  This is the polite-echo failure that is invisible in a plain chat, and it is an alarm;
* `unresolved` — the turn budget ran out, **or** a `--force` close wrote an unresolved
  record, which is read back from `board/status` the same way `decided` is and wins over
  every computed verdict. So an `unresolved` room is not necessarily one that ran out of
  turns; `status` distinguishes the two in its alarms;
* `no-proposal` — the room talked and put nothing on the table;
* `decided` — the record has been written. Read from `board/status`, which `decide` writes
  once the record is on disk; a `decide` message with no record closes nothing, and the
  room reports whichever of the verdicts above it is really in.

`council.sh decide` **refuses** a room that is not ready. `--force` writes an honest
`unresolved` record listing what is still open — a valid outcome, not a failure to hide.

`--force` is not unconditional: **while a room is still open**, if its **roster** cannot be
read, `decide` refuses with **exit 1** and writes nothing, `--force` included, because there is
then no participant list to write a record about. Exit 2 still means "not ripe" and 3 "already
decided", so a supervisor that retries on 2 must not retry on 1.

**A room that has already closed is the exception, and it is a remainder rather than a design.**
`--force` over a room whose record is on disk rewrites that record, and it does so at exit 0
even when the roster has since become unreadable — the rewritten header then carries
`* participants: ` and `* mode: , rule: ` blank. That is `origin/main`'s behaviour, unchanged
here; only the sentence above it is new, and an earlier revision of it claimed the refusal
covered this case too. Re-forcing a closed room whose roster is broken is not something to do.

**A lane file that does not parse is a different case, and a worse one.** The readers that glob
the whole log on every call — `order`, `transcript`, `claims`, `verdict`, `status` — report the
room as EMPTY rather than as broken, and `decide --force` will write a record over it saying
there were no objections. (A participant's view of the first three, and of `status`'s display
half, is cut further by an open barrier round; see Modes. That does not change this paragraph:
an unreadable lane file empties them all either way.) Only
the diagnostic on stderr says otherwise, and it is the thing to act on. Treat a `council:` line
about a log that could not be read as invalidating every other answer in the same breath.

That is a known remainder rather than a design. Three designs were tried on this branch and
this is the second of them — the one that ships. The first, dropping the bad file and reading
the rest, turned "unreadable" into "silently incomplete"; the third, giving the reader a second
exit status, made a room that had already CLOSED stop reporting itself closed. Both were
reverted. `lib/lib.sh`'s `c_all` carries the account, and a fourth attempt has to let the
record answer before the log does — `v_verdict` now does exactly that, and it is why a closed
room survives both an unreadable log and an unreadable roster.

**The two causes differ for participants:**

* **A lane file that does not parse.** The error names that file. `recv` keeps working — it
  reads only what is new and steps over the file — so seats are not wedged while it is
  repaired, and `send` keeps stamping from the clock it can still read.
* **A roster whose participant list cannot be read.** The error names no file, because no file
  is at fault. `recv` returns 4 delivering nothing and `send` returns 6, for every seat, until
  `roster.json` is repaired — so the room is fully stopped, not degraded.

**`floor` answers from an unread log at exit 0 in both cases**, so do not use it to decide whose
turn it is while a room is in either state.

## Verbs

```bash
council.sh up --scenario debate --agents claude,codex,agy "question"   # or @file
council.sh status | claims | verdict | order | transcript | floor
council.sh agenda | protocol | decision   # the room's own files, through the entrypoint
council.sh say <peer> "..."        # out of band, into that participant's terminal
council.sh relaunch <peer>         # put one seat back up, mid-room
council.sh decide [--force]        # write the ADR and close the room
council.sh down [--purge]          # close terminals; the room (the record) survives
council.sh rooms                   # what exists and where each room stands
```

Participants use `agenda` (and `protocol`, if they need their role again) at the start, then
`recv --until-floor` and `send --act …` for the rest of the room, and `decision` once it
closes. Those five are everything that would otherwise have been a path; `status` and `claims`
cover looking at the room itself.

`--room <name>` selects among several rooms; `--me <peer>` says who you are — pass it to
`up` as well when you intend to sit in the room yourself, and that participant gets no
terminal because it is you.

**One entrypoint, on purpose.** A participant's permission allowlist matches the literal
start of a command, so eight scripts would need eight grants and the first lap of every
room would stall on approval prompts. One script is one allowlist entry.

Two things one entrypoint does **not** buy, both learned from a live room. A prefix grant only
matches if the agent runs the command *as written*, and `agy` prepends the environment inline,
so a grant on `bash <skill>/council.sh` never matches it — moot for a council-launched seat,
which carries the blanket flag instead, but worth knowing before you go and write one. And a
**command** grant says nothing about **file** reads: opening a room file by path is a separate
permission question for some agents. That is why `agenda`, `protocol` and `decision` are verbs
rather than paths, and why the protocol tells every participant to read the room through the
command.

## Restarting one seat

A participant dies, or is killed to pick up new permissions, or hits a context ceiling.
`up` would create a *new* room and `down` closes them all, so putting one seat back is its
own verb:

```bash
council.sh relaunch codex            # closes its terminal if one is still there, starts it again
council.sh relaunch codex --cwd DIR  # run it somewhere other than the room's recorded cwd
```

### What survives the restart, and what does not

**The room survives it completely.** The floor, the lanes and every objection's
open-or-closed state are derived from the log, so an objection the dead participant had
filed is still exactly as open, or as closed, as it was. Nothing about the room has to be
rebuilt.

**That seat's knowledge does not.** The new process has read none of the argument, and its
cursors are files that outlived it, so `recv` hands it nothing — from inside, a room
twenty turns deep looks brand new. This is why `protocol/_channel.md` carries a section
telling *every* participant, relaunched or not, to read `council.sh transcript` when it
starts into a room that is not empty. It is safe to read during an open barrier round as
well: every reader holds the barrier, so a restarted seat is caught up on everything except
the positions it is not allowed to have yet. The room is not
replayed to a restarted seat, and it is not made to be: a cursor has exactly one writer,
which is the participant itself, and that invariant is what lets the whole transport work
without a lock.

### The launcher and the protocol are regenerated, not re-run

`relaunch` rewrites `state/launch-<peer>.sh` and `protocol-<peer>.md` from the roster and
this skill before starting anything. Two reasons.

Every participant is handed the room as a **writable root** (`--add-dir <room>`, in all
three adapters) — and a scenario deliberately makes those agents adversarial to each other.
Both of those files live in the room. Re-executing a stored launcher would run whatever
another participant had put there, in a login shell, in your own process tree — and the
protocol file is what the agent is launched on: `claude` takes it as its system prompt,
`codex` and `agy` are told to read it and follow it literally.

The values regeneration reads out of `roster.json` — which agent plays the seat, the
scenario, the role, the participant names — are checked to be bare names before use. They
select a file to source and a file to render, and `roster.json` is in the room too.

### The room is not a trust boundary

**Do not read any of the above as containment, because it is not.** Measured, all three
adapters, writing to a path outside the repo entirely — outside the working directory and
outside every `--add-dir`:

| adapter | wrote where it was told |
|---|---|
| `claude --permission-mode auto` | yes |
| `codex -s workspace-write -a never` | yes |
| `agy --dangerously-skip-permissions` | yes |

`--add-dir` is an allowlist **addition**, not a restriction, and this skill launches every
participant with approval prompts turned off on purpose — that is what keeps a room running
unattended. So a participant is an agent running **as you**, and everything you can reach, it
can reach: the roster, another seat's launcher, `council.sh` itself, your home directory.

That makes regeneration and the checks above **blast-radius reduction, not a boundary**. They
remove the traversal and sed-injection forms. They do **not** close the supervisor-triggered
path in general: `--add-dir <skill>` makes this skill's own `adapters/` directory writable, so
a participant can drop a plausibly-named file there and have the roster point a seat at it,
and an ordinary `council.sh relaunch <peer>` will source it. That is measured, not theorised.

**Deriving a message's author from its lane is not containment either.** It makes `.from`
honest about *which lane wrote this*, which is what the room's mechanical rules need. It says
nothing about *which agent session* wrote it, because nothing stops a participant writing into
another participant's lane. Read it as a correctness fix, never as authentication.

What it removes is one accident: anything that writes a lane **file** without going through
`send` — an agent that emits the JSON itself, or copies a message it read out of `recv` with
the original `from` intact. It does **not** cover a seat running under the wrong
`COUNCIL_ME`, even though that sounds like the same thing: `send` takes the lane path and
`from` from the same variable, so such a seat writes into the wrong lane with a *matching*
`from`, and deriving one from the other changes nothing.

Nothing here makes a room safe to share with a participant you would not trust with your
shell. Run rooms accordingly. The trust model itself is an open question, not a settled one;
it is being argued rather than assumed.

The second reason is the ordinary one: a regenerated launcher picks up **adapter changes
made since the room opened**, which is exactly what "killed to pick up new permissions"
asks for. A stored launcher would bring the seat back with the command line it had when
the room was created.

**The cost, and you will not discover it any other way: a hand-edited launcher or protocol
is discarded.** If you tuned a participant's protocol by hand, `relaunch` throws that away
and writes the generated one.

### `--cwd`

Without it, `relaunch` uses **the directory recorded in the room's `roster.json`**, which is
where `up` was pointed when the room opened. Pass `--cwd` to override it.

It decides where the participant actually **runs** — the regenerated launcher `cd`s there
before exec'ing the agent — not merely where its terminal window opens. A room created
before the cwd was recorded has nothing to fall back on and asks for `--cwd` explicitly
rather than guessing.

### The rest

**Do not hand-roll this.** Calling the launcher through the terminal backend directly —
`agtermctl session new --command <room>/state/launch-<peer>.sh` — looks like the whole
job and is not: the command runs with no login shell, so the agent CLI is not on the
resulting `PATH`, `exec` fails with 127, and the session closes within a second. From the
outside it looks exactly like the backend silently refusing to create a session, and
nothing is logged anywhere the caller can see. `relaunch` goes through the same wrapper
the first launch used (`zsh -lc 'exec …'`) and the same pinned container.

It also puts the **keeper** back if it is missing — `down` kills it along with the
terminals, and a seat restarted into a room with no keeper looks perfectly healthy while
every bell rung at it is lost.

The one peer it cannot restart is the seat *you* took with `--me`: that participant was
never given a terminal, so there is no launcher, and it says so.

## Scenarios and roles

The channel rules are one file for everyone (`protocol/_channel.md`); a scenario adds only
the roles. `up` renders them into `protocol-<peer>.md`.

* `debate` — proposer vs critic (+ a third angle), opening lap on a barrier. The
  default for a design fork.
* `review` — author vs reviewer; the author owns writes, the reviewer only reads.
* `freeform` — rules and an agenda, no roles.

A new scenario is one markdown file with front-matter (`mode`, `decide_by`, `turns`,
`roles`, and `round_deadline_ms` for a barrier round) and a `## role: <name>` block each.
No code changes.

Roles and agents are independent: `--agents arch=claude,impl=codex,sec=agy` names the
participants and says which CLI plays each.

## Adapters — the three agents differ where it matters

| | launch | permissions | verified |
|---|---|---|---|
| `claude` | `--permission-mode auto --add-dir <room>` | declarative | — |
| `codex` | `-s workspace-write -a never --add-dir <room>` | declarative, per-run | writes to a room outside its cwd; shell tool tolerates a block of **>200 s**, so `recv --timeout 180` is safe; `-a` does not exist on `codex exec` |
| `agy` | `--dangerously-skip-permissions --add-dir <room> -i <protocol text>` | **interactive: a persisted allowlist for commands, nothing at all for file reads** | `--sandbox` is not a policy, it just refuses; the protocol is handed over as argv, not as a path |

`agy` asks about **commands** and about **file reads**, and the two work nothing alike. Either
one stalls the room the same way: the participant sits on a prompt **holding the floor**, which
from the outside is indistinguishable from a wedged session (measured: 626 s). This is why
`status` calls out a long-held floor and why the turn deadline and `skip` exist.

*Commands* have a persisted allowlist — *always allow … commands that start with `<prefix>`* —
but the prefix it stores must match what `agy` actually runs, and it does not run the bare
command. It prepends the environment inline, `COUNCIL_ROOM=… COUNCIL_ME=… bash …`, even though
`state/launch-<peer>.sh` already exported both, so a grant written as `bash <skill>/council.sh`
never matches.

*File reads* have **no grant at all**: the menu offers `1. Yes / 2. No` with no "always", and
there is no per-run flag. What decides whether it asks is not the directory but **whether the
agent was told the path or worked it out itself** — a path named in the launch prompt is read
silently, a path the participant derives prompts every time. Adding the room to
`trustedWorkspaces` does **not** help; that was tried in the room it was meant to fix.
(Measured in [#7](https://github.com/dimonb/skills/issues/7) and
[#18](https://github.com/dimonb/skills/pull/18) — both of the above.)

So the launch passes the blanket `--dangerously-skip-permissions`, which applies to sessions
this skill starts and never to an interactive `agy`. It is a workaround, and the room is built
to need less of it: **a participant is never handed a path to a file in the room** (it is told
which room it is in, and nothing below that). The protocol
arrives as argv (as it always did for `claude`, via its system prompt), and the agenda, the
role and the record are verbs — `council.sh agenda`, `protocol`, `decision` — which ride the
command grant. What still needs the flag is everything *outside* the room: a `review`
participant reading the codebase derives those paths itself, and nothing persists a grant for
them. Solve that and the flag can go.

`codex` keeps its `Read <path>` launch prompt, because its permission is declarative
(`-s workspace-write -a never --add-dir <room>`) and covers that read without ever asking. The
rule above is about agents that ask per file.

**Both `codex` and `agy` also gate the first launch in an unfamiliar directory on a
trust-this-directory prompt** — the blanket flag does not answer that one — and until it is
answered the participant holds the floor while looking, from the room, exactly like a wedged
session. `up` prints the caveat for each adapter; `status` flags a long-held floor. Answer it
once per directory.

`codex queue --thread` looks like a native way to wake a busy Codex participant. It is
not: it accepts the message, prints `Queued message …`, returns 0 — and delivered it
**265 seconds later** in the one run where it did deliver. Typing into the terminal
(`council.sh say`) arrives in seconds. Judge that channel by delivery, never by its exit
code.

## Modes: turn-taking, and the opening barrier

`token` (the default) is plain turn-taking. `roundtable` adds one thing in front of it:
**the first lap runs as a barrier**.

Rotation moves the anchor, it does not remove it — in a room of two or three the second
speaker still sees the first position before forming its own, which is exactly the case
`debate` exists for. So in a roundtable room every participant writes its opening position
without waiting for a turn, and **nobody reads anyone else's until the round is complete**.
A lane stops at its withheld message instead of skipping past it, so nothing is lost and no
cursor runs ahead of unread words. A second message in an open round is refused (exit 5)
rather than queued.

**Every reader holds it, not only `recv`.** `transcript`, `claims`, `order` and `status` show
a participant no more than `recv` has already released **for any lane `recv` reads** — a lane
is withheld whole — so none of the verbs a participant reads the room with hands it another
seat's opening words. Each of them says on stderr when the barrier is why a read looks thin,
so "nothing was said" cannot be mistaken for "nothing was shown to you". The bound is
one-sided on purpose: a lane withheld for its opening position keeps that seat's other
messages waiting with it (a `--hand` message is allowed during an open round), and a lane the
roster does not list is read here and never delivered by `recv` at all — that second one is
issue #66's divergence, not this mode's.

A **supervisor** — anyone reading the room without `--me` — is exempt and sees all of it, which
is what makes `status` usable for watching a round that has not finished. The seat a human
takes with `up --me` gets no launcher, so nothing exports `COUNCIL_ME` for it: **that seat must
pass `--me` on every command, reads included**, or its reads are supervisor reads.

The room's own arithmetic is exempt too — turn counts, the floor and `verdict` are computed
from the whole log, because they are facts about the room rather than about who is asking, and
they report counts and message ids, never text. **The record is the one real exception, and
deliberately so:** `decide` writes it from the whole log, because a record holding only the
writer's own position would be worse than none, so a room `--force`-closed mid-round hands
every position to whoever runs `decision`.

Read that as a **bypass available to every seat**, because `decide` takes `need_me`: a
supervisor with no `--me` cannot run it at all, and any participant can — including one that
has posted nothing. Two documented commands (`decide --force`, then `decision`) hand it the
whole opening round. What it costs the seat doing it is the room: the record is on disk,
`board/status` is set, and every other seat's stop signal fires, so this is loud rather than
quiet. It is a known remainder of the barrier, not a property of it.

When the last position lands, all of them are released at once, in the room's one order.
The round then counts as **one whole lap**, and everything after it is turn-taking, so no
delivery-stability rule is needed: from there on only one participant speaks at a time.
Opening positions carry no turn number, so they never compete for one.

A participant that never posts does not hold the room: past `round_deadline_ms` (default
10 min, from the first position) with a quorum present (default N−1, never below 2) the
round closes without it. `status` shows `OPEN ROUND: posted k/N, waiting for …` while it is
open — the one state in which a long-held floor is normal rather than a stall.

The `debate` scenario runs `roundtable`; `review` stays turn-taking, because there the
author's proposal *is* the subject and a blind first lap would have nothing to be about.

*(This design was itself decided by a council room of `claude` and `codex`, which killed
the position that turn-taking is enough. The decision record is in the room that produced
it.)*

## Supervising a room

`council.sh status` is the block to read: whose floor and for how long, what is on the
table, what is open, the verdict, and the alarms (`STUCK`, `STALL`, turn conflicts, budget
exhausted, and **"this room's state could not be computed"** — that last one means the room's
participant list could not be read, so the lines above it are incomplete and none of them
should be believed; the diagnostic on stderr says what could not be read, and
`council.sh decision` still prints the record if the room had already closed).
A `STALL` whose held time is longer than the room has existed says so in the same alarm: one
seat's clock is wrong, so the figure cannot be trusted even though the stall is real.
It exits **0 when the room is finished** and 1 while it is open — with one caveat
worth knowing: a room whose
turn budget ran out reports `unresolved` and exits 0 before anyone has written a record, so
`council.sh decision` (exit 0 only with a record) is the signal to trust when you need to know
that the room's output exists.

**Exit codes here mean status, not success.** `verdict` returns 1 on a live room and 2 on
a stuck one. It also returns **1 having printed nothing at all** when the room's ROSTER
cannot be read. So rc 1 with output is a live room and rc 1 with no output is one whose
participant list is unreadable; a supervisor that treats every 1 as "still going" will wait
forever on the second. `status` names it in its alarms line, and `council.sh rooms` says it
in place of the verdict. An unreadable lane FILE does not produce that signal — `verdict`
answers confidently from what it takes to be an empty room, and only stderr disagrees.
Piping such a command (`council.sh status | grep -q X` under
`set -o pipefail`) reads the room's state as a failure of the pipeline — that already
produced one false test result during development. Do not pipe status through a gate.

## Failure modes worth knowing before they cost you a night

* **The two readers do not agree on which lanes are the room.** `recv` builds its list from
  `roster.order`; everything else (`verdict`, `claims`, `transcript`, `decide`) globs `lane/*/`.
  So renaming or removing a peer in `roster.json` orphans its lane: it still appears in the
  transcript and the verdict, while `recv` delivers none of it to anybody, and an objection
  raised there can never be answered. Nothing warns about it. This is a known open defect
  (issue #66) — the obvious fix, pointing both readers at the roster, was tried and reverted,
  and `c_all` carries the account of why.
* **A participant that consumed your message and then went quiet is usually not thinking.**
  Look at its terminal. On `codex` it may be the trust-this-directory prompt; `agy` is
  launched with permissions skipped and no longer prompts at all. Otherwise it is a context
  ceiling, or a process that is simply gone. The room cannot tell the difference — `status`
  can only tell you the floor has been held a long time. **A prompt and a dead seat need
  opposite fixes.** Answer a prompt *in that participant's terminal*, where it carries on
  with its context intact: restarting closes the very terminal holding the prompt, and the
  fresh session stops at the same one. A context ceiling, or a seat that is genuinely gone,
  is `council.sh relaunch <peer>`.
* **A permission prompt for a FILE is not the same prompt as one for a command**, and the
  grant that settles the command class does nothing for it — on `agy` nothing settles the file
  class at all. What decides it is whether the agent was *told* the path or *derived* it, so
  the fix is to stop making participants derive paths: give them a verb, not a location. For
  an agent that asks per file, a path in an instruction is a stall waiting to happen.
* **An empty room is a normal state, not an error.** Reporting "nothing here" through an
  exit code once killed the very first `send` into a fresh room, because the caller ran
  under `set -e` with `pipefail`.
* **A room closed as `unresolved` must read back as `unresolved`.** The recorded status is
  written to `board/status`, not re-derived from the presence of a `decide` message.
* **`support` closes nothing.** A room can lap forever on agreement while an objection
  stays open; that is exactly what `stuck` is for.
* **The recorded decision is the proposal AS AMENDED** — the original followed by each
  amendment, under headings that say which is which. A proposal nobody amended is recorded as
  plain text, with no headings. The record used to render the latest message text, which —
  since an `amend` is how an objection closes — was the last amendment alone, in the
  amendment's own voice: every accepted item it did not restate appeared nowhere, and the
  decision could only be reconstructed from the transcript.
* **A long agenda is summarised at the top of the record and quoted in full at the end**, so
  the decision is not pushed below two screens of prompt. A one-line agenda stays inline.

## Files

| file | role |
|---|---|
| `council.sh` | the single entrypoint; every verb |
| `lib/lib.sh` | transport: lanes, Lamport, cursors, bell, floor, turn conflicts |
| `lib/verbs.sh` | send/recv/claims/verdict/status/decide |
| `lib/up.sh` | room creation, roster, protocols, launchers, teardown |
| `lib/term.sh` | the terminal a participant lives in (agterm or tmux) |
| `lib/claims.jq` | the argument graph and the closure rules |
| `adapters/*.sh` | how each agent CLI is launched, and what it needs |
| `protocol/_channel.md` | the channel rules every participant gets |
| `scenarios/*.md` | roles per scenario |
| `tests/run-all.sh` | the suite (`--full` adds load and latency runs) |

`lib/term.sh` is deliberately a **second copy** of the abstraction the `shipyard` skill
carries, not a shared import: Codex has no plugin-dependency field, so a cross-plugin
source would work in one agent and silently break in the other. It is kept small so the
two cannot drift far — fix a backend bug in one, check the other.
