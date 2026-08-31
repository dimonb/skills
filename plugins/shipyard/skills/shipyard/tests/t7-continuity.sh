#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$DIR/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/shipyard-continuity-test.XXXXXXXX") || exit 1
trap 'shipyard_continuity_stop_all >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

# shellcheck source=../shipyard-continuity.sh
. "$SKILL_DIR/shipyard-continuity.sh"

failures=0
check() {
  local want="$1" got="$2" label="$3"
  if [ "$want" = "$got" ]; then
    printf 'ok - %s\n' "$label"
  else
    printf 'not ok - %s (want %q, got %q)\n' "$label" "$want" "$got"
    failures=$((failures + 1))
  fi
}

capacity='⚠ Selected model is at capacity. Please try a different model.'
empty_prompt='› Ask Codex to do anything'

shipyard_continuity_reset
service_after_capacity=$(printf '%s\n%s\n%s\n%s' \
  '• Work completed before the stop.' "$capacity" '• Ran 2 commands · open transcript' "$empty_prompt")
shipyard_continuity_decide "$service_after_capacity" 100
check resume "$SHIPYARD_CONTINUITY_ACTION" "service lines after capacity do not hide the stop"
shipyard_continuity_succeeded resume 100
shipyard_continuity_decide "$service_after_capacity" 101
check "" "$SHIPYARD_CONTINUITY_ACTION" "one capacity banner is consumed once"

shipyard_continuity_reset
stale_working=$(printf '%s\n%s\n%s' "$capacity" '• Working (1m 08s · esc to interrupt)' "$empty_prompt")
shipyard_continuity_decide "$stale_working" 101
check resume "$SHIPYARD_CONTINUITY_ACTION" "stale Working scrollback does not mask capacity"
shipyard_continuity_succeeded resume 101

replacement=$(printf '%s\n%s\n%s\n%s' '• Later work reached another stop.' \
  "$capacity" '• Working (4s)' "$empty_prompt")
shipyard_continuity_decide "$replacement" 102
check resume "$SHIPYARD_CONTINUITY_ACTION" "same-count replacement capacity episode is retried"

shipyard_continuity_reset
human_resumed=$(printf '%s\n%s\n%s\n%s' "$capacity" '› resume' '• Working (4s)' "$empty_prompt")
shipyard_continuity_decide "$human_resumed" 103
check "" "$SHIPYARD_CONTINUITY_ACTION" "a submitted root turn consumes the capacity episode"

shipyard_continuity_reset
nested=$(printf '%s\n%s\n%s' '• Ran child terminal capture' \
  '  └ ⚠ Selected model is at capacity. Please try a different model.' "$empty_prompt")
shipyard_continuity_decide "$nested" 200
check "" "$SHIPYARD_CONTINUITY_ACTION" "indented tool output cannot trigger retry"

shipyard_continuity_reset
resumed=$(printf '%s\n%s\n%s\n%s' "$capacity" '• Continued the interrupted work.' \
  '• Working (2s)' "$empty_prompt")
shipyard_continuity_decide "$resumed" 210
check "" "$SHIPYARD_CONTINUITY_ACTION" "real assistant activity clears stale capacity"

shipyard_continuity_reset
active_empty=$(printf '%s\n%s\n%s' '• Working (1m 08s · esc to interrupt)' \
  '• Goal paused Objective: finish the change.' "$empty_prompt")
SHIPYARD_CONTINUITY_PENDING_GOAL_AT=308
shipyard_continuity_decide "$active_empty" 307
check "" "$SHIPYARD_CONTINUITY_ACTION" "paused goal cannot bypass the post-capacity delay"
shipyard_continuity_decide "$active_empty" 308
check goal "$SHIPYARD_CONTINUITY_ACTION" "active session with empty prompt queues goal resume"

shipyard_continuity_reset
active_draft=$(printf '%s\n%s\n%s' '• Working (1m 08s · esc to interrupt)' \
  '• Goal paused Objective: finish the change.' '› unsent user draft')
SHIPYARD_CONTINUITY_PENDING_GOAL_AT=308
shipyard_continuity_decide "$active_draft" 308
check "" "$SHIPYARD_CONTINUITY_ACTION" "active session with draft is protected"

shipyard_continuity_reset
idle_paused=$(printf '%s\n%s' "$empty_prompt" \
  '  gpt-example high · ./repo · Context 20% used        Goal stalled (/goal resume)')
shipyard_continuity_decide "$idle_paused" 400
check goal "$SHIPYARD_CONTINUITY_ACTION" "idle paused goal resumes"
shipyard_continuity_succeeded goal 400
shipyard_continuity_decide "$idle_paused" 401
check "" "$SHIPYARD_CONTINUITY_ACTION" "one paused goal marker is latched"

# The terminal API must receive text and Return in distinct calls, and the live
# prompt plus real-user idle clock must still belong to the watcher before Return.
mkdir -p "$TMP/bin"
FAKE_LOG="$TMP/agterm.log"
FAKE_PROMPT="$TMP/prompt"
FAKE_IDLE="$TMP/idle"
FAKE_MODE="$TMP/mode"
FAKE_RETURN_FAILURES="$TMP/return-failures"
FAKE_READ_FAILURES="$TMP/read-failures"
export FAKE_LOG FAKE_PROMPT FAKE_IDLE FAKE_MODE FAKE_RETURN_FAILURES FAKE_READ_FAILURES
cat >"$TMP/bin/agtermctl" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "session type" ]; then
  shift 2
  if [ "${1:-}" = --stdin ]; then
    bytes=$(od -An -tx1 | tr -d ' \n')
    printf 'stdin:%s\n' "$bytes" >>"$FAKE_LOG"
    if [ "$bytes" = 0a ]; then
      failures=$(cat "$FAKE_RETURN_FAILURES")
      if [ "$failures" -gt 0 ]; then
        printf '%s\n' "$((failures - 1))" >"$FAKE_RETURN_FAILURES"
        exit 1
      fi
      printf '%s\n' '› Ask Codex to do anything' >"$FAKE_PROMPT"
    elif [ "$(cat "$FAKE_MODE")" = draft-after-text ]; then
      printf '%s\n' '› resumedo not submit this draft' >"$FAKE_PROMPT"
    else
      printf '%s\n' '› resume' >"$FAKE_PROMPT"
      [ "$(cat "$FAKE_MODE")" != activity-after-text ] || printf '%s\n' 0 >"$FAKE_IDLE"
    fi
  fi
  exit 0
fi
if [ "${1:-} ${2:-}" = "session text" ]; then
  failures=$(cat "$FAKE_READ_FAILURES")
  if [ "$failures" -gt 0 ]; then
    printf '%s\n' "$((failures - 1))" >"$FAKE_READ_FAILURES"
    exit 1
  fi
  jq -n --rawfile text "$FAKE_PROMPT" '{ok:true,result:{text:($text | rtrimstr("\n"))}}'
  exit 0
fi
if [ "${1:-}" = tree ]; then
  jq -n --argjson idle "$(cat "$FAKE_IDLE")" \
    '{ok:true,result:{tree:{idleMs:$idle,workspaces:[{sessions:[{id:"test-session"}]}]}}}'
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/bin/agtermctl"
PATH="$TMP/bin:$PATH"
export PATH
_SHIPYARD_CONTINUITY_SETTLE_DELAY=0
_SHIPYARD_CONTINUITY_QUIET_MS=2000
export _SHIPYARD_CONTINUITY_SETTLE_DELAY _SHIPYARD_CONTINUITY_QUIET_MS

reset_fake() {
  printf '%s\n' '› Ask Codex to do anything' >"$FAKE_PROMPT"
  printf '%s\n' 5000 >"$FAKE_IDLE"
  printf '%s\n' normal >"$FAKE_MODE"
  printf '%s\n' 0 >"$FAKE_RETURN_FAILURES"
  printf '%s\n' 0 >"$FAKE_READ_FAILURES"
  : >"$FAKE_LOG"
  shipyard_continuity_reset
}

reset_fake
shipyard_continuity_submit resume resume test-session test-socket primary test-window
check $'stdin:726573756d65\nstdin:0a' "$(cat "$FAKE_LOG")" "text and Return are separate submissions"

reset_fake
printf '%s\n' '› protected user draft' >"$FAKE_PROMPT"
shipyard_continuity_submit resume resume test-session test-socket primary test-window || true
check "" "$(cat "$FAKE_LOG")" "a draft appearing before preflight is untouched"

reset_fake
printf '%s\n' draft-after-text >"$FAKE_MODE"
shipyard_continuity_submit resume resume test-session test-socket primary test-window || true
check 'stdin:726573756d65' "$(cat "$FAKE_LOG")" "a draft appearing after text blocks Return"
check '› resumedo not submit this draft' "$(cat "$FAKE_PROMPT")" "draft conflict is never erased"

reset_fake
printf '%s\n' activity-after-text >"$FAKE_MODE"
shipyard_continuity_submit resume resume test-session test-socket primary test-window || true
check 'stdin:726573756d65' "$(cat "$FAKE_LOG")" "real user activity during submission blocks Return"

reset_fake
printf '%s\n' 1 >"$FAKE_RETURN_FAILURES"
first_rc=0
shipyard_continuity_submit resume resume test-session test-socket primary test-window || first_rc=$?
check 2 "$first_rc" "failed Return retains watcher ownership"
retry_rc=0
shipyard_continuity_finish_owned test-session test-socket primary test-window || retry_rc=$?
check 0 "$retry_rc" "failed Return is retried without typing text again"
check $'stdin:726573756d65\nstdin:0a\nstdin:0a' "$(cat "$FAKE_LOG")" "Return retry never duplicates command text"

reset_fake
printf '%s\n' '› resume' >"$FAKE_PROMPT"
shipyard_continuity_finish_owned test-session test-socket primary test-window || true
check "" "$(cat "$FAKE_LOG")" "pre-existing command text is not watcher-owned"

# Start is idempotent and last-slot cleanup owns the detached watcher.
_SHIPYARD_CONTINUITY_DIR="$TMP/state"
export _SHIPYARD_CONTINUITY_DIR
CODEX_SESSION_ID=test-thread
AGTERM_ENABLED=1
AGTERM_SESSION_ID=test-session
AGTERM_SOCKET=test-socket
AGTERM_WINDOW_ID=test-window
AGTERM_PANE=primary
_SHIPYARD_CONTINUITY_POLL_SECS=0.05
SHIPYARD_AGENT=claude
export CODEX_SESSION_ID AGTERM_ENABLED AGTERM_SESSION_ID AGTERM_SOCKET AGTERM_WINDOW_ID AGTERM_PANE
export SHIPYARD_AGENT
export _SHIPYARD_CONTINUITY_POLL_SECS
reset_fake
printf '%s\n' 4 >"$FAKE_READ_FAILURES"
start_rc=0
shipyard_continuity_start agterm >/dev/null || start_rc=$?
pidfile=$(find "$_SHIPYARD_CONTINUITY_DIR" -name 'continuity-*.pid' -print -quit)
if [ "$start_rc" -ne 0 ] || [ -z "$pidfile" ]; then
  printf 'watcher start diagnostics:\n'
  find "$_SHIPYARD_CONTINUITY_DIR" -name 'continuity-*.log' -exec sed -n '1,80p' {} \;
fi
pid1=$(awk '{print $1}' "$pidfile" 2>/dev/null)
if kill -0 "$pid1" 2>/dev/null; then started=yes; else started=no; fi
check yes "$started" "Codex parent starts a watcher despite a Claude child override"
sleep 0.3
if kill -0 "$pid1" 2>/dev/null; then survived=yes; else survived=no; fi
check yes "$survived" "transient capture failures do not disable the watcher"
shipyard_continuity_start agterm >/dev/null
pid2=$(awk '{print $1}' "$pidfile")
check "$pid1" "$pid2" "automatic start is idempotent per parent session"
read -r stale_pid stale_token <"$pidfile"
printf '%s %s\n' "$stale_token" 1 >"${pidfile%.pid}.heartbeat"
shipyard_continuity_stop_all
if kill -0 "$pid1" 2>/dev/null; then alive=yes; else alive=no; fi
check no "$alive" "lifecycle cleanup stops a stale live watcher"
files=$(find "$_SHIPYARD_CONTINUITY_DIR" -type f -print 2>/dev/null)
check "" "$files" "lifecycle cleanup removes watcher state"

_SHIPYARD_CONTINUITY_INITIAL_DELAY=2
export _SHIPYARD_CONTINUITY_INITIAL_DELAY
shipyard_continuity_start agterm >/dev/null 2>&1 &
starter_pid=$!
n=0
timeout_pidfile=""
while [ -z "$timeout_pidfile" ] && [ "$n" -lt 20 ]; do
  timeout_pidfile=$(find "$_SHIPYARD_CONTINUITY_DIR" -name 'continuity-*.pid' -print -quit)
  [ -n "$timeout_pidfile" ] || sleep 0.05
  n=$((n + 1))
done
timeout_watcher=$(awk '{print $1}' "$timeout_pidfile" 2>/dev/null)
timeout_rc=0
wait "$starter_pid" || timeout_rc=$?
check 1 "$timeout_rc" "startup timeout reports failure"
if [ -n "$timeout_watcher" ] && kill -0 "$timeout_watcher" 2>/dev/null; then
  timeout_alive=yes
else
  timeout_alive=no
fi
check no "$timeout_alive" "startup timeout terminates its detached watcher"
unset _SHIPYARD_CONTINUITY_INITIAL_DELAY

unset CODEX_SESSION_ID CODEX_THREAD_ID
shipyard_continuity_start agterm >/dev/null
non_codex_files=$(find "$_SHIPYARD_CONTINUITY_DIR" -name 'continuity-*.pid' -print)
check "" "$non_codex_files" "non-Codex parent does not start a watcher"

cleanup_calls=0
shipyard_continuity_stop_all() { cleanup_calls=$((cleanup_calls + 1)); }
shipyard_container_prune() { cleanup_calls=$((cleanup_calls + 1)); }
shipyard_container_unpin() { cleanup_calls=$((cleanup_calls + 1)); }
shipyard_continuity_cleanup_last_slot 1 "" || true
check 0 "$cleanup_calls" "failed slot enumeration preserves lifecycle state"
shipyard_continuity_cleanup_last_slot 0 remaining || true
check 0 "$cleanup_calls" "a remaining slot preserves lifecycle state"
shipyard_continuity_cleanup_last_slot 0 ""
check 3 "$cleanup_calls" "successful empty enumeration performs last-slot cleanup"
check 1 "$(grep -Fc 'shipyard_continuity_start "$BACKEND"' "$SKILL_DIR/shipyard-launch.sh")" \
  "child launch wires automatic parent continuity from the parent environment"
check 1 "$(grep -Fc 'shipyard_continuity_cleanup_last_slot' "$SKILL_DIR/shipyard-down.sh")" \
  "last-slot teardown uses status-aware continuity cleanup"

exit "$failures"
