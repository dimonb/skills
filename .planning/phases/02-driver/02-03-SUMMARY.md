# SUMMARY — 02-03 · council migration (SHIPPED)

**Requirements:** DRV-04 (replace two copies — council half), MIG-01 (surface unchanged).
**Plan:** issue **#80** (the atomic plan; no separate PLAN.md — see Phase-2 CONTEXT convention).
**Ship:** PR **#81** → merged `6fd1c08`.

## What shipped
- `plugins/council/skills/council/lib/term.sh` (164 lines, mostly removed) now delegates its
  `ct_*` functions to the shared `drv_*`; no second copy of the backend logic remains in council.
- Container name reproduced EXACTLY via caller-set vars (council keeps `-ai`, no repo-key
  transform, pins at `$ROOM/state`, no override env); session template `council-<room>-<peer>`
  stays in council.
- `tests/t15-term-adapter.sh` (5 checks): ct_name template, tmux no `-ai`, agterm `-ai`, pin
  location, unresolvable-backend refusal.

## Verification
- ship review: 1 blocker (stale SKILL.md "second copy" doc) fixed; round 2 clean.
- **Independently re-verified: the council suite (21/21 incl. t15) is green on merged main** — the
  behaviour-preserving gate for the user's priority skill.

## Result
council runs on the shared driver, behaviour identical. The riskiest regression step passed.
