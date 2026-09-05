# REQUIREMENTS — Shared agent-harness core

> One REQ-ID per capability. Prefixes name the layer:
> **DRV** driver · **FLOW** guard/flow · **ESC** escalation policy ·
> **LIFE** process lifetime · **LOAD** fleet admission · **MIG** migration ·
> **GATE** repo-law (non-negotiable, cross-cutting).
>
> Priority: **P0** must-have for the phase to ship · **P1** should-have · **P2** later.
> Acceptance is written so it can be verified by a test or a demonstrable run.

---

## Driver — the agent-console wrapper (layer 1)

### DRV-01 · Backend-agnostic session control — P0
One module drives a console over **agterm or tmux** behind a single interface:
`launch(kind, cwd, goal) → session`, `tell(session, text)`, `submit(session)`,
`read(session) → transcript`, `kill(session)`.
**Accept:** the same calling code launches, types into, and kills a session under agterm and
under tmux with no backend branch in the caller; backend is auto-selected as council's
`ct_backend` does today.

### DRV-02 · Agent-agnostic via adapters — P0
Agent-kind specifics (how claude / codex / agy are started with a goal, how an approval or an
answer is phrased) live only in `adapters/<kind>.sh`. Adding an agent kind is one adapter and
touches no driver or caller code.
**Accept:** claude, codex and agy each launch and receive a directive through the same driver
calls; a fourth stub adapter can be added without editing the driver.

### DRV-03 · Normalized signal read — P0
`signal(session) → AgentSignal` returns one of a fixed vocabulary — `working`,
`awaiting_turn`, `crashed` (liveness); `access_request`, `plan_review`, `question`,
`escalation` (needs-human); `rate_limited`, `context_full`, `overloaded`, `quota_exhausted`
(capacity); `auth_required`, `error` (fault) — each carrying `class`, `blocking`, optional
`resume_at`, and a raw `payload`.
**Accept:** for claude, the Notification/Stop/PostToolUse hooks map to
`access_request`/`awaiting_turn`/`working`; for codex, transcript-tail detection yields the
same vocabulary; unknown output degrades to `working`/`crashed` via exit code, never an
unrecognised state.

### DRV-04 · One driver replaces two copies — P0
The driver supersedes both `council/lib/term.sh` and `shipyard-backend.sh` terminal logic;
the two skills call the shared module. Net shell LOC for backend handling goes **down**.
**Accept:** no terminal-backend function is defined in two places; a duplication scan finds no
parallel `ct_*` / backend pair.

---

## Guard — the flow interpreter (layer 2)

### FLOW-01 · Declared step-graph — P0
A flow is a graph of nodes; each node declares `enter` (what to tell the agent),
`done_when` (a **mechanical** completion predicate over signals/artifacts), `on_done`
(transition → next | emit-artifact | close), and `on_block` (defer to policy).
**Accept:** a graph is data the interpreter reads; the interpreter contains no skill-specific
branch.

### FLOW-02 · Mechanical transitions only — P0
No node transition may depend on a model's judgement. Closure conditions are facts:
a signal arrived, an artifact exists, a turn budget elapsed, all objections are closed.
**Accept:** council consensus/closure is computed by rule (as `claims.jq` does today), not by
asking an agent; a review of every `done_when` shows no LLM call in the transition path.

### FLOW-03 · shipyard as a one-node graph — P0
`shipyard`'s pipeline is expressed as a single node: give the goal, wait for the terminal
artifact (PR opened / merged), done.
**Accept:** a shipyard run is driven end to end by the interpreter over a one-node graph with
no bespoke supervision loop in the skill.

### FLOW-04 · council as a turn-cycle graph — P0
`council`'s protocol is expressed as a multi-node graph with participants and turn order;
the interpreter gates **whose turn it is**, replacing per-reader barrier polling.
**Accept:** turn admission is decided in one place by the guard; the opening round still runs
as a barrier; the race class fixed by recent commits cannot recur because no reader polls a
shared barrier.

### FLOW-05 · Multi-agent turn-taking — P1
The interpreter drives **N agents in gated turns** (council) as well as **one agent to
completion** (shipyard) from the same engine.
**Accept:** a node is addressable to a specific participant or to the single agent; a
council room with ≥ 2 participants and a shipyard run both run on the same interpreter binary.

---

## Escalation policy (layer 3)

### ESC-01 · One disposition table — P0
A single policy maps each blocking `AgentSignal` to a disposition: auto-resolve or
hand-to-human. Both skills use it; there is no second copy.
**Accept:** `question`, `escalation`, `plan_review` route to the human mailbox;
`rate_limited` parks and reschedules; the mapping lives in one file.

### ESC-02 · Safe-set auto-approval is default-deny — P0
`access_request` is auto-approved only for an explicit allowlist (edits, git status/add/commit,
tests, builds); everything else (network, `git push`, destructive commands) is denied and
escalated. The allowlist is declared, not inferred.
**Accept:** a request outside the allowlist is never auto-approved; the boundary is a readable
config, and worktree isolation is the containment.

### ESC-03 · Rate-limit time is trusted from usage, not the banner — P0
A `rate_limited` disposition sets `resume_at` from the agent's own usage view, never from a
scrollback banner (whose time is when the window *ran out*, not now). When unsure, re-probe
rather than sleep on a stale timestamp.
**Accept:** a stale banner cannot park a run into the past; a run parked on a rate limit
resumes at a verified time.

### ESC-04 · Human hand-off via the existing mailbox — P0
Human escalations are written to `.git/ship-escalations/`, resolvable identically from the
main checkout and every worktree.
**Accept:** an escalation raised from any worktree lands in the one mailbox and is visible to
the human-facing reporter.

---

## Process lifetime / reaping (cross-cutting fix)

### LIFE-01 · Owner death reaps the whole tree — P0
When the owning guard dies **for any reason** (clean exit, SIGKILL, OOM, GUI-session
recycle), every agent session and child it spawned is terminated — no process reparented to
launchd survives.
**Accept:** killing the guard with SIGKILL leaves no agent console and no descendant alive
within a bounded grace period.

### LIFE-02 · Canary, not $PPID — P0
Liveness of the owner is detected by an **inherited pipe fd going EOF**, never by `$PPID` or
`kill -0 $PPID` (which read as alive after reparenting).
**Accept:** no reaping path reads `$PPID`; the canary fires on owner death even after the
child would have been reparented.

### LIFE-03 · One process group per run + escalating kill — P0
Each run's agent tree runs in its own process group; teardown is `TERM` then `KILL` on the
**group**. No agent is launched with `nohup` / `disown` / a detaching `setsid`.
**Accept:** a grep of the shipped scripts finds no `nohup`/`disown` on an agent launch and no
`setsid` on the agent itself; closing a session HUP-reaps its subtree.

### LIFE-04 · council keeper gains a live owner — P0
The council keeper stops being an immortal directory-poller: it also reaps on owner-canary
EOF and, on teardown, closes every participant terminal. An interactive `up --hold` mode ties
a room's life to the launching session.
**Accept:** killing the owner of a `--hold` room tears down keeper and all participant
consoles; an abandoned room no longer leaves a supervisor polling forever.

---

## Fleet admission / load control (cross-cutting fix)

### LOAD-01 · Concurrency cap — P0
A fleet admits a new run only while live runs are below a configured `max_runs`, sized to the
machine (default small on ~16 GB).
**Accept:** with `max_runs = N`, an N+1-th run stays queued until a slot frees; the cap is
one enforced check, not scattered guesses.

### LOAD-02 · Memory-pressure gate — P0
A run leaves the queue only when memory headroom is available now — measured by macOS memory
pressure, not raw free pages or a single spot check.
**Accept:** under memory pressure the queue holds instead of admitting; a reproduction of the
incident conditions does not drive the machine to a WindowServer recycle.

### LOAD-03 · Paced recovery, no storm — P0
After a mass loss (a GUI-session recycle killing every agent), the fleet re-admits runs
**gradually** through the same gates, never all at once.
**Accept:** a simulated recycle followed by recovery admits runs one at a time under the cap,
not a simultaneous relaunch.

---

## Migration (both skills onto the shared core)

### MIG-01 · Skill surface unchanged for users — P0
`shipyard` and `council` keep their entrypoints, verbs, and portable-markdown packaging under
`plugins/`. Only the coordination core underneath changes.
**Accept:** existing documented commands behave as before; SKILL.md instructions stay accurate
(AGENTS.md: documented behaviour must match the skill).

### MIG-02 · Shared code has one home and one source of truth — P0
Shared runtime code lives in exactly one place with a decided location that respects the
one-source-of-truth symlink model; it is not copied into both plugins.
**Accept:** the shared module is defined once; `make check` confirms no duplicate real file;
the location decision is recorded (a `CONTEXT.md` decision).

### MIG-03 · Incremental, test-guarded rollout — P1
Migration proceeds driver → policy → guard, each landing behind its own passing tests before
the next; council and shipyard keep working at every step.
**Accept:** each phase ships independently with green tests; no phase requires a big-bang cutover.

---

## Repo-law — non-negotiable, every phase (GATE)

### GATE-01 · `make check` and `make check-test` stay green — P0
Every commit passes the gate; new rules the gate cannot see get a probe added to
`check-test.sh` or a stated caveat where the rule lives.
**Accept:** CI/local gate is green on every commit of every phase.

### GATE-02 · Generic-only (rule zero) — P0
No machine-, person-, company-, or forge-specific value, default, example, or comment in any
tracked file; machine specifics are environment variables, never defaults.
**Accept:** the leak scan passes; examples are placeholders; no absolute home paths or private
names in code, commits, PRs, or comments.

### GATE-03 · Portable across Claude Code and Codex — P0
The shared runtime works under both host runtimes and both marketplace manifests; anything
Codex cannot express as a manifest dependency is stated in docs.
**Accept:** both `.claude-plugin` and `.codex-plugin` install the affected plugins from the
clone; the change is verified by running, not only reasoned about.

### GATE-04 · English, conventional commits, labels — P1
All prose English; one logical change per commit under Conventional Commits; every issue and
PR carries one kind label and one `area:` label.
**Accept:** commit history and PR/issue labels conform; no attribution footers.
