#!/usr/bin/env bash
# shipyard-launch.sh - start a ship child in its own terminal and git worktree.
#
# Usage:
#   shipyard-launch.sh 123                  # continue existing MR/PR !123      -> /ship 123
#   shipyard-launch.sh "#42"                # start from issue 42               -> /ship #42
#   shipyard-launch.sh "add X to Y"         # new change from a free-text idea  -> /ship "add X to Y"
#   shipyard-launch.sh 123 no-merge         # extra ship flags are passed through
#
# The child runs `/ship` and nothing else. `/ship` owns the whole pipeline — issue, spec
# (where the repo keeps one), implementation, its own review passes, and the hand-off at
# ready-to-merge — so there is no second skill to hand over to and no explore step in
# front of it: a free-text idea is exactly what `ship "<description>"` takes. Read the
# stage list from the `/ship` in use; do not rely on one written down here.
#
# Slot (= terminal named `ship-<slot>` = worktree `.claude/worktrees/ship-<slot>`):
#   * numeric arg / `!123` / `#42` / an MR/PR/issue URL  -> slot = the number
#   * free text                                          -> slot = slug of the text
#
# A slot must pass shipyard_slot_check (shipyard-backend.sh) — letters, digits, `-`, `_`,
# bounded length — or the launch exits 2 before anything is created.
#
# Dedup: a numeric slot is never started twice (two agents in one worktree collide)
# — exit 3. A text slot gets a -2, -3, ... suffix instead. When the backend cannot say
# whether a slot is taken — it did not answer, or this process resolved a different
# backend from the fleet's — the launch is refused with exit 7 rather than guessed.
# The admission gate below has its own codes (4, 5, 6; see shipyard-admission.sh).
#
# Every child is launched with an escalation protocol appended to its system prompt: no
# human is present in a child terminal, so questions, design decisions and blockers go
# up to the parent watcher through shipyard-ask.sh.
#
# Env:
#   SHIPYARD_AGENT      codex | claude | auto (default: match the parent runtime)
#   SHIPYARD_BACKEND    agterm (default) | tmux | auto
#   SHIPYARD_WORKSPACE  agterm workspace name (default: the parent's workspace + "-ai",
#                 pinned in <mailbox>/container-agterm at the first launch)
#   SHIPYARD_SESSION    tmux session name    (default: <repo>)
#   SHIPYARD_ENV_PASS   env vars copied from THIS session into the child (default:
#                 CODEX_HOME for Codex; CLAUDE_HOME CLAUDE_CONFIG_DIR for Claude)
#   SHIPYARD_EFFORT     low|medium|high|xhigh|max: an explicit --effort for a Claude child
#                 (default: none — no flag is passed, and ship chooses its own effort)
#   SHIPYARD_FORCE=1    allow a second terminal for the same numeric slot
#   SHIPYARD_DRY=1      print the slot, protocol path and command; start nothing
set -o pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shipyard-lib.sh
. "$DIR/shipyard-lib.sh"

ARG="$1"
if [ -z "$ARG" ]; then
  echo 'usage: shipyard-launch.sh <mr-iid | #issue | "idea text"> [ship flags...]' >&2
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
ROOT=$(git rev-parse --show-toplevel) || exit 1

AGENT=$(shipyard_agent)
shipyard_agent_check "$AGENT" || exit 1
SHIP_REF=$(shipyard_skill_ref "$AGENT") || exit 1
SELF_REF=$(shipyard_self_ref "$AGENT") || exit 1

shipyard_backend_check || exit 1
BACKEND=$(shipyard_backend)
KIND=$(shipyard_container_kind)

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
  # `tr -cs`, not a `sed` substitution: sed works one LINE at a time, so a newline in the text
  # survived into the slot — and from there into the launcher's comment line, where the rest of the
  # launch text ran as shell commands (#198). `tr` treats a newline like any other character. The C
  # locale makes it a byte operation, so a non-ASCII letter becomes a separator rather than a
  # character the slot check then refuses.
  SLOT=$(printf '%s' "$ARG" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -cs 'a-z0-9' '-' \
    | sed -E 's/^-+//; s/-+$//' | cut -c1-28 | sed -E 's/-+$//')
  [ -z "$SLOT" ] && SLOT="idea"
  TARGET="$ARG"; NUMERIC=0
fi

# The boundary for every name derived below it — the terminal, the worktree, the mailbox files and
# the launcher. Exit 2, the usage error: nothing has been created yet.
shipyard_slot_check "$SLOT" || exit 2

# --- dedup ---------------------------------------------------------------------
# slot_taken <slot> — 0 taken, 1 free, 2 cannot tell (the verdict left in UNRESOLVED).
#
# A failed `shipyard_target` is not a free slot. It is also what a backend that did not answer
# returns, and what this process returns when it resolved a different backend from the one the
# fleet was launched on — and reading either as "free" started a second agent in the same worktree,
# because `shipyard_agent_prepare_worktree` accepts one that is already registered (#140). So a
# miss is put to `shipyard_signal_class` with ONE enumeration taken before any candidate is looked
# at, and bare slots on both sides of the comparison (its namespace note). `listed` — the backend
# answered and has the slot, only the lookup failed — is simply taken. Called without `$( )` so
# UNRESOLVED reaches this shell.
TAB=$(printf '\t')
ENUM_RC=0
ENUM=$(shipyard_slots 2>/dev/null) || ENUM_RC=$?
UNRESOLVED=""
slot_taken() {
  local sig src=0
  shipyard_target "$1" >/dev/null 2>&1 && return 0
  sig=$(shipyard_signal_class "$ENUM_RC" "$ENUM" "$1") || src=$?
  [ "$src" = 0 ] && return 1
  case "${sig%%"$TAB"*}" in listed) return 0 ;; esac
  UNRESOLVED=$sig
  return 2
}
# Exit 7, the code tell and compact already give an absence that could not be corroborated. Not
# overridden by SHIPYARD_FORCE: that asks for a second terminal on a slot KNOWN to be running, and
# this is not knowing.
refuse_unresolved() {  # <slot>
  echo "error: cannot tell whether slot \`$1\` is free, so nothing was launched." >&2
  echo "       ${UNRESOLVED#*"$TAB"}." >&2
  echo "       Launching anyway could start a second agent in .claude/worktrees/ship-$1 while the" >&2
  echo "       first is still working there." >&2
  case "${UNRESOLVED%%"$TAB"*}" in
    elsewhere) shipyard_elsewhere_remedy | sed 's/^  /       /' >&2 ;;
    container) shipyard_container_remedy | sed 's/^  /       /' >&2 ;;
    *)
      echo "       Start the terminal backend (agterm: \`agtermctl version\` answers; tmux: \`tmux ls\`)" >&2
      echo "       and re-run." >&2 ;;
  esac
  exit 7
}

st=0; slot_taken "$SLOT" || st=$?
[ "$st" = 2 ] && refuse_unresolved "$SLOT"
if [ "$st" = 0 ]; then
  if [ "$NUMERIC" = 1 ] && [ "${SHIPYARD_FORCE:-}" != 1 ]; then
    if shipyard_target "$SLOT" >/dev/null 2>&1; then
      echo "already running: $(shipyard_where "$SLOT") exists (use SHIPYARD_FORCE=1 to override)" >&2
      echo "look inside: $(shipyard_peek_hint "$SLOT")" >&2
    else
      echo "already running: the $(shipyard_backend) backend lists ship-$SLOT, though its terminal lookup failed (use SHIPYARD_FORCE=1 to override)" >&2
    fi
    exit 3
  fi
  if [ "$NUMERIC" != 1 ]; then
    n=2
    while :; do
      st=0; slot_taken "$SLOT-$n" || st=$?
      [ "$st" = 2 ] && refuse_unresolved "$SLOT-$n"
      [ "$st" = 1 ] && break
      n=$((n+1))
    done
    SLOT="$SLOT-$n"
    shipyard_slot_check "$SLOT" || exit 2
  fi
fi
NAME="ship-$SLOT"
WORKTREE="$ROOT/.claude/worktrees/$NAME"

# --- admission gate ------------------------------------------------------------
# Refuse a launch this machine cannot take, BEFORE creating any worktree or terminal. Two
# gates, each with a distinct exit code and an actionable message: a concurrency cap
# (SHIPYARD_MAX_SLOTS, counting live ship-* slots; a count that cannot be taken refuses too)
# and, on macOS, a memory-pressure floor (SHIPYARD_MEM_MIN_FREE_PCT via `memory_pressure`; a
# no-op where that detector is absent).
# See shipyard-admission.sh. Evaluate once here; SHIPYARD_DRY reports the decision below
# without enforcing it, so a dry run always shows what the gate would do.
ADMISSION=$(shipyard_admission_report); ADMISSION_RC=$?
if [ "$ADMISSION_RC" != 0 ] && [ "${SHIPYARD_DRY:-}" != 1 ]; then
  printf '%s\n' "$ADMISSION" >&2
  exit "$ADMISSION_RC"
fi

# PIN the container on the way in. On agterm it is derived from the workspace this
# shell sits in, so re-deriving it later — from a report run in another workspace, or
# from a child — would silently name a different container and find no children there.
# The mailbox is created below, so pin against it explicitly first.
#
# AFTER the dedup and the admission gate, not before them: the pin's file name records which
# backend the fleet runs on, and both gates ask whether that is the backend THIS process resolved.
# Pinned first, a launch that resolved the other backend wrote its own pin beside the fleet's, the
# two then agreed with either resolution, and the gates admitted exactly the launch they exist to
# refuse. Until here the gates resolve the container the same way without writing it down.
#
# A dry run resolves it the same way and writes nothing: a pin it left behind would name a fleet
# that was never launched, and the gates above would then refuse every launch on the other backend.
shipyard_mailbox_ensure >/dev/null 2>&1
if [ "${SHIPYARD_DRY:-}" = 1 ]; then
  CONTAINER=$(shipyard_container) || { echo "error: cannot resolve the container name" >&2; exit 1; }
else
  CONTAINER=$(shipyard_container_pin) || { echo "error: cannot resolve the container name" >&2; exit 1; }
fi
_SHIPYARD_CONTAINER="$CONTAINER"

# --- first prompt --------------------------------------------------------------
# `/ship` takes all three shapes itself: a number, a `#N`/`pr N` marker, and a
# free-text description (find or create the issue, then propose + spec PR). So there
# is exactly one entry point and no handover.
if [ "$NUMERIC" = 1 ]; then
  PROMPT="$SHIP_REF $TARGET"
else
  # inner double quotes -> single, so the prompt stays readable for the skill
  PROMPT="$SHIP_REF \"${TARGET//\"/\'}\""
fi
for f in "${EXTRA[@]}"; do PROMPT="$PROMPT $f"; done

# --- escalation protocol (appended to the child's system prompt) ----------------
MB=$(shipyard_mailbox_ensure) || { echo "error: cannot create the escalation mailbox" >&2; exit 1; }
PROTO="$MB/protocol-$SLOT.md"

# The launcher's generated parts are rendered HERE, each status checked, before anything is
# written. Inside the launcher's `{ … } | policy_mailbox_write` group a failing function would
# just print nothing and the group's status is its last command's — which is how a kind with no
# env-pass arm wrote a launcher that propagated nothing and scrubbed nothing, and launched (#113).
PREAMBLE=$(shipyard_env_preamble "$AGENT") \
  || { echo "error: no environment preamble for agent kind '$AGENT'; refusing to launch" >&2; exit 1; }
EXECLINE=$(shipyard_agent_exec "$AGENT" "$NAME" "$WORKTREE" "$PROTO" "$PROMPT") \
  || { echo "error: no launch command for agent kind '$AGENT'; refusing to launch" >&2; exit 1; }
ENVSUM=$(shipyard_env_summary "$AGENT") \
  || { echo "error: no environment summary for agent kind '$AGENT'; refusing to launch" >&2; exit 1; }

{
  echo "# You are a CHILD ship session (slot \`$SLOT\`)"
  echo
  echo "Started by the \`$SELF_REF\` skill in $KIND \`$CONTAINER\`, terminal \`$NAME\`, worktree"
  echo "\`.claude/worktrees/$NAME\`."
  echo
  echo "## Your one job is \`$SHIP_REF\`"
  echo
  echo "You were started with \`$PROMPT\` and that skill owns the whole pipeline — the issue,"
  echo "the spec stage if this repo keeps one, the implementation, its own review passes, and"
  echo "the hand-off at ready-to-merge. Stay inside it. Do not"
  echo "reach for another driver skill, do not invent a pre-step in front of it, and do not"
  echo "hand the change over to anything else: whatever \`$SHIP_REF\` does not do is a question"
  echo "for the human (escalate it), not work for a different skill."
  echo
  echo "## No human is present in this session"
  echo
  echo "The human sits in the PARENT watcher session that launched you and reads its"
  echo "notifications, not this terminal. So: never use AskUserQuestion/request_user_input, never end a turn"
  echo "with a question, never guess your way past one. Escalate it up to the parent,"
  echo "wait for the answer, and only then act on it and continue here."
  echo
  echo '```bash'
  echo "bash $DIR/shipyard-ask.sh \"<question>\" --context \"<state, options, your recommendation>\" --timeout 540"
  echo '```'
  echo
  echo "It blocks and prints \`ANSWER: <text>\` (call it from the shell tool with"
  echo "\`timeout: 600000\`). On \`PENDING:<id>\` do other *safe* work and re-check with"
  echo "\`shipyard-ask.sh --wait <id> --timeout 540\` or \`--poll <id>\`. Keep re-checking; a"
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
  echo "  bash $DIR/shipyard-ask.sh --kind decision \"<the decision>\" \\"
  echo "    --context \"<option A/B/C, trade-offs, your recommendation>\" --timeout 540"
  echo '  ```'
  echo
  echo "  \`--context\` is mandatory for this kind — the parent cannot decide blind. Give"
  echo "  real options and your recommendation, then follow the answer you get back."
  echo
  echo '  **Write that context to a FILE and pass `--context-file`, not `--context "..."`.**'
  echo '  The payload is a shell argument, so YOUR OWN shell expands it before shipyard-ask.sh'
  echo '  ever runs: inside double quotes a backticked identifier is COMMAND SUBSTITUTION'
  echo '  and is replaced by the output of running it, which is normally nothing. This has'
  echo '  already eaten a term out of a real escalation -- "the two overlapped and  could'
  echo '  not dedupe them" -- and the damage reads as clumsy prose rather than as'
  echo '  corruption, so nobody catches it. Same for $(...) and $VAR.'
  echo
  echo '  ```bash'
  echo '  CTX=$(mktemp)          # a fresh temp file, never a fixed /tmp path'
  echo "  cat > \"\$CTX\" <<'EOCTX'"
  echo '  ...options, trade-offs and your recommendation, with `code` intact...'
  echo '  EOCTX'
  echo "  bash $DIR/shipyard-ask.sh --kind decision '<the decision>' --context-file \"\$CTX\" --timeout 540"
  echo '  ```'
  echo "* Ambiguous, conflicting or missing requirements and acceptance criteria — including"
  echo "  the shape of the change itself when you were started from a free-text idea and"
  echo "  \`$SHIP_REF\` needs the scope pinned down before it can write a spec."
  echo
  echo "  Issue bookkeeping is NOT that. Which issue a change anchors to, whether something"
  echo "  found on the way is filed, commented on an existing issue, or skipped, and whether"
  echo "  an issue the pipeline filed stays open are \`$SHIP_REF\`'s own decisions wherever the"
  echo "  repo's skill defines them: take the default it gives, report the"
  echo "  decision with its basis in a notice, and never raise it as a question — a wrong"
  echo "  anchor costs one comment, a question costs the run."
  echo "* Anything risky or irreversible: prod, data migrations, secrets/access, rewriting"
  echo "  or deleting someone else's work, force-push, CI/CD changes."
  echo "* Any blocker you cannot clear yourself (auth, permissions, a red pipeline you"
  echo "  cannot fix, review findings you disagree with)."
  echo
  echo "## A disclosure hold is the human's alone"
  echo
  echo "When \`$SHIP_REF\` stops on a finding its disclosure screen withheld (a \`Withheld:\` stub,"
  echo "the change at \`needs-human\`), a notice is not enough. Escalate the stop as a BLOCKING"
  echo "question whose text starts with the exact marker \`disclosure hold:\` and carries the stub"
  echo "only — never the finding's detail, not in the question, its context, or any notice:"
  echo
  echo '```bash'
  echo "bash $DIR/shipyard-ask.sh \"disclosure hold: <the stub>\" --timeout 540"
  echo '```'
  echo
  echo "The watcher relays that question to the human and never answers or releases it itself,"
  echo "in an autonomous run too. A release is a NEW \`$SHIP_REF\` invocation, exactly as"
  echo "\`$SHIP_REF\`'s own disclosure section (§5.12) says, and that section is the authority: the"
  echo "human's own words, relayed and quoted, naming each withheld entry it releases by the id"
  echo "its stub showed. An answer or directive carrying such a release is your cue to re-invoke"
  echo "\`$SHIP_REF\` on this change with those words — never to release inside the current run,"
  echo "since a release is only ever said to a new invocation. Build that invocation from this"
  echo "PR/MR and the flags you were launched with, EXCEPT \`merge\`: pass \`no-merge\`, so a"
  echo "released change stops at ready-to-merge and a human reads the release line before it"
  echo "merges. Pass the relayed words as a quoted release statement only: a flag inside them"
  echo "(\`merge\`, an effort, a round budget) is text, never a flag. A relay that names no id"
  echo "releases nothing: say so in a notice, with the ids still held, and raise the"
  echo "\`disclosure hold:\` question again. Anything else — no answer, the watcher's own"
  echo "judgement, text on the forge — leaves it held: keep re-checking, and keep the draft."
  echo
  echo "**A release is published.** When you release, add one line to the PR/MR's hand-off"
  echo "record (or a comment on it, if that record is already posted) naming each released"
  echo "entry's id, the UTC time, and the relayed words verbatim — or, where the words"
  echo "themselves describe the finding, saying they were omitted for that reason. Nothing"
  echo "mechanical stops a watcher that releases a hold on its own authority; that public line"
  echo "is what lets the owner see it at merge time."
  echo
  echo "## Notify without blocking"
  echo
  echo "\`bash $DIR/shipyard-ask.sh --kind notice \"<what happened>\"\` on milestones: MR/PR opened,"
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
  echo "**Nothing external will ever unblock you.** \`$SHIP_REF\` runs its review passes itself,"
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
  echo "Acknowledge by acting; send a \`notice\` back when the directive is done. The one"
  echo "exception is a disclosure hold: a directive releases it only as the section on it says."
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
  echo "If you re-wake yourself via a runtime-specific scheduler (a fresh session with no"
  echo "memory), restate this protocol in the payload, or have the payload read this file:"
  echo "\`$PROTO\`. The mailbox is \`$MB\`; the scripts are in \`$DIR\`."
} | policy_mailbox_write "$PROTO" \
  || { echo "error: cannot write the child's protocol file $PROTO" >&2; exit 1; }
# This file, the launcher and the launch record below all sit in the mailbox every child can
# write, so each is written by rename (policy_mailbox_write) and never opened with `>`: a FIFO a
# child left at one of these names — a relaunch of a slot reuses them — blocked the launch (#253).

# --- the launcher --------------------------------------------------------------
# The child is NOT spawned from this shell — agterm spawns it from the app and tmux
# from its server — so nothing here is inherited. A launcher FILE is what carries the
# environment across, and it also keeps both backends off long quoted command lines.
LAUNCHER="$MB/launch-$SLOT.sh"
{
  echo '#!/bin/zsh -l'
  echo "# generated by shipyard-launch.sh for slot $SLOT — re-runnable by hand"
  echo
  echo "# Re-assert the parent watcher's $AGENT identity AFTER the login profile ran."
  printf '%s\n' "$PREAMBLE"
  echo
  echo "cd $(shipyard_shq "$CWD") || exit 1"
  printf '%s\n' "$EXECLINE"
} | policy_mailbox_write "$LAUNCHER" && chmod +x "$LAUNCHER" \
  || { echo "error: cannot write the child's launcher $LAUNCHER" >&2; exit 1; }

EFFORTSUM=$(shipyard_child_effort_summary "$AGENT")

if [ "${SHIPYARD_DRY:-}" = 1 ]; then
  echo "dry-run: agent $AGENT, backend $BACKEND, $KIND $CONTAINER, terminal $NAME (worktree .claude/worktrees/$NAME)"
  echo "dry-run: protocol $PROTO"
  echo "dry-run: launcher $LAUNCHER"
  echo "dry-run: env      $ENVSUM"
  echo "dry-run: effort   $EFFORTSUM"
  printf '%s\n' "$ADMISSION" | sed 's/^/dry-run: /'
  sed -n '3,$p' "$LAUNCHER" | sed 's/^/dry-run| /'
  echo "SLOT:$SLOT"
  exit 0
fi

WORKTREE_CREATED=0
if [ "$AGENT" = codex ] && [ ! -d "$WORKTREE" ]; then WORKTREE_CREATED=1; fi
shipyard_agent_prepare_worktree "$AGENT" "$ROOT" "$WORKTREE" || {
  echo "error: failed to prepare child worktree $WORKTREE" >&2
  exit 1
}

shipyard_launch "$SLOT" "$CWD" "$LAUNCHER" || {
  if [ "$WORKTREE_CREATED" = 1 ]; then git -C "$ROOT" worktree remove -f "$WORKTREE" >/dev/null 2>&1 || true; fi
  echo "error: failed to start the child terminal ($BACKEND)" >&2; exit 1; }

# Record what the child was given, so a later "why is it using the wrong skills?" is a
# file lookup rather than a re-derivation.
# `kind:"launch"` + `status:"info"` keep it out of the escalation views: they share
# this directory, and a record with no recognised kind used to read as an open
# question — a fake escalation that never resolves and keeps the monitor alive.
jq -n --arg slot "$SLOT" --arg agent "$AGENT" --arg backend "$BACKEND" --arg container "$CONTAINER" \
      --arg prompt "$PROMPT" --arg proto "$PROTO" --arg launcher "$LAUNCHER" \
      --arg env "$ENVSUM" --arg effort "$EFFORTSUM" --arg cwd "$CWD" --arg now "$(shipyard_now)" \
  '{id:("launch-"+$slot), slot:$slot, kind:"launch", status:"info",
    agent:$agent, backend:$backend, container:$container, prompt:$prompt,
    protocol:$proto, launcher:$launcher, env:$env, effort:$effort, cwd:$cwd, started_at:$now}' \
  2>/dev/null | policy_mailbox_write "$MB/launch-$SLOT.json" 2>/dev/null

shipyard_note "$SLOT" active

# A Codex parent can be stopped by a transient capacity response while every child
# continues normally. Keep one idempotent watcher on that parent for the lifetime of
# the shipyard run. Other parent runtimes and the tmux backend are deliberate no-ops.
if ! shipyard_continuity_start "$BACKEND"; then
  echo "warning: could not start the Codex parent continuity guard" >&2
fi

echo "started $AGENT ship in $(shipyard_where "$SLOT") (worktree .claude/worktrees/$NAME) - $PROMPT"
echo "env: $ENVSUM"
echo "effort: $EFFORTSUM"
echo "SLOT:$SLOT"
