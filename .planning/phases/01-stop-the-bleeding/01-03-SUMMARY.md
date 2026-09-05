# SUMMARY — 01-03 · LIFE-03 shipyard-side reaping (SHIPPED)

**Requirements:** LIFE-03 (process group + escalating kill; no-detach reaping — shipyard side).
**Plan:** issue **#90** (+ decision 90-1, answered Option A under delegation). **Ship:** PR **#93**
→ merged `ea6ed4c`.

## Decision 90-1 (answered by me) — corrected the issue's wrong assumption
The child caught that the issue's goal-1 assumed a council-style symmetry that does not hold:
shipyard's continuity watcher is **designed to outlive its transient launcher** and be re-ensured
idempotently per tick (t7), so a launcher-held canary would reap it after every launch and break
the feature. Production owner-death is already handled by the **agterm-session path**; the `nohup`
mode is test-only. Chosen **Option A**: an OPT-IN owner-hold canary + process group on the detached
path; default detached + agterm paths unchanged; `$PPID` scoped out of the reaping decision only
(kept in the lifecycle-lock owner probe, which is not a reaping decision — out of scope); honest
docs; a faked-owner test.

## What shipped
- `shipyard-continuity.sh` (+169): opt-in owner-hold on the detached path — armed launcher holds a
  canary write end, the detached watcher inherits the read end in its **own process group**, reaps
  itself + group on owner-EOF; fd-inheritance footgun closed. Default detached and agterm-session
  paths unchanged.
- SKILL.md (+16): honest docs — production owner-death guarantee is the agterm-session path; the
  canary hardens the detached path for a future long-lived/tmux holder (or the test).
- `tests/t10-continuity-canary.sh` (213 lines, 21 checks).

## Verification (on the head)
- `make check` + shipyard suite green. **t10 PASS (21 checks)**: faked-owner reaping; the
  with/without process-group control; **case E asserts the reaping path reads no `$PPID`** (comments
  stripped) — the LIFE-03 acceptance.

## Result
The shipyard supervisor's detached path now reaps on owner death with a process group, `$PPID`-free.
**Phase 1 is fully closed:** LOAD (#87) + LIFE council (#89) + LIFE shipyard (#93). The crash and the
orphaned-supervisor class are both fixed across both skills.
