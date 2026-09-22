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

# SHIPYARD_EFFORT too: it is an operator knob, and the operator who uses it is exactly who runs
# this file. An exported value would red the no-flag default case below for no real reason.
unset SHIPYARD_AGENT SHIPYARD_EFFORT CLAUDECODE CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID
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

# The child's effort is ship's to choose: a launch carries no --effort unless the operator set
# SHIPYARD_EFFORT, and an unusable value means no flag rather than a level shipyard picked.
effort_of() { # <cmd> — the value after --effort, or nothing
  sed -n "s/.*--effort '\{0,1\}\([a-z]*\)'\{0,1\}.*/\1/p" <<<"$1" | head -1
}
has_effort() { case "$1" in *--effort*) printf 'yes' ;; *) printf 'no' ;; esac; }
check no "$(has_effort "$claude_cmd")" "a default launch passes no --effort: the level is ship's to choose"
check low "$(effort_of "$(SHIPYARD_EFFORT=low shipyard_agent_exec claude ship-42 "$TMP/work tree" "$TMP/protocol file" '/ship #42')")" \
  "SHIPYARD_EFFORT is the operator's explicit override"
check no "$(has_effort "$(SHIPYARD_EFFORT=turbo shipyard_agent_exec claude ship-42 "$TMP/work tree" "$TMP/protocol file" '/ship #42' 2>/dev/null)")" \
  "an unusable SHIPYARD_EFFORT passes no flag rather than a level shipyard picked"
check 1 "$(SHIPYARD_EFFORT=turbo shipyard_child_effort 2>&1 >/dev/null | grep -c 'not low|medium')" \
  "and says why on stderr"
check 'runtime default (ship decides)' "$(shipyard_child_effort_summary)" \
  "the launch line says the choice is ship's when nothing was set"
check 'low (SHIPYARD_EFFORT)' "$(SHIPYARD_EFFORT=low shipyard_child_effort_summary)" \
  "the launch line names the override and where it came from"
check 'runtime default (ship decides)' "$(SHIPYARD_EFFORT=turbo shipyard_child_effort_summary 2>/dev/null)" \
  "an unusable override reads as no choice on the launch line"

shipyard_agent_prepare_worktree codex "$TMP/repo" "$TMP/worktree" || failures=$((failures+1))
if [ -f "$TMP/worktree/.git" ] || [ -d "$TMP/worktree/.git" ]; then worktree_exists=true; else worktree_exists=false; fi
check true "$worktree_exists" "Codex worktree is created"
check 0 "$(shipyard_agent_prepare_worktree codex "$TMP/repo" "$TMP/worktree"; echo $?)" "registered worktree is reusable"
mkdir "$TMP/not-a-worktree"
check 1 "$(shipyard_agent_prepare_worktree codex "$TMP/repo" "$TMP/not-a-worktree" >/dev/null 2>&1; echo $?)" "unregistered path is refused"

exit "$failures"
