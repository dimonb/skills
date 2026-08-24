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
council.sh decide          # write the decision record and close the room
```

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

## A note on permissions

Agents differ in how they grant a participant the right to run the room's one command.
Claude Code and Codex take it declaratively at launch. Antigravity asks interactively, per
command prefix — grant *always allow commands that start with `bash <skill>/council.sh`*
once, or that participant will sit on a permission prompt while holding the floor.

Full documentation, including the failure modes that are worth knowing before they cost
you an evening: [`skills/council/SKILL.md`](skills/council/SKILL.md).
