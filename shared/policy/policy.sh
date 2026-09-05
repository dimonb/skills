# policy.sh — the ONE escalation-disposition policy, shared by shipyard and council.
#
# SOURCE OF TRUTH: shared/policy/policy.sh. Do NOT edit the vendored copies listed in
# shared/policy/targets.txt — edit here, re-vendor the copies, and commit the canonical AND the
# copies together. Today those copies are kept byte-identical BY HAND: shared/driver/ has drift
# enforced (scripts/check.sh check 11 fails on a drifted driver copy; scripts/sync-driver.sh
# writes them), but that check and sync are driver-specific and do NOT yet see shared/policy/.
# They are being generalized to iterate every shared/<mod>/, which will then enforce this module
# too with no per-module gate code; until that lands, re-vendoring here by hand is what keeps the
# copies honest — the same "one source, enforced" model as shared/driver/, one step behind it.
#
# Why a vendored copy and not a symlink or an import: a Codex plugin is installed as a
# self-contained directory and cannot depend on another plugin, so each plugin carries its own
# copy of shared code. The gate — not the filesystem — is what makes the copies one source of
# truth, because a symlink cannot cross a plugin boundary a Codex install draws.
#
# WHAT THIS IS: the policy layer of the shared agent-harness core. It answers one question —
# "a blocking AgentSignal arrived; what should the supervisor DO about it?" — in one place, so
# shipyard and council dispose of the same signal the same way. It is POLICY, not a running
# supervisor: policy_dispose is a pure lookup the flow guard (a later phase) calls at on_block,
# and the mailbox helpers are the shared channel a needs-human disposition is written to. The
# four things it owns map to the four escalation requirements:
#   ESC-01  policy_dispose — the disposition table over the normalized signal vocabulary.
#   ESC-02  policy_dispose + the declared safe-set — access requests are DEFAULT-DENY.
#   ESC-03  the resume-time guard — a rate-limit park never trusts a stale/past timestamp.
#   ESC-04  policy_mailbox_dir + policy_escalate — the human mailbox, resolvable from any worktree.
#
# THE SIGNAL VOCABULARY (the driver's AgentSignal `class`, DRV-03), one of:
#   liveness    working awaiting_turn crashed
#   needs-human access_request plan_review question escalation
#   capacity    rate_limited context_full overloaded quota_exhausted
#   fault       auth_required error
# A class this file does not recognise is treated as needs-human, never auto-resolved (default
# deny extends past the safe-set to the whole table: an unknown signal is a human's call).
#
# Source only, never execute. Sourced into a shell that may run `set -u`, so every optional
# variable is read as `${VAR:-}` and multi-statement `local` avoids a read-before-assign. The
# baseline interpreter is bash >= 5 (a caller on an older bash re-execs into a modern one before
# sourcing, as council.sh does), matching the shared driver.

# A version marker, bumped when the body changes, so sync + the drift gate stay easy to prove.
_POLICY_VERSION=1

# --- ESC-01 · the disposition table -------------------------------------------------------------
# policy_dispose <class> [payload] [resume_at] -> one disposition token on stdout, exit 0.
#
# The token is `<action>` or `<action>|<detail>`, so a caller splits on the first `|`:
#   continue                 non-blocking — nothing to do (working, awaiting_turn).
#   auto_approve             an access_request whose payload is in the safe-set — approve + resume.
#   compact                  context_full — compact the context and resume.
#   park|<resume_at>         a capacity limit — pause until <resume_at> (a future epoch) and
#                            reschedule. <resume_at> is the literal `reprobe` when no trustworthy
#                            future time is known (ESC-03): the supervisor must re-derive the time
#                            from the agent's usage view, never sleep on a guess.
#   escalate|<reason>        hand to a human via the mailbox. <reason> names the signal:
#                            access | plan_review | question | escalation | auth | crashed |
#                            error | unknown.
#
# `continue` is the ONLY non-blocking token: a caller that sees anything else has a blocking
# signal to act on. The disposition is keyed on the class alone — the class is authoritative for
# what to do — so a caller need not pass the signal's `blocking` flag; the payload matters only
# for access_request, and resume_at only for a capacity park.
#
# A usage error (no class) exits 2 and prints to stderr, distinct from any disposition.
policy_dispose() {
  local class="${1:-}" payload="${2:-}" resume="${3:-}"
  [ -n "$class" ] || { echo "policy_dispose: missing signal class" >&2; return 2; }
  case "$class" in
    # liveness — working/awaiting_turn are not blocking; a crash is a human's problem (a
    # relaunch decision belongs to the guard, not to this table).
    working|awaiting_turn)          printf 'continue' ;;
    crashed)                        printf 'escalate|crashed' ;;
    # needs-human — the four that are, by definition, a person's call.
    access_request)
      # ESC-02: auto-approve ONLY a payload the declared safe-set matches; everything else is a
      # human's call. This is the one class whose disposition depends on the payload.
      if _policy_allowlisted "$payload"; then printf 'auto_approve'
      else                                    printf 'escalate|access'; fi ;;
    plan_review)                    printf 'escalate|plan_review' ;;
    question)                       printf 'escalate|question' ;;
    escalation)                     printf 'escalate|escalation' ;;
    auth_required)                  printf 'escalate|auth' ;;
    # capacity — park and reschedule; the resume time is guarded (ESC-03). overloaded carries no
    # usage-view time, so with no trustworthy resume_at it too parks on `reprobe` (a backoff the
    # supervisor picks), never on a scrollback guess.
    rate_limited|quota_exhausted|overloaded)
                                    printf 'park|%s' "$(_policy_resume_at "$resume")" ;;
    context_full)                   printf 'compact' ;;
    # fault — an error is a human's call; the whole harness may be mid-fault.
    error)                          printf 'escalate|error' ;;
    # DEFAULT-DENY over the whole table: an unrecognised class is never auto-resolved.
    *)                              printf 'escalate|unknown' ;;
  esac
}

# --- ESC-02 · the declared safe-set -------------------------------------------------------------
# The one readable allowlist. An access_request is auto-approved ONLY when its payload matches a
# shape here; DEFAULT-DENY means everything else — network, `git push`, `git reset --hard`, `rm`,
# anything not listed — is escalated to a human. Widen or narrow it by editing this list (it is
# declared config, not inferred at runtime), and remember worktree isolation is the containment
# that makes a conservative allowlist safe: an approved edit or commit lands only in the agent's
# own worktree. Each line is a glob matched against the whitespace-normalised request.
#
# The list is a plain variable, not a `${:-}` env indirection, on purpose: default-deny must not
# be silently widenable from the environment of whatever launched the agent. A test reassigns it
# in its own shell after sourcing; production sources this file and never touches it.
POLICY_SAFE_SET='
edit
edit *
write
write *
apply_patch
apply_patch *
git status
git status *
git diff
git diff *
git log
git log *
git show
git show *
git add
git add *
git commit
git commit *
make check
make check *
make test
make test *
make check-test
make check-test *
'

# _policy_allowlisted <command> -> exit 0 if the safe-set permits auto-approval, 1 otherwise.
# The 1 branch is the default: a command reaches it by matching nothing, so a typo in the list
# fails safe (escalate), never open (auto-approve).
_policy_allowlisted() {
  local cmd="${1:-}" pat
  [ -n "$cmd" ] || return 1
  # A multi-line request is more than one command; a prefix match on the first line would wave
  # the rest through. Detect the newline BEFORE the whitespace collapse below turns it into a
  # space and hides it.
  case "$cmd" in *$'\n'*) return 1 ;; esac
  # Normalise horizontal whitespace so " git   add   -A " matches the "git add *" shape.
  cmd=$(printf '%s' "$cmd" | tr -s ' \t' ' ' | sed 's/^ //; s/ $//')
  [ -n "$cmd" ] || return 1
  # Any shell control operator can smuggle a denied command past a prefix match
  # ("git add . && git push", "git status; rm -rf .", "$(curl evil)"), so a request carrying one
  # is never auto-approved. Over-refusing a benign command that merely contains one of these
  # (a commit message with a pipe, say) only sends it to a human — the safe direction.
  case "$cmd" in
    *'&&'*|*'||'*|*';'*|*'|'*|*'&'*|*'$('*|*'`'*|*'>'*|*'<'*) return 1 ;;
  esac
  local IFS=$'\n'
  for pat in $POLICY_SAFE_SET; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2254
    case "$cmd" in $pat) return 0 ;; esac    # $pat is an intentional glob from the safe-set
  done
  return 1
}

# --- ESC-03 · the resume-time guard -------------------------------------------------------------
# _policy_resume_at <candidate> [now] -> a trustworthy future epoch, or the literal `reprobe`.
#
# A rate-limit banner in an agent's scrollback shows when the window RAN OUT, not when it
# resumes, so a candidate time lifted from one is worthless: it is in the past. This guard is
# what keeps ESC-01's `park` honest — it emits a time ONLY if it is a plain integer strictly in
# the future; anything else (empty, non-numeric, negative, now, or past) becomes `reprobe`, which
# tells the supervisor to re-derive the time from the agent's own usage view rather than sleep on
# a guess. `now` is injectable so a test is deterministic; it defaults to the wall clock.
_policy_resume_at() {
  local cand="${1:-}" now="${2:-}"
  [ -n "$now" ] || now=$(date +%s)
  case "$cand" in
    ''|*[!0-9]*) printf 'reprobe'; return 0 ;;   # empty or not a bare non-negative integer
  esac
  # `now` must itself be an integer for the comparison; if the clock read failed, do not risk a
  # `[: integer expected` error deciding a park — re-probe.
  case "$now" in ''|*[!0-9]*) printf 'reprobe'; return 0 ;; esac
  if [ "$cand" -gt "$now" ]; then printf '%s' "$cand"; else printf 'reprobe'; fi
}

# --- ESC-04 · the human mailbox -----------------------------------------------------------------
# The shared escalation mailbox lives in the common git dir, so the SAME path resolves from the
# main checkout and from every worktree a fleet spawns. This is the exact expression shipyard
# uses for its mailbox and council uses for its room base, kept identical on purpose: council's
# needs-human signals must land in the one directory shipyard's human-facing reporter already
# reads (`.git/ship-escalations/`), so the parent surfaces council and ship escalations together.
policy_mailbox_dir() {
  # An explicit POLICY_MAILBOX_DIR wins — a test points it at a throwaway directory so it never
  # writes into the real mailbox, and an operator could relocate the mailbox with it. Left unset
  # (the production default) the mailbox is the one shipyard's reporter already reads, so council
  # and ship escalations meet in one place. The override does NOT weaken that default: it is
  # opt-in, and shipyard's own resolver has no such knob, so production leaves it unset.
  [ -n "${POLICY_MAILBOX_DIR:-}" ] && { printf '%s' "$POLICY_MAILBOX_DIR"; return 0; }
  local gcd
  gcd=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$gcd" in /*) ;; *) gcd="$(pwd -P)/$gcd" ;; esac   # --git-common-dir may be relative
  gcd=$(cd "$gcd" 2>/dev/null && pwd -P) || return 1
  printf '%s/ship-escalations' "$gcd"
}

# _policy_now -> a UTC timestamp in the mailbox's format (matches shipyard_now).
_policy_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# policy_escalate <kind> <slot> <text> [context] -> writes one escalation entry into the mailbox
# and prints its path. <kind> is question|decision|notice (a `decision` requires context, the
# same contract shipyard-ask.sh enforces). <slot> is the id stem — shipyard passes its slot
# number; council passes a room-derived tag — and the entry is `<slot>-<n>.json`, n the first
# free integer, so two writers on one stem do not collide. The JSON shape is byte-for-byte the
# one shipyard-ask.sh writes, so shipyard-escalations.sh (parent viewer) and shipyard-answer.sh
# (parent reply) consume a council entry unchanged. A `notice` is fire-and-forget — the natural
# kind for council's "this room could not converge, a human should look".
policy_escalate() {
  local kind="${1:-}" slot="${2:-}" text="${3:-}" ctx="${4:-}"
  case "$kind" in
    question|decision|notice) ;;
    *) echo "policy_escalate: kind must be question|decision|notice (got: ${kind:-})" >&2; return 2 ;;
  esac
  [ -n "$slot" ] || { echo "policy_escalate: missing slot (the id stem)" >&2; return 2; }
  # The slot is an id STEM, not a path — it becomes the filename "<slot>-<n>.json". Reject a '/'
  # or a '..' so no caller, now or a future one wiring in more sources, can make the write escape
  # the mailbox directory. Defensive at the boundary (the repo's "refuse malformed input loudly"
  # rule); the only live caller passes council-<basename>, which never contains either.
  case "$slot" in
    */*|*..*) echo "policy_escalate: slot must not contain '/' or '..' (got: $slot)" >&2; return 2 ;;
  esac
  [ -n "$text" ] || { echo "policy_escalate: missing text" >&2; return 2; }
  if [ "$kind" = decision ] && [ -z "$ctx" ]; then
    echo "policy_escalate: kind 'decision' requires context" >&2; return 2
  fi
  local mb
  mb=$(policy_mailbox_dir) || { echo "policy_escalate: cannot resolve the mailbox (not in a git repo?)" >&2; return 1; }
  mkdir -p "$mb" || return 1
  # First free integer for this stem. The same benign race shipyard-ask.sh carries: escalations
  # are rare and the stem is per-room/per-slot, so a collision needs two writers on one stem in
  # the same instant — and the loser would just reuse a number, not clobber, since the winner's
  # file now exists on the next pass.
  local n=1
  while [ -e "$mb/$slot-$n.json" ]; do n=$((n + 1)); done
  local id="$slot-$n" f="$mb/$slot-$n.json" wt
  wt=$(git rev-parse --show-toplevel 2>/dev/null)
  jq -n --arg id "$id" --arg slot "$slot" --arg kind "$kind" \
        --arg text "$text" --arg ctx "$ctx" --arg now "$(_policy_now)" \
        --arg wt "$wt" \
    '{id:$id, slot:$slot, kind:$kind, text:$text, context:$ctx,
      worktree:$wt, created_at:$now, status:"pending", notified:false,
      answer:null, answered_at:null}' > "$f" || return 1
  printf '%s' "$f"
}
