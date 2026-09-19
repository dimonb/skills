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
  state/                 counters, launchers, the pinned terminal container, keeper pid,
                         and `teardown` — a decided close's request that the keeper reap
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

Anything urgent can be said out of turn with `--hand`: the acts a **participant** may raise that
way are `object`, `clarify` and `notice`, it consumes no turn and does not move the floor, and the
next speaker must answer it. (`decide`'s close announcement is also `--hand` — sent by the room
rather than raised by a participant, and nobody owes it an answer. `c_send` enforces no list.)

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

`--force` is not unconditional. Two conditions refuse it:

* **while a room is still open**, if its **roster** cannot be read, `decide` refuses with
  **exit 1** and writes nothing, `--force` included, because there is then no participant list
  to write a record about;
* **while an opening barrier round is not verifiably closed and another seat's round-0 traffic
  is being withheld from the caller**, a seat that has posted nothing is refused with **exit 2**.
  Closing a room writes the record from the whole log and `decision` hands it to anyone, so
  without this a seat that owed a position could read every other by closing the round — two
  commands, available to every participant and to no supervisor, since `decide` takes `--me`. A
  seat that has posted keeps the escape hatch.

That second one refuses exactly when the record would hand over something the caller may not
read, and **not** merely because the round is open: a round with no round-0 traffic at all holds
nothing to disclose, so any seat may still close it. That distinction is the difference between
a gate and a wedge — such a round never closes on its own (the deadline is measured from the
first position), so refusing there would have left the room unclosable by anyone, `decide` being
`--me`-gated.

It asks `c_round0_withheld`, deliberately: the question is what the barrier is **holding back**,
which is `c_drain`'s and `c_visible`'s question, not how many **positions** are in, which is the
barrier's own. Keying it to the counting predicate looks equivalent and is not — a round-0
message with any other act then stops satisfying the gate while the withholders go on hiding it,
and a seat that posted nothing can force-close and read it. That shipped briefly and is pinned
now by a fixture whose hand-written message is deliberately *not* a position.

It still has a cost, named here rather than left to be discovered: **a seat that has not posted
cannot close a round others have started.** Post a position first — that is always available,
and it is what the refusal names. Waiting also works once a position exists, since the round
then closes past `round_deadline_ms` with a quorum and unconditionally past twice it.

Exit 2 still means "not ripe" and 3 "already decided", so a supervisor that retries on 2 must
not retry on 1.

### Closing a room tells it, and `decide` says so when it could not

Writing the record and telling the room are two separate acts, and the record goes first. So they
can come apart: the record on disk while the room is never told. `decide` reports that state
rather than hiding it.

The announcement is a message of act `decide`, sent `--hand`. It **closes nothing** — the record
does that, and `verdict`, `status`, `claims` and `decision` all read the record (see above) — so it
carries no authority: a stray one cannot make a room report `decided`. (It is not inert, though.
A stray `decide` sent the ordinary way is a normal message and **consumes a turn** like any other,
which can bring a room to `ready-to-decide` a turn early; only the close's own `--hand`
announcement consumes none.) What it does is **ring every seat**, so a waiting participant is
released now rather than at its own timeout. `--hand` because closing is taken out of band: the
caller is `--me`-gated to a seat, but it acts for the room rather than taking its turn, so it
consumes no turn and does not move the floor. Before this, the announcement was a plain send and
`c_send` refused one from a peer that did not hold the floor — which is any closer but the current
floor holder — and the refusal was discarded, so the commonest close rang nobody and still
reported success.

A `--hand` message moves no floor, so on its own it would **not** release a seat waiting in
`recv --until-floor` — the loop `protocol/_channel.md` prescribes. `recv --until-floor` therefore
also returns once the room's record says it closed, read through the same `c_recorded_status` as
everything else. Without that, closing a room left every seat but the floor holder waiting out its
full `--timeout` (**540 s** by default) with the record already finished on disk.

| exit | what it means |
|---|---|
| 0 | the record is written, the announcement was written, **and** — on a close recorded `decided` — the teardown below was asked for. A close recorded `unresolved` deliberately asks for none. |
| 5 | the record is written and the announcement went out, but the **terminals could not be closed**: no live keeper to do the reaping, or the request could not be written (the message names the path). The close stands; `down` closes them. A third cause exists only for a *library* caller that sourced `verbs.sh` without `lib/up.sh` and so has no keeper machinery in scope — `council.sh decide` cannot produce it, because the entrypoint always sources it. |
| 4 | the record is written, the announcement was **not**. The close stands: `board/status` is set and `decision` serves the record; no seat was rung, so each learns at its own next poll. No teardown is asked for on this path, so the terminals are still up. |
| 1 | the record itself could not be written. **The room is not closed** and nothing was announced; no path is printed. |

**The three things that can fail are reported apart, on purpose.** The record is the deliverable,
so neither a lost announcement nor a teardown that could not happen is allowed to read as a failed
close — and neither is allowed to hide inside the other's code either. 1 is "there is no record";
4 is "there is a record and the room does not know"; 5 is "there is a record, the room knows, and
the seats are still up". The record path is on stdout on every one of those but 1, because it is
the room's output whatever else went wrong.

Exit 0 says the announcement reached the log, which is not quite the same as every seat having
read it: while an **opening barrier round** is still open, a lane is withheld whole from the other
seats, so a `--force` close taken mid-round is not visible to them until the round releases. Use
`council.sh say` to stop a room sooner in that case.

**Exit 4 is not a failed close and must not be retried.** A re-run answers 3 on a `decided` room
and 2 (*"not ripe"*) on an `unresolved` one — and 2 is the status this skill tells a supervisor it
may retry, so read it here as "already closed", not as an invitation to `--force`, which would
rewrite the record and announce a second time. Exit 4 is `say`'s exit 6 in another verb: report
what was established, never the claim you wanted to make. The record path is still printed on
stdout, because it is the room's output either way. If the room should stop sooner, wake a seat
with `council.sh say`.

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

### A decided room closes its own terminals

**The decision is the deliverable, not the chat.** A room that reaches `decided` asks for its
participant terminals to be closed, as the last act of `decide`. Everything durable stays exactly
as `down` (without `--purge`) leaves it — the room directory, `board/decision.md`, `board/status`,
the lanes and the cursors — so `council.sh decision` and `council.sh transcript` serve the room
afterwards just as before. Only `--purge` deletes anything.

The reason it is the room's job and not the operator's is not that operators are careless. **The
moment a room decides is the moment its OUTPUT arrives**, and the output is what the operator
turns to; a reminder printed there has to be read at exactly the moment attention has moved to the
record. The case that produced this left three agent sessions running for about eleven hours,
twice in one day, the second time after the operator had said out loud they would close them.

**`decide` does not do the reaping — it asks the room's keeper to.** That is forced by the shape
of the verb: `decide` takes `--me`, so a **participant** runs it, and the seat closing the room is
closing its own terminal. A reap written inline races the process that began it. The keeper
already runs in its own process group, already holds the room's roster, and already closes every
participant terminal and exits — that is what `up --hold` uses when its owner dies — so this is a
fourth trigger on machinery that already existed rather than a second teardown path. It is a
**request**: the keeper polls, so the terminals go within one poll (about five seconds) rather
than at once. That is the right side to err on. The close announcement rings every seat first, so
each learns now rather than at its own timeout, and closing the terminals ahead of it would leave
it ringing nobody.

Three consequences worth knowing:

* **An `unresolved` close does not tear down — and `--force` is NOT the switch.** A room that did
  *not* converge is one the same close escalates to the shared mailbox as needs-human, and it is
  the room a person is most likely to want to walk into, so its seats stay up and the close says
  so, naming `down`. The rule is about a room whose question is answered; it does not reach one
  that failed to answer it. **The gate is the recorded status, not the flag.** `--force` does one
  thing only — it lifts the not-ripe refusal — so on a room that has already converged it is a
  no-op: the record still comes out `decided` and the seats still go. There is no flag that means
  "write the record and keep the seats"; if that is ever wanted it belongs on a separate
  `--keep-seats`, not on `--force`.
* **A teardown that cannot happen is reported, not pretended.** That is exit 5 above, and it names
  which of the three causes it was: no live keeper, a request that could not be written, or a
  caller with no keeper machinery in scope. Nothing is written when there is no keeper — a marker
  no keeper will ever take would sit waiting for whichever keeper the room is given next.
* **But that report is about the room's bookkeeping, never about a terminal actually closing**, and
  the difference matters because [the room is not a trust
  boundary](#the-room-is-not-a-trust-boundary). Whether exit 5 *appears* is decided by
  `state/keeper.pid` and by `state/` being writable, which are room state any participant can
  write. A pid file naming a live process that is not this room's keeper — a seat's own doing, or
  just `down` leaving a stale pid the OS then recycles — makes the close report success while
  nothing ever reaps. So `decide` says the keeper **has been asked**, which is all it establishes;
  it does not say the seats are gone. Neither prevented nor made self-revealing here, and
  `_keeper_teardown`'s header names the routes found so far — and says itself to read them as
  that and never as the set. What the room's own bookkeeping cannot report, three reads of the
  backend now can: `status`'s closed-room alarm, `council.sh terminals`, and `rooms`' `term`
  column. All three inherit the container pin's forgeability, so they narrow the question rather
  than closing it.
* **`relaunch` cancels a teardown no keeper has taken yet.** Putting a seat back up says the room
  is in use again, and it outranks a close that asked for the seats to go — it has to, or the seat
  it launches is reaped within a poll of starting. That covers the keeper that died before taking
  the request *and* the live keeper still inside its five-second poll window. What it cannot
  cancel is a reap already **in flight**: the keeper consumes the request before it starts
  closing, so from that moment there is nothing left to clear and `relaunch` cannot see it. That
  window is the length of one reap — measured at 84–383 ms for three seats on a live tmux backend
  — and a `relaunch` landing inside it can leave the room without a keeper until the next one
  repairs it. It is tracked separately rather than papered over here.

`down` is unchanged and still the way to close a room by hand: an unresolved one, one whose
teardown could not happen, or any room at all before it decides. `down --purge` remains the only
thing that deletes a record.

## Verbs

```bash
council.sh up --scenario debate --agents claude,codex,agy "question"   # or @file
council.sh status | claims | verdict | order | transcript | floor
council.sh status --only-changed | --alarms-only   # the two supervisor monitors
council.sh terminals               # <live>/<total> seats still holding one; ? unknown; - never had any
council.sh agenda | protocol | decision   # the room's own files, through the entrypoint
council.sh say <peer> "..."        # out of band, into that participant's terminal
council.sh relaunch <peer>         # put one seat back up, mid-room
council.sh decide [--force]        # write the ADR and close the room; a close recorded DECIDED
                                   # then closes its own terminals, an UNRESOLVED one leaves
                                   # them up (--force only lifts the not-ripe refusal)
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

### Room lifetime: detached (default) or `--hold`

By default `up` **launches the room and returns**. The room is detached: it outlives the shell
that started it and its **live** side lasts until something ends it: `down` (which closes the seats
and the keeper but **keeps** the room), `down --purge` or a deletion by hand (which removes the
directory as well), or the room deciding, which closes its own terminals
([above](#a-decided-room-closes-its-own-terminals)) and likewise leaves everything durable behind.
Only `--purge` and a hand deletion take the record with them. This is the right
mode for a room you want to leave running and revisit from another shell.

`up --hold` instead **stays in the foreground as the room's owner**, and binds the room's life to
this shell: when it dies for *any* reason — Ctrl-C, the pane closing, a crash, even SIGKILL — the
room's keeper closes every participant terminal and exits, so no background console is left
orphaned. Use it for a short session tied to one terminal, where walking away should tear the
room down rather than strand agents in it.

**A held room also ends when it decides, and that returns your shell.** A participant closing the
room asks the keeper to reap ([above](#a-decided-room-closes-its-own-terminals)); the keeper is
this shell's own background job, so when it reaps and exits, the `wait` above returns and
`up --hold` comes back to a prompt. **Nothing is lost when that happens** — the room directory,
the record and the transcript all survive, exactly as on the detached path; only the live seats
are gone, which is what the close asked for. So a held shell returning is the normal end of a room
that reached a decision, not a sign that something tore it down.

The mechanism, in one paragraph, because it is the kind of thing that rots silently: the owner
holds the write end of a small **canary pipe** and the keeper inherits the read end, so the
owner's death closes the write end and the keeper's read hits EOF. It is detected by EOF alone,
never by `$PPID` or `kill -0` — on macOS a dead owner's children reparent to `launchd`, which
reads as "parent alive" and cannot be reaped after the fact, so death has to be *observed*, not
polled for. The keeper runs in its own process group, so the very Ctrl-C that kills the owner
does not also kill the keeper before it can do the reaping. `down` and `--purge` still tear a
room down exactly as before; the canary is an added trigger, not a replacement.

The keeper's loop has **four** ways to return, and it is worth keeping them straight because only
three of them end the live room. Its directory going away — a backstop rather than the usual
cause, since *both* forms of `down` signal the keeper first and a signal beats a five-second poll,
and a plain `down` does not remove the directory at all; a `--hold` room's owner dying, seen as the EOF
above, on which it reaps; **a decided `decide` asking it to reap**
([above](#a-decided-room-closes-its-own-terminals)), which applies to a detached room as much as
to a held one; and its pid file naming another keeper, on which it steps down and reaps
**nothing** — the room at that path belongs to whoever superseded it, and reaping there would
close the replacement's terminals.

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

### What it establishes before it kills anything

`relaunch` closes a seat and starts a fresh one, so it asks the same question `say` asks — is
that seat really gone? — from the same shared verdict, before anything is killed, written or
launched. The three answers that are not a plain corroborated absence:

| class | what it does |
|---|---|
| `elsewhere` | **Refuses, exit 4.** The room's pin records that these seats were launched on the *other* backend. `COUNCIL_BACKEND=auto` resolves per process, so one failed socket probe sends a run to the backend where this room's container is empty for entirely correct reasons — the close then reaches nothing, and the launch starts a **second** agent for the same peer name while the live one keeps running. Both write the same lane and claim the same seat, and no verb can tell them apart. The message names the backend to pin. |
| `unreachable` | Says so and **continues**. A question the backend would not answer is not authority to refuse a documented recovery — but the close prints nothing either way, so it cannot tell you whether it restarted a dead seat or killed a live one. |
| `listed` | Says the seat is **alive** and **continues**. That is an ordinary reason to be here ("killed to pick up new permissions"); it is a statement of what is about to happen, not a refusal. |

An absence the backend corroborates says nothing at all.

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
well: every reader holds the barrier, so a restarted seat is caught up on no more than `recv`
has released — a lane holding another seat's opening position is withheld whole, and
everything in it arrives when the round does. The room is not
replayed to a restarted seat, and it is not made to be: a cursor has exactly one writer,
which is the participant itself, and that invariant is what lets the whole transport work
without a lock.

### The launcher and the protocol are regenerated, not re-run

`relaunch` rewrites `state/launch-<peer>.sh` and `protocol-<peer>.md` from the roster and
this skill before starting anything. Two reasons.

Every participant is handed the room as a **writable root** (`--add-dir <room>`, for every
agent kind) — and a scenario deliberately makes those agents adversarial to each other.
Both of those files live in the room. Re-executing a stored launcher would run whatever
another participant had put there, in a login shell, in your own process tree — and the
protocol file is what the agent is launched on: `claude` takes it as its system prompt,
`codex` and `agy` are told to read it and follow it literally.

The values regeneration reads out of `roster.json` — which agent plays the seat, the
scenario, the role, the participant names — are checked to be bare names before use. The
scenario and the names still select a file to render and text to interpolate, and
`roster.json` is in the room too. The **agent kind no longer selects a file at all**: it is
matched against `case` labels in the shared adapter module (below).

### The room is not a trust boundary

**Do not read any of the above as containment, because it is not.** Measured, all three
agent kinds, writing to a path outside the repo entirely — outside the working directory and
outside every `--add-dir`:

| agent kind | wrote where it was told |
|---|---|
| `claude --permission-mode auto` | yes |
| `codex -s workspace-write -a never` | yes |
| `agy --dangerously-skip-permissions` | yes |

`--add-dir` is an allowlist **addition**, not a restriction, and this skill launches every
participant with approval prompts turned off on purpose — that is what keeps a room running
unattended. So a participant is an agent running **as you**, and everything you can reach, it
can reach: the roster, another seat's launcher, `council.sh` itself, your home directory.

That makes regeneration and the checks above **blast-radius reduction, not a boundary**. They
remove the traversal and sed-injection forms.

One supervisor-triggered path that used to survive them is now **retired**. `--add-dir <skill>`
makes this skill's own directory writable, and the agent kind used to name a file there
(`adapters/<kind>.sh`) that `relaunch` **sourced** — so a participant could drop a
plausibly-named file in and have the roster point a seat at it, and an ordinary
`council.sh relaunch <peer>` would run it. That was measured, not theorised. A kind is now
matched by `adp_known` against `case` labels in the shared adapter module and is never turned
back into a path, so there is nothing to plant; `t13-relaunch.sh` plants a bare-named file in
both plausible directories and asserts the refusal names the kind and the plant never runs.

The class is narrower, not closed: `--add-dir <skill>` is still a writable grant over this
skill, and the scenario and role still select files here by name (bare-name-checked).

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
once per directory — **in place**, never with `relaunch`, which would only produce the same
prompt again with the seat's reading of the argument thrown away. `status`'s `STALL` line says
so, because this is the distinction it used to guess at.

`codex queue --thread` looks like a native way to wake a busy Codex participant. It is
not: it accepts the message, prints `Queued message …`, returns 0 — and delivered it
**265 seconds later** in the one run where it did deliver. Typing into the terminal
(`council.sh say`) arrives in seconds. Judge that channel by delivery, never by its exit
code.

### What `say` establishes, and what each answer means

`say` reports only what it has established, so its exit code **is** meaningful — unlike the
`codex queue` channel above. Each answer names a different next move:

| exit | answer | what it means |
|---|---|---|
| 0 | `delivered` | a turn was seen to start that was not running before the send. |
| 0 | `queued` | the participant's own client said it has taken the message for the next turn. |
| 1 | could not read a verdict | the shared turn-state module did not load. Nothing was established; the plugin install is broken. |
| 2 | nothing to send, or no such seat | no peer given, an empty message, a roster that cannot be read, or a name that is not in it. The message went **nowhere**; fix the argument. |
| 3 | has no live terminal | the backend answered and does not have that seat. It really is gone — `council.sh relaunch <peer>`. |
| 4 | cannot tell whether it is alive | the question went unanswered. **Do not `relaunch`** — that kills a live agent mid-turn and takes its context with it. The message names which of `unreachable`, `elsewhere` or `listed` applies, and the remedy for that one. `relaunch` asks the same question itself, so an operator who arrives there by another route is not relying on having read this: on `elsewhere` it refuses outright, and on the other two it says what it cannot tell before it closes anything. |
| 6 | typed, but no turn observed | the text **may be sitting unsent in the seat's input box**. Look before re-sending — a second `say` types another copy onto the first. Also the answer when the submit itself failed, where the text is definitely in the box. |

Exit 6 is not proof the message went nowhere: a turn that starts *and finishes* between two
samples looks identical, and so does a participant that was mid-turn for the whole window whose
client rendered no queued hint. The bias is deliberate — re-sending on a false `unconfirmed` is
cheap and visible, believing a false confirmation is neither. `adp_delivery_verdict` in
`shared/adapters/agent-adapters.sh` defines each verdict and what it does and does not rule out.

The confirmation window defaults to 10 s, sampled every 0.5 s; `COUNCIL_SAY_CONFIRM_SECS` and
`COUNCIL_SAY_CONFIRM_INTERVAL` override them. An unusable value falls back to the default and says
so on stderr rather than being used:

* the **window** must be a whole number of at most nine digits — long enough for any real poll,
  short enough that a typo cannot leave one running for centuries. `0` is legitimate and means
  "take one sample and decide"; a leading zero is normalised rather than refused, so `08` is eight
  seconds and not an octal error.
* the **interval** must be a plain decimal carrying at least one non-zero digit, and likewise
  bounded — so every spelling of zero falls back (`0`, `00`, `0.00`, `.00`, `000.000`, …), because
  each makes `sleep` a no-op and the bounded poll a fork storm.

Both rules live in `shared/knobs/knobs.sh`, which `shipyard tell` reads for the same two knobs —
it had the same two defects, and one module is why neither can drift back.

## Modes: turn-taking, and the opening barrier

`token` (the default) is plain turn-taking. `roundtable` adds one thing in front of it:
**the first lap runs as a barrier**.

Rotation moves the anchor, it does not remove it — in a room of two or three the second
speaker still sees the first position before forming its own, which is exactly the case
`debate` exists for. So in a roundtable room every participant writes its opening position
without waiting for a turn, and **nobody reads anyone else's until the round is complete**.
A lane stops at its withheld message instead of skipping past it, so nothing is lost and no
cursor runs ahead of unread words. A second message in an open round is refused (exit 5)
rather than queued — unless it is an urgent `--hand` one, which is allowed before and after a
seat posts.

**What satisfies the barrier is a position, and a position is `--act propose`.** Any other act
sent into an open round without `--hand` is refused (exit 7) and nothing is written; the two
refusals ask for opposite things, so they carry different codes — 5 means "already posted,
wait", 7 means "that was not a position, send it again as one". Until this was checked the
barrier counted by field alone: a seat whose first message was the literal `--help`, sent as the
default `msg`, satisfied it, and the room reached `ready-to-decide` on one proposal with zero
independent positions.

The act itself is one constant, `C_OPENING_ACT` in `lib.sh`, read by both executable bindings —
the `c_opens_round` predicate the send path asks, and the `.act` term `c_round0_positions`
filters on — so the two cannot drift apart. Round 0 is then read through **two** predicates,
named for the questions they answer because their safe directions are opposite:
`c_round0_positions` (narrow) answers *"is this a position?"* for everything that counts them,
and `c_round0_withheld` (raw) answers *"is this round-0 traffic that must not be shown?"* for
`decide`'s disclosure gate, alongside the inline tests in `c_drain` and `c_visible`. Narrowing
the withholding side is not a tidy-up but a leak, and widening the counting side is the original
bug; the names exist so neither is reachable by picking the shorter one.

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

`decide` takes `--me`, so a supervisor cannot run it at all and any participant can. That made
`decide --force` then `decision` a two-command bypass of the barrier, available to every seat
and to none of the people watching — so **`decide` now refuses from a seat that has stated no
position while the round is not verifiably closed and another seat has stated one** (see the
`--force` conditions above; a round nobody has posted in holds nothing to disclose, so any seat
may still close that). A
seat that has posted can still close the room and read the record; what that costs it is the
room, since the record is on disk, `board/status` is set, and every other seat's stop signal
fires. Loud rather than quiet, and only for a seat that took part.

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

**Arm two monitors, then stop watching.** A room is meant to run unattended, and until this
section had a procedure it did not: the primitives were all here and the numbered step telling
anyone to arm them was not, so four rooms in one evening were supervised by four hand-rolled
loops with four different blind spots (#21). The shape below is `shipyard`'s, because that skill
had already paid for it — a slow status loop that **ends itself** when the work does, and a fast
one for anything needing a person. The primitives differ; the protocol does not.

**1. The status loop — the block, every ten minutes, and it exits by itself.**

```bash
SCRIPT=<skill>/council.sh
while true; do
  bash "$SCRIPT" status --room <room> --only-changed && { echo "__room closed — exiting monitor__"; break; }
  sleep 600
done
```

`status` already exits **0 when the room is finished** and 1 while it is open, so the `&&` is
the whole termination condition — there is no separate "is it done yet" call to get wrong, and a
watch left running is a watch that ends when the room does.

`--only-changed` is what makes it liveable. A room spends most of its life with one seat
thinking, so without the flag this prints the same block every ten minutes for hours and the one
tick that matters drowns in it. With it the tick is silent until the room's meaningful state
moves — the terms are assembled where `$sig` is built in `v_status`, which is the one place they
are listed.

**It cannot hide an alarm, and that is the point.** Any tick carrying one prints in full, every
time it holds — not once when it arrives. A stalled room *changes nothing by definition*, so a
filter that suppressed a standing alarm would go quiet exactly when the room needs a person;
that is the failure this loop is a fix for, in a hand-rolled monitor that printed on verdict
changes while the verdict sat still. A **closed** room is always printed too, since that is the
tick the loop exits on.

**2. The alarm loop — anything needing a person, at a minute's cadence.**

```bash
SCRIPT=<skill>/council.sh
while true; do
  bash "$SCRIPT" status --room <room> --alarms-only && break
  sleep 60
done
```

`--alarms-only` prints the alarms and nothing else, and **prints nothing at all when there are
none** — so this stays silent until something actually needs you. Ten minutes is too slow for a
seat sitting on a permission prompt; a minute is not. It keeps no state between ticks, so unlike
the loop above there is nothing here that could go stale and swallow a standing alarm.

**It takes the same `&& break` as loop 1, and for a sharper reason than tidiness.** `status`'s
exit code is the same in this mode, so the loop ends itself when the room closes — and a loop
without that clause never ends: a finished room's floor keeps ageing, so it stays past the stall
threshold for ever, and this channel would report that once a minute until somebody noticed. If
you do stop one by hand, `TaskStop` (or whatever your runtime calls it) is the way.

**3. Check that a closed room let go of its terminals.** A room that reaches `decided` now closes
its own ([above](#a-decided-room-closes-its-own-terminals)), so usually there is nothing to do —
but that close can fail, and its own exit table says so: no live keeper, or a request that could
not be written, exits **5** and reports it once, at the moment your attention is on the record.
Both monitor loops exit on the closing tick, so nothing after that would remind you either.

That is what the closed-room alarm is for: `⚠️ this room is closed but N of M terminals are still
up` fires on the very tick the loops stop, and on every later tick. `council.sh rooms` carries a
`term` column so several rooms' seats are visible at a glance, and `council.sh terminals` asks for
one room directly. `council.sh down --room <room>` is still the way to release them.

**A zero is reported, not trusted.** On a room that closed cleanly a zero is the expected
answer — `decide` reaped the seats itself. But the count is taken through the container pin, a
file inside the room, so a room whose pin has been retargeted reads as empty in exactly the same
way. (A pin *removed* while the launchers remain is a different answer: that one alarms.) The closing tick therefore always *says* what it read — `terminals: none
of N seats is listed … a zero is not proof` — rather than falling silent, and when the read cannot
be resolved at all it raises the alarm instead. Silence on that tick is the one outcome the block
will not produce.

### What the alarms can tell you apart, and what they cannot

A seat that is **ALIVE and idle at a prompt** and a seat that is **GONE** look identical from
inside the room — a floor held, nothing arriving — and they need opposite remedies. The prompt is
answered **in place**, and the seat carries on with everything it has read; `relaunch` is for a
seat that is genuinely dead, and it **discards everything that seat has read**. Using the second
on the first throws away the argument that seat was holding.

**Which of the two the alarm can name today:**

| | can it tell? | how |
|---|---|---|
| the seat's terminal is **gone** | **partly — evidence, not proof** | the backend is asked which sessions exist, and an absence is reported only when it answered and no pin says these seats were launched on a different backend. Neither check establishes *which* container was enumerated, and the pin (`<room>/state/container-<backend>`) is a file inside the room — so a participant can point the read at an empty container and make a live seat look gone |
| the seat's terminal is **up** | **partly — same read, same limit** | a session named `council-<room>-<peer>` is listed. Anything that can reach the backend can create that name, so this is a reason not to reach for `relaunch` first, not proof of identity |
| a terminal that is up is **at a prompt** rather than working | **no** | no committed pane capture separates a prompt from a think. `adp_turn_state` (shared adapters, used by `say`) reads running/idle/queued, but `idle` cannot tell a permission prompt from a finished turn, so it would not answer this either |
| a terminal that is up is in an announced **capacity wait** | **partly** | `status` quotes a `rate_limited`-style banner where the client's chrome makes it forgery-proof — two of the three agent kinds have a committed pane capture, the third gets no annotation at all |

So the alarm says what a live seat and a dead seat **look like** (*"a session named … is listed,
which is what a live seat looks like — so do not reach for relaunch first"* / *"its terminal is
GONE … which is what a dead seat looks like … look at the terminal before running
`council.sh relaunch`"*), and when the read cannot be corroborated it says nothing rather than
guessing. Two things that wording is doing deliberately:

* **it never issues the destructive command as an instruction.** A wrong confident *gone* is the
  expensive error — it is the one that sends a supervisor to `relaunch` on a live seat mid-turn,
  discarding everything that seat has read.
* **the corroboration rules out the two accidental misreads** — a backend that did not answer,
  and a run resolved to the other backend. It does not rule out a room file that has been
  rewritten. Making this a verdict rather than evidence needs an identity a participant cannot
  forge: the backend-assigned handle (a tmux window id, an agterm session UUID) recorded outside
  the room at launch. That is filed, not done here.

A seat the room never gave a terminal — the one a human took with `--me` — is named as exactly
that rather than as a dead seat, because `relaunch` refuses it and the room is simply waiting on
a person.

**One alarm and one annotation — and the difference is not a matter of degree.**

| line | default | where it goes | pushes? |
|---|---|---|---|
| `quiet: …` | `COUNCIL_STALL_WARN_SECS`, 300s | the **block only** — never the alarms line, never `--alarms-only`. Entering or leaving the quiet state breaks `--only-changed`'s silence **once**; holding it does not | no |
| `🛑 STALL` | `COUNCIL_STALL_SECS`, 900s | the alarms line: both loops, and it bypasses every filter | yes, one `notice` to the mailbox |

The early line exists because the wedges that actually cost rooms were **323s and 344s**, well
under the 900s threshold, so nothing fired for either. It was first written as an alarm, and that
was wrong: **single turns on real rooms were then measured at 24, 51, 55 and 84 minutes** — every
one a healthy seat thinking, and every one of them past a 300-second alarm. That is the
alarm-on-the-commonest-healthy-path failure this repo has been bitten by three times, and it is
the one that teaches an operator to skim.

**Raising the number could not fix it, and that is the useful part.** Past that measurement the
threshold would sit above 5000s — above the 900s stall tier it exists to sit below, which is not a
tier but dead code. The two states are simply not separable by held time: a 323-second prompt
wedge and a 5040-second think are the same number to this clock. So **held time is the wrong
instrument, not a mistuned one**, and the honest form of the early signal is a line on the block
that a supervisor reads when the block is printing anyway. At that point a low threshold costs
nothing, which is why 300s stays — as an annotation threshold, not an alarm threshold.

What *would* separate them is turn state: the failure this was asked for was a seat that **ended
its turn** at a prompt, i.e. idle rather than running, and `adp_turn_state` in the shared adapters
already reads that. Wiring it in is a change of its own and is filed rather than half-made here.

The `🛑 STALL` alarm keeps the mailbox push to itself, for a mechanical reason as well as a
judgement one: `_stall_escalate` de-duplicates on `[stall:<peer>:<turns>]`, so a push from an
earlier tier would consume the key the real alarm needs and silence it. Both lines are skipped
during an open barrier round, where a long-held floor is normal; the quiet line is also skipped on
a closed room, and on a closed room the `STALL` alarm still fires (a closure is two files a
participant can forge, so withholding it would buy that silence) but makes no claim about any
seat's terminal.

### Reading the block

`council.sh status` is the block to read: whose floor and for how long, what is on the
table, what is open, the verdict, and the alarms (`STUCK`, `STALL`, turn conflicts, budget
exhausted, **"this room is closed but N of M terminals are still up"**, and
**"this room's state could not be computed"** — that last one means the room's
participant list could not be read, so the lines above it are incomplete and none of them
should be believed; the diagnostic on stderr says what could not be read, and
`council.sh decision` still prints the record if the room had already closed).
A `STALL` whose held time is longer than the room has existed says so in the same alarm: one
seat's clock is wrong, so the figure cannot be trusted even though the stall is real.

**A `STALL` says which remedy goes with which cause, and quotes the terminal where it can.** The
alarm used to guess — *"it may be sitting on a permission prompt"* — and the guess mattered because
the two likeliest causes need opposite moves: a seat on a permission or first-launch trust prompt
needs that prompt answered **in place**, while `council.sh relaunch` is for a seat that is
genuinely dead and discards everything that seat has read. The alarm names both rather than
guessing between them, and then narrows to one where the backend can settle it — see
["What the alarms can tell you apart"](#what-the-alarms-can-tell-you-apart-and-what-they-cannot)
above for which half of that question this skill can actually answer.

Where it can, it adds a second sentence quoting the seat's own client, read through the shared
modules shipyard's stall watchdog already uses: `adp_wait_class` (`shared/adapters`) for the class
the client announced, `policy_dispose` (`shared/policy`) for what that class means. Today the one
shape it recognises is an announced **capacity limit**, so the annotation reads *"its pane carries
a live `rate_limited` banner … if that banner is current the seat resumes by itself, so check the
terminal before relaunching"*, with the matched line printed as evidence.

> **That sentence can never remove the alarm or its push, and that is deliberate.** Everything the
> read keys on — the roster's `kind`, the container pin, the pane itself — is room state a
> participant can write, and ["The room is not a trust boundary"](#the-room-is-not-a-trust-boundary)
> records that no kind is confined at all. So the rule is: **untrusted evidence may annotate an
> operator-facing signal, never suppress one.** It says *signal*, not *alarm*, because the first
> draft of this said *alarm*, was applied to the alarm line, and left the mailbox push — the same
> event's other output — gated on peer-writable state for another round. The test is per output:
> for each thing a supervisor reads, ask what decides whether it appears.
>
> **It does not make this verb unsuppressible, and no rule about how untrusted evidence is *used*
> could — while every input is room state.** Closing it needs a held time that is not room state;
> #165's suggested direction is one, and a launch record written outside the room is another.
> Every field in the block above
> is a function of room state, `held` included: a seat that stamps a message in the future clamps
> the held time to 0 and takes the `STALL` line and its push with it (measured — #165). That is
> #40's fact, not this read's — what the read adds is annotation only, so it adds no new way to go
> dark.

A `STALL` also **pushes**: one `notice` into the shared escalation mailbox — the same
fire-and-forget channel an `unresolved` close uses (`.git/ship-escalations/`, which a shipyard
parent's escalation monitor already polls). What that buys is durability and audience: the alarm
stops being a line in a console someone has to be reading, and reaches a supervisor who never
looked at this room. **It still does not make the room self-reporting** — something has to run
`council.sh status` for the alarm to be reached at all, which is what the two monitors at the top
of this section are for. Arm them; the push is what covers the supervisor who is not watching
*this* room's console.

The push is de-duplicated within one room — the room matched on the mailbox entry's own `slot`
field, and within that, on the floor holder and the turn count — so polling does not accrue
duplicates while a room that moves and stalls again notifies afresh. **It de-duplicates against the
mailbox itself, not against a latch file**, and that is the interesting part: nothing confines a
participant, so a latch anywhere is a file the seat the notice is about could pre-write, and
pre-writing it is silence. Keying on the mailbox makes suppression **through that check**
self-revealing — to stop the notice there you must leave an entry carrying its key where you look.
Weaker than preventing suppression, stronger than pretending to. It is a property of the check and
not of the push: a forged closure, an unwritable mailbox and #165 each stop the notice by other
routes, and `_stall_escalate`'s header lists them.

`status` therefore writes, on that one path: a stalled room appends an entry to the mailbox.
(`recv` already writes too — it advances cursors, even with `--peek` — so this is not the only
reader with a side effect; the new thing is a write *outside* the room.) Participants are told they
may read the room with `status`, so a seat that does so on a stalled room will push that notice —
true and harmless, but worth knowing before you wonder who wrote it.

**The annotation is gated on the agent kind: available for two of the three council can launch.**
It is withheld for `agy`, and for any room whose roster records no kind at all. The anchor that
makes a banner the client's own — column one, where the agent's words cannot reach — is a measured
property of the two clients this repo has committed pane captures of. A kind with no captured pane
gets **no annotation**: `status` does not print a claim about a client whose chrome nobody has
looked at. Widening that list means capturing a pane of the kind and committing it
(`shared/adapters/tests/fixtures/`), never reasoning that a client probably renders like its
neighbours.

`status` exits **0 when the room is finished** and 1 while it is open — with one caveat
worth knowing: a room whose
turn budget ran out reports `unresolved` and exits 0 before anyone has written a record, so
`council.sh decision` (exit 0 only with a record) is the signal to trust when you need to know
that the room's output exists.

**A `decided` close that exited 0 leaves nothing outstanding**, because asking for the teardown is
its last act ([above](#a-decided-room-closes-its-own-terminals)) — read the record and move on.
Any other ending can leave the seats up, and `decide`'s **exit code** is what says so: the table
under ["Closing a room tells it"](#closing-a-room-tells-it-and-decide-says-so-when-it-could-not)
is the authoritative list, and each of those paths names `council.sh down` in its own message.

Two cautions for a supervisor rather than a participant. That message goes to **whoever ran
`decide`**, which is `--me`-gated to a seat — so a supervisor watching from outside sees the
record say `decided` and does *not* see the sentence, which is exactly the room-2 case that
produced this issue. And `board/status` alone cannot tell you which ending it was: it reads
`decided` on a clean close, on an exit 4 whose announcement was lost, and on an exit 5 whose
teardown could not happen. **`rooms` does tell you**, since the monitor
work landed: its `term` column runs `council.sh terminals` per room, so a decided room with live
seats reads `term 3/3` where a torn-down one reads `term 0/3`. Prefer that, or `council.sh
terminals` for one room — both read the backend without touching the seats, and both inherit the
container pin's forgeability (`_room_terminals`' header names the routes). The per-seat probe is
[`say`](#what-say-establishes-and-what-each-answer-means), and its cost is in the next sentence,
so reach for it when you need a single seat's answer rather than the room's: `council.sh say
<peer> "…"` answers **exit 3** when that seat has no live terminal, and **exit 4** when the room was
launched on the *other* backend — which is the caveat that makes reading `tmux ls` by hand
unreliable here, since `COUNCIL_BACKEND=auto` resolves per process and the seats may be in the
other container entirely. The cost of asking is that `say` types into the seat if it *is* alive.

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
| `lib/term.sh` | the terminal a participant lives in (agterm or tmux) — a thin adapter over the shared driver |
| `lib/agent-driver.sh` | vendored copy of the shared agent-console driver (`shared/driver/agent-driver.sh`); `term.sh` delegates to it |
| `lib/flow.sh` | vendored copy of the shared flow-guard interpreter (`shared/flow/flow.sh`); `room-graph.sh` evaluates the room's graph through it |
| `lib/room-graph.sh` | the room's turn cycle as a declared flow graph; `c_phase` reads it through the shared guard (opening/exchange/closing/decided) and `status` shows the phase, while the transport's opening gate is the one shared `c_round_open`/`c_round_closed` accessor (`lib.sh`) every reader consults instead of re-deriving the barrier |
| `lib/claims.jq` | the argument graph and the closure rules |
| `lib/agent-adapters.sh` | vendored copy of the shared per-agent-kind adapters (`shared/adapters/agent-adapters.sh`); `up.sh` renders every launcher through it |
| `protocol/_channel.md` | the channel rules every participant gets |
| `scenarios/*.md` | roles per scenario |
| `tests/run-all.sh` | the suite (`--full` adds load and latency runs) |

`lib/term.sh` is a thin council **adapter** over the shared agent-console driver
(`shared/driver/agent-driver.sh`, vendored beside it as `lib/agent-driver.sh` and kept
byte-identical by `scripts/sync-driver.sh` and the repo gate's check 11): it maps council's
knobs onto the driver's `DRV_*` variables and delegates each `ct_*` verb to the matching
`drv_*` one. A backend bug is fixed once, in the shared driver — there is no second copy here
to keep in step. The driver is vendored rather than imported because a Codex plugin cannot
depend on another plugin, so a cross-plugin source would work in one agent and silently break
in the other.

`lib/up.sh` stands in the same relation to the shared **adapter** module
(`shared/adapters/agent-adapters.sh`, vendored as `lib/agent-adapters.sh`, same sync and same
gate). How a kind is started — its binary, its unattended-approval flags, how it is granted a
directory and how it receives its protocol — lives there and is shared with `shipyard`; council
keeps what is council's: the roster, the protocol file, the launcher's `COUNCIL_ROOM`/`COUNCIL_ME`
preamble, and the sentence each participant is greeted with. **There is no longer a per-kind file
in this skill.** Council enumerates no kinds of its own: it admits whatever `adp_known` accepts
and picks its greeting from `adp_protocol_mode`, so a kind added to the shared module works here
with no edit — which is also what retired the plant-a-file path above. Council launches every seat
at the module's `sandboxed` approval level, never `full`; `shipyard` is the caller that uses
`full`, and both are pinned by `shared/adapters/tests/t-callers.sh`. **Read that as a knob, not as
containment**: it changes only `codex` (`-s workspace-write -a never` rather than
`--approve-for-me`), while `claude` still gets `--permission-mode auto` and `agy`
`--dangerously-skip-permissions` at either level — as the trust table above records, and as "The
room is not a trust boundary" says outright.
