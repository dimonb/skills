#!/usr/bin/env bash
# shipyard-report.sh — one markdown status table for a set of ship children.
# Usage: shipyard-report.sh [--only-changed] [<slot> ...]
#        no slot args = every `ship-*` terminal in this repo's container
#
# Terminals come from the backend layer (agterm by default, tmux with SHIPYARD_BACKEND=tmux),
# so this script never touches agtermctl or tmux itself — see shipyard-backend.sh.
#
# --only-changed prints NOTHING while the meaningful state is the same as the last
# printed report, so a child parked in idle-wait for hours stops generating identical
# tables. Meaningful = slot, MR iid, terminal present, MR state, pipeline stage, open
# escalation count, the ctx BAND, the WAIT CLASS, and the REAP class (see the stall section
# below — entering or leaving a stated wait is news, and it is news exactly once, which is what
# makes suppressing the stall block for it cost the operator nothing).
# THE REAP CLASSES DO NOT RIDE THE SIGNATURE. A torn-down, held or refused slot bypasses this
# filter outright, like STALLED, so it is printed on every tick the condition lasts — see the
# bypass block near the end of the file for why a per-slot signature is the wrong owner of that
# decision. The class is still in the signature above, which is what makes the tick it CLEARS
# news as well.
# Deliberately NOT meaningful: the timestamp, the
# `last line` column (elapsed time / token counts change every tick), the raw ctx
# figure — only its band — and ▶️/⏸, which flips
# constantly while ship works and re-waits. A terminal report (nothing in flight) is
# always printed, so the end of the run is never swallowed — and so is a tick that could
# NOT TELL whether anything is in flight (the 🛑 NO SIGNAL block below), and a tick whose
# backend disagrees with the fleet's pin, for the same reason: those are the two states
# where silence would be the quietest possible way to say the loudest thing. Exit codes
# are unchanged whether or not anything was printed.
#
# The ctx band has always been in the signature, but it could never move it while the
# column was blind: the old pane-scraping ctx_of returned "—" on current builds, so the
# band was permanently `ok`. Reading it from the transcript makes it a live signal, which
# is why it is named here now — a band crossing is exactly the tick worth breaking
# silence for, and it is the only thing in the ctx column that does.
#
# Design notes:
#  * running-vs-idle comes from a snapshot DIFF (two captures $SHIPYARD_MOTION_INTERVAL apart,
#    3s by default). That answers "is this
#    child MOVING", which is what this column is for, and it is a different question from "is a
#    turn in flight" — a turn marker holds steady across a long tool call, and motion says nothing
#    about whether a turn was ever started. `adp_turn_state` in shared/adapters answers the second
#    question and `shipyard-tell.sh` relies on it; the two are complementary, not rivals. (This
#    note used to say the footer was useless because it "always looks busy". That was about
#    spinner glyphs, it was wrong as written, and a maintainer reading it would have concluded the
#    module this file now imports its marker from could not work.);
#  * the whole report is buffered and printed in ONE block so Monitor batches it
#    into a single notification;
#  * a slot's MR iid is read out of ship's own state (`.pipeline-state/*.json` inside the
#    worktree), and when that file says nothing — a child that never wrote one — out of the
#    FORGE, by the slot worktree's branch. Only when neither can answer is there none, and the
#    slot counts as in-flight;
#  * open escalations are appended, so a question raised between fast-monitor
#    ticks still shows up here;
#  * a slot whose PR/MR has read `merged` on $SHIPYARD_AUTODOWN_TICKS consecutive ticks, whose
#    ship stage is terminal and whose terminal nobody is at, is torn down by calling
#    `shipyard-down.sh` — unchanged, with no flags and never `--force`, so every gate that
#    protects a worktree is the one that runs. An open escalation HOLDS it: a child that stopped
#    to ask is idle because it is waiting for you, and destroying it makes the answer
#    undeliverable. See the block where SHIPYARD_AUTODOWN is read for every lock and why
#    `closed` is not a trigger. It is the one thing here that REMOVES A SLOT rather than
#    observing it; the script's other side effects are its own mailbox bookkeeping
#    (report-sig / -stall / -tick / -merged), the agterm sidebar glyphs it repaints, the pending
#    notices its escalation tail closes, and the Codex parent continuity watcher it re-arms. What it removed, refused or held each get their
#    own block, and all three bypass --only-changed;
#  * a motionless slot is asked WHY before the stall clock is consulted (shipyard_wait_state in
#    shipyard-lib.sh). A child that CANNOT move (a stated capacity wait) and one nobody ASKED to
#    move (finished, or blocked on a human) get their own row and their own block, and are exempt
#    from the clock; only a slot with no known reason is STUCK, and that still raises the loud
#    block. The clock itself is restarted across a gap in supervision, because time this script
#    did not watch is not motionlessness it can report;
#  * exit 0 = nothing in flight (all MRs merged/closed) → stop the loop;
#    exit 1 = work is still open, OR this run could not tell. Those two share an exit code on
#    purpose: the loop's only decision is whether to keep watching, and the answer to "I do not
#    know" is the same as the answer to "yes" — keep watching. Only a CORROBORATED empty answer
#    exits 0 (see the shipyard_signal_class calls below); an unreachable backend, or one that
#    disagrees with the fleet's own container pin, raises 🛑 NO SIGNAL and keeps the monitor alive.
#
# Env:
#   SHIPYARD_BACKEND    agterm (default) | tmux | auto
#   SHIPYARD_WORKSPACE  agterm workspace name (default: the pinned one, see shipyard-backend.sh)
#   SHIPYARD_SESSION    tmux session name    (default: <repo>)
#   SHIPYARD_STALL_SECS motionless seconds before the stall block fires (default: 1800)
#   SHIPYARD_AUTODOWN   1 (default) tears a finished slot down through shipyard-down.sh once
#                       its PR/MR has read `merged` on enough consecutive ticks, ship's stage
#                       is terminal and nobody is at the terminal; 0 leaves teardown entirely
#                       manual. See the block where this is read for every lock
#   SHIPYARD_AUTODOWN_TICKS
#                       consecutive `merged` ticks required (default and minimum: 2)
#   SHIPYARD_CTX_WINDOW context window in tokens, overriding the inference in ctx_window
#   CLAUDE_CONFIG_DIR / CLAUDE_HOME
#                       where a child's transcript is looked up (default: $HOME/.claude);
#                       propagated to children by shipyard_env_preamble when set here
#   GITLAB_HOST         glab host (default: derived from the origin remote)
set -o pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shipyard-lib.sh
. "$DIR/shipyard-lib.sh"
# shellcheck source=shipyard-continuity.sh
. "$DIR/shipyard-continuity.sh"
# The ctx column's logic lives in its own file so that it can be SOURCED — this one cannot be,
# because shipyard_backend_check below exits a process that tries. See shipyard-ctx.sh and its
# tests/ directory.
# shellcheck source=shipyard-ctx.sh
. "$DIR/shipyard-ctx.sh"

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# Resolved ONCE, here, because slot_iid_forge() below runs inside a $( ) per slot and could never
# keep a cache of its own. Empty is a legitimate answer (no origin/HEAD ref, or a fake git in the
# test rig); the one caller treats empty as "no base branch to exclude" and asks the forge anyway.
DEFAULT_BRANCH=$(git -C "$ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null \
  | sed 's#^origin/##')
shipyard_backend_check || exit 1
CONTAINER=$(shipyard_container)
KIND=$(shipyard_container_kind)
if [ -z "${GITLAB_HOST:-}" ]; then
  GITLAB_HOST=$(git -C "$ROOT" remote get-url origin 2>/dev/null \
    | sed -E 's#(git@|https?://)([^:/]+).*#\2#')
fi
export GITLAB_HOST

ONLY_CHANGED=0
declare -a SLOTS=()
for a in "$@"; do
  case "$a" in
    --only-changed) ONLY_CHANGED=1 ;;
    *)              SLOTS+=("$a") ;;
  esac
done

# --- may an EMPTY answer be read as "all shipped"? ---------------------------------------
# EXIT 0 IS THE MONITOR'S STOP SIGNAL, so it is the loudest claim this script makes: the loop in
# Step 2 breaks on it and supervision ends for good. Everything below exists because that claim
# used to be reachable from an ABSENCE — the script asked which terminals exist, got no usable
# answer, and reported the one shape that ends the watch.
#
# Measured: two children were mid-review with open PRs when the agterm control socket failed a
# single probe. `auto` re-resolved to tmux for that one tick, a tmux session named after the repo
# holds no ship windows, and the tick printed "no live ship terminals ... all changes shipped —
# exiting monitor". Both children were alive; re-running seconds later produced the normal table.
# The report was not wrong about what it saw. It was wrong about what seeing nothing MEANS.
#
# So emptiness must be CORROBORATED before it may end the watch, and corroboration is two facts:
#   * the container answered at all (`shipyard_slots` rc — see its contract note), and
#   * we asked the backend this fleet was actually launched on (the container pin's own name).
# Neither is a new kind of knowledge. `shipyard-down.sh` already refuses to drop the container pin
# unless enumeration PROVED the fleet empty (`shipyard_continuity_cleanup_last_slot` returns 2 for
# "could not prove"), so the report is the second consumer to ask, not the first.
#
# It is not the last, either: `shipyard_admission_slot_count` still pipes `shipyard_slots` into
# `wc -l` and drops the status, so the concurrency cap reads an unanswerable question as "nothing
# running". That is the same defect at a different gate, out of scope here and filed on its own —
# recorded so a later reader does not take this block as the end of the sweep.
#
# It is also the same distinction the stall classifier draws one level down. `shipyard_wait_state`
# asks why a SLOT yields no signal and refuses to call "not moving" death; this asks why the FLEET
# yields no signal and refuses to call "not found" completion. One principle, two scopes — and
# deliberately not one function, because the evidence is different in kind: that one reads a
# child's screen, this one reads whether the parent's own transport answered.
ENUM_RC=0
SLOTS_OUT=""
SLOTS_OUT=$(shipyard_slots 2>/dev/null) || ENUM_RC=$?
# The fleet's backend, from the driver's `container-<backend>` pin. Empty when they agree, when
# nothing was ever launched here, or when this run pins nothing — i.e. silent unless it is news.
PINNED_ELSEWHERE=$(shipyard_backend_pinned_elsewhere) || PINNED_ELSEWHERE=""

if [ ${#SLOTS[@]} -eq 0 ]; then
  # Read the list captured above rather than enumerating a second time: two calls could disagree,
  # and the status this run refuses to exit 0 on must belong to the very list it printed.
  while IFS= read -r slot; do
    [ -n "$slot" ] && SLOTS+=("$slot")
  done <<EOF
$SLOTS_OUT
EOF
fi

TAB=$(printf '\t')
# "May an absence be believed?" is `shipyard_signal_class` in shipyard-backend.sh — same two facts
# (did enumeration answer; does the pin name another backend), same two classes, one implementation.
# This file used to carry its own `fleet_signal` saying exactly that; #137 added the shared one and
# named this deletion as owed to this branch, because two answers to one question is the defect the
# shared engine exists to remove.
#
# ALWAYS pass the CAPTURED rc. The function probes for itself when called with no argument, and
# that is the wrong thing here: this script must classify the status of the list it PRINTED, not of
# a second enumeration taken later that could disagree with it. The parameter exists for this.

# The loud refusal, printed wherever an empty answer would otherwise have ended the watch. Modelled
# on the STALLED block deliberately: an operator who has learned that a 🛑 heading means "read this
# one" should not have to learn a second convention for the same severity.
no_signal_block() {  # <class> <why>
  echo "### 🛑 NO SIGNAL — this report cannot tell whether anything is still running"
  echo
  echo "- $2."
  echo "- Finding no ship terminals is therefore not the same as finding that there are none, so"
  echo "  this tick claims nothing about whether the fleet is drained and the monitor keeps running."
  case "$1" in
    unreachable)
      echo "- If the backend is simply down, start it and the next tick reports normally; nothing was lost."
      echo "  agterm: check that the app is running and answering \`agtermctl version\`."
      echo "  tmux:   check \`tmux ls\`."
      # Two causes reach this class and the second one answers `version` perfectly well, so an
      # operator told only to check the socket would find it healthy and have nothing to act on.
      echo "  agterm: if the socket IS answering, the tree it returned did not have the shape this"
      echo "  report requires — inspect \`agtermctl tree --json\`. The shape is asserted over the WHOLE"
      echo "  tree, so a malformed session in an unrelated workspace reaches here too." ;;
    elsewhere)
      echo "- \`SHIPYARD_BACKEND=auto\` decides per PROCESS, so one failed socket probe sends a single tick"
      echo "  to the other backend, where this repo's container is empty for entirely correct reasons."
      echo "  Pin it for the run — \`SHIPYARD_BACKEND=$PINNED_ELSEWHERE\` in the monitor's environment —"
      echo "  and the choice stops moving under you."
      echo "- If that fleet really is finished, the pin is stale. \`shipyard-down.sh\` clears only the pin"
      echo "  of the backend IT resolved, so pin \`SHIPYARD_BACKEND=$PINNED_ELSEWHERE\` first and then tear"
      echo "  the slots down; a down run resolved on the other backend leaves this one in place." ;;
  esac
}

# Where the last printed report's signature lives (shared .git, never committed).
SIGFILE=""
STALLFILE=""
TICKFILE=""
MERGEDFILE=""
MAILBOX_DIR="(mailbox unresolved)"   # named once in the HELD block; the records are basenames
STALL_SECS="${SHIPYARD_STALL_SECS:-1800}"   # 30 min of no movement, idle, nothing asked of you

# How long the motion diff waits between its two captures. THREE SECONDS IS THE PRODUCTION
# ANSWER and is not being changed: it is long enough that a child between two tool calls still
# reads as moving, and short enough that a report of a whole fleet is not itself the pause.
#
# It is a knob because the shipyard suite pays it ~46 times over in one file (t17 runs this
# script once per tick against a FAKE backend whose capture is a fixed file, so the wait
# measures nothing there and cost 118 of the suite's ~825 seconds). A test sets it to
# hundredths; production never does. The separation is the point — making the DEFAULT fast to
# make tests fast would trade a real signal for a cheap number, which is the failure this knob
# exists to avoid rather than to enable.
MOTION_INTERVAL=$(knob_interval "${SHIPYARD_MOTION_INTERVAL:-}" 3) \
  || echo "warning: SHIPYARD_MOTION_INTERVAL is not a usable positive number — using 3" >&2
# ENSURE, not just resolve: if the directory is missing the stall table cannot be
# written, `since` resets to now on every run, and the watchdog silently never
# fires. A watchdog that fails closed is worse than none — it looks armed.
if mb=$(shipyard_mailbox_ensure 2>/dev/null); then
  SIGFILE="$mb/report-sig"; STALLFILE="$mb/report-stall"; TICKFILE="$mb/report-tick"
  MERGEDFILE="$mb/report-merged"
  MAILBOX_DIR="$mb"
fi

# --- a merged slot tears itself down (#181) -------------------------------------------------
# A slot whose PR/MR is merged and whose child has finished is done work, and it used to sit
# there — terminal and worktree both — until somebody remembered `shipyard-down.sh`. This
# calls that script, unchanged, with no flags and NEVER `--force`. That is a binding
# condition and not a style preference: every gate that stands between a teardown and a live
# child's worktree lives in there, so an automatic path that reimplemented any of them would
# be a second, looser teardown that nobody audits.
#
# THE LOCKS. The first two say the work is finished; 2b says nobody is owed an answer; the
# third says nobody is using the terminal; the fourth is the gate that actually protects
# content. They are numbered for reference, not counted — an earlier version of this comment
# said "four locks" in three places and the count went stale the moment 2b was added.
#
#   1. `merged` ON THE FORGE. Not `closed`: a closed PR's content is not in the base branch,
#      so the content gate refuses by construction and this path would only ever print
#      refusals. Left out on purpose — a teardown after a close is a person's call, and the
#      gate's `unmerged` wording is written for a person to read.
#
#   2. SHIP'S STAGE IS TERMINAL (`done` or `ready-to-merge`). MERGED IS NOT "CHILD DONE", and
#      this is the condition that says so: slot_iid reads the LAST state file, so a child
#      that lands one PR and keeps working is invisible behind its own merged number until it
#      writes a new one. The slot graph already encodes the same rule from the other side —
#      `concluded` stays non-terminal while a terminal is live. The cost, stated rather than
#      discovered: a child that writes no state file at all has no stage, so it is never torn
#      down automatically. That is the conservative direction, and the manual path is
#      unchanged for it.
#
#   3. NOBODY IS AT THE TERMINAL — `drv_signal` reports `idle` (an input prompt at the foot of
#      the screen), or there is no terminal and `shipyard_absence_report` CORROBORATES that:
#      the backend answered and does not list the slot. The second half is the same question
#      shipyard-down.sh now asks before it removes anything, so a blip refuses in both places
#      rather than in one. `drv_signal` is called directly rather than through a
#      `shipyard_*` wrapper: `shipyard_signal_class` already owns that name for a different
#      question, and one caller does not earn a second one next to it.
#
#   4. THE CONTENT GATE, inside shipyard-down.sh. It refuses unless the worktree is clean AND
#      its content is proven to be in the base branch. A genuinely merged slot passes by
#      construction — but it is what stands between a MIS-RESOLVED PR NUMBER and a removed
#      worktree, and that is a live path rather than a theoretical one: slot_iid reads a
#      hand-authored `.pr_number`, and on GitLab a slot-number heuristic that returns an ISSUE
#      number for a `#N`-launched slot (its own comment says so). Either can make mr_state
#      report the state of the WRONG object. (The `MR-<slug>.json` basename arm is NOT a third:
#      `sed` passes a non-matching name through, and slot_iid's numeric exit guard then rejects
#      it — that arm yields no number rather than a wrong one.) When it does, this slot's own branch is not in the base branch and the
#      gate answers `unmerged`.
#
# AND CONSECUTIVE OBSERVATIONS ON TOP OF ALL FOUR. $MERGEDFILE carries a per-slot count of how
# many ticks in a row this slot has read `merged` with the SAME iid; the teardown needs
# $AUTODOWN_TICKS of them. Any tick that reads anything else — including the `?` and
# `no MR yet` that #142 measured a flickering forge producing over a child that had not moved
# — drops the entry, so the count is consecutive and not merely cumulative. That is why the
# file is rewritten UNCONDITIONALLY below, unlike the stall table beside it, which is
# preserved when empty.
#
# NOTHING BECOMES LESS VISIBLE THAN IT IS TODAY. Every slot that got this far and was refused
# is named in the ✋ AWAITING REMOVAL block with the exact command to run, so a worktree that
# the automatic path declined is louder than a worktree nobody looked at.
AUTODOWN="${SHIPYARD_AUTODOWN:-1}"
AUTODOWN_TICKS=$(knob_uint "${SHIPYARD_AUTODOWN_TICKS:-}" 2) \
  || echo "warning: SHIPYARD_AUTODOWN_TICKS is not a usable whole number — using 2" >&2
# knob_uint admits 0, and for a WINDOW that is a legitimate setting. Here it is not: a
# threshold of zero or one makes the trigger a single observation of the forge, which is the
# one shape this mechanism exists to rule out. An operator who typed it gets told, rather
# than silently coerced, because the value they set is not the one that will be used.
if [ "$AUTODOWN_TICKS" -lt 2 ] 2>/dev/null; then
  [ -n "${SHIPYARD_AUTODOWN_TICKS:-}" ] && \
    echo "warning: SHIPYARD_AUTODOWN_TICKS=$SHIPYARD_AUTODOWN_TICKS would tear a slot down on a single forge read — using 2" >&2
  AUTODOWN_TICKS=2
fi
MERGED_ROWS=()   # this tick's consecutive-merged counts, rewritten whole (see above)
REAPED=()        # slots this tick tore down
REAP_REFUSED=()  # slots that got as far as the teardown and were refused, with the reason
REAP_HELD=()     # slots held back by an open escalation — finished, but somebody is owed an answer

# autodown_consider <slot> <iid> <state> <stage> <addr> <pending> — the locks above, in cost
# order, then the teardown. Echoes nothing; it reports through globals — MERGED_ROWS, REAPED,
# REAP_REFUSED and REAP_HELD — which is also why it is never called inside a `$( )`: every one of
# them would be appended to in a subshell and lost, and the consecutive count would never advance
# past one. (Named rather than counted: this sentence read "three globals" for exactly as long as
# it took the next round to add a fourth.)
#
# Returns 0 ONLY when the slot was actually torn down, so the caller can stop rendering it as
# a live row. Every other outcome — not eligible, not enough ticks, held, refused — returns 1.
#
# <addr> empty means the slot has no terminal on the backend this run resolved, which is NOT
# the same fact as the child being gone; that difference is exactly what lock 3's
# `shipyard_absence_report` arm is for.
autodown_consider() {
  local slot="$1" iid="$2" state="$3" stage="$4" addr="$5" pending="$6"
  local prev_m prev_iid prev_n seen=1 sig out down_rc=0
  [ "$AUTODOWN" = 1 ] || return 1
  [ -n "$MERGEDFILE" ] || return 1
  # A slot name is a terminal name with `ship-` stripped (`shipyard_slots`), and nothing
  # validates it. One containing `/` reaches the locks and the removal target DIFFERENTLY: the
  # mailbox glob `$mb/$slot-*.json` is a flat-directory match and misses it, while `slot_stage`,
  # `slot_iid`, the worktree test below and `shipyard-down.sh`'s own `wt_of` all collapse the
  # path and resolve the VICTIM slot's real worktree. Measured on tmux, which accepts `ship-7/`
  # as a window name and lists it verbatim: slot `7/` was not held, and the teardown it would
  # have run targets slot `7`. Refusing here keeps the AUTOMATIC path away from a name it cannot
  # reason about. Validating slot names at the boundary would fix the manual path too — that is
  # #198, and it belongs there because it changes a function with other callers.
  case "$slot" in *"/"*) return 1 ;; esac
  # Lock 2 first, because it is a file read and lock 1's value costs a forge call on the
  # no-terminal path. Both are already in hand for a live slot, so the order costs nothing
  # there and saves a query per tick for every gone slot whose child never finished.
  case "$stage" in done|ready-to-merge) ;; *) return 1 ;; esac
  [ "$state" = merged ] || return 1
  [ -n "$iid" ] || return 1

  if [ -f "$MERGEDFILE" ]; then
    # FIELD-EXACT AND STRING-EXACT. `grep -F "$slot<TAB>"` matched this slot's name anywhere in
    # the row — rows are `slot<TAB>iid<TAB>seen`, so the tab follows the IID as well, and slot
    # `7` read slot `50`'s row whenever slot 50's PR number ended in `917`. The victim then
    # re-reads a foreign iid every tick, never accumulates past one, and is silently never torn
    # down. It self-heals once the colliding row leaves the file — except when that slot's own
    # teardown keeps being refused, which is the one case where nothing says so.
    #
    # The value travels through the ENVIRONMENT and both sides are forced to strings, because
    # `awk -v` is neither. `-v` processes escape sequences in the value, so a slot named `\062`
    # read slot `2`'s row; and a bare `$1==s` is a NUMERIC comparison when both sides look like
    # numbers, so `7` matched a row keyed `07`. Both measured. ENVIRON does no escape processing,
    # and `""` on each side forces the string compare the sentence above claims.
    prev_m=$(SLOT="$slot" awk -F'\t' '$1""==ENVIRON["SLOT"]""{print;exit}' "$MERGEDFILE" 2>/dev/null)
    prev_iid=$(printf '%s' "$prev_m" | cut -f2)
    prev_n=$(printf '%s' "$prev_m" | cut -f3)
    # The iid must MATCH, not merely exist. A slot number is reused across fleets and the
    # mailbox outlives a fleet, so a stale count under the same slot must not combine with one
    # fresh observation to tear a new child down on its first tick. The row this guards against
    # is one a SUCCESSFUL reap leaves behind — the append below happens before the teardown —
    # and it survives only across a gap in which no report ran for that slot at a merged and
    # terminal-staged read, because any later tick that reaches the write rewrites the file.
    case "${prev_n:-}" in
      ''|*[!0-9]*) ;;
      *) [ "$prev_iid" = "$iid" ] && seen=$(( prev_n + 1 )) ;;
    esac
  fi
  MERGED_ROWS+=("$slot	$iid	$seen")
  [ "$seen" -ge "$AUTODOWN_TICKS" ] || return 1

  # Lock 3. A live terminal must be IDLE; an absent one must be corroborated absent. Both
  # diagnostics are captured rather than printed: this whole report is buffered into one
  # block, and `shipyard_absence_report`'s rc-0 wording is written for a caller that did not
  # expect the absence.
  if [ -n "$addr" ]; then
    sig=$(drv_signal "ship-$slot" 2>/dev/null)
    case "$sig" in
      *'|idle') ;;
      *) return 1 ;;
    esac
  else
    shipyard_absence_report "$slot" >/dev/null 2>&1 || return 1
  fi

  # AN OPEN ESCALATION IS A HOLD, and it is passed in rather than read out of the caller's own
  # variables, which merely happen to be in scope at both call sites.
  #
  # Every other place in this file that asks whether a slot is idle — the wait classifier, the
  # stall clock, the sidebar badge and the in-flight test — treats a pending escalation as
  # "blocked on a human, do not conclude" — the stall clock exempts such a slot BECAUSE ITS
  # IDLENESS IS EXPECTED, and the in-flight test refuses to call the fleet drained over it. This
  # was very nearly the only one to get it wrong. Lock 3, just above, reads that same expected
  # idleness through `drv_signal` as "nobody is at the terminal" — so without this a
  # child that stopped to ask a question, and was then merged by the operator, is destroyed
  # BECAUSE it was waiting for them.
  #
  # Measured, on a rig driving this script: the same tick printed `🧹 TORN DOWN — terminal and
  # worktree removed` and, four lines below it, `Reply: shipyard-answer.sh <id> "<answer>"` for
  # the question it had just orphaned. And the reply does not fail loudly — `shipyard-answer.sh`
  # only falls back to `shipyard-tell.sh` for a notice, so for a pending QUESTION it exits 0 and
  # claims "the child session will pick it up within ~5s" about a session that no longer exists.
  #
  # The state is stable, not a race: `shipyard-ask.sh` leaves `status: pending` when it TIMES
  # OUT, the launcher tells the child in as many words to carry on past a `PENDING:` reply, and
  # nothing but an operator answering ever clears the record — ship's own plugin has no
  # reference to the mailbox at all, so its stage can reach `ready-to-merge` with a question
  # still open. (A `notice` also counts here, but the report's own tail closes notices each
  # tick, so that arm holds a slot for one tick at most.)
  #
  # PLACED LAST, after the count and after lock 3, and the position is load-bearing twice over.
  # It used to sit before the count, which meant a held slot appended no row and the
  # unconditional rewrite dropped its consecutive observations — so answering a question cost two
  # further ticks while the block promised the next one, and the block also fired for slots that
  # were not going to be torn down this tick at all, including a child that was visibly mid-turn.
  # Both measured. Here, HELD means every other condition is already satisfied and the answer is
  # the only thing outstanding, which is exactly what the block tells the operator.
  if [ "${pending:-0}" != 0 ]; then
    # Both counts, so the block can tell the operator which case they are in: `$pending` is the
    # fail-closed one and `$shown` is what the escalation block below will actually display. The
    # two ask different questions — any record not provably closed, versus a readable escalation
    # KIND whose status is `pending` — so they diverge for an unreadable record and would diverge
    # for an off-allow-list kind too, if anything wrote one under this stem today.
    REAP_HELD+=("$slot|$pending|$(slot_pending "$slot")")
    return 1
  fi

  # Lock 4, and the act. NO FLAGS, and never --force: shipyard-down.sh's gates are the gates.
  #
  # THE EXIT STATUS IS NOT THE ANSWER TO "WAS THIS SLOT TORN DOWN", so the worktree is asked
  # instead. shipyard-down.sh folds a FLEET-level result into its per-slot status: its tail
  # runs the last-slot continuity cleanup on every invocation and sets rc 1 when that cleanup
  # cannot verify the fleet is drained, or cannot stop a parent watcher — AFTER this slot's
  # terminal and worktree are already gone. That is not a blip-only path: the watcher case
  # needs no blip at all and arrives precisely on the LAST slot, which is the one this function
  # reaches. Reading the status alone printed `NOTHING was removed` one line under a quoted
  # `removed worktree …`, kept the slot in flight, and rendered its closed terminal as a live
  # row. The status is deliberately NOT changed in shipyard-down.sh: t7-continuity.sh pins that
  # exit-1-with-lifecycle-state-preserved as a contract.
  out=$(bash "$DIR/shipyard-down.sh" "$slot" 2>&1) || down_rc=$?
  if [ "$down_rc" = 0 ] || [ ! -d "$ROOT/.claude/worktrees/ship-$slot" ]; then
    # `!$iid` derived here rather than read out of the caller's $mr_label: this function is
    # reached from two places in the loop and a variable that happens to be in scope at both
    # is not a parameter.
    REAPED+=("$slot|!$iid|$seen|$down_rc")
    return 0
  fi
  REAP_REFUSED+=("$slot|$out")
  return 1
}

STALLED=()
STALL_ROWS=()
WAITING=()    # motionless for a stated, self-healing reason — nothing to do
ATTENTION=()  # motionless for a known reason that needs a person, but never compaction
UNSCALED=()   # "<slot>|<display>" — a ctx figure with no window to assert it against; the
              # display distinguishes the two causes, which take different remedies (Step 5)

# --- the supervision gap ---------------------------------------------------------------
# THE STALL CLOCK ONLY MEASURES WHAT THIS SCRIPT WATCHED. `since` is carried across runs in
# $STALLFILE, so the figure it yields is wall-clock time between two INVOCATIONS — not observed
# motionlessness. While the monitor ticks every ~10 min those are the same thing. They stop being
# the same thing the moment nobody is watching, and then the clock reports a number it cannot
# justify: an operator stopped a fleet for four days with both children deliberately left intact
# and idle, and the next run printed "motionless for 5420 min ... A child does not idle this long
# on its own" — ninety hours of which the script observed two instants.
#
# So: if this run is further from the previous one than the stall threshold itself, one tick could
# take a slot from zero to alarmed with no observation in between, which is exactly the untrustworthy
# case. Restart every clock and say so. Derived from $STALL_SECS rather than given a knob of its
# own, so it scales with whatever the threshold is set to and there is no second thing to tune.
#
# This is also the honest answer to an operator-initiated PAUSE, and it needs nothing from the pane:
# the parent's own absence is a parent-side fact, recorded here as it happens rather than re-derived
# afterwards from a child's screen.
RUN_EPOCH=$(date +%s)
GAP=0
if [ -n "$TICKFILE" ] && [ -f "$TICKFILE" ]; then
  prev_tick=$(cat "$TICKFILE" 2>/dev/null)
  case "${prev_tick:-}" in
    ''|*[!0-9]*) ;;   # unreadable or not an epoch: claim no gap rather than a wrong one
    *) if [ "$RUN_EPOCH" -gt "$prev_tick" ] && [ $(( RUN_EPOCH - prev_tick )) -gt "$STALL_SECS" ]; then
         GAP=$(( RUN_EPOCH - prev_tick ))
       fi ;;
  esac
fi
# The tick is stamped AFTER the loop, beside the stall table it must stay consistent with — see the
# write below. Stamping it here instead looks safer and is not: the clocks are rebased inside the
# loop and written after it, so a run interrupted part-way would CONSUME the gap without restarting
# anything, and the next run would print "motionless for 5420 min" with no gap notice — exactly the
# unjustified figure this mechanism exists to remove, now silent. The cost of stamping late is that
# a report which always dies mid-loop re-announces the gap every tick; that is noisy, honest, and
# true (nothing IS being watched), which is the right way round.

# Which forge origin points at. The report used to assume GitLab everywhere and ran
# `glab mr view` against a GitHub remote, where it fails silently — see mr_state().
forge() {
  case "$(git -C "$ROOT" remote get-url origin 2>/dev/null)" in
    *github.com*|*github-*) printf 'github' ;;
    *)                      printf 'gitlab' ;;
  esac
}

# Ask the FORGE which PR/MR has this slot's branch as its head. The fallback that needs no
# cooperation from the child, and the reason it exists: every source above is ship's own state
# file, and a child that writes one late — or not at all — leaves this column blank for exactly
# the part of the run where supervision matters. Measured (#124): a slot reading `no MR yet` over
# a PR that had been open for over an hour with two completed review rounds, and a second that
# wrote the file only once its PR already existed. The forge always knows; the child need not.
#
# It also unblocks the SLOT GRAPH, which is not obvious from here. shipyard-slot-graph.sh's first
# node completes on `_syg_pr_known`, so with no iid a slot can never leave `launched` — and its
# comment reasons that the divergence is unreachable "because ship records the PR number when it
# opens the PR", which is exactly the assumption #124 falsified. With the column blind, the
# `completed` glyph could never fire for any state-file-less child either.
#
# COST: one forge call per slot per tick, and only for a slot no state file could answer for.
# ORDER: last. Every cheaper source wins first — including GitLab's slot-is-the-iid rule, which is
# a heuristic rather than an exact answer (see slot_iid). This is a fallback, never a substitute.
slot_iid_forge() {
  local slot="$1" wt physical br v
  wt="$ROOT/.claude/worktrees/ship-$slot"
  [ -d "$wt" ] || return 0
  # A DIRECTORY IS NOT A WORKTREE, and the difference is a wrong answer rather than a blank. Git
  # discovery walks UP, so `rev-parse` inside a stray `.claude/worktrees/ship-*` — an interrupted
  # `worktree add`, a `remove` that failed on a dirty tree, or a bare `.pipeline-state/` — succeeds
  # and returns the SUPERVISOR's own branch. The supervisor is on a feature branch (AGENTS.md
  # forbids working on main), so the base-branch guard below cannot mask it and the slot would
  # render the supervisor's own PR, then take its `merged` as the child concluding. shipyard-down-
  # gate.sh records this same walk-up as measured; this is its registration check, the one
  # shipyard_agent_prepare_worktree already uses.
  physical=$(cd "$wt" 2>/dev/null && pwd -P) || return 0
  git -C "$ROOT" worktree list --porcelain | grep -Fqx "worktree $physical" || return 0
  br=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)
  # No branch, a detached HEAD (a child that has not branched yet), or the base branch itself:
  # there is no question to ask, and asking one about the base branch invites a wrong answer.
  case "$br" in ''|HEAD) return 0 ;; esac
  [ -n "$DEFAULT_BRANCH" ] && [ "$br" = "$DEFAULT_BRANCH" ] && return 0
  # BOTH arms ask the same question, and the two CLIs spell it differently in ways that are easy to
  # get backwards. Verified against the installed clients rather than reasoned about:
  #   * state — `gh` defaults to OPEN and takes `--state all`; `glab` also defaults to opened, and
  #     `-A/--all` is its opt-in (`glab mr list --help`, 1.90). Merged must be included or a merged
  #     change whose terminal is still up loses its number at the exact moment the graph needs
  #     `merged` to conclude — #124's own symptom, reintroduced.
  #   * count — `--limit 1` and `-P 1`. glab's per-page default is 30, i.e. 30 records fetched to
  #     read one integer.
  #   * cwd — both run inside the same subshell `cd "$ROOT"` as mr_state(), so each resolves the
  #     project from the remote rather than from wherever the monitor was started.
  #   * stderr — the redirect wraps the whole pipeline, jq included, so a non-JSON banner cannot
  #     put `parse error:` outside the single buffered block this report promises.
  if [ "$(forge)" = github ]; then
    v=$( (cd "$ROOT" 2>/dev/null && unset GITHUB_TOKEN \
      && gh pr list --head "$br" --state all --limit 1 --json number --jq '.[0].number // empty') 2>/dev/null)
  else
    v=$( (cd "$ROOT" 2>/dev/null \
      && OAUTH_TOKEN= glab mr list --source-branch "$br" --all -P 1 -F json | jq -r '.[0].iid // empty') 2>/dev/null)
  fi
  printf '%s' "$v"
}

# The MR/PR number for a slot, or empty when the change has not opened one yet.
#
# A NUMERIC SLOT IS NOT AUTOMATICALLY THE MR NUMBER. On GitHub `/shipyard` is normally started
# from an ISSUE, so the slot is an issue number and the PR does not exist yet and will get a
# DIFFERENT number. Returning the slot there labelled a live issue as a PR, and then the state
# lookup for that non-existent PR came back "?" — which mr_state()/inflight took for "finished",
# so the monitor declared the run over about a minute after it started.
#
# The GitLab arm below is a HEURISTIC, not the exception that proves the rule, and `#N` breaks it:
# shipyard-launch.sh maps both `!42` and `#42` to slot 42, and its own comment says `#N` is the
# issue form on GitLab too — so a `#N`-launched GitLab slot returns an ISSUE number here, exactly
# the GitHub defect above. It is left as it stands because narrowing it to the `!N` spelling is a
# behaviour change on a path nothing here tests (t15's rig is GitHub-only); filed rather than
# guessed at. Do not read the arm as exact.
#
# ONLY A NUMBER IS AN ANSWER, and that test lives HERE, at the single exit, rather than in the arm
# that happens to have prompted it. Every arm can yield junk: `.pr_number` is hand-authored JSON
# (§2.8 of ship now has a child write it at DISCOVERY, before any PR exists, so `"TBD"`/`"pending"`
# is a plausible value where the field used to be written by a run that already held the integer);
# `sed` passes non-matching input through, so an `MR-<slug>.json` basename returns the slug; and a
# CLI that is unauthenticated or pointed at the wrong forge can put prose on stdout. Any of those
# renders as `!<junk>`, makes mr_state() answer `?` forever, and — being non-empty — satisfies
# `_syg_pr_known`, advancing the graph for a slot that has no PR. Guarding one arm of four is the
# enumerable shape that comes back; guarding the exit also lets a junk state-file value fall
# THROUGH to the forge, which is the arm most likely to hold the real number.
slot_iid() {
  local slot="$1" sd f v=""
  sd="$ROOT/.claude/worktrees/ship-$slot/.pipeline-state"
  f=$(ls -1 "$sd"/*.json 2>/dev/null | tail -1)
  [ -n "$f" ] && v=$(jq -r '.pr_number // .pr // .iid // .mr_iid // empty' "$f" 2>/dev/null)
  case "$v" in ''|*[!0-9]*) v="" ;; *) printf '%s' "$v"; return ;; esac
  f=$(ls -1 "$sd"/MR-*.json 2>/dev/null | tail -1)
  [ -n "$f" ] && v=$(basename "$f" | sed -E 's/^MR-([0-9]+)\.json$/\1/')
  case "$v" in ''|*[!0-9]*) v="" ;; *) printf '%s' "$v"; return ;; esac
  # Only GitLab may fall back to the slot itself.
  if [[ "$slot" =~ ^[0-9]+$ ]] && [ "$(forge)" = gitlab ]; then printf '%s' "$slot"; return; fi
  v=$(slot_iid_forge "$slot")
  case "$v" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$v"
}

# opened | merged | closed | ? — normalised across both forges.
mr_state() {
  local iid="$1" st
  if [ "$(forge)" = github ]; then
    # In a SUBSHELL cd, so gh resolves the repo from the remote itself. Deriving
    # owner/name with sed here needed a non-greedy quantifier BSD sed does not have,
    # and it failed loudly on every call while still appearing to work.
    # GH_CONFIG_DIR is passed through only when the caller set it; with no default, gh uses
    # its own. A hardcoded default here pointed gh at a config dir that exists on exactly one
    # machine, so everywhere else gh ran unauthenticated, every state came back `?`, `?`
    # counts as in-flight below, and the monitor loop could never terminate.
    st=$( (cd "$ROOT" 2>/dev/null && unset GITHUB_TOKEN \
      && gh pr view "$iid" --json state --jq '.state') 2>/dev/null)
    case "$st" in
      OPEN) printf 'opened' ;; MERGED) printf 'merged' ;; CLOSED) printf 'closed' ;;
      *) printf '?' ;;
    esac
    return
  fi
  st=$(OAUTH_TOKEN= glab mr view "$iid" -F json 2>/dev/null | jq -r '.state // "?"')
  [ -z "$st" ] && st="?"
  printf '%s' "$st"
}

# Pipeline stage out of ship's state file (issue-ready / spec-review / apply / impl-review / ...).
slot_stage() {
  local slot="$1" sd f
  sd="$ROOT/.claude/worktrees/ship-$slot/.pipeline-state"
  f=$(ls -1 "$sd"/*.json 2>/dev/null | tail -1)
  [ -n "$f" ] && jq -r '.stage // .state // .phase // empty' "$f" 2>/dev/null
}

# Pending escalations for a slot (count).
slot_pending() {
  local slot="$1" mb n=0 f
  mb=$(shipyard_mailbox 2>/dev/null) || { printf 0; return; }
  [ -d "$mb" ] || { printf 0; return; }
  shopt -s nullglob
  for f in "$mb/$slot-"*.json; do
    # Same allow-list as shipyard-escalations.sh: only a real escalation kind counts, so a
    # `directive` (parent->child) or any future record type can never inflate this.
    [ "$(jq -r 'if (.kind|IN("question","decision","notice")) then (.status // "pending") else "" end' \
         "$f" 2>/dev/null)" = pending ] && n=$((n+1))
  done
  printf '%s' "$n"
}

# slot_unsettled <slot> — how many mailbox records for this slot are NOT provably closed.
#
# THIS IS A DIFFERENT QUESTION FROM slot_pending, and the difference is the whole point.
# `slot_pending` answers "how many open escalations should the esc column show", so it counts only
# a record it can READ, whose kind is on the escalation allow-list, and whose status is `pending`.
# Every one of those conditions is a way for a record to go uncounted — right for a column, wrong
# for a gate standing in front of `git worktree remove -f -f`.
#
# MEASURED: that filter run on a truncated or non-JSON record prints an empty string, so
# `slot_pending` reads 0. `shipyard-ask.sh` is what writes the record, so a child killed mid-write,
# or any corruption, leaves a question that is open in fact, invisible in the column, and unable to
# hold the teardown. AGENTS.md: untrusted evidence may annotate an operator-facing signal and never
# suppress one. The hold is such a signal, so this fails CLOSED — anything unreadable counts.
#
# WHAT IS PREVENTED here, and what is only NAMED. The rule asks for both, and for the two not to be
# blurred. PREVENTED: an unreadable record, an unknown kind, a missing status, and a mailbox
# directory that exists but cannot be read (see the `-r`/`-x` test — an earlier version of this
# list claimed that case and did not have it). NOT PREVENTED, deliberately or otherwise:
#   * FALSE evidence, as opposed to unreadable evidence. The mailbox is the child's own write
#     channel and nothing binds a record to the slot that wrote it, so a child writing
#     `status: done` on its own still-open record — or on a peer's — releases the hold with no
#     operator-visible trace. `shipyard-ask.sh` writes `done` on its normal path, so this is one
#     line of the child's own tool away. The hold fails closed on evidence it cannot READ, and
#     trusts evidence it can.
#   * a record keyed on a name this report never globs. The filename is `$(shipyard_slot)-N.json`
#     evaluated in the CHILD's cwd, and `SHIPYARD_SLOT` is scrubbed from the launch environment,
#     so a child that asks from outside its worktree writes `<repo-basename>-N.json`, which no
#     slot's glob matches. No hostility required.
#   * `answered` counts as settled, so a reply the operator has given but the child has not yet
#     consumed does not hold the teardown. Widening the lock to a state the operator has already
#     acted on is a separate change, not this one.
#   * a child that writes no record at all is indistinguishable from one with nothing to ask —
#     there is no evidence to fail closed on.
#   * the record stays INVISIBLE in the escalation view and in the esc column, which read it
#     through filters that skip what they cannot parse (#197). This function makes such a slot
#     survive and say so; it does not make the question answerable, and for a child that is not
#     merged and finished it changes nothing at all.
#   * the other locks also rest on child-written evidence (the pipeline stage, the PR number, the
#     screen). Those AUTHORISE a teardown rather than suppress a signal, which is the other half of
#     the rule; the content gate inside shipyard-down.sh is what stands behind them.
# That is the set of routes this function was checked against. Nothing here, and nothing in the
# gate, enforces that the set is complete.
# slot_unsettled_files <slot> — the paths slot_unsettled counted, one per line.
#
# Separate from the count rather than folded into it: the count is read in a condition and the
# paths are read in a render block, and a function that returns both through one string would be
# parsed by both callers. It re-walks the glob, which costs one extra pass over a handful of
# files and only for a slot that is actually held.
# BOTH VALUES IT PRINTS ARE WRITTEN BY THE CHILD, and this block is operator-facing text, so
# neither goes out raw. A filename may contain any byte but `/` and NUL, and `.status` is a JSON
# string, so both can carry newlines and control bytes. Measured before this was added: a crafted
# filename injected a whole forged `### 🧹 TORN DOWN` line while the header still said the slot
# was HELD, and a raw `ESC[2J ESC[H` plus CR erased the real block and the table above it. The
# review that found it also rendered a forged `AWAITING REMOVAL` whose "exact command" carried
# `--force` — which `shipyard-down.sh` accepts in any argv position and which overrides every
# gate. That is child-written evidence deciding whether the operator sees a signal, i.e. the rule
# this whole change is built on, in the function added to satisfy it.
#
# `%q` rather than a `tr` filter: it is bash 3.2 built-in, it renders a newline or ESC as
# `$'\n'` / `$'\033'` on ONE line, and what it prints stays paste-able. The basename is used
# because the directory is constant and is printed once in the block's own sentence.
slot_unsettled_files() {
  local slot="$1" mb f st
  mb=$(shipyard_mailbox 2>/dev/null) || return 0
  [ -d "$mb" ] || return 0
  { [ -r "$mb" ] && [ -x "$mb" ]; } || { printf '%q (unreadable mailbox directory)\n' "$mb"; return 0; }
  shopt -s nullglob
  for f in "$mb/$slot-"*.json; do
    st=$(jq -r '.status // "pending"' "$f" 2>/dev/null) || st=""
    case "$st" in
      done|answered) ;;
      '')            printf '%q (unreadable — cannot be answered)\n' "${f##*/}" ;;
      *)             printf '%q (%q)\n' "${f##*/}" "$st" ;;
    esac
  done
}

slot_unsettled() {
  local slot="$1" mb n=0 f st
  # Cannot ask at all -> 1, never 0. An unanswerable question must not read as "nothing is
  # owed": that is the confident-negative shape #139 is about, one level up.
  #
  # HONEST SCOPE of this first arm: it fires only for a `git rev-parse --git-common-dir` failure
  # that appears MID-RUN. If the mailbox is unresolvable when the run starts, `$MERGEDFILE` is
  # empty too and `autodown_consider` returns before it ever reads this count — measured: no
  # teardown and no hold, because nothing was asked. The arm is kept for the mid-run case and
  # because a fail-closed default is the right shape here, not because it covers what an earlier
  # version of this comment claimed.
  mb=$(shipyard_mailbox 2>/dev/null) || { printf 1; return; }
  [ -d "$mb" ] || { printf 0; return; }
  # THE ONE THAT ACTUALLY FIRES, and the one this function shipped without. A directory that
  # exists but cannot be read passes `-d`, and bash's glob over it then yields NO MATCHES
  # SILENTLY — nullglob removes the word and the count stays 0 while a pending record sits
  # inside, still reachable by name. The count reads 0 at modes 000, 111 and 311 (measured under
  # bash 5 and /bin/bash 3.2), but only ONE of those actually ends in a teardown, and the
  # difference is worth stating because the other two look like evidence and are not: at 000 the
  # counter file cannot be read and at 111 it cannot be written, so in both the consecutive count
  # never reaches its threshold and something other than this guard stops the removal. The
  # exhibiting mode is 311 — writable and traversable, not listable — where `report-merged` keeps
  # working by name and the slot really is torn down with its question open. t17's B18 uses 311
  # for exactly that reason.
  { [ -r "$mb" ] && [ -x "$mb" ]; } || { printf 1; return; }
  shopt -s nullglob
  for f in "$mb/$slot-"*.json; do
    st=$(jq -r '.status // "pending"' "$f" 2>/dev/null) || st=""
    case "$st" in
      done|answered) ;;
      *)             n=$((n+1)) ;;
    esac
  done
  printf '%s' "$n"
}

# The turn marker is interpolated rather than written out: shared/adapters is the one place it is
# spelled, so a client renaming it does not leave this column quietly printing a footer line as if
# it were the child's last word.
#
# It gets its OWN fixed-string stage rather than joining the alternation below. The constant exists
# to be edited when a client renames the marker, and a value carrying a regex metacharacter would
# either change this filter's meaning or make the expression invalid — and an invalid one blanks
# the `last line` column for every slot with no error anyone sees. Every other alternative keeps
# its original quoting byte for byte.
status_line() {
  grep -vF -- "$ADP_TURN_MARKER" \
    | grep -vE '^[[:space:]]*$|──|❯|tokens$|shift\+tab|current: [0-9]|scroll with|tmux detected|Tip:' \
    | grep -iE '✻|✽|·|agents done|Cogitated|Waddling|Whirlpool|ship|propose|spec|apply|archive|merg|approv|pipeline|await|waiting|escalat|ready|pushed|done' \
    | tail -1 | sed -E 's/^[[:space:]]*//; s/[[:space:]]+$//'
}

if [ ${#SLOTS[@]} -eq 0 ]; then
  # The FIRST of the two exits this script has, and the one the incident came through: discovery
  # mode found no terminals. Whether that ends the watch is shipyard_signal_class's call, not the
  # emptiness's own. ENUM_RC is the status of the enumeration this branch is acting on.
  NOSIG=""; NOSIG_RC=0
  NOSIG=$(shipyard_signal_class "$ENUM_RC") || NOSIG_RC=$?
  {
    echo "### ship status — $(date '+%H:%M:%S %Z')"
    echo
    if [ "$NOSIG_RC" = 0 ]; then
      echo "_no live ship terminals in $KIND \`$CONTAINER\` ($(shipyard_backend))_"
    else
      no_signal_block "${NOSIG%%$TAB*}" "${NOSIG#*$TAB}"
    fi
  } | cat
  # A guard clause, so the ordinary empty report still leaves on a bare `exit 0` — t7-continuity.sh
  # anchors on that line to prove this branch returns before shipyard_continuity_start below can
  # re-arm a watcher for a fleet that has just drained.
  if [ "$NOSIG_RC" != 0 ]; then exit 1; fi
  exit 0
fi

# Re-arm only while the report has work to supervise. Doing this before the
# empty report would recreate a watcher immediately after last-slot cleanup.
if ! shipyard_continuity_start "$KIND"; then
  echo "warning: could not ensure the Codex parent continuity guard" >&2
fi

declare -a ROWS
declare -a SIG
inflight=0
total_pend=0
total_unsettled=0   # the wider count the teardown hold uses; see the terminal test
GONE=""      # slots this tick rendered `⛔ no terminal`; consulted by the tail's re-ask

# ONCE, HERE, IN THIS SHELL — never from inside the loop below. The per-slot ctx call is
# $(ctx_probe ...), which nests $(ctx_window ...): a warning raised down there fires once per
# slot and cannot be suppressed from within, because the flag that would suppress it dies with
# its own subshell. That is measured, not feared.
#
# What this buys is one line per TICK instead of one per SLOT. Be honest about what it does not
# buy: this still runs before --only-changed decides whether to print, so a typo'd override puts
# one stderr line on a tick that is documented as silent. Moving the call below that decision
# would restore the silence and cost the validation on exactly the ticks nobody is watching,
# which is the worse trade. t2-window.sh pins this call site, above the loop, for both reasons.
ctx_check_env

for slot in "${SLOTS[@]}"; do
  [ -z "$slot" ] && continue
  addr=$(shipyard_slot_addr "$slot")
  iid=$(slot_iid "$slot")
  mr_label="—"; [ -n "$iid" ] && mr_label="!$iid"
  pend=$(slot_pending "$slot")
  # The esc COLUMN's count and the teardown's HOLD are different questions and are read from
  # different functions on purpose — see slot_unsettled. A record this report cannot parse raises
  # the second and not the first, so `esc —` beside a held slot is correct rather than a
  # contradiction; the HELD block says so in words.
  unsettled=$(slot_unsettled "$slot")
  esc="—"; [ "$pend" != 0 ] && esc="⚠️ $pend"
  total_pend=$((total_pend+pend))
  total_unsettled=$((total_unsettled+unsettled))

  if [ -z "$addr" ]; then
    # A slot with no terminal but a worktree still on disk is the shape that ACCUMULATES: it
    # is not enumerated in discovery mode, so only a named-slot monitor ever sees it again.
    # Ask the locks about it before writing it off — the answer is the same teardown,
    # and lock 3 takes its absence arm here rather than its idle one. The stage is read first
    # and the forge only if it is terminal, so a gone slot whose child never finished costs no
    # query. The row itself is unchanged: this branch reports a missing terminal, and saying
    # more about a slot the backend could not resolve is what #139 is about.
    gone_stage=$(slot_stage "$slot"); [ -z "$gone_stage" ] && gone_stage="—"
    gone_note=""; gone_before=${#REAP_REFUSED[@]}; gone_held=${#REAP_HELD[@]}
    case "$gone_stage" in
      done|ready-to-merge)
        gone_state="no MR yet"
        [ -n "$iid" ] && gone_state=$(mr_state "$iid")
        if autodown_consider "$slot" "$iid" "$gone_state" "$gone_stage" "" "$unsettled"; then
          ROWS+=("| $slot | $mr_label | — | 🧹 torn down | $gone_state / $gone_stage | $esc | — | terminal and worktree removed |")
          SIG+=("$slot|$mr_label|term=0|$gone_state|$gone_stage|$pend|reaped")
          continue
        fi
        # THE REFUSAL MUST REACH THE SIGNATURE ON THIS ARM TOO. It did not, and the live arm's
        # marker hid how much that cost: this branch's SIG line is a fixed literal, so a refused
        # teardown left it byte-identical tick after tick, `--only-changed` — which is what the
        # documented monitor loop passes — suppressed the whole report, and the ✋ AWAITING
        # REMOVAL block never printed while the destructive call was retried every tick.
        # Measured before the fix: three invocations, zero bytes of output. It surfaced only on
        # the tick the whole fleet drained, and never at all on a fleet that keeps being topped
        # up — on precisely the arm this block calls the shape that ACCUMULATES.
        [ "${#REAP_REFUSED[@]}" -gt "$gone_before" ] && gone_note="reap-refused"
        [ "${#REAP_HELD[@]}" -gt "$gone_held" ] && gone_note="reap-held" ;;
    esac
    ROWS+=("| $slot | $mr_label | — | ⛔ no terminal | — | $esc | — | — |")
    SIG+=("$slot|$mr_label|term=0|—|—|$pend|$gone_note")
    # Remember WHICH slots this tick concluded were gone. The tail re-asks the backend before it
    # may stop the loop, and the only honest reading of "still enumerated, but I rendered it gone"
    # is that the lookup failed, not that the child ended.
    GONE="$GONE $slot"
    continue
  fi

  a=$(shipyard_capture "$slot")
  sleep "$MOTION_INTERVAL"
  b=$(shipyard_capture "$slot")
  [ "$a" = "$b" ] && run="⏸ idle/wait" || run="▶️ running"

  line=$(printf '%s\n' "$b" | status_line)
  [ -z "$line" ] && line="—"
  line=$(printf '%s' "$line" | cut -c1-55)

  stage=$(slot_stage "$slot"); [ -z "$stage" ] && stage="—"

  if [ -n "$iid" ]; then
    state=$(mr_state "$iid")
  else
    state="no MR yet"
  fi

  # The slot's supervision phase and glyph verdict, from the DECLARED graph (shipyard-slot-graph.sh)
  # evaluated by the shared flow guard — the single authority for "which phase is this slot in / is
  # it terminal" (FLOW-03), replacing the scattered forge-state/stage tests that used to decide the
  # verdict and the in-flight count here. A subprocess, because this script must stay bash-3.2-clean
  # (t7) while the guard needs bash >= 5; it is spawned only here, for a LIVE slot, never on the
  # no-terminal path that exits above. The facts it reads are the ones already resolved just above,
  # so it adds no forge call.
  read -r phase verdict <<<"$(bash "$DIR/shipyard-slot-graph.sh" slot "$iid" "$state" "$stage" "$addr")"
  # Fail-safe if the graph could not answer: it fails loudly with EMPTY stdout (a missing bash 5, or
  # an unloadable flow.sh — it never emits a misleading phase), so an empty verdict defaults to
  # `active` (never falsely `completed`) and the empty phase is not `torn-down`, so the slot is still
  # counted in flight below (never dropped).
  [ -n "$verdict" ] || verdict=active

  # --- a merged slot tears itself down (#181) --------------------------------
  # Placed HERE, before the in-flight count and before the ctx/stall work: a slot this tick
  # removes is not in flight, and asking a closed terminal how motionless it was is a question
  # about a window that no longer exists. The locks live in autodown_consider.
  #
  # Cleared every iteration, not just assigned: these are plain shell variables in one long
  # loop, so a value left over from the previous slot would otherwise decide this one's row.
  reap_note=""; before_refused=${#REAP_REFUSED[@]}; before_held=${#REAP_HELD[@]}
  if autodown_consider "$slot" "$iid" "$state" "$stage" "$addr" "$unsettled"; then
    # The row says what happened to a terminal that WAS live when this tick began, so the
    # teardown is never silent, and the SIG carries `term=0` — a teardown is news, and it is
    # the one thing --only-changed must not swallow.
    ROWS+=("| $slot | $mr_label | $addr | 🧹 torn down | $state / $stage | $esc | — | terminal and worktree removed |")
    SIG+=("$slot|$mr_label|term=0|$state|$stage|$pend|reaped")
    continue
  fi
  # Refused: the gate said no, or the absence could not be corroborated. The count is kept so
  # the next tick retries — a dirty worktree gets committed, a blip passes — and the reason
  # goes into the SIG so that the tick a refusal CLEARS is news too. The block itself no longer
  # depends on the signature: a refused or held slot bypasses --only-changed outright, so it is
  # printed on every tick the condition lasts (see the bypass block).
  [ "${#REAP_REFUSED[@]}" -gt "$before_refused" ] && reap_note="reap-refused"
  [ "${#REAP_HELD[@]}" -gt "$before_held" ] && reap_note="reap-held"

  # `?` counts as IN FLIGHT, never as finished. The window is alive and the pane is
  # moving; an unresolvable state means the lookup failed, not that the work ended.
  # Treating it as terminal is what stopped a monitor 60 seconds into a fresh run.
  # A LIVE TERMINAL IS IN FLIGHT, whatever the forge says. `merged` means one MR
  # ended, not that the child did. THE EXAMPLE THIS USED TO GIVE — a ship session that
  # lands a spec change and then outlives its first MR — COULD NOT BE ESTABLISHED
  # against the ship in this repo, and is left out rather than repeated: that skill's
  # own synopsis says "one branch + one PR/MR per change", §7.B opens a single PR/MR
  # for the whole change, §7.F folds the archive into the SAME one, and AGENTS.md's law
  # is "one issue, one branch, one pull request". What the rule actually rests on is
  # narrower and still true: a merged child is not a finished one — it is still
  # posting its record, answering a comment, or writing its state file — and the stage
  # it reports is what says otherwise (autodown_consider's lock 2 reads exactly that).
  # Counting only the MR state here reported "nothing in flight — monitor stopped" over a child
  # that was mid implementation, and took the STALL detector down with it, so the
  # supervisor got two green signals while the session sat with an unsubmitted line
  # in its box. Teardown is the supervisor's act; the absence of a terminal is the
  # honest end signal — but only once CORROBORATED, which is the shipyard_signal_class block
  # above: an absence nobody could verify is not an end signal at all, and reading it
  # as one is #61. (A dead terminal never reaches here — it `continue`s above — so
  # this counts live sessions only, and the monitor still exits once every terminal
  # is gone AND the backend confirmed it.)
  #
  # The graph expresses exactly this rule: a live slot is at launched|in-review|concluded, never the
  # empty `torn-down` phase (an absent terminal `continue`d above), so this counts every live
  # terminal as before — now derived from the graph's phase. An empty/unreadable phase is counted in
  # flight, never dropped, so the guard can inform the loop but can never end it early.
  [ "$phase" = torn-down ] || inflight=$((inflight+1))

  read -r ctx_pct ctx <<<"$(ctx_probe "$slot" "$b")"
  band=$(ctx_band "$ctx_pct")
  # `unknown` gets a glyph of its own and is collected below. It must never read as healthy:
  # it is the one band where the report is holding a number it cannot scale, so an unmarked
  # row would be the silent-blind column this whole file was rewritten to remove.
  case "$band" in
    warn)    ctx="⚠️ $ctx" ;;
    crit)    ctx="🛑 $ctx" ;;
    # The DISPLAY is carried alongside the slot, not just the slot: the block below tells the two
    # `?` causes apart by whether ctx_probe printed a `<=` bound or a bare count, because their
    # remedies differ. A parallel associative array would be the obvious way and is bash 4+; this
    # file is sourced into a bash-3.2 floor, so it uses the same `|`-joined entry shape ATTENTION
    # does. Captured before the glyph is prefixed, so the test is over ctx_probe's own output.
    unknown) UNSCALED+=("$slot|$ctx"); ctx="❓ $ctx" ;;
  esac

  # --- WHY is it not moving? asked BEFORE the clock is consulted ---------------
  # The watchdog below measures motionlessness and concludes death. Two of the three things that
  # make a healthy child motionless are not death at all: it CANNOT move (a stated capacity wait),
  # or nobody ASKED it to (it is finished, or blocked on a human). Both used to reach the same
  # alarm and the same prescription, whose last step is compaction — discarding live context to
  # cure a condition the child does not have. So classify first; only what has no known reason is
  # STUCK, and that still gets the loud block, unchanged.
  #
  # Only ever asked of a MOTIONLESS child. On a moving one any banner still on screen is history by
  # definition, and reading it would park a child that is working.
  #
  # The knowledge is not local: shipyard_wait_state joins the declared graph's phase, the shared
  # adapters' per-kind banner shapes and the shared policy's disposition. See shipyard-lib.sh.
  # Cleared every iteration, not just assigned: these are plain shell variables in one long loop,
  # so a value left over from the previous slot would otherwise decide this one's row.
  wait_kind=""; wait_class=""; wait_label=""; wait_action=""; wait_line=""
  # `$pend = 0` for the same reason the stall condition below carries it: a slot with an open
  # escalation is already accounted for by the esc column and the escalation block, and it is
  # asking for something. Without this guard such a slot could be printed under "a stated,
  # self-healing wait ... Do not nudge" while a child is in fact blocked on an unanswered question.
  if [ "$run" = "⏸ idle/wait" ] && [ "$pend" = 0 ]; then
    wait_line=$(shipyard_wait_state "$b" "$phase" "$stage" 2>/dev/null) || wait_line=""
    if [ -n "$wait_line" ]; then
      wait_kind=$(printf '%s' "$wait_line" | cut -f1)
      wait_class=$(printf '%s' "$wait_line" | cut -f2)
      wait_label=$(printf '%s' "$wait_line" | cut -f3)
      wait_action=$(printf '%s' "$wait_line" | cut -f4)
      run="$wait_label"
    fi
  fi

  # --- stall detection -------------------------------------------------------
  # The silence of --only-changed is indistinguishable from death: a child that has
  # hit its context ceiling, that was compacted and never told to resume, or that left
  # its own next instruction unsubmitted in the input box sits
  # ⏸ idle with esc — and NOTHING changes, so the monitor says nothing. One ran that
  # way for 8.5 hours. So track how long each slot has been motionless and shout
  # when it crosses the threshold, bypassing --only-changed entirely.
  slot_sig="$state|$stage|$pend|$(printf '%s' "$b" | md5 -q 2>/dev/null || printf '%s' "$b" | md5sum | cut -d" " -f1)"
  now_epoch=$(date +%s)
  since=""
  if [ -n "$STALLFILE" ] && [ -f "$STALLFILE" ]; then
    prev=$(grep -F "$slot	" "$STALLFILE" 2>/dev/null | head -1)
    prev_sig=$(printf '%s' "$prev" | cut -f2)
    prev_epoch=$(printf '%s' "$prev" | cut -f3)
    [ "$prev_sig" = "$slot_sig" ] && since="$prev_epoch"
  fi
  [ -z "$since" ] && since="$now_epoch"
  # Restart the clock rather than carry a figure nothing observed (see the supervision gap above),
  # and while a stated wait is in effect, so the timer never accumulates minutes that were never
  # idle in the sense the alarm means. Both rebase `since`, so the figure the NEXT tick reports is
  # measured from an instant this script was actually watching.
  { [ "$GAP" != 0 ] || [ -n "$wait_kind" ]; } && since="$now_epoch"
  STALL_ROWS+=("$slot	$slot_sig	$since")
  motionless=$(( now_epoch - since ))
  stalled_now=0
  if [ -n "$wait_kind" ]; then
    # Motionless for a reason it told us. Not a stall, and never a compaction candidate.
    case "$wait_kind" in
      wait) WAITING+=("$slot|$wait_class|$ctx|$wait_action") ;;
      *)    ATTENTION+=("$slot|$wait_class|$ctx|$wait_action") ;;
    esac
  elif [ "$run" = "⏸ idle/wait" ] && [ "$pend" = 0 ] && [ "$motionless" -ge "$STALL_SECS" ]; then
    STALLED+=("$slot|$((motionless/60))|$ctx")
    stalled_now=1
  fi

  # Paint the same verdict on the sidebar glyph (agterm only; a no-op on tmux), so the
  # board is readable without reading the table: blocked = it is waiting on YOU. The
  # completed-vs-active verdict is the declared graph's (via shipyard-slot-graph.sh) — the
  # single authority for a slot's phase (FLOW-03) — while the escalation and stall overlays
  # below still take precedence over it, exactly as before.
  # ONLY `needs_human` overrides the graph's verdict. A `finished` slot must keep the graph's
  # `completed` glyph: FLOW-03 states outright that `_syg_concluded` "reproduces shipyard-report.sh's
  # old completed verdict EXACTLY ... so the glyph does not change", and painting it `blocked` from
  # its first idle tick would break that — the old code only reached `blocked` after 30 motionless
  # minutes, which is not the same claim. A `wait` slot wants nobody, so it falls through too.
  if   [ "$pend" != 0 ];             then shipyard_note "$slot" blocked --blink
  elif [ "$wait_class" = needs_human ]; then shipyard_note "$slot" blocked
  elif [ "$stalled_now" = 1 ];        then shipyard_note "$slot" blocked
  else                                    shipyard_note "$slot" "$verdict"
  fi

  ROWS+=("| $slot | $mr_label | $addr | $run | $state / $stage | $esc | $ctx | ${line} |")
  # No $run and no $line here on purpose — see the --only-changed note in the header. $wait_class
  # IS meaningful: entering or leaving a stated wait is exactly the tick worth breaking silence
  # for, and it is the news the first time it appears, which is why it is not left to the (now
  # suppressed) stall block to announce.
  SIG+=("$slot|$mr_label|term=1|$state|$stage|$pend|$band|$wait_class|$reap_note")
  :
done

[ -n "$STALLFILE" ] && [ "${#STALL_ROWS[@]}" -gt 0 ] && printf '%s\n' "${STALL_ROWS[@]}" >"$STALLFILE" 2>/dev/null
# ON EVERY TICK THAT REACHES HERE, unlike the stall table above, and that difference is the
# whole of "consecutive". (Not literally every tick: the discovery-mode early exit above,
# taken when the backend enumerated no slots at all, returns before this write and so
# preserves the counts. Both merged reads either side of such a tick are still genuine forge
# reads, so the gap is deliberate rather than overlooked.) The stall table is preserved when empty so a clock survives a tick that
# rendered no rows; this one must be TRUNCATED then, or a slot that read `merged`, then `?`,
# then `merged` would carry its first count across the gap and fire on two readings that were
# never consecutive — which is precisely the flickering-forge sequence (#142) the
# consecutive-observation requirement exists to refuse. Written with `:>` first so an empty array still empties the file.
#
# The consequence, stated rather than left to be discovered: this run replaces the whole file,
# so an ad-hoc `shipyard-report.sh <one-slot>` run beside a monitor resets the counts of the
# slots it did not visit — the same wholesale replacement the stall table above already does.
# It costs one tick of delay and it errs towards not closing a terminal, which is the side of
# the trade this mechanism should fail on.
if [ -n "$MERGEDFILE" ]; then
  : >"$MERGEDFILE" 2>/dev/null
  [ "${#MERGED_ROWS[@]}" -gt 0 ] && printf '%s\n' "${MERGED_ROWS[@]}" >"$MERGEDFILE" 2>/dev/null
fi
# Together with the stall table, never before it: a gap may only be consumed by a run that actually
# restarted the clocks (see the supervision-gap block above).
[ -n "$TICKFILE" ] && printf '%s\n' "$RUN_EPOCH" >"$TICKFILE" 2>/dev/null

TERMINAL=0
# `$total_pend` AND `$total_unsettled`, because the two answer the same question from different
# sources and the teardown uses the wider one. `total_pend` comes from `slot_pending`, which
# cannot see a record it fails to parse; a slot held by exactly such a record would otherwise let
# the run declare the fleet drained WHILE holding it — measured: the tick printed "nothing in
# flight (all merged/closed) — monitor stopped" directly above a HELD block promising a next tick
# that would never come, and exited 0. A parseable pending question kept the loop alive on the
# same fixture, so the two counts disagreed precisely where it mattered.
#
# IT IS `$total_unsettled` AND NOT `${#REAP_HELD[@]}`, and that correction is the whole of this
# paragraph's second life. The first version tested the HELD array, which is only populated once
# `autodown_consider` has passed the consecutive-tick gate and lock 3 — so on the FIRST merged
# tick, and whenever `$AUTODOWN` is 0, the array is empty and the run stopped anyway. Measured: a
# gone slot with an unreadable record printed `monitor stopped` on tick 1 with no HELD block at
# all, which was worse than before the hold existed. `$total_unsettled` is summed for every slot
# in the loop above, before any of those gates, so it holds on tick 1 and with the teardown
# disabled.
#
# This can keep a monitor running indefinitely over an unclearable hold, which is why it is not
# the whole fix: the HELD block names the records holding the slot so the operator can clear one.
[ "$inflight" -eq 0 ] && [ "$total_pend" -eq 0 ] && [ "$total_unsettled" -eq 0 ] && TERMINAL=1

# The SECOND exit, and it needs the same corroboration for the same reason. Named slots do not
# reach the discovery branch above, so `shipyard-report.sh --only-changed 22 61` against a backend
# that cannot answer renders every row as `⛔ no terminal`, counts nothing in flight, and lands
# here — an identical false completion by a different route.
#
# What is deliberately NOT treated as an anomaly: named slots that are all gone. The Step 2 loop is
# armed once with a fixed slot list and the supervisor tears children down one at a time, so the
# last teardown leaving zero terminals IS the designed end of a run. "Slots were named, therefore
# finding none is suspicious" would make that termination unreachable and every finished fleet
# would monitor itself forever. Teardown and unreachability are told apart by the backend having
# ANSWERED, which is what shipyard_signal_class asks.
NOSIG=""; NOSIG_RC=0
if [ "$TERMINAL" = 1 ]; then
  # RE-ASK, rather than trust the sample taken before the loop. The row loop is the slow part of a
  # tick — a 3s motion diff per live slot, plus a forge call and a graph subprocess — so a backend
  # that answers the enumeration and dies a second later leaves the pre-loop ENUM_RC stale and
  # reassuring. Measured: a socket that served the first query and failed afterwards enumerated
  # `ship-41`, rendered it `⛔ no terminal` when the addr lookup failed, counted nothing in flight,
  # and exited 0 with "monitor stopped" — #61's exact symptom on a tick that had just seen a live
  # slot. The window this closes is far larger than the one the pre-loop sample covers, and one
  # extra enumeration is charged only on the tick that would otherwise END supervision.
  ENUM_RC=0
  RECHECK=$(shipyard_slots 2>/dev/null) || ENUM_RC=$?
  # The RE-checked rc, passed explicitly: this late test must classify the enumeration it just
  # took, which is the whole point of taking a second one here.
  NOSIG=$(shipyard_signal_class "$ENUM_RC") || NOSIG_RC=$?
  [ "$NOSIG_RC" = 0 ] || TERMINAL=0
  # KEEP THE ANSWER, not just the status. A blip that fails the row loop's lookups and recovers
  # before this point returns rc 0 — corroborated — while listing the very slot the tick has just
  # rendered `⛔ no terminal`. Reproduced: a fake failing only the middle call printed "monitor
  # stopped" and exited 0 over a live child. The contradiction is the evidence, and it costs
  # nothing extra: the list is already in hand.
  #
  # It is matched per slot, NOT by asking whether the list is non-empty. With named slots an
  # unrelated `ship-*` terminal in the same container would satisfy a bare emptiness test and block
  # the designed termination forever — the opposite-direction bug this change keeps having to
  # defend against.
  if [ "$TERMINAL" = 1 ] && [ -n "$GONE" ] && [ -n "$RECHECK" ]; then
    for g in $GONE; do
      case "
$RECHECK
" in
        *"
$g
"*) TERMINAL=0
            NOSIG_RC=9
            NOSIG="unreachable${TAB}slot $g is still listed by the backend, but its terminal could not be resolved while this tick was building the table"
            break ;;
      esac
    done
  fi
fi

# --only-changed: stay silent unless the meaningful state moved. A terminal report is
# always printed so the end of the run is never swallowed — and so is a tick that could not tell,
# which would otherwise be the quietest possible way to say the loudest thing (the STALLED
# precedent: a block that bypasses the filter, because silence is what made the bug invisible).
# `$PINNED_ELSEWHERE` is in the condition rather than in the signature: a disagreement is news on
# EVERY tick it holds, not once. Left to the signature it would be announced the first time and
# then suppressed for as long as it lasted, which is the one tick shape the report is supposed to
# be loudest about — the header line is the only trace the incident left behind.
# A REAPED, HELD or REFUSED slot bypasses the silence outright, like STALLED above and for the
# same reason: each is a state where a destructive act has just happened, or is being attempted
# and declined every tick, and where the operator owes an action nobody else can take. Leaving
# them to the signature made them news EXACTLY ONCE — and AGENTS.md now forbids letting state the
# supervised party writes decide whether an operator-facing signal appears at all, which a
# per-slot signature partly is ($SIGFILE lives in the shared mailbox every child writes into).
#
# REAPED is here for the strongest version of that argument and was missing from the first
# attempt: it reports an act that has ALREADY closed a terminal and removed a worktree. On the
# natural path a reap always moves the signature, so this changes nothing there; what it removes
# is the forged-file route, where a child writes the predicted post-reap signature and the
# teardown then happens with zero bytes printed.
#
# The cost is a repeated block for as long as the condition lasts; that is the STALLED trade,
# taken knowingly, and neither held nor refused is the normal case. Worth knowing before taking
# it again: #182 is open against exactly this trade on this supervisor — a stall alarm that
# repeats verbatim trains the operator to skim it — so if that lands, these blocks should move to
# whatever de-duplication it introduces rather than keep a second precedent alive.
#
# NOT closed by any of this: an ad-hoc `shipyard-report.sh --only-changed <slot>` run beside the
# monitor performs the teardown and consumes the only 🧹 block, leaving the monitor to show a
# table the slot has merely vanished from. The same hazard is documented for $MERGEDFILE above.
if [ "$ONLY_CHANGED" = 1 ] && [ "$TERMINAL" = 0 ] && [ "${#STALLED[@]}" -eq 0 ] \
   && [ "${#REAP_HELD[@]}" -eq 0 ] && [ "${#REAP_REFUSED[@]}" -eq 0 ] \
   && [ "${#REAPED[@]}" -eq 0 ] \
   && [ "$NOSIG_RC" = 0 ] && [ -z "$PINNED_ELSEWHERE" ] && [ "$GAP" = 0 ] && [ -n "$SIGFILE" ]; then
  NOW_SIG=$(printf '%s\n' "${SIG[@]}")
  if [ -f "$SIGFILE" ] && [ "$NOW_SIG" = "$(cat "$SIGFILE" 2>/dev/null)" ]; then
    exit 1   # still in flight, just nothing new to say
  fi
  printf '%s\n' "$NOW_SIG" >"$SIGFILE" 2>/dev/null
elif [ -n "$SIGFILE" ]; then
  printf '%s\n' "${SIG[@]}" >"$SIGFILE" 2>/dev/null
fi

{
  echo "### ship status — $(date '+%H:%M:%S %Z') · $(shipyard_backend) $KIND \`$CONTAINER\`"
  # Say WHICH backend answered whenever it is not the one the fleet was launched on, on every such
  # tick and not only on the ones that refuse to exit. In the incident the header was the sole
  # visible trace that anything had moved — it stopped naming an agterm workspace and started
  # naming a tmux session — and nobody reads a header for a word that is normally constant.
  [ -n "$PINNED_ELSEWHERE" ] && \
    echo "⚠️ resolved \`$(shipyard_backend)\`, but this fleet was launched on \`$PINNED_ELSEWHERE\` — this table may be looking in the wrong place."
  echo
  echo "| slot | MR | term | session | MR state / stage | esc | ctx | last line |"
  echo "|------|----|------|---------|------------------|-----|-----|-----------|"
  for r in "${ROWS[@]}"; do echo "$r"; done
  echo
  # $TERMINAL, not the two counts it was computed from: they are also 0 when the backend could not
  # be asked, and printing "monitor stopped" there is the sentence the operator was left with while
  # two children went on working.
  if [ "$TERMINAL" = 1 ]; then
    echo "_nothing in flight (all merged/closed) — monitor stopped_"
  elif [ "$NOSIG_RC" != 0 ]; then
    echo "_cannot tell what is in flight — see below; the monitor keeps running_"
  else
    echo "_in flight: ${inflight}; open escalations: ${total_pend}_"
  fi
  if [ "$NOSIG_RC" != 0 ]; then
    echo
    no_signal_block "${NOSIG%%$TAB*}" "${NOSIG#*$TAB}"
  fi
  if [ "$GAP" != 0 ]; then
    echo
    echo "_supervision resumed after $((GAP/60)) min with nothing watching — every stall clock was"
    echo "restarted from now, because a figure measured across that gap is one this report cannot"
    echo "justify. If the fleet was paused on purpose, this line is the whole of the news._"
  fi
  if [ "${#STALLED[@]}" -gt 0 ]; then
    echo
    echo "### 🛑 STALLED — idle, nothing asked of you, and nothing moving"
    for x in "${STALLED[@]}"; do
      sl=${x%%|*}; rest=${x#*|}; mins=${rest%%|*}; c=${rest#*|}
      # NOT "a child does not idle this long on its own" any more. That sentence was this block's
      # stated justification and it was the one assumption that failed: a child idles exactly that
      # long when it cannot move, or when nobody asked it to. Both now leave before here, so what
      # this line may claim is what the classification actually ruled out — and no more, since the
      # reason could still be one the classifier has no shape for.
      echo "- \`$sl\` — motionless for ${mins} min (ctx $c), announcing no reason and at no stage that waits by design."
      # The order is load-bearing and is the whole of Step 5's diagnosis rule, restated at the
      # point of alarm: the cheapest and most reliable evidence first, hand-driving never.
      echo "  1. GIT FIRST: \`git -C $ROOT/.claude/worktrees/ship-$sl log --oneline -5\` and \`git status\`."
      echo "     Git says what the child PRODUCED; the pane says only what it INTENDED, and the commonest"
      echo "     stall silhouette is a child that left its own next instruction unsubmitted in the input box."
      echo "  2. THEN NUDGE IT: \`bash $DIR/shipyard-tell.sh $sl \"<what to do next>\"\`. It types, submits, polls"
      echo "     the child's turn state and reports delivered/queued, or unconfirmed and exit 6. Do not hand-drive."
      echo "  2b. IF IT CAME BACK unconfirmed: peek, and submit what is already in the box — the nudge prints"
      echo "     both commands. Compaction's FIRST act is Escape, which CLEARS the box, so compacting here"
      echo "     throws the directive away. The text survives in the mailbox .txt, the delivery does not."
      echo "  3. ONLY THEN COMPACT: \`bash $DIR/shipyard-compact.sh $sl\` (compacts AND resumes) — and only if"
      echo "     ctx is ⚠️/🛑, or the unconfirmed nudge turns out to be a child REFUSING input. An unconfirmed"
      echo "     on a child that was running all window is the healthy case and is NOT a compaction trigger."
      echo "     A ❓ ctx is NOT a compaction trigger and NOT a clearance: it means the figure could not be"
      echo "     scaled, so resolve that first (see the block below) and act on the band it turns into."
    done
  fi
  # The two blocks the STALLED one used to swallow. Each is a slot that is motionless for a reason
  # it stated, so neither bypasses --only-changed: the class is in the signature, which makes the
  # state the news exactly once — on the tick it appears and on the tick it clears — instead of
  # once every ten minutes for as long as it lasts.
  if [ "${#WAITING[@]}" -gt 0 ]; then
    echo
    echo "### ⏳ WAITING — a stated, self-healing wait, not a stall"
    for x in "${WAITING[@]}"; do
      sl=${x%%|*}; rest=${x#*|}; cl=${rest%%|*}; rest=${rest#*|}; c=${rest%%|*}; act=${rest#*|}
      echo "- \`$sl\` — \`$cl\` (ctx $c). $act"
    done
  fi
  if [ "${#ATTENTION[@]}" -gt 0 ]; then
    echo
    echo "### 🙋 WAITING FOR YOU — a known cause, not a stall (do NOT compact)"
    for x in "${ATTENTION[@]}"; do
      sl=${x%%|*}; rest=${x#*|}; cl=${rest%%|*}; rest=${rest#*|}; c=${rest%%|*}; act=${rest#*|}
      echo "- \`$sl\` — \`$cl\` (ctx $c). $act"
    done
  fi
  # An unscalable ctx figure is NOT a healthy one, and the band alone is easy to miss in a wide
  # table — so it gets its own line. It means the report is holding a token count and no window it
  # can defend ASSERTING it against.
  #
  # THE TWO CAUSES TAKE DIFFERENT ACTS, so this block says which is which rather than printing
  # both remedies at every slot. An earlier draft did print both, on the stated grounds that the
  # operator's act was the same — it is not, and the half that does not apply is actively harmful:
  # for a figure whose window is merely unsettled, the size is already listed, so adding another
  # cannot clear it, and an extra entry BELOW the current smallest moves the boundary the guard
  # measures against. The row already distinguishes them (ctx_probe prints a bare count for one
  # and a `<=` bound for the other), so this block reads the same distinction off the display
  # rather than keeping a second copy of the rule.
  if [ "${#UNSCALED[@]}" -gt 0 ]; then
    echo
    echo "### ❓ ctx UNSCALED — a token count with no window to assert it against"
    echo "Do NOT read a missing percentage as healthy: these children may be at their ceiling or nowhere near it."
    for x in "${UNSCALED[@]}"; do
      sl=${x%%|*}; disp=${x#*|}
      case "$disp" in
      '<='*)
        echo "- \`$sl\` — the figure is an UPPER BOUND, not a measurement: the window is not pinned"
        echo "  down yet, so the child is at most that fraction and possibly far less. Name the window"
        echo "  — \`SHIPYARD_CTX_WINDOW=<tokens>\` — to turn it into a real band. Adding a CTX_WINDOWS"
        echo "  entry will NOT clear this one; the size is already listed."
        echo "  A bound that never resolves as the count climbs is itself the answer: that child's"
        echo "  window IS the smallest size this report knows, and only the override will say so."
        ;;
      *)
        echo "- \`$sl\` — the count exceeds every window this report knows of, so no percentage exists"
        echo "  to print. Add the size to CTX_WINDOWS in shipyard-ctx.sh if a new model has shipped,"
        echo "  or name it with \`SHIPYARD_CTX_WINDOW=<tokens>\`."
        ;;
      esac
    done
  fi
  # What this tick TORE DOWN, and what it refused to. A destructive act the operator did not
  # ask for must never be inferable only from a row that quietly changed, so the first block
  # is printed whenever it is non-empty. The second exists because of what the automatic path
  # would otherwise COST in visibility: a slot it declines keeps its worktree AND, once its
  # terminal is gone, stops being enumerated — so without this block a refused worktree would
  # be quieter than it is today rather than louder. It carries the exact command.
  if [ "${#REAPED[@]}" -gt 0 ]; then
    echo
    echo "### 🧹 TORN DOWN — merged, finished, and gate clear"
    for x in "${REAPED[@]}"; do
      sl=${x%%|*}; rest=${x#*|}; mr=${rest%%|*}; rest=${rest#*|}; n=${rest%%|*}; drc=${rest#*|}
      echo "- \`$sl\` ($mr) — \`merged\` on $n consecutive ticks, ship's stage terminal, nobody at the terminal,"
      echo "  and the content gate proved the branch's content is in the base branch. Terminal and worktree are gone."
      echo "  The BRANCH is untouched: \`git branch -D\` it when you are done with it (see SKILL.md on why not \`-d\`)."
      # A teardown that removed the slot and THEN failed its fleet-level bookkeeping is reported
      # as what it is. The slot is gone either way — the worktree test in autodown_consider
      # established that — but the lifecycle state it could not settle is the operator's to look at.
      [ "$drc" = 0 ] || \
        echo "  NOTE: it exited $drc AFTER removing the slot — its fleet-level cleanup (container pin, parent watchers) could not be verified. Re-run \`bash $DIR/shipyard-down.sh $sl\` once the backend is healthy to settle it."
    done
  fi
  # HELD is its own block, not a variant of the refusal below, because the remedy is the
  # opposite one: a refusal wants the operator to go and look at a worktree, this wants them to
  # answer a question — after which the slot tears itself down on the next tick with nothing
  # else to do. Silence was never an option here: skipping quietly is what made the slot
  # destroyable in the first place.
  if [ "${#REAP_HELD[@]}" -gt 0 ]; then
    echo
    echo "### ✋ HELD — finished and merged, but somebody is owed an answer"
    for x in "${REAP_HELD[@]}"; do
      sl=${x%%|*}; rest=${x#*|}; n=${rest%%|*}; shown=${rest#*|}
      echo "- \`$sl\` — merged, finished and otherwise ready; its teardown is HELD by $n unsettled record(s) in $MAILBOX_DIR:"
      # NAME THE FILES. Without this the block's only remedy was "answer it", which is false for
      # exactly the records the hold was widened to catch: `shipyard-escalations.sh` skips a
      # record whose kind it cannot parse, so for an unparseable one the escalation block below
      # is EMPTY, `shipyard-answer.sh` cannot write it (jq fails on the same bytes), and nothing
      # named the file. That combination is an unclearable hold announced by two instructions
      # that cannot be followed — measured — and naming the path is what makes it clearable.
      # `while read`, not `for … in $( )`: the lines carry spaces (the path plus a parenthesised
      # reason), and word-splitting turned each one into a column of fragments.
      slot_unsettled_files "$sl" | while IFS= read -r hf; do echo "    $hf"; done
      if [ "$shown" = "$n" ]; then
        echo "  Answer it — the escalation block below carries the command."
        echo "  It then tears itself down on the next tick."
      else
        # The counts differ, so at least one record is unreadable. Say that, rather than the
        # blanket sentence an earlier version printed even when the two agreed.
        echo "  $shown of those are readable escalations; the rest are not."
        echo "  A record this report cannot parse does NOT appear in the escalation block below"
        echo "  and cannot be answered — look at the file named above and repair or remove it (#197)."
      fi
      echo "  Nothing was removed. Tearing it down by hand first destroys the session that asked, and"
      echo "  the reply then reports success to a child that is no longer there."
    done
  fi
  if [ "${#REAP_REFUSED[@]}" -gt 0 ]; then
    echo
    echo "### ✋ AWAITING REMOVAL — finished work whose teardown was refused"
    for x in "${REAP_REFUSED[@]}"; do
      sl=${x%%|*}; why=${x#*|}
      echo "- \`$sl\` — merged and finished, but the teardown refused:"
      printf '%s\n' "$why" | sed 's/^/    /'
      echo "  NOTHING was removed. This is re-tried every tick; to do it yourself once you have looked:"
      echo "    bash $DIR/shipyard-down.sh $sl"
    done
  fi
  bash "$DIR/shipyard-escalations.sh" 2>/dev/null
} | cat

# An unanswered escalation also keeps the loop alive — never exit on a live question.
[ "$TERMINAL" = 1 ] && exit 0 || exit 1
