# agent-adapters.sh — the ONE per-agent-kind adapter set, shared by shipyard and council.
#
# SOURCE OF TRUTH: shared/adapters/agent-adapters.sh. Do NOT edit the vendored copies listed in
# shared/adapters/targets.txt — edit here, run `scripts/sync-driver.sh`, and commit the canonical
# AND the copies together. The repo gate (scripts/check.sh, check 11) fails on a drifted copy.
#
# Why a vendored copy and not a symlink or an import: a Codex plugin is installed as a
# self-contained directory and cannot depend on another plugin, so each plugin carries its own
# copy of shared code. The gate — not the filesystem — is what makes the copies one source of
# truth, because a symlink cannot cross the boundary a Codex install draws.
#
# WHAT THIS IS: the per-KIND layer of the shared agent-harness core (DRV-02). It answers one
# question — "how do I start agent kind X with a goal, in this cwd, with this protocol, and what
# is its identity?" — in one place, so shipyard and council launch the same kind the same way.
# It is the sibling of shared/driver/agent-driver.sh, which drives the terminal a launched agent
# lives in and deliberately knows nothing about agent kinds; this file is the half that does.
#
# Adding an agent kind is ONE edit HERE and touches no caller: a `case` label in each of the
# functions below. Nothing in shipyard or council enumerates kinds by hand — both ask `adp_known`
# and `adp_kinds`.
#
# WHAT THIS IS NOT: it does not decide WHICH kind a caller may launch (shipyard admits only
# claude and codex; council admits every kind here), it does not carry either skill's launcher
# preamble (shipyard's CLAUDE_*/CODEX_* propagation and scrub list, council's protocol and roster
# wiring), and it does not write or run the launcher. It renders one `exec` line.
#
# Source only, never execute. Sourced into a shell that may run `set -u`, so every optional
# variable is read as `${VAR:-}`. The baseline interpreter is bash >= 5, matching the shared
# driver (a caller on an older bash re-execs into a modern one before sourcing, as council.sh
# does).

# A version marker, bumped when the body changes, so sync + the drift gate stay easy to prove.
_ADP_VERSION=1

# --- the kinds -----------------------------------------------------------------
# One per line, sorted, so a caller can `paste -sd, -` them into a message.
adp_kinds() { printf '%s\n' agy claude codex; }

# adp_known <kind> — rc 0 when this file can launch that kind.
#
# THIS IS THE ONLY ADMISSION TEST, and it is a `case` over literals. It replaced a probe for
# `<skill>/adapters/<kind>.sh` that a caller then SOURCED, which made an agent kind a path: a
# roster naming a kind reached a file, so a participant able to write into the (writable) skill
# directory could plant a plausibly-named file and have the supervisor source it on the next
# relaunch. A kind is now a `case` label and never a path segment, so a planted file is inert.
# Callers must validate through here BEFORE dispatch, and must not rebuild a path from a kind.
adp_known() { case "${1:-}" in agy|claude|codex) return 0 ;; *) return 1 ;; esac; }

# POSIX-shell-safe quoting of one word, for DATA this file interpolates into a launcher.
#
# Single-quoting, not `printf %q`: `%q` is a bashism that emits `$'...'` for a value holding a
# newline or a control character, while `'...'` is correct in every POSIX shell for every byte —
# and the two launchers this renders into run under different shells (council's under bash,
# shipyard's under `zsh -l`). Same argv either way for ordinary paths; this one is right for all
# of them.
#
# Substitution, not `| sed`: a `$(… | sed …)` form strips the value's TRAILING NEWLINES, which
# the agy fusion below depends on keeping. It also forks twice per argument.
_adp_shq() { local v=${1//\'/\'\\\'\'}; printf "'%s'" "$v"; }

# --- how each kind receives its protocol ---------------------------------------
# adp_protocol_mode <kind> — a READ-ONLY property of the binary's flags, never a caller input:
#
#   system-prompt  the protocol is a real system prompt, read from its file at launch (claude).
#   inline         no system-prompt flag exists, so the protocol's TEXT is fused into the goal
#                  argument (agy).
#   reference      neither is available, so the protocol travels as a PATH the agent is told to
#                  read. The caller must name that path inside its own ADP_PROMPT sentence —
#                  which is why this query exists and has a real caller (codex).
#
# A kind this file does not know has no mode; rc 1 rather than a plausible default.
adp_protocol_mode() {
  case "${1:-}" in
    claude) printf 'system-prompt' ;;
    agy)    printf 'inline' ;;
    codex)  printf 'reference' ;;
    *)      return 1 ;;
  esac
}

# --- how each kind spells "run unattended" -------------------------------------
# ADP_APPROVAL is a normalized two-value knob, because the two callers genuinely need different
# freedom and the difference must not be flattened by unifying them:
#
#   sandboxed  the agent may write, but the sandbox stays on. council uses this: a participant
#              writes into a room OUTSIDE its cwd, which is what `-s workspace-write` plus
#              `--add-dir` buys, and nothing more.
#   full       approvals are off wholesale. shipyard uses this: the child `-C`s into its own
#              worktree and drives a whole change end to end.
#
# Default `sandboxed` — the more confined of the two, so an omitted knob cannot silently widen an
# agent's freedom. Each caller sets it explicitly regardless, and the suite pins both values.
_adp_approval() { case "${ADP_APPROVAL:-sandboxed}" in full) printf 'full' ;; *) printf 'sandboxed' ;; esac; }

# --- adp_cmd <kind> — render the `exec` line(s) --------------------------------
# Prints the launch command for one kind, reading these caller-set variables. EVERY ONE IS
# OPTIONAL and each flag is emitted IFF its variable is set and non-empty — that rule is what
# lets one renderer reproduce both callers' command lines exactly, and what keeps a knob only one
# caller happens to use today from imposing anything on the other.
#
#   ADP_PROMPT     the goal text (the one argument every kind takes).
#   ADP_PROTOCOL   path to the protocol / system-prompt file; delivered per adp_protocol_mode.
#   ADP_DIRS       extra directories to grant, one per line -> `--add-dir` each.
#   ADP_CWD        the directory the agent itself should run in (codex `-C`).
#   ADP_NAME       a session identity; where the CLI has session flags they are wired to it.
#   ADP_EFFORT     reasoning-effort selector, where the CLI has one.
#   ADP_APPROVAL   sandboxed|full, above.
#
# QUOTING RULE: `_adp_shq` quotes DATA. The shell constructs this file emits — claude's
# `"$(cat <proto>)"` and agy's inline fusion — are SYNTAX, with the path quoted inside the
# substitution. Single-quoting one of those whole would hand the agent the literal characters
# `$(cat ...)` as its protocol, and every seat would come up with no protocol at all while the
# launch still looked healthy.
adp_cmd() {
  local kind="${1:-}" d
  adp_known "$kind" || return 1

  case "$kind" in
    claude)
      printf 'exec claude'
      [ -n "${ADP_NAME:-}" ]   && printf ' -w %s' "$(_adp_shq "$ADP_NAME")"
      [ -n "${ADP_EFFORT:-}" ] && printf ' --effort %s' "$(_adp_shq "$ADP_EFFORT")"
      [ -n "${ADP_NAME:-}" ]   && printf ' -n %s' "$(_adp_shq "$ADP_NAME")"
      # claude has one unattended mode; both approval levels map onto it.
      printf ' --permission-mode auto'
      [ -n "${ADP_NAME:-}" ]   && printf ' --remote-control %s' "$(_adp_shq "$ADP_NAME")"
      while IFS= read -r d; do
        [ -n "$d" ] && printf ' --add-dir %s' "$(_adp_shq "$d")"
      done <<< "${ADP_DIRS:-}"
      printf ' \\\n'
      # system-prompt mode: the file is READ at launch, so this stays a substitution.
      [ -n "${ADP_PROTOCOL:-}" ] \
        && printf '  --append-system-prompt "$(cat %s)" \\\n' "$(_adp_shq "$ADP_PROTOCOL")"
      printf '  %s\n' "$(_adp_shq "${ADP_PROMPT:-}")"
      ;;

    codex)
      printf 'exec codex'
      case "$(_adp_approval)" in
        full)      printf ' --approve-for-me' ;;
        sandboxed) printf ' -s workspace-write -a never' ;;
      esac
      [ -n "${ADP_CWD:-}" ] && printf ' -C %s' "$(_adp_shq "$ADP_CWD")"
      while IFS= read -r d; do
        [ -n "$d" ] && printf ' --add-dir %s' "$(_adp_shq "$d")"
      done <<< "${ADP_DIRS:-}"
      printf ' \\\n'
      # reference mode: codex has no system-prompt flag, so ADP_PROTOCOL is not rendered here at
      # all — the caller has already named the path inside ADP_PROMPT (adp_protocol_mode says so).
      printf '  %s\n' "$(_adp_shq "${ADP_PROMPT:-}")"
      ;;

    agy)
      # `--dangerously-skip-permissions` is not a preference: agy raises an un-suppressible
      # file-access prompt for any path a participant DISCOVERS for itself, with no "always"
      # option, and while it is up the agent holds the floor and looks exactly like one that is
      # thinking. See adp_notes.
      printf 'exec agy --dangerously-skip-permissions'
      while IFS= read -r d; do
        [ -n "$d" ] && printf ' --add-dir %s' "$(_adp_shq "$d")"
      done <<< "${ADP_DIRS:-}"
      printf ' \\\n'
      # inline mode: the goal and the protocol's TEXT are ONE argument. Adjacent quoted strings
      # concatenate into a single word, so the goal stays single-quoted DATA and only the
      # substitution is syntax — no double-quote escaping of caller text anywhere.
      if [ -n "${ADP_PROTOCOL:-}" ]; then
        printf '  -i %s"$(cat %s)"\n' \
          "$(_adp_shq "${ADP_PROMPT:-}"$'\n\n')" "$(_adp_shq "$ADP_PROTOCOL")"
      else
        printf '  -i %s\n' "$(_adp_shq "${ADP_PROMPT:-}")"
      fi
      ;;
  esac
}

# --- adp_notes <kind> <label> — what a human must know about this kind ----------
# Printed once per kind when a supervisor starts agents. Multi-line on purpose; a caller that
# de-duplicates must do it by KIND, never by sorting the lines (an indented continuation sorts
# above the sentence it continues, and the one instruction the human has to act on comes out
# shuffled).
adp_notes() {
  local kind="${1:-}" label="${2:-}"
  case "$kind" in
    claude) : ;;
    codex)
      printf 'codex (%s): the first launch in an unfamiliar directory asks you to trust it.\n' "$label"
      printf '            until you answer, the participant holds the floor and looks wedged.\n'
      ;;
    agy)
      printf 'agy (%s): launched with --dangerously-skip-permissions, so it does not prompt.\n' "$label"
      printf '          That flag is why the seat runs unattended: without it a path the\n'
      printf '          participant discovers for itself raises a file-access prompt while it\n'
      printf '          holds the floor, and the menu offers no "always" option. It applies to\n'
      printf '          launched sessions only, never to an interactive agy.\n'
      printf '          A room itself no longer needs it — the protocol arrives as an argument\n'
      printf '          and the agenda and record are verbs — but files a participant opens\n'
      printf '          OUTSIDE the room still do.\n'
      printf '          The first launch in a directory agy has not seen also asks you to trust\n'
      printf '          it; the flag does not answer that one for you.\n'
      ;;
    *) return 1 ;;
  esac
}

# --- adp_skill_ref <kind> <skill-name> — how a skill is invoked in that agent ---
# `/name` in claude, `$name` in codex. agy's syntax is not established here, so it returns rc 1
# rather than a plausible guess: a wrong invocation string produces a child that starts fine and
# then does nothing anyone asked for. Its only caller today admits claude and codex only.
adp_skill_ref() {
  case "${1:-}" in
    claude) printf '/%s' "${2:-}" ;;
    codex)  printf '$%s' "${2:-}" ;;
    *)      return 1 ;;
  esac
}

# --- adp_parent_kind — which kind is running THIS session -----------------------
# Environment markers first (they are authoritative: they say what actually started us), then
# what is installed. agy publishes no parent marker, so it is never auto-detected — a caller that
# wants it must be told explicitly. `none` when nothing is available.
adp_parent_kind() {
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
}
