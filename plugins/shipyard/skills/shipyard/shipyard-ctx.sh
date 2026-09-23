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
#   CODEX_HOME                       Codex transcript root (default: $HOME/.codex)
#   CLAUDE_CONFIG_DIR / CLAUDE_HOME  Claude transcript root (default: $HOME/.claude)
#   SHIPYARD_CTX_WINDOW              context window in tokens, outranking both the transcript's
#                                    declared window and ctx_window's inference
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
# WHERE EACH KIND'S WINDOW COMES FROM, stated as a scope rather than an absolute, because the two
# kinds differ and a reader who adds a third should be corrected by this sentence:
#
#   codex   STATES it — WHEN a rollout resolves. Every token_count event carries
#           `model_context_window`, so ctx_codex_totals reads the real figure and returns before
#           ctx_window. When no rollout matches the worktree (CODEX_HOME resolved differently in
#           the child, a cwd that does not match) or none has written a token_count event yet,
#           the codex arm FALLS THROUGH to the pane path and is inferred exactly like claude,
#           ctx_window_unproven included. Driven, not reasoned: a codex slot with no rollout and
#           a pane carrying a token figure renders the same bound a claude child would.
#   claude  DECLARES it in the transcript's `attachment` model record, which ctx_declared_window
#           reads — but only when the id carries a window marker. Without one the window is
#           INFERRED from the peak (ctx_window) and ctx_window_unproven marks the readings where
#           that inference is a guess.
#   a new kind takes the claude arm by ctx_probe's own `elif`, so it inherits the inference
#           silently unless an arm is written for it — see shipyard-agent.sh, which says the same
#           about the rest of a new kind's wiring.
#
# That asymmetry is why a DECLARED PER-KIND DEFAULT was examined for #228 and rejected — but the
# codex half of the argument is NEAR-dead rather than dead, and the distinction is the fall-through
# above. A declared codex window would do nothing on the rollout path and would be live on the
# pane fall-through, where the figure it scaled would be a pane scrape this file already declares
# untrustworthy, and where it would be as much a guess as a claude one: codex windows are
# model-dependent too, and the suite's own fixture uses one that is on neither CTX_WINDOWS entry.
# What actually carries the rejection is the CLAUDE half, untouched by any of this: the window is
# a property of the MODEL rather than of the kind, and nothing pins the model at launch (adp_cmd
# renders no --model and shipyard-launch.sh records none), so a per-kind figure would be a guess
# wearing the clothes of a fact.
#
# ONE LIVE SIGNAL NAMES CLAUDE'S MODEL WITH ITS WINDOW MARKER, and ctx_declared_window reads it.
# The transcript carries an `attachment` record of `"type":"model"` whose `identity.modelId` keeps
# the `[1m]` suffix — `claude-opus-5[1m]`, `claude-opus-5-5[1m]` — beside a `marketingName` that
# spells the size out ("Opus 5.5 (1M context)"). Measured across three children's transcripts it
# sat at line 10 of every one, so it is available from the session's first turn, which is exactly
# where the peak inference is at its weakest. Cross-checked against the one case that can be
# settled independently: a child whose peak request carried 335521 tokens had PROVEN a window
# larger than 200000, and its marker read `[1m]` — the two agree.
#
# THE ABSENCE OF THE MARKER PROVES NOTHING, so it is read in one direction only. A default-window
# session carries no suffix, and neither would a future model whose default is large; treating a
# bare id as 200000 would be the same guess wearing the clothes of a fact, in the more dangerous
# direction. Without the marker this falls through to the peak inference, unchanged.
#
# The other two places checked for #228 ARE dead ends, recorded so the next reader does not
# re-check them:
#   * `message.model` OMITS the marker even for sessions that really are 1M: it reads the same
#     either way, which is why the check that matters is the `attachment` record above and not
#     this one. This is the fact that makes a per-kind default impossible FOR CLAUDE — the leg
#     that actually carries the rejection above; for codex it is near-dead rather than impossible;
#   * the `cost-state` record also carries the marker, but it is written once at session EXIT —
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
ctx_claude_transcript() {
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

ctx_agent() {
  local slot="$1" mb launch agent
  mb=$(shipyard_mailbox 2>/dev/null) || { printf 'claude'; return; }
  launch="$mb/launch-$slot.json"
  if [ -f "$launch" ]; then agent=$(jq -r '.agent // empty' "$launch" 2>/dev/null); fi
  printf '%s' "${agent:-claude}"
}

# Mtime in epoch seconds. GNU form FIRST: on GNU coreutils `stat -f` is --file-system (prints fs
# status to stdout AND exits non-zero), so a BSD-first order returns that garbage on Linux rather
# than falling through — which read as an empty transcript and a "—" context column. BSD stat
# rejects `-c` cleanly (stderr only, no stdout), so this order is correct on both.
ctx_mtime() {
  stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null
}

# Codex records the worktree cwd in session_meta. Pick the newest matching rollout;
# another Codex session rooted in the same worktree has the same ambiguity as Claude.
ctx_codex_transcript() {
  local slot="$1" cfg wt f mt newest="" newest_mt=0 first
  cfg="${CODEX_HOME:-$HOME/.codex}"
  wt="$ROOT/.claude/worktrees/ship-$slot"
  wt=$(cd "$wt" 2>/dev/null && pwd -P) || return 1
  [ -d "$cfg/sessions" ] || return 1
  while IFS= read -r f; do
    first=$(head -1 "$f" 2>/dev/null) || continue
    printf '%s\n' "$first" | jq -e --arg wt "$wt" \
      '.type == "session_meta" and .payload.cwd == $wt' >/dev/null 2>&1 || continue
    mt=$(ctx_mtime "$f") || continue
    if [ "$mt" -ge "$newest_mt" ] 2>/dev/null; then newest="$f"; newest_mt="$mt"; fi
  done < <(find "$cfg/sessions" -type f -name '*.jsonl' -print 2>/dev/null)
  [ -n "$newest" ] || return 1
  printf '%s' "$newest"
}

# "<current> <window>" from Codex's latest token_count event, or nothing.
ctx_codex_totals() {
  jq -r 'select(.type == "event_msg" and .payload.type == "token_count")
         | [(.payload.info.last_token_usage.total_tokens // 0),
            (.payload.info.model_context_window // 0)]
         | @tsv' "$1" 2>/dev/null \
    | awk '$1 + 0 > 0 && $2 + 0 > 0 { cur=$1; win=$2 }
           END { if (cur != "") print cur, win }'
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
# "API Error: 500 Internal server error", "Connection closed mid-response". Measured on the
# machine that found it: 25 of 290 transcripts ended on such a record, the largest hiding a real
# total of 501456 tokens. A ceiling-stalled child is MORE likely to end on one, not less — it has
# stopped producing real turns — so taking it at face value paints the most reassuring possible
# reading on exactly the children that are dead.
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

# The window the transcript DECLARES, in tokens, or nothing. The signal and its one-directional
# reading are argued at the per-kind block above; this is only the parse.
#
# The LAST such record wins, not the first: a session whose model is switched mid-run writes
# another one, and the newest is the model the next request will run on. `fromjson?` per line for
# the same reason ctx_totals uses it — a partially written final line must not take the whole read
# down with it.
#
# Only `[1m]` is recognised, because it is the only marker in use and a mapping table of marketing
# names is the part that would rot. A new marker appends a branch here.
ctx_declared_window() {
  local id
  id=$(jq -Rr 'fromjson? | select(.attachment.type == "model")
               | .attachment.identity.modelId // empty' "$1" 2>/dev/null | tail -1)
  case "$id" in
    *'[1m]') printf '%s' 1000000 ;;
  esac
}

# Known context window sizes, in tokens. DATA, deliberately kept out of the logic below, because
# this list is the part that rots and a list is cheap to correct.
#
# APPEND IN ASCENDING ORDER. ctx_window returns the FIRST entry that fits, so an out-of-order
# entry is silently ignored and the correction does nothing — with no error anywhere.
#
# THE FIRST ENTRY IS LOAD-BEARING BEYOND ORDERING, which appending does not change but inserting
# does: ctx_window_unproven measures against CTX_WINDOWS[0], so that entry is the boundary between
# "the peak has settled the window" and "the column prints a bound instead of a glyph". Adding a
# size ABOVE the current smallest leaves that boundary alone. Adding one BELOW it moves the
# boundary down, which lets a child alarm against a window the peak has not settled. An earlier
# draft measured against the LAST entry instead, where appending silently blinded every child
# below the new top; see ctx_window_unproven for what that cost and why the test moved.
CTX_WINDOWS=(200000 1000000)

# The band thresholds, as percentages. DATA for the same reason, and kept here rather than inline
# in ctx_band because TWO readings must agree on them: ctx_band turns a percentage into a glyph,
# and ctx_probe (below) asks whether a percentage is high enough to be worth asserting at all. A
# second copy of 65 would let those two drift, and the drift would be invisible — the guard would
# simply start scoping a different region than the alarm it guards.
CTX_WARN_PCT=65
CTX_CRIT_PCT=80

# The malformed-override warning, RAISED ONCE, FROM THE CALLER'S OWN SHELL.
#
# It cannot live in ctx_window. ctx_window is reached only as $(ctx_window ...) inside
# $(ctx_probe ...) — two nested command substitutions — so a "have I warned yet" flag set there is
# written in a grandchild shell that exits immediately, and the warning fires once per slot on
# every tick regardless. That is not a hypothesis: 15 probes through the real call shape emitted
# 15 warnings both before and after such a flag was added, while 15 direct calls emitted 1 —
# which is exactly why the flag looked like it worked. A per-slot warning defeats --only-changed,
# the flag SKILL.md calls what makes this monitor liveable.
#
# So the caller runs this ONCE, in its own shell, before the per-slot loop. ctx_window stays
# silent and pure, and the check becomes directly assertable — which the in-function flag was not:
# deleting it left the whole suite green, because every ctx_window call in t2 is its own subshell.
ctx_check_env() {
  if [ -n "${SHIPYARD_CTX_WINDOW:-}" ] && ! [[ "$SHIPYARD_CTX_WINDOW" =~ ^[1-9][0-9]*$ ]]; then
    echo "warning: SHIPYARD_CTX_WINDOW='$SHIPYARD_CTX_WINDOW' is not a positive integer of tokens — ignored, inferring instead" >&2
  fi
}

# The model's context window, in tokens, for the paths where no signal states it (the per-kind
# block above says which those are — claude always, codex on its fall-through). There it is
# INFERRED: a
# single request that carried N tokens cannot have run on a window smaller than N, so the window
# is the smallest known size that still fits the peak.
#
# WHAT THIS GUARANTEES, stated narrowly: the inference is exact when the true window IS one of the
# sizes listed above, and only then.
#
# THE COMFORTABLE VERSION IS FALSE, and it is the one you will re-derive if you do not read this
# paragraph. It goes: "an unlisted window resolves to the smallest known one that fits, so it
# over-warns rather than under-warns, which is the safe direction." That was written into this
# design's own rationale twice before review caught it, and it is wrong in both directions. A real
# 400k window whose peak has passed 200000 infers 1000000, so a child at 380k — 95%, effectively
# at the ceiling — reads 38%, an UNDER-warning. A window smaller than the smallest listed
# under-warns the same way. There is no way to be safe about a size nobody has declared; what
# there is, is SHIPYARD_CTX_WINDOW, and a percentage that always travels next to the raw token
# count it came from, so a wrong inference can be caught by eye.
#
# One thing that IS bounded, and is why the PAST-THE-LIST cause of `?` is rare rather than
# routine: a single request's usage sum cannot exceed the window it ran on, because prompt plus
# output is what the window measures. Measured across 291 transcripts, the largest single-record
# sum was 999567 and none exceeded 1000000. So a total past the top of this list means the list is
# out of date, not that a 1M child is near its ceiling — the ceiling case bands crit long before it
# gets there. (That last clause still holds after ctx_window_unproven: a peak past the smallest
# listed size settles the window, so 800000 bands crit as it always did. Only the scope of the
# first clause moved — the OTHER cause of `?` is not rare, it is the standing state of any child
# whose peak has not settled the window, and permanent for one whose window is the smallest listed
# size. Scoping this sentence rather than deleting it is deliberate: the bound it states is what
# makes the past-the-list reading rare, and that is still true.)
#
# SHIPYARD_CTX_WINDOW wins unconditionally, INCLUDING DOWNWARDS: someone running a window smaller
# than anything listed has to be able to say so, and no inference may overrule them. A value that
# is not a positive integer of tokens is REFUSED OUT LOUD rather than ignored — a silently dead
# escape hatch is worse than none, because the operator believes the band they are looking at is
# the one they configured. The refusal lives in ctx_check_env, the precedence in ctx_window.
ctx_window() {
  local peak="$1" declared="${2:-}" w
  if [[ "${SHIPYARD_CTX_WINDOW:-}" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$SHIPYARD_CTX_WINDOW"; return
  fi
  # A declared window is EVIDENCE, so it outranks the inference — but never the operator, who must
  # still be able to say a smaller size downwards. Hence this sits below the override, not above.
  if [[ "$declared" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s' "$declared"; return
  fi
  for w in "${CTX_WINDOWS[@]}"; do
    if [ "$peak" -le "$w" ] 2>/dev/null; then printf '%s' "$w"; return; fi
  done
  # Past the end of the list: no known window fits. Return the largest so the caller can see the
  # total exceed it and say so, rather than inventing a size.
  printf '%s' "${CTX_WINDOWS[${#CTX_WINDOWS[@]}-1]}"
}

# ctx_window_unproven <peak> — rc 0 when ctx_window's answer for that peak is a GUESS between
# listed sizes rather than something the peak established.
#
# The inference proves upward and only upward: a request that carried N tokens cannot have run on
# a window smaller than N. So a peak that has passed 200000 has PROVEN the window is not 200000,
# and picking the next listed size up is a deduction. A peak that has NOT passed the smallest
# listed size has proven nothing at all, and "smallest that fits" is then a choice among the
# listed candidates, made by picking the first one.
#
# The test is THE SMALLEST LISTED SIZE, not "is ctx_window's answer the last entry?". Those look
# equivalent on a two-entry list and are not, and the difference is the review finding that caught
# the first draft of this function: "not the last entry" means that APPENDING a size retroactively
# unproves every child below it. Measured on the draft — appending 2000000 turned a real
# `90% · 900k` crit into a bare `?` for every 1M child at 65-100%, because only the topmost class
# could still be proven. The report's own UNSCALED block prints "add the size to CTX_WINDOWS" as a
# remedy, so the instrument would have been instructing the edit that blinded it. The trigger was a
# source edit, so no shipped list was ever affected; the shape is what mattered.
#
# It degenerates correctly at both ends. A single-entry list is never unproven — hence the length
# guard, without which every reading below the sole window would be unproven and the whole column
# would withhold at once. A peak past the whole list is likewise not unproven, which leaves
# ctx_probe's >100% branch to speak for it.
#
# An explicit SHIPYARD_CTX_WINDOW is never unproven: the operator stated the window, and this
# file does not second-guess a stated fact. That mirrors ctx_window's own precedence, so the
# override continues to win in both directions and to leave the `?` band immediately.
#
# THE CASE IT CANNOT SEE, because no evidence reaches it: a window that is not on the list at all.
# A real 400k session whose peak has passed 200000 lands on 1000000 and reads as proven, because
# relative to the listed candidates it is. That under-warning is the one SHIPYARD_CTX_WINDOW exists
# for and it is unchanged by this function.
#
# THE CASE IT SEES FOREVER, which is the other half of the same coin and is NOT a defect to be
# fixed here: a child whose real window IS the smallest listed size can never prove it, because a
# single request's usage sum cannot exceed the window it ran on (the bound stated at ctx_window).
# So its peak never passes CTX_WINDOWS[0] and this returns true for the child's whole life. That is
# why ctx_probe prints a BOUND OVER THE LISTED CANDIDATES rather than nothing: a permanent `?`
# carrying no figure
# would leave that child's operator with no reading at all, and it is the commonest deployment.
ctx_window_unproven() {
  local peak="$1" declared="${2:-}"
  [[ "${SHIPYARD_CTX_WINDOW:-}" =~ ^[1-9][0-9]*$ ]] && return 1
  # A window the transcript named is not a choice among candidates, so it leaves the `?` band for
  # the same reason the override does: this file does not second-guess a stated fact.
  [[ "$declared" =~ ^[1-9][0-9]*$ ]] && return 1
  [ "${#CTX_WINDOWS[@]}" -gt 1 ] || return 1
  [ "$peak" -le "${CTX_WINDOWS[0]}" ] 2>/dev/null
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
#   -   nothing could be measured                 -> band ok, display "—"
#   ?   measured, but no window to assert it with  -> band unknown, display below
# Collapsing those two into one sentinel is what made the alarm switch OFF at the ceiling: with
# an override of 400000, 400001 tokens banded crit and 450000 banded ok.
#
# The branches below raise `?` separately, and they DISPLAY differently on purpose, because the
# operator's remedy differs and the row is where they meet it:
#   past every listed window   -> the bare count  (`1400k`)      — add the size to CTX_WINDOWS
#   window not yet pinned down -> a bound         (`<=92% · 185k`) — name it with the override
# The full argument for each lives at its own branch. What holds for both is that neither may
# print a percentage as though it were measured.
ctx_probe() {
  local slot="$1" pane="$2" agent f tot cur peak win pct declared=""
  agent=$(ctx_agent "$slot")
  if [ "$agent" = codex ]; then
    if f=$(ctx_codex_transcript "$slot"); then tot=$(ctx_codex_totals "$f"); fi
    if [ -n "${tot:-}" ]; then
      cur=${tot%% *}; win=${tot##* }
      pct=$(awk -v c="$cur" -v w="$win" 'BEGIN{ printf "%d", (c * 100) / w }')
      if [ "$pct" -gt 100 ] 2>/dev/null; then printf '%s %s' '?' "$(ctx_human "$cur")"; return; fi
      printf '%s %s%% · %s' "$pct" "$pct" "$(ctx_human "$cur")"
      return
    fi
  elif f=$(ctx_claude_transcript "$slot"); then
    tot=$(ctx_totals "$f")
    declared=$(ctx_declared_window "$f")
  fi
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
  win=$(ctx_window "$peak" "$declared")
  pct=$(awk -v c="$cur" -v w="$win" 'BEGIN{ printf "%d", (c * 100) / w }')
  # NEVER PRINT A PERCENTAGE ABOVE 100. A total larger than the window it is measured against is
  # not a reading, it is a contradiction — the window list is out of date, or an override is set
  # too low. Either way what is missing is KNOWLEDGE, and it must look like missing knowledge: the
  # raw figure alone, no percentage.
  if [ "$pct" -gt 100 ] 2>/dev/null; then printf '%s %s' '?' "$(ctx_human "$cur")"; return; fi
  # A GLYPH IS AN ASSERTION, SO IT NEEDS A WINDOW THE PEAK ESTABLISHED — but withholding the
  # FIGURE as well would punish the commonest deployment, so this prints a BOUND instead.
  #
  # Where ctx_window had to choose between listed sizes (ctx_window_unproven), the percentage is
  # an assumption, and one that would raise a glyph is an assumption the operator is asked to act
  # on. So the band becomes `?` — `unknown`, which no consumer may read as healthy — and the
  # display becomes `<=<pct>% · <count>`.
  #
  # THE BOUND IS THE TIGHTEST READING THE LISTED CANDIDATES ALLOW, and that is the whole of what
  # `<=` claims — it costs nothing to compute, because ctx_window already returns the SMALLEST
  # listed size the peak fits, so scaling against it yields the LARGEST percentage any listed
  # candidate could produce. For a child whose real window IS that smallest size the bound is the
  # reading itself; for a child on a larger LISTED one it overstates, and the raw count beside it
  # is what tells them apart. As the peak grows past the smallest size the window becomes a
  # deduction, this branch stops firing, and the ordinary `<pct>% · <count>` reading returns.
  #
  # IT IS NOT AN UPPER BOUND ON THE TRUTH, and the comfortable version of this sentence — "the
  # child is at most that" — is FALSE. It is bounded over the LIST, and ctx_window's own paragraph
  # already says why that is not the same thing: a window smaller than the smallest listed one
  # under-warns. Worked, because this is the third time the comfortable version has been written
  # into this file's design and the second time in this change alone: a real 150000-token window
  # carrying 140000 takes CTX_WINDOWS[0]=200000, prints `<=70%`, and is actually at 93%. The `<=`
  # is a bound relative to the candidates this file knows, nothing more, and SHIPYARD_CTX_WINDOW
  # is what closes the gap for anyone whose size is not on the list.
  #
  # WHY A BOUND RATHER THAN NOTHING. A bare `?` is right for a figure past every listed window —
  # there no candidate fits, so no bound over the list exists at all — but wrong here, where one
  # does. It matters most for the population that never leaves this branch: a child whose window
  # IS the smallest listed size (ctx_window_unproven's closing note). Under a bare `?` that
  # operator gets an unscaled number for the child's whole life and must go and configure
  # something; under the bound they get `<=92% · 185k`, which is the tightest reading the listed
  # candidates allow, needs no configuration act, and is actionable on sight. The two `?` causes therefore RENDER DIFFERENTLY, and that is
  # deliberate — a bare count means "past every listed window, add the size", a bounded one means
  # "the window is not pinned down, name it" — so the operator can tell from the row which remedy
  # is theirs.
  #
  # This is not the column falling silent, which is the failure it was rebuilt to remove. What it
  # removes is the FALSE PRECISION — a 1M child reading `🛑 81% · 162k` through its normal early
  # life, an alarm on the common path that an operator learns to ignore and that has invited
  # compacting healthy children mid-review.
  #
  # Gated on ctx_band rather than on CTX_WARN_PCT directly, so "would this raise a glyph?" is ONE
  # question with one owner. Gating on the warn threshold alone was correct only while the two
  # thresholds stayed in order: with CTX_WARN_PCT=90 and CTX_CRIT_PCT=80 a reading of 86 skipped
  # this branch and then banded crit against a window nothing established — the exact assertion
  # this branch exists to forbid, reachable by a config edit and by no test.
  if [ "$(ctx_band "$pct")" != ok ] && ctx_window_unproven "$peak" "$declared"; then
    printf '%s <=%s%% · %s' '?' "$pct" "$(ctx_human "$cur")"; return
  fi
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
#
# TWO READINGS REACH IT, and ctx_probe is where they are told apart, not here — this function sees
# only the `?` sentinel. A total past every listed window, and a total high enough to alarm against
# a window ctx_window had to guess at (ctx_window_unproven). They share a band because they share
# what is missing — a window to assert against. They do NOT share the remedy, and an earlier draft
# of this file said they did: naming the window clears either, but ADDING a CTX_WINDOWS entry
# clears only the past-the-list one and cannot clear a bound, whose size is already listed.
# ctx_probe renders the two differently and shipyard-report.sh's block dispatches on that display,
# so the distinction lives in one place rather than being restated here.
ctx_band() {
  case "$1" in
    ''|-) printf 'ok'; return ;;
    '?')  printf 'unknown'; return ;;
  esac
  if   [ "$1" -ge "$CTX_CRIT_PCT" ] 2>/dev/null; then printf 'crit'
  elif [ "$1" -ge "$CTX_WARN_PCT" ] 2>/dev/null; then printf 'warn'
  else printf 'ok'; fi
}
