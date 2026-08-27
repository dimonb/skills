#!/usr/bin/env bash
# shipyard-ctx.sh — how much of its context window a ship child has used. Source only.
#
# These functions live here rather than in shipyard-report.sh for one reason: they are PURE and
# side-effect free, and shipyard-report.sh cannot be sourced — its top level runs
# `shipyard_backend_check || exit 1`, which exits any test process that tries. So every review
# that wanted to exercise them had to re-extract them with awk first, and nothing could assert
# on them afterwards. A file no test can reach is a defect in its own right; this is the fix.
# The suite is in tests/ beside this file.
#
# The caller must have set $ROOT to the MAIN checkout (not a child worktree) — the same
# assumption slot_iid() and slot_stage() already make in shipyard-report.sh.
#
# Env:
#   CLAUDE_CONFIG_DIR / CLAUDE_HOME  where a child's transcript is looked up
#                                    (default: $HOME/.claude)
#   SHIPYARD_CTX_WINDOW              context window in tokens, overriding ctx_window's inference
#
# ---------------------------------------------------------------------------------------------
# A child that crosses its context ceiling stops accepting turns SILENTLY and reads as
# ⏸ idle/wait with no escalation — indistinguishable from waiting on CI. This column exists to
# make that visible before it happens.
#
# THE INSTRUMENT IS THE CHILD'S OWN TRANSCRIPT, NOT THE PANE. Two independent reasons, and the
# second is the one that was actually paid for:
#
#   * the footer has stated the figure differently across client builds — a session token total,
#     then a `NN% context used` line — and each rename silently disabled this column with no
#     error anywhere;
#   * more importantly, THE PANE IS A RENDERING, and what it renders depends on what the child is
#     doing at capture time. Measured on the current build, side by side: an idle child still
#     prints `172188 tokens` in its footer, while a child running subagents prints NO session
#     figure at all — the agent-progress list takes that room and leaves only per-turn
#     `↓ 115.2k tokens` download counters, which are per-request and not a session figure. So the
#     column goes blind exactly when the child is deepest in a review battery, which is when it
#     matters most. That is how it read "—" for a whole night while the child behind it sat at
#     756445 tokens: a child at 76% of its window looked exactly like one at 5%.
#
# Pane scraping is fragile for a third reason too: the capture contains whatever the child happens
# to be PRINTING, so any output of the form "<number> tokens" scrolling through it is
# indistinguishable from a footer total. The transcript has none of these problems, and it alone
# carries the PEAK (below). The footer forms are kept, but as the fallback now.
#
# NO LIVE SIGNAL NAMES THE MODEL, so none is read and the window is inferred instead
# (ctx_window). Three places were checked and all three are dead ends — recorded here so the next
# reader does not re-check them:
#   * `message.model` in the transcript OMITS the `[1m]` marker even for sessions that really are
#     1M: it reads the same either way;
#   * the `cost-state` record DOES carry the marker, but it is written once at session EXIT —
#     absent from every live child, which is the only kind this reads;
#   * a subagent's `.meta.json` carries an aliased model id, but that is what the SUBAGENT was
#     spawned with, not the parent session's window.

# The child's transcript file, or nothing. Claude Code keys its per-project directory on the
# working directory, slugged by replacing every non-alphanumeric character with `-`.
#
# CLAUDE_CONFIG_DIR / CLAUDE_HOME are honoured here, and the launcher propagates them into a child
# WHEN THEY ARE SET IN THE PARENT (shipyard_env_preamble exports only variables that are set). It
# does not follow that parent and child always agree: with neither set here, a child's login
# profile may still resolve a different root, and this lookup then finds no transcript and the
# column falls back to the pane. That is one of the causes of a "—" reading.
ctx_transcript() {
  local slot="$1" cfg wt slug d f
  cfg="${CLAUDE_CONFIG_DIR:-${CLAUDE_HOME:-$HOME/.claude}}"
  wt="$ROOT/.claude/worktrees/ship-$slot"
  wt=$(cd "$wt" 2>/dev/null && pwd -P) || return 1
  slug=$(printf '%s' "$wt" | sed 's/[^A-Za-z0-9]/-/g')
  d="$cfg/projects/$slug"
  [ -d "$d" ] || return 1
  # Only the top level: subagent transcripts live under `<session-id>/subagents/` and are not the
  # child's own context. Newest by mtime is the live session — a resumed session writes a new file
  # rather than appending to the old one. The heuristic assumes the child is the ONLY session
  # rooted in that worktree; open your own session there and its transcript wins instead, silently.
  f=$(ls -1t "$d"/*.jsonl 2>/dev/null | head -1)
  [ -n "$f" ] || return 1
  printf '%s' "$f"
}

# "<current> <peak>" in tokens, or nothing. BOTH matter, and they are not the same number: the
# CURRENT total is what the column reports, the PEAK is what the window is inferred from. A window
# cannot shrink, but the client's own autocompact drops the current total sharply and unprompted
# (one child here fell from 756445 tokens to 27% with no intervention), so inferring from the
# current total would let the inferred window bounce back down with it and quietly re-band a
# healthy child as critical.
#
# ZERO-SUM RECORDS ARE SKIPPED, and this is not a tidiness rule — it is the difference between
# a frozen child reading `87% · 879k` and reading `0% · 0` with no glyph at all. The client writes
# its OWN `message.usage` records with all four fields zero when a turn never reached the API:
# `"model": "<synthetic>"`, `isApiErrorMessage: true`, for "You've hit your session limit",
# "API Error: 500 Internal server error", "Connection closed mid-response". Measured on this
# machine: 18 of 290 transcripts currently END on one. A ceiling-stalled child is MORE likely to
# end on such a record, not less — it has stopped producing real turns — so taking it at face
# value paints the most reassuring possible reading on exactly the children that are dead.
# A real API turn always carries input tokens, so a zero sum means "not measured", never
# "zero context used". Filtering on the sum rather than on `model == "<synthetic>"` is deliberate:
# it catches any unmeasured record, whatever the client calls it next.
ctx_totals() {
  jq -Rr 'fromjson? | .message.usage | select(. != null)
          | ((.input_tokens // 0) + (.cache_read_input_tokens // 0)
             + (.cache_creation_input_tokens // 0) + (.output_tokens // 0))' "$1" 2>/dev/null \
    | awk '$1 + 0 > 0 { last = $1; if ($1 + 0 > max) max = $1 + 0 }
           END { if (last != "") print last, max }'
}

# Known context window sizes, in tokens. DATA, deliberately kept out of the logic below, because
# this list is the part that rots and a list is cheap to correct.
#
# APPEND IN ASCENDING ORDER. ctx_window returns the FIRST entry that fits, so an out-of-order
# entry is silently ignored and the correction does nothing — with no error anywhere.
CTX_WINDOWS=(200000 1000000)

# The model's context window, in tokens. Nothing states it (see above), so it is INFERRED: a
# single request that carried N tokens cannot have run on a window smaller than N, so the window
# is the smallest known size that still fits the peak.
#
# WHAT THIS GUARANTEES, stated narrowly because the earlier draft of this comment claimed more
# than the code delivers and that is exactly how a hardcoded list gets left to rot: the inference
# is exact when the true window IS one of the sizes listed above. For a window that is NOT listed
# it can land above the truth and UNDER-warn — a real 400k window whose peak has passed 200000
# infers 1000000, so a child at 380k (95%, effectively at the ceiling) reads 38%. A window smaller
# than the smallest listed under-warns the same way. There is no way to be safe about a size
# nobody has told us about; what there is, is SHIPYARD_CTX_WINDOW, and a reading that looks wrong
# next to its own raw token count.
#
# SHIPYARD_CTX_WINDOW wins unconditionally, INCLUDING DOWNWARDS: someone running a window smaller
# than anything listed has to be able to say so, and no inference may overrule them. A value that
# is not a positive integer of tokens is REFUSED OUT LOUD rather than ignored — a silently dead
# escape hatch is worse than none, because the operator believes the band they are looking at is
# the one they configured.
ctx_window() {
  local peak="$1" w
  if [[ "${SHIPYARD_CTX_WINDOW:-}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$SHIPYARD_CTX_WINDOW"; return
  fi
  if [ -n "${SHIPYARD_CTX_WINDOW:-}" ]; then
    echo "warning: SHIPYARD_CTX_WINDOW='$SHIPYARD_CTX_WINDOW' is not a positive integer of tokens — ignored, inferring instead" >&2
  fi
  for w in "${CTX_WINDOWS[@]}"; do
    if [ "$peak" -le "$w" ] 2>/dev/null; then printf '%s' "$w"; return; fi
  done
  # Past the end of the list: no known window fits. Return the largest so the caller can see the
  # total exceed it and say so, rather than inventing a size.
  printf '%s' "${CTX_WINDOWS[${#CTX_WINDOWS[@]}-1]}"
}

ctx_human() { awk -v n="$1" 'BEGIN{ if (n >= 1000) printf "%dk", n/1000; else printf "%d", n }'; }

# The session token total an OLDER build printed in its footer ("512k tokens", or the
# "/clear to save 628k tokens" hint). Never the per-turn "↓ 39.3k tokens" download counter, which
# is per-request — so lines carrying ↓ are skipped.
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

# "<band-key> <display>" for the ctx column: transcript first, footer as fallback.
#
# The band key is a PERCENTAGE, or one of two sentinels that are deliberately NOT the same value:
#   -   nothing could be measured          -> band ok, display "—"
#   ?   measured, but larger than any known window -> band unknown, display the bare figure
# Collapsing those two into one sentinel is what made the alarm switch OFF at the ceiling: with
# an override of 400000, 400001 tokens banded crit and 450000 banded ok.
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
  # Never let the column claim knowledge it does not have. A child that has not completed a turn
  # has no usage record at all, and that is "—" — not 0%, which reads as a measured figure and is
  # the same lie in the reassuring direction.
  [ -n "${cur:-}" ] || { printf '%s %s' '-' "—"; return; }
  win=$(ctx_window "$peak")
  pct=$(awk -v c="$cur" -v w="$win" 'BEGIN{ printf "%d", (c * 100) / w }')
  # NEVER PRINT A PERCENTAGE ABOVE 100. A total larger than the window it is measured against is
  # not a reading, it is a contradiction — the window list is out of date, or an override is set
  # too low. Either way what is missing is KNOWLEDGE, and it must look like missing knowledge: the
  # raw figure alone, no percentage.
  if [ "$pct" -gt 100 ] 2>/dev/null; then printf '%s %s' '?' "$(ctx_human "$cur")"; return; fi
  # The RAW FIGURE travels with the band, always. The percentage is derived from an inferred
  # window; a reader who cannot see the token count it came from cannot tell a wrong inference
  # from a real ceiling, and a bare percentage reads authoritative either way.
  printf '%s %s%% · %s' "$pct" "$pct" "$(ctx_human "$cur")"
}

# ok | warn | crit | unknown.
#
# Banded on the PERCENTAGE, never on a token count: 400k is 40% of a 1M window and 100% of a 400k
# one, so a token threshold is a hidden assumption about which model is running. The thresholds sit
# low because compaction is itself an API call that needs working room — a warning has to arrive
# while there is still some left, not at the ceiling.
#
# WHY `unknown` IS ITS OWN BAND rather than folded into ok or crit: the state is not "fine" and it
# is not "at the ceiling", it is "I cannot scale this number", and asserting either neighbour would
# be untrue — ok goes silent at the worst reading the report can produce, and crit would pin every
# child of a new model generation to a permanent alarm until the list is updated, which is the
# glyph nobody reads. No consumer may treat it as healthy.
ctx_band() {
  case "$1" in
    ''|-) printf 'ok'; return ;;
    '?')  printf 'unknown'; return ;;
  esac
  if   [ "$1" -ge 80 ] 2>/dev/null; then printf 'crit'
  elif [ "$1" -ge 65 ] 2>/dev/null; then printf 'warn'
  else printf 'ok'; fi
}
