#!/usr/bin/env bash
# shipyard-agent.sh - child-agent abstraction for shipyard. Source only.
#
# The per-KIND knowledge no longer lives here. How a kind is started, how a skill is referenced
# in it, and which kind is running the parent are the shared adapter module's
# (shared/adapters/agent-adapters.sh, vendored beside this file as agent-adapters.sh and kept
# byte-identical by scripts/sync-driver.sh + the repo gate's check 11) — the same arrangement
# shipyard-backend.sh has with the shared driver. What stays here is shipyard's own policy:
# WHICH kinds it admits, the SHIPYARD_AGENT knob, the child's environment propagation and scrub
# list, the worktree it prepares for codex, and the sentence it bootstraps a child with.
# shellcheck source=agent-adapters.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/agent-adapters.sh"

# THE ADMISSION SET IS SHIPYARD'S OWN, and deliberately narrower than the module's. The module
# knows more kinds than shipyard can drive (it also serves council, which runs `agy`), and a
# child that cannot be supervised by this skill must not become launchable just because the
# shared module learned how to start it. Widening it is a shipyard decision, made in this file —
# in BOTH places: this list, and the `case` in `shipyard_agent` that reads the SHIPYARD_AGENT
# knob. That `case` cannot be built from the list (it is shell syntax, not data), so the two are
# kept adjacent and the refusal message below is derived from the list so at least the operator-
# facing half cannot drift.
shipyard_agent_kinds() { printf '%s\n' claude codex; }
# `-F`: a LITERAL match. Without it the pattern is a basic regular expression, and this function
# is the one that keeps a kind shipyard cannot supervise out — `shipyard_agent_admits '.*'`
# returning true is the opposite of what the rest of this change is built on (a kind is matched
# against literals, never interpreted).
shipyard_agent_admits() {
  [ -n "${1:-}" ] && shipyard_agent_kinds | grep -qxF -- "$1"
}

shipyard_agent() {
  case "${SHIPYARD_AGENT:-auto}" in
    codex|claude) printf '%s' "$SHIPYARD_AGENT" ;;
    auto)
      # The module answers "what is running me?"; shipyard then keeps only what it admits, so a
      # parent kind outside the set degrades to `none` (no child) rather than to a launch.
      local parent; parent=$(adp_parent_kind)
      if shipyard_agent_admits "$parent"; then printf '%s' "$parent"; else printf 'none'; fi
      ;;
    *) printf 'invalid' ;;
  esac
}

shipyard_agent_check() {
  local agent="${1:-$(shipyard_agent)}"
  if shipyard_agent_admits "$agent"; then
    command -v "$agent" >/dev/null 2>&1 || {
      echo "error: child agent '$agent' is not on PATH" >&2
      return 1
    }
    return 0
  fi
  case "$agent" in
    invalid)
      echo "error: SHIPYARD_AGENT must be $(shipyard_agent_kinds | paste -sd, - | sed 's/,/, /g') or auto (got: ${SHIPYARD_AGENT:-})" >&2
      return 1
      ;;
    *)
      echo "error: neither codex nor claude is available for the child session" >&2
      return 1
      ;;
  esac
}

shipyard_skill_ref() {
  shipyard_agent_admits "$1" || return 1
  adp_skill_ref "$1" ship
}

shipyard_self_ref() {
  shipyard_agent_admits "$1" || return 1
  adp_skill_ref "$1" shipyard
}

shipyard_agent_prepare_worktree() {
  local agent="$1" root="$2" worktree="$3" physical
  [ "$agent" = codex ] || return 0
  if [ -e "$worktree" ]; then
    physical=$(cd "$worktree" 2>/dev/null && pwd -P) || physical="$worktree"
    git -C "$root" worktree list --porcelain | grep -Fqx "worktree $physical" && return 0
    echo "error: child worktree path exists but is not a registered worktree: $worktree" >&2
    return 1
  fi
  git -C "$root" worktree add --detach "$worktree" HEAD >/dev/null || return 1
}

shipyard_agent_env_pass_default() {
  case "$1" in
    codex) printf 'CODEX_HOME' ;;
    claude) printf 'CLAUDE_HOME CLAUDE_CONFIG_DIR' ;;
    *) return 1 ;;
  esac
}

shipyard_agent_env_scrub_default() {
  printf '%s' 'CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID CLAUDE_CODE_CHILD_SESSION CLAUDE_PID CLAUDE_CODE_MESSAGING_SOCKET CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_EFFORT CODEX_SESSION_ID CODEX_THREAD_ID SHIPYARD_SLOT'
}

# The exec line for the child's launcher. shipyard sets the knobs; the module spells them.
#
# `full` approval, not `sandboxed`: a shipyard child `-C`s into its own worktree and drives a
# whole change end to end unattended. council takes `sandboxed` for the opposite reason. The two
# values are the one thing this unification must not flatten, so both are asserted in the suites.
shipyard_agent_exec() {
  local agent="$1" name="$2" worktree="$3" proto="$4" prompt="$5" mode
  shipyard_agent_admits "$agent" || return 1
  mode=$(adp_protocol_mode "$agent") || return 1
  (
    # UNSET first, for the same reason council does: `adp_cmd` reads the environment, so an
    # exported ADP_* would otherwise reach the child. Measured: `ADP_DIRS=/x` hands a child that
    # already runs with approvals off an extra `--add-dir /x`. Everything this function chooses
    # is assigned below; nothing is inherited.
    unset ADP_DIRS ADP_PROTOCOL ADP_CWD ADP_NAME ADP_EFFORT
    ADP_APPROVAL=full
    ADP_PROMPT="$prompt"
    case "$mode" in
      # The protocol travels as a system prompt where the CLI has one; where it does not, the
      # path has to be named in the bootstrap sentence instead, which is shipyard's wording.
      system-prompt) ADP_PROTOCOL="$proto"; ADP_NAME="$name"; ADP_EFFORT=max ;;
      reference)
        ADP_CWD="$worktree"
        ADP_PROMPT="Read and follow the supervisor protocol at $proto. Then invoke $prompt and stay inside that workflow until its stopping condition."
        ;;
      # `inline` is refused, loudly, rather than guessed at: shipyard has no established way to
      # point such a kind at the child's WORKTREE (claude takes -w, codex takes -C, and a kind
      # that has neither would silently run the child in the parent's checkout — the one place
      # a wrong answer is worse than no answer). Admitting an inline kind means deciding that
      # here, alongside widening shipyard_agent_kinds.
      *) exit 1 ;;
    esac
    adp_cmd "$agent"
  )
}
