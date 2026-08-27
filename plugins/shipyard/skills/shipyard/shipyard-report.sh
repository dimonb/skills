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
# escalation count, and the ctx BAND. Deliberately NOT meaningful: the timestamp, the
# `last line` column (elapsed time / token counts change every tick), the raw ctx
# figure — only its band — and ▶️/⏸, which flips
# constantly while ship works and re-waits. A terminal report (nothing in flight) is
# always printed, so the end of the run is never swallowed. Exit codes are unchanged
# whether or not anything was printed.
#
# The ctx band has always been in the signature, but it could never move it while the
# column was blind: the old pane-scraping ctx_of returned "—" on current builds, so the
# band was permanently `ok`. Reading it from the transcript makes it a live signal, which
# is why it is named here now — a band crossing is exactly the tick worth breaking
# silence for, and it is the only thing in the ctx column that does.
#
# Design notes:
#  * running-vs-idle comes from a snapshot DIFF (two captures 3s apart), not from
#    parsing spinner glyphs / the footer — those always look "busy";
#  * the whole report is buffered and printed in ONE block so Monitor batches it
#    into a single notification;
#  * the MR iid of a text slot is read out of ship's own state
#    (`.pipeline-state/MR-<iid>.json` inside the worktree) — before the MR exists
#    there is none, and the slot counts as in-flight;
#  * open escalations are appended, so a question raised between fast-monitor
#    ticks still shows up here;
#  * exit 0 = nothing in flight (all MRs merged/closed) → stop the loop;
#    exit 1 = work is still open.
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
# The ctx column's logic lives in its own file so that it can be SOURCED — this one cannot be,
# because shipyard_backend_check below exits a process that tries. See shipyard-ctx.sh and its
# tests/ directory.
# shellcheck source=shipyard-ctx.sh
. "$DIR/shipyard-ctx.sh"

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
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
if [ ${#SLOTS[@]} -eq 0 ]; then
  mapfile -t SLOTS < <(shipyard_slots)
fi

# Where the last printed report's signature lives (shared .git, never committed).
SIGFILE=""
STALLFILE=""
STALL_SECS="${SHIPYARD_STALL_SECS:-1800}"   # 30 min of no movement, idle, nothing asked of you
# ENSURE, not just resolve: if the directory is missing the stall table cannot be
# written, `since` resets to now on every run, and the watchdog silently never
# fires. A watchdog that fails closed is worse than none — it looks armed.
if mb=$(shipyard_mailbox_ensure 2>/dev/null); then SIGFILE="$mb/report-sig"; STALLFILE="$mb/report-stall"; fi
STALLED=()
STALL_ROWS=()
UNSCALED=()   # slots whose ctx figure exceeds every window size the report knows of

# iid: numeric slot is the iid; otherwise read it from .pipeline-state.
# Which forge origin points at. The report used to assume GitLab everywhere and ran
# `glab mr view` against a GitHub remote, where it fails silently — see mr_state().
forge() {
  case "$(git -C "$ROOT" remote get-url origin 2>/dev/null)" in
    *github.com*|*github-*) printf 'github' ;;
    *)                      printf 'gitlab' ;;
  esac
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
  if [[ "$slot" =~ ^[0-9]+$ ]] && [ "$(forge)" = gitlab ]; then printf '%s' "$slot"; fi
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

status_line() {
  grep -vE '^[[:space:]]*$|──|❯|tokens$|esc to interrupt|shift\+tab|current: [0-9]|scroll with|tmux detected|Tip:' \
    | grep -iE '✻|✽|·|agents done|Cogitated|Waddling|Whirlpool|ship|propose|spec|apply|archive|merg|approv|pipeline|await|waiting|escalat|ready|pushed|done' \
    | tail -1 | sed -E 's/^[[:space:]]*//; s/[[:space:]]+$//'
}

if [ ${#SLOTS[@]} -eq 0 ]; then
  {
    echo "### ship status — $(date '+%H:%M:%S %Z')"
    echo
    echo "_no live ship terminals in $KIND \`$CONTAINER\` ($(shipyard_backend))_"
  } | cat
  exit 0
fi

declare -a ROWS
declare -a SIG
inflight=0
total_pend=0

# ONCE, HERE, IN THIS SHELL — never from inside the loop below. The per-slot ctx call is
# $(ctx_probe ...), which nests $(ctx_window ...): a warning raised down there fires once per
# slot on every tick and cannot be suppressed from within, because the flag that would suppress
# it dies with its own subshell. That is measured, not feared, and it defeats --only-changed,
# which decides whether to print anything only AFTER this loop has already written to stderr.
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
  # honest end signal. (A dead terminal never reaches here — it `continue`s above —
  # so this counts live sessions only, and the monitor still exits once every
  # terminal is gone.)
  inflight=$((inflight+1))

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
  STALL_ROWS+=("$slot	$slot_sig	$since")
  motionless=$(( now_epoch - since ))
  stalled_now=0
  if [ "$run" = "⏸ idle/wait" ] && [ "$pend" = 0 ] && [ "$motionless" -ge "$STALL_SECS" ]; then
    STALLED+=("$slot|$((motionless/60))|$ctx")
    stalled_now=1
  fi

  # Paint the same verdict on the sidebar glyph (agterm only; a no-op on tmux), so the
  # board is readable without reading the table: blocked = it is waiting on YOU.
  if   [ "$pend" != 0 ];      then shipyard_note "$slot" blocked --blink
  elif [ "$stalled_now" = 1 ]; then shipyard_note "$slot" blocked
  elif [ "$state" = merged ] || [ "$state" = closed ] || [ "$stage" = ready-to-merge ]; then
                                   shipyard_note "$slot" completed
  else                             shipyard_note "$slot" active
  fi

  ROWS+=("| $slot | $mr_label | $addr | $run | $state / $stage | $esc | $ctx | ${line} |")
  # No $run and no $line here on purpose — see the --only-changed note in the header.
  SIG+=("$slot|$mr_label|term=1|$state|$stage|$pend|$band")
  :
done

[ -n "$STALLFILE" ] && [ "${#STALL_ROWS[@]}" -gt 0 ] && printf '%s\n' "${STALL_ROWS[@]}" >"$STALLFILE" 2>/dev/null

TERMINAL=0
[ "$inflight" -eq 0 ] && [ "$total_pend" -eq 0 ] && TERMINAL=1

# --only-changed: stay silent unless the meaningful state moved. A terminal report is
# always printed so the end of the run is never swallowed.
if [ "$ONLY_CHANGED" = 1 ] && [ "$TERMINAL" = 0 ] && [ "${#STALLED[@]}" -eq 0 ] && [ -n "$SIGFILE" ]; then
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
  echo
  echo "| slot | MR | term | session | MR state / stage | esc | ctx | last line |"
  echo "|------|----|------|---------|------------------|-----|-----|-----------|"
  for r in "${ROWS[@]}"; do echo "$r"; done
  echo
  if [ "$inflight" -eq 0 ] && [ "$total_pend" -eq 0 ]; then
    echo "_nothing in flight (all merged/closed) — monitor stopped_"
  else
    echo "_in flight: ${inflight}; open escalations: ${total_pend}_"
  fi
  if [ "${#STALLED[@]}" -gt 0 ]; then
    echo
    echo "### 🛑 STALLED — idle, nothing asked of you, and nothing moving"
    for x in "${STALLED[@]}"; do
      sl=${x%%|*}; rest=${x#*|}; mins=${rest%%|*}; c=${rest#*|}
      echo "- \`$sl\` — motionless for ${mins} min (ctx $c). A child does not idle this long on its own."
      # The order is load-bearing and is the whole of Step 5's diagnosis rule, restated at the
      # point of alarm: the cheapest and most reliable evidence first, hand-driving never.
      echo "  1. GIT FIRST: \`git -C $ROOT/.claude/worktrees/ship-$sl log --oneline -5\` and \`git status\`."
      echo "     Git says what the child PRODUCED; the pane says only what it INTENDED, and the commonest"
      echo "     stall silhouette is a child that left its own next instruction unsubmitted in the input box."
      echo "  2. THEN NUDGE IT: \`bash $DIR/shipyard-tell.sh $sl \"<what to do next>\"\`. It types, submits, and"
      echo "     reports delivered/queued/unconfirmed from a before/after diff. Do not hand-drive the pane."
      echo "  3. ONLY THEN COMPACT: \`bash $DIR/shipyard-compact.sh $sl\` (compacts AND resumes) — and only if"
      echo "     ctx is ⚠️/🛑 or the nudge went unconfirmed. The client's own autocompact usually gets there first."
      echo "     A ❓ ctx is NOT a compaction trigger and NOT a clearance: it means the figure could not be"
      echo "     scaled, so resolve that first (see the block below) and act on the band it turns into."
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
