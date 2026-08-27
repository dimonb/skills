#!/usr/bin/env bash
# shipyard-ctx.sh — how much of its context window a ship child has used. Source only.
#
# These functions live here rather than in shipyard-report.sh for one reason: they are PURE and
# side-effect free, and shipyard-report.sh CANNOT BE SOURCED — its top level runs
# `shipyard_backend_check || exit 1`, which exits any test process that tries. So every review
# that wanted to exercise them had to re-extract them with awk first, and nothing could assert on
# them afterwards. A file no test can reach is a defect in its own right; this is the fix, and the
# suite lives in tests/ beside this file.
#
# The caller must have set $ROOT to the MAIN checkout (not a child worktree) — the same assumption
# slot_iid() and slot_stage() already make in shipyard-report.sh.
#
# This commit is a MOVE and nothing else: the functions below are byte-identical to the ones that
# were in shipyard-report.sh, so that the extraction can be reviewed as an extraction. Behaviour
# changes follow in their own commits.

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
