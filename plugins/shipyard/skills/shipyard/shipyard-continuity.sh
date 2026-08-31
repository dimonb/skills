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
  SHIPYARD_CONTINUITY_PENDING_GOAL_AT=0
  SHIPYARD_CONTINUITY_GOAL_LATCHED=0
  SHIPYARD_CONTINUITY_ACTION=""
  SHIPYARD_CONTINUITY_ACTION_CAPACITY=0
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

# Print: <total root capacity banners> <banners since the last real assistant line>.
# Tool output is indented, so only a banner in column one is eligible. Codex service
# lines do not prove that the interrupted turn resumed and therefore do not reset the
# second count.
shipyard_continuity_capacity_counts() {
  local screen="$1" line total=0 current=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '⚠ Selected model is at capacity. Please try a different model.'*)
        total=$((total + 1)); current=$((current + 1)) ;;
      '• '*)
        shipyard_continuity_is_service_line "$line" || current=0 ;;
    esac
  done <<<"$screen"
  printf '%s %s' "$total" "$current"
}

# The latest root prompt is the live input box. A missing prompt is not assumed empty:
# refusing to submit is safer than overwriting input that the capture did not expose.
shipyard_continuity_prompt_empty() {
  local screen="$1" line prompt=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '›'|'› '*) prompt="$line" ;; esac
  done <<<"$screen"
  case "$prompt" in
    '›'|'› '|'› Ask Codex to do anything') return 0 ;;
    *) return 1 ;;
  esac
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
  local screen="$1" now="$2" total current goal
  SHIPYARD_CONTINUITY_ACTION=""
  SHIPYARD_CONTINUITY_ACTION_CAPACITY=0
  read -r total current <<<"$(shipyard_continuity_capacity_counts "$screen")"
  goal=$(shipyard_continuity_goal_state "$screen")

  # A scrollback ring can discard old banners. Move the high-water mark down without
  # treating the remaining old banner as a new episode.
  if [ "$total" -lt "$SHIPYARD_CONTINUITY_HANDLED_CAPACITY" ]; then
    SHIPYARD_CONTINUITY_HANDLED_CAPACITY="$total"
  fi

  # Once real assistant prose follows the latest banner, every visible capacity event
  # is historical. Service lines such as Working, Ran, or Goal paused are deliberately
  # excluded from that clearance.
  if [ "$current" -eq 0 ]; then
    SHIPYARD_CONTINUITY_HANDLED_CAPACITY="$total"
  elif [ "$total" -gt "$SHIPYARD_CONTINUITY_HANDLED_CAPACITY" ] \
    && shipyard_continuity_prompt_empty "$screen"; then
    SHIPYARD_CONTINUITY_ACTION=resume
    SHIPYARD_CONTINUITY_ACTION_CAPACITY="$total"
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
  elif [ "$goal" = paused ] && [ "$SHIPYARD_CONTINUITY_GOAL_LATCHED" -eq 0 ] \
    && shipyard_continuity_prompt_empty "$screen"; then
    SHIPYARD_CONTINUITY_ACTION=goal
  fi
}

shipyard_continuity_succeeded() {
  local action="$1" now="$2" delay="${_SHIPYARD_CONTINUITY_GOAL_DELAY:-8}"
  case "$action" in
    resume)
      SHIPYARD_CONTINUITY_HANDLED_CAPACITY="$SHIPYARD_CONTINUITY_ACTION_CAPACITY"
      SHIPYARD_CONTINUITY_PENDING_GOAL_AT=$((now + delay)) ;;
    goal)
      SHIPYARD_CONTINUITY_PENDING_GOAL_AT=0
      SHIPYARD_CONTINUITY_GOAL_LATCHED=1 ;;
  esac
}

# Text and Return MUST be separate control requests. A newline bundled with text is
# a multiline edit in Codex; a later newline is the submit keystroke.
shipyard_continuity_submit() {
  local message="$1" sid="$2" socket="$3" pane="$4"
  printf '%s' "$message" | agtermctl session type --stdin \
    --target "$sid" --pane "$pane" --socket "$socket" >/dev/null 2>&1 || return 1
  sleep "${_SHIPYARD_CONTINUITY_RETURN_DELAY:-1}"
  printf '\n' | agtermctl session type --stdin \
    --target "$sid" --pane "$pane" --socket "$socket" >/dev/null 2>&1
}

shipyard_continuity_read() {
  agtermctl session text --all --target "$1" --pane "$3" --socket "$2" --json 2>/dev/null \
    | jq -er '.result.text' 2>/dev/null
}

shipyard_continuity_watch() {
  local sid="$1" socket="$2" pane="$3" pidfile="$4" heartbeat="$5" token="$6"
  local screen now action misses=0 interval="${_SHIPYARD_CONTINUITY_POLL_SECS:-5}"
  trap 'rm -f "$pidfile" "$heartbeat"' EXIT
  trap 'exit 0' INT TERM
  shipyard_continuity_reset
  while true; do
    printf '%s %s\n' "$token" "$(date +%s)" >"$heartbeat" 2>/dev/null || return 1
    if ! screen=$(shipyard_continuity_read "$sid" "$socket" "$pane"); then
      misses=$((misses + 1))
      [ "$misses" -ge 3 ] && return 0
      sleep "$interval"
      continue
    fi
    misses=0
    now=$(date +%s)
    shipyard_continuity_decide "$screen" "$now"
    action="$SHIPYARD_CONTINUITY_ACTION"
    case "$action" in
      resume)
        if shipyard_continuity_submit resume "$sid" "$socket" "$pane"; then
          shipyard_continuity_succeeded resume "$now"
          printf '[%s] retried parent Codex after model capacity\n' "$(date '+%H:%M:%S')"
        fi ;;
      goal)
        if shipyard_continuity_submit '/goal resume' "$sid" "$socket" "$pane"; then
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

shipyard_continuity_pid_is_guard() {
  local pid="$1" token="$2" heartbeat="$3" seen beat now stale
  kill -0 "$pid" 2>/dev/null || return 1
  [ -f "$heartbeat" ] || return 1
  read -r seen beat <"$heartbeat" || return 1
  [ "$seen" = "$token" ] || return 1
  case "$beat" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  stale="${_SHIPYARD_CONTINUITY_STALE_SECS:-30}"
  [ $((now - beat)) -le "$stale" ]
}

shipyard_continuity_start() {
  local agent="$1" backend="$2" state key pidfile heartbeat logfile pid token old_token n
  [ "$agent" = codex ] || return 0
  [ "$backend" = agterm ] || return 0
  [ -n "${CODEX_SESSION_ID:-}${CODEX_THREAD_ID:-}" ] || return 0
  [ "${AGTERM_ENABLED:-}" = 1 ] || return 0
  [ -n "${AGTERM_SESSION_ID:-}" ] && [ -n "${AGTERM_SOCKET:-}" ] || return 0
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
      && shipyard_continuity_pid_is_guard "$pid" "$old_token" "$heartbeat"; then
      return 0
    fi
    rm -f "$pidfile" "$heartbeat"
  fi

  token="$$-$RANDOM-$(date +%s)"
  nohup bash "$SHIPYARD_CONTINUITY_SCRIPT" watch "$AGTERM_SESSION_ID" \
    "$AGTERM_SOCKET" "${AGTERM_PANE:-primary}" "$pidfile" "$heartbeat" "$token" \
    >>"$logfile" 2>&1 </dev/null &
  pid=$!
  printf '%s %s\n' "$pid" "$token" >"$pidfile" \
    || { kill "$pid" 2>/dev/null || true; return 1; }
  n=0
  while ! shipyard_continuity_pid_is_guard "$pid" "$token" "$heartbeat"; do
    if ! kill -0 "$pid" 2>/dev/null || [ "$n" -ge 20 ]; then
      rm -f "$pidfile" "$heartbeat"
      return 1
    fi
    sleep 0.05
    n=$((n + 1))
  done
  printf 'parent continuity guard started for Codex session %s\n' "$AGTERM_SESSION_ID"
}

shipyard_continuity_stop_all() {
  local state f pid token heartbeat log n
  state=$(shipyard_continuity_state_dir 2>/dev/null) || return 0
  for f in "$state"/continuity-*.pid; do
    [ -f "$f" ] || continue
    read -r pid token <"$f" || true
    heartbeat="${f%.pid}.heartbeat"
    if [ -n "${pid:-}" ] && [ -n "${token:-}" ] \
      && shipyard_continuity_pid_is_guard "$pid" "$token" "$heartbeat"; then
      kill "$pid" 2>/dev/null || true
      n=0
      while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 20 ]; do
        sleep 0.05
        n=$((n + 1))
      done
    fi
    log="${f%.pid}.log"
    rm -f "$f" "$heartbeat" "$log"
  done
  rm -f "$state"/continuity-*.heartbeat "$state"/continuity-*.log 2>/dev/null || true
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    watch) shift; shipyard_continuity_watch "$@" ;;
    *) echo 'usage: shipyard-continuity.sh watch <session> <socket> <pane> <pidfile> <heartbeat> <token>' >&2; exit 2 ;;
  esac
fi
