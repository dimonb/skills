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
#
# Three knobs for the dedup and slot-name cases further down, each defaulting to the plain launch:
#   T5_ARG   the launch argument (default `#42`);
#   T5_TMUX  `answer` (default): tmux says no server is running, which is an ANSWERED, empty
#            backend; `down`: it fails saying nothing, which is an unanswered one; `listed`: the
#            enumeration (`-F '#{window_name}'`) lists ship-42 while the per-slot lookup fails;
#   T5_PIN   a backend whose container pin to plant first, as a fleet launched there would leave.
dry_launch() { # <skill-dir> <repo> [mailbox-name-to-plant-a-directory-at] -> output, then "rc=<n>"
  local rc=0 out
  git init -q "$2"
  git -C "$2" -c user.email=shipyard-test -c user.name=shipyard-test commit -q --allow-empty -m fixture
  [ -z "${3:-}" ] || mkdir -p "$2/.git/ship-escalations/$3"
  [ -z "${T5_PIN:-}" ] || { mkdir -p "$2/.git/ship-escalations"; printf 't5ex' >"$2/.git/ship-escalations/container-$T5_PIN"; }
  out=$( cd "$2" || exit 1
         # Functions, not binaries on PATH: shipyard-lib.sh prepends the system PATH. The default
         # fake must ANSWER: the launch dedup refuses a backend that does not (#140), so a fake that
         # fails silently would be refused before any check below reached what it is about.
         export T5_TMUX="${T5_TMUX:-answer}"
         tmux() {
           case "$T5_TMUX" in
             down)   return 1 ;;
             listed) [ "${!#}" = '#{window_name}' ] && { echo ship-42; return 0; }; return 1 ;;
           esac
           echo 'no server running on /tmp/t5-fake' >&2; return 1
         }
         claude() { :; }; export -f tmux claude
         # The two env knobs replace the per-kind defaults these checks are about.
         unset CLAUDECODE CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID \
           SHIPYARD_ENV_PASS SHIPYARD_ENV_SCRUB
         SHIPYARD_AGENT=claude SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t5ex SHIPYARD_DRY=1 \
           bash "$1/shipyard-launch.sh" "${T5_ARG:-#42}" 2>&1 ) || rc=$?
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

# #319: a disclosure hold is the human's alone. The child is told the marker to raise it under and
# that a release it acts on is published; the watcher is told, where it reads its answering policy,
# never to answer one. Text pins, not behaviour: nothing mechanical enforces the rule, and both
# files say so — these checks keep the words from being dropped, which is all the rule has.
PROTO_OK="$TMP/launch-ok/.git/ship-escalations/protocol-42.md"
check 1 "$(grep -c '^## A disclosure hold is the human.s alone$' "$PROTO_OK" 2>/dev/null)" \
  "the child protocol has the disclosure-hold section"
check 1 "$(grep -c 'shipyard-ask.sh "disclosure hold: <the stub>"' "$PROTO_OK" 2>/dev/null)" \
  "...raising it as a blocking question under the marker"
check 1 "$(grep -c '^in an autonomous run too\. A release is a NEW `/ship` invocation, exactly as$' "$PROTO_OK" 2>/dev/null)" \
  "...which the watcher never answers, in an autonomous run too, and ship releases by re-invocation"
check 1 "$(grep -c '^`/ship` on this change with those words — never to release inside the current run,$' "$PROTO_OK" 2>/dev/null)" \
  "...never inside the current run"
check 1 "$(grep -c '^PR/MR and the flags you were launched with minus any `merge`, and ALWAYS add `no-merge`$' "$PROTO_OK" 2>/dev/null)" \
  "...re-invoking with no-merge"
check 1 "$(grep -c '^— whatever you were launched with and whatever the repo.s policy says — so ship never$' "$PROTO_OK" 2>/dev/null)" \
  "...whatever the launch flags or the repo's policy"
check 1 "$(grep -c '^(`merge`, an effort, a round budget) is text, never a flag\. A relay that names no id$' "$PROTO_OK" 2>/dev/null)" \
  "...with the relayed words as text, never as flags"
check 1 "$(grep -c '^releases nothing: say so in a notice, with the ids still held, and raise the$' "$PROTO_OK" 2>/dev/null)" \
  "...never on a relay that names no id, which raises the question again"
check 1 "$(grep -c '^only — never the finding.s detail, not in the question, its context, or any notice:$' "$PROTO_OK" 2>/dev/null)" \
  "...carrying the stub only"
check 1 "$(grep -c '^mechanical stops a watcher that releases a hold on its own authority; that public line$' "$PROTO_OK" 2>/dev/null)" \
  "...and saying nothing mechanical stops a watcher"
check 1 "$(grep -c '^entry.s id, the UTC time, and the relayed words verbatim' "$PROTO_OK" 2>/dev/null)" \
  "...whose published line carries the ids, the time and the words"
check 1 "$(grep -c '^\*\*A release is published\.\*\*' "$PROTO_OK" 2>/dev/null)" \
  "...and publishing any release it acts on"
check 1 "$(grep -c '^exception is a disclosure hold: a directive releases it only' "$PROTO_OK" 2>/dev/null)" \
  "...which a supervisor directive does not bypass"
check 1 "$(grep -c '^\*\*A `disclosure hold:` question is the human.s alone — never answer it, never release it,$' "$SKILL_DIR/SKILL.md")" \
  "SKILL.md's answering policy forbids the watcher to answer one"
check 1 "$(grep -c '^including in an autonomous run\*\* where you otherwise decide escalations yourself\.' "$SKILL_DIR/SKILL.md")" \
  "...including in an autonomous run"
check 1 "$(grep -c '^that names no id releases nothing\. With no human reachable, leave it pending' "$SKILL_DIR/SKILL.md")" \
  "...says a relay naming no id releases nothing, and a hold with nobody to ask stays pending"
check 1 "$(grep -c '^\*\*Nothing mechanical enforces this\*\*' "$SKILL_DIR/SKILL.md")" \
  "...and says nothing mechanical enforces it"

out=$(dry_launch "$TMP/skill-noarm" "$TMP/launch-noarm")
check 1 "$(printf '%s' "$out" | sed -n 's/^rc=//p')" "no env-pass arm: the launch is refused"
check 1 "$(printf '%s' "$out" | grep -c 'no environment preamble for agent kind')" "...saying why"
if [ -e "$TMP/launch-noarm/.git/ship-escalations/launch-42.sh" ]; then left=yes; else left=no; fi
check no "$left" "...and leaves no launcher behind"
if [ -e "$TMP/launch-noarm/.git/ship-escalations/protocol-42.md" ]; then left=yes; else left=no; fi
check no "$left" "...nor a protocol file"

# The launcher's own write is checked too. A directory at its name makes policy_mailbox_write
# refuse, and the launch used to go on to start a terminal on whatever was, or was not, there.
out=$(dry_launch "$TMP/skill-ok" "$TMP/launch-blocked" launch-42.sh)
check 1 "$(printf '%s' "$out" | sed -n 's/^rc=//p')" "an unwritable launcher refuses the launch"
check 1 "$(printf '%s' "$out" | grep -c "cannot write the child's launcher")" "...saying why"

# --- the launch dedup does not read an unanswerable slot as free (#140) -----------------------
rc_of() { printf '%s' "$1" | sed -n 's/^rc=//p'; }
has() { [ -e "$1" ] && printf yes || printf no; }
out=$(T5_TMUX=down dry_launch "$TMP/skill-ok" "$TMP/launch-down")
check 7 "$(rc_of "$out")" "a backend that does not answer refuses the launch (rc 7)"
check 1 "$(printf '%s' "$out" | grep -c 'cannot tell whether slot `42` is free')" "...saying it could not tell"
check no "$(has "$TMP/launch-down/.git/ship-escalations/launch-42.sh")" "...and writes no launcher"
check no "$(has "$TMP/launch-down/.git/ship-escalations/container-tmux")" "...nor a container pin"
# Answered, but this fleet was launched on agterm and this process resolved tmux. The pin is the
# evidence, and the launch used to write its own tmux pin beside it before asking anything.
out=$(T5_PIN=agterm dry_launch "$TMP/skill-ok" "$TMP/launch-elsewhere")
check 7 "$(rc_of "$out")" "a fleet pinned on the other backend refuses the launch (rc 7)"
check 1 "$(printf '%s' "$out" | grep -c 'Launch on the fleet.s backend: SHIPYARD_BACKEND=agterm')" "...naming the backend to pin"
check 1 "$(printf '%s' "$out" | grep -c 'asked for tmux explicitly')" "...in the words for an explicit backend, not auto's"
check 1 "$(printf '%s' "$out" | grep -c 'SHIPYARD_BACKEND=agterm bash .*/shipyard-report.sh')" \
  "...and clearing a stale pin starts from the pinned backend's terminals, not its worktrees"
check 1 "$(printf '%s' "$out" | grep -c 'Do not remove it')" \
  "...and a pin the teardown kept is not to be removed by hand"
check no "$(has "$TMP/launch-elsewhere/.git/ship-escalations/container-tmux")" "...without writing a second pin first"
out=$(T5_PIN=agterm T5_TMUX=down SHIPYARD_FORCE=1 dry_launch "$TMP/skill-ok" "$TMP/launch-forced")
check 7 "$(rc_of "$out")" "SHIPYARD_FORCE does not override not knowing"
# Control: the fleet's own backend pinned, answered and empty, launches.
out=$(T5_PIN=tmux dry_launch "$TMP/skill-ok" "$TMP/launch-samepin")
check 0 "$(rc_of "$out")" "control: pinned on this backend, answered and empty -> launches"
# The narrowest blip: the backend answers the enumeration and still lists the slot, and only the
# per-slot lookup fails. That slot is taken, not free.
out=$(T5_TMUX=listed dry_launch "$TMP/skill-ok" "$TMP/launch-listed")
check 3 "$(rc_of "$out")" "a slot the backend still lists is taken even when its lookup fails (rc 3)"
check 1 "$(printf '%s' "$out" | grep -c 'lists ship-42, though its terminal lookup failed')" "...saying so"
check no "$(has "$TMP/launch-listed/.git/ship-escalations/launch-42.sh")" "...and writes no launcher"
# A dry run writes no container pin: one left behind would name a fleet that never launched, and
# the dedup would then refuse every launch on the other backend.
check no "$(has "$TMP/launch-ok/.git/ship-escalations/container-tmux")" "a dry run writes no container pin"

# --- a slot name is validated before anything is made from it (#198) --------------------------
# Multi-line free text. The old sed slug ran per line, so the newline reached the launcher's
# comment line and the second line of the text ran as a command.
out=$(T5_ARG="$(printf 'first line\nsecond; touch pwned')" dry_launch "$TMP/skill-ok" "$TMP/launch-multiline")
check 0 "$(rc_of "$out")" "multi-line free text still launches"
check 'SLOT:first-line-second-touch-pwne' "$(printf '%s' "$out" | grep '^SLOT:')" "...as one single-line slug"
check '# generated by shipyard-launch.sh for slot first-line-second-touch-pwne — re-runnable by hand' \
  "$(sed -n 2p "$TMP/launch-multiline/.git/ship-escalations/launch-first-line-second-touch-pwne.sh" 2>/dev/null)" \
  "...whose launcher comment is one line"
check 1 "$(printf '%s\n' "$out" | grep -c '^SLOT:')" "...and exactly one slot is reported"
LONGN=$(printf '9%.0s' $(seq 1 60))
out=$(T5_ARG="#$LONGN" dry_launch "$TMP/skill-ok" "$TMP/launch-long")
check 2 "$(rc_of "$out")" "a slot past the worktree-name limit is refused (rc 2)"
check 1 "$(printf '%s' "$out" | grep -c 'refusing the slot name')" "...saying why"
check no "$(has "$TMP/launch-long/.git/ship-escalations/launch-$LONGN.sh")" "...before any launcher exists"

exit "$failures"
