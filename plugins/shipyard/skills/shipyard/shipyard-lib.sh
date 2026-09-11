#!/usr/bin/env bash
# shipyard-lib.sh — shared helpers for the `shipyard` skill. Source only, never execute.
# A child is spawned by a GUI app or by a tmux server, neither of which inherits a login
# shell's PATH — so `git`, `jq`, `gh`/`glab` and `agtermctl` can all be missing even though
# they work fine in your terminal. This prepends the standard system and package-manager
# locations so those lookups succeed. It is a UNION of conventional paths, not one machine's
# layout: entries that do not exist on a given system are inert, and the caller's own PATH is
# preserved at the end, so anything already resolvable stays resolvable.
export PATH="/opt/homebrew/bin:/opt/local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# The terminal a child lives in — agterm (default) or tmux — sits behind the shipyard_*
# functions in shipyard-backend.sh. Nothing else in this skill calls agtermctl or tmux.
# shellcheck source=shipyard-backend.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shipyard-backend.sh"
# shellcheck source=shipyard-agent.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shipyard-agent.sh"
# shellcheck source=shipyard-continuity.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shipyard-continuity.sh"
# The pre-launch admission gate (concurrency cap + macOS memory-pressure). Sourced AFTER the
# backend, whose shipyard_slots it counts. It defines functions only and never touches PATH, so
# the launch inherits the system PATH this file prepended above.
# shellcheck source=shipyard-admission.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shipyard-admission.sh"
# The shared escalation-disposition policy (shared/policy/policy.sh, vendored beside this file and
# kept byte-identical by scripts/sync-driver.sh + the gate's check 11). shipyard carried this copy
# with NO caller until `shipyard_wait_state` below; it is now the module's production consumer on
# this side, which is the point — a vendored module nothing calls is decoration, and the same
# question answered twice is the defect the shared engine exists to remove.
# shellcheck source=policy.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/policy.sh"

# Escalation mailbox. Lives in the SHARED .git (git-common-dir), so the very same
# path resolves from the main worktree (parent watcher) and from
# .claude/worktrees/ship-<slot> (child session). Never committed by construction.
shipyard_mailbox() {
  local gcd
  gcd=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$gcd" in /*) ;; *) gcd="$(pwd -P)/$gcd" ;; esac
  gcd=$(cd "$gcd" 2>/dev/null && pwd -P) || return 1
  printf '%s/ship-escalations' "$gcd"
}

shipyard_mailbox_ensure() {
  local mb; mb=$(shipyard_mailbox) || return 1
  mkdir -p "$mb" || return 1
  printf '%s' "$mb"
}

# Slot of the current session: $SHIPYARD_SLOT, else derived from the worktree name.
shipyard_slot() {
  if [ -n "${SHIPYARD_SLOT:-}" ]; then printf '%s' "$SHIPYARD_SLOT"; return; fi
  local top b
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  b=$(basename "$top")
  case "$b" in ship-*) printf '%s' "${b#ship-}" ;; *) printf '%s' "$b" ;; esac
}

shipyard_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- WHY a motionless child is not moving ---------------------------------------
# shipyard_wait_state <screen> <phase> <stage>
#   -> "<kind>\t<class>\t<label>\t<action>" and rc 0, or nothing and rc 1.
#
# THE DEFECT THIS CLOSES. The stall watchdog measures motionlessness and concludes death. Three
# measured false alarms on one fleet say the same thing from different directions: a rate-limited
# pair (motionless because they CANNOT move), a change parked at its hand-off with every review
# round clean (motionless because it is FINISHED), and a 90-hour operator pause that printed
# "motionless for 5420 min (ctx 44% · 446k). A child does not idle this long on its own" — whose
# stated justification is the one assumption that was false, since it idled that long precisely
# because it was told to. Every one of them ended at a prescription whose last step is compaction,
# i.e. discarding live context to cure a condition the child did not have.
#
# So the watchdog must separate CANNOT MOVE and WAS NOT ASKED from STUCK, and this function is
# where that happens — asked BEFORE the stall clock is consulted. `rc 1` means "no known reason",
# which is STUCK, and the loud block still fires for it unchanged. Making the alarm rarer and right
# is the whole job; making it quieter is not.
#
# IT INVENTS NO KNOWLEDGE OF ITS OWN, which is why it is a handful of lines in this lib rather than
# a script of its own. Three authorities already answer the three parts:
#   * the DECLARED SLOT GRAPH (shipyard-slot-graph.sh) says whether the CHANGE is concluded, so
#     merged/closed/ready-to-merge is read from `$phase` rather than re-tested here — narrowed by
#     ship's own stage, because "the change is over" and "the session has nothing left to do" are
#     not the same question (see the first arm);
#   * shared/adapters (`adp_wait_class`) owns what a client RENDERS, and returns a class from the
#     driver's AgentSignal vocabulary;
#   * shared/policy (`policy_dispose`) owns what to DO with such a class — `park` is a self-healing
#     wait. Nothing here re-derives either, and nothing here reads a time out of a banner (ESC-03
#     in the policy module records why).
# What IS shipyard's own is the one stage the graph deliberately excludes: `needs-human` is a ship
# state a healthy child is SUPPOSED to sit in indefinitely, and it appeared in no script at all.
#
# THIS ANSWERS TWO SCREEN-READ STATES, NOT FIVE, and that is deliberate. An earlier version also
# claimed a transport fault ("the turn died, nudge it"), which read well and rested on nothing: no
# capture shows which glyph a client renders that behind. An exemption that cannot be evidenced is
# worth less than not having it — such a child now falls through to the stall path, whose remedy
# order opens with exactly the nudge it needs. Widen from a capture, never from reasoning.
#
# `<kind>` is `wait` (nothing to do) or `attention` (a person's move, but never compaction).
shipyard_wait_state() {
  local screen="${1:-}" phase="${2:-}" stage="${3:-}" cls='' shown='' ev=''
  # 1. Terminal BY DESIGN, and so exempt whatever the pane shows: a finished change does not become
  #    unfinished because a banner is still on screen above its last line.
  #
  #    BOTH conditions, not the phase alone. The graph's `concluded` is `merged|closed OR stage =
  #    ready-to-merge`, so a forge state of merged is enough to reach it — and a ship session
  #    OUTLIVES ITS FIRST MR by design where a repo lands a spec change before its implementation.
  #    Exempting on the phase alone therefore disarms the stall clock for a child that is still
  #    working, which is the incident shipyard-report.sh's own comment records as measured: "the
  #    supervisor got two green signals while the session sat with an unsubmitted line in its box".
  #    The graph stays the authority for "this change is over"; ship's own stage is what says the
  #    SESSION has nothing left to do, and an exemption needs both.
  case "$stage" in
    ready-to-merge|done)
      if [ "$phase" = concluded ]; then
        printf 'attention\tfinished\t✅ finished\t%s' \
          'nothing is wrong — ship reached a terminal outcome and a human owns the next move: review and merge it, tell it what to change, or tear the slot down if it is already merged. Do NOT compact.'
        return 0
      fi ;;
  esac
  if [ "$stage" = needs-human ]; then
    printf 'attention\tneeds_human\t🙋 needs you\t%s' \
      'ship stopped on blockers it will not fix and posted them — read its record on the PR/MR and answer it. Do NOT compact.'
    return 0
  fi
  # 2. A capacity wait the CLIENT announced. The class is the adapter's; the disposition is policy's.
  #    No resume_at is passed on purpose: the only candidate time would come off the banner, which
  #    ESC-03 exists to refuse, so every capacity class parks on `reprobe` and the action says so.
  #
  #    The evidence line comes back with the class and IS used — the report prints it, so an
  #    operator can see which line bought the exemption rather than taking the verdict on trust.
  #    That matters most for exactly the case this cannot fully rule out: a banner that is live by
  #    the adapter's test but that the operator can see is old.
  # The `|| return 1` an eye expects here would be dead: in a pipeline `$?` is `cut`'s, which is 0
  # even when adp_wait_class found nothing and printed nothing. The emptiness test IS the check.
  ev=$(adp_wait_class "$screen" 2>/dev/null)   # "<class><TAB><the line that said so>", or empty
  cls=${ev%%	*}
  ev=${ev#*	}
  [ -n "$cls" ] || return 1
  case "$(policy_dispose "$cls" 2>/dev/null)" in
    park*)
      shown="$cls"
      [ "$cls" = rate_limited ] && shown=rate-limited
      printf 'wait\t%s\t⏳ %s\t%s' "$cls" "$shown" \
        "a stated, self-healing wait — it resumes on its own. Do not nudge and do NOT compact. The banner states when the window RAN OUT, not when it resumes, so re-probe the agent's own usage view if you need a time. Evidence: ${ev}"
      return 0 ;;
  esac
  # Every OTHER disposition is deliberately unanswered here, and the list is not hypothetical:
  # `compact` for a context ceiling falls through to the stall clock, where the existing rule
  # already governs compaction (only on a ⚠️/🛑 ctx band, never on a ❓ or a blank one), and an
  # unrecognised class falls through as well. Routing through policy rather than testing the class
  # directly is what makes that true BY CONSTRUCTION: a class added to the adapter later arrives
  # here with the shared disposition already attached, and lands on the safe path unless someone
  # deliberately writes an arm for it.
  return 1
}

# --- the child agent's identity -------------------------------------------------
# A child is NOT spawned from the parent's shell: agterm spawns it from the app (GUI
# environment), and tmux spawns it from a server whose environment was frozen whenever
# that server happened to start. Either way the parent's environment does not reach it
# — so anything that decides WHICH Claude the child is must be re-asserted explicitly
# in the launcher, AFTER the login profile has run and possibly set its own value.
#
# CLAUDE_HOME / CLAUDE_CONFIG_DIR are exactly that: they select the config dir, hence
# the skills, settings and memory the child sees. A parent running under a non-default
# one (e.g. a per-project config dir) that lets the child fall back to the profile default
# gets a child with different skills — including, possibly, no `/ship` at all.
#
# Per-session variables go the other way: they must be SCRUBBED. Handing a child the
# parent's CLAUDE_CODE_MESSAGING_SOCKET/TOKEN points it at the parent's IPC channel.
# Emit `export X=…` / `unset X` lines for the launcher. Only variables actually set in
# the parent are exported, so an unset CLAUDE_HOME stays unset rather than becoming "".
shipyard_env_preamble() {
  local agent="$1" v pass scrub
  pass=${SHIPYARD_ENV_PASS:-$(shipyard_agent_env_pass_default "$agent")} || return 1
  scrub=${SHIPYARD_ENV_SCRUB:-$(shipyard_agent_env_scrub_default)} || return 1
  for v in $pass; do
    if [ -n "${!v+set}" ]; then printf 'export %s=%q\n' "$v" "${!v}"; fi
  done
  printf 'unset %s\n' $scrub
}

# One line naming what will be propagated, for the launch log and the mailbox record.
shipyard_env_summary() {
  local agent="$1" v out="" pass
  pass=${SHIPYARD_ENV_PASS:-$(shipyard_agent_env_pass_default "$agent")} || return 1
  for v in $pass; do
    if [ -n "${!v+set}" ]; then out="$out $v=${!v}"; else out="$out $v=<unset>"; fi
  done
  printf '%s' "${out# }"
}

shipyard_esc_file() {
  local mb; mb=$(shipyard_mailbox) || return 1
  printf '%s/%s.json' "$mb" "$1"
}

# In-place jq update of a json file.
shipyard_json_set() {
  local f="$1"; shift
  local tmp="$f.tmp.$$"
  jq "$@" "$f" >"$tmp" 2>/dev/null && mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# --- payload input ------------------------------------------------------------
# Long technical payloads (answers, directives, escalation context) travel as a
# shell ARGUMENT, so the CALLER's shell expands them before this code ever runs.
# In a double-quoted argument `foo` is command substitution and $(x)/$VAR expand,
# so an identifier in backticks is silently replaced by the output of running it
# — usually empty. The record is then written, and looks fine, minus the words
# that mattered.
#
# This is not hypothetical and it is not only an operator error: it has eaten a
# term out of a child's escalation ("the two overlapped and  could not dedupe
# them") and out of a parent's decision ("#N IS THE TRAP.  inside a transaction
# is rejected"). Both read as merely clumsy rather than corrupted, which is what
# makes it expensive.
#
# `shipyard_payload` gives every caller an input channel that no shell touches:
#   shipyard_payload "@/path/to/file"   read the file verbatim
#   shipyard_payload "@-"               read stdin verbatim (heredoc, pipe)
#   shipyard_payload "literal text"     unchanged, for short single-line messages
shipyard_payload() {
  local v="$1"
  case "$v" in
    '@-')  cat ;;
    '@'?*) local p="${v#@}"
           [ -f "$p" ] || { echo "error: payload file not found: $p" >&2; return 1; }
           cat "$p" ;;
    *)     printf '%s' "$v" ;;
  esac
}

# Point the shared driver's container pin at shipyard's mailbox — resolved HERE, at the end,
# because shipyard-backend.sh (which sources the driver) is sourced from the top of this file,
# before shipyard_mailbox is defined. Set in THIS (main) shell so every $(shipyard_*) fork inherits
# it; NOT exported (a launched child and the tmux server must not see it). Empty when outside a
# repo, which leaves the driver unpinned — exactly what the old pin lookup did when the mailbox
# could not be resolved.
DRV_CONTAINER_PIN_DIR=$(shipyard_mailbox 2>/dev/null) || DRV_CONTAINER_PIN_DIR=""

# Resolve the container ONCE, here at the end, for the same reason: shipyard-backend.sh cannot do
# it itself (the pin dir above is only known now). Every dispatch asks via `$(shipyard_container)`,
# i.e. from a subshell, so without this each one would re-read the pin file and, unpinned, re-query
# the agterm tree. A failure here is not fatal: it just leaves the cache empty and the lookup lazy.
_SHIPYARD_CONTAINER=$(shipyard_container 2>/dev/null) || _SHIPYARD_CONTAINER=""
