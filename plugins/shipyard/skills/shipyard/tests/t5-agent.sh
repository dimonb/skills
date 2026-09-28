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
# Byte for byte against the default render, not `has_effort`: an empty render would read as
# "no flag" too, and this case discards the render's stderr, so nothing else would catch it.
check "$claude_cmd" "$(SHIPYARD_EFFORT=turbo shipyard_agent_exec claude ship-42 "$TMP/work tree" "$TMP/protocol file" '/ship #42' 2>/dev/null)" \
  "an unusable SHIPYARD_EFFORT renders the default launcher: no flag, not a level shipyard picked"
check 1 "$(SHIPYARD_EFFORT=turbo shipyard_child_effort 2>&1 >/dev/null | grep -c 'not low|medium')" \
  "and says why on stderr"
check 'runtime default (ship decides)' "$(shipyard_child_effort_summary claude)" \
  "the launch line says the choice is ship's when nothing was set"
check 'low (SHIPYARD_EFFORT)' "$(SHIPYARD_EFFORT=low shipyard_child_effort_summary claude)" \
  "the launch line names the override and where it came from"
check 'runtime default (ship decides)' "$(SHIPYARD_EFFORT=turbo shipyard_child_effort_summary claude 2>/dev/null)" \
  "an unusable override reads as no choice on the launch line"
# A codex child takes no --effort from shipyard, so the override changes nothing in its launcher
# and the record must not claim a level the child was never given.
check "$codex_cmd" "$(SHIPYARD_EFFORT=low shipyard_agent_exec codex ship-42 "$TMP/work tree" "$TMP/protocol file" '$ship #42')" \
  "SHIPYARD_EFFORT leaves a codex launcher unchanged"
check 'runtime default (ship decides; SHIPYARD_EFFORT=low is not passed to a codex child)' \
  "$(SHIPYARD_EFFORT=low shipyard_child_effort_summary codex)" \
  "the launch line says the override is not passed to a codex child"

shipyard_agent_prepare_worktree codex "$TMP/repo" "$TMP/worktree" || failures=$((failures+1))
if [ -f "$TMP/worktree/.git" ] || [ -d "$TMP/worktree/.git" ]; then worktree_exists=true; else worktree_exists=false; fi
check true "$worktree_exists" "Codex worktree is created"
check 0 "$(shipyard_agent_prepare_worktree codex "$TMP/repo" "$TMP/worktree"; echo $?)" "registered worktree is reusable"
mkdir "$TMP/not-a-worktree"
check 1 "$(shipyard_agent_prepare_worktree codex "$TMP/repo" "$TMP/not-a-worktree" >/dev/null 2>&1; echo $?)" "unregistered path is refused"

# --- a kind with no env-pass arm refuses the LAUNCH (#113) ------------------------------------
# Executed, not grepped: shipyard-launch.sh runs as a dry run from a COPY of this skill whose
# `shipyard_agent_env_pass_default` has lost its claude arm — the state a newly admitted kind is in
# when nobody added the arm. The preamble then fails, and the launcher used to be written anyway
# with no export and no unset lines in it. The control run on an unmodified copy is what keeps the
# refusal checks from passing on a launch that fails for some other reason.
dry_launch() { # <skill-dir> <repo> -> stdout+stderr, then "rc=<n>"
  local rc=0 out
  git init -q "$2"
  git -C "$2" -c user.email=shipyard-test -c user.name=shipyard-test commit -q --allow-empty -m fixture
  out=$( cd "$2" || exit 1
         # Functions, not binaries on PATH: shipyard-lib.sh prepends the system PATH.
         tmux() { return 1; }; claude() { :; }; export -f tmux claude
         # The two env knobs replace the per-kind defaults these checks are about.
         unset CLAUDECODE CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID \
           SHIPYARD_ENV_PASS SHIPYARD_ENV_SCRUB
         SHIPYARD_AGENT=claude SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t5ex SHIPYARD_DRY=1 \
           bash "$1/shipyard-launch.sh" "#42" 2>&1 ) || rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
cp -R "$SKILL_DIR" "$TMP/skill-ok"
cp -R "$SKILL_DIR" "$TMP/skill-noarm"
sed '/^shipyard_agent_env_pass_default()/,/^}/{/claude)/d;}' "$SKILL_DIR/shipyard-agent.sh" \
  >"$TMP/skill-noarm/shipyard-agent.sh"
check 1 "$(sed -n '/^shipyard_agent_env_pass_default()/,/^}/p' "$SKILL_DIR/shipyard-agent.sh" | grep -c 'claude)')" \
  "the fixture's sed has a claude arm to remove"
check 0 "$(sed -n '/^shipyard_agent_env_pass_default()/,/^}/p' "$TMP/skill-noarm/shipyard-agent.sh" | grep -c 'claude)')" \
  "...and removed it from the env-pass default"

out=$(dry_launch "$TMP/skill-ok" "$TMP/launch-ok")
check 0 "$(printf '%s' "$out" | sed -n 's/^rc=//p')" "control: a known kind's dry launch succeeds"
if grep -q '^unset CLAUDE_CODE_MESSAGING_SOCKET$' "$TMP/launch-ok/.git/ship-escalations/launch-42.sh" 2>/dev/null; then
  scrubbed=yes; else scrubbed=no; fi
check yes "$scrubbed" "control: ...and its launcher scrubs the parent's IPC socket"

out=$(dry_launch "$TMP/skill-noarm" "$TMP/launch-noarm")
check 1 "$(printf '%s' "$out" | sed -n 's/^rc=//p')" "no env-pass arm: the launch is refused"
check 1 "$(printf '%s' "$out" | grep -c 'no environment preamble for agent kind')" "...saying why"
if [ -e "$TMP/launch-noarm/.git/ship-escalations/launch-42.sh" ]; then left=yes; else left=no; fi
check no "$left" "...and leaves no launcher behind"
if [ -e "$TMP/launch-noarm/.git/ship-escalations/protocol-42.md" ]; then left=yes; else left=no; fi
check no "$left" "...nor a protocol file"

exit "$failures"
