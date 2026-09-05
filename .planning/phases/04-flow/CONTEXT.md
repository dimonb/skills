# CONTEXT — Phase 4: Flow guard (interpreter core)

GSD discuss-phase for the flow interpreter (issue #95, FLOW-01/02). The graph schema and
interpreter contract were escalated as a decision before any code was written (the issue asked for
exactly that) and approved by the user. Decisions taken:

## Contract decisions

1. **A flow is data, declared in shell (not JSON).** Nodes are registered with `flow_node` into
   associative arrays and run with `flow_run <start>`; the interpreter reads the graph and carries
   no skill-specific branch (FLOW-01). Chosen over a JSON graph read by `jq`: it mirrors the
   driver's source-only shell module (`shared/driver/agent-driver.sh`), needs no parser, keeps one
   language, and is tested the same way. The graph is still data — a handful of `flow_node` calls.

2. **`done_when` is a FIXED, model-free predicate vocabulary** — `signal`, `artifact`, `budget`,
   `check`. Because the vocabulary is closed and every member is a deterministic read, "no node
   transition depends on a model" (FLOW-02) is a STRUCTURAL property of the interpreter, not a
   convention a reviewer must re-check per graph. `check <command>` is the general hatch for a
   computed fact — council's `claims.jq` rule-based closure ("all objections closed") lives here —
   and is required to be a model-free command; the test asserts predicate evaluation prompts the
   agent nothing. Chosen over "any caller command for every done_when", which would make the
   FLOW-02 guarantee a convention rather than a structural fact.

3. **On-block defers to a policy seam; the policy is stubbed default-deny.** When a node stalls or
   times out without completing, `on_block` (default `policy`) consults `policy_dispose`; a
   `resume` re-polls the same node bounded by `FLOW_MAX_BLOCKS`, anything else parks (needs-human,
   exit 10). `policy_dispose` is defined by `flow.sh` ONLY if the caller has not already sourced the
   real one, so the Phase-3 policy (#94, `shared/policy/`) drops in behind the same name with no
   interpreter change. Default-deny (return `human`) matches #94's intent.

4. **The vendoring + drift gate is generalized to any shared module.** `check 11` and
   `scripts/sync-driver.sh` iterate every `shared/<mod>/` (canonical = the lone `*.sh`, each
   `targets.txt` lists its copies); a malformed module — no canonical, several, or no target list —
   reds closed. Chosen over mirroring `check 11` into a driver-specific `check 12`: the repo already
   generalized `check 10` for the same "a copied check rots" reason, and the imminent Phase-3 policy
   module is then covered with NO further gate change. `sync-driver.sh` keeps its path (name now
   historical) so every existing reference stays correct; the driver and both skills are otherwise
   untouched.

## Scope

This task is the interpreter core + one tiny, skill-agnostic example graph + tests only. Expressing
shipyard as one node (FLOW-03), council as a turn cycle (FLOW-04), and multi-agent turn-taking
(FLOW-05), plus the migrations, are separate later issues. Nothing calls the interpreter yet; no
behaviour change to either skill.

## Open items carried forward

- The driver's `drv_signal` today is coarse (`live|idle` / `busy` / `dead`). The interpreter reads
  it for stall detection and disambiguates "idle-and-done" from "idle-and-blocked" via `done_when`
  (checked first). The richer AgentSignal (DRV-03, Phase 3) strengthens block detection but is not
  required by the core.
- `policy_dispose`'s richer dispositions (rate-limit park with `resume_at`, safe-set auto-approve)
  arrive with #94; the interpreter already routes every block through the seam.
