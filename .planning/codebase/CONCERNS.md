# CONCERNS — technical debt and risks

Grounded in the code. These drive the requirements and reshape the plan.

## C1 · Duplicated backend, kept in sync by hand — drives DRV-04
Two ~130-line agterm|tmux backends (`lib/term.sh` ↔ `shipyard-backend.sh`) are copies **by
necessity**: Codex has no cross-plugin dependency field, so a plugin can't import another's code
(`term.sh:9-11`, `AGENTS.md:98-102`). The files say "fix a bug here, check the other"
(`term.sh:13`, `shipyard-backend.sh:17-18`). Drift is a live risk. Parallel functions:
`ct_backend`↔`shipyard_backend`, `ct_launch`↔`shipyard_launch`, `ct_{type,submit,capture,kill,
focus,target}`↔`shipyard_*`. **Unifying here needs a sharing mechanism the Codex manifest can't
express** — the central Phase-2 question (MIG-02).

## C2 · Orphan supervisors — drives LIFE-*
- **council keeper** anchors to the room *directory*, not a process: detached `( … ) &` looping
  `while [ -d "$room" ]` (`up.sh:70-72`). An abandoned/undeleted room = an immortal keeper
  polling forever with its bell fifos held open. No `nohup`/`setsid`, but no owner either.
- **shipyard watcher** needs the whole symlink-lock + PPID-probe apparatus
  (`shipyard-continuity.sh:492-715`) precisely because "nohup cannot reap" under Codex
  (`:374-376`); it has a nohup fallback (`:783-805`) that is the classic orphan path.
- Both lean on `kill -0` liveness (`shipyard-continuity.sh:394,428,…,924`; council `up.sh:65`),
  which reads a reparented process as alive. → replace with owner-canary EOF (LIFE-02).

## C3 · Unbounded fleet — drives LOAD-*
`shipyard-launch.sh` starts one terminal + one worktree per invocation with **no cap**; numeric
slots dedupe (`:104-109`) but nothing throttles total concurrency. council needs ≥ 2 participants
(`up.sh:180`) but caps neither participants nor rooms; each participant is a full agent subshell.
This is the direct cause of the desktop-recycle incident.

## C4 · Approvals are off — drives ESC-02
Agents run as the user with permission gates disabled: `agy.sh --dangerously-skip-permissions`
(`:36`), `codex.sh -a never` (`:10`), `claude.sh --permission-mode auto` (`:5`). council's own
docs state the room is **not** a trust boundary (`lib/lib.sh:192`); `relaunch` regenerates rather
than re-runs stored launchers because peers can write each other's launcher/protocol files
(`up.sh:358-382`). A shared **default-deny** escalation policy (ESC-02) is a real security
improvement over today's "auto-approve everything."

## C5 · Bash baseline mismatch — constrains DRV
council **requires bash ≥ 5** (`council.sh:26-38`); shipyard is written for **3.2** compat
(`shipyard-continuity.sh:515-530`). One shared driver cannot honour both. Phase 2 must pick a
baseline (likely ≥ 5, re-exec'd as council does) and confirm shipyard tolerates it — a design
decision, recorded in the Phase-2 CONTEXT.

## C6 · Escalation asymmetry — affects ESC-04 scope
shipyard has a human mailbox; council has none (self-reports in-room). Unifying the policy means
**adding** a mailbox path to council for needs-human signals, not just wiring an existing one.

## C7 · Tests are outside the gate — affects GATE-01 / MIG-03
Neither skill's `tests/run-all.sh` is run by `make check` (shipyard says so at
`tests/run-all.sh:6-10`). "Green tests" must mean the runner is invoked per phase; prefer wiring
the tests into the gate (`AGENTS.md:172-173`) over a caveat.
