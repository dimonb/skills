# VERIFICATION — Phase 3: ESC policy

**Phase COMPLETE.** Requirement coverage (issue #94 → PR #96 → `f47f15a`).

| Req | Statement | Covered by | Status |
|-----|-----------|------------|--------|
| ESC-01 | One disposition table both skills use | `shared/policy/policy.sh` `policy_dispose`; t-policy (88 checks) | ✅ |
| ESC-02 | Auto-approval is default-deny | explicit allowlist; a request outside it is denied + escalated; tested | ✅ |
| ESC-03 | Rate-limit time from usage, not the banner | `resume_at` from the usage view; a stale banner cannot park a run into the past | ✅ |
| ESC-04 | Human hand-off via the mailbox | council now routes unresolved rooms to `.git/ship-escalations/` (was absent) | ✅ |

## Notes
- The module is gate-covered by the **generalized** shared-module drift check from Phase 4 (#97),
  not a policy-specific check — verified on final main (driver + flow + policy drift each red).
- Consumed by the flow guard at `on_block` (Phase 4): the guard's default-deny `policy_dispose` stub
  is superseded by this table behind the same name, no interpreter change.

**Exit:** all P0 met; no open tails.
