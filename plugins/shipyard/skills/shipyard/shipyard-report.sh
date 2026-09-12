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
# escalation count, the ctx BAND, and the WAIT CLASS (see the stall section below —
# entering or leaving a stated wait is news, and it is news exactly once, which is what
# makes suppressing the stall block for it cost the operator nothing).
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
#  * running-vs-idle comes from a snapshot DIFF (two captures 3s apart). That answers "is this
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
#    exits 0 (see the fleet_signal block below); an unreachable backend, or one that disagrees
#    with the fleet's own container pin, raises 🛑 NO SIGNAL and keeps the monitor alive.
#
# Env:
#   SHIPYARD_BACKEND    agterm (default) | tmux | auto
#   SHIPYARD_WORKSPACE  agterm workspace name (default: the pinned one, see shipyard-backend.sh)
#   SHIPYARD_SESSION    tmux session name    (default: <repo>)
#   SHIPYARD_STALL_SECS motionless seconds before the stall block fires (default: 1800)
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
# fleet_signal — "<class><TAB><why>" and rc 1 when an empty answer may NOT be read as completion;
# nothing and rc 0 when it may. A pure reader of the two facts above, so it can be asked at both
# exit-0 sites without re-probing anything.
fleet_signal() {
  if [ "$ENUM_RC" != 0 ]; then
    printf 'unreachable%sthe %s backend did not answer when asked which terminals exist' \
      "$TAB" "$(shipyard_backend)"
    return 1
  fi
  if [ -n "$PINNED_ELSEWHERE" ]; then
    printf 'elsewhere%sthis tick resolved %s, but this fleet was launched on %s' \
      "$TAB" "$(shipyard_backend)" "$PINNED_ELSEWHERE"
    return 1
  fi
  return 0
}

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
STALL_SECS="${SHIPYARD_STALL_SECS:-1800}"   # 30 min of no movement, idle, nothing asked of you
# ENSURE, not just resolve: if the directory is missing the stall table cannot be
# written, `since` resets to now on every run, and the watchdog silently never
# fires. A watchdog that fails closed is worse than none — it looks armed.
if mb=$(shipyard_mailbox_ensure 2>/dev/null); then
  SIGFILE="$mb/report-sig"; STALLFILE="$mb/report-stall"; TICKFILE="$mb/report-tick"
fi
STALLED=()
STALL_ROWS=()
WAITING=()    # motionless for a stated, self-healing reason — nothing to do
ATTENTION=()  # motionless for a known reason that needs a person, but never compaction
UNSCALED=()   # slots whose ctx figure exceeds every window size the report knows of

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
# file, and a child that never wrote one leaves this column blank for the whole life of the
# change — measured, three changes in a row, `no MR yet` from launch to merge over open,
# reviewed, mergeable pull requests (#124). The forge always knows; the child need not.
#
# It also unblocks the SLOT GRAPH, which is not obvious from here. shipyard-slot-graph.sh's first
# node completes on `_syg_pr_known`, so with no iid a slot can never leave `launched` — and its
# comment reasons that the divergence is unreachable "because ship records the PR number when it
# opens the PR", which is exactly the assumption #124 falsified. With the column blind, the
# `completed` glyph could never fire for any state-file-less child either.
#
# COST: one forge call per slot per tick, and only for a slot no state file could answer for.
# ORDER: last. Every cheaper and more exact source wins first, GitLab's slot-is-the-iid rule
# included — this is a fallback, never a substitute.
slot_iid_forge() {
  local slot="$1" wt br v
  wt="$ROOT/.claude/worktrees/ship-$slot"
  [ -d "$wt" ] || return 0
  br=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)
  # No branch, a detached HEAD (a child that has not branched yet), or the base branch itself:
  # there is no question to ask, and asking one about the base branch invites a wrong answer.
  case "$br" in ''|HEAD) return 0 ;; esac
  [ -n "$DEFAULT_BRANCH" ] && [ "$br" = "$DEFAULT_BRANCH" ] && return 0
  if [ "$(forge)" = github ]; then
    # Same subshell-cd and token guard as mr_state(), for the same reasons documented there.
    # `--state all`, not `open`: a merged PR whose terminal is still up must keep its number, or
    # the column would go blank again at the exact moment the graph needs `merged` to conclude.
    v=$( (cd "$ROOT" 2>/dev/null && unset GITHUB_TOKEN \
      && gh pr list --head "$br" --state all --limit 1 --json number --jq '.[0].number // empty') 2>/dev/null)
  else
    v=$(OAUTH_TOKEN= glab mr list --source-branch "$br" -F json 2>/dev/null | jq -r '.[0].iid // empty')
  fi
  # ONLY a number is an answer. A CLI that is unauthenticated, rate-limited or pointed at the
  # wrong forge prints prose, a usage line or an error on stdout, and an iid of `error:` would be
  # carried into mr_state() and rendered as a PR that does not exist.
  case "$v" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$v"
}

# The MR/PR number for a slot, or empty when the change has not opened one yet.
#
# A NUMERIC SLOT IS NOT AUTOMATICALLY THE MR NUMBER. On GitLab it is (the slot comes
# from an MR iid). On GitHub `/shipyard` is normally started from an ISSUE, so the slot is an
# issue number and the PR does not exist yet and will get a DIFFERENT number. Returning
# the slot there labelled a live issue as a PR, and then the state lookup for that
# non-existent PR came back "?" — which mr_state()/inflight took for "finished", so the
# monitor declared the run over about a minute after it started.
slot_iid() {
  local slot="$1" sd f v
  sd="$ROOT/.claude/worktrees/ship-$slot/.pipeline-state"
  f=$(ls -1 "$sd"/*.json 2>/dev/null | tail -1)
  if [ -n "$f" ]; then
    v=$(jq -r '.pr_number // .pr // .iid // .mr_iid // empty' "$f" 2>/dev/null)
    [ -n "$v" ] && { printf '%s' "$v"; return; }
  fi
  f=$(ls -1 "$sd"/MR-*.json 2>/dev/null | tail -1)
  if [ -n "$f" ]; then
    basename "$f" | sed -E 's/^MR-([0-9]+)\.json$/\1/'
    return
  fi
  # Only GitLab may fall back to the slot itself.
  if [[ "$slot" =~ ^[0-9]+$ ]] && [ "$(forge)" = gitlab ]; then printf '%s' "$slot"; return; fi
  slot_iid_forge "$slot"
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
  # mode found no terminals. Whether that ends the watch is now fleet_signal's call, not the
  # emptiness's own.
  NOSIG=""; NOSIG_RC=0
  NOSIG=$(fleet_signal) || NOSIG_RC=$?
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
  esc="—"; [ "$pend" != 0 ] && esc="⚠️ $pend"
  total_pend=$((total_pend+pend))

  if [ -z "$addr" ]; then
    ROWS+=("| $slot | $mr_label | — | ⛔ no terminal | — | $esc | — | — |")
    SIG+=("$slot|$mr_label|term=0|—|—|$pend")
    # Remember WHICH slots this tick concluded were gone. The tail re-asks the backend before it
    # may stop the loop, and the only honest reading of "still enumerated, but I rendered it gone"
    # is that the lookup failed, not that the child ended.
    GONE="$GONE $slot"
    continue
  fi

  a=$(shipyard_capture "$slot")
  sleep 3
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
  # `?` counts as IN FLIGHT, never as finished. The window is alive and the pane is
  # moving; an unresolvable state means the lookup failed, not that the work ended.
  # Treating it as terminal is what stopped a monitor 60 seconds into a fresh run.
  # A LIVE TERMINAL IS IN FLIGHT, whatever the forge says. `merged` means one MR
  # ended, not that the child did: a ship session that lands a spec change and
  # continues to its implementation outlives its first MR by design. Counting only
  # the MR state here reported "nothing in flight — monitor stopped" over a child
  # that was mid implementation, and took the STALL detector down with it, so the
  # supervisor got two green signals while the session sat with an unsubmitted line
  # in its box. Teardown is the supervisor's act; the absence of a terminal is the
  # honest end signal — but only once CORROBORATED, which is the fleet_signal block
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
    unknown) ctx="❓ $ctx"; UNSCALED+=("$slot") ;;
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
  SIG+=("$slot|$mr_label|term=1|$state|$stage|$pend|$band|$wait_class")
  :
done

[ -n "$STALLFILE" ] && [ "${#STALL_ROWS[@]}" -gt 0 ] && printf '%s\n' "${STALL_ROWS[@]}" >"$STALLFILE" 2>/dev/null
# Together with the stall table, never before it: a gap may only be consumed by a run that actually
# restarted the clocks (see the supervision-gap block above).
[ -n "$TICKFILE" ] && printf '%s\n' "$RUN_EPOCH" >"$TICKFILE" 2>/dev/null

TERMINAL=0
[ "$inflight" -eq 0 ] && [ "$total_pend" -eq 0 ] && TERMINAL=1

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
# ANSWERED, which is what fleet_signal asks.
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
  NOSIG=$(fleet_signal) || NOSIG_RC=$?
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
if [ "$ONLY_CHANGED" = 1 ] && [ "$TERMINAL" = 0 ] && [ "${#STALLED[@]}" -eq 0 ] \
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
  # table — so it gets its own line. It means the report is holding a token count larger than any
  # window it knows of, which is the one state where it can neither reassure nor alarm honestly.
  if [ "${#UNSCALED[@]}" -gt 0 ]; then
    echo
    echo "### ❓ ctx OUT OF RANGE — a figure larger than any window this report knows of"
    for sl in "${UNSCALED[@]}"; do
      echo "- \`$sl\` — the token count is shown without a percentage because none can be computed."
      echo "  Do NOT read the missing glyph as healthy: this child may be at its ceiling or nowhere near it."
      echo "  Fix it by naming the window — \`SHIPYARD_CTX_WINDOW=<tokens>\` — or add the size to CTX_WINDOWS"
      echo "  in shipyard-ctx.sh if a new model has shipped."
    done
  fi
  bash "$DIR/shipyard-escalations.sh" 2>/dev/null
} | cat

# An unanswered escalation also keeps the loop alive — never exit on a live question.
[ "$TERMINAL" = 1 ] && exit 0 || exit 1
