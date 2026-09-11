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
# Adding an agent kind is ONE edit HERE — a `case` label in each of the functions below — and it
# touches no caller THAT ADMITS EVERY KIND. council is such a caller: it enumerates no kinds of
# its own, asking `adp_known` what is launchable and `adp_protocol_mode` how to word the greeting,
# so a kind added here works there with no edit. shipyard is NOT: it keeps a deliberately narrower
# admission set of its own (`shipyard_agent_kinds`) and widening that is a shipyard decision, made
# there. Neither statement is a promise that a new kind is launchable everywhere.
#
# WHAT THIS IS NOT: it does not decide WHICH kind a caller may launch (shipyard admits only
# claude and codex; council admits every kind here), it does not carry either skill's launcher
# preamble (shipyard's CLAUDE_*/CODEX_* propagation and scrub list, council's protocol and roster
# wiring), and it does not write or run the launcher. It renders one `exec` line.
#
# Source only, never execute. Sourced into a shell that may run `set -u`, so every optional
# variable is read as `${VAR:-}`.
#
# THE INTERPRETER FLOOR IS BASH 3.2, which is lower than the shared driver's and is deliberate:
# this file is sourced IN-PROCESS into `shipyard-report.sh`, which must stay bash-3.2-clean (it
# spawns the flow guard as a subprocess for exactly that reason) and re-execs into nothing. So a
# bash-4+ construct here — an associative array, `${var^^}`, `mapfile` — would break status
# reporting on a stock macOS shell, where /bin/bash is 3.2. council re-execs into bash >= 5 before
# sourcing anything, so it constrains nothing; shipyard is the binding caller.

# A version marker, bumped when the body changes, so sync + the drift gate stay easy to prove.
_ADP_VERSION=2

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

    # Verified on codex-cli 0.149.0: `-s workspace-write` plus `--add-dir` lets it write into a
    # directory outside its cwd, and its shell tool tolerates a block of at least 200s, so a
    # blocking read with a ~180s timeout is safe. `-a` (ask-for-approval) exists only on the
    # interactive command, not on `codex exec`.
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
    # `adp_known` gates entry, so this arm is reachable only if the two kind sets drift — which
    # is exactly what "add a case label in each of the functions below" invites. Every other
    # entry point here already refuses an unhandled kind; without this one, a half-added kind
    # would render NOTHING at rc 0, and both callers would write a launcher with no exec line,
    # chmod it, start it, watch it exit 0, and report a successful launch.
    *) return 1 ;;
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

# --- the child's TURN STATE, and whether what we typed started one --------------
# Both skills ask this question. `shipyard tell` asks it to confirm a directive actually landed;
# `council say` has the same gap (its confirmation only proves the keystrokes were injected). It
# lives here, in the per-agent-kind module, because a client's on-screen vocabulary is per-KIND
# knowledge — the terminal backend knows agterm from tmux and nothing about what a client renders.
#
# It is deliberately KIND-LESS: no caller passes a kind, because no caller needs to. Each of the
# markers below has ONE home per kind, and no kind uses another's home, so accepting either shape
# answers the question without ever being told which client is on screen. THE SEAM: the day two
# kinds disagree about the same home, these functions take a kind and the callers grow the lookup
# — not before. Adding that parameter today would buy nothing and cost every caller.
#
# WHY ANCHORING, AND WHAT IT IS FOR. A plain substring search over the whole capture is what this
# replaced, and it was wrong in a way that matters: a caller TYPES its message into the child's
# input box, and the capture includes that box — so a directive that merely mentioned a marker
# manufactured the very evidence the read was looking for, and an unsubmitted message reported as
# delivered. Three real shapes carry the markers and nothing else may:
#
#   * the FOOTER, which is the last non-empty line of the capture;
#   * a SERVICE LINE, whose first character is the bullet below, in column one;
#   * the composer PLACEHOLDER, which only renders while the box is empty (see the queued arm).
#
# Everything else is ignored, and that is what excludes the three ways the old read was fooled: a
# marker inside the box's first line, inside a WRAPPED continuation of it, and inside transcript
# content (a child displaying this repo's own source — the case that permanently poisons a slot).
# Tool output is indented, so it is never column one and never last; the discipline is the one
# `shipyard-continuity.sh` already documents for the other client's service lines.
#
# Every shape above was read off a LIVE capture of both admitted kinds, committed as fixtures in
# `tests/fixtures/pane-*.txt` with their provenance in `panes.notes`. Do not retune an anchor
# without a capture: too loose restores the false confirmation, and too tight makes a healthy
# running turn read as not-running, so the commonest healthy path alarms and an operator learns to
# ignore the signal.
#
# RESIDUAL the gate cannot check, stated here because it lives here: the footer arm assumes a
# footer is rendered, so if a client ever omits it the last non-empty line could be a box line.
# None of the nine captures showed that.
ADP_TURN_MARKER='esc to interrupt'

# A service line's column-one bullet. One kind puts BOTH its turn marker and its queued header
# here; the other uses this for neither.
ADP_SERVICE_BULLET='•'

# The composer glyphs, and the separators that follow them. One kind follows its glyph with a
# NON-BREAKING space, which is why the separator is stripped explicitly rather than with a
# whitespace class: under `LC_ALL=C` (which the suites set) a class would not match it.
ADP_BOX_GLYPHS='❯ ›'
ADP_NBSP=$'\xc2\xa0'

# The queued hints, pinned to the SHORTEST leading phrase common to every observed variant rather
# than to the longest phrase seen — so a client varying the rest of the sentence cannot break the
# match. One kind renders its hint as the composer placeholder; the other as a service line.
ADP_QUEUED_BOX_HINT='Press up'
ADP_QUEUED_BLOCK_HINT='Messages to be submitted'

# Set by BOTH line helpers instead of returned, so the hot predicates fork nothing: these run once
# per line per poll sample, and a command substitution there costs a process each time.
#
# The name is deliberately LINE-neutral rather than box-specific, because the service-line helper
# writes it too. A box-flavoured name here would make the running predicate's service arm read as
# if it inspected the composer — which is the exact misreading the anchor comment above spends its
# length preventing, and the one that would invite someone to "simplify" the read back into the
# forgery this closed.
_ADP_LINE_CONTENT=''

# _adp_box_content <line> — 0 when the line is the composer's, with its content (after the glyph
# and one separator) in $_ADP_LINE_CONTENT. 1 when the line is not a box line.
_adp_box_content() {
  local line="${1:-}" g rest
  # `local IFS=' '` because the loop below splits an unquoted expansion, which otherwise splits on
  # the CALLER's IFS — and this module is sourced into other people's shells. Measured: under
  # `IFS=,` the expansion yields one word, no line matches, and the queued read answers `running`
  # instead of `queued`. A silent wrong answer, not an error.
  local IFS=' '
  for g in $ADP_BOX_GLYPHS; do
    case "$line" in
      "$g"*)
        rest=${line#"$g"}
        rest=${rest# }
        rest=${rest#"$ADP_NBSP"}
        _ADP_LINE_CONTENT=$rest
        return 0 ;;
    esac
  done
  _ADP_LINE_CONTENT=''
  return 1
}

# _adp_service_content <line> — 0 when the line is a column-one service line, content in
# $_ADP_LINE_CONTENT.
_adp_service_content() {
  local line="${1:-}" rest
  case "$line" in
    "$ADP_SERVICE_BULLET"*)
      rest=${line#"$ADP_SERVICE_BULLET"}
      rest=${rest# }
      # Same two-separator strip as the composer helper. Every captured service line uses a plain
      # space, but leaving the arms asymmetric means an NBSP here would silently stop the
      # queued-block prefix matching — and that failure alarms on a healthy child.
      rest=${rest#"$ADP_NBSP"}
      _ADP_LINE_CONTENT=$rest
      return 0 ;;
  esac
  _ADP_LINE_CONTENT=''
  return 1
}

# adp_turn_running <screen> — 0 while a turn is in flight, by the footer or service-line anchor.
adp_turn_running() {
  local screen=${1:-} line last=''
  while IFS= read -r line || [ -n "$line" ]; do
    if _adp_service_content "$line"; then
      case "$_ADP_LINE_CONTENT" in *"$ADP_TURN_MARKER"*) return 0 ;; esac
    fi
    case "$line" in *[![:space:]]*) last=$line ;; esac
  done <<<"$screen"
  case "$last" in *"$ADP_TURN_MARKER"*) return 0 ;; esac
  return 1
}

# adp_turn_queued <screen> — 0 when the CLIENT says it has taken a message for the next turn.
#
# THE INVARIANT, THE TEST, AND THE BELT — in that order, because a maintainer who knows only the
# test will eventually relax it back to a substring match and restore the forgery this closes.
#
#   INVARIANT: on the kind that renders this hint in the composer, the hint IS the placeholder, so
#     it appears ONLY while the box is empty. The real hint and anyone's typed text are therefore
#     mutually exclusive on screen. (Established by capture, not by reasoning.)
#   TEST: "the box's content BEGINS with the hint" is a decidable test for exactly that — the box
#     is showing its own placeholder rather than someone's text. It is not a heuristic that
#     happens to work.
#   BELT: a caller's message also always carries its own bracketed prefix, so a mentioned phrase
#     can only ever land mid-line. Independent of the invariant, and second to it.
#
# The other kind renders the hint as a column-one service line, where no typed text can reach at
# all, so that arm needs no placeholder argument.
#
# NOTE FOR A LATER READER: this reads a box line for a KNOWN literal, which is decidable. It does
# NOT make the open question of whether arbitrary box content is a real draft solvable — a live
# capture during this work showed the client rendering suggestion text nobody typed. That question
# is tracked separately and nothing here answers it.
adp_turn_queued() {
  local screen=${1:-} line
  while IFS= read -r line || [ -n "$line" ]; do
    if _adp_box_content "$line"; then
      case "$_ADP_LINE_CONTENT" in "$ADP_QUEUED_BOX_HINT"*) return 0 ;; esac
    fi
    if _adp_service_content "$line"; then
      case "$_ADP_LINE_CONTENT" in "$ADP_QUEUED_BLOCK_HINT"*) return 0 ;; esac
    fi
  done <<<"$screen"
  return 1
}

# adp_turn_state <screen> — queued | running | idle | unknown, in that precedence.
#
# `unknown` IS NOT `idle`, and the difference is load-bearing: an empty capture is what a FAILED
# read returns as well as what a blank screen returns, and letting it count as idle would let
# adp_delivery_verdict conclude a send landed from a turn that was already running before anything
# was typed. An unreadable screen contributes no evidence at all.
#
# `queued` outranks `running` because one kind carries both markers on the same service line, and
# queued is the more specific answer.
adp_turn_state() {
  if [ -z "${1:-}" ]; then printf 'unknown'
  elif adp_turn_queued "$1"; then printf 'queued'
  elif adp_turn_running "$1"; then printf 'running'
  else printf 'idle'
  fi
}

# adp_delivery_verdict <pre-send-state> [<post-send-state> ...]
#   -> delivered | queued | unconfirmed
#
# What this replaced: a before/after screen DIFF. That diff could not answer the question it was
# asked — typing changes the screen whether or not the submit took, so it was non-empty either way
# and a message left sitting UNSENT reported as delivered. It happened twice in one night on two
# different slots, and both times the child then read as healthy and idle.
#
# The evidence used instead is a STATE, not a change, and BOTH positive verdicts require the
# evidence to be ABSENT and then PRESENT, so that nothing already on screen can be read as being
# about this send:
#
#   * `delivered` needs an idle observation first (`seen_idle`); the pre-send sample may supply it.
#     A child already mid-turn therefore cannot yield it from the turn marker alone.
#   * `queued` needs a NON-queued observation first (`pre_queued` cleared). A hint still rendered
#     from an EARLIER send is not evidence about this one — and because the hint persists while its
#     queue is non-empty, the first post-send sample would otherwise re-supply it and decide, which
#     was a live false positive.
#
# `unknown` clears neither: an unreadable frame is not an observation.
#
# WHAT `unconfirmed` DOES AND DOES NOT RULE OUT — stated here because this is where the word is
# defined. It says no turn was observed to start and the client never said it had queued anything.
# It does NOT prove the message was not delivered: a turn that started AND finished between two
# samples looks identical, so does one on a child whose screen could not be read, and so does a
# child that was mid-turn for the whole window whose client rendered no queued hint. What it DOES
# mean is that the text may be sitting unsent in the input box, which is the one case worth an
# operator's eyes. The bias is deliberate — re-sending on a false `unconfirmed` is cheap and
# visible, believing a false confirmation is neither — and dense sampling by the caller is what
# keeps the false case rare. A fourth verdict naming the residual would be fuzzier than these three.
adp_delivery_verdict() {
  # `pre_queued` starts at 1, i.e. ASSUME a hint may already be there. It is cleared only by a
  # POSITIVE observation that there is none. Starting it at 0 made absence of a baseline grant the
  # baseline: an unreadable pre-send frame — which `drv_read` returns for every backend failure,
  # indistinguishable from a blank screen — let the first stale hint decide, so
  # `unknown queued` confirmed a send that never took. That is the same false positive as the
  # screen diff, through a different door. `seen_idle` needs no such treatment: it already
  # requires a positive observation to become 1.
  local state seen_idle=0 pre_queued=1
  case "${1:-}" in
    idle)   seen_idle=1; pre_queued=0 ;;
    running)             pre_queued=0 ;;
    queued)              pre_queued=1 ;;
  esac
  shift 2>/dev/null || true
  for state in "$@"; do
    case "$state" in
      queued)  [ "$pre_queued" = 1 ] || { printf 'queued'; return 0; } ;;
      running) pre_queued=0; [ "$seen_idle" = 1 ] && { printf 'delivered'; return 0; } ;;
      idle)    pre_queued=0; seen_idle=1 ;;
    esac
  done
  printf 'unconfirmed'
}

# --- WHY a child is not moving: the waits and faults a client ANNOUNCES ---------
# Both skills ask this question, and both get it wrong the same way. shipyard's stall watchdog
# measures MOTIONLESSNESS and concludes death, so a child that CANNOT move (a usage limit) and a
# child nobody ASKED to move both read as wedged — and the remedy it prints ends in compaction,
# discarding live context to cure a condition the child does not have. Measured three times on one
# fleet: a rate-limited pair, a finished change correctly waiting for a human, and a 90-hour
# operator pause that produced a 5420-minute alarm. council's room STALL alarm has the same blind
# spot from the other end — a participant blocked on a capacity limit is indistinguishable from one
# that is thinking, and the alarm guesses "it may be sitting on a permission prompt".
#
# What a client RENDERS is per-KIND knowledge, which is why the shapes live here beside the turn
# marker rather than in either skill. What to DO about the answer is deliberately NOT here: this
# returns a class from the driver's AgentSignal vocabulary (DRV-03), so a caller hands it straight
# to `policy_dispose` in shared/policy and gets the one disposition both skills share.
#
# IN PARTICULAR, NOTHING HERE READS A TIME OUT OF A BANNER. shared/policy's ESC-03 already records
# why — a capacity banner states when the window RAN OUT, not when it resumes, so a timestamp
# lifted from one is in the past — and re-deriving that judgement here would be a second place for
# the same question, which is the defect the shared engine exists to remove. The class is the whole
# answer; the resume time is the supervisor's to re-probe.
#
# ANCHORED, for the same reason the turn read is, and with the consequence inverted. The capture
# includes everything the child rendered — its input box AND its own prose — so an unanchored
# substring search lets text that merely MENTIONS a banner manufacture the evidence. Here that
# direction is the dangerous one: a genuinely wedged child would read as "waiting, nothing to do"
# and its alarm would be suppressed. And it is not a hypothetical — a child working on THIS defect
# discusses these very phrases, so its own transcript is full of them.
#
# THE ANCHOR IS AN ALLOW-LIST OF LEADING GLYPHS, not "a line in column one", and that distinction
# is the whole of it. The first version of this function took any column-one line that was not a
# composer line, on the stated grounds that "tool output and transcript content are indented". That
# is TRUE OF TOOL OUTPUT AND FALSE OF ASSISTANT PROSE: `fixtures/pane-claude-running.txt` shows one
# kind rendering its own sentences at column one behind its assistant glyph, with only their
# WRAPPED continuations indented. So a child writing the sentence "the watchdog fires on a usage
# limit" would have classified itself as rate-limited and silenced its own alarm. Only a line whose
# FIRST character is one of the two evidenced client-status glyphs below is eligible, which excludes
# assistant prose, both composers, indented tool output and every wrapped continuation by
# construction rather than by a deny-list that has to anticipate each of them.
#
# BIASED TIGHT, deliberately, and this is the bias that made the bug above survivable in the other
# direction. A shape this MISSES falls through to the caller's existing stall path, i.e. to today's
# behaviour; a shape it matches too LOOSELY silences a real alarm. So the residual must always be a
# miss, never a false clearance — the opposite bias from the turn read, and for the same underlying
# reason: bias towards the failure an operator can still see.
#
# RESIDUAL the gate cannot check, stated here because it lives here. Unlike the turn marker, the
# WORDS below are not pinned to committed pane captures: they are verbatim from the supervising
# operator's reports of what the `last line` column carried, and from the Codex service-line list
# `shipyard-continuity.sh` matches off a real capture — but which glyph each is rendered behind is
# inferred, not observed. The transport-fault phrase in particular has NO observed glyph at all, so
# it classifies only if a client puts it behind the warning glyph, and may in practice never fire.
# That is the safe direction on purpose (see BIASED TIGHT). Add a capture and a fixture when one is
# taken, and widen the allow-list only from a capture — never from reasoning about what a client
# "probably" renders, which is exactly how the first version got it wrong.
#
# Written as explicit `case` arms rather than as an editable ADP_* list, unlike the markers above:
# those are constants because a caller INTERPOLATES them (shipyard-report.sh builds a grep from the
# turn marker), while these are matched only here — and a list would have to be word-split
# unquoted, where the bracket classes below would become pathname globs.

# The warning glyph both admitted kinds put in column one ahead of a client-status banner ("⚠ Usage
# limit reached …", "⚠ Selected model is at capacity …", the second of which shipyard-continuity.sh
# already matches as a whole line off a real capture). A constant, not an inline literal, because it
# is the one thing here a client could rename — and because the assistant glyph it must NOT be
# confused with differs from it by a single codepoint.
ADP_BANNER_GLYPH='⚠'
_ADP_WAIT_CLASS=''

# _adp_wait_line_class <line> — 0 when the line announces a wait or fault, with the AgentSignal
# class in $_ADP_WAIT_CLASS. Set rather than printed, the same way the line helpers above do it, so
# the per-line walk forks nothing.
#
# Each phrase is the SHORTEST leading substring common to every observed variant — the discipline
# the queued hints above state — so a client varying the rest of the sentence cannot break the
# match. The leading letter is a bracket class because both a capitalised form ("Usage limit
# reached · continuing automatically at <time>") and a lowercase one ("You have N usage limit
# resets left") were recorded, on different kinds.
_adp_wait_line_class() {
  case "${1:-}" in
    *[Uu]'sage limit'*)             _ADP_WAIT_CLASS=rate_limited; return 0 ;;
    *[Ss]'ession limit'*)           _ADP_WAIT_CLASS=rate_limited; return 0 ;;
    *'at capacity'*)                _ADP_WAIT_CLASS=overloaded;   return 0 ;;
    # A transport fault, not a capacity one: the TURN died mid-response while the session stayed
    # up. It maps to `error`, so policy escalates it to a human instead of parking — the right
    # answer, because this one does need a nudge. What it never needs is compaction: the context
    # is intact, which is exactly the distinction the measured false alarms collapsed.
    *'went to sleep mid-response'*) _ADP_WAIT_CLASS=error;        return 0 ;;
  esac
  _ADP_WAIT_CLASS=''
  return 1
}

# adp_wait_class <screen> — the AgentSignal class the child's own screen announces, or nothing.
# Prints "<class><TAB><the line that said so>" and returns 0; prints nothing and returns 1 when no
# anchored line carries a known shape.
#
# THE LAST anchored match wins. A screen can still show an older banner above newer output, so the
# most recent announcement is the live one — and a caller should only ask this of a child that is
# already motionless, since on a MOVING child any banner on screen is history by definition.
adp_wait_class() {
  local screen=${1:-} line body hit_cls='' hit_line=''
  [ -n "$screen" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    # THE ALLOW-LIST. Both arms pattern-match from the START of the line, so column one is a
    # property of the match rather than a separate test — and a line that is indented, is assistant
    # prose, is a composer line, or is a wrapped continuation of any of those simply matches
    # neither. The body is what follows the glyph, so a phrase must be in the banner itself and not
    # merely somewhere on a line that happens to begin with one.
    body=''
    case "$line" in
      "$ADP_BANNER_GLYPH"*) body=${line#"$ADP_BANNER_GLYPH"} ;;
      # The other kind states its capacity waits as ordinary service lines, so reuse the helper that
      # already knows that shape rather than spelling the bullet again here.
      *) if _adp_service_content "$line"; then body=$_ADP_LINE_CONTENT; fi ;;
    esac
    [ -n "$body" ] || continue
    if _adp_wait_line_class "$body"; then hit_cls=$_ADP_WAIT_CLASS; hit_line=$line; fi
  done <<<"$screen"
  [ -n "$hit_cls" ] || return 1
  printf '%s\t%s' "$hit_cls" "$hit_line"
}
