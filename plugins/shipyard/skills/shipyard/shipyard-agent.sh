#!/usr/bin/env bash
# shipyard-agent.sh - child-agent abstraction for shipyard. Source only.

shipyard_agent() {
  case "${SHIPYARD_AGENT:-auto}" in
    codex|claude) printf '%s' "$SHIPYARD_AGENT" ;;
    auto)
      if [ -n "${CODEX_SESSION_ID:-}${CODEX_THREAD_ID:-}" ]; then
        printf 'codex'
      elif [ -n "${CLAUDECODE:-}${CLAUDE_CODE_SESSION_ID:-}" ]; then
        printf 'claude'
      elif command -v codex >/dev/null 2>&1 && ! command -v claude >/dev/null 2>&1; then
        printf 'codex'
      elif command -v claude >/dev/null 2>&1; then
        printf 'claude'
      elif command -v codex >/dev/null 2>&1; then
        printf 'codex'
      else
        printf 'none'
      fi
      ;;
    *) printf 'invalid' ;;
  esac
}

shipyard_agent_check() {
  local agent="${1:-$(shipyard_agent)}"
  case "$agent" in
    codex|claude)
      command -v "$agent" >/dev/null 2>&1 || {
        echo "error: child agent '$agent' is not on PATH" >&2
        return 1
      }
      ;;
    invalid)
      echo "error: SHIPYARD_AGENT must be codex, claude or auto (got: ${SHIPYARD_AGENT:-})" >&2
      return 1
      ;;
    *)
      echo "error: neither codex nor claude is available for the child session" >&2
      return 1
      ;;
  esac
}

shipyard_skill_ref() {
  case "$1" in
    codex) printf '$ship' ;;
    claude) printf '/ship' ;;
    *) return 1 ;;
  esac
}

shipyard_self_ref() {
  case "$1" in
    codex) printf '$shipyard' ;;
    claude) printf '/shipyard' ;;
    *) return 1 ;;
  esac
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

shipyard_agent_exec() {
  local agent="$1" name="$2" worktree="$3" proto="$4" prompt="$5" bootstrap
  case "$agent" in
    codex)
      bootstrap="Read and follow the supervisor protocol at $proto. Then invoke $prompt and stay inside that workflow until its stopping condition."
      printf 'exec codex --approve-for-me -C %s %s\n' \
        "$(shipyard_shq "$worktree")" "$(shipyard_shq "$bootstrap")"
      ;;
    claude)
      printf 'exec claude -w %s --effort max -n %s --permission-mode auto --remote-control %s \\\n' \
        "$(shipyard_shq "$name")" "$(shipyard_shq "$name")" "$(shipyard_shq "$name")"
      printf '  --append-system-prompt "$(cat %s)" \\\n' "$(shipyard_shq "$proto")"
      printf '  %s\n' "$(shipyard_shq "$prompt")"
      ;;
    *) return 1 ;;
  esac
}
