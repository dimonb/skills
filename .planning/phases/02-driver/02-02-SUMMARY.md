# SUMMARY — 02-02 · driver body (SHIPPED)

**Requirements:** DRV-01, DRV-02, DRV-03. **Plan:** `02-02-PLAN.md` + issue **#78**.
**Ship:** PR **#79** → merged `911d3db`.

## What shipped
- Real `drv_*` body in `shared/driver/agent-driver.sh` (+312 lines), a behaviour-preserving
  **superset** of both backends: `drv_backend`, `drv_shq`, `drv_container`/`_pin`, `drv_target`,
  `drv_launch`, `drv_tell`/`submit`/`read`/`kill`/`focus`, `drv_signal`. Vendored copies re-synced.
- `shared/driver/tests/` (run-all.sh + t-driver.sh, 59 checks): backend select, quoting,
  container-name for both variants, target-query, dispatch construction, signal — all faked, no
  live terminal.

## Decision on the way (#78, answered by me under delegation)
The child caught a spec error: **both backends append `-ai` identically** (not council-only). The
real differences (repo-key `:`→`_`, pin location, override env) go to caller-set vars; container
names preserved exactly. `drv_target` takes the RESOLVED name (templates stay in callers).

## Verification
- ship review: 0 blockers. Re-verified on head: `make check` + driver suite (59 checks) green.
- No skill calls `drv_*` yet, so both skills' behaviour unchanged (regression check).

## Result
The shared driver is real and tested; the two skills can now be migrated onto it (02-03/04).
