# flow.sh — the ONE flow-guard interpreter, shared by shipyard and council.
#
# SOURCE OF TRUTH: shared/flow/flow.sh. Do NOT edit the vendored copies under
# plugins/*/skills/*/ — edit here, then run `scripts/sync-driver.sh` (which vendors EVERY
# shared/<mod>/ module, flow included, not the driver alone). The repo gate (scripts/check.sh,
# check 11) fails if any copy drifts from this file.
#
# Why a vendored copy and not a symlink or an import: a Codex plugin is installed as a
# self-contained directory and cannot depend on another plugin, so each plugin carries its own
# copy of shared code. The gate — not the filesystem — is what keeps the copies one source of
# truth. This is the same mechanism the shared driver uses.
#
# WHAT THIS IS: a tiny interpreter that drives an agent through a DECLARED GRAPH OF STEPS with
# MECHANICAL transitions only (FLOW-01, FLOW-02). A flow is data — nodes registered with
# `flow_node`, run with `flow_run <start>`. The interpreter reads the graph and contains NO
# skill-specific branch, and NO node transition consults a model: every completion is a fact
# (a signal token, a file on disk, a poll budget, or a deterministic command's exit status).
#
# LAYERING — this sits ON TOP of two seams it does not itself provide:
#   * the driver (`drv_tell` / `drv_submit` / `drv_signal`, from shared/driver/agent-driver.sh):
#     how the interpreter speaks to and reads an agent console. The CALLER sources the driver;
#     flow.sh only calls the `drv_*` functions, exactly as a plugin caller composes the two.
#   * the escalation policy (`policy_dispose`, Phase 3 / #94): how a blocking signal is disposed.
#     flow.sh ships a DEFAULT-DENY stub (see `policy_dispose` below) used ONLY when the caller has
#     not already sourced the real policy, so the real table drops in behind the same name with no
#     change here.
# Nothing calls this interpreter yet; migrating shipyard (one node) and council (a turn cycle)
# onto it are separate later changes (FLOW-03/04/05).
#
# Source only, never execute. Sourced into a shell that may run `set -u`, so every optional
# variable is read as `${VAR:-}`. The baseline interpreter is bash >= 5 (associative arrays); a
# caller started by an older bash re-execs into a modern one before sourcing (council.sh does
# exactly that).

# A version marker, bumped when the body changes, so sync + the drift gate stay easy to prove.
_FLOW_VERSION=1

# --- the graph, as data --------------------------------------------------------
# One associative array per node field, keyed by node name; `_FLOW_NODES` is the registration
# order/registry. A node declares the issue's four fields:
#   enter      text to `drv_tell` + `drv_submit` on entry (optional — a node may only wait).
#   done_when  a MECHANICAL predicate (vocabulary below); true => the node is complete.
#   on_done    the transition once done: `goto:<node>` or `close`.
#   on_block   what to do when the node blocks (agent stalled / timed out): `policy` (default —
#              defer to `policy_dispose`), `goto:<node>` (a declared retry/alt path), or `close`.
# Plus one convenience that expresses the issue's "emit-artifact" outcome by composition:
#   emit       a path written when the node completes, BEFORE on_done runs. `--emit X --on-done
#              close` emits then closes; `--emit X --on-done goto:n` emits then continues.
declare -gA _FLOW_ENTER _FLOW_DONE_WHEN _FLOW_ON_DONE _FLOW_ON_BLOCK _FLOW_EMIT 2>/dev/null || true
: "${_FLOW_NODES:=}"

# Set by _flow_drive_node for flow_run to read (bash has no multi-value return).
_FLOW_OUTCOME=""
_FLOW_SIG=""

# Tunables (all optional; defaults suit a real run, the tests override `flow_sleep`):
#   FLOW_SESSION       the resolved driver session name the graph is driven against. REQUIRED at
#                      flow_run time — the graph is the data, the session is the run.
#   FLOW_MAX_POLLS     polls of drv_signal before a node is declared timed-out (a block). Default 600.
#   FLOW_POLL_INTERVAL seconds `flow_sleep` waits between polls. Default 1.
#   FLOW_MAX_BLOCKS    blocks ONE node may hit before it is parked instead of resumed — it is
#                      resumed on the first FLOW_MAX_BLOCKS-1, parked on the last. Default 3.
#   FLOW_MAX_NODES     transitions before flow_run aborts as a suspected cycle. Default 1000.
#   FLOW_PARK_FILE     if set, `flow_park` appends its one-line record there. The real hand-off
#                      destination is the policy layer's mailbox — deliberately NOT hard-coded here.

# flow_reset — forget every registered node. Tests call it between cases; a caller that runs more
# than one flow in a process calls it between them.
flow_reset() {
  _FLOW_NODES=""
  _FLOW_ENTER=(); _FLOW_DONE_WHEN=(); _FLOW_ON_DONE=(); _FLOW_ON_BLOCK=(); _FLOW_EMIT=()
}

# flow_node <name> [--enter TEXT] [--done-when PRED] [--on-done ACT] [--on-block ACT] [--emit PATH]
# Register (or extend) one node. Fields not named are left as they were, so a node can be built up
# over several calls; the registry de-dupes the name. This is the whole authoring surface — a
# graph is a handful of these calls, i.e. data, which is what lets one interpreter drive any graph.
flow_node() {
  local name=${1:-}
  [ -n "$name" ] || { echo "flow_node: missing node name" >&2; return 2; }
  shift
  case " $_FLOW_NODES " in *" $name "*) ;; *) _FLOW_NODES="$_FLOW_NODES $name" ;; esac
  while [ $# -gt 0 ]; do
    # Every option takes a value; refuse a trailing flag with none rather than silently consuming
    # the next flag as its value.
    case "$1" in
      --enter|--done-when|--on-done|--on-block|--emit)
        [ $# -ge 2 ] || { echo "flow_node: $1 needs a value" >&2; return 2; } ;;
    esac
    case "$1" in
      --enter)     _FLOW_ENTER[$name]=$2 ;;
      --done-when) _FLOW_DONE_WHEN[$name]=$2 ;;
      --on-done)   _FLOW_ON_DONE[$name]=$2 ;;
      --on-block)  _FLOW_ON_BLOCK[$name]=$2 ;;
      --emit)      _FLOW_EMIT[$name]=$2 ;;
      *) echo "flow_node: unknown option: $1" >&2; return 2 ;;
    esac
    shift 2
  done
}

_flow_known() { case " $_FLOW_NODES " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# --- the mechanical predicate vocabulary (the heart of FLOW-02) -----------------
# `done_when` is one of a FIXED, model-free vocabulary. Because the vocabulary is closed and every
# member is a deterministic read, "no node transition depends on a model's judgement" is a
# STRUCTURAL property of this interpreter, not a convention a reviewer has to re-check each graph:
#   signal <match>   the current drv_signal token contains <match> — "a signal arrived"
#                    (e.g. `signal idle` = the agent finished its turn; `signal dead` = it crashed).
#   artifact <path>  a file exists — "an artifact exists".
#   budget <n>       at least <n> polls have elapsed in this node — "a turn budget elapsed".
#   check <command>  a deterministic, MODEL-FREE command exits 0 — the general hatch for a
#                    computed fact, e.g. council's rule-based closure (`lib/claims.jq`) deciding
#                    "all objections are closed". The command must prompt no agent; that it is a
#                    program's exit status, never a model's answer, is what keeps FLOW-02 through
#                    this hatch too.
# `sig` is the drv_signal token already read this poll (so the `signal` kind adds no extra read),
# `poll` the count of polls so far in this node. Returns 0 when the predicate is met.
_flow_pred_met() {
  local sig=$1 poll=$2 pred=$3 kind arg
  [ -n "$pred" ] || return 1                      # no predicate => never self-completes (blocks)
  kind=${pred%% *}
  case "$pred" in *" "*) arg=${pred#* } ;; *) arg="" ;; esac
  [ -n "$arg" ] || { echo "flow: predicate '$kind' needs an argument" >&2; return 1; }
  case "$kind" in
    signal)   case "$sig" in *"$arg"*) return 0 ;; *) return 1 ;; esac ;;
    artifact) [ -e "$arg" ] ;;
    budget)   [ "$poll" -ge "$arg" ] 2>/dev/null ;;
    # A subshell isolates the caller's command: a `set -u` violation or a non-zero exit inside it
    # reads as "not met", it never aborts the interpreter. This is a mechanical check by
    # construction — a program's status, not a model call.
    check)    ( eval "$arg" ) >/dev/null 2>&1 ;;
    *)        echo "flow: unknown predicate kind: $kind" >&2; return 1 ;;
  esac
}

# An agent that has STOPPED without completing is blocked. `idle` (waiting for input) and `dead`
# (crashed) are stops; the synthetic `timeout` token (a node's poll budget ran out) is treated the
# same. `busy` and `unknown` are progress — keep polling. done_when is always checked BEFORE this,
# so an idle-because-finished node completes; only idle-because-not-finished blocks.
_flow_stalled() { case "$1" in *idle*|*dead*|*timeout*) return 0 ;; *) return 1 ;; esac; }

# Overridable seams — a caller (or a test) may define its own before sourcing this file, or
# redefine after; the later definition wins, and the `policy_dispose` guard below means the real
# policy module, if sourced first, is never shadowed by the stub.
flow_sleep() { sleep "${FLOW_POLL_INTERVAL:-1}"; }

# flow_emit <path> — write the node's completion artifact. Kept minimal and generic; the caller
# owns the directory. Overridable for a caller that wants richer contents.
flow_emit() { printf 'flow-emit\n' > "$1" 2>/dev/null || echo "flow: could not emit artifact: $1" >&2; }

# flow_park <node> <signal> — record a needs-human hand-off. The interpreter has reached a block
# the policy did not resolve. Generic on purpose: append to FLOW_PARK_FILE if set, always say so
# on stderr. The mailbox destination belongs to the policy layer, not here.
flow_park() {
  local line="flow: parked at node '$1' (signal: ${2:-unknown}) — needs human"
  [ -n "${FLOW_PARK_FILE:-}" ] && printf '%s\n' "$line" >> "$FLOW_PARK_FILE" 2>/dev/null
  echo "$line" >&2
}

# The DEFAULT-DENY policy stub (Phase 3 / #94 provides the real one). Defined ONLY if the caller
# has not already sourced a `policy_dispose` — so the real disposition table, sourced first, is
# used unchanged and this stub never shadows it. Default-deny means: hand everything to the human
# (return `human`); the interpreter parks. When #94 lands it may instead return `resume` for an
# auto-resolved signal (a safe-set approval granted, a rate limit waited out).
if ! declare -F policy_dispose >/dev/null 2>&1; then
  policy_dispose() { printf 'human'; }
fi

# --- the interpreter -----------------------------------------------------------
# _flow_drive_node <session> <node> — enter the node, then poll until it is done or blocked,
# giving policy a chance to resume a block in place (without re-sending `enter`). Reports through
# _FLOW_OUTCOME (done|block) and _FLOW_SIG (the signal at a block). No model is consulted anywhere
# in here: the loop reads a signal and evaluates a mechanical predicate, nothing more.
_flow_drive_node() {
  local session=$1 node=$2 enter poll blocks sig disp
  enter=${_FLOW_ENTER[$node]:-}
  if [ -n "$enter" ]; then drv_tell "$session" "$enter" && drv_submit "$session"; fi
  blocks=0
  while : ; do
    poll=0
    while : ; do
      # Read the signal once; done_when is checked FIRST so a node whose artifact exists completes
      # even if the agent has since gone idle or died.
      sig=$(drv_signal "$session" 2>/dev/null || true)
      if _flow_pred_met "$sig" "$poll" "${_FLOW_DONE_WHEN[$node]:-}"; then
        _FLOW_OUTCOME=done; _FLOW_SIG=""; return 0
      fi
      _flow_stalled "$sig" && break
      poll=$((poll + 1))
      # Fail CLOSED on a non-numeric FLOW_MAX_POLLS: `! [ poll -lt MAX ]` reads the comparison
      # error as "budget reached" (block now), never as "keep polling forever" the way a plain
      # `-ge` that errored would — the same fail-closed stance FLOW_MAX_NODES takes.
      if ! [ "$poll" -lt "${FLOW_MAX_POLLS:-600}" ] 2>/dev/null; then sig="live|timeout"; break; fi
      flow_sleep
    done
    # The node has blocked (stalled or timed out). If its on_block is not `policy`, hand the block
    # back to flow_run to act on (goto/close). Otherwise consult the policy: a `resume` disposition
    # re-polls the SAME node (enter is not re-sent), up to FLOW_MAX_BLOCKS; anything else parks.
    if [ "${_FLOW_ON_BLOCK[$node]:-policy}" != policy ]; then
      _FLOW_OUTCOME=block; _FLOW_SIG=$sig; return 0
    fi
    disp=$(policy_dispose "$sig" 2>/dev/null || echo human)
    blocks=$((blocks + 1))
    if [ "$disp" = resume ] && [ "$blocks" -lt "${FLOW_MAX_BLOCKS:-3}" ]; then
      flow_sleep; continue
    fi
    _FLOW_OUTCOME=block; _FLOW_SIG=$sig; return 0
  done
}

# flow_run <start-node> — drive the graph from <start-node> until a node closes, a block is parked,
# or an error. Reads FLOW_SESSION. This is the whole coordination loop, and it is mechanical: it
# transitions on _flow_drive_node's outcome, never on a model's say-so, and it names no skill.
# Exit status: 0 a node closed cleanly; 10 parked (needs human); 64 no FLOW_SESSION; 65 node
# budget exceeded (a cycle); 66 a missing or unknown node; 67 a malformed transition action
# (a bad on_done/on_block, or an empty goto target).
flow_run() {
  local node=${1:-} guard=0 act emit
  [ -n "$node" ] || { echo "flow_run: missing start node" >&2; return 66; }
  [ -n "${FLOW_SESSION:-}" ] || { echo "flow_run: FLOW_SESSION is not set" >&2; return 64; }
  while [ -n "$node" ]; do
    guard=$((guard + 1))
    [ "$guard" -le "${FLOW_MAX_NODES:-1000}" ] \
      || { echo "flow_run: node budget exceeded — a cycle in the graph?" >&2; return 65; }
    _flow_known "$node" || { echo "flow_run: unknown node: $node" >&2; return 66; }

    _flow_drive_node "$FLOW_SESSION" "$node"

    if [ "$_FLOW_OUTCOME" = done ]; then
      emit=${_FLOW_EMIT[$node]:-}
      [ -n "$emit" ] && flow_emit "$emit"
      act=${_FLOW_ON_DONE[$node]:-close}
    else
      act=${_FLOW_ON_BLOCK[$node]:-policy}
      # A `policy` on_block that reached here means the policy did not resume — park and stop.
      if [ "$act" = policy ]; then flow_park "$node" "$_FLOW_SIG"; return 10; fi
    fi

    case "$act" in
      goto:*) node=${act#goto:}
              # An empty goto target (`goto:` with nothing after it) would blank $node and let the
              # `while [ -n "$node" ]` loop exit as a CLEAN close; reject it as malformed instead.
              [ -n "$node" ] \
                || { echo "flow_run: empty goto target in action '$act'" >&2; return 67; } ;;
      close)  return 0 ;;
      *) echo "flow_run: malformed action for node '$node': $act" >&2; return 67 ;;
    esac
  done
  return 0
}
