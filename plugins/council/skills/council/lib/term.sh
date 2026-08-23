#!/usr/bin/env bash
# term.sh — the terminal a participant lives in. Source only.
#
# Two backends, one API: agterm (a native macOS terminal driven over a control socket by
# `agtermctl`) and tmux. `COUNCIL_BACKEND=agterm|tmux|auto`, default auto: agterm when its
# socket answers, else tmux, and a hard error when neither is there — a room whose
# participants cannot be read from or typed into is worse than one that refuses to start.
#
# This is the same abstraction the shipyard skill carries, and it is DUPLICATED here on
# purpose rather than sourced across the plugin boundary: Codex has no plugin-dependency
# field, so a cross-plugin source would work in Claude Code and silently break in Codex.
# Kept deliberately small (launch, read, type, close) so the two cannot drift far. If you
# fix a backend bug here, check the other one.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

ct_backend() {
  [ -n "${_CT_BE:-}" ] && { printf '%s' "$_CT_BE"; return 0; }
  case "${COUNCIL_BACKEND:-auto}" in
    agterm) _CT_BE=agterm ;;
    tmux)   _CT_BE=tmux ;;
    auto)
      if command -v agtermctl >/dev/null 2>&1 && agtermctl version >/dev/null 2>&1; then _CT_BE=agterm
      elif command -v tmux >/dev/null 2>&1; then _CT_BE=tmux
      else _CT_BE=none; fi ;;
    *) _CT_BE=invalid ;;
  esac
  printf '%s' "$_CT_BE"
}
_ct_no_backend() {
  case "$(ct_backend)" in
    invalid) echo "council: COUNCIL_BACKEND='${COUNCIL_BACKEND:-}' — только agterm, tmux или auto" >&2 ;;
    *) echo "council: нет терминального бэкенда. Нужен agterm (с установленным agtermctl) либо tmux." >&2 ;;
  esac
  return 1
}
ct_shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# The container holding this room's participants. Pinned INSIDE the room at first launch:
# the derived name depends on which workspace the launcher was sitting in, so re-deriving
# it later from another workspace would name an empty container and report, truthfully and
# uselessly, that the room has no participants.
_ct_pin() { printf '%s/state/container-%s' "$ROOM" "$(ct_backend)"; }
_ct_repo_key() { basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd -P)"; }
_ct_workspace() {
  [ -n "${AGTERM_WORKSPACE_ID:-}" ] || return 1
  command -v agtermctl >/dev/null 2>&1 || return 1
  local n
  n=$(agtermctl tree --json --window "${AGTERM_WINDOW_ID:-active}" 2>/dev/null \
      | jq -r --arg id "$AGTERM_WORKSPACE_ID" '.result.tree.workspaces[]? | select(.id==$id) | .name' 2>/dev/null | head -1)
  [ -n "$n" ] || return 1
  printf '%s' "$n"
}
ct_container() {
  local f v ws key
  f=$(_ct_pin); [ -f "$f" ] && { read -r v < "$f"; [ -n "$v" ] && { printf '%s' "$v"; return 0; }; }
  case "$(ct_backend)" in
    agterm) if ws=$(_ct_workspace); then case "$ws" in *-ai) printf '%s' "$ws" ;; *) printf '%s-ai' "$ws" ;; esac
            else printf '%s-ai' "$(_ct_repo_key)"; fi ;;
    tmux)   printf '%s' "$(_ct_repo_key)" ;;
    *) _ct_no_backend; return 1 ;;
  esac
}
ct_container_pin() { local v; v=$(ct_container) || return 1; printf '%s\n' "$v" > "$(_ct_pin)"; printf '%s' "$v"; }

ct_name() { printf 'council-%s-%s' "$(basename "$ROOM")" "$1"; }

ct_target() { # <peer> -> opaque handle, exit 1 when there is no live terminal
  local n; n=$(ct_name "$1"); local v
  case "$(ct_backend)" in
    agterm) v=$(agtermctl tree --json 2>/dev/null | jq -r --arg ws "$(ct_container)" --arg n "$n" \
              '.result.tree.workspaces[]? | select(.name==$ws) | .sessions[]? | select(.name==$n) | .id' 2>/dev/null | head -1) ;;
    tmux)   v=$(tmux list-windows -t "$(ct_container)" -F '#{window_index} #{window_name}' 2>/dev/null \
              | awk -v n="$n" '{ gsub(/[-*]$/,"",$2); if ($2==n) { print "'"$(ct_container)"':" $1; exit } }') ;;
    *) _ct_no_backend; return 1 ;;
  esac
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

ct_launch() { # <peer> <cwd> <launcher-script>
  local peer="$1" cwd="$2" launcher="$3" n cmd inner
  n=$(ct_name "$peer")
  case "$(ct_backend)" in
    agterm)
      # `zsh -lc` gives the child a LOGIN shell: agterm spawns it from the app, so it
      # inherits the GUI environment and would otherwise miss the user's PATH entirely.
      # --wait holds the session open after the agent exits, so a crash stays readable.
      inner="exec $(ct_shq "$launcher")"; cmd="zsh -lc $(ct_shq "$inner")"
      agtermctl session new --cwd "$cwd" --workspace-name "$(ct_container_pin)" --create-workspace \
        --name "$n" --no-select --wait --command "$cmd" >/dev/null || return 1 ;;
    tmux)
      # Scrub AGTERM_* before the tmux SERVER is born: a server started from inside an
      # agterm session captures them and hands them to everything it ever spawns.
      local -a scrub=(env -u AGTERM_ENABLED -u AGTERM_PANE -u AGTERM_PANE_ID -u AGTERM_SESSION_ID
                      -u AGTERM_SOCKET -u AGTERM_WINDOW_ID -u AGTERM_WORKSPACE_ID)
      cmd=$(ct_shq "$launcher")
      if tmux has-session -t "$(ct_container_pin)" 2>/dev/null; then
        "${scrub[@]}" tmux new-window -t "$(ct_container)" -n "$n" -c "$cwd" "$cmd" || return 1
      else
        "${scrub[@]}" tmux new-session -d -s "$(ct_container)" -n "$n" -c "$cwd" "$cmd" || return 1
      fi ;;
    *) _ct_no_backend; return 1 ;;
  esac
}

ct_capture() { local t; t=$(ct_target "$1") || return 1
  case "$(ct_backend)" in
    agterm) agtermctl session text --target "$t" --json 2>/dev/null | jq -r '.result.text // ""' ;;
    tmux)   tmux capture-pane -p -t "$t" 2>/dev/null ;;
  esac; }
ct_type() { local t; t=$(ct_target "$1") || return 1
  case "$(ct_backend)" in
    agterm) printf '%s' "$2" | agtermctl session type --stdin --target "$t" >/dev/null 2>&1 ;;
    tmux)   tmux send-keys -t "$t" -l "$2" ;;
  esac; }
ct_submit() { local t; t=$(ct_target "$1") || return 1
  case "$(ct_backend)" in
    agterm) printf '\n' | agtermctl session type --stdin --target "$t" >/dev/null 2>&1 ;;
    tmux)   tmux send-keys -t "$t" Enter ;;
  esac; }
ct_kill() { local t; t=$(ct_target "$1") || return 1
  case "$(ct_backend)" in
    agterm) agtermctl session close --target "$t" >/dev/null ;;
    tmux)   tmux kill-window -t "$t" ;;
  esac; }
ct_focus() { local t; t=$(ct_target "$1") || return 1
  case "$(ct_backend)" in
    agterm) agtermctl session select --target "$t" >/dev/null ;;
    tmux)   tmux select-window -t "$t" ;;
  esac; }
