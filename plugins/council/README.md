# council

A **room** where several agent sessions argue one question and the room decides — or says
plainly that it did not.

Each participant is a real agent session (Claude Code, Codex, Antigravity) in its own
background terminal. They speak in turn, objections must reference what they object to,
and an objection is closed by a specific message — not by anyone declaring the matter
settled. The room finishes when nothing is open and a full lap passes with nothing new,
and then writes a decision record with the whole argument history.

```bash
council.sh up --scenario debate --agents claude,codex,agy "Synchronous or asynchronous delivery?"
council.sh status          # whose turn, what is on the table, what is still open
council.sh relaunch codex  # one participant died or wedged — put that seat back up
council.sh decide          # write the decision record and close the room
council.sh down            # release the terminals once the room has closed
```

Supervising a room is two loops, and the skill tells you to arm them rather than leaving you to
invent your own: a ten-minute `status --only-changed` block that **exits by itself** when the
room finishes, and a one-minute `status --alarms-only` check that prints nothing until something
needs a person. Neither can be talked into silence by a room that has stopped — an alarm always
breaks the filter, on every tick it holds.

## Why a room and not a chat

* **The outcome is computed.** "We agree" means: no open objection, and a full lap in which
  nobody added a proposal, an amendment or an objection. Politeness cannot end a room, and
  a lap of mutual agreement over an unanswered objection is reported as `stuck`.
* **Nothing is lost and nothing blocks.** One writer per lane, atomic publish, Lamport
  ordering — no locks anywhere. Two participants that claim the same turn are settled
  deterministically, and the loser's words stay in the record.
* **A room that fails says so.** Out of turns with an objection open? The record is written
  as `unresolved`, listing exactly what nobody closed.

## Prerequisites

`git`, `jq`, `python3`, and a terminal backend — [agterm](https://github.com/umputun/agterm)
or `tmux`. Plus the CLI of each agent you want in the room: `claude`, `codex`, `agy`.

## Scenarios

| scenario | roles |
|---|---|
| `debate` | proposer vs critic (+ a third angle) — the default for a design fork |
| `review` | author vs reviewer; the author owns writes, the reviewer only reads |
| `freeform` | the channel rules and an agenda, no roles |

A new scenario is one markdown file: front-matter plus a block per role. No code changes.

## Upgrading while a `roundtable` room is open

Upgrading council over a **live** barrier room is safe but not invisible, and it is worth
finishing the round first if you can.

The opening barrier used to be satisfied by any message a seat sent; it now requires
`--act propose`. So a round that had been closed by a message which was not a position
**re-opens** after the upgrade, with two visible consequences:

* **The barrier lap stops counting toward the room's turn total** until the round closes again,
  so `verdict --json` reports a turn count lower by one lap — the number of participants. Turns
  already taken keep their numbers; the count does not go to zero.
* **Positions already released to the other seats are withheld again** until the round completes
  for real.

Every seat that has not posted a **position** must post one — whether its opening message was not
a position, or it never sent one at all — with `--act propose`. A seat that had already posted a
real position cannot re-post: it is refused at exit 5 and limited to `--hand` until the round
closes again. That asymmetry is the reason to finish the round first where you can.

Nothing is disclosed that was not already, and nothing is lost — the re-withholding is the
cautious direction, and the messages stay in their lanes. A round in that state never
legitimately closed: it closed on something that was not a position, which is the defect the
change exists to remove.

## A note on permissions

Agents differ in how they let a participant act. Claude Code and Codex take it declaratively
at launch. Antigravity asks interactively, and about two separate things — the **command** it
runs, and every **file** it opens.

Commands have a persisted allowlist; file reads have none at all, and no flag scopes them.
What decides whether it asks about a file is not the directory but whether it was *told* the
path or worked it out itself. So the room hands participants verbs instead of locations —
`council.sh agenda`, `protocol`, `decision` — and the Antigravity seat launches with the
blanket `--dangerously-skip-permissions`, which covers what a participant reads *outside* the
room. That flag applies only to sessions this skill starts.

What still stops a room is the **first launch in a directory the agent has not seen**: both
Codex and Antigravity ask you to trust it, and the blanket flag does not answer that one.
Until you do, the participant holds the floor and looks, from the room, exactly like a wedged
session. Answer it once per directory — **in place**. Relaunching that seat only asks the same
question again, with everything it has read thrown away.

`council.sh status` narrows it and says how far. It asks the terminal backend whether the seat's
session exists, so the alarm can say what a **gone** seat and an **up** seat look like — and when
the backend cannot be asked, or the pin says this run resolved the wrong backend, it says nothing
rather than guess, because a wrong confident *gone* is what sends you to `relaunch` on a live seat
mid-turn. It is **evidence, not proof**, and the wording says so: the session list is matched by
name inside a container named by a file in the room, so a participant can point that read
somewhere else. It never issues `relaunch` as an instruction. What it cannot tell you at all is
what a terminal that IS up is doing — a trust prompt and hard thinking both read as a held floor.
The one exception is a client that announced a capacity limit, which `status` quotes with the line
it matched.

One alarm and one annotation, and the difference matters: `🛑 STALL` at 900s goes to both monitors
and writes a notice into the shared escalation mailbox; the earlier `quiet:` line at 300s goes on
the block only. It was an alarm until single turns were measured at 24 to 84 minutes — all
healthy, all past 300s — and raising the threshold past that would put it above the stall tier it
sits below. Held time cannot separate a wedge from a long think, so the early signal is a thing to
notice rather than a thing that is wrong.

Nothing here edits an agent's settings file for you.

Full documentation, including the failure modes that are worth knowing before they cost
you an evening: [`skills/council/SKILL.md`](skills/council/SKILL.md).
