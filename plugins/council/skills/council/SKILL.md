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

## When to use it, and when not

Reach for it when a question benefits from a second and third *independent* model — a
design fork, a review of somebody's change, a decision that is expensive to reverse. Do
not reach for it to do work: a room is for argument. One agent doing the task is faster
than three agents discussing it, and a room with nothing to disagree about burns tokens
producing polite agreement.

## The room

```
<git-common-dir>/council/<room>/
  roster.json            participants, roles, mode, decision rule, turn budget
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
* total order is `(lamport, from)`, carried **inside** each message, so every reader
  derives the same sequence without asking anyone.

Reaction is a **doorbell**: a one-byte write into the recipient's fifo, which a sleeping
`recv` wakes on. Measured on the reference machine: the bell itself is **0.7 ms** at the
median, end-to-end delivery **56 ms** (two `jq` spawns, not the wire). A poll loop would
be 0–5 s. A keeper process holds every bell open read-write for the life of the room, so a
bell rung at a participant that is not currently listening is buffered rather than lost,
and the ring itself is backgrounded so a dead participant can never wedge a sender.

**Scan the inbox from the cursor upward, never by globbing the lane.** A lane is gapless
and single-writer, so probing `cursor+1, cursor+2, …` until the first missing file is
O(new). The globbing version was O(everything ever said), and it did not merely run slow:
readers fell behind, and **the order in which a participant received messages diverged
from the final transcript in ~30% of cases** under load. Fixing the scan took that from
`0/101/133` inversions to `0/0/0`. Inversions are not structurally impossible — they are
simply absent while readers keep up. In turn-taking mode only one participant speaks at a
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
| `concede --refs '["<id>"]'` | **the sender yields** |
| `withdraw` · `support` · `overrule` (chair) · `msg` · `notice` · `skip` · `decide` | |

`concede` always means the same thing, and who sends it decides what falls: from the
objection's author it closes the objection; from the proposal's author it kills the
proposal. An objection also closes on `withdraw` by its author, on an `amend` that
references it, or on the chair's `overrule`.

**Verdicts** (`council.sh verdict`, and the alarms in `status`):

* `deliberating` — work in progress;
* `ready-to-decide` — no open objection, one live proposal, and a full lap with no new
  proposal, amendment or objection;
* `stuck` — a full lap went by, the objection is still open, nobody said anything new.
  This is the polite-echo failure that is invisible in a plain chat, and it is an alarm;
* `unresolved` — the turn budget ran out;
* `no-proposal` — the room talked and put nothing on the table;
* `decided` — the record has been written.

`council.sh decide` **refuses** a room that is not ready. `--force` writes an honest
`unresolved` record listing what is still open — a valid outcome, not a failure to hide.

## Verbs

```bash
council.sh up --scenario debate --agents claude,codex,agy "вопрос"   # or @file
council.sh status | claims | verdict | order | transcript | floor
council.sh say <peer> "..."        # out of band, into that participant's terminal
council.sh decide [--force]        # write the ADR and close the room
council.sh down [--purge]          # close terminals; the room (the record) survives
council.sh rooms                   # what exists and where each room stands
```

Participants use exactly two: `recv --until-floor` and `send --act …`.

`--room <name>` selects among several rooms; `--me <peer>` says who you are — pass it to
`up` as well when you intend to sit in the room yourself, and that participant gets no
terminal because it is you.

**One entrypoint, on purpose.** A participant's permission allowlist matches the literal
start of a command, so eight scripts would need eight grants and the first lap of every
room would stall on approval prompts. One script is one allowlist entry.

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
| `agy` | `--add-dir <room> -i` | **interactive, per command prefix** | `--sandbox` is not a policy, it just refuses; the only unattended flag is a blanket one |

`agy` needs one grant of the form *always allow commands that start with
`bash <skill>/council.sh`* — give it once and the room runs unattended. Miss it and the
participant sits on a permission prompt **holding the floor**, which from the outside is
indistinguishable from a wedged session (measured: 626 s). This is why `status` calls out
a long-held floor and why the turn deadline and `skip` exist.

**Both `codex` and `agy` gate the first launch in an unfamiliar directory on a
trust-this-directory prompt**, and until it is answered the participant holds the floor
while looking, from the room, exactly like a wedged session. `up` prints the caveat for
each adapter; `status` flags a long-held floor. Answer it once per directory.

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
`recv` withholds them; a lane stops at its withheld message instead of skipping past it, so
nothing is lost and no cursor runs ahead of unread words. A second message in an open round
is refused (exit 5) rather than queued.

When the last position lands, all of them are released at once, in the room's one order.
The round then counts as **one whole lap**, and everything after it is turn-taking, so no
delivery-stability rule is needed: from there on only one participant speaks at a time.
Opening positions carry no turn number, so they never compete for one.

A participant that never posts does not hold the room: past `round_deadline_ms` (default
10 min, from the first position) with a quorum present (default N−1, never below 2) the
round closes without it. `status` shows `ОТКРЫТЫЙ КРУГ: собрано k/N, ждём …` while it is
open — the one state in which a long-held floor is normal rather than a stall.

The `debate` scenario runs `roundtable`; `review` stays turn-taking, because there the
author's proposal *is* the subject and a blind first lap would have nothing to be about.

*(This design was itself decided by a council room of `claude` and `codex`, which killed
the position that turn-taking is enough. The decision record is in the room that produced
it.)*

## Supervising a room

`council.sh status` is the block to read: whose floor and for how long, what is on the
table, what is open, the verdict, and the alarms (`STUCK`, `STALL`, turn conflicts, budget
exhausted). It exits **0 when the room is finished** and 1 while it is open.

**Exit codes here mean status, not success.** `verdict` returns 1 on a live room and 2 on
a stuck one. Piping such a command (`council.sh status | grep -q X` under
`set -o pipefail`) reads the room's state as a failure of the pipeline — that already
produced one false test result during development. Do not pipe status through a gate.

## Failure modes worth knowing before they cost you a night

* **A participant that consumed your message and then went quiet is usually not thinking.**
  Look at its terminal: on `agy` it is probably a permission prompt; on any of them it may
  be a context ceiling. The room cannot tell the difference — `status` can only tell you
  the floor has been held a long time.
* **An empty room is a normal state, not an error.** Reporting "nothing here" through an
  exit code once killed the very first `send` into a fresh room, because the caller ran
  under `set -e` with `pipefail`.
* **A room closed as `unresolved` must read back as `unresolved`.** The recorded status is
  written to `board/status`, not re-derived from the presence of a `decide` message.
* **`support` closes nothing.** A room can lap forever on agreement while an objection
  stays open; that is exactly what `stuck` is for.

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
