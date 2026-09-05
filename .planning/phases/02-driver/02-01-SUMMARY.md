# SUMMARY — 02-01 · shared-driver mechanism (DONE)

**Requirement:** DRV-04 / MIG-02 (one source of truth for shared code across two plugins).
**Commit:** `236bd20` on branch `refactor/harness-core` (local, not pushed).

## What was built
- `shared/driver/agent-driver.sh` — the one canonical driver (drv_* interface; bodies are stubs
  until 02-02).
- `shared/driver/targets.txt` — the list of vendored copies.
- `scripts/sync-driver.sh` — copies canonical → each target.
- `scripts/check.sh` **check 11** — reds on drift / missing copy / empty list / missing canonical
  (fails closed).
- `scripts/check-test.sh` — two probes (drift, missing copy) pinning the exact message.
- Vendored copies in both plugins.

## Verification
- `make check` green.
- `make check-test` green — **70 assertions, 0 not proven**, the two new probes among them.
- All four fail-closed arms verified by hand.

## Result
The Codex "no cross-plugin dependency" blocker (C1) is answered: a plugin ships its own copy,
the gate keeps the copies identical. Phases 2–4 are unblocked. Next: 02-02 fills the driver body.
