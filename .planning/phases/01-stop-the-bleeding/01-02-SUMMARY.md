# SUMMARY — 01-02 · LIFE keeper reaping (SHIPPED)

**Requirements:** LIFE-01 (owner death reaps the tree), LIFE-02 (canary, not `$PPID`),
LIFE-04 (keeper gains a live owner via `up --hold`). **Plan:** issue **#88**. **Ship:** PR **#89**
→ merged `413193b`.

## What shipped
- `plugins/council/skills/council/lib/up.sh` (+156): `council up --hold` binds a room to its owner.
  The owner (the foreground `up --hold`) holds the WRITE end of a fifo canary; the keeper inherits
  the READ end and, in `_keeper_loop`, uses `read -t 5 -u <cfd>` — timeout = owner alive, EOF =
  owner dead. On owner death (Ctrl-C / crash / OOM / SIGKILL) the keeper reaps every participant
  terminal and exits. Detached (non `--hold`) rooms behave exactly as before (directory-bound).
- `council.sh` (+4): the `--hold` flag. SKILL.md (+22): the owner/canary lifetime.
- `tests/t16-keeper-canary.sh` (212 lines, 26 checks).

## Review found + fixed 2 real blockers (both regression-tested)
1. **tmux server inherited the canary write fd** → keeper never saw EOF → feature broken on tmux
   (agterm unaffected). Fixed by closing the write fd for launch children. This is exactly the
   CLOEXEC/fd-inheritance footgun flagged in the original design discussion.
2. **Unguarded canary bootstrap** could hang `up --hold` under fd exhaustion (a reader on a
   writer-less fifo blocks forever). Guarded.
The 5/6-axis "stall" earlier was a session **rate limit** (reset ~13:10), not a real stop — the
disguised `rate_limited` case the ESC policy is meant to handle.

## Verification (independently, on the head)
- `make check` green. **t16 PASS (26 checks)**, covering: reaping on owner death; case D proving
  the tmux fd fix (with the guard → EOF; without → timeout); case E the real `up --hold` CLI reaps
  the keeper on owner kill; case F no `$PPID` in any owner-liveness path (LIFE-02 acceptance);
  case C backward-compat for detached rooms.

## Result
The orphaned-keeper class is closed for council: owner dies → room reaps itself, no process left
to launchd. LIFE-03's **shipyard-side** reaping remains a tracked follow-up (see 01-VERIFICATION).
