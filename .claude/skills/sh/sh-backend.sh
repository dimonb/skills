#!/usr/bin/env bash
# sh-backend.sh — terminal-backend abstraction for the `sh` skill. Source only.
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
# Pick one with SH_BACKEND=agterm|tmux|auto. The default is `auto`: agterm whenever an
# agterm app is answering its control socket, else tmux, and a hard error when NEITHER
# is available — `sh` has no third way to reach a child, so pretending to have a backend
# only moves the failure somewhere less legible. Every other script in this skill talks
# only to the sh_* functions below and never to agtermctl/tmux directly, so a slot
# behaves identically on both.
#
# The container name is the ONE place the two differ by design:
#   agterm: workspace `<parent's workspace>-ai`, falling back to `<repo>-ai`
#           (the `-ai` suffix keeps agent sessions in their own workspace, away from the
#            human's own tabs)
#   tmux:   session   `<repo>`      (unchanged, so ship and rv windows still coexist)
#
# The agterm name is derived ONCE and then PINNED in the mailbox, because it depends on
# where the caller was sitting. Re-deriving it per call would mean a report run from a
# different workspace resolves a different container and truthfully reports that there
# are no children — the worst possible lie for a monitor.

# --- backend selection ---------------------------------------------------------
sh_backend() {
  if [ -n "${_SH_BE:-}" ]; then printf '%s' "$_SH_BE"; return 0; fi
  case "${SH_BACKEND:-auto}" in
    agterm) _SH_BE=agterm ;;
    tmux)   _SH_BE=tmux ;;
    auto)
      if command -v agtermctl >/dev/null 2>&1 && agtermctl version >/dev/null 2>&1; then
        _SH_BE=agterm
      elif command -v tmux >/dev/null 2>&1; then
        _SH_BE=tmux
      else
        # Neither is reachable. `none` is a real value, not a fallback: sh_backend_check
        # turns it into one clear error naming both, and every dispatch below refuses it
        # rather than silently doing nothing.
        _SH_BE=none
      fi ;;
    # A bad SH_BACKEND resolves to a VALUE too, and says nothing here: the message is
    # _sh_no_backend's, so a caller gets one accurate line instead of a "nothing is
    # installed" error stacked on top of "you typed the name wrong".
    *) _SH_BE=invalid ;;
  esac
  printf '%s' "$_SH_BE"
}

# The refusal every dispatch shares, so an unusable backend can never read as a no-op.
_sh_no_backend() {
  # Re-resolve rather than reading $_SH_BE directly: every dispatch reaches us from
  # inside a `case "$(sh_backend)"`, i.e. from a SUBSHELL, so an assignment made during
  # that resolution never reached this shell. sh_backend is deterministic and cached.
  if [ "$(sh_backend)" = invalid ]; then
    echo "error: SH_BACKEND must be agterm, tmux or auto (got: ${SH_BACKEND:-})" >&2
  else
    echo "error: no terminal backend available — sh cannot reach a child session." >&2
    echo "       agterm: install agtermctl (agterm ▸ Help ▸ Install Command Line Tool…) and start the app;" >&2
    echo "       tmux:   brew install tmux, then run with SH_BACKEND=tmux." >&2
  fi
  return 1
}

# Fail early and loudly rather than at the first weird empty capture.
sh_backend_check() {
  case "$(sh_backend)" in
    agterm)
      command -v agtermctl >/dev/null 2>&1 || {
        echo "error: agtermctl is not on PATH (agterm ▸ Help ▸ Install Command Line Tool…)" >&2
        echo "       or run with SH_BACKEND=tmux" >&2; return 1; }
      agtermctl version >/dev/null 2>&1 || {
        echo "error: no agterm is answering the control socket (${AGTERM_SOCKET:-default})" >&2
        echo "       start agterm, or run with SH_BACKEND=tmux" >&2; return 1; }
      command -v jq >/dev/null 2>&1 || { echo "error: the agterm backend needs jq" >&2; return 1; } ;;
    tmux)
      command -v tmux >/dev/null 2>&1 || { echo "error: tmux is not on PATH" >&2; return 1; } ;;
    *) _sh_no_backend; return 1 ;;
  esac
}

# --- naming --------------------------------------------------------------------
sh_repo_key() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "error: not inside a git repository — sh derives its container name from the repo" >&2
    return 1; }
  basename "$root" | tr ':' '_'
}

# The agterm workspace THIS shell is sitting in, by name. Empty + exit 1 outside agterm.
#
# `--window` is not decoration: `tree` defaults to the FRONTMOST window, and this shell's
# session may live in another one — the lookup would then match nothing and read as "no
# workspace" rather than as "wrong window".
#
# Caveat worth knowing: AGTERM_* is inherited by every descendant, including long-lived
# daemons. Called from a process some other session started, this reports THAT session's
# workspace. That is one more reason the result gets pinned instead of re-derived.
sh_current_workspace() {
  [ -n "${AGTERM_WORKSPACE_ID:-}" ] || return 1
  command -v agtermctl >/dev/null 2>&1 || return 1
  local n
  n=$(agtermctl tree --json --window "${AGTERM_WINDOW_ID:-active}" 2>/dev/null \
      | jq -r --arg id "$AGTERM_WORKSPACE_ID" \
          '.result.tree.workspaces[]? | select(.id==$id) | .name' 2>/dev/null | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

# Where the pinned container name lives. Keyed by BACKEND: switching to tmux must not
# inherit an agterm workspace name as its session name.
_sh_container_file() {
  local mb; mb=$(sh_mailbox 2>/dev/null) || return 1
  printf '%s/container-%s' "$mb" "$(sh_backend)"
}

# What the container WOULD be called if it were being chosen right now.
#
# The key is captured into a variable rather than interpolated as `$(sh_repo_key)-ai`:
# inside a string, a failing substitution just expands to nothing, so running this from
# outside a repo used to yield the container `-ai` and go looking for children in it.
sh_container_derive() {
  local key ws
  case "$(sh_backend)" in
    agterm)
      # Children belong beside the work: the workspace the parent watcher is in, plus
      # `-ai`. Outside agterm (a plain shell, cron, another terminal) there is no such
      # workspace, so fall back to the repo name — which is what this always used to be.
      if ws=$(sh_current_workspace); then
        # Never stack the suffix: launching from inside `<x>-ai` keeps `<x>-ai`, so a
        # child that starts a sibling does not create `<x>-ai-ai`.
        case "$ws" in *-ai) printf '%s' "$ws" ;; *) printf '%s-ai' "$ws" ;; esac
        return 0
      fi
      key=$(sh_repo_key) || return 1
      printf '%s-ai' "$key" ;;
    tmux)
      # Unchanged: `<repo>`, so `sh` and `rv` windows keep sharing one session.
      key=$(sh_repo_key) || return 1
      printf '%s' "$key" ;;
    *) _sh_no_backend; return 1 ;;
  esac
}

# The container this repo's children actually live in.
#   1. SH_WORKSPACE / SH_SESSION — an explicit override always wins;
#   2. the name pinned at the first launch — so every later script agrees with it;
#   3. freshly derived.
sh_container() {
  [ -n "${_SH_CONTAINER:-}" ] && { printf '%s' "$_SH_CONTAINER"; return 0; }
  case "$(sh_backend)" in
    agterm) [ -n "${SH_WORKSPACE:-}" ] && { printf '%s' "$SH_WORKSPACE"; return 0; } ;;
    tmux)   [ -n "${SH_SESSION:-}" ]   && { printf '%s' "$SH_SESSION"; return 0; } ;;
  esac
  local f v
  if f=$(_sh_container_file 2>/dev/null) && [ -f "$f" ]; then
    v=$(head -1 "$f" 2>/dev/null)
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  fi
  sh_container_derive
}

# sh_container_pin — resolve the container and write it down (sh-launch.sh calls this
# before creating anything). Idempotent: an already-pinned name is returned unchanged,
# so the second slot of a run joins the first one's container even if you have since
# moved to another workspace.
sh_container_pin() {
  local v f
  v=$(sh_container) || return 1
  if f=$(_sh_container_file 2>/dev/null); then printf '%s\n' "$v" >"$f" 2>/dev/null || true; fi
  printf '%s' "$v"
}

# sh_container_unpin — forget it, so the next launch derives a fresh one. Only correct
# once nothing is left in the old container (sh-down.sh calls it then).
sh_container_unpin() {
  local f; f=$(_sh_container_file 2>/dev/null) && rm -f "$f" 2>/dev/null
  return 0
}

# What kind of thing that container is, for messages.
sh_container_kind() {
  case "$(sh_backend)" in
    agterm) printf 'workspace' ;;
    tmux)   printf 'session' ;;
    *) _sh_no_backend; return 1 ;;
  esac
}

# POSIX-shell-safe quoting of one word.
sh_shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# --- agterm internals ----------------------------------------------------------
_sh_at_sessions() {   # one compact JSON object per session in our workspace
  agtermctl tree --json 2>/dev/null \
    | jq -c --arg ws "$(sh_container)" \
        '.result.tree.workspaces[]? | select(.name==$ws) | .sessions[]?' 2>/dev/null
}

# --- the API every other script uses -------------------------------------------

# sh_target <slot> — opaque handle for the backend; exit 1 when the slot has no
# live terminal. agterm: the session UUID. tmux: `<session>:<index>`.
sh_target() {
  local slot="$1" v
  case "$(sh_backend)" in
    agterm)
      v=$(_sh_at_sessions | jq -r --arg n "ship-$slot" 'select(.name==$n) | .id' 2>/dev/null | head -1) ;;
    tmux)
      v=$(tmux list-windows -t "$(sh_container)" -F '#{window_index} #{window_name}' 2>/dev/null \
          | awk -v n="ship-$slot" '{ gsub(/[-*]$/,"",$2); if ($2==n) { print $1; exit } }')
      [ -n "$v" ] && v="$(sh_container):$v" ;;
    *) _sh_no_backend; return 1 ;;
  esac
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

# sh_slot_addr <slot> — the SHORT column value for the report ("win" on tmux, the
# session-id prefix on agterm). Empty + exit 1 when the slot is gone.
sh_slot_addr() {
  local t; t=$(sh_target "$1") || return 1
  case "$(sh_backend)" in
    agterm) printf '%s' "$(printf '%s' "$t" | cut -c1-8 | tr '[:upper:]' '[:lower:]')" ;;
    tmux)   printf '%s' "${t##*:}" ;;
    *) _sh_no_backend; return 1 ;;
  esac
}

# sh_where <slot> — human-readable location, for log lines and errors.
sh_where() {
  local t
  if ! t=$(sh_target "$1"); then printf '%s/ship-%s (no live terminal)' "$(sh_container)" "$1"; return 1; fi
  case "$(sh_backend)" in
    agterm) printf '%s/ship-%s' "$(sh_container)" "$1" ;;
    tmux)   printf '%s' "$t" ;;
    *) _sh_no_backend; return 1 ;;
  esac
}

# sh_peek_hint <slot> — a command the human can paste to look inside the child.
sh_peek_hint() {
  local t; t=$(sh_target "$1") || { printf 'no live terminal for ship-%s' "$1"; return 1; }
  case "$(sh_backend)" in
    agterm) printf "agtermctl session text --target %s --lines 20" "$t" ;;
    tmux)   printf "tmux capture-pane -t '%s' -p | tail -20" "$t" ;;
    *) _sh_no_backend; return 1 ;;
  esac
}

# sh_slots — every slot that currently has a terminal.
sh_slots() {
  case "$(sh_backend)" in
    agterm) _sh_at_sessions | jq -r '.name // empty' 2>/dev/null | sed -n -E 's/^ship-(.+)$/\1/p' ;;
    tmux)   tmux list-windows -t "$(sh_container)" -F '#{window_name}' 2>/dev/null \
              | sed -E 's/[-*]$//' | sed -n -E 's/^ship-(.+)$/\1/p' ;;
    *) _sh_no_backend; return 1 ;;
  esac
}

# sh_capture <slot> — the child's visible screen as plain text.
sh_capture() {
  local t; t=$(sh_target "$1") || return 1
  case "$(sh_backend)" in
    agterm) agtermctl session text --target "$t" --json 2>/dev/null | jq -r '.result.text // ""' ;;
    tmux)   tmux capture-pane -t "$t" -p 2>/dev/null ;;
    *) _sh_no_backend; return 1 ;;
  esac
}

# sh_type <slot> <text> — inject text as keystrokes WITHOUT submitting. The text goes
# in over stdin on both backends, so nothing re-expands it on the way.
sh_type() {
  local t; t=$(sh_target "$1") || return 1
  case "$(sh_backend)" in
    agterm) printf '%s' "$2" | agtermctl session type --stdin --target "$t" >/dev/null 2>&1 ;;
    tmux)   tmux send-keys -t "$t" -l "$2" 2>/dev/null ;;
    *) _sh_no_backend; return 1 ;;
  esac
}

# sh_submit <slot> [alt] — press Return. `alt` asks for the keypad Return, which some
# Claude Code builds want instead; agterm delivers a real newline either way, so there
# it is the same keystroke and a second call is harmless.
sh_submit() {
  local t; t=$(sh_target "$1") || return 1
  case "$(sh_backend)" in
    agterm) printf '\n' | agtermctl session type --stdin --target "$t" >/dev/null 2>&1 ;;
    tmux)   if [ "${2:-}" = alt ]; then tmux send-keys -t "$t" KPEnter 2>/dev/null
            else tmux send-keys -t "$t" Enter 2>/dev/null; fi ;;
    *) _sh_no_backend; return 1 ;;
  esac
}

# sh_esc <slot> — Escape, i.e. CLEAR the input box. Never send this mid-turn: Escape
# is INTERRUPT while Claude Code is working.
sh_esc() {
  local t; t=$(sh_target "$1") || return 1
  case "$(sh_backend)" in
    agterm) printf '\033' | agtermctl session type --stdin --target "$t" >/dev/null 2>&1 ;;
    tmux)   tmux send-keys -t "$t" Escape 2>/dev/null ;;
    *) _sh_no_backend; return 1 ;;
  esac
}

# sh_launch <slot> <cwd> <launcher-script> — start a child terminal running the
# launcher. The launcher is an executable file (sh-launch.sh writes it), so neither
# backend has to carry a long quoted command line.
sh_launch() {
  local slot="$1" cwd="$2" launcher="$3" ws inner cmd
  case "$(sh_backend)" in
    agterm)
      ws=$(sh_container)
      # `zsh -lc` gives the child a LOGIN shell: agterm spawns it from the app, so it
      # inherits the GUI environment and would otherwise miss the user's PATH entirely.
      # --wait holds the session open after claude exits, so a crash is still readable.
      inner="exec $(sh_shq "$launcher")"
      cmd="zsh -lc $(sh_shq "$inner")"
      agtermctl session new --cwd "$cwd" --workspace-name "$ws" --create-workspace \
        --name "ship-$slot" --no-select --wait --command "$cmd" >/dev/null || return 1
      ;;
    tmux)
      cmd=$(sh_shq "$launcher")
      # Scrub AGTERM_* before the tmux SERVER is born. A server started from inside an
      # agterm session captures those variables and hands them to every process it ever
      # spawns, so a child's agent-status hook would report against the session that
      # happened to start tmux.
      local -a scrub=(env -u AGTERM_ENABLED -u AGTERM_PANE -u AGTERM_PANE_ID
                      -u AGTERM_SESSION_ID -u AGTERM_SOCKET -u AGTERM_WINDOW_ID
                      -u AGTERM_WORKSPACE_ID)
      if tmux has-session -t "$(sh_container)" 2>/dev/null; then
        "${scrub[@]}" tmux new-window -t "$(sh_container)" -n "ship-$slot" -c "$cwd" "$cmd" || return 1
      else
        "${scrub[@]}" tmux new-session -d -s "$(sh_container)" -n "ship-$slot" -c "$cwd" "$cmd" || return 1
      fi
      ;;
    *) _sh_no_backend; return 1 ;;
  esac
}

# sh_kill <slot> — tear the child's terminal down (teardown after a merge).
sh_kill() {
  local t; t=$(sh_target "$1") || return 1
  case "$(sh_backend)" in
    agterm) agtermctl session close --target "$t" >/dev/null ;;
    tmux)   tmux kill-window -t "$t" ;;
    *) _sh_no_backend; return 1 ;;
  esac
}

# sh_focus <slot> — put the human on that child.
sh_focus() {
  local t; t=$(sh_target "$1") || return 1
  case "$(sh_backend)" in
    agterm) agtermctl session select --target "$t" >/dev/null ;;
    tmux)   tmux select-window -t "$t" ;;
    *) _sh_no_backend; return 1 ;;
  esac
}

# sh_note <slot> <idle|active|completed|blocked> [--blink] — paint the child's state on
# the sidebar so the board is readable without the report. agterm only; a no-op on tmux,
# which has nowhere to put it.
sh_note() {
  [ "$(sh_backend)" = agterm ] || return 0
  local t; t=$(sh_target "$1") || return 1
  shift
  agtermctl session status "$@" --target "$t" >/dev/null 2>&1 || true
}

# sh_container_prune — drop the container once it holds no ship terminals, so a repo
# that has finished all its work stops showing an empty `<repo>-ai` workspace. Only
# ever removes an EMPTY one, so a human tab parked in there keeps it alive.
sh_container_prune() {
  case "$(sh_backend)" in
    agterm)
      local n ws
      n=$(agtermctl tree --json 2>/dev/null | jq -r --arg ws "$(sh_container)" \
            '[.result.tree.workspaces[]? | select(.name==$ws) | .sessions[]?] | length' 2>/dev/null)
      [ "${n:-1}" = 0 ] || return 0
      ws=$(agtermctl tree --json 2>/dev/null | jq -r --arg ws "$(sh_container)" \
            '.result.tree.workspaces[]? | select(.name==$ws) | .id' 2>/dev/null | head -1)
      [ -n "$ws" ] || return 0
      agtermctl workspace delete --target "$ws" >/dev/null 2>&1 || true ;;
    tmux)
      # A tmux session is shared with rv windows and the human's own, so it is never
      # pruned from here — tmux kills an empty session by itself anyway.
      return 0 ;;
    *) _sh_no_backend; return 1 ;;
  esac
}

# sh_notify <slot> <body> [title] — desktop notification attributed to the child.
sh_notify() {
  [ "$(sh_backend)" = agterm ] || return 0
  local t; t=$(sh_target "$1") || return 1
  agtermctl notify "$2" --title "${3:-ship}" --target "$t" >/dev/null 2>&1 || true
}

# Resolve ONCE, here in the sourcing shell. Every dispatch below asks via
# `case "$(sh_backend)"`, which runs in a subshell — so a resolution made there is
# thrown away, and without this line `auto` would ping the agterm socket again on
# every single call (the report makes dozens per tick). Failure is not fatal here:
# sh_backend_check is what turns an unusable backend into an error, at a point where
# the caller can print it.
sh_backend >/dev/null 2>&1 || true
