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
#   SHIPYARD_BACKEND    agterm (default) | tmux | auto
#   SHIPYARD_WORKSPACE  agterm workspace name (default: the pinned one, see shipyard-backend.sh)
#   SHIPYARD_SESSION    tmux session name    (default: <repo>)
#   SHIPYARD_STALL_SECS motionless seconds before the stall block fires (default: 1800)
#   SHIPYARD_CTX_WINDOW context window in tokens, overriding the inference in ctx_window
#   GITLAB_HOST         glab host (default: derived from the origin remote)
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
# --- context usage of a child ---------------------------------------------------
# A child that crosses its context ceiling stops accepting turns SILENTLY and reads as
# ⏸ idle/wait with no escalation — indistinguishable from waiting on CI. This column
# exists to make that visible before it happens.
#
# THE INSTRUMENT IS THE CHILD'S OWN TRANSCRIPT, NOT THE PANE. Two independent reasons,
# and the second is the one that was actually paid for:
#
#   * the footer has stated the figure differently across client builds — a session token
#     total, then a `NN% context used` line — and each rename silently disabled this
#     column with no error anywhere;
#   * more importantly, THE PANE IS A RENDERING, and what it renders depends on what the
#     child is doing at capture time. Measured on the current build, side by side: an idle
#     child still prints `172188 tokens` in its footer, while a child running subagents
#     prints NO session figure at all — the agent-progress list takes that room and leaves
#     only per-turn `↓ 115.2k tokens` download counters, which are per-request and not a
#     session figure. So the column goes blind exactly when the child is deepest in a
#     review battery, which is when it matters most. That is how it read "—" for a whole
#     night while the child behind it sat at 756445 tokens: a child at 76% of its window
#     looked exactly like one at 5%.
#
# Pane scraping is fragile for a third reason too: the capture contains whatever the child
# happens to be PRINTING, so any output of the form "<number> tokens" scrolling through it
# is indistinguishable from a footer total. The transcript has none of these problems, and
# it alone carries the PEAK (below). The footer forms are kept, but as the fallback now.
#
# NO LIVE SIGNAL NAMES THE MODEL, so none is read and the window is inferred instead
# (ctx_window). Three places were checked and all three are dead ends — recorded here so
# the next reader does not re-check them:
#   * `message.model` in the transcript OMITS the `[1m]` marker even for sessions that
#     really are 1M: it reads the same either way;
#   * the `cost-state` record DOES carry the marker, but it is written once at session
#     EXIT — absent from every live child, which is the only kind this reads;
#   * a subagent's `.meta.json` carries an aliased model id, but that is what the
#     SUBAGENT was spawned with, not the parent session's window.

# The child's transcript file, or nothing. Claude Code keys its per-project directory on
# the working directory, slugged by replacing every non-alphanumeric character with `-`.
# CLAUDE_CONFIG_DIR / CLAUDE_HOME are honoured because the launcher propagates them into
# the child (shipyard_env_preamble), so parent and child resolve the same root.
ctx_transcript() {
  local slot="$1" cfg wt slug d f
  cfg="${CLAUDE_CONFIG_DIR:-${CLAUDE_HOME:-$HOME/.claude}}"
  wt="$ROOT/.claude/worktrees/ship-$slot"
  wt=$(cd "$wt" 2>/dev/null && pwd -P) || return 1
  slug=$(printf '%s' "$wt" | sed 's/[^A-Za-z0-9]/-/g')
  d="$cfg/projects/$slug"
  [ -d "$d" ] || return 1
  # Only the top level: subagent transcripts live under `<session-id>/subagents/` and are
  # not the child's own context. Newest by mtime is the live session — a resumed session
  # writes a new file rather than appending to the old one.
  f=$(ls -1t "$d"/*.jsonl 2>/dev/null | head -1)
  [ -n "$f" ] || return 1
  printf '%s' "$f"
}

# "<current> <peak>" in tokens, or nothing. BOTH matter, and they are not the same number:
# the CURRENT total is what the column reports, the PEAK is what the window is inferred
# from. A window cannot shrink, but the client's own autocompact drops the current total
# sharply and unprompted (one child here fell from 756445 tokens to 27% with no
# intervention), so inferring from the current total would let the inferred window bounce
# back down with it and quietly re-band a healthy child as critical.
ctx_totals() {
  jq -Rr 'fromjson? | .message.usage | select(. != null)
          | ((.input_tokens // 0) + (.cache_read_input_tokens // 0)
             + (.cache_creation_input_tokens // 0) + (.output_tokens // 0))' "$1" 2>/dev/null \
    | awk 'NF { last = $1; if ($1 + 0 > max) max = $1 + 0 }
           END { if (last != "") print last, max }'
}

# Known context window sizes, ascending. DATA, deliberately kept out of the logic below,
# because this list is the part that rots and a list is cheap to correct.
#
# WHAT HAPPENS WHEN A NEW SIZE APPEARS, which is the whole reason a hardcoded list is
# acceptable at all: a window not on this list resolves to the smallest listed one that
# still fits the peak, so the inference stays CONSERVATIVE — it over-warns, and it can never
# fall silent, which is the failure this column exists to prevent. A window LARGER than
# everything listed is caught in ctx_probe instead and reported as missing knowledge rather
# than as an impossible percentage. Either way the correction is one entry here, or
# SHIPYARD_CTX_WINDOW for a size that should not be baked in at all.
CTX_WINDOWS=(200000 1000000)

# The model's context window, in tokens. Nothing states it (see above), so it is INFERRED:
# a single request that carried N tokens cannot have run on a window smaller than N, so the
# window is the smallest known size that still fits the peak. That is a proof where it
# fires, not a guess.
#
# SHIPYARD_CTX_WINDOW wins unconditionally, INCLUDING DOWNWARDS: someone running a window
# smaller than anything listed has to be able to say so, and no inference may overrule them.
ctx_window() {
  local peak="$1" w
  if [[ "${SHIPYARD_CTX_WINDOW:-}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$SHIPYARD_CTX_WINDOW"; return
  fi
  for w in "${CTX_WINDOWS[@]}"; do
    if [ "$peak" -le "$w" ] 2>/dev/null; then printf '%s' "$w"; return; fi
  done
  # Past the end of the list: no known window fits. Return the largest so the caller can see
  # the total exceed it and say so, rather than inventing a size.
  printf '%s' "${CTX_WINDOWS[${#CTX_WINDOWS[@]}-1]}"
}

ctx_human() { awk -v n="$1" 'BEGIN{ if (n >= 1000) printf "%dk", n/1000; else printf "%d", n }'; }

# The session token total an OLDER build printed in its footer ("512k tokens", or the
# "/clear to save 628k tokens" hint). Never the per-turn "↓ 39.3k tokens" download
# counter, which is per-request — so lines carrying ↓ are skipped.
ctx_pane_tokens() {
  local max=0 v n
  while read -r n; do
    [ -z "$n" ] && continue
    case "$n" in
      *k) v=$(awk -v x="${n%k}" 'BEGIN{printf "%d", x*1000}') ;;
      *)  v="$n" ;;
    esac
    if [ "$v" -gt "$max" ] 2>/dev/null; then max=$v; fi
  done < <(printf '%s\n' "$1" | grep -v '↓' | grep -oE '[0-9]+(\.[0-9]+)?k? tokens' | sed 's/ tokens//')
  [ "$max" -eq 0 ] || printf '%s' "$max"
}

# "<percentage-or-dash> <display>" for the ctx column: transcript first, footer as fallback.
ctx_probe() {
  local slot="$1" pane="$2" f tot cur peak win pct
  if f=$(ctx_transcript "$slot"); then tot=$(ctx_totals "$f"); fi
  if [ -n "${tot:-}" ]; then
    cur=${tot%% *}; peak=${tot##* }
  else
    # A footer percentage is used as-is: it needs no assumption about the window at all.
    pct=$(printf '%s\n' "$pane" | grep -oE '[0-9]+% context used' | grep -oE '^[0-9]+' | sort -n | tail -1)
    if [ -n "$pct" ]; then printf '%s %s%%' "$pct" "$pct"; return; fi
    cur=$(ctx_pane_tokens "$pane"); peak="$cur"
  fi
  # Never let the column claim knowledge it does not have. A child that has not completed
  # a turn has no usage record at all, and that is "—" — not 0%, which reads as a measured
  # figure and is the same lie in the reassuring direction.
  [ -n "${cur:-}" ] || { printf '%s %s' '-' "—"; return; }
  win=$(ctx_window "$peak")
  pct=$(awk -v c="$cur" -v w="$win" 'BEGIN{ printf "%d", (c * 100) / w }')
  # NEVER PRINT A PERCENTAGE ABOVE 100. A total larger than the window it is measured against
  # is not a reading, it is a contradiction — the window list is out of date, or an override
  # is set too low. Either way what is missing is KNOWLEDGE, and it must look like missing
  # knowledge: the raw figure alone, no percentage. An impossible measurement invites someone
  # to act on it; a bare, unusually large token count invites them to fix the list or set
  # SHIPYARD_CTX_WINDOW, which is the actual repair.
  if [ "$pct" -gt 100 ] 2>/dev/null; then printf '%s %s' '-' "$(ctx_human "$cur")"; return; fi
  # The RAW FIGURE travels with the band, always. The percentage is derived from an
  # inferred window; a reader who cannot see the token count it came from cannot tell a
  # wrong inference from a real ceiling, and a bare percentage reads authoritative either way.
  printf '%s %s%% · %s' "$pct" "$pct" "$(ctx_human "$cur")"
}

# ok | warn (get it compacted soon) | crit (it is close to not accepting turns).
# Banded on the PERCENTAGE, never on a token count: 400k is 40% of a 1M window and 100% of
# a 400k one, so a token threshold is a hidden assumption about which model is running.
# The thresholds sit low because compaction is itself an API call that needs working room —
# ⚠️ has to arrive while there is still some left, not at the ceiling.
ctx_band() {
  case "$1" in ''|-) printf 'ok'; return ;; esac
  if   [ "$1" -ge 80 ] 2>/dev/null; then printf 'crit'
  elif [ "$1" -ge 65 ] 2>/dev/null; then printf 'warn'
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
      # The order is load-bearing and is the whole of Step 5's diagnosis rule, restated at the
      # point of alarm: the cheapest and most reliable evidence first, hand-driving never.
      echo "  1. GIT FIRST: \`git -C $ROOT/.claude/worktrees/ship-$sl log --oneline -5\` and \`git status\`."
      echo "     Git says what the child PRODUCED; the pane says only what it INTENDED, and the commonest"
      echo "     stall silhouette is a child that left its own next instruction unsubmitted in the input box."
      echo "  2. THEN NUDGE IT: \`bash $DIR/shipyard-tell.sh $sl \"<what to do next>\"\`. It types, submits, and"
      echo "     reports delivered/queued/unconfirmed from a before/after diff. Do not hand-drive the pane."
      echo "  3. ONLY THEN COMPACT: \`bash $DIR/shipyard-compact.sh $sl\` (compacts AND resumes) — and only if"
      echo "     ctx is ⚠️/🛑 or the nudge went unconfirmed. The client's own autocompact usually gets there first."
    done
  fi
  bash "$DIR/shipyard-escalations.sh" 2>/dev/null
} | cat

# An unanswered escalation also keeps the loop alive — never exit on a live question.
[ "$TERMINAL" = 1 ] && exit 0 || exit 1
