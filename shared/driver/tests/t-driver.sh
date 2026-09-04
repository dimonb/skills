#!/usr/bin/env bash
# t-driver.sh — unit tests for the shared agent-console driver (shared/driver/agent-driver.sh).
#
# Everything here is a PURE read over environment variables and two faked CLIs (agtermctl, tmux)
# placed on PATH — NO live terminal, no network, no real agterm/tmux. It covers the driver's
# deterministic surface: backend selection, drv_shq quoting, container-name derivation for BOTH
# caller variants, drv_target handle construction, drv_signal, and the COMMAND the write/interaction
# dispatches construct — the fakes log their argv, so the command line is asserted without a live
# terminal: drv_launch on BOTH backends (agterm's zsh -lc session; tmux new-session vs new-window
# and the AGTERM_* scrub); drv_tell/submit/kill/focus on tmux (send-keys -l, Enter vs KPEnter,
# kill-window, select-window); and drv_read on tmux plus, via drv_signal, agterm. Out of scope: a
# real spawn (the launched child actually running) and the agterm argv of tell/submit/kill/focus.
#
# The driver's baseline interpreter is bash >= 5, so re-exec into one if a stock bash 3.2 started
# us (the same guard council.sh uses), or a future bash-5-only construct in the driver would fail
# here as a confusing syntax error rather than a clear version message.
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ] && [ -z "${DRV_TEST_BASH_REEXEC:-}" ]; then
  for _c in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash bash; do
    _p=$(command -v "$_c" 2>/dev/null) || continue
    _v=$("$_p" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null) || continue
    [ "${_v:-0}" -ge 5 ] && exec env DRV_TEST_BASH_REEXEC=1 "$_p" "$0" "$@"
  done
  echo "t-driver: needs bash >= 5, this one is ${BASH_VERSION:-unknown}." >&2
  echo "          macOS ships bash 3.2 as /bin/bash; install a modern one (brew install bash)." >&2
  exit 70
fi

set -uo pipefail
# Byte-wise matching, so the input-prompt glyphs in drv_signal compare as bytes regardless of the
# machine's locale — the same LC_ALL the callers run under.
export LC_ALL=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$(cd "$DIR/.." && pwd)/agent-driver.sh"
[ -f "$DRIVER" ] || { echo "t-driver: cannot find the driver at $DRIVER" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/drv-test.XXXXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

CHECKS=0
FAILURES=0
# ok <label> <expected> <actual>
ok() {
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"
    FAILURES=$((FAILURES + 1))
  fi
}

# --- the faked CLIs ---------------------------------------------------------------------------
# Deterministic stand-ins for agtermctl and tmux, driven entirely by environment variables so a
# test controls exactly what the driver sees. Placed FIRST on PATH so they shadow any real ones.
FAKEBIN="$TMP/bin"
mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/agtermctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  version) exit "${FAKE_AT_VERSION_RC:-0}" ;;
  tree)    cat "${FAKE_AT_TREE:-/dev/null}"; exit 0 ;;
  session)
    if [ "${2:-}" = text ]; then
      jq -n --rawfile t "${FAKE_AT_TEXT:-/dev/null}" '{result:{text:($t | rtrimstr("\n"))}}'
      exit 0
    fi
    printf 'session %s\n' "$*" >>"${FAKE_AT_LOG:-/dev/null}"; exit 0 ;;
  *) printf '%s\n' "$*" >>"${FAKE_AT_LOG:-/dev/null}"; exit 0 ;;
esac
EOF
cat >"$FAKEBIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list-windows) cat "${FAKE_TMUX_WINDOWS:-/dev/null}"; exit 0 ;;
  has-session)  exit "${FAKE_TMUX_HASSESSION_RC:-0}" ;;
  capture-pane) cat "${FAKE_TMUX_CAPTURE:-/dev/null}"; exit 0 ;;
  *) printf '%s\n' "$*" >>"${FAKE_TMUX_LOG:-/dev/null}"
     # When the server is (re)started, record any AGTERM_* variable that survived into this
     # process's environment, so the launch scrub can be asserted: a scrubbed var leaves no line.
     case "$1" in
       new-session|new-window)
         env | sed -n 's/^\(AGTERM_[A-Za-z_]*\)=.*/leak:\1/p' >>"${FAKE_TMUX_LOG:-/dev/null}" ;;
     esac
     exit 0 ;;
esac
EOF
chmod +x "$FAKEBIN/agtermctl" "$FAKEBIN/tmux"
EMPTYBIN="$TMP/emptybin"; mkdir -p "$EMPTYBIN"

# shellcheck source=../agent-driver.sh
. "$DRIVER"

# --- 1. backend selection --------------------------------------------------------------------
# Explicit values need no CLI at all — the case short-circuits before any lookup.
printf '\n── backend selection ──\n'
ok "explicit agterm"          agterm  "$(unset _DRV_BE; DRV_BACKEND=agterm drv_backend)"
ok "explicit tmux"            tmux    "$(unset _DRV_BE; DRV_BACKEND=tmux drv_backend)"
ok "a bad value is invalid"   invalid "$(unset _DRV_BE; DRV_BACKEND=nonsense drv_backend)"
# auto: agterm when agtermctl answers its version probe. The control vars are EXPORTED (not just
# set with a `;`), or the faked agtermctl — a separate process — never sees them.
ok "auto picks agterm when the socket answers" agterm \
  "$(unset _DRV_BE; export PATH="$FAKEBIN:$PATH" FAKE_AT_VERSION_RC=0 DRV_BACKEND=auto; drv_backend)"
# tmux when agtermctl is present but does NOT answer, and tmux is there.
ok "auto falls to tmux when the socket is silent" tmux \
  "$(unset _DRV_BE; export PATH="$FAKEBIN:$PATH" FAKE_AT_VERSION_RC=1 DRV_BACKEND=auto; drv_backend)"
# `none` when neither is reachable — an empty PATH hides both, and the none path runs no external.
ok "auto is none when neither is reachable" none \
  "$(unset _DRV_BE; export PATH="$EMPTYBIN" DRV_BACKEND=auto; drv_backend)"
# `none` and `invalid` each drive the shared refusal, on stderr, non-zero. Force the backend by
# pinning _DRV_BE rather than restricting PATH, which would hide the very tools the check runs.
none_rc=0; ( _DRV_BE=none _drv_no_backend ) 2>/dev/null || none_rc=$?
ok "no-backend refusal is non-zero" 1 "$none_rc"
none_msg=$( _DRV_BE=none _drv_no_backend 2>&1 >/dev/null | head -1 )
case "$none_msg" in error:*) ok "no-backend refusal prints an error" yes yes ;; *) ok "no-backend refusal prints an error" yes "no: [$none_msg]" ;; esac
inv_msg=$( _DRV_BE=invalid DRV_BACKEND=nonsense _drv_no_backend 2>&1 >/dev/null | head -1 )
case "$inv_msg" in *DRV_BACKEND*) ok "invalid refusal names DRV_BACKEND" yes yes ;; *) ok "invalid refusal names DRV_BACKEND" yes "no: [$inv_msg]" ;; esac

# --- 2. drv_shq ------------------------------------------------------------------------------
printf '\n── drv_shq ──\n'
ok "plain word"            "'abc'"          "$(drv_shq abc)"
ok "spaces"                "'a b c'"        "$(drv_shq 'a b c')"
ok "empty string"          "''"            "$(drv_shq '')"
ok "single quote escaped"  "'a'\\''b'"      "$(drv_shq "a'b")"
# The property that actually matters: the quoted form round-trips back to the input under eval,
# for the metacharacters a launcher path or command could carry.
for s in "plain" "a b" "a'b" 'a$b' 'a`b`c' 'a"b' 'a\b' "two  spaces" "semi;colon|pipe"; do
  got=$(eval "printf '%s' $(drv_shq "$s")")
  ok "round-trips: [$s]" "$s" "$got"
done

# --- 3. container naming: BOTH caller variants -----------------------------------------------
# The stem is injected via DRV_REPO_KEY so no real repo is needed, and the differences the two
# callers actually have (suffix, override, and a sanitised stem) are exercised directly.
printf '\n── container naming ──\n'
# Variant with a workspace suffix (agterm), no override, plain stem — the "-ai" caller, on the
# fallback path (no live agterm workspace).
ok "agterm fallback appends the suffix" myrepo-ai \
  "$(unset AGTERM_WORKSPACE_ID; _DRV_BE=agterm DRV_REPO_KEY=myrepo DRV_CONTAINER_SUFFIX=-ai drv_container)"
ok "tmux carries no suffix" myrepo \
  "$(_DRV_BE=tmux DRV_REPO_KEY=myrepo DRV_CONTAINER_SUFFIX=-ai drv_container)"
# Un-stacking is a WORKSPACE-path property (see below); the repo-stem fallback appends the suffix
# unconditionally, exactly as both source backends do — so a stem already ending in it doubles.
ok "the fallback appends the suffix unconditionally" myrepo-ai-ai \
  "$(unset AGTERM_WORKSPACE_ID; _DRV_BE=agterm DRV_REPO_KEY=myrepo-ai DRV_CONTAINER_SUFFIX=-ai drv_container)"
ok "an empty suffix appends nothing" plain \
  "$(unset AGTERM_WORKSPACE_ID; _DRV_BE=agterm DRV_REPO_KEY=plain DRV_CONTAINER_SUFFIX= drv_container)"
# The other variant: an explicit override always wins, whatever the backend/suffix/stem.
ok "override wins over derivation" explicit-name \
  "$(_DRV_BE=agterm DRV_CONTAINER_OVERRIDE=explicit-name DRV_REPO_KEY=ignored DRV_CONTAINER_SUFFIX=-ai drv_container)"
# The stem is used VERBATIM — sanitising (e.g. ":" -> "_") is the caller's job, so the driver
# neither adds nor strips it. Inject a sanitised stem and it comes back sanitised; inject a raw
# one and it comes back raw.
ok "sanitised stem passes through" a_b \
  "$(_DRV_BE=tmux DRV_REPO_KEY=a_b drv_container)"
ok "raw stem is not re-sanitised" "a:b" \
  "$(_DRV_BE=tmux DRV_REPO_KEY='a:b' drv_container)"
# A live agterm workspace: the container is the workspace name (plus the suffix, un-stacked).
printf '%s' '{"result":{"tree":{"workspaces":[{"id":"w1","name":"proj","sessions":[{"name":"s1","id":"u1"},{"name":"s2","id":"u2"}]}]}}}' >"$TMP/tree.json"
ok "a live workspace names the container" proj-ai \
  "$(PATH="$FAKEBIN:$PATH" FAKE_AT_TREE="$TMP/tree.json" AGTERM_WORKSPACE_ID=w1 _DRV_BE=agterm DRV_CONTAINER_SUFFIX=-ai drv_container)"
printf '%s' '{"result":{"tree":{"workspaces":[{"id":"w1","name":"proj-ai","sessions":[]}]}}}' >"$TMP/tree-ai.json"
ok "a workspace already suffixed is left alone" proj-ai \
  "$(PATH="$FAKEBIN:$PATH" FAKE_AT_TREE="$TMP/tree-ai.json" AGTERM_WORKSPACE_ID=w1 _DRV_BE=agterm DRV_CONTAINER_SUFFIX=-ai drv_container)"

# Pinning: written once, read back, and the pin beats a later derivation while an override still
# beats the pin.
printf '\n── container pinning ──\n'
PIN="$TMP/pin"; mkdir -p "$PIN"
ok "pin returns the derived name" myrepo \
  "$(_DRV_BE=tmux DRV_CONTAINER_PIN_DIR="$PIN" DRV_REPO_KEY=myrepo drv_container_pin)"
ok "the pin file was written" myrepo "$(cat "$PIN/container-tmux")"
ok "a later call reads the pin, not a new derivation" myrepo \
  "$(_DRV_BE=tmux DRV_CONTAINER_PIN_DIR="$PIN" DRV_REPO_KEY=changed drv_container)"
ok "an override still beats the pin" over \
  "$(_DRV_BE=tmux DRV_CONTAINER_PIN_DIR="$PIN" DRV_CONTAINER_OVERRIDE=over DRV_REPO_KEY=changed drv_container)"
ok "no pin dir means no write and the derived name" solo \
  "$(_DRV_BE=tmux DRV_REPO_KEY=solo drv_container_pin)"

# --- 4. drv_target: handle construction ------------------------------------------------------
printf '\n── drv_target ──\n'
# agterm: the session UUID for a name inside the container workspace; exit 1 for an absent name.
ok "agterm target resolves the session UUID" u2 \
  "$(PATH="$FAKEBIN:$PATH" FAKE_AT_TREE="$TMP/tree.json" _DRV_BE=agterm DRV_CONTAINER_OVERRIDE=proj drv_target s2)"
at_miss_rc=0
( PATH="$FAKEBIN:$PATH" FAKE_AT_TREE="$TMP/tree.json" _DRV_BE=agterm DRV_CONTAINER_OVERRIDE=proj drv_target nope ) >/dev/null || at_miss_rc=$?
ok "agterm target exits 1 for an absent name" 1 "$at_miss_rc"
# tmux: "<container>:<index>"; the active/last flag on a window name is stripped; absent -> exit 1.
printf '%s\n' '0 other' '1 target' '3 marked-' >"$TMP/windows.txt"
ok "tmux target is container:index" cont:1 \
  "$(PATH="$FAKEBIN:$PATH" FAKE_TMUX_WINDOWS="$TMP/windows.txt" _DRV_BE=tmux DRV_CONTAINER_OVERRIDE=cont drv_target target)"
ok "tmux target resolves the first window too" cont:0 \
  "$(PATH="$FAKEBIN:$PATH" FAKE_TMUX_WINDOWS="$TMP/windows.txt" _DRV_BE=tmux DRV_CONTAINER_OVERRIDE=cont drv_target other)"
ok "tmux target strips a window's active/last flag" cont:3 \
  "$(PATH="$FAKEBIN:$PATH" FAKE_TMUX_WINDOWS="$TMP/windows.txt" _DRV_BE=tmux DRV_CONTAINER_OVERRIDE=cont drv_target marked)"
tmux_miss_rc=0
( PATH="$FAKEBIN:$PATH" FAKE_TMUX_WINDOWS="$TMP/windows.txt" _DRV_BE=tmux DRV_CONTAINER_OVERRIDE=cont drv_target nope ) >/dev/null || tmux_miss_rc=$?
ok "tmux target exits 1 for an absent name" 1 "$tmux_miss_rc"

# --- 5. dispatch command construction --------------------------------------------------------
# The dispatches are one-liners, but the COMMAND each builds is deterministic and the fakes log it,
# so a behavioural fork regresses silently unless asserted here. The fakes are on PATH already.
printf '\n── dispatch command construction ──\n'
# A window fixture so drv_target resolves "sess" -> cont:0 for the interaction dispatches.
printf '%s\n' '0 sess' >"$TMP/win-dispatch.txt"
export PATH="$FAKEBIN:$PATH"

# drv_launch, tmux, NO existing session -> new-session; and every one of the seven AGTERM_* is
# scrubbed before the server is born. All seven are set to sentinels here, so dropping any one from
# the scrub array would leave it in the faked server's environment and fail the leak assertion.
launch_new="$TMP/launch-new.log"
( export FAKE_TMUX_LOG="$launch_new" FAKE_TMUX_HASSESSION_RC=1 _DRV_BE=tmux DRV_CONTAINER_OVERRIDE=cont \
    AGTERM_ENABLED=1 AGTERM_PANE=p AGTERM_PANE_ID=pi AGTERM_SESSION_ID=s \
    AGTERM_SOCKET=so AGTERM_WINDOW_ID=wi AGTERM_WORKSPACE_ID=ws
  drv_launch sess /work/dir /path/to/launcher >/dev/null )
grep -q 'new-session -d -s cont -n sess -c /work/dir' "$launch_new" && r=yes || r=no
ok "tmux launch with no session spawns new-session" yes "$r"
ok "tmux launch scrubs every AGTERM_* before the server" 0 \
  "$(grep -cE 'leak:AGTERM_(ENABLED|PANE|PANE_ID|SESSION_ID|SOCKET|WINDOW_ID|WORKSPACE_ID)$' "$launch_new")"

# drv_launch, tmux, EXISTING session -> new-window.
launch_win="$TMP/launch-win.log"
( export FAKE_TMUX_LOG="$launch_win" FAKE_TMUX_HASSESSION_RC=0 _DRV_BE=tmux DRV_CONTAINER_OVERRIDE=cont
  drv_launch sess /work/dir /path/to/launcher >/dev/null )
grep -q 'new-window -t cont -n sess -c /work/dir' "$launch_win" && r=yes || r=no
ok "tmux launch with an existing session adds a new-window" yes "$r"

# drv_launch, agterm -> a --create-workspace --no-select --wait session running `zsh -lc 'exec …'`.
launch_at="$TMP/launch-at.log"
( export FAKE_AT_LOG="$launch_at" _DRV_BE=agterm DRV_CONTAINER_OVERRIDE=cont
  drv_launch sess /work/dir /path/to/launcher >/dev/null )
at_line=$(cat "$launch_at" 2>/dev/null)
case "$at_line" in
  *"session new "*"--workspace-name cont"*"--create-workspace"*"--name sess"*"--no-select"*"--wait"*"zsh -lc"*"exec"*)
    ok "agterm launch builds the zsh -lc --create-workspace --no-select --wait session" yes yes ;;
  *) ok "agterm launch builds the zsh -lc --create-workspace --no-select --wait session" yes "no: [$at_line]" ;;
esac

# drv_tell -> send-keys with the literal -l flag.
tell_log="$TMP/tell.log"
( export FAKE_TMUX_WINDOWS="$TMP/win-dispatch.txt" FAKE_TMUX_LOG="$tell_log" _DRV_BE=tmux DRV_CONTAINER_OVERRIDE=cont
  drv_tell sess "hello there" )
grep -q 'send-keys -t cont:0 -l hello there' "$tell_log" && r=yes || r=no
ok "tmux tell sends the literal text with -l" yes "$r"

# drv_submit -> Enter by default, KPEnter with `alt`.
sub_log="$TMP/submit.log"
( export FAKE_TMUX_WINDOWS="$TMP/win-dispatch.txt" FAKE_TMUX_LOG="$sub_log" _DRV_BE=tmux DRV_CONTAINER_OVERRIDE=cont
  drv_submit sess )
grep -q 'send-keys -t cont:0 Enter' "$sub_log" && r=yes || r=no
ok "tmux submit presses Enter by default" yes "$r"
sub_alt="$TMP/submit-alt.log"
( export FAKE_TMUX_WINDOWS="$TMP/win-dispatch.txt" FAKE_TMUX_LOG="$sub_alt" _DRV_BE=tmux DRV_CONTAINER_OVERRIDE=cont
  drv_submit sess alt )
grep -q 'send-keys -t cont:0 KPEnter' "$sub_alt" && r=yes || r=no
ok "tmux submit with alt presses KPEnter" yes "$r"

# drv_kill / drv_focus -> the right window verb; drv_read -> the captured pane.
kill_log="$TMP/kill.log"
( export FAKE_TMUX_WINDOWS="$TMP/win-dispatch.txt" FAKE_TMUX_LOG="$kill_log" _DRV_BE=tmux DRV_CONTAINER_OVERRIDE=cont
  drv_kill sess )
grep -q 'kill-window -t cont:0' "$kill_log" && r=yes || r=no
ok "tmux kill closes the window" yes "$r"
focus_log="$TMP/focus.log"
( export FAKE_TMUX_WINDOWS="$TMP/win-dispatch.txt" FAKE_TMUX_LOG="$focus_log" _DRV_BE=tmux DRV_CONTAINER_OVERRIDE=cont
  drv_focus sess )
grep -q 'select-window -t cont:0' "$focus_log" && r=yes || r=no
ok "tmux focus selects the window" yes "$r"
printf '%s\n' 'pane contents here' >"$TMP/cap.txt"
ok "tmux read returns the captured pane" "pane contents here" \
  "$(FAKE_TMUX_WINDOWS="$TMP/win-dispatch.txt" FAKE_TMUX_CAPTURE="$TMP/cap.txt" _DRV_BE=tmux DRV_CONTAINER_OVERRIDE=cont drv_read sess)"

# --- 6. drv_signal: minimal liveness + capacity ----------------------------------------------
printf '\n── drv_signal ──\n'
# Dead: the name has no live terminal in the tree -> "dead|gone", non-zero.
sig_dead=$(PATH="$FAKEBIN:$PATH" FAKE_AT_TREE="$TMP/tree.json" _DRV_BE=agterm DRV_CONTAINER_OVERRIDE=proj drv_signal nope); sig_dead_rc=$?
ok "signal for a gone session"      "dead|gone" "$sig_dead"
ok "signal for a gone session exits 1" 1 "$sig_dead_rc"
# Live + an input prompt at the foot -> idle.
printf '%s\n%s\n' 'some earlier output' '› Ask me anything' >"$TMP/screen-idle.txt"
sig_idle=$(PATH="$FAKEBIN:$PATH" FAKE_AT_TREE="$TMP/tree.json" FAKE_AT_TEXT="$TMP/screen-idle.txt" _DRV_BE=agterm DRV_CONTAINER_OVERRIDE=proj drv_signal s1); sig_idle_rc=$?
ok "signal for an idle session"        "live|idle" "$sig_idle"
ok "signal for a live session exits 0" 0 "$sig_idle_rc"
# Live + a working line at the foot -> busy.
printf '%s\n%s\n' '› earlier prompt' 'Working (2s · esc to interrupt)' >"$TMP/screen-busy.txt"
ok "signal for a busy session" "live|busy" \
  "$(PATH="$FAKEBIN:$PATH" FAKE_AT_TREE="$TMP/tree.json" FAKE_AT_TEXT="$TMP/screen-busy.txt" _DRV_BE=agterm DRV_CONTAINER_OVERRIDE=proj drv_signal s1)"
# The alternate idle prompt glyph the driver also accepts.
printf '%s\n%s\n' 'earlier output' '❯ ready' >"$TMP/screen-idle2.txt"
ok "signal idle via the alternate prompt glyph" "live|idle" \
  "$(PATH="$FAKEBIN:$PATH" FAKE_AT_TREE="$TMP/tree.json" FAKE_AT_TEXT="$TMP/screen-idle2.txt" _DRV_BE=agterm DRV_CONTAINER_OVERRIDE=proj drv_signal s1)"
# Live but an empty screen -> unknown (can't tell without a per-kind read).
: >"$TMP/screen-empty.txt"
ok "signal for a live but blank screen" "live|unknown" \
  "$(PATH="$FAKEBIN:$PATH" FAKE_AT_TREE="$TMP/tree.json" FAKE_AT_TEXT="$TMP/screen-empty.txt" _DRV_BE=agterm DRV_CONTAINER_OVERRIDE=proj drv_signal s1)"

# --- done ------------------------------------------------------------------------------------
printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 't-driver: %d checks, all passed\n' "$CHECKS"
  exit 0
fi
printf 't-driver: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"
exit 1
