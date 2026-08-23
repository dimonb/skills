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
# escalation count. Deliberately NOT meaningful: the timestamp, the `last line`
# column (elapsed time / token counts change every tick) and ▶️/⏸, which flips
# constantly while ship works and re-waits. A terminal report (nothing in flight) is
# always printed, so the end of the run is never swallowed. Exit codes are unchanged
# whether or not anything was printed.
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
#   SHIPYARD_BACKEND   agterm (default) | tmux | auto
#   SHIPYARD_WORKSPACE agterm workspace name (default: the pinned one, see shipyard-backend.sh)
#   SHIPYARD_SESSION   tmux session name    (default: <repo>)
#   GITLAB_HOST  glab host (default: derived from the origin remote)
set -o pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shipyard-lib.sh
. "$DIR/shipyard-lib.sh"

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
# Context usage of a child, read from the pane footer. The figure that matters is the
# SESSION TOTAL ("627976 tokens", or the "/clear to save 628k tokens" hint), never the
# per-turn "↓ 39.3k tokens" download counter — so lines carrying ↓ are skipped. A child
# that crosses its ceiling stops accepting turns SILENTLY and reads as ⏸ idle/wait with
# no escalation, which is indistinguishable from waiting on CI. This column is what
# makes that visible before it happens.
ctx_of() {
  local max=0 v n
  while read -r n; do
    [ -z "$n" ] && continue
    case "$n" in
      *k) v=$(awk -v x="${n%k}" 'BEGIN{printf "%d", x*1000}') ;;
      *)  v="$n" ;;
    esac
    if [ "$v" -gt "$max" ] 2>/dev/null; then max=$v; fi
  done < <(printf '%s\n' "$1" | grep -v '↓' | grep -oE '[0-9]+(\.[0-9]+)?k? tokens' | sed 's/ tokens//')
  [ "$max" -eq 0 ] && { printf '%s' "—"; return; }
  awk -v m="$max" 'BEGIN{ if (m>=1000) printf "%dk", m/1000; else printf "%d", m }'
}

# ok | warn (compact soon) | crit (compact NOW, it is about to stop accepting turns)
ctx_band() {
  local n="$1"
  case "$n" in —) printf 'ok'; return ;; esac
  local v=${n%k}
  if [ "${n}" = "${v}" ]; then printf 'ok'; return; fi
  if [ "$v" -ge 550 ] 2>/dev/null; then printf 'crit'
  elif [ "$v" -ge 400 ] 2>/dev/null; then printf 'warn'
  else printf 'ok'; fi
}

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
  case "$state" in opened|"no MR yet"|"?") inflight=$((inflight+1)) ;; esac

  ctx=$(ctx_of "$b"); band=$(ctx_band "$ctx")
  case "$band" in warn) ctx="⚠️ $ctx" ;; crit) ctx="🛑 $ctx" ;; esac

  # --- stall detection -------------------------------------------------------
  # The silence of --only-changed is indistinguishable from death: a child that has
  # hit its context ceiling, or that was compacted and never told to resume, sits
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
      echo "  If ctx is ⚠️/🛑 it has hit its context ceiling; if it was just compacted it is waiting to be told to resume."
      echo "  Both are fixed the same way: \`bash $DIR/shipyard-compact.sh $sl\` (compacts AND resumes), or send a directive if ctx is low."
    done
  fi
  bash "$DIR/shipyard-escalations.sh" 2>/dev/null
} | cat

# An unanswered escalation also keeps the loop alive — never exit on a live question.
[ "$TERMINAL" = 1 ] && exit 0 || exit 1
