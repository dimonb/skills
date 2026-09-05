# CONTEXT — Phase 3: ESC policy

GSD discuss-phase. Requirements: ESC-01/02/03/04. Ran in parallel with Phase 4 (guard core).

## Plan convention
The GitHub issue (#94) is the atomic plan (per the repo's "GSD's plan-phase output is the issue").

## Decisions
1. **A shared module, vendored like the driver.** `shared/policy/policy.sh` + `targets.txt` +
   copies in both plugins, source-only. `policy_dispose(signal) -> disposition` is the surface the
   flow guard calls.
2. **ESC-02 auto-approval is default-deny.** `access_request` is auto-approved only for an explicit
   allowlist (edits, git status/add/commit, tests, builds); everything else is denied and escalated.
3. **ESC-03 rate-limit time from usage, not the banner.** `rate_limited` disposition's `resume_at`
   comes from the agent's usage view; a stale scrollback banner must not park a run into the past.
4. **ESC-04 gives council a mailbox path.** council had none; route its unresolved rooms to
   `.git/ship-escalations/` (the common git dir).
5. **No bespoke drift check (coordination with Phase 4).** The policy module does NOT add its own
   check 11 clone or `sync-policy.sh`; it relies on the shared-module gate that Phase 4 (#97)
   generalized to iterate every `shared/<mod>/`. Merge order was #97 (generalize) then #96 (policy),
   so the generalized gate auto-covers `shared/policy/`. (Supervisor directive `94-1`.)

## Coupling
Consumed by the flow guard's `on_block` (Phase 4): #97 ships a default-deny `policy_dispose` stub
under the same name, so when this module lands the real table drops in behind it with no interpreter
change.
