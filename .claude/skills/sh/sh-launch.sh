#!/usr/bin/env bash
# sh-launch.sh — start a `/ship` Claude session in its own terminal (an agterm session
# by default, a tmux window with SH_BACKEND=tmux) and its own git worktree.
#
# Usage:
#   sh-launch.sh 123                  # continue existing MR/PR !123      -> /ship 123
#   sh-launch.sh "#42"                # start from issue 42               -> /ship #42
#   sh-launch.sh "add X to Y"         # new change from a free-text idea  -> /ship "add X to Y"
#   sh-launch.sh 123 no-merge         # extra ship flags are passed through
#
# The child runs `/ship` and nothing else. `/ship` owns the whole pipeline (issue →
# spec → its own review passes → apply → archive → ready-to-merge), so there is no
# second skill to hand over to and no explore step in front of it: a free-text idea is
# exactly what `ship "<description>"` takes.
#
# Slot (= terminal named `ship-<slot>` = worktree `.claude/worktrees/ship-<slot>`):
#   * numeric arg / `!123` / `#42` / an MR/PR/issue URL  -> slot = the number
#   * free text                                          -> slot = slug of the text
#
# Dedup: a numeric slot is never started twice (two Claudes in one worktree collide)
# — exit 3. A text slot gets a -2, -3, ... suffix instead.
#
# Every child is launched with an escalation protocol appended to its system prompt: no
# human is present in a child terminal, so questions, design decisions and blockers go
# up to the parent watcher through sh-ask.sh.
#
# Env:
#   SH_BACKEND    agterm (default) | tmux | auto
#   SH_WORKSPACE  agterm workspace name (default: the parent's workspace + "-ai",
#                 pinned in <mailbox>/container-agterm at the first launch)
#   SH_SESSION    tmux session name    (default: <repo>)
#   SH_ENV_PASS   env vars copied from THIS session into the child (default:
#                 CLAUDE_HOME CLAUDE_CONFIG_DIR) — see sh_env_preamble in sh-lib.sh
#   SH_FORCE=1    allow a second terminal for the same numeric slot
#   SH_DRY=1      print the slot, protocol path and command; start nothing
set -o pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=sh-lib.sh
. "$DIR/sh-lib.sh"

ARG="$1"
if [ -z "$ARG" ]; then
  echo 'usage: sh-launch.sh <mr-iid | #issue | "idea text"> [ship flags...]' >&2
  exit 2
fi
shift
EXTRA=("$@")

CWD=$(pwd -P)
if [ "$CWD" = "$(cd "$HOME" && pwd -P)" ]; then
  echo "error: refusing to run from HOME: $HOME" >&2
  exit 1
fi
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "error: current directory is not inside a git repository: $CWD" >&2
  exit 1
fi

sh_backend_check || exit 1
BACKEND=$(sh_backend)
KIND=$(sh_container_kind)
# PIN the container on the way in. On agterm it is derived from the workspace this
# shell sits in, so re-deriving it later — from a report run in another workspace, or
# from a child — would silently name a different container and find no children there.
# The mailbox is created below, so pin against it explicitly first.
sh_mailbox_ensure >/dev/null 2>&1
CONTAINER=$(sh_container_pin) || { echo "error: cannot resolve the container name" >&2; exit 1; }
_SH_CONTAINER="$CONTAINER"

# --- slot + /ship target -------------------------------------------------------
if [[ "$ARG" =~ ^[0-9]+$ ]]; then
  SLOT="$ARG"; TARGET="$ARG"; NUMERIC=1
elif [[ "$ARG" =~ ^[!#]([0-9]+)$ ]]; then
  # The MARKER is preserved, not stripped. A bare number is ambiguous to a
  # GitHub-native `/ship` ("#N is an Issue and pr N/!N is a PR — a bare number is
  # ambiguous; do not guess, ask"), so stripping it bought a slot name at the cost
  # of the child stopping to ask which one you meant. Both forms are accepted
  # verbatim by that skill, and `#N` is the issue form on GitLab too.
  SLOT="${BASH_REMATCH[1]}"; TARGET="$ARG"; NUMERIC=1
elif [[ "$ARG" =~ merge_requests/([0-9]+) ]]; then
  SLOT="${BASH_REMATCH[1]}"; TARGET="$ARG"; NUMERIC=1
elif [[ "$ARG" =~ issues/([0-9]+) ]]; then
  # GitHub issue URL -> the `#N` form, for the same reason as above. Passing the
  # URL through would work for a skill that parses URLs, but the marker form is
  # what every accepted spelling of "this is an issue" has in common.
  SLOT="${BASH_REMATCH[1]}"; TARGET="#${BASH_REMATCH[1]}"; NUMERIC=1
elif [[ "$ARG" =~ pull/([0-9]+) ]]; then
  # GitHub PR URL -> `pr N`.
  SLOT="${BASH_REMATCH[1]}"; TARGET="pr ${BASH_REMATCH[1]}"; NUMERIC=1
else
  SLOT=$(printf '%s' "$ARG" | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' | cut -c1-28 | sed -E 's/-+$//')
  [ -z "$SLOT" ] && SLOT="idea"
  TARGET="$ARG"; NUMERIC=0
fi

if sh_target "$SLOT" >/dev/null 2>&1; then
  if [ "$NUMERIC" = 1 ] && [ "${SH_FORCE:-}" != 1 ]; then
    echo "already running: $(sh_where "$SLOT") exists (use SH_FORCE=1 to override)" >&2
    echo "look inside: $(sh_peek_hint "$SLOT")" >&2
    exit 3
  fi
  if [ "$NUMERIC" != 1 ]; then
    n=2
    while sh_target "$SLOT-$n" >/dev/null 2>&1; do n=$((n+1)); done
    SLOT="$SLOT-$n"
  fi
fi
NAME="ship-$SLOT"

# --- first prompt --------------------------------------------------------------
# `/ship` takes all three shapes itself: a number, a `#N`/`pr N` marker, and a
# free-text description ("Create a new Issue (asks to confirm), then propose + spec
# PR"). So there is exactly one entry point and no handover.
if [ "$NUMERIC" = 1 ]; then
  PROMPT="/ship $TARGET"
else
  # inner double quotes -> single, so the prompt stays readable for the skill
  PROMPT="/ship \"${TARGET//\"/\'}\""
fi
for f in "${EXTRA[@]}"; do PROMPT="$PROMPT $f"; done

# --- escalation protocol (appended to the child's system prompt) ----------------
MB=$(sh_mailbox_ensure) || { echo "error: cannot create the escalation mailbox" >&2; exit 1; }
PROTO="$MB/protocol-$SLOT.md"

{
  echo "# You are a CHILD ship session (slot \`$SLOT\`)"
  echo
  echo "Started by the \`/sh\` skill in $KIND \`$CONTAINER\`, terminal \`$NAME\`, worktree"
  echo "\`.claude/worktrees/$NAME\`."
  echo
  echo "## Your one job is \`/ship\`"
  echo
  echo "You were started with \`$PROMPT\` and that skill owns the whole pipeline — issue,"
  echo "spec, its own review passes, apply, archive, ready-to-merge. Stay inside it. Do not"
  echo "reach for another driver skill, do not invent a pre-step in front of it, and do not"
  echo "hand the change over to anything else: whatever \`/ship\` does not do is a question"
  echo "for the human (escalate it), not work for a different skill."
  echo
  echo "## No human is present in this session"
  echo
  echo "The human sits in the PARENT watcher session that launched you and reads its"
  echo "notifications, not this terminal. So: never use AskUserQuestion, never end a turn"
  echo "with a question, never guess your way past one. Escalate it up to the parent,"
  echo "wait for the answer, and only then act on it and continue here."
  echo
  echo '```bash'
  echo "bash $DIR/sh-ask.sh \"<question>\" --context \"<state, options, your recommendation>\" --timeout 540"
  echo '```'
  echo
  echo "It blocks and prints \`ANSWER: <text>\` (call it from the Bash tool with"
  echo "\`timeout: 600000\`). On \`PENDING:<id>\` do other *safe* work and re-check with"
  echo "\`sh-ask.sh --wait <id> --timeout 540\` or \`--poll <id>\`. Keep re-checking; a"
  echo "pending question is never a reason to stop the pipeline loop or to decide alone."
  echo
  echo "## Always escalate — never decide alone"
  echo
  echo "* **Architectural / design decisions** — module boundaries, data model or schema,"
  echo "  a new dependency or service, API/contract shape, migration or rollout strategy,"
  echo "  sync vs async, anything expensive to reverse. Escalate **before** writing it into"
  echo "  the design/spec artifacts (i.e. while proposing, not after):"
  echo
  echo '  ```bash'
  echo "  bash $DIR/sh-ask.sh --kind decision \"<the decision>\" \\"
  echo "    --context \"<option A/B/C, trade-offs, your recommendation>\" --timeout 540"
  echo '  ```'
  echo
  echo "  \`--context\` is mandatory for this kind — the parent cannot decide blind. Give"
  echo "  real options and your recommendation, then follow the answer you get back."
  echo
  echo '  **Write that context to a FILE and pass `--context-file`, not `--context "..."`.**'
  echo '  The payload is a shell argument, so YOUR OWN shell expands it before sh-ask.sh'
  echo '  ever runs: inside double quotes a backticked identifier is COMMAND SUBSTITUTION'
  echo '  and is replaced by the output of running it, which is normally nothing. This has'
  echo '  already eaten a term out of a real escalation -- "the two overlapped and  could'
  echo '  not dedupe them" -- and the damage reads as clumsy prose rather than as'
  echo '  corruption, so nobody catches it. Same for $(...) and $VAR.'
  echo
  echo '  ```bash'
  echo "  cat > /tmp/ctx.md <<'CTX'"
  echo '  ...options, trade-offs and your recommendation, with `code` intact...'
  echo '  CTX'
  echo "  bash $DIR/sh-ask.sh --kind decision '<the decision>' --context-file /tmp/ctx.md --timeout 540"
  echo '  ```'
  echo "* Ambiguous, conflicting or missing requirements and acceptance criteria — including"
  echo "  the shape of the change itself when you were started from a free-text idea and"
  echo "  \`/ship\` needs the scope pinned down before it can write a spec."
  echo "* Anything risky or irreversible: prod, data migrations, secrets/access, rewriting"
  echo "  or deleting someone else's work, force-push, CI/CD changes."
  echo "* Any blocker you cannot clear yourself (auth, permissions, a red pipeline you"
  echo "  cannot fix, review findings you disagree with)."
  echo
  echo "## Notify without blocking"
  echo
  echo "\`bash $DIR/sh-ask.sh --kind notice \"<what happened>\"\` on milestones: MR/PR opened,"
  echo "a review pass posted blocking findings, pipeline failed, change archived, merged, and"
  echo "whenever you stop for any reason. No waiting, one line each."
  echo
  echo "## The review handshake — two traps that have stranded sessions"
  echo
  echo "**There will be no formal APPROVE.** GitHub forbids approving your own PR, and any"
  echo "review pass runs under the SAME account you push from, so an approved state can"
  echo "never arrive. The gate is a COMPLETED REVIEW PASS WITH ITS FINDINGS ADDRESSED."
  echo "Waiting for an approval is an infinite wait."
  echo
  echo "**Never detect a review by authorship.** Because reviewer and author share one"
  echo "identity, any check keyed on who wrote something — a \`author != <you>\` filter, a"
  echo "\"wait for someone else's comment\" heuristic — excludes the very reviewer it waits"
  echo "for. Detect a review by the PRESENCE of review threads on the head you pushed, count"
  echo "them regardless of resolved state (a thread opened and quickly resolved still"
  echo "happened), and filter only \`[bot]\` authors."
  echo
  echo "**Nothing external will ever unblock you.** \`/ship\` runs its review passes itself,"
  echo "as subagents. If you find yourself waiting for a second actor to show up, you have"
  echo "left the skill's state machine — re-read it, or escalate. A wait nobody satisfies is"
  echo "invisible from outside and has cost whole nights."
  echo
  echo "## Directives coming the other way"
  echo
  echo "The parent can also speak first. A message arriving in this session prefixed"
  echo "\`[supervisor directive]\` (optionally \`, re <id>\`) is the **human's** instruction,"
  echo "relayed by the parent watcher — treat it exactly like an answer to an escalation:"
  echo "authoritative, and it takes precedence over your current plan. It is how you get"
  echo "a reply to a \`notice\` (which you never poll) and how you are told to change course"
  echo "without having asked. If it points at a file for the full text, read that file."
  echo "Acknowledge by acting; send a \`notice\` back when the directive is done."
  echo
  if [ "$BACKEND" = agterm ]; then
    echo "## Your status glyph"
    echo
    echo "This terminal is an agterm session, so the sidebar carries a state glyph the human"
    echo "reads at a glance. Keep it honest — it costs one command:"
    echo
    echo '```bash'
    echo "agtermctl session status active    --target \"\$AGTERM_SESSION_ID\"           # working"
    echo "agtermctl session status blocked   --target \"\$AGTERM_SESSION_ID\" --blink   # waiting on an escalation"
    echo "agtermctl session status completed --target \"\$AGTERM_SESSION_ID\"           # ready-to-merge / done"
    echo '```'
    echo
    echo "Always pass \`--target \"\$AGTERM_SESSION_ID\"\`: the default target is whatever session"
    echo "the HUMAN has selected, which is not yours. The parent also sets the glyph from the"
    echo "outside on every report tick, so a stale one corrects itself — but yours is timely."
    echo
  fi
  echo "## Re-wakes"
  echo
  echo "If you re-wake yourself via \`schedule\`/\`CronCreate\` (a fresh session with no"
  echo "memory), restate this protocol in the payload, or have the payload read this file:"
  echo "\`$PROTO\`. The mailbox is \`$MB\`; the scripts are in \`$DIR\`."
} >"$PROTO"

# --- the launcher --------------------------------------------------------------
# The child is NOT spawned from this shell — agterm spawns it from the app and tmux
# from its server — so nothing here is inherited. A launcher FILE is what carries the
# environment across, and it also keeps both backends off long quoted command lines.
LAUNCHER="$MB/launch-$SLOT.sh"
{
  echo '#!/bin/zsh -l'
  echo "# generated by sh-launch.sh for slot $SLOT — re-runnable by hand"
  echo
  echo '# Re-assert the parent watcher'"'"'s Claude identity AFTER the login profile ran:'
  echo '# a profile that sets its own CLAUDE_HOME/CLAUDE_CONFIG_DIR would otherwise hand'
  echo '# the child a different config dir, hence different skills — possibly no /ship.'
  sh_env_preamble
  echo
  echo "cd $(sh_shq "$CWD") || exit 1"
  printf 'exec claude -w %s --effort max -n %s --permission-mode auto --remote-control %s \\\n' \
    "$(sh_shq "$NAME")" "$(sh_shq "$NAME")" "$(sh_shq "$NAME")"
  printf '  --append-system-prompt "$(cat %s)" \\\n' "$(sh_shq "$PROTO")"
  printf '  %s\n' "$(sh_shq "$PROMPT")"
} >"$LAUNCHER"
chmod +x "$LAUNCHER"

ENVSUM=$(sh_env_summary)

if [ "${SH_DRY:-}" = 1 ]; then
  echo "dry-run: backend $BACKEND, $KIND $CONTAINER, terminal $NAME (worktree .claude/worktrees/$NAME)"
  echo "dry-run: protocol $PROTO"
  echo "dry-run: launcher $LAUNCHER"
  echo "dry-run: env      $ENVSUM"
  sed -n '3,$p' "$LAUNCHER" | sed 's/^/dry-run| /'
  echo "SLOT:$SLOT"
  exit 0
fi

sh_launch "$SLOT" "$CWD" "$LAUNCHER" || {
  echo "error: failed to start the child terminal ($BACKEND)" >&2; exit 1; }

# Record what the child was given, so a later "why is it using the wrong skills?" is a
# file lookup rather than a re-derivation.
# `kind:"launch"` + `status:"info"` keep it out of the escalation views: they share
# this directory, and a record with no recognised kind used to read as an open
# question — a fake escalation that never resolves and keeps the monitor alive.
jq -n --arg slot "$SLOT" --arg backend "$BACKEND" --arg container "$CONTAINER" \
      --arg prompt "$PROMPT" --arg proto "$PROTO" --arg launcher "$LAUNCHER" \
      --arg env "$ENVSUM" --arg cwd "$CWD" --arg now "$(sh_now)" \
  '{id:("launch-"+$slot), slot:$slot, kind:"launch", status:"info",
    backend:$backend, container:$container, prompt:$prompt,
    protocol:$proto, launcher:$launcher, env:$env, cwd:$cwd, started_at:$now}' \
  >"$MB/launch-$SLOT.json" 2>/dev/null

sh_note "$SLOT" active

echo "started ship in $(sh_where "$SLOT") (worktree .claude/worktrees/$NAME) — $PROMPT"
echo "env: $ENVSUM"
echo "SLOT:$SLOT"
