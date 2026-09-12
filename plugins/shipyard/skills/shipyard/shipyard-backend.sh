#!/usr/bin/env bash
# shipyard-backend.sh — terminal-backend abstraction for the `shipyard` skill. Source only.
#
# A child ship session lives in a terminal the parent watcher can read from and type
# into. Two backends provide that surface:
#
#   agterm (DEFAULT) — a native macOS terminal driven over a control socket by
#                      `agtermctl`. Children are SESSIONS named `ship-<slot>` inside a
#                      WORKSPACE named `<repo>-ai`.
#   tmux             — the original backend. Children are WINDOWS named `ship-<slot>`
#                      inside a session named `<repo>`.
#
# Pick one with SHIPYARD_BACKEND=agterm|tmux|auto. The default is `auto`: agterm whenever an
# agterm app is answering its control socket, else tmux, and a hard error when NEITHER
# is available — `shipyard` has no third way to reach a child. Every other script in this skill
# talks only to the shipyard_* functions below and never to agtermctl/tmux directly, so a slot
# behaves identically on both.
#
# THE BACKEND MECHANICS NO LONGER LIVE HERE. They are the one shared agent-console driver
# (shared/driver/agent-driver.sh, vendored beside this file as agent-driver.sh and kept
# byte-identical to its source by scripts/sync-driver.sh + the repo gate, check 11). What was a
# second hand-synced copy of that backend code is now a thin shipyard ADAPTER over it: this file
# maps shipyard's own knobs onto the driver's caller-set variables, keeps shipyard's `ship-<slot>`
# session-name template, and lets the shared ops (backend, container, target, launch, read, type,
# submit, kill, focus) delegate to the matching drv_* one. If a backend needs fixing, fix it in the
# shared driver; there is no longer a second copy here to keep in step.
#
# The container name is the ONE place the two backends differ, and the ONE place shipyard differs
# from council — so it is expressed entirely through the driver's caller-set vars (mapped below):
#   agterm: workspace `<parent's workspace>-ai`, falling back to `<repo>-ai`
#           (the `-ai` suffix keeps agent sessions in their own workspace, away from the
#            human's own tabs)
#   tmux:   session   `<repo>`      (unchanged, so ship windows coexist with your own)
# The agterm name is derived ONCE and then PINNED in the shipyard mailbox, because it depends on
# where the caller was sitting. Re-deriving it per call would mean a report run from a different
# workspace resolves a different container and truthfully reports that there are no children — the
# worst possible lie for a monitor.
#
# What STAYS in shipyard, because the shared driver has no twin for it: the backend precheck
# (shipyard_backend_check), the slot enumeration (shipyard_slots and its helpers), the Escape key
# (shipyard_esc), the sidebar note / desktop notify / empty-workspace prune, the container
# kind/unpin, and the report-facing shipyard_slot_addr / shipyard_where / shipyard_peek_hint. Only
# the shared backend ops move.

# --- map shipyard's knobs onto the driver's, then source it --------------------------------
# The driver resolves and caches the backend ONCE, at source time, so DRV_BACKEND must already
# carry shipyard's choice or the cache would answer for `auto` whatever SHIPYARD_BACKEND said.
# SHIPYARD_BACKEND is process-stable, so this single mapping reproduces shipyard_backend's old
# resolve-and-cache-on-first-call exactly, including the `invalid` a bad value used to yield.
#   DRV_BACKEND          <- SHIPYARD_BACKEND (default auto).
#   DRV_CONTAINER_SUFFIX  "-ai": shipyard keeps its agent sessions in a `<workspace>-ai` container.
# DRV_REPO_KEY, DRV_CONTAINER_OVERRIDE are set just below (they need the sourced driver's resolved
# backend and shipyard's own repo-key rule); DRV_CONTAINER_PIN_DIR is set at the end of
# shipyard-lib.sh, once shipyard_mailbox is defined. None of these are exported: the old code put
# nothing of the kind into a launched child's or the tmux server's environment, and neither does
# this.
DRV_BACKEND="${SHIPYARD_BACKEND:-auto}"
DRV_CONTAINER_SUFFIX="-ai"
# shellcheck source=agent-driver.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/agent-driver.sh"

# --- naming: the repo-key rule that is shipyard's, not the driver's -------------------------
# shipyard sanitises ':' -> '_' in the stem and derives its container from a git repo — DISTINCT
# from council, which takes the driver's forgiving default (basename of the git top-level, or of
# $PWD outside a repo). shipyard injects its own DRV_REPO_KEY, which the driver reads only on the
# repo-stem fallback path (no live agterm workspace), so the ':' -> '_' transform holds wherever a
# container is actually derived (t8 asserts it). One edge is NOT reproduced exactly: outside a git
# repo the old code failed (empty + exit 1), whereas an empty DRV_REPO_KEY here lets the driver
# fall back to the pwd basename. shipyard is a per-repo tool (worktrees + a .git mailbox), so this
# surfaces only if a report is run outside every repo — cosmetically naming a pwd-based container in
# its "no live terminals" line; a same-named terminal container would then read as ship slots.
# Reproducing the failure exactly would mean re-duplicating the driver's override/pin/derive
# precedence in this adapter — the very duplication this migration removes — so it is left as is.
shipyard_repo_key() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "error: not inside a git repository — shipyard derives its container name from the repo" >&2
    return 1; }
  basename "$root" | tr ':' '_'
}
DRV_REPO_KEY=$(shipyard_repo_key 2>/dev/null) || DRV_REPO_KEY=""

# shipyard's explicit container override is backend-specific: SHIPYARD_WORKSPACE names the agterm
# workspace, SHIPYARD_SESSION the tmux session. The driver takes a single DRV_CONTAINER_OVERRIDE, so
# resolve shipyard's pair against the now-cached backend and hand the driver the one that applies.
# Both are process-stable env vars, exactly as the old shipyard_container read them.
case "$(drv_backend)" in
  agterm) DRV_CONTAINER_OVERRIDE="${SHIPYARD_WORKSPACE:-}" ;;
  tmux)   DRV_CONTAINER_OVERRIDE="${SHIPYARD_SESSION:-}" ;;
esac

# --- backend + container: thin delegations to the shared driver -----------------------------
shipyard_backend() { drv_backend; }
shipyard_shq()     { drv_shq "$1"; }

# The container keeps shipyard's cross-process cache: _SHIPYARD_CONTAINER is resolved once in the
# main shell (end of shipyard-lib.sh, after the mailbox is defined) and every $(shipyard_container)
# fork inherits it, so a hot report loop neither re-reads the pin file nor re-queries agterm. With
# no cache the delegation is the driver's own resolve (override -> pin -> derive), in that order.
shipyard_container() {
  [ -n "${_SHIPYARD_CONTAINER:-}" ] && { printf '%s' "$_SHIPYARD_CONTAINER"; return 0; }
  drv_container
}
shipyard_container_pin() { drv_container_pin; }

# The refusal shipyard's own surface shares (the delegating ops get the driver's equivalent). Its
# message names SHIPYARD_BACKEND and the agterm/tmux install steps, so an unusable backend can never
# read as a no-op. Re-resolve rather than reading $_DRV_BE: every dispatch reaches us from inside a
# `case "$(shipyard_backend)"`, i.e. a SUBSHELL, so an assignment there never reached this shell.
_shipyard_no_backend() {
  if [ "$(shipyard_backend)" = invalid ]; then
    echo "error: SHIPYARD_BACKEND must be agterm, tmux or auto (got: ${SHIPYARD_BACKEND:-})" >&2
  else
    echo "error: no terminal backend available — shipyard cannot reach a child session." >&2
    echo "       agterm: install agtermctl (agterm ▸ Help ▸ Install Command Line Tool…) and start the app;" >&2
    echo "       tmux:   brew install tmux, then run with SHIPYARD_BACKEND=tmux." >&2
  fi
  return 1
}

# Fail early and loudly rather than at the first weird empty capture. No driver twin: the driver has
# no precheck of its own, so this stays shipyard's, with shipyard's own remediation text and jq need.
shipyard_backend_check() {
  case "$(shipyard_backend)" in
    agterm)
      command -v agtermctl >/dev/null 2>&1 || {
        echo "error: agtermctl is not on PATH (agterm ▸ Help ▸ Install Command Line Tool…)" >&2
        echo "       or run with SHIPYARD_BACKEND=tmux" >&2; return 1; }
      agtermctl version >/dev/null 2>&1 || {
        echo "error: no agterm is answering the control socket (${AGTERM_SOCKET:-default})" >&2
        echo "       start agterm, or run with SHIPYARD_BACKEND=tmux" >&2; return 1; }
      command -v jq >/dev/null 2>&1 || { echo "error: the agterm backend needs jq" >&2; return 1; } ;;
    tmux)
      command -v tmux >/dev/null 2>&1 || { echo "error: tmux is not on PATH" >&2; return 1; } ;;
    *) _shipyard_no_backend; return 1 ;;
  esac
}

# shipyard_container_unpin — forget the pinned name, so the next launch derives a fresh one. Only
# correct once nothing is left in the old container, which is why shipyard-down.sh calls it solely
# after `shipyard_continuity_cleanup_last_slot` has PROVEN the fleet empty.
#
# IT CLEARS ONLY THE RESOLVED BACKEND'S PIN, which is the rule that was already here, and the
# reuse of `_drv_pin_file` that goes with it: unpin removes exactly what `drv_container_pin` wrote.
#
# That is worth a note because this change spent two review rounds getting back to it. Reading the
# pin's NAME as evidence (shipyard_backend_pinned_elsewhere, below) made a leftover pin look like
# litter worth sweeping, so unpin was widened to clear every backend's. It was wrong twice, in the
# same direction both times:
#   * resolved tmux, pinned agterm — the extra removal deletes the evidence the report reads, so
#     the next blip exits 0 over live children. #61, reintroduced by its own fix.
#   * resolved tmux, BOTH pinned — patched with an early return when the pins disagree, which does
#     not fire here (tmux IS pinned). The justification written for it was circular: the agterm pin
#     is invisible to the disagreement check only BECAUSE the tmux pin sits beside it, and this very
#     call is about to delete that one. Afterwards the leftover is exactly what the check reads.
#
# The rule that covers all three configurations without a guard is the original one: the caller
# proved that the backend it RESOLVED holds no slots and learned nothing about the other, so clear
# that one and leave the other alone. A pin whose fleet ended some other way does outlive it — and
# that is fail-CLOSED (a refusal that names itself and says what to run), which is the direction to
# be wrong in.
shipyard_container_unpin() {
  local f; f=$(_drv_pin_file 2>/dev/null) && rm -f "$f" 2>/dev/null
  return 0
}

# What kind of thing that container is, for messages. No driver twin.
shipyard_container_kind() {
  case "$(shipyard_backend)" in
    agterm) printf 'workspace' ;;
    tmux)   printf 'session' ;;
    *) _shipyard_no_backend; return 1 ;;
  esac
}

# --- agterm internals ----------------------------------------------------------
# One compact JSON object per session in our workspace. Stays in shipyard: the driver resolves ONE
# session by name (drv_target); enumerating every session in the container is shipyard's own need
# (shipyard_slots), with no driver twin.
_shipyard_at_sessions() {
  local tree
  tree=$(agtermctl tree --json 2>/dev/null) || return 1
  printf '%s' "$tree" | jq -c --arg ws "$(shipyard_container)" '
    if .ok != true or (.result.tree.workspaces | type) != "array"
      or (all(.result.tree.workspaces[];
        type == "object" and (.name | type) == "string"
        and (.sessions | type) == "array"
        and all(.sessions[];
          type == "object" and (.id | type) == "string" and (.id | length) > 0
          and (.name | type) == "string")) | not)
    then error("invalid agterm tree")
    else .result.tree.workspaces[] | select(.name == $ws) | .sessions[]
    end
  ' 2>/dev/null
}

# --- the API every other script uses -------------------------------------------
# The shared ops delegate; the session-name template `ship-<slot>` is resolved here and handed to
# the driver, which re-derives the opaque backend handle from it on every call.

# shipyard_target <slot> — opaque handle for the backend; exit 1 when the slot has no live
# terminal. agterm: the session UUID. tmux: `<session>:<index>`.
shipyard_target()  { drv_target "ship-$1"; }

# shipyard_capture <slot> — the child's visible screen as plain text.
shipyard_capture() { drv_read "ship-$1"; }

# shipyard_type <slot> <text> — inject text as keystrokes WITHOUT submitting.
shipyard_type()    { drv_tell "ship-$1" "$2"; }

# shipyard_submit <slot> [alt] — press Return. `alt` asks for the keypad Return, which some
# Claude Code builds want instead; agterm delivers a real newline either way.
shipyard_submit()  { drv_submit "ship-$1" "${2:-}"; }

# shipyard_launch <slot> <cwd> <launcher-script> — start a child terminal running the launcher.
# drv_launch echoes the session name on success; shipyard_launch never wrote to stdout and its
# caller runs it uncaptured, so swallow that echo while preserving the exit status it branches on.
shipyard_launch()  { drv_launch "ship-$1" "$2" "$3" >/dev/null; }

# shipyard_kill <slot> — tear the child's terminal down (teardown after a merge).
shipyard_kill()    { drv_kill "ship-$1"; }

# shipyard_focus <slot> — put the human on that child.
shipyard_focus()   { drv_focus "ship-$1"; }

# shipyard_slot_addr <slot> — the SHORT column value for the report ("win" on tmux, the
# session-id prefix on agterm). Empty + exit 1 when the slot has no terminal ON THE BACKEND THIS
# RUN RESOLVED, which is not the same fact as the child being gone (shipyard_signal_class tells
# the two apart, and every caller that reports an absence to a human must ask it). No driver twin.
shipyard_slot_addr() {
  local t; t=$(shipyard_target "$1") || return 1
  case "$(shipyard_backend)" in
    agterm) printf '%s' "$(printf '%s' "$t" | cut -c1-8 | tr '[:upper:]' '[:lower:]')" ;;
    tmux)   printf '%s' "${t##*:}" ;;
    *) _shipyard_no_backend; return 1 ;;
  esac
}

# shipyard_where <slot> — human-readable location, for log lines and errors. No driver twin.
shipyard_where() {
  local t
  if ! t=$(shipyard_target "$1"); then printf '%s/ship-%s (no live terminal)' "$(shipyard_container)" "$1"; return 1; fi
  case "$(shipyard_backend)" in
    agterm) printf '%s/ship-%s' "$(shipyard_container)" "$1" ;;
    tmux)   printf '%s' "$t" ;;
    *) _shipyard_no_backend; return 1 ;;
  esac
}

# shipyard_peek_hint <slot> — a command the human can paste to look inside the child. No driver twin.
shipyard_peek_hint() {
  local t; t=$(shipyard_target "$1") || { printf 'no live terminal for ship-%s' "$1"; return 1; }
  case "$(shipyard_backend)" in
    agterm) printf "agtermctl session text --target %s --lines 20" "$t" ;;
    tmux)   printf "tmux capture-pane -t '%s' -p | tail -20" "$t" ;;
    *) _shipyard_no_backend; return 1 ;;
  esac
}

# shipyard_slots — every slot that currently has a terminal. No driver twin (the driver resolves
# one session by name; enumerating them is shipyard's own).
#
# THE EXIT STATUS IS PART OF THE CONTRACT, and it carries the one distinction this change is about:
# rc 0 means the container ANSWERED (its slot list follows, possibly empty), non-zero means it did
# not answer at all. `shipyard-down.sh` consults it today — it refuses to drop the container pin on
# anything but a proven-empty fleet — and `shipyard-report.sh` now does too. ("Today", not "always":
# the original down.sh unpinned on `[ -z "$(shipyard_slots)" ]`, i.e. read a failed enumeration as
# empty, and the proof-of-empty gate arrived later with shipyard_continuity_cleanup_last_slot.)
#
# THE THIRD CALLER STILL DISCARDS IT. `shipyard_admission_slot_count` pipes this function into
# `wc -l`, so a socket that answers `version` and fails `tree` reads as zero live slots and the
# SHIPYARD_MAX_SLOTS cap is silently bypassed — the same defect one gate over. That is out of this
# change's scope and filed separately; it is named here so the next reader does not infer from the
# paragraph above that every caller now branches on the status.
#
# The agterm arm used to be a bare pipeline, so its status was `sed`'s, which is 0 whether or not
# anything upstream survived. It happened to work because both callers that CONSULT the status set
# `pipefail`: an ambient option in the caller decided whether a failed enumeration was
# distinguishable from an empty container. Capture it explicitly instead, so no later caller
# inherits the wrong answer by forgetting an option it never knew it needed.
shipyard_slots() {
  local raw
  case "$(shipyard_backend)" in
    agterm)
      # Non-zero on a dead control socket AND on a tree that fails the shape assertion inside
      # _shipyard_at_sessions; empty output with rc 0 when the workspace simply holds no sessions.
      raw=$(_shipyard_at_sessions) || return 1
      printf '%s' "$raw" | jq -r '.name // empty' 2>/dev/null | sed -n -E 's/^ship-(.+)$/\1/p' ;;
    tmux)   _shipyard_tmux_slots ;;
    *) _shipyard_no_backend; return 1 ;;
  esac
}

# shipyard_backend_pinned_elsewhere — echoes the backend(s) this fleet was actually launched on,
# and returns 0 ONLY when a pin exists and NONE of them is the backend this process resolved.
#
# There is no separate backend pin file to maintain. The driver's container pin is already named
# `container-<backend>`, so the set of pin files present IS the record of which backends this
# mailbox has launched a fleet on. Reading that name keeps one fact in one place, and it needs
# nothing from the driver's backend resolution — which is cached at source time, before shipyard's
# pin directory is set (shipyard-lib.sh, at the end), so a pin consulted there would have to move
# that whole ordering. That is a cost argument, not an impossibility: the mailbox derives from
# `git rev-parse --git-common-dir` and could be computed earlier.
#
# THE SEAM, stated because this file now spells a path the driver owns. `_drv_pin_file` names only
# the CURRENT backend, so it cannot answer "which pins exist"; both sites here therefore write
# `container-<b>` themselves, duplicating the driver's template. A rename in the driver would make
# this read nothing and fail OPEN — back to the incident, silently. The right home is a
# `drv_pins_present` in shared/driver, vendored into both plugins; it is not there yet because
# council, checked rather than assumed, has no empty-answer conclusion to protect (its verdict is
# computed from the room's on-disk log, and `council say` already refuses per peer), so the shared
# module would have exactly one consumer today. Move it the moment that stops being true.
#
# WHY IT MATTERS. `SHIPYARD_BACKEND=auto` decides per PROCESS by probing the agterm control socket,
# so a socket that blips for one tick resolves tmux for that tick — and a tmux session named after
# the repo holds no ship windows, correctly and uselessly. Nothing is wrong with either answer;
# what was wrong was reading "I looked somewhere else and found nothing" as "there is nothing".
shipyard_backend_pinned_elsewhere() {
  local d b f now any="" found=""
  d="${DRV_CONTAINER_PIN_DIR:-}"
  [ -n "$d" ] && [ -d "$d" ] || return 1
  now=$(shipyard_backend)
  for b in agterm tmux; do
    f="$d/container-$b"
    [ -f "$f" ] || continue
    any="${any:+$any and }$b"
    [ "$b" = "$now" ] && found=1
  done
  [ -n "$any" ] || return 1        # nothing was ever launched from this mailbox — no disagreement
  [ -n "$found" ] && return 1      # the resolved backend is one of them — no disagreement
  printf '%s' "$any"
}

# shipyard_signal_class [<enum-rc>] — MAY AN ABSENCE BE BELIEVED?
#
# Echoes "<class><TAB><why>" and returns 1 when it may not: the question was not answered, so any
# negative drawn from it would be a guess. Echoes nothing and returns 0 when it may.
#
#   unreachable  the backend did not answer when asked which terminals exist.
#   elsewhere    it answered, but this fleet was launched on a DIFFERENT backend (the pin says so).
#
# The two facts are the ones `shipyard-report.sh` already corroborates its empty answer with, and
# they are read here through the same two functions — `shipyard_slots`' exit status and
# `shipyard_backend_pinned_elsewhere`. Nothing new is probed and no second record is invented: the
# per-slot callers were the level of the skill that still had no way to ask.
#
# WHY IT IS A PARAMETER. `shipyard-report.sh` must classify the status of the list it PRINTED, not
# of a second enumeration that could disagree with it, so it captures the rc once and passes it;
# `shipyard-tell.sh` and `shipyard-compact.sh` have no such list and let this probe. One optional
# argument covers both, which is why this is one function and not two.
#
# NOT USED AS EVIDENCE: the slot's worktree. A worktree outlives its terminal by design — that is
# the state of every child whose terminal was killed but not torn down — so reading its presence as
# "the child may still be alive" would raise the alarm on the commonest healthy case, which
# AGENTS.md names as costing more than the bug it guards. The per-slot launch record that WOULD
# carry that evidence belongs with the pin-staleness work, filed separately.
shipyard_signal_class() {
  local rc="${1:-}" pe TAB
  TAB=$(printf '\t')
  if [ -z "$rc" ]; then rc=0; shipyard_slots >/dev/null 2>&1 || rc=$?; fi
  if [ "$rc" != 0 ]; then
    printf 'unreachable%sthe %s backend did not answer when asked which terminals exist' \
      "$TAB" "$(shipyard_backend)"
    return 1
  fi
  pe=$(shipyard_backend_pinned_elsewhere) || pe=""
  if [ -n "$pe" ]; then
    printf 'elsewhere%sthis run resolved %s, but this fleet was launched on %s' \
      "$TAB" "$(shipyard_backend)" "$pe"
    return 1
  fi
  return 0
}

# shipyard_absence_report <slot> — say, on stderr, why that slot has no terminal.
#
# Returns 0 when the absence is CORROBORATED (the backend answered and does not have it — the
# child really is gone) and 1 when it is UNRESOLVED. Callers map that onto their own exit codes;
# it is one function rather than a paragraph in each script so the two cannot drift apart.
#
# THE DEFECT IT CLOSES. `shipyard_target` resolves against whatever backend THIS process picked,
# and `SHIPYARD_BACKEND=auto` picks per process by probing the agterm control socket. During a blip
# the honest answer is "no terminal on the backend I resolved", not "the child is gone" — and the
# supervising agent acts on what it is told, so the reasonable next moves after "gone" are to tear
# the slot down or relaunch it, against a child that is mid-review and alive in the other backend.
# An unanswerable question must never produce a confident negative.
shipyard_absence_report() {
  local slot="$1" sig class why pin rc=0 TAB
  TAB=$(printf '\t')
  sig=$(shipyard_signal_class) || rc=$?
  if [ "$rc" = 0 ]; then
    echo "error: no live terminal \`ship-$slot\` in $(shipyard_container_kind) \`$(shipyard_container)\`." >&2
    echo "       the $(shipyard_backend) backend answered and does not have it, so the child is gone." >&2
    return 0
  fi
  class=${sig%%$TAB*}; why=${sig#*$TAB}
  echo "error: cannot tell whether \`ship-$slot\` is alive, so nothing was sent." >&2
  echo "       $why." >&2
  echo "       Not finding its terminal is therefore not the same as finding it is gone: do NOT tear" >&2
  echo "       this slot down or relaunch it on this answer. The report's \`🛑 NO SIGNAL\` block" >&2
  echo "       refuses the same inference one level up, and means the same thing here." >&2
  case "$class" in
    unreachable)
      echo "       If the backend is simply down, start it and re-run; nothing was lost." >&2
      echo "         agterm: check the app is running and answering \`agtermctl version\`." >&2
      echo "         tmux:   check \`tmux ls\`." >&2 ;;
    elsewhere)
      # Asked a second time rather than parsed back out of the message above: re-reading two file names costs
      # nothing, and recovering a value from prose couples this arm to that sentence's wording.
      pin=$(shipyard_backend_pinned_elsewhere) || pin=""
      echo "       \`SHIPYARD_BACKEND=auto\` decides per PROCESS, so one failed socket probe sends this" >&2
      echo "       run to the other backend, where this repo's container is empty for entirely" >&2
      echo "       correct reasons." >&2
      [ -n "$pin" ] && echo "       Pin it for this shell and re-run: SHIPYARD_BACKEND=$pin" >&2 ;;
  esac
  return 1
}

_shipyard_tmux_slots() {
  local out
  if out=$(tmux list-windows -t "$(shipyard_container)" -F '#{window_name}' 2>&1); then
    printf '%s\n' "$out" | sed -E 's/[-*]$//' | sed -n -E 's/^ship-(.+)$/\1/p'
    return 0
  fi
  case "$out" in
    *'no server running'*|*"can't find session"*|*'session not found'*|*'no such session'*) return 0 ;;
    *) return 1 ;;
  esac
}

# shipyard_esc <slot> — Escape, i.e. CLEAR the input box. Never send this mid-turn: Escape
# is INTERRUPT while Claude Code is working. No driver twin.
shipyard_esc() {
  local t; t=$(shipyard_target "$1") || return 1
  case "$(shipyard_backend)" in
    agterm) printf '\033' | agtermctl session type --stdin --target "$t" >/dev/null 2>&1 ;;
    tmux)   tmux send-keys -t "$t" Escape 2>/dev/null ;;
    *) _shipyard_no_backend; return 1 ;;
  esac
}

# shipyard_note <slot> <idle|active|completed|blocked> [--blink] — paint the child's state on
# the sidebar so the board is readable without the report. agterm only; a no-op on tmux,
# which has nowhere to put it. No driver twin.
shipyard_note() {
  [ "$(shipyard_backend)" = agterm ] || return 0
  local t; t=$(shipyard_target "$1") || return 1
  shift
  agtermctl session status "$@" --target "$t" >/dev/null 2>&1 || true
}

# shipyard_container_prune — drop the container once it holds no ship terminals, so a repo
# that has finished all its work stops showing an empty `<repo>-ai` workspace. Only
# ever removes an EMPTY one, so a human tab parked in there keeps it alive. No driver twin.
shipyard_container_prune() {
  case "$(shipyard_backend)" in
    agterm)
      local n ws
      n=$(agtermctl tree --json 2>/dev/null | jq -r --arg ws "$(shipyard_container)" \
            '[.result.tree.workspaces[]? | select(.name==$ws) | .sessions[]?] | length' 2>/dev/null)
      [ "${n:-1}" = 0 ] || return 0
      ws=$(agtermctl tree --json 2>/dev/null | jq -r --arg ws "$(shipyard_container)" \
            '.result.tree.workspaces[]? | select(.name==$ws) | .id' 2>/dev/null | head -1)
      [ -n "$ws" ] || return 0
      agtermctl workspace delete --target "$ws" >/dev/null 2>&1 || true ;;
    tmux)
      # A tmux session is shared with the human's own windows, so it is never
      # pruned from here — tmux kills an empty session by itself anyway.
      return 0 ;;
    *) _shipyard_no_backend; return 1 ;;
  esac
}

# shipyard_notify <slot> <body> [title] — desktop notification attributed to the child. No driver
# twin.
shipyard_notify() {
  [ "$(shipyard_backend)" = agterm ] || return 0
  local t; t=$(shipyard_target "$1") || return 1
  agtermctl notify "$2" --title "${3:-ship}" --target "$t" >/dev/null 2>&1 || true
}
