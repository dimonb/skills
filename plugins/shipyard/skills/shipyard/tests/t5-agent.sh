#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$DIR/.." && pwd)"
TMP=$(mktemp -d /tmp/shipyard-agent-test.XXXXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT

failures=0
check() {
  local want="$1" got="$2" label="$3"
  if [ "$want" = "$got" ]; then
    printf 'ok - %s\n' "$label"
  else
    printf 'not ok - %s (want %q, got %q)\n' "$label" "$want" "$got"
    failures=$((failures+1))
  fi
}

git init -q "$TMP/repo"
git -C "$TMP/repo" config user.email shipyard-test
git -C "$TMP/repo" config user.name shipyard-test
printf 'fixture\n' >"$TMP/repo/README"
git -C "$TMP/repo" add README
git -C "$TMP/repo" commit -qm fixture
cd "$TMP/repo" || exit 1
. "$SKILL_DIR/shipyard-lib.sh"

unset SHIPYARD_AGENT CLAUDECODE CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID
CODEX_SESSION_ID=test
check codex "$(shipyard_agent)" "auto matches a Codex parent"

unset CODEX_SESSION_ID
CLAUDE_CODE_SESSION_ID=test
check claude "$(shipyard_agent)" "auto matches a Claude parent"

SHIPYARD_AGENT=codex
check codex "$(shipyard_agent)" "explicit agent override wins"
check '$ship' "$(shipyard_skill_ref codex)" "Codex skill invocation"
check '/ship' "$(shipyard_skill_ref claude)" "Claude skill invocation"

codex_cmd=$(shipyard_agent_exec codex ship-42 "$TMP/work tree" "$TMP/protocol file" '$ship #42')
case "$codex_cmd" in
  *"exec codex --approve-for-me -C"*'$ship #42'*) printf 'ok - Codex launcher\n' ;;
  *) printf 'not ok - Codex launcher (%s)\n' "$codex_cmd"; failures=$((failures+1)) ;;
esac

claude_cmd=$(shipyard_agent_exec claude ship-42 "$TMP/work tree" "$TMP/protocol file" '/ship #42')
case "$claude_cmd" in
  *"exec claude -w"*"/ship #42"*) printf 'ok - Claude launcher\n' ;;
  *) printf 'not ok - Claude launcher (%s)\n' "$claude_cmd"; failures=$((failures+1)) ;;
esac

shipyard_agent_prepare_worktree codex "$TMP/repo" "$TMP/worktree" || failures=$((failures+1))
if [ -f "$TMP/worktree/.git" ] || [ -d "$TMP/worktree/.git" ]; then worktree_exists=true; else worktree_exists=false; fi
check true "$worktree_exists" "Codex worktree is created"
check 0 "$(shipyard_agent_prepare_worktree codex "$TMP/repo" "$TMP/worktree"; echo $?)" "registered worktree is reusable"
mkdir "$TMP/not-a-worktree"
check 1 "$(shipyard_agent_prepare_worktree codex "$TMP/repo" "$TMP/not-a-worktree" >/dev/null 2>&1; echo $?)" "unregistered path is refused"

exit "$failures"
