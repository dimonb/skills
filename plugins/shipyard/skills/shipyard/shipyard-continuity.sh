#!/usr/bin/env bash
# shipyard-continuity.sh - keep a Codex parent supervising after a capacity stop.
#
# Source this file for the lifecycle and parser functions. `shipyard-launch.sh`
# starts one session-hosted watcher per parent agterm session; the watcher exits
# when that session disappears, and `shipyard-down.sh` stops every watcher after
# the last ship slot is removed.

SHIPYARD_CONTINUITY_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shipyard-continuity.sh"

shipyard_continuity_reset() {
  SHIPYARD_CONTINUITY_HANDLED_CAPACITY=0
  SHIPYARD_CONTINUITY_HANDLED_CAPACITY_KEY=""
  SHIPYARD_CONTINUITY_CAPACITY_ARMED=1
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
  SHIPYARD_CONTINUITY_OWNED_EMPTY_READS=0
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
      '⚠ Selected model is at capacity. Please try a different model.')
        total=$((total + 1)); current=$((current + 1))
        key=$(printf '%s\n%s' "$anchor" "$line" | cksum | awk '{print $1 "-" $2}') ;;
      '• '*)
        if ! shipyard_continuity_is_service_line "$line"; then
          current=0
          anchor="$line"
        fi ;;
      '›'|'› '|'› Ask Codex to do anything') ;;
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
    '›'|'› '|'› Ask Codex to do anything') return 0 ;;
    *) return 1 ;;
  esac
}

shipyard_continuity_live_prompt() {
  local screen="$1" line prompt=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '›'|'› '*) prompt="$line" ;; esac
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
  fi

  # Once real assistant prose follows the latest banner, every visible capacity event
  # is historical. Service lines such as Working, Ran, or Goal paused are deliberately
  # excluded from that clearance.
  if [ "$current" -eq 0 ]; then
    SHIPYARD_CONTINUITY_HANDLED_CAPACITY="$total"
    SHIPYARD_CONTINUITY_HANDLED_CAPACITY_KEY="$key"
    SHIPYARD_CONTINUITY_CAPACITY_ARMED=1
  elif { [ "$SHIPYARD_CONTINUITY_CAPACITY_ARMED" -eq 1 ] \
      || [ "$total" -gt "$SHIPYARD_CONTINUITY_HANDLED_CAPACITY" ] \
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
      SHIPYARD_CONTINUITY_CAPACITY_ARMED=0
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
  SHIPYARD_CONTINUITY_OWNED_EMPTY_READS=0
}

shipyard_continuity_clear_owned() {
  SHIPYARD_CONTINUITY_OWNED_COMMAND=""
  SHIPYARD_CONTINUITY_OWNED_ACTION=""
  SHIPYARD_CONTINUITY_OWNED_CAPACITY=0
  SHIPYARD_CONTINUITY_OWNED_CAPACITY_KEY=""
  SHIPYARD_CONTINUITY_RETURN_ATTEMPTED=0
  SHIPYARD_CONTINUITY_OWNED_EMPTY_READS=0
}

# Finish watcher-owned text. Return 0 after Return succeeds, 3 when a prior
# ambiguous Return visibly submitted, 2 while ownership is safely retained, and
# 1 after a conflict relinquishes ownership without sending Return.
shipyard_continuity_finish_owned() {
  local sid="$1" socket="$2" pane="$3" window="$4" screen prompt idle
  screen=$(shipyard_continuity_read "$sid" "$socket" "$pane") || return 2
  prompt=$(shipyard_continuity_live_prompt "$screen")
  idle=$(shipyard_continuity_window_idle "$window" "$socket" 2>/dev/null) || idle=-1
  if [ "$SHIPYARD_CONTINUITY_RETURN_ATTEMPTED" -eq 1 ] \
    && shipyard_continuity_prompt_empty "$screen"; then
    if [ "${SHIPYARD_CONTINUITY_OWNED_IDLE:--1}" -ge 0 ] \
      && { [ "$idle" -lt 0 ] || [ "$idle" -lt "$SHIPYARD_CONTINUITY_OWNED_IDLE" ]; }; then
      shipyard_continuity_clear_owned
      return 1
    fi
    shipyard_continuity_clear_owned
    return 3
  fi
  if [ "$SHIPYARD_CONTINUITY_RETURN_ATTEMPTED" -eq 0 ] \
    && shipyard_continuity_prompt_empty "$screen"; then
    # A capture can lag one successful type request. Confirm the empty prompt on a
    # later read before deciding that our staged text disappeared; the bounded
    # confirmation also unlatches zero or unavailable activity baselines.
    SHIPYARD_CONTINUITY_OWNED_EMPTY_READS=$((SHIPYARD_CONTINUITY_OWNED_EMPTY_READS + 1))
    if [ "$SHIPYARD_CONTINUITY_OWNED_EMPTY_READS" -ge 2 ]; then
      shipyard_continuity_clear_owned
      return 1
    fi
    return 2
  fi
  if [ "$prompt" != "› $SHIPYARD_CONTINUITY_OWNED_COMMAND" ]; then
    shipyard_continuity_clear_owned
    return 1
  fi
  if [ "${SHIPYARD_CONTINUITY_OWNED_IDLE:--1}" -ge 0 ] \
    && [ "$idle" -ge 0 ] && [ "$idle" -lt "$SHIPYARD_CONTINUITY_OWNED_IDLE" ]; then
    SHIPYARD_CONTINUITY_OWNED_IDLE="$idle"
    return 2
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
  idle=$(shipyard_continuity_window_idle "$window" "$socket" 2>/dev/null) || idle=-1
  SHIPYARD_CONTINUITY_OWNED_IDLE="$idle"
  screen=$(shipyard_continuity_read "$sid" "$socket" "$pane") || return 1
  shipyard_continuity_prompt_empty "$screen" || return 1
  shipyard_continuity_begin_owned "$message" "$action"
  printf '%s' "$message" | agtermctl session type --stdin \
    --target "$sid" --pane "$pane" --socket "$socket" >/dev/null 2>&1 || type_rc=$?
  sleep "${_SHIPYARD_CONTINUITY_SETTLE_DELAY:-0.02}"
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
  printf '%s' "$tree" | jq -e '
    .ok == true and (.result.tree.workspaces | type) == "array"
    and all(.result.tree.workspaces[];
      type == "object" and (.name | type) == "string"
      and (.sessions | type) == "array"
      and all(.sessions[];
        type == "object" and (.id | type) == "string" and (.id | length) > 0
        and (.name | type) == "string"))
  ' >/dev/null 2>&1 || return 2
  if printf '%s' "$tree" | jq -e --arg sid "$sid" \
    '.result.tree.workspaces[].sessions[] | select(.id == $sid)' >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

shipyard_continuity_write_record() {
  local path="$1" token="$2" rest="$3" tmp
  tmp="$path.$token.tmp.$$"
  printf '%s %s\n' "$token" "$rest" >"$tmp" 2>/dev/null || return 1
  if ! mv -f "$tmp" "$path" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
}

# A matching stop request is acknowledged before the watcher exits. A ping is
# acknowledged and the watcher continues. Unrelated or malformed requests are ignored.
shipyard_continuity_control_check() {
  local control="$1" ack="$2" token="$3" seen verb nonce
  [ -f "$control" ] || return 1
  read -r seen verb nonce <"$control" || return 1
  [ "$seen" = "$token" ] || return 1
  case "$verb" in
    ping|stop) ;;
    *) return 1 ;;
  esac
  [ -n "$nonce" ] || return 1
  shipyard_continuity_write_record "$ack" "$token" "$verb $nonce" || return 1
  [ "$verb" = stop ]
}

shipyard_continuity_watch() {
  local sid="$1" socket="$2" pane="$3" window="$4" pidfile="$5" heartbeat="$6"
  local control="$7" ack="$8" token="$9" lock="${10}" lock_token="${11}" logfile="${12}"
  local screen now action submit_rc exists_rc cleanup interval="${_SHIPYARD_CONTINUITY_POLL_SECS:-5}"
  printf -v cleanup 'shipyard_continuity_remove_owned_state %q %q "" "" %q' \
    "$pidfile" "$heartbeat" "$token"
  trap "$cleanup" EXIT
  trap 'exit 0' INT TERM
  shipyard_continuity_reset
  if ! shipyard_continuity_wait_publication "$pidfile" "$token"; then
    # The starter owns this lock until it publishes or exits. A timed-out watcher
    # may reclaim it only after proving that owner is gone.
    shipyard_continuity_reclaim_dead_lock "$lock" "$lock_token" || true
    rm -f "$logfile"
    return 1
  fi
  sleep "${_SHIPYARD_CONTINUITY_INITIAL_DELAY:-0}"
  while true; do
    shipyard_continuity_control_check "$control" "$ack" "$token" && return 0
    shipyard_continuity_write_record "$heartbeat" "$token" "$(date +%s)" || return 1
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

# Run the watcher as the foreground process of a dedicated agterm session. Codex
# tool processes reap detached descendants after the tool exits, so nohup alone
# cannot provide parent continuity there.
shipyard_continuity_watch_foreground() {
  local pidfile="$5" heartbeat="$6" control="$7" ack="$8" token="$9"
  shipyard_continuity_write_record "$pidfile" "$$" "$token" || return 1
  shipyard_continuity_watch "$@"
}

shipyard_continuity_state_dir() {
  if [ -n "${_SHIPYARD_CONTINUITY_DIR:-}" ]; then
    mkdir -p "$_SHIPYARD_CONTINUITY_DIR" || return 1
    printf '%s' "$_SHIPYARD_CONTINUITY_DIR"
  else
    shipyard_mailbox_ensure
  fi
}

shipyard_continuity_pid_is_healthy() {
  local pid="$1" token="$2" heartbeat="$3" seen beat now stale
  kill -0 "$pid" 2>/dev/null || return 1
  shipyard_continuity_heartbeat_is_healthy "$token" "$heartbeat"
}

shipyard_continuity_heartbeat_is_healthy() {
  local token="$1" heartbeat="$2" seen beat now stale
  [ -f "$heartbeat" ] || return 1
  read -r seen beat <"$heartbeat" || return 1
  [ "$seen" = "$token" ] || return 1
  case "$beat" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  stale="${_SHIPYARD_CONTINUITY_STALE_SECS:-30}"
  [ $((now - beat)) -le "$stale" ]
}

shipyard_continuity_remove_owned_state() {
  local pidfile="$1" heartbeat="$2" control="$3" ack="$4" token="$5"
  local path pid seen rest
  if [ -f "$pidfile" ]; then
    read -r pid seen <"$pidfile" || true
    [ "${seen:-}" = "$token" ] && rm -f "$pidfile"
  fi
  for path in "$heartbeat" "$control" "$ack"; do
    if [ -f "$path" ]; then
      read -r seen rest <"$path" || true
      [ "${seen:-}" = "$token" ] && rm -f "$path"
    fi
    rm -f "$path.$token.tmp."* 2>/dev/null || true
  done
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

shipyard_continuity_request() {
  local verb="$1" pid="$2" token="$3" control="$4" ack="$5" heartbeat="${6:-}"
  local nonce n=0 seen got_verb got_nonce
  nonce="$$-$RANDOM-$(date +%s)"
  shipyard_continuity_write_record "$control" "$token" "$verb $nonce" || return 1
  while [ "$n" -lt "${_SHIPYARD_CONTINUITY_CONTROL_POLLS:-70}" ]; do
    if [ -f "$ack" ]; then
      read -r seen got_verb got_nonce <"$ack" || true
      if [ "${seen:-}" = "$token" ] && [ "${got_verb:-}" = "$verb" ] \
        && [ "${got_nonce:-}" = "$nonce" ]; then
        return 0
      fi
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      [ -n "$heartbeat" ] && shipyard_continuity_heartbeat_is_healthy "$token" "$heartbeat" \
        || return 1
    fi
    sleep "${_SHIPYARD_CONTINUITY_CONTROL_SLEEP:-0.1}"
    n=$((n + 1))
  done
  return 1
}

shipyard_continuity_wait_state_gone() {
  local pidfile="$1" token="$2" n=0 pid seen
  while [ "$n" -lt 30 ]; do
    [ -f "$pidfile" ] || return 0
    read -r pid seen <"$pidfile" || return 0
    [ "${seen:-}" != "$token" ] && return 0
    sleep 0.05
    n=$((n + 1))
  done
  return 1
}

shipyard_continuity_wait_publication() {
  local pidfile="$1" token="$2" n=0 pid seen
  while [ "$n" -lt "${_SHIPYARD_CONTINUITY_PUBLICATION_POLLS:-20}" ]; do
    if [ -f "$pidfile" ]; then
      read -r pid seen <"$pidfile" || true
      [ "${pid:-}" = "$$" ] && [ "${seen:-}" = "$token" ] && return 0
    fi
    sleep "${_SHIPYARD_CONTINUITY_PUBLICATION_SLEEP:-0.05}"
    n=$((n + 1))
  done
  return 1
}

shipyard_continuity_legacy_lock_reclaim() {
  local lock="$1" age="$2" owner pid="" token=""
  owner="$lock/owner"
  if [ -f "$owner" ]; then
    read -r pid token <"$owner" || true
    case "$pid" in ''|0|0*|*[!0-9]*) pid="" ;; esac
    [ -n "$token" ] || pid=""
    if [ -n "$pid" ]; then
      kill -0 "$pid" 2>/dev/null && return 1
      rm -f "$owner"
      shipyard_continuity_remove_dead_lock_temps "$lock"
      rmdir "$lock" 2>/dev/null
      return $?
    fi
    [ "$age" -ge 20 ] || return 1
    rm -f "$owner"
  else
    [ "$age" -ge 20 ] || return 1
  fi
  shipyard_continuity_remove_dead_lock_temps "$lock"
  rmdir "$lock" 2>/dev/null
}

# Bash 3.2 has no BASHPID and $$ keeps the parent shell's PID inside a
# background subshell. Ask a direct child for its PPID without wrapping that
# child in command substitution, then return the value through a global.
shipyard_continuity_set_current_pid() {
  local dir="$1" probe pid
  probe=$(mktemp "$dir/continuity-owner.XXXXXXXX") || return 1
  if ! sh -c 'printf "%s\n" "$PPID" >"$1"' shipyard-pid-probe "$probe"; then
    rm -f "$probe"
    return 1
  fi
  read -r pid <"$probe" || pid=""
  rm -f "$probe"
  case "$pid" in ''|0|0*|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  SHIPYARD_CONTINUITY_CURRENT_PID="$pid"
}

shipyard_continuity_acquire_lock() {
  local lock="$1" n=0 record pid token owner_pid claim claim_path lock_dir lock_name valid
  lock_dir=${lock%/*}
  shipyard_continuity_set_current_pid "$lock_dir" || return 1
  owner_pid="$SHIPYARD_CONTINUITY_CURRENT_PID"
  SHIPYARD_CONTINUITY_LOCK_TOKEN="$owner_pid-$RANDOM-$(date +%s)"
  SHIPYARD_CONTINUITY_LOCK_OWNER_PID="$owner_pid"
  lock_name=${lock##*/}
  claim="$lock_name.claim.$owner_pid.$SHIPYARD_CONTINUITY_LOCK_TOKEN"
  claim_path="$lock_dir/$claim"
  mkdir "$claim_path" 2>/dev/null || return 1
  while true; do
    # `ln` follows an existing directory and would create the claim inside it, so
    # legacy directories and symlinks to claim directories must be handled before
    # attempting the atomic symlink.
    if [ -d "$lock" ] && [ ! -L "$lock" ]; then
      shipyard_continuity_legacy_lock_reclaim "$lock" "$n" && continue
    elif [ -L "$lock" ]; then
      record=$(readlink "$lock" 2>/dev/null) || record=""
      valid=1
      case "$record" in
        "$lock_name.claim."*)
          token=${record#"$lock_name.claim."}
          pid=${token%%.*}
          token=${token#*.}
          ;;
        *) valid=0; pid=""; token="" ;;
      esac
      case "$pid" in ''|0|0*|*[!0-9]*) valid=0 ;; esac
      if { [ "$valid" -eq 1 ] && ! kill -0 "$pid" 2>/dev/null; } \
        || { [ "$valid" -eq 0 ] && [ "$n" -ge 20 ]; }; then
        if shipyard_continuity_reap_claim "$lock" "$record" "$claim" "$n"; then
          return 0
        fi
      fi
    elif sleep "${_SHIPYARD_CONTINUITY_BEFORE_CLAIM_DELAY:-0}" \
      && ln -s -n "$claim" "$lock" 2>/dev/null; then
      shipyard_continuity_cleanup_reapers "$lock"
      return 0
    elif [ -e "$lock" ] && [ "$n" -ge 20 ]; then
      rm -f "$lock"
      continue
    fi
    if [ "$n" -ge 100 ]; then
      rmdir "$claim_path" 2>/dev/null || true
      return 1
    fi
    sleep 0.05
    n=$((n + 1))
  done
}

# Serialize stale-claim replacement so two reclaimers cannot both pass a
# compare-then-delete window. The replacement is installed before the reaper is
# released, leaving no ownerless admission gap.
shipyard_continuity_reap_claim() {
  local lock="$1" expected="$2" replacement="$3" age="$4"
  local owner_pid token lock_dir source candidate path suffix reaper_pid valid_target=0 rc=1
  lock_dir=${lock%/*}
  shipyard_continuity_set_current_pid "$lock_dir" || return 1
  owner_pid="$SHIPYARD_CONTINUITY_CURRENT_PID"
  token="$owner_pid-$RANDOM-$(date +%s)"
  case "$expected" in
    "${lock##*/}.claim."*/*|*'..'*) source="" ;;
    "${lock##*/}.claim."*) source="$lock_dir/$expected"; valid_target=1 ;;
    *) source="" ;;
  esac
  if [ "$valid_target" -eq 1 ] && [ ! -d "$source" ]; then
    source=""
    for path in "$lock_dir/$expected".reap.*; do
      [ -d "$path" ] || continue
      suffix=${path##*.reap.}
      reaper_pid=${suffix%%.*}
      case "$reaper_pid" in ''|0|0*|*[!0-9]*) ;; *)
        kill -0 "$reaper_pid" 2>/dev/null && return 1
        ;;
      esac
      source="$path"
      break
    done
  fi
  # A malformed old symlink has no claim directory. Materialize a unique
  # election node only after its grace period; valid claims always arrive with one.
  if [ -z "$source" ] && [ "$age" -ge 20 ]; then
    source="$lock.claim.invalid.$(printf '%s' "$expected" | cksum | awk '{print $1 "-" $2}')"
    mkdir "$source" 2>/dev/null || true
  fi
  [ -n "$source" ] || return 1
  candidate="$source.reap.$owner_pid.$token"
  mv "$source" "$candidate" 2>/dev/null || return 1
  if [ -L "$lock" ] && [ "$(readlink "$lock" 2>/dev/null)" = "$expected" ]; then
    sleep "${_SHIPYARD_CONTINUITY_RECLAIM_DELAY:-0}"
    rm -f "$lock"
    if [ -z "$replacement" ] || ln -s -n "$replacement" "$lock" 2>/dev/null; then
      rc=0
    fi
  fi
  rmdir "$candidate" 2>/dev/null || true
  [ "$rc" -ne 0 ] || shipyard_continuity_cleanup_reapers "$lock"
  return "$rc"
}

shipyard_continuity_cleanup_reapers() {
  local lock="$1" path suffix pid record lock_dir lock_name
  lock_dir=${lock%/*}
  lock_name=${lock##*/}
  record=""
  [ ! -L "$lock" ] || record=$(readlink "$lock" 2>/dev/null) || true
  if [ -d "$lock.reap" ]; then
    shipyard_continuity_legacy_lock_reclaim "$lock.reap" 20 || true
  fi
  for path in "$lock_dir/$lock_name.claim."*; do
    [ -d "$path" ] || continue
    case "$path" in
      *.reap.*)
        suffix=${path##*.reap.}
        pid=${suffix%%.*}
        case "$pid" in ''|0|0*|*[!0-9]*) ;; *)
          kill -0 "$pid" 2>/dev/null && continue
          ;;
        esac
        ;;
      *)
        [ "${path##*/}" = "$record" ] && continue
        suffix=${path#"$lock_dir/$lock_name.claim."}
        pid=${suffix%%.*}
        case "$pid" in ''|0|0*|*[!0-9]*) ;; *)
          kill -0 "$pid" 2>/dev/null && continue
          ;;
        esac
        ;;
    esac
    rmdir "$path" 2>/dev/null || true
  done
}

shipyard_continuity_release_lock() {
  local lock="$1" token="$2" owner_pid="$3" claim claim_path
  [ -L "$lock" ] || return 0
  claim="${lock##*/}.claim.$owner_pid.$token"
  claim_path="${lock%/*}/$claim"
  [ "$(readlink "$lock" 2>/dev/null)" = "$claim" ] || return 1
  rm -f "$lock"
  rmdir "$claim_path" 2>/dev/null || true
}

shipyard_continuity_remove_dead_lock_temps() {
  local lock="$1" tmp name pid
  for tmp in "$lock"/owner.*.tmp.*; do
    [ -f "$tmp" ] || continue
    name=${tmp##*/}
    pid=${name##*.tmp.}
    case "$pid" in
      ''|0|0*|*[!0-9]*) rm -f "$tmp" ;;
      *) kill -0 "$pid" 2>/dev/null || rm -f "$tmp" ;;
    esac
  done
}

shipyard_continuity_reclaim_dead_lock() {
  local lock="$1" token="$2" record pid seen
  [ -L "$lock" ] || return 1
  record=$(readlink "$lock" 2>/dev/null) || return 1
  seen=${record#"${lock##*/}.claim."}
  [ "$seen" != "$record" ] || return 1
  pid=${seen%%.*}
  seen=${seen#*.}
  case "$pid" in ''|0|0*|*[!0-9]*) return 1 ;; esac
  [ "$seen" = "$token" ] || return 1
  kill -0 "$pid" 2>/dev/null && return 1
  shipyard_continuity_reap_claim "$lock" "$record" "" 20
}

shipyard_continuity_stop_in_progress() {
  local state="$1" marker="$state/continuity-stopping" pid token claim
  [ -f "$marker" ] || return 1
  read -r pid token <"$marker" || return 1
  case "$pid" in ''|0|0*|*[!0-9]*) return 1 ;; esac
  [ -n "$token" ] || return 1
  claim="continuity-lifecycle.lock.claim.$pid.$token"
  [ -L "$state/continuity-lifecycle.lock" ] \
    && [ "$(readlink "$state/continuity-lifecycle.lock" 2>/dev/null)" = "$claim" ] \
    && kill -0 "$pid" 2>/dev/null
}

shipyard_continuity_generation() {
  local state="$1" generation=0
  if [ -f "$state/continuity-generation" ]; then
    read -r generation <"$state/continuity-generation" || generation=0
  fi
  case "$generation" in ''|*[!0-9]*) generation=0 ;; esac
  printf '%s' "$generation"
}

shipyard_continuity_remove_dead_intents() {
  local state="$1" intent name pid
  for intent in "$state"/continuity-start-*.intent; do
    [ -f "$intent" ] || continue
    name=${intent##*/continuity-start-}
    pid=${name%%-*}
    case "$pid" in ''|0|0*|*[!0-9]*) continue ;; esac
    kill -0 "$pid" 2>/dev/null || rm -f "$intent"
  done
}

shipyard_continuity_remove_dead_owner_probes() {
  local state="$1" probe pid
  for probe in "$state"/continuity-owner.*; do
    [ -f "$probe" ] || continue
    read -r pid <"$probe" || pid=""
    case "$pid" in
      ''|0|0*|*[!0-9]*) rm -f "$probe" ;;
      *) kill -0 "$pid" 2>/dev/null || rm -f "$probe" ;;
    esac
  done
}

shipyard_continuity_shq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

shipyard_continuity_start_agterm_session_locked() {
  local pidfile="$1" heartbeat="$2" control="$3" ack="$4" logfile="$5"
  local token="$6" lock="$7" lock_token="$8" command="" arg guard_session pid seen n=0
  for arg in /bin/bash "$SHIPYARD_CONTINUITY_SCRIPT" watch-foreground \
    "$AGTERM_SESSION_ID" "$AGTERM_SOCKET" "${AGTERM_PANE:-primary}" "$AGTERM_WINDOW_ID" \
    "$pidfile" "$heartbeat" "$control" "$ack" "$token" "$lock" "$lock_token" "$logfile"; do
    command="$command $(shipyard_continuity_shq "$arg")"
  done
  : >"$logfile" || return 1
  guard_session=$(agtermctl session new --after "$AGTERM_SESSION_ID" --no-select \
    --name "shipyard-goal-$(printf '%.8s' "$AGTERM_SESSION_ID")" \
    --command "${command# }" --socket "$AGTERM_SOCKET" 2>>"$logfile") || return 1
  while [ "$n" -lt "${_SHIPYARD_CONTINUITY_PUBLICATION_POLLS:-40}" ]; do
    if [ -f "$pidfile" ]; then
      read -r pid seen <"$pidfile" || true
      if [ "${seen:-}" = "$token" ] \
        && shipyard_continuity_heartbeat_is_healthy "$token" "$heartbeat"; then
        printf 'parent continuity guard started for Codex session %s\n' "$AGTERM_SESSION_ID"
        return 0
      fi
    fi
    sleep "${_SHIPYARD_CONTINUITY_PUBLICATION_SLEEP:-0.05}"
    n=$((n + 1))
  done
  agtermctl session close --target "$guard_session" --socket "$AGTERM_SOCKET" >/dev/null 2>&1 || true
  shipyard_continuity_remove_owned_state "$pidfile" "$heartbeat" "$control" "$ack" "$token"
  rm -f "$logfile"
  return 1
}

shipyard_continuity_start_nohup_locked() {
  local pidfile="$1" heartbeat="$2" control="$3" ack="$4" logfile="$5"
  local token="$6" lock="$7" lock_token="$8" pid n=0
  nohup bash "$SHIPYARD_CONTINUITY_SCRIPT" watch "$AGTERM_SESSION_ID" \
    "$AGTERM_SOCKET" "${AGTERM_PANE:-primary}" "$AGTERM_WINDOW_ID" \
    "$pidfile" "$heartbeat" "$control" "$ack" "$token" "$lock" "$lock_token" "$logfile" \
    >>"$logfile" 2>&1 </dev/null &
  pid=$!
  sleep "${_SHIPYARD_CONTINUITY_PUBLISH_DELAY:-0}"
  shipyard_continuity_write_record "$pidfile" "$pid" "$token" \
    || { shipyard_continuity_terminate_pid "$pid" || true; rm -f "$logfile"; return 1; }
  while ! shipyard_continuity_pid_is_healthy "$pid" "$token" "$heartbeat"; do
    if ! kill -0 "$pid" 2>/dev/null || [ "$n" -ge 20 ]; then
      shipyard_continuity_terminate_pid "$pid" || true
      shipyard_continuity_remove_owned_state "$pidfile" "$heartbeat" "$control" "$ack" "$token"
      rm -f "$logfile"
      return 1
    fi
    sleep 0.05
    n=$((n + 1))
  done
  printf 'parent continuity guard started for Codex session %s\n' "$AGTERM_SESSION_ID"
}

shipyard_continuity_start_locked() {
  local state="$1" key="$2" lock="$3" lock_token="$4"
  local pidfile heartbeat control ack logfile pid token old_token
  pidfile="$state/continuity-$key.pid"
  heartbeat="$state/continuity-$key.heartbeat"
  control="$state/continuity-$key.control"
  ack="$state/continuity-$key.ack"
  logfile="$state/continuity-$key.log"
  if [ -f "$pidfile" ]; then
    read -r pid old_token <"$pidfile" || true
    if [ -n "${pid:-}" ] && [ -n "${old_token:-}" ]; then
      if shipyard_continuity_heartbeat_is_healthy "$old_token" "$heartbeat"; then
        shipyard_continuity_request ping "$pid" "$old_token" "$control" "$ack" "$heartbeat" \
          && return 0
        return 1
      elif kill -0 "$pid" 2>/dev/null; then
        shipyard_continuity_request ping "$pid" "$old_token" "$control" "$ack" && return 0
        return 1
      fi
    fi
    if [ -n "${old_token:-}" ]; then
      shipyard_continuity_remove_owned_state "$pidfile" "$heartbeat" "$control" "$ack" "$old_token"
    else
      rm -f "$pidfile" "$heartbeat" "$control" "$ack"
    fi
  fi

  token="$$-$RANDOM-$(date +%s)"
  case "${_SHIPYARD_CONTINUITY_LAUNCH_MODE:-agterm-session}" in
    agterm-session)
      shipyard_continuity_start_agterm_session_locked \
        "$pidfile" "$heartbeat" "$control" "$ack" "$logfile" \
        "$token" "$lock" "$lock_token" ;;
    nohup)
      shipyard_continuity_start_nohup_locked \
        "$pidfile" "$heartbeat" "$control" "$ack" "$logfile" \
        "$token" "$lock" "$lock_token" ;;
    *) return 1 ;;
  esac
}

shipyard_continuity_start() {
  local backend="$1" state key lock lock_token lock_owner_pid rc owner_pid intent_token intent
  local start_generation current_generation recorded_generation intent_session
  [ "$backend" = agterm ] || return 0
  [ -n "${CODEX_SESSION_ID:-}${CODEX_THREAD_ID:-}" ] || return 0
  [ "${AGTERM_ENABLED:-}" = 1 ] || return 0
  [ -n "${AGTERM_SESSION_ID:-}" ] && [ -n "${AGTERM_SOCKET:-}" ] \
    && [ -n "${AGTERM_WINDOW_ID:-}" ] || return 0
  command -v agtermctl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  state=$(shipyard_continuity_state_dir) || return 1
  key=$(printf '%s' "$AGTERM_SESSION_ID" | tr -c 'A-Za-z0-9._-' '_')
  shipyard_continuity_set_current_pid "$state" || return 1
  owner_pid="$SHIPYARD_CONTINUITY_CURRENT_PID"
  intent_token="$owner_pid-$RANDOM-$(date +%s)"
  intent="$state/continuity-start-$intent_token.intent"
  start_generation=$(shipyard_continuity_generation "$state")
  sleep "${_SHIPYARD_CONTINUITY_BEFORE_INTENT_DELAY:-0}"
  printf '%s %s\n' "$start_generation" "$AGTERM_SESSION_ID" >"$intent" 2>/dev/null || return 1
  if shipyard_continuity_stop_in_progress "$state"; then
    rm -f "$intent"
    return 0
  fi
  sleep "${_SHIPYARD_CONTINUITY_ADMISSION_DELAY:-0}"
  lock="$state/continuity-lifecycle.lock"
  if ! shipyard_continuity_acquire_lock "$lock"; then
    rm -f "$intent"
    return 1
  fi
  lock_token="$SHIPYARD_CONTINUITY_LOCK_TOKEN"
  lock_owner_pid="$SHIPYARD_CONTINUITY_LOCK_OWNER_PID"
  rm -f "$state/continuity-stopping"
  rc=0
  shipyard_continuity_remove_dead_intents "$state"
  shipyard_continuity_remove_dead_owner_probes "$state"
  recorded_generation=""
  [ ! -f "$intent" ] || read -r recorded_generation intent_session <"$intent" || true
  current_generation=$(shipyard_continuity_generation "$state")
  if [ -f "$intent" ] && [ "$recorded_generation" = "$current_generation" ]; then
    shipyard_continuity_start_locked "$state" "$key" "$lock" "$lock_token" || rc=$?
  fi
  rm -f "$intent"
  shipyard_continuity_release_lock "$lock" "$lock_token" "$lock_owner_pid" || rc=1
  return "$rc"
}

shipyard_continuity_stop_all() {
  local state f pid token heartbeat control ack log lock lock_token lock_owner_pid marker rc=0 stop_rc
  local generation next_generation
  state=$(shipyard_continuity_state_dir 2>/dev/null) || return 0
  lock="$state/continuity-lifecycle.lock"
  shipyard_continuity_acquire_lock "$lock" || return 1
  lock_token="$SHIPYARD_CONTINUITY_LOCK_TOKEN"
  lock_owner_pid="$SHIPYARD_CONTINUITY_LOCK_OWNER_PID"
  generation=$(shipyard_continuity_generation "$state")
  next_generation=$((generation + 1))
  if ! shipyard_continuity_write_record "$state/continuity-generation" "$next_generation" ""; then
    shipyard_continuity_release_lock "$lock" "$lock_token" "$lock_owner_pid"
    return 1
  fi
  marker="$state/continuity-stopping"
  printf '%s %s\n' "$lock_owner_pid" "$lock_token" >"$marker" 2>/dev/null \
    || { shipyard_continuity_release_lock "$lock" "$lock_token" "$lock_owner_pid"; return 1; }
  rm -f "$state"/continuity-start-*.intent
  rm -f "$state"/continuity-owner.*
  sleep "${_SHIPYARD_CONTINUITY_STOP_AFTER_SWEEP_DELAY:-0}"
  for f in "$state"/continuity-*.pid; do
    [ -f "$f" ] || continue
    read -r pid token <"$f" || true
    heartbeat="${f%.pid}.heartbeat"
    control="${f%.pid}.control"
    ack="${f%.pid}.ack"
    log="${f%.pid}.log"
    stop_rc=0
    if [ -n "${pid:-}" ] && [ -n "${token:-}" ] \
      && { kill -0 "$pid" 2>/dev/null \
        || shipyard_continuity_heartbeat_is_healthy "$token" "$heartbeat"; }; then
      shipyard_continuity_request stop "$pid" "$token" "$control" "$ack" "$heartbeat" || stop_rc=$?
      [ "$stop_rc" -ne 0 ] || shipyard_continuity_wait_state_gone "$f" "$token" || stop_rc=$?
    fi
    if [ "$stop_rc" -eq 0 ] && [ -n "${token:-}" ]; then
      shipyard_continuity_remove_owned_state "$f" "$heartbeat" "$control" "$ack" "$token"
      rm -f "$log"
    else
      rc=1
    fi
  done
  for heartbeat in "$state"/continuity-*.heartbeat "$state"/continuity-*.control \
    "$state"/continuity-*.ack "$state"/continuity-*.log; do
    [ -f "$heartbeat" ] || continue
    [ -f "${heartbeat%.*}.pid" ] || rm -f "$heartbeat"
  done
  # Catch intents registered after the first sweep while the stop marker was live.
  rm -f "$state"/continuity-start-*.intent
  rm -f "$state"/continuity-owner.*
  rm -f "$marker"
  shipyard_continuity_release_lock "$lock" "$lock_token" "$lock_owner_pid" || rc=1
  return "$rc"
}

# 0 cleaned up, 1 still has slots, 2 could not prove the fleet is empty,
# 3 could not stop every watcher.
shipyard_continuity_cleanup_last_slot() {
  local enumeration_status="$1" slots="$2"
  [ "$enumeration_status" -eq 0 ] || return 2
  [ -z "$slots" ] || return 1
  shipyard_continuity_stop_all || return 3
  shipyard_container_prune
  shipyard_container_unpin
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    watch) shift; shipyard_continuity_watch "$@" ;;
    watch-foreground) shift; shipyard_continuity_watch_foreground "$@" >>"${12}" 2>&1 ;;
    *) echo 'usage: shipyard-continuity.sh watch <session> <socket> <pane> <window> <pidfile> <heartbeat> <control> <ack> <token> <lock> <lock-token> <log>' >&2; exit 2 ;;
  esac
fi
