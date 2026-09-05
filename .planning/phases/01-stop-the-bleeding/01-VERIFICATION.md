# VERIFICATION — Phase 1: Stop the bleeding

Requirement coverage. Status as of the LIFE task in flight (issue #88, slot 88).

| Req | Statement | Covered by | Status |
|-----|-----------|------------|--------|
| LOAD-01 | Concurrency cap | #87: `shipyard-admission.sh`, cap `SHIPYARD_MAX_SLOTS` default 2; t9 checks the refusal | ✅ shipped |
| LOAD-02 | Memory-pressure gate (macOS pressure, not free pages) | #87: floor 10% free, refuse under pressure; t9 with faked detector | ✅ shipped |
| LOAD-03 | Paced recovery, no storm | #87: the cap paces any mass relaunch (no separate scheduler) | ✅ shipped |
| LIFE-01 | Owner death reaps the whole tree | #89: keeper reaps participant terminals on owner-EOF; t16 case A/E | ✅ shipped |
| LIFE-02 | Canary, not `$PPID` | #89: fifo canary + `read -t` EOF; t16 case F asserts no `$PPID` | ✅ shipped |
| LIFE-03 | One process group per run + escalating kill; no detach | council: #89 (t16 case D). shipyard: #93 — opt-in canary + process group on the detached path, `$PPID`-free reaping (t10, 21 checks) | ✅ shipped |
| LIFE-04 | council keeper gains a live owner (`up --hold`) | #89: the `up --hold` CLI, t16 case E | ✅ shipped |

## Notes
- **LIFE-03 shipyard** shipped as #93 (task 01-03). Decision 90-1 corrected the issue's assumption:
  shipyard has no long-lived owner (transient launchers), so the canary is opt-in on the detached
  path and the production owner-death guarantee stays the agterm-session path — documented honestly.
- `$PPID` was scoped out of the **reaping** decision (both skills); it remains in shipyard's
  lifecycle-lock owner probe, which is not a reaping decision and not an orphan risk (out of scope).
- LOAD verified live on merged main (01-01-SUMMARY). LIFE verified via t16 (26 checks) on the
  head before merge (01-02-SUMMARY): killing a `--hold` owner reaps keeper + consoles; the tmux
  fd-inheritance fix proven with-and-without the guard.

**Phase 1 exit criteria — MET. Phase 1 CLOSED.** LOAD ✅ (#87), LIFE council ✅ (#89), LIFE shipyard
✅ (#93). The desktop-recycle crash and the orphaned-supervisor class are both fixed across both
skills. All requirements covered; no open tails.
