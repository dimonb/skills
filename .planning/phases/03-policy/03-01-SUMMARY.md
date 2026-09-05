# SUMMARY — 03-01 · ESC policy module (SHIPPED)

**Requirements:** ESC-01/02/03/04. **Plan:** issue **#94**. **Ship:** PR **#96** → merged `f47f15a`.

## What shipped
- `shared/policy/policy.sh` (+ `targets.txt` + vendored copies) — one `policy_dispose` table mapping
  each blocking `AgentSignal` to a disposition, used by both skills (ESC-01).
- **ESC-02** default-deny: `access_request` auto-approved only for an explicit allowlist; everything
  else denied + escalated.
- **ESC-03** rate-limit `resume_at` from usage, not the scrollback banner.
- **ESC-04** council's unresolved rooms now route to `.git/ship-escalations/` (council had no mailbox
  before — additive). Also a review fix: reject a slot with `/` or `..`; the drift-gate stated
  honestly.
- `shared/policy/tests/t-policy.sh` (88 checks) + a council `t17`.

## Coordination (directive 94-1)
Followed the merge-order plan: no bespoke drift check / `sync-policy.sh`; the module relies on the
generalized shared-module gate from #97. Held at ready-to-merge until #97 merged, then merged onto
it. Verified by a local trial-merge before the real merge: 0 conflicts, `make check` green, and the
generalized gate catches a `shared/policy/` copy drift.

## Verification
- ship review: 0 blocking (fixes folded). Independently: on final main `make check` green, and the
  one generalized drift gate catches driver + flow + policy copy drift.

## Result
Both skills share one escalation-disposition table; the flow guard's default-deny stub is now backed
by the real table behind the same name. Phase 3 done.
