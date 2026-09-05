# SUMMARY — 01-01 · LOAD admission gate (SHIPPED)

**Requirements:** LOAD-01 (concurrency cap), LOAD-02 (memory-pressure gate), LOAD-03 (paced
recovery, via the cap). **Plan:** issue **#86**. **Ship:** PR **#87** → merged `dd996eb`.

## What shipped
- `plugins/shipyard/skills/shipyard/shipyard-admission.sh` (new, ~118 lines) — the gate.
- `shipyard-launch.sh` (+14) calls the gate **before** creating any worktree/terminal.
- `shipyard-lib.sh` (+5); SKILL.md/README document the cap, the memory gate, and the env overrides.
- `tests/t9-admission.sh` (new, 42 checks): the refusal exit precedes creation; cap and
  memory-gate decisions with the detector faked.

## Behaviour
- Refuses when live `ship-*` slots ≥ `SHIPYARD_MAX_SLOTS` (default **2**) or under macOS memory
  pressure (floor **10%** free), with an actionable message; otherwise admits.

## Verification
- ship review: 3 rounds, 0 blocking.
- Independently re-verified on head: `make check` + shipyard suite (incl t9) green.
- **Live check on merged main:** `admission: OK — slots 0/2, memory 46% free (floor 10%)` — a
  legitimate launch at 0 slots is admitted, so the gate does not block normal use.

## Result
The desktop-recycle crash is fixed at its cause: the fleet can no longer launch past what a 16 GB
machine tolerates. Running up to 2 slots is now safe. LOAD-03 is satisfied by the cap (a mass
relaunch is paced by it); no separate scheduler was needed.
