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
# shipyard REQUIRES a git repo and sanitises ':' -> '_' in the stem — DISTINCT from council, which
# takes the driver's forgiving default (basename of the git top-level, or of $PWD outside a repo).
# So shipyard injects its own DRV_REPO_KEY. The driver reads it only on the repo-stem fallback path
# (no live agterm workspace); an empty value outside a repo would fall back to the driver's pwd
# basename rather than fail, but that is unreachable in practice — every shipyard entry point
# already needs the repo for its mailbox and slot, so the container is never derived outside one.
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
# correct once nothing is left in the old container (shipyard-down.sh calls it then). The pin file
# is the driver's now — reuse its path so unpin removes exactly what drv_container_pin wrote.
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
# session-id prefix on agterm). Empty + exit 1 when the slot is gone. No driver twin.
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
shipyard_slots() {
  case "$(shipyard_backend)" in
    agterm) _shipyard_at_sessions | jq -r '.name // empty' 2>/dev/null | sed -n -E 's/^ship-(.+)$/\1/p' ;;
    tmux)   _shipyard_tmux_slots ;;
    *) _shipyard_no_backend; return 1 ;;
  esac
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
