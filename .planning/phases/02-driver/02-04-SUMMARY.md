# SUMMARY — 02-04 · shipyard migration (SHIPPED)

**Requirements:** DRV-04 (replace two copies — shipyard half), MIG-01, MIG-03 (incremental).
**Plan:** issue **#82**. **Ship:** PR **#83** → merged `05cf692`.

## What shipped
- `plugins/shipyard/skills/shipyard/shipyard-backend.sh` (390→322) delegates `shipyard_*` to the
  shared `drv_*`; no second backend copy remains. `shipyard-lib.sh` points the driver pin dir at
  the mailbox.
- Container name reproduced EXACTLY via caller-set vars — shipyard's DISTINCT variant: keeps
  `-ai`, DOES the repo-key `:`→`_` transform, pins in the shipyard mailbox, honours
  `SHIPYARD_WORKSPACE`/`SESSION`. shipyard's extra surface (`shipyard_note`/`notify`/
  `container_prune`/`slot_addr`/`where`/`peek_hint`) stayed in shipyard.
- `tests/t8-backend-adapter.sh` (24 checks): pin dir at mailbox, target-query `ship-<slot>`,
  absent-slot exit 1, backend select, slots listing.

## Verification
- ship review: 0 blockers. Re-verified on head: `make check` + shipyard suite (incl t8) green.
- **Load-bearing check:** `shipyard-backend.sh` is sourced by the live monitors — confirmed
  `shipyard-report.sh` still works on the migrated backend on merged main.

## Result
Driver de-duplication COMPLETE — neither skill carries its own backend copy; both on one driver.
