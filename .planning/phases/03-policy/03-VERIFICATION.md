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

## Later — ESC-01's "both skills use it" became true on council's side (#17 → PR #162)

Worth recording because the row above read as stronger than it was. At exit, council used this
module for **ESC-04 only**: an unresolved close wrote to the mailbox. It called `policy_dispose`
nowhere, so the one disposition table had exactly one consumer, shipyard, and council's room STALL
alarm went on guessing a cause in prose — which `shared/adapters`' own header had already named as
the same blind spot from the other end.

`council.sh status` now routes a long-held floor through `adp_wait_class` + `policy_dispose` before
alarming, so ESC-01 has a second consumer and ESC-03 a second surface. Two things moved into the
shared modules with it, by the rule that the module owning the KIND of knowledge is the right home:

* `policy_park_advice` (here) — ESC-03 said to a person. Both supervisors print it; the remedy
  clause stays with each caller, because what **not** to do differs per skill.
* `adp_wait_anchored` (`shared/adapters`) — whether the banner anchor is evidenced for an agent
  kind. council admits every kind; shipyard admits exactly the two with committed pane captures, so
  the gate is called only from council today and named in shipyard's docs as already present.

**One rule the review forced out of it, worth carrying past this phase.** The first draft let a
recognised class REPLACE council's stall alarm. Every fact that read keys on — the roster's `kind`,
the container pin, the pane itself — lives in the room directory, which is the participant's own
writable root (#40), and two reviewers reproduced the consequence: a seat silencing the
supervisor's alarm about itself, one of them end to end on a real capture with an honest roster. So:

> Untrusted evidence may ANNOTATE an operator-facing signal, never SUPPRESS one. A peer-writable
> value that changes how a signal reads is fine; one that decides whether the signal appears is not.

It says *signal*, not *alarm*, and that word cost a round: stated as "alarm" it was applied to the
alarm line, and the mailbox push — the same event's other operator-facing output — stayed gated on
peer-writable state until a second review round. The test is per **output**.

Where suppression cannot be prevented, the rule's stronger form is to make it **self-revealing**:
council's push de-duplicates against the mailbox rather than a latch file, so silencing it costs an
entry in the directory the supervisor reads. Nothing confines a participant (SKILL.md, "The room is
not a trust boundary"), so that property is worth more here than any unreachable-file argument.

Both are what a later consumer of a screen-derived class should inherit; `policy_dispose` is what
turns the class into the wording.

**Still open, and not this change's:**

* `context_full` disposes to `compact`, and council has no **wired** compaction path — a ceiling
  falls through to STALL, whose only automated remedy is a relaunch that discards the seat's
  context. (A supervisor can still type `/compact` by hand through `council.sh say`, over the same
  driver `shipyard-compact.sh` uses; what is missing is the compact-and-resume wiring.) **#161**
  (shipyard's `ctx_*` readers and its compact-and-resume script have no council caller). Routing
  through `policy_dispose` rather than testing classes directly is what makes that arrival a single
  arm when someone takes it.
* The push reaches the mailbox a shipyard parent already polls, but something must still run
  `council.sh status` — nothing does so unattended. **#21**.
* The remaining wedge shapes #17 names (permission prompt, trust prompt, crashed CLI) need a
  committed pane capture per kind before any anchor may be widened. **#17** is re-scoped to that
  remainder and stays open; **#128** is the same missing-capture problem from shipyard's side.
