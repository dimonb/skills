# agent-driver.sh — the ONE agent-console driver, shared by shipyard and council.
#
# SOURCE OF TRUTH: shared/driver/agent-driver.sh. Do NOT edit the vendored copies under
# plugins/*/skills/*/ — edit here, then run `scripts/sync-driver.sh`. The repo gate
# (scripts/check.sh, check 11) fails if any copy drifts from this file.
#
# Why a vendored copy and not a symlink or an import: a Codex plugin is installed as a
# self-contained directory and cannot depend on another plugin, so each plugin must carry its
# own copy of shared code. The gate — not the filesystem — is what makes the copies one source
# of truth. This is the same "one source, enforced" idea the dogfood symlinks give, adapted to
# a boundary a symlink cannot cross.
#
# WHAT THIS IS: a behaviour-preserving superset of the two hand-synced terminal backends the
# plugins carried separately. It drives an agent console on either of two backends —
#   agterm — a native macOS terminal driven over a control socket by `agtermctl`;
#   tmux   — the portable fallback.
# The `drv_*` functions are what every caller uses; nothing here talks about a specific agent
# kind (claude/codex/…). The per-kind adapters that turn a goal into a launcher, and the
# migration of each plugin's call sites onto these functions, are separate later changes.
#
# Source only, never execute. Sourced into a shell that may run `set -u`, so every optional
# variable is read as `${VAR:-}`. The baseline interpreter is bash >= 5; a caller started by an
# older bash re-execs into a modern one before sourcing this (council.sh does exactly that).
#
# THE CONTAINER IS THE ONE PLACE THE TWO CALLERS DIFFER, so the naming is parameterised through
# caller-set variables (all optional, all with behaviour-preserving defaults):
#   DRV_BACKEND            agterm|tmux|auto (default auto). A caller maps its own backend
#                          variable onto this.
#   DRV_CONTAINER_OVERRIDE an explicit container name; wins over everything below.
#   DRV_CONTAINER_PIN_DIR  directory holding the `container-<backend>` pin file. Set = the name
#                          is pinned at first launch and every later call agrees with it; unset
#                          = no pinning (each call derives afresh).
#   DRV_CONTAINER_SUFFIX   suffix for the agterm container (default empty). A caller that keeps
#                          its agent sessions in their own workspace sets this (e.g. "-ai"); the
#                          suffix is never stacked, so a name already ending in it is left alone.
#   DRV_REPO_KEY           the repo-derived container stem (default: the basename of the git
#                          top-level, or of $PWD outside a repo). A caller that sanitises the
#                          stem (say ":" -> "_") or requires a repo injects its own value here.

# A version marker, bumped when the body changes, so sync + the drift gate stay easy to prove
# end to end.
_DRV_VERSION=1

# --- backend selection ---------------------------------------------------------
# agterm when its control socket answers, else tmux; `none` when neither is reachable and
# `invalid` for a bad DRV_BACKEND. Resolved once (see the bottom of the file) and cached, so
# `auto` does not re-ping the socket on every call.
drv_backend() {
  [ -n "${_DRV_BE:-}" ] && { printf '%s' "$_DRV_BE"; return 0; }
  case "${DRV_BACKEND:-auto}" in
    agterm) _DRV_BE=agterm ;;
    tmux)   _DRV_BE=tmux ;;
    auto)
      if command -v agtermctl >/dev/null 2>&1 && agtermctl version >/dev/null 2>&1; then
        _DRV_BE=agterm
      elif command -v tmux >/dev/null 2>&1; then
        _DRV_BE=tmux
      else
        # A real value, not a fallback: _drv_no_backend turns it into one clear error naming
        # both backends, and every dispatch refuses it rather than silently doing nothing.
        _DRV_BE=none
      fi ;;
    # A bad DRV_BACKEND resolves to a VALUE too and says nothing here — the message is
    # _drv_no_backend's, so a caller gets one accurate line instead of a "nothing installed"
    # error stacked on top of "you typed the name wrong".
    *) _DRV_BE=invalid ;;
  esac
  printf '%s' "$_DRV_BE"
}

# The refusal every dispatch shares, so an unusable backend can never read as a no-op. Re-resolve
# rather than read $_DRV_BE directly: every dispatch reaches us from inside a `case
# "$(drv_backend)"`, i.e. a SUBSHELL, so an assignment made during that resolution never reached
# this shell. drv_backend is deterministic and cached.
_drv_no_backend() {
  if [ "$(drv_backend)" = invalid ]; then
    echo "error: DRV_BACKEND must be agterm, tmux or auto (got: ${DRV_BACKEND:-})" >&2
  else
    echo "error: no terminal backend available — the driver cannot reach a session." >&2
    echo "       agterm: install agtermctl and start the app; or run with DRV_BACKEND=tmux." >&2
    echo "       tmux:   install tmux, then run with DRV_BACKEND=tmux." >&2
  fi
  return 1
}

# POSIX-shell-safe quoting of one word.
drv_shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# --- container naming ----------------------------------------------------------
# The repo-derived stem, when the caller does not inject DRV_REPO_KEY. Basename of the git
# top-level, or of $PWD outside a repo — the forgiving form; a caller that must fail outside a
# repo injects its own DRV_REPO_KEY instead.
_drv_repo_key() { basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"; }

# The agterm workspace THIS shell is sitting in, by name. Empty + exit 1 outside agterm.
# `--window` is not decoration: `tree` defaults to the FRONTMOST window, and this shell's
# session may live in another one — the lookup would then match nothing and read as "no
# workspace" rather than as "wrong window". AGTERM_* is inherited by descendants, so called from
# a process another session started this reports THAT session's workspace — one more reason the
# result gets pinned instead of re-derived.
_drv_workspace() {
  [ -n "${AGTERM_WORKSPACE_ID:-}" ] || return 1
  command -v agtermctl >/dev/null 2>&1 || return 1
  local n
  n=$(agtermctl tree --json --window "${AGTERM_WINDOW_ID:-active}" 2>/dev/null \
      | jq -r --arg id "$AGTERM_WORKSPACE_ID" \
          '.result.tree.workspaces[]? | select(.id==$id) | .name' 2>/dev/null | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}

# Where the pinned container name lives, keyed by BACKEND so switching backends never inherits
# the other's name. Empty + exit 1 when the caller set no pin directory.
_drv_pin_file() {
  [ -n "${DRV_CONTAINER_PIN_DIR:-}" ] || return 1
  printf '%s/container-%s' "$DRV_CONTAINER_PIN_DIR" "$(drv_backend)"
}

# What the container WOULD be called if it were being chosen right now (no override, no pin).
# The stem is captured into a variable rather than interpolated as `$(_drv_repo_key)$suffix`:
# inside a string a failing substitution just expands to nothing, so a failure outside a repo
# used to yield a bare suffix and go looking for children in it.
_drv_container_derive() {
  local key ws suffix="${DRV_CONTAINER_SUFFIX:-}"
  case "$(drv_backend)" in
    agterm)
      # Children belong beside the work: the workspace the caller is in, plus the suffix.
      # Outside agterm (a plain shell, cron, another terminal) there is no such workspace, so
      # fall back to the repo stem.
      if ws=$(_drv_workspace); then
        # Never stack the suffix: a name already ending in it is left as-is, so a child that
        # starts a sibling does not double it. An empty suffix matches every name, i.e. never
        # appends — which is the no-suffix caller's behaviour.
        case "$ws" in *"$suffix") printf '%s' "$ws" ;; *) printf '%s%s' "$ws" "$suffix" ;; esac
        return 0
      fi
      key=${DRV_REPO_KEY:-$(_drv_repo_key)}
      printf '%s%s' "$key" "$suffix" ;;
    tmux)
      # The tmux container carries no suffix, so sessions coexist with the human's own.
      key=${DRV_REPO_KEY:-$(_drv_repo_key)}
      printf '%s' "$key" ;;
    *) _drv_no_backend; return 1 ;;
  esac
}

# The container this caller's children actually live in:
#   1. DRV_CONTAINER_OVERRIDE — an explicit override always wins;
#   2. the name pinned at the first launch — so every later call agrees with it;
#   3. freshly derived.
drv_container() {
  [ -n "${DRV_CONTAINER_OVERRIDE:-}" ] && { printf '%s' "$DRV_CONTAINER_OVERRIDE"; return 0; }
  local f v
  if f=$(_drv_pin_file 2>/dev/null) && [ -f "$f" ]; then
    read -r v < "$f" 2>/dev/null
    [ -n "$v" ] && { printf '%s' "$v"; return 0; }
  fi
  _drv_container_derive
}

# Resolve the container and write it down (a launcher calls this before creating anything).
# Idempotent: an already-pinned name is returned unchanged, so a second child of a run joins the
# first one's container even if the caller has since moved to another workspace. With no pin
# directory it just returns the derived name.
drv_container_pin() {
  local v f
  v=$(drv_container) || return 1
  if f=$(_drv_pin_file 2>/dev/null); then printf '%s\n' "$v" > "$f" 2>/dev/null || true; fi
  printf '%s' "$v"
}

# --- the API every caller uses -------------------------------------------------
# Callers pass a RESOLVED session name (the naming template — e.g. "<prefix>-<slot>" — belongs to
# the caller, not here, which is what lets one driver serve callers whose names differ). Every op
# re-derives the opaque backend handle from that name, because the handle can change and the
# session can vanish between calls.

# drv_target <session-name> — opaque handle for the backend; exit 1 when the name has no live
# terminal. agterm: the session UUID. tmux: "<container>:<window-index>".
drv_target() {
  local name="$1" v container
  case "$(drv_backend)" in
    agterm)
      v=$(agtermctl tree --json 2>/dev/null \
            | jq -r --arg ws "$(drv_container)" --arg n "$name" \
                '.result.tree.workspaces[]? | select(.name==$ws) | .sessions[]?
                   | select(.name==$n) | .id' 2>/dev/null | head -1) ;;
    tmux)
      container=$(drv_container)
      v=$(tmux list-windows -t "$container" -F '#{window_index} #{window_name}' 2>/dev/null \
            | awk -v n="$name" '{ gsub(/[-*]$/,"",$2); if ($2==n) { print $1; exit } }')
      [ -n "$v" ] && v="$container:$v" ;;
    *) _drv_no_backend; return 1 ;;
  esac
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

# drv_launch <session-name> <cwd> <launcher> — start an agent console in its own session running
# the launcher (an executable file the caller writes, so neither backend carries a long quoted
# command line). Echoes the session name on success. The container is pinned here, so the first
# launch fixes the name for every later call.
drv_launch() {
  local name="$1" cwd="$2" launcher="$3" container inner cmd
  case "$(drv_backend)" in
    agterm)
      container=$(drv_container_pin) || return 1
      # `zsh -lc` gives the child a LOGIN shell: agterm spawns it from the app, so it inherits
      # the GUI environment and would otherwise miss the user's PATH entirely. --wait holds the
      # session open after the agent exits, so a crash stays readable.
      inner="exec $(drv_shq "$launcher")"
      cmd="zsh -lc $(drv_shq "$inner")"
      agtermctl session new --cwd "$cwd" --workspace-name "$container" --create-workspace \
        --name "$name" --no-select --wait --command "$cmd" >/dev/null || return 1 ;;
    tmux)
      container=$(drv_container_pin) || return 1
      cmd=$(drv_shq "$launcher")
      # Scrub AGTERM_* before the tmux SERVER is born: a server started from inside an agterm
      # session captures them and hands them to everything it ever spawns, so a child's
      # agent-status hook would report against the session that happened to start tmux.
      local -a scrub=(env -u AGTERM_ENABLED -u AGTERM_PANE -u AGTERM_PANE_ID
                      -u AGTERM_SESSION_ID -u AGTERM_SOCKET -u AGTERM_WINDOW_ID
                      -u AGTERM_WORKSPACE_ID)
      if tmux has-session -t "$container" 2>/dev/null; then
        "${scrub[@]}" tmux new-window -t "$container" -n "$name" -c "$cwd" "$cmd" || return 1
      else
        "${scrub[@]}" tmux new-session -d -s "$container" -n "$name" -c "$cwd" "$cmd" || return 1
      fi ;;
    *) _drv_no_backend; return 1 ;;
  esac
  printf '%s' "$name"
}

# drv_read <session-name> — the session's visible screen as plain text.
drv_read() {
  local t; t=$(drv_target "$1") || return 1
  case "$(drv_backend)" in
    agterm) agtermctl session text --target "$t" --json 2>/dev/null | jq -r '.result.text // ""' ;;
    tmux)   tmux capture-pane -p -t "$t" 2>/dev/null ;;
  esac
}

# drv_tell <session-name> <text> — inject text as keystrokes WITHOUT submitting. It goes in over
# stdin on both backends, so nothing re-expands it on the way.
drv_tell() {
  local t; t=$(drv_target "$1") || return 1
  case "$(drv_backend)" in
    agterm) printf '%s' "$2" | agtermctl session type --stdin --target "$t" >/dev/null 2>&1 ;;
    tmux)   tmux send-keys -t "$t" -l "$2" 2>/dev/null ;;
  esac
}

# drv_submit <session-name> [alt] — press Return. `alt` asks for the keypad Return, which some
# agent builds want instead; agterm delivers a real newline either way, so there it is the same
# keystroke and a second call is harmless.
drv_submit() {
  local t; t=$(drv_target "$1") || return 1
  case "$(drv_backend)" in
    agterm) printf '\n' | agtermctl session type --stdin --target "$t" >/dev/null 2>&1 ;;
    tmux)   if [ "${2:-}" = alt ]; then tmux send-keys -t "$t" KPEnter 2>/dev/null
            else tmux send-keys -t "$t" Enter 2>/dev/null; fi ;;
  esac
}

# drv_kill <session-name> — end the session (closing its pane HUP-reaps the subtree).
drv_kill() {
  local t; t=$(drv_target "$1") || return 1
  case "$(drv_backend)" in
    agterm) agtermctl session close --target "$t" >/dev/null ;;
    tmux)   tmux kill-window -t "$t" ;;
  esac
}

# drv_focus <session-name> — put the human on that session.
drv_focus() {
  local t; t=$(drv_target "$1") || return 1
  case "$(drv_backend)" in
    agterm) agtermctl session select --target "$t" >/dev/null ;;
    tmux)   tmux select-window -t "$t" ;;
  esac
}

# drv_signal <session-name> — one normalized status token "<liveness>|<capacity>":
#   liveness = live|dead
#   capacity = idle|busy|unknown for a live session, gone for a dead one
# This is the MINIMAL foundation a later phase grows into the full
# liveness|capacity|blocking|resume-at|payload escalation vocabulary. The capacity read is
# deliberately coarse and agent-agnostic — a visible input prompt at the foot of the screen means
# the session is waiting for input (idle), anything else is treated as busy. Telling "working"
# from "blocked" from "at capacity" apart is per-kind and is not here yet. Exit 1 when dead, 0
# when live, so a caller can branch on the status without parsing.
drv_signal() {
  local name="$1" screen last
  if ! drv_target "$name" >/dev/null 2>&1; then
    printf 'dead|gone'
    return 1
  fi
  screen=$(drv_read "$name" 2>/dev/null)
  [ -n "$screen" ] || { printf 'live|unknown'; return 0; }
  last=$(printf '%s\n' "$screen" | awk 'NF{l=$0} END{print l}')
  case "$last" in
    '›'*|'❯'*) printf 'live|idle' ;;
    *)         printf 'live|busy' ;;
  esac
  return 0
}

# Resolve the backend ONCE, here in the sourcing shell. Every dispatch asks via
# `case "$(drv_backend)"`, which runs in a subshell — so a resolution made there is thrown away,
# and without this line `auto` would ping the agterm socket again on every single call. Failure
# is not fatal here: _drv_no_backend is what turns an unusable backend into an error, at a point
# where the caller can print it.
drv_backend >/dev/null 2>&1 || true
