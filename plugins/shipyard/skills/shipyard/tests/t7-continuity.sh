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

repeated=$(printf '%s\n%s\n%s\n%s\n%s\n%s' \
  '• Work completed before the stop.' "$capacity" '• Working (4s)' "$capacity" \
  '• Goal paused Objective: finish the change.' "$empty_prompt")
shipyard_continuity_decide "$repeated" 102
check resume "$SHIPYARD_CONTINUITY_ACTION" "a later capacity episode is retried"

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
SHIPYARD_CONTINUITY_PENDING_GOAL_AT=300
shipyard_continuity_decide "$active_empty" 308
check goal "$SHIPYARD_CONTINUITY_ACTION" "active session with empty prompt queues goal resume"

shipyard_continuity_reset
active_draft=$(printf '%s\n%s\n%s' '• Working (1m 08s · esc to interrupt)' \
  '• Goal paused Objective: finish the change.' '› unsent user draft')
SHIPYARD_CONTINUITY_PENDING_GOAL_AT=300
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

# The terminal API must receive text and Return in distinct calls.
mkdir -p "$TMP/bin"
FAKE_LOG="$TMP/agterm.log"
export FAKE_LOG
cat >"$TMP/bin/agtermctl" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-} ${2:-}" = "session type" ]; then
  shift 2
  if [ "${1:-}" = --stdin ]; then
    bytes=$(od -An -tx1 | tr -d ' \n')
    printf 'stdin:%s\n' "$bytes" >>"$FAKE_LOG"
  fi
  exit 0
fi
if [ "${1:-} ${2:-}" = "session text" ]; then
  printf '%s\n' '{"ok":true,"result":{"text":"› Ask Codex to do anything"}}'
  exit 0
fi
exit 0
EOF
chmod +x "$TMP/bin/agtermctl"
PATH="$TMP/bin:$PATH"
export PATH
_SHIPYARD_CONTINUITY_RETURN_DELAY=0
export _SHIPYARD_CONTINUITY_RETURN_DELAY
: >"$FAKE_LOG"
shipyard_continuity_submit resume test-session test-socket primary
check $'stdin:726573756d65\nstdin:0a' "$(cat "$FAKE_LOG")" "text and Return are separate submissions"

# Start is idempotent and last-slot cleanup owns the detached watcher.
_SHIPYARD_CONTINUITY_DIR="$TMP/state"
export _SHIPYARD_CONTINUITY_DIR
CODEX_SESSION_ID=test-thread
AGTERM_ENABLED=1
AGTERM_SESSION_ID=test-session
AGTERM_SOCKET=test-socket
AGTERM_PANE=primary
_SHIPYARD_CONTINUITY_POLL_SECS=0.05
export CODEX_SESSION_ID AGTERM_ENABLED AGTERM_SESSION_ID AGTERM_SOCKET AGTERM_PANE
export _SHIPYARD_CONTINUITY_POLL_SECS
start_rc=0
shipyard_continuity_start codex agterm >/dev/null || start_rc=$?
pidfile=$(find "$_SHIPYARD_CONTINUITY_DIR" -name 'continuity-*.pid' -print -quit)
if [ "$start_rc" -ne 0 ] || [ -z "$pidfile" ]; then
  printf 'watcher start diagnostics:\n'
  find "$_SHIPYARD_CONTINUITY_DIR" -name 'continuity-*.log' -exec sed -n '1,80p' {} \;
fi
pid1=$(awk '{print $1}' "$pidfile" 2>/dev/null)
if kill -0 "$pid1" 2>/dev/null; then started=yes; else started=no; fi
check yes "$started" "automatic start leaves a live watcher"
shipyard_continuity_start codex agterm >/dev/null
pid2=$(awk '{print $1}' "$pidfile")
check "$pid1" "$pid2" "automatic start is idempotent per parent session"
shipyard_continuity_stop_all
if kill -0 "$pid1" 2>/dev/null; then alive=yes; else alive=no; fi
check no "$alive" "lifecycle cleanup stops the watcher"
files=$(find "$_SHIPYARD_CONTINUITY_DIR" -type f -print 2>/dev/null)
check "" "$files" "lifecycle cleanup removes watcher state"
check 1 "$(grep -Fc 'shipyard_continuity_start "$AGENT" "$BACKEND"' "$SKILL_DIR/shipyard-launch.sh")" \
  "child launch wires automatic parent continuity"
check 1 "$(grep -Fc 'shipyard_continuity_stop_all' "$SKILL_DIR/shipyard-down.sh")" \
  "last-slot teardown wires continuity cleanup"

exit "$failures"
