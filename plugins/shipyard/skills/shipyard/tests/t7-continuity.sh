#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$DIR/.." && pwd)"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/shipyard-continuity-test.XXXXXXXX") || exit 1
trap 'shipyard_continuity_stop_all >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

# shellcheck source=../shipyard-continuity.sh
. "$SKILL_DIR/shipyard-continuity.sh"
# shellcheck source=../shipyard-backend.sh
. "$SKILL_DIR/shipyard-backend.sh"

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

runtime_state_paths() {
  find "$_SHIPYARD_CONTINUITY_DIR" -mindepth 1 ! -name continuity-generation -print 2>/dev/null
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
suffixed=$(printf '%s\n%s' "$capacity This is quoted prose." "$empty_prompt")
shipyard_continuity_decide "$suffixed" 201
check "" "$SHIPYARD_CONTINUITY_ACTION" "only the exact root capacity banner triggers retry"
if shipyard_continuity_prompt_empty " › Ask Codex to do anything"; then indented_empty=yes; else indented_empty=no; fi
check no "$indented_empty" "indented prompt output is not a root input box"

shipyard_continuity_reset
resumed=$(printf '%s\n%s\n%s\n%s' "$capacity" '• Continued the interrupted work.' \
  '• Working (2s)' "$empty_prompt")
shipyard_continuity_decide "$resumed" 210
check "" "$SHIPYARD_CONTINUITY_ACTION" "real assistant activity clears stale capacity"

shipyard_continuity_reset
two_banners=$(printf '%s\n%s\n%s\n%s\n%s' '• Older anchor.' "$capacity" \
  '• Latest anchor.' "$capacity" "$empty_prompt")
shipyard_continuity_decide "$two_banners" 220
shipyard_continuity_succeeded resume 220
latest_only=$(printf '%s\n%s\n%s' '• Latest anchor.' "$capacity" "$empty_prompt")
shipyard_continuity_decide "$latest_only" 221
check "" "$SHIPYARD_CONTINUITY_ACTION" "evicting an older banner does not replay the latest one"

shipyard_continuity_reset
same_anchor_first=$(printf '%s\n%s\n%s' '› resume' "$capacity" "$empty_prompt")
shipyard_continuity_decide "$same_anchor_first" 222
shipyard_continuity_succeeded resume 222
intervened=$(printf '%s\n%s\n%s\n%s' '› resume' "$capacity" '› resume' "$empty_prompt")
shipyard_continuity_decide "$intervened" 223
same_anchor_replacement=$(printf '%s\n%s\n%s' '› resume' "$capacity" "$empty_prompt")
shipyard_continuity_decide "$same_anchor_replacement" 224
check resume "$SHIPYARD_CONTINUITY_ACTION" "an observed intervention re-arms an identical replacement episode"

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
  '  gpt-example high · ./repo · Context 20% used        Goal paused (/goal resume)')
shipyard_continuity_decide "$idle_paused" 400
check goal "$SHIPYARD_CONTINUITY_ACTION" "idle paused goal resumes"
shipyard_continuity_succeeded goal 400
shipyard_continuity_decide "$idle_paused" 401
check "" "$SHIPYARD_CONTINUITY_ACTION" "one paused goal marker is latched"

shipyard_continuity_reset
blocked_goal=$(printf '%s\n%s' "$empty_prompt" \
  '  gpt-example high · ./repo · Context 20% used        Goal stalled (/goal resume)')
shipyard_continuity_decide "$blocked_goal" 402
check "" "$SHIPYARD_CONTINUITY_ACTION" "a blocked goal is never resumed automatically"

SHIPYARD_CONTINUITY_PENDING_GOAL_AT=403
shipyard_continuity_decide "$blocked_goal" 403
check goal "$SHIPYARD_CONTINUITY_ACTION" \
  "a watcher-owned post-capacity handoff can resume a stalled goal"

# The terminal API must receive text and Return in distinct calls, and the live
# prompt plus real-user idle clock must still belong to the watcher before Return.
mkdir -p "$TMP/bin"
FAKE_LOG="$TMP/agterm.log"
FAKE_PROMPT="$TMP/prompt"
FAKE_IDLE="$TMP/idle"
FAKE_MODE="$TMP/mode"
FAKE_RETURN_FAILURES="$TMP/return-failures"
FAKE_READ_FAILURES="$TMP/read-failures"
FAKE_STALE_READS="$TMP/stale-reads"
FAKE_LATE_PROMPT="$TMP/late-prompt"
FAKE_GUARD_PID="$TMP/guard-pid"
export FAKE_LOG FAKE_PROMPT FAKE_IDLE FAKE_MODE FAKE_RETURN_FAILURES FAKE_READ_FAILURES
export FAKE_STALE_READS FAKE_LATE_PROMPT FAKE_GUARD_PID
cat >"$TMP/bin/agtermctl" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "session new" ]; then
  shift 2
  command=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --command) command="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [ -n "$command" ] || exit 1
  printf 'session-new:%s\n' "$command" >>"$FAKE_LOG"
  nohup /bin/bash -c "$command" </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" >"$FAKE_GUARD_PID"
  printf '%s\n' guard-session
  exit 0
fi
if [ "${1:-} ${2:-}" = "session close" ]; then
  printf '%s\n' session-close >>"$FAKE_LOG"
  [ ! -s "$FAKE_GUARD_PID" ] || kill "$(cat "$FAKE_GUARD_PID")" 2>/dev/null || true
  exit 0
fi
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
      if [ "$bytes" = 2f676f616c20726573756d65 ]; then
        typed_prompt='› /goal resume'
      else
        typed_prompt='› resume'
      fi
      if [ "$(cat "$FAKE_MODE")" = stale-after-text ]; then
        printf '%s\n' "$typed_prompt" >"$FAKE_LATE_PROMPT"
        printf '%s\n' 1 >"$FAKE_STALE_READS"
      else
        printf '%s\n' "$typed_prompt" >"$FAKE_PROMPT"
      fi
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
  stale=$(cat "$FAKE_STALE_READS")
  if [ "$stale" -gt 0 ]; then
    printf '%s\n' "$((stale - 1))" >"$FAKE_STALE_READS"
  elif [ -s "$FAKE_LATE_PROMPT" ]; then
    cp "$FAKE_LATE_PROMPT" "$FAKE_PROMPT"
    : >"$FAKE_LATE_PROMPT"
  fi
  jq -n --rawfile text "$FAKE_PROMPT" '{ok:true,result:{text:($text | rtrimstr("\n"))}}'
  exit 0
fi
if [ "${1:-}" = tree ]; then
  if [ "$(cat "$FAKE_MODE")" = malformed-tree ]; then
    printf '%s\n' '{"ok":false,"error":"temporary tree failure"}'
    exit 0
  fi
  if [ "$(cat "$FAKE_MODE")" = malformed-session ]; then
    printf '%s\n' '{"ok":true,"result":{"tree":{"idleMs":5000,"workspaces":[{"name":"test-ai","sessions":[{}]}]}}}'
    exit 0
  fi
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
  printf '%s\n' 0 >"$FAKE_STALE_READS"
  : >"$FAKE_LATE_PROMPT"
  : >"$FAKE_GUARD_PID"
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
printf '%s\n' stale-after-text >"$FAKE_MODE"
stale_submit_rc=0
shipyard_continuity_submit resume resume test-session test-socket primary test-window || stale_submit_rc=$?
check 2 "$stale_submit_rc" "one stale empty capture retains watcher ownership"
check resume "$SHIPYARD_CONTINUITY_OWNED_COMMAND" "stale capture cannot strand typed watcher text"
stale_finish_rc=0
shipyard_continuity_finish_owned test-session test-socket primary test-window || stale_finish_rc=$?
check 0 "$stale_finish_rc" "later watcher-text capture completes submission"
check $'stdin:726573756d65\nstdin:0a' "$(cat "$FAKE_LOG")" \
  "stale capture recovery submits one text action and one Return"

reset_fake
printf '%s\n' activity-after-text >"$FAKE_MODE"
shipyard_continuity_submit resume resume test-session test-socket primary test-window || true
check 'stdin:726573756d65' "$(cat "$FAKE_LOG")" "real user activity during submission blocks Return"
printf '%s\n' 100 >"$FAKE_IDLE"
activity_retry_rc=0
shipyard_continuity_finish_owned test-session test-socket primary test-window || activity_retry_rc=$?
check 0 "$activity_retry_rc" "exact watcher text stays owned until activity settles"
check $'stdin:726573756d65\nstdin:0a' "$(cat "$FAKE_LOG")" "settled activity submits without duplicating watcher text"

reset_fake
printf '%s\n' 1 >"$FAKE_RETURN_FAILURES"
shipyard_continuity_submit resume resume test-session test-socket primary test-window || true
printf '%s\n' '› Ask Codex to do anything' >"$FAKE_PROMPT"
printf '%s\n' 0 >"$FAKE_IDLE"
cleared_rc=0
shipyard_continuity_finish_owned test-session test-socket primary test-window || cleared_rc=$?
check 1 "$cleared_rc" "user-cleared text after failed Return is not inferred as success"

reset_fake
shipyard_continuity_begin_owned resume resume
SHIPYARD_CONTINUITY_OWNED_IDLE=5000
printf '%s\n' '› Ask Codex to do anything' >"$FAKE_PROMPT"
printf '%s\n' 0 >"$FAKE_IDLE"
pre_return_clear_rc=0
shipyard_continuity_finish_owned test-session test-socket primary test-window || pre_return_clear_rc=$?
check 2 "$pre_return_clear_rc" "one empty capture does not prematurely release watcher ownership"
pre_return_clear_rc=0
shipyard_continuity_finish_owned test-session test-socket primary test-window || pre_return_clear_rc=$?
check 1 "$pre_return_clear_rc" "confirmed user-cleared text before Return relinquishes ownership"
check "" "$SHIPYARD_CONTINUITY_OWNED_COMMAND" "cleared watcher text cannot wedge later decisions"

reset_fake
shipyard_continuity_begin_owned resume resume
SHIPYARD_CONTINUITY_OWNED_IDLE=0
printf '%s\n' '› Ask Codex to do anything' >"$FAKE_PROMPT"
printf '%s\n' 0 >"$FAKE_IDLE"
zero_baseline_rc=0
shipyard_continuity_finish_owned test-session test-socket primary test-window || zero_baseline_rc=$?
check 2 "$zero_baseline_rc" "zero activity baseline waits for empty-prompt confirmation"
zero_baseline_rc=0
shipyard_continuity_finish_owned test-session test-socket primary test-window || zero_baseline_rc=$?
check 1 "$zero_baseline_rc" "zero activity baseline cannot retain confirmed vanished text"
check "" "$SHIPYARD_CONTINUITY_OWNED_COMMAND" "zero activity baseline releases watcher ownership"

reset_fake
shipyard_continuity_begin_owned resume resume
SHIPYARD_CONTINUITY_OWNED_IDLE=-1
printf '%s\n' '› Ask Codex to do anything' >"$FAKE_PROMPT"
printf '%s\n' malformed-tree >"$FAKE_MODE"
unavailable_baseline_rc=0
shipyard_continuity_finish_owned test-session test-socket primary test-window || unavailable_baseline_rc=$?
check 2 "$unavailable_baseline_rc" "unavailable activity baseline waits for empty-prompt confirmation"
unavailable_baseline_rc=0
shipyard_continuity_finish_owned test-session test-socket primary test-window || unavailable_baseline_rc=$?
check 1 "$unavailable_baseline_rc" "unavailable activity baseline cannot retain confirmed vanished text"
check "" "$SHIPYARD_CONTINUITY_OWNED_COMMAND" "unavailable activity baseline releases watcher ownership"

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

reset_fake
printf '%s\n' 0 >"$FAKE_IDLE"
shipyard_continuity_submit '/goal resume' goal test-session test-socket primary test-window
check $'stdin:2f676f616c20726573756d65\nstdin:0a' "$(cat "$FAKE_LOG")" \
  "active empty prompt steers goal resume despite recent window activity"

printf '%s\n' malformed-session >"$FAKE_MODE"
malformed_exists_rc=0
shipyard_continuity_session_exists test-session test-socket test-window || malformed_exists_rc=$?
check 2 "$malformed_exists_rc" "malformed nested sessions cannot prove the parent absent"
reset_fake

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
session_start_rc=0
shipyard_continuity_start agterm >/dev/null || session_start_rc=$?
session_pidfile=$(find "$_SHIPYARD_CONTINUITY_DIR" -name 'continuity-*.pid' -print -quit)
session_pid=$(awk '{print $1}' "$session_pidfile" 2>/dev/null)
if [ -n "$session_pid" ] && kill -0 "$session_pid" 2>/dev/null; then
  session_alive=yes
else
  session_alive=no
fi
check 0 "$session_start_rc" "Codex continuity starts through a dedicated agterm session"
check yes "$session_alive" "the agterm foreground watcher survives its launcher"
check 1 "$(grep -c '^session-new:.*watch-foreground' "$FAKE_LOG")" \
  "the agterm guard session runs the foreground watcher entrypoint"
shipyard_continuity_stop_all

_SHIPYARD_CONTINUITY_LAUNCH_MODE=nohup
export _SHIPYARD_CONTINUITY_LAUNCH_MODE
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
files=$(runtime_state_paths)
[ -z "$files" ] || find "$_SHIPYARD_CONTINUITY_DIR" -name 'continuity-*.log' -exec sed -n '1,80p' {} \;
check "" "$files" "lifecycle cleanup removes watcher state"

_SHIPYARD_CONTINUITY_INITIAL_DELAY=30
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
timeout_files=$(runtime_state_paths)
check "" "$timeout_files" "startup timeout removes all watcher state and logs"
unset _SHIPYARD_CONTINUITY_INITIAL_DELAY

_SHIPYARD_CONTINUITY_PUBLISH_DELAY=2
export _SHIPYARD_CONTINUITY_PUBLISH_DELAY
shipyard_continuity_start agterm >/dev/null 2>&1 & interrupted_starter=$!
n=0
while ! find "$_SHIPYARD_CONTINUITY_DIR" -name 'continuity-*.log' -print -quit | grep -q . \
  && [ "$n" -lt 20 ]; do
  sleep 0.05
  n=$((n + 1))
done
sleep 1.2
if [ -L "$_SHIPYARD_CONTINUITY_DIR/continuity-lifecycle.lock" ]; then live_lock=yes; else live_lock=no; fi
check yes "$live_lock" "unpublished watcher cannot release a live starter lock"
kill "$interrupted_starter" 2>/dev/null || true
wait "$interrupted_starter" 2>/dev/null || true
interrupted_pidfiles=$(find "$_SHIPYARD_CONTINUITY_DIR" -name 'continuity-*.pid' -print)
check "" "$interrupted_pidfiles" "interrupted unpublished start leaves no published watcher"
unset _SHIPYARD_CONTINUITY_PUBLISH_DELAY
shipyard_continuity_start agterm >/dev/null
restarted_pidfile=$(find "$_SHIPYARD_CONTINUITY_DIR" -name 'continuity-*.pid' -print -quit)
if [ -n "$restarted_pidfile" ]; then restarted=yes; else restarted=no; fi
check yes "$restarted" "start recovers after an interrupted publication"
shipyard_continuity_stop_all

reset_fake
_SHIPYARD_CONTINUITY_BEFORE_CLAIM_DELAY=0.2
export _SHIPYARD_CONTINUITY_BEFORE_CLAIM_DELAY
shipyard_continuity_start agterm >"$TMP/start-one" 2>&1 & start_one=$!
shipyard_continuity_start agterm >"$TMP/start-two" 2>&1 & start_two=$!
start_one_rc=0; wait "$start_one" || start_one_rc=$?
start_two_rc=0; wait "$start_two" || start_two_rc=$?
check 0 "$start_one_rc" "first concurrent start succeeds"
check 0 "$start_two_rc" "second concurrent start joins the same watcher"
starts=$(grep -hFc 'parent continuity guard started' "$TMP/start-one" "$TMP/start-two" | awk '{n += $1} END {print n + 0}')
check 1 "$starts" "concurrent starts create exactly one watcher"
lock_files=$(find "$_SHIPYARD_CONTINUITY_DIR" -name 'continuity-*.lock' -print)
check "" "$lock_files" "concurrent start releases its lifecycle lock"
shipyard_continuity_stop_all
unset _SHIPYARD_CONTINUITY_BEFORE_CLAIM_DELAY

mkdir -p "$_SHIPYARD_CONTINUITY_DIR/continuity-lifecycle.lock"
printf '%s\n' interrupted >"$_SHIPYARD_CONTINUITY_DIR/continuity-lifecycle.lock/owner"
printf '%s\n' stale \
  >"$_SHIPYARD_CONTINUITY_DIR/continuity-lifecycle.lock/owner.dead-token-with-hyphens.tmp.999999"
shipyard_continuity_start agterm >/dev/null
recovered_owner_pidfile=$(find "$_SHIPYARD_CONTINUITY_DIR" -name 'continuity-*.pid' -print -quit)
if [ -n "$recovered_owner_pidfile" ]; then owner_recovered=yes; else owner_recovered=no; fi
check yes "$owner_recovered" "start reclaims hyphenated legacy lock-owner temp publication"
shipyard_continuity_stop_all

mkdir -p "$TMP/outside.reap.999999.dead-token"
printf '%s\n' preserve >"$TMP/outside.reap.999999.dead-token/marker"
ln -s ../outside "$_SHIPYARD_CONTINUITY_DIR/continuity-lifecycle.lock"
shipyard_continuity_start agterm >/dev/null
if [ -f "$TMP/outside.reap.999999.dead-token/marker" ]; then outside_preserved=yes; else outside_preserved=no; fi
check yes "$outside_preserved" "malformed lock target cannot move a sibling directory"
shipyard_continuity_stop_all

reset_fake
stale_claim='continuity-lifecycle.lock.claim.999999.stale-claim'
mkdir "$_SHIPYARD_CONTINUITY_DIR/$stale_claim"
ln -s "$stale_claim" "$_SHIPYARD_CONTINUITY_DIR/continuity-lifecycle.lock"
mkdir -p "$_SHIPYARD_CONTINUITY_DIR/continuity-lifecycle.lock.reap"
printf '%s %s\n' 999999 dead-reaper \
  >"$_SHIPYARD_CONTINUITY_DIR/continuity-lifecycle.lock.reap/owner"
_SHIPYARD_CONTINUITY_RECLAIM_DELAY=0.3
export _SHIPYARD_CONTINUITY_RECLAIM_DELAY
shipyard_continuity_start agterm >"$TMP/reclaim-one" 2>&1 & reclaim_one=$!
shipyard_continuity_start agterm >"$TMP/reclaim-two" 2>&1 & reclaim_two=$!
reclaim_one_rc=0; wait "$reclaim_one" || reclaim_one_rc=$?
reclaim_two_rc=0; wait "$reclaim_two" || reclaim_two_rc=$?
check 0 "$reclaim_one_rc" "first stale-claim contender succeeds"
check 0 "$reclaim_two_rc" "second stale-claim contender joins safely"
reclaim_starts=$(grep -hFc 'parent continuity guard started' "$TMP/reclaim-one" "$TMP/reclaim-two" \
  | awk '{n += $1} END {print n + 0}')
check 1 "$reclaim_starts" "stale-claim replacement admits exactly one watcher"
if [ -d "$_SHIPYARD_CONTINUITY_DIR/continuity-lifecycle.lock.reap" ]; then
  combined_reaper=present
else
  combined_reaper=gone
fi
check gone "$combined_reaper" "stale handoff also cleans an interrupted legacy reaper"
shipyard_continuity_stop_all
unset _SHIPYARD_CONTINUITY_RECLAIM_DELAY

mkdir -p "$_SHIPYARD_CONTINUITY_DIR/continuity-lifecycle.lock.reap"
printf '%s %s\n' 999999 dead-reaper \
  >"$_SHIPYARD_CONTINUITY_DIR/continuity-lifecycle.lock.reap/owner"
shipyard_continuity_stop_all
orphan_reaper_paths=$(runtime_state_paths)
check "" "$orphan_reaper_paths" "lifecycle entry cleans an interrupted legacy reaper"

reset_fake
_SHIPYARD_CONTINUITY_ADMISSION_DELAY=0.4
export _SHIPYARD_CONTINUITY_ADMISSION_DELAY
shipyard_continuity_start agterm >"$TMP/admission-start" 2>&1 & admission_start=$!
n=0
while ! find "$_SHIPYARD_CONTINUITY_DIR" -name 'continuity-start-*.intent' -print -quit | grep -q . \
  && [ "$n" -lt 20 ]; do
  sleep 0.02
  n=$((n + 1))
done
admission_intent=$(find "$_SHIPYARD_CONTINUITY_DIR" -name 'continuity-start-*.intent' -print -quit)
admission_owner=${admission_intent##*/continuity-start-}
admission_owner=${admission_owner%%-*}
if [ -n "$admission_owner" ] && kill -0 "$admission_owner" 2>/dev/null; then
  admission_owner_alive=yes
else
  admission_owner_alive=no
fi
check yes "$admission_owner_alive" "start intent names the live starter process"
admission_stop_rc=0
shipyard_continuity_stop_all || admission_stop_rc=$?
admission_start_rc=0; wait "$admission_start" || admission_start_rc=$?
check 0 "$admission_stop_rc" "stop cancels a start admitted before lock acquisition"
check 0 "$admission_start_rc" "cancelled admitted start exits cleanly"
admission_files=$(runtime_state_paths)
check "" "$admission_files" "stop-first admission race cannot publish late watcher state"
unset _SHIPYARD_CONTINUITY_ADMISSION_DELAY

reset_fake
_SHIPYARD_CONTINUITY_STOP_AFTER_SWEEP_DELAY=0.4
export _SHIPYARD_CONTINUITY_STOP_AFTER_SWEEP_DELAY
shipyard_continuity_stop_all >"$TMP/sweeping-stop" 2>&1 & sweeping_stop=$!
n=0
while [ ! -f "$_SHIPYARD_CONTINUITY_DIR/continuity-stopping" ] && [ "$n" -lt 20 ]; do
  sleep 0.02
  n=$((n + 1))
done
if [ -f "$_SHIPYARD_CONTINUITY_DIR/continuity-stopping" ]; then sweep_seen=yes; else sweep_seen=no; fi
check yes "$sweep_seen" "stop sweep synchronization point is observed"
sweep_start_rc=0
shipyard_continuity_start agterm >"$TMP/during-sweep-start" 2>&1 || sweep_start_rc=$?
sweeping_stop_rc=0; wait "$sweeping_stop" || sweeping_stop_rc=$?
check 0 "$sweeping_stop_rc" "stop with active admission marker succeeds"
check 0 "$sweep_start_rc" "start during stop sweep is cancelled cleanly"
sweep_files=$(runtime_state_paths)
check "" "$sweep_files" "intent created during stop sweep cannot publish late state"
unset _SHIPYARD_CONTINUITY_STOP_AFTER_SWEEP_DELAY

reset_fake
_SHIPYARD_CONTINUITY_BEFORE_INTENT_DELAY=0.4
export _SHIPYARD_CONTINUITY_BEFORE_INTENT_DELAY
shipyard_continuity_start agterm >"$TMP/pre-intent-start" 2>&1 & pre_intent_start=$!
sleep 0.1
pre_intent_stop_rc=0
shipyard_continuity_stop_all || pre_intent_stop_rc=$?
pre_intent_start_rc=0; wait "$pre_intent_start" || pre_intent_start_rc=$?
check 0 "$pre_intent_stop_rc" "stop advances admission generation during pre-intent start"
check 0 "$pre_intent_start_rc" "old-generation start is cancelled cleanly"
pre_intent_files=$(runtime_state_paths)
check "" "$pre_intent_files" "old-generation intent cannot publish after stop returns"
unset _SHIPYARD_CONTINUITY_BEFORE_INTENT_DELAY

reset_fake
_SHIPYARD_CONTINUITY_PUBLISH_DELAY=0.4
_SHIPYARD_CONTINUITY_PUBLICATION_POLLS=40
export _SHIPYARD_CONTINUITY_PUBLISH_DELAY _SHIPYARD_CONTINUITY_PUBLICATION_POLLS
shipyard_continuity_start agterm >"$TMP/racing-start" 2>&1 & racing_start=$!
n=0
while [ ! -L "$_SHIPYARD_CONTINUITY_DIR/continuity-lifecycle.lock" ] && [ "$n" -lt 20 ]; do
  sleep 0.02
  n=$((n + 1))
done
if [ -L "$_SHIPYARD_CONTINUITY_DIR/continuity-lifecycle.lock" ]; then start_lock_seen=yes; else start_lock_seen=no; fi
check yes "$start_lock_seen" "start-wins lifecycle synchronization point is observed"
shipyard_continuity_stop_all >"$TMP/racing-stop" 2>&1 & racing_stop=$!
racing_start_rc=0; wait "$racing_start" || racing_start_rc=$?
racing_stop_rc=0; wait "$racing_stop" || racing_stop_rc=$?
check 0 "$racing_start_rc" "in-flight start publishes before synchronized stop"
check 0 "$racing_stop_rc" "synchronized stop waits for an in-flight start"
racing_files=$(runtime_state_paths)
check "" "$racing_files" "synchronized stop leaves no late watcher state"
unset _SHIPYARD_CONTINUITY_PUBLISH_DELAY _SHIPYARD_CONTINUITY_PUBLICATION_POLLS

mkdir -p "$_SHIPYARD_CONTINUITY_DIR"
printf '%s\n' orphan >"$_SHIPYARD_CONTINUITY_DIR/continuity-orphan.log"
printf '%s\n' orphan >"$_SHIPYARD_CONTINUITY_DIR/continuity-orphan.heartbeat"
shipyard_continuity_stop_all
orphan_files=$(runtime_state_paths)
check "" "$orphan_files" "last-slot cleanup sweeps orphan watcher records"

failure_state="$TMP/failure-state"
mkdir -p "$failure_state"
printf '%s %s\n' "$$" held-token >"$failure_state/continuity-held.pid"
printf '%s %s\n' held-token 1 >"$failure_state/continuity-held.heartbeat"
printf '%s\n' held-log >"$failure_state/continuity-held.log"
failure_result=$(
  _SHIPYARD_CONTINUITY_DIR="$failure_state"
  shipyard_continuity_request() { return 1; }
  rc=0
  shipyard_continuity_stop_all || rc=$?
  printf '%s:%s' "$rc" "$(find "$failure_state" -type f ! -name continuity-generation | wc -l | tr -d ' ')"
)
check 1:3 "$failure_result" "failed cooperative stop preserves every lifecycle record"

FAKE_ROOT="$TMP/repo"
FAKE_GIT_DIR="$TMP/gitdir"
export FAKE_ROOT FAKE_GIT_DIR
mkdir -p "$FAKE_ROOT" "$FAKE_GIT_DIR/ship-escalations"
printf '%s\n' preserve >"$FAKE_GIT_DIR/ship-escalations/continuity-preserve.log"
git() {
  if [ "${1:-} ${2:-}" = "rev-parse --show-toplevel" ]; then printf '%s\n' "$FAKE_ROOT"; return 0; fi
  if [ "${1:-} ${2:-}" = "rev-parse --git-common-dir" ]; then printf '%s\n' "$FAKE_GIT_DIR"; return 0; fi
  return 0
}
export -f git
export TMP
agtermctl() { "$TMP/bin/agtermctl" "$@"; }
export -f agtermctl
printf '%s\n' malformed-tree >"$FAKE_MODE"
down_rc=0
SHIPYARD_BACKEND=agterm SHIPYARD_WORKSPACE=test-ai \
  bash "$SKILL_DIR/shipyard-down.sh" ghost --force >"$TMP/down.out" 2>"$TMP/down.err" || down_rc=$?
check 1 "$down_rc" "down fails when agterm enumeration is structurally invalid"
[ "$(grep -Fc 'lifecycle state was preserved' "$TMP/down.err")" -eq 1 ] || sed -n '1,80p' "$TMP/down.err"
check 1 "$(grep -Fc 'lifecycle state was preserved' "$TMP/down.err")" \
  "down reports that malformed enumeration preserved lifecycle state"
if [ -f "$FAKE_GIT_DIR/ship-escalations/continuity-preserve.log" ]; then preserved=yes; else preserved=no; fi
check yes "$preserved" "down integration preserves state on malformed enumeration"

printf '%s\n' malformed-session >"$FAKE_MODE"
nested_down_rc=0
SHIPYARD_BACKEND=agterm SHIPYARD_WORKSPACE=test-ai \
  bash "$SKILL_DIR/shipyard-down.sh" ghost --force >/dev/null 2>"$TMP/nested-down.err" || nested_down_rc=$?
check 1 "$nested_down_rc" "down rejects malformed nested session records"
check 1 "$(grep -Fc 'lifecycle state was preserved' "$TMP/nested-down.err")" \
  "nested session failure preserves lifecycle state"

tmux_absent=$(
  _SHIPYARD_BE=tmux
  _SHIPYARD_CONTAINER=test-ai
  tmux() { printf '%s\n' "can't find session: test-ai" >&2; return 1; }
  rc=0
  shipyard_slots || rc=$?
  printf 'rc=%s' "$rc"
)
check rc=0 "$tmux_absent" "an absent final tmux session is authoritative empty state"
tmux_error=$(
  _SHIPYARD_BE=tmux
  _SHIPYARD_CONTAINER=test-ai
  tmux() { printf '%s\n' 'permission denied' >&2; return 1; }
  rc=0
  shipyard_slots || rc=$?
  printf 'rc=%s' "$rc"
)
check rc=1 "$tmux_error" "an unrelated tmux query failure preserves lifecycle state"

report_rc=0
CODEX_SESSION_ID= CODEX_THREAD_ID= AGTERM_ENABLED=0 SHIPYARD_BACKEND=agterm \
  SHIPYARD_WORKSPACE=test-ai bash "$SKILL_DIR/shipyard-report.sh" \
  >"$TMP/report.out" 2>"$TMP/report.err" || report_rc=$?
check 0 "$report_rc" "status monitoring executes on macOS Bash 3.2"
check "" "$(cat "$TMP/report.err")" "status monitoring uses no unavailable Bash 4 builtins"
check 1 "$(grep -Fc '_no live ship terminals' "$TMP/report.out")" \
  "status monitoring reaches its authoritative empty report"

unset -f git
unset -f agtermctl
reset_fake

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
check 1 "$(grep -Fc 'shipyard_continuity_start "$KIND"' "$SKILL_DIR/shipyard-report.sh")" \
  "status monitoring re-arms Codex goal continuity"
report_start_line=$(grep -n 'shipyard_continuity_start "$KIND"' "$SKILL_DIR/shipyard-report.sh" | cut -d: -f1)
empty_exit_line=$(grep -n '^  exit 0$' "$SKILL_DIR/shipyard-report.sh" | head -1 | cut -d: -f1)
if [ -n "$report_start_line" ] && [ -n "$empty_exit_line" ] \
  && [ "$report_start_line" -gt "$empty_exit_line" ]; then
  check yes yes "empty status cannot recreate the last-slot continuity watcher"
else
  check yes no "empty status cannot recreate the last-slot continuity watcher"
fi
check 1 "$(grep -Fc 'shipyard_continuity_cleanup_last_slot' "$SKILL_DIR/shipyard-down.sh")" \
  "last-slot teardown uses status-aware continuity cleanup"

unset _SHIPYARD_CONTINUITY_LAUNCH_MODE

exit "$failures"
