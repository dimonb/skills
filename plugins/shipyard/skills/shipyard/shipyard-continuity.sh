#!/usr/bin/env bash
# shipyard-continuity.sh - keep a Codex parent supervising after a capacity stop.
#
# Source this file for the lifecycle and parser functions. `shipyard-launch.sh`
# starts one detached watcher per parent agterm session; the watcher exits when
# that session disappears, and `shipyard-down.sh` stops every watcher after the
# last ship slot is removed.

SHIPYARD_CONTINUITY_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shipyard-continuity.sh"

shipyard_continuity_reset() {
  SHIPYARD_CONTINUITY_HANDLED_CAPACITY=0
  SHIPYARD_CONTINUITY_HANDLED_CAPACITY_KEY=""
  SHIPYARD_CONTINUITY_PENDING_GOAL_AT=0
  SHIPYARD_CONTINUITY_GOAL_LATCHED=0
  SHIPYARD_CONTINUITY_ACTION=""
  SHIPYARD_CONTINUITY_ACTION_CAPACITY=0
  SHIPYARD_CONTINUITY_ACTION_CAPACITY_KEY=""
  SHIPYARD_CONTINUITY_OWNED_COMMAND=""
  SHIPYARD_CONTINUITY_OWNED_ACTION=""
  SHIPYARD_CONTINUITY_OWNED_CAPACITY=0
  SHIPYARD_CONTINUITY_OWNED_CAPACITY_KEY=""
  SHIPYARD_CONTINUITY_RETURN_ATTEMPTED=0
}

shipyard_continuity_is_service_line() {
  case "$1" in
    '• Running '*|'• Ran '*|'• Working'*|'• Waited '*|'• Explored'*|\
    '• Edited '*|'• Added '*|'• Updated Plan'*|'• Context compacted'*|\
    '• Goal active'*|'• Goal paused'*|'• Goal stalled'*|\
    '• You have '[0-9]*' usage limit reset'*) return 0 ;;
    *) return 1 ;;
  esac
}

# Print: <total root capacity banners> <banners since the last intervention>
# <latest episode key>.
# Tool output is indented, so only a banner in column one is eligible. Codex service
# lines do not prove that the interrupted turn resumed. Real assistant prose or a
# submitted root prompt does. The episode key distinguishes a replacement banner when
# scrollback eviction leaves the visible banner count unchanged.
shipyard_continuity_capacity_state() {
  local screen="$1" line total=0 current=0 anchor="" key="none"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '⚠ Selected model is at capacity. Please try a different model.'*)
        total=$((total + 1)); current=$((current + 1))
        key=$(printf '%s\n%s' "$anchor" "$line" | cksum | awk '{print $1 "-" $2}') ;;
      '• '*)
        if ! shipyard_continuity_is_service_line "$line"; then
          current=0
          anchor="$line"
        fi ;;
      '›'|'› '|'› Ask Codex to do anything'|\
      ' ›'|' › '*|' › Ask Codex to do anything') ;;
      '› '*)
        current=0
        anchor="$line" ;;
    esac
  done <<<"$screen"
  printf '%s %s %s' "$total" "$current" "$key"
}

shipyard_continuity_capacity_counts() {
  local total current key
  read -r total current key <<<"$(shipyard_continuity_capacity_state "$1")"
  printf '%s %s' "$total" "$current"
}

# The latest root prompt is the live input box. A missing prompt is not assumed empty:
# refusing to submit is safer than overwriting input that the capture did not expose.
shipyard_continuity_prompt_empty() {
  local prompt
  prompt=$(shipyard_continuity_live_prompt "$1")
  case "$prompt" in
    '›'|'› '|' ›'|' › '|' › Ask Codex to do anything'|'› Ask Codex to do anything') return 0 ;;
    *) return 1 ;;
  esac
}

shipyard_continuity_live_prompt() {
  local screen="$1" line prompt=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '›'|'› '*|' ›'|' › '*) prompt="$line" ;; esac
  done <<<"$screen"
  printf '%s' "$prompt"
}

# active | paused | none, using only Codex's root goal service line or live footer.
shipyard_continuity_goal_state() {
  local screen="$1" line state=none
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '• Goal active'*) state=active ;;
      '• Goal paused'*|'• Goal stalled'*) state=paused ;;
      '  gpt-'*'Goal paused'*|'  gpt-'*'Goal stalled'*) state=paused ;;
      '  gpt-'*'Pursuing goal'*) state=active ;;
    esac
  done <<<"$screen"
  printf '%s' "$state"
}

# Set SHIPYARD_CONTINUITY_ACTION to resume, goal, or empty. State changes happen
# only in shipyard_continuity_succeeded, after both terminal control calls succeed.
shipyard_continuity_decide() {
  local screen="$1" now="$2" total current key goal
  SHIPYARD_CONTINUITY_ACTION=""
  SHIPYARD_CONTINUITY_ACTION_CAPACITY=0
  SHIPYARD_CONTINUITY_ACTION_CAPACITY_KEY=""
  read -r total current key <<<"$(shipyard_continuity_capacity_state "$screen")"
  goal=$(shipyard_continuity_goal_state "$screen")

  # A scrollback ring can discard old banners. Move the high-water mark down without
  # treating the remaining old banner as a new episode.
  if [ "$total" -lt "$SHIPYARD_CONTINUITY_HANDLED_CAPACITY" ]; then
    SHIPYARD_CONTINUITY_HANDLED_CAPACITY="$total"
    SHIPYARD_CONTINUITY_HANDLED_CAPACITY_KEY=""
  fi

  # Once real assistant prose follows the latest banner, every visible capacity event
  # is historical. Service lines such as Working, Ran, or Goal paused are deliberately
  # excluded from that clearance.
  if [ "$current" -eq 0 ]; then
    SHIPYARD_CONTINUITY_HANDLED_CAPACITY="$total"
    SHIPYARD_CONTINUITY_HANDLED_CAPACITY_KEY="$key"
  elif { [ "$total" -gt "$SHIPYARD_CONTINUITY_HANDLED_CAPACITY" ] \
      || [ "$key" != "$SHIPYARD_CONTINUITY_HANDLED_CAPACITY_KEY" ]; } \
    && shipyard_continuity_prompt_empty "$screen"; then
    SHIPYARD_CONTINUITY_ACTION=resume
    SHIPYARD_CONTINUITY_ACTION_CAPACITY="$total"
    SHIPYARD_CONTINUITY_ACTION_CAPACITY_KEY="$key"
    return 0
  fi

  [ "$goal" = active ] && SHIPYARD_CONTINUITY_GOAL_LATCHED=0

  # agterm queues a submitted command as steering while a Codex turn is active. The
  # prompt, not the session status, is the safety boundary: an empty active prompt is
  # eligible, and any draft blocks both paths.
  if [ "$SHIPYARD_CONTINUITY_PENDING_GOAL_AT" -gt 0 ] \
    && [ "$now" -ge "$SHIPYARD_CONTINUITY_PENDING_GOAL_AT" ] \
    && shipyard_continuity_prompt_empty "$screen"; then
    SHIPYARD_CONTINUITY_ACTION=goal
  elif [ "$SHIPYARD_CONTINUITY_PENDING_GOAL_AT" -eq 0 ] \
    && [ "$goal" = paused ] && [ "$SHIPYARD_CONTINUITY_GOAL_LATCHED" -eq 0 ] \
    && shipyard_continuity_prompt_empty "$screen"; then
    SHIPYARD_CONTINUITY_ACTION=goal
  fi
}

shipyard_continuity_succeeded() {
  local action="$1" now="$2" delay="${_SHIPYARD_CONTINUITY_GOAL_DELAY:-8}"
  case "$action" in
    resume)
      SHIPYARD_CONTINUITY_HANDLED_CAPACITY="$SHIPYARD_CONTINUITY_ACTION_CAPACITY"
      SHIPYARD_CONTINUITY_HANDLED_CAPACITY_KEY="$SHIPYARD_CONTINUITY_ACTION_CAPACITY_KEY"
      SHIPYARD_CONTINUITY_PENDING_GOAL_AT=$((now + delay)) ;;
    goal)
      SHIPYARD_CONTINUITY_PENDING_GOAL_AT=0
      SHIPYARD_CONTINUITY_GOAL_LATCHED=1 ;;
  esac
}

shipyard_continuity_read() {
  agtermctl session text --all --target "$1" --pane "$3" --socket "$2" --json 2>/dev/null \
    | jq -er '.result.text' 2>/dev/null
}

shipyard_continuity_window_idle() {
  agtermctl tree --json --window "$1" --socket "$2" 2>/dev/null \
    | jq -er '.result.tree.idleMs | numbers' 2>/dev/null
}

shipyard_continuity_begin_owned() {
  SHIPYARD_CONTINUITY_OWNED_COMMAND="$1"
  SHIPYARD_CONTINUITY_OWNED_ACTION="$2"
  SHIPYARD_CONTINUITY_OWNED_CAPACITY="$SHIPYARD_CONTINUITY_ACTION_CAPACITY"
  SHIPYARD_CONTINUITY_OWNED_CAPACITY_KEY="$SHIPYARD_CONTINUITY_ACTION_CAPACITY_KEY"
  SHIPYARD_CONTINUITY_RETURN_ATTEMPTED=0
}

shipyard_continuity_clear_owned() {
  SHIPYARD_CONTINUITY_OWNED_COMMAND=""
  SHIPYARD_CONTINUITY_OWNED_ACTION=""
  SHIPYARD_CONTINUITY_OWNED_CAPACITY=0
  SHIPYARD_CONTINUITY_OWNED_CAPACITY_KEY=""
  SHIPYARD_CONTINUITY_RETURN_ATTEMPTED=0
}

# Finish watcher-owned text. Return 0 after Return succeeds, 3 when a prior
# ambiguous Return visibly submitted, 2 while ownership is safely retained, and
# 1 after a conflict relinquishes ownership without sending Return.
shipyard_continuity_finish_owned() {
  local sid="$1" socket="$2" pane="$3" window="$4" screen prompt idle
  screen=$(shipyard_continuity_read "$sid" "$socket" "$pane") || return 2
  prompt=$(shipyard_continuity_live_prompt "$screen")
  if [ "$SHIPYARD_CONTINUITY_RETURN_ATTEMPTED" -eq 1 ] \
    && shipyard_continuity_prompt_empty "$screen"; then
    shipyard_continuity_clear_owned
    return 3
  fi
  if [ "$prompt" != "› $SHIPYARD_CONTINUITY_OWNED_COMMAND" ]; then
    shipyard_continuity_clear_owned
    return 1
  fi
  idle=$(shipyard_continuity_window_idle "$window" "$socket") || return 2
  if [ "$idle" -lt "${_SHIPYARD_CONTINUITY_QUIET_MS:-2000}" ] \
    || [ "$idle" -lt "${SHIPYARD_CONTINUITY_OWNED_IDLE:-0}" ]; then
    shipyard_continuity_clear_owned
    return 1
  fi
  SHIPYARD_CONTINUITY_RETURN_ATTEMPTED=1
  if printf '\n' | agtermctl session type --stdin \
    --target "$sid" --pane "$pane" --socket "$socket" >/dev/null 2>&1; then
    shipyard_continuity_clear_owned
    return 0
  fi
  return 2
}

# Text and Return MUST be separate control requests. A newline bundled with text is
# a multiline edit in Codex; a later newline is the submit keystroke. Re-read both
# the prompt and real-user idle clock before Return so a stale snapshot cannot consume
# a draft typed while the transaction is in flight.
shipyard_continuity_submit() {
  local message="$1" action="$2" sid="$3" socket="$4" pane="$5" window="$6"
  local screen idle type_rc=0
  screen=$(shipyard_continuity_read "$sid" "$socket" "$pane") || return 1
  shipyard_continuity_prompt_empty "$screen" || return 1
  idle=$(shipyard_continuity_window_idle "$window" "$socket") || return 1
  [ "$idle" -ge "${_SHIPYARD_CONTINUITY_QUIET_MS:-2000}" ] || return 1
  SHIPYARD_CONTINUITY_OWNED_IDLE="$idle"
  shipyard_continuity_begin_owned "$message" "$action"
  printf '%s' "$message" | agtermctl session type --stdin \
    --target "$sid" --pane "$pane" --socket "$socket" >/dev/null 2>&1 || type_rc=$?
  sleep "${_SHIPYARD_CONTINUITY_SETTLE_DELAY:-0.05}"
  if [ "$type_rc" -ne 0 ]; then
    screen=$(shipyard_continuity_read "$sid" "$socket" "$pane") || return 2
    if shipyard_continuity_prompt_empty "$screen"; then
      shipyard_continuity_clear_owned
      return 1
    fi
  fi
  shipyard_continuity_finish_owned "$sid" "$socket" "$pane" "$window"
}

# 0 means present, 1 means authoritatively absent, 2 means the tree could not be read.
shipyard_continuity_session_exists() {
  local sid="$1" socket="$2" window="$3" tree
  tree=$(agtermctl tree --json --window "$window" --socket "$socket" 2>/dev/null) || return 2
  if printf '%s' "$tree" | jq -e --arg sid "$sid" \
    '.result.tree.workspaces[].sessions[] | select(.id == $sid)' >/dev/null 2>&1; then
    return 0
  fi
  printf '%s' "$tree" | jq -e '.result.tree.workspaces | arrays' >/dev/null 2>&1 || return 2
  return 1
}

shipyard_continuity_watch() {
  local sid="$1" socket="$2" pane="$3" window="$4" pidfile="$5" heartbeat="$6" token="$7"
  local screen now action submit_rc exists_rc interval="${_SHIPYARD_CONTINUITY_POLL_SECS:-5}"
  trap 'shipyard_continuity_remove_owned_state "$pidfile" "$heartbeat" "$token"' EXIT
  trap 'exit 0' INT TERM
  shipyard_continuity_reset
  sleep "${_SHIPYARD_CONTINUITY_INITIAL_DELAY:-0}"
  while true; do
    printf '%s %s\n' "$token" "$(date +%s)" >"$heartbeat" 2>/dev/null || return 1
    if ! screen=$(shipyard_continuity_read "$sid" "$socket" "$pane"); then
      exists_rc=0
      shipyard_continuity_session_exists "$sid" "$socket" "$window" || exists_rc=$?
      [ "$exists_rc" -eq 1 ] && return 0
      sleep "$interval"
      continue
    fi
    now=$(date +%s)
    if [ -n "$SHIPYARD_CONTINUITY_OWNED_COMMAND" ]; then
      action="$SHIPYARD_CONTINUITY_OWNED_ACTION"
      SHIPYARD_CONTINUITY_ACTION_CAPACITY="$SHIPYARD_CONTINUITY_OWNED_CAPACITY"
      SHIPYARD_CONTINUITY_ACTION_CAPACITY_KEY="$SHIPYARD_CONTINUITY_OWNED_CAPACITY_KEY"
      submit_rc=0
      shipyard_continuity_finish_owned "$sid" "$socket" "$pane" "$window" || submit_rc=$?
      if [ "$submit_rc" -eq 0 ] || [ "$submit_rc" -eq 3 ]; then
        shipyard_continuity_succeeded "$action" "$now"
      fi
      sleep "$interval"
      continue
    fi
    shipyard_continuity_decide "$screen" "$now"
    action="$SHIPYARD_CONTINUITY_ACTION"
    case "$action" in
      resume)
        if shipyard_continuity_submit resume resume "$sid" "$socket" "$pane" "$window"; then
          shipyard_continuity_succeeded resume "$now"
          printf '[%s] retried parent Codex after model capacity\n' "$(date '+%H:%M:%S')"
        fi ;;
      goal)
        if shipyard_continuity_submit '/goal resume' goal "$sid" "$socket" "$pane" "$window"; then
          shipyard_continuity_succeeded goal "$now"
          printf '[%s] resumed parent Codex goal\n' "$(date '+%H:%M:%S')"
        fi ;;
    esac
    sleep "$interval"
  done
}

shipyard_continuity_state_dir() {
  if [ -n "${_SHIPYARD_CONTINUITY_DIR:-}" ]; then
    mkdir -p "$_SHIPYARD_CONTINUITY_DIR" || return 1
    printf '%s' "$_SHIPYARD_CONTINUITY_DIR"
  else
    shipyard_mailbox_ensure
  fi
}

shipyard_continuity_pid_is_owned() {
  local pid="$1" token="$2" heartbeat="$3" seen beat
  kill -0 "$pid" 2>/dev/null || return 1
  [ -f "$heartbeat" ] || return 1
  read -r seen beat <"$heartbeat" || return 1
  [ "$seen" = "$token" ] || return 1
  case "$beat" in ''|*[!0-9]*) return 1 ;; esac
}

shipyard_continuity_pid_is_healthy() {
  local pid="$1" token="$2" heartbeat="$3" seen beat now stale
  shipyard_continuity_pid_is_owned "$pid" "$token" "$heartbeat" || return 1
  read -r seen beat <"$heartbeat" || return 1
  now=$(date +%s)
  stale="${_SHIPYARD_CONTINUITY_STALE_SECS:-30}"
  [ $((now - beat)) -le "$stale" ]
}

shipyard_continuity_remove_owned_state() {
  local pidfile="$1" heartbeat="$2" token="$3" pid seen beat
  if [ -f "$pidfile" ]; then
    read -r pid seen <"$pidfile" || true
    [ "${seen:-}" = "$token" ] && rm -f "$pidfile"
  fi
  if [ -f "$heartbeat" ]; then
    read -r seen beat <"$heartbeat" || true
    [ "${seen:-}" = "$token" ] && rm -f "$heartbeat"
  fi
}

shipyard_continuity_terminate_owned() {
  local pid="$1" token="$2" heartbeat="$3"
  shipyard_continuity_pid_is_owned "$pid" "$token" "$heartbeat" || return 1
  shipyard_continuity_terminate_pid "$pid"
}

shipyard_continuity_terminate_pid() {
  local pid="$1" n=0
  kill "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 20 ]; do
    sleep 0.05
    n=$((n + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    n=0
    while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 20 ]; do
      sleep 0.05
      n=$((n + 1))
    done
  fi
  wait "$pid" 2>/dev/null || true
  ! kill -0 "$pid" 2>/dev/null
}

shipyard_continuity_start() {
  local backend="$1" state key pidfile heartbeat logfile pid token old_token n
  [ "$backend" = agterm ] || return 0
  [ -n "${CODEX_SESSION_ID:-}${CODEX_THREAD_ID:-}" ] || return 0
  [ "${AGTERM_ENABLED:-}" = 1 ] || return 0
  [ -n "${AGTERM_SESSION_ID:-}" ] && [ -n "${AGTERM_SOCKET:-}" ] \
    && [ -n "${AGTERM_WINDOW_ID:-}" ] || return 0
  command -v agtermctl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  state=$(shipyard_continuity_state_dir) || return 1
  key=$(printf '%s' "$AGTERM_SESSION_ID" | tr -c 'A-Za-z0-9._-' '_')
  pidfile="$state/continuity-$key.pid"
  heartbeat="$state/continuity-$key.heartbeat"
  logfile="$state/continuity-$key.log"
  if [ -f "$pidfile" ]; then
    read -r pid old_token <"$pidfile" || true
    if [ -n "${pid:-}" ] && [ -n "${old_token:-}" ] \
      && shipyard_continuity_pid_is_healthy "$pid" "$old_token" "$heartbeat"; then
      return 0
    fi
    if [ -n "${pid:-}" ] && [ -n "${old_token:-}" ] \
      && shipyard_continuity_pid_is_owned "$pid" "$old_token" "$heartbeat"; then
      shipyard_continuity_terminate_owned "$pid" "$old_token" "$heartbeat" || return 1
      shipyard_continuity_remove_owned_state "$pidfile" "$heartbeat" "$old_token"
    else
      rm -f "$pidfile" "$heartbeat"
    fi
  fi

  token="$$-$RANDOM-$(date +%s)"
  nohup bash "$SHIPYARD_CONTINUITY_SCRIPT" watch "$AGTERM_SESSION_ID" \
    "$AGTERM_SOCKET" "${AGTERM_PANE:-primary}" "$AGTERM_WINDOW_ID" \
    "$pidfile" "$heartbeat" "$token" \
    >>"$logfile" 2>&1 </dev/null &
  pid=$!
  printf '%s %s\n' "$pid" "$token" >"$pidfile" \
    || { shipyard_continuity_terminate_pid "$pid" || true; return 1; }
  n=0
  while ! shipyard_continuity_pid_is_healthy "$pid" "$token" "$heartbeat"; do
    if ! kill -0 "$pid" 2>/dev/null || [ "$n" -ge 20 ]; then
      shipyard_continuity_terminate_pid "$pid" || true
      shipyard_continuity_remove_owned_state "$pidfile" "$heartbeat" "$token"
      return 1
    fi
    sleep 0.05
    n=$((n + 1))
  done
  printf 'parent continuity guard started for Codex session %s\n' "$AGTERM_SESSION_ID"
}

shipyard_continuity_stop_all() {
  local state f pid token heartbeat log
  state=$(shipyard_continuity_state_dir 2>/dev/null) || return 0
  for f in "$state"/continuity-*.pid; do
    [ -f "$f" ] || continue
    read -r pid token <"$f" || true
    heartbeat="${f%.pid}.heartbeat"
    if [ -n "${pid:-}" ] && [ -n "${token:-}" ] \
      && shipyard_continuity_pid_is_owned "$pid" "$token" "$heartbeat"; then
      shipyard_continuity_terminate_owned "$pid" "$token" "$heartbeat" || true
    fi
    log="${f%.pid}.log"
    if [ -n "${token:-}" ]; then
      shipyard_continuity_remove_owned_state "$f" "$heartbeat" "$token"
    fi
    [ ! -f "$f" ] && rm -f "$log"
  done
}

# 0 cleaned up, 1 still has slots, 2 could not prove the fleet is empty.
shipyard_continuity_cleanup_last_slot() {
  local enumeration_status="$1" slots="$2"
  [ "$enumeration_status" -eq 0 ] || return 2
  [ -z "$slots" ] || return 1
  shipyard_continuity_stop_all
  shipyard_container_prune
  shipyard_container_unpin
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    watch) shift; shipyard_continuity_watch "$@" ;;
    *) echo 'usage: shipyard-continuity.sh watch <session> <socket> <pane> <window> <pidfile> <heartbeat> <token>' >&2; exit 2 ;;
  esac
fi
