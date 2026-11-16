#!/usr/bin/env bash
# t25-finish.sh — a finished child closes its own terminal (#355).
#
# PROVENANCE. Step 6 tears a merged slot down only once its terminal is gone, and a ship child
# never closed its terminal after `done`, so in a real fleet three finished slots sat as
# `✅ finished` until the human asked why they had not closed. shipyard-finish.sh is the child's
# own last act; each case below is one of its refusals or one of its two ordering promises.
#
#   F1 a stage that is not `done` (here `ready-to-merge`, where a human still owes the merge)
#      closes nothing, and says why in a notice.
#   F2 `done`, run in the slot's own window: the window is killed, and the closing notice is
#      ALREADY in the mailbox when the kill arrives — the race the request named.
#   F3 run from a DIFFERENT window (a sibling's, or the parent's): refused, nothing killed. This is
#      what keeps the script from being aimed at anything but the terminal it runs in.
#   F4 no pane to identify at all: refused.
#   F5 a worktree that is not `ship-<slot>`: refused before anything else, notice included,
#      whatever SHIPYARD_SLOT says.
#   F6 the close fails: a second notice says so, and the exit is non-zero.
#   F7 agterm: the session id must match, and a match sends `session close` to that id.
#   F8 the PRODUCTION resolution — no SHIPYARD_BACKEND or SHIPYARD_SESSION, as a real child has —
#      on a tmux child while agterm also answers: the pane decides, not `auto`.
#   F9 a closing notice that cannot be written stops the close.
#
# Real git, because the mailbox is found through `git rev-parse --git-common-dir` and the slot
# through the worktree's own name; only the terminal backends are faked, as exported functions.
# The driver's companion refusal (exit 3/4) is shared/driver's and is tested there.
set -uo pipefail
export LC_ALL=C
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$DIR/.." && pwd)"
FINISH="$SKILL_DIR/shipyard-finish.sh"

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=shipyard-test GIT_AUTHOR_EMAIL=shipyard-test
export GIT_COMMITTER_NAME=shipyard-test GIT_COMMITTER_EMAIL=shipyard-test

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}

T=$(mktemp -d "${TMPDIR:-/tmp}/shipyard-t25.XXXXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT
R="$T/repo"
git init -q -b main "$R"
git -C "$R" commit -q --allow-empty -m base
git -C "$R" worktree add -q -b feat/five "$R/.claude/worktrees/ship-5"
git -C "$R" worktree add -q -b feat/other "$R/.claude/worktrees/other"
W="$R/.claude/worktrees/ship-5"
MB="$R/.git/ship-escalations"
LOG="$T/backend.log"
export LOG MB

stage() { mkdir -p "$1/.pipeline-state"; printf '{"state":"%s"}\n' "$2" >"$1/.pipeline-state/PR-9.json"; }
notices() { cat "$MB"/5-*.json 2>/dev/null | jq -r 'select(.kind=="notice") | .question // .text // empty' 2>/dev/null; }
reset() { : >"$LOG"; rm -f "$MB"/5-*.json; }

# tmux: the slot's window is index 3 of container t25; $OWN is what the pane reports itself as.
# kill-window records whether the closing notice was already on disk when the kill arrived.
tmux() {
  case "${1:-}" in
    display-message)
      case "$*" in
        *'#{session_name}:#{window_index}'*) printf '%s\n' "$OWN" ;;
        *)                                   printf '%s\n' "${OWN%%:*}" ;;
      esac ;;
    list-windows)    printf '3 ship-5\n7 ship-6\n' ;;
    has-session)     return 0 ;;
    kill-window)
      if grep -qs 'finished: ship recorded done' "$MB"/5-*.json; then echo "kill $3 after-notice" >>"$LOG"
      else echo "kill $3 before-notice" >>"$LOG"; fi
      return "${KILL_RC:-0}" ;;
  esac
  return 0
}
export -f tmux

run() { # [VAR=value ...] — the script, from the child's worktree, on tmux
  (cd "$W" && env SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t25 TMUX_PANE=%9 "$@" bash "$FINISH" 2>/dev/null)
}

# --- F1: not done -----------------------------------------------------------------------------
reset; stage "$W" ready-to-merge
run OWN=t25:3 >/dev/null; rc=$?
ok "F1 ready-to-merge: refused"                     1 "$rc"
ok "F1 ...nothing killed"                           0 "$(grep -c kill "$LOG")"
ok "F1 ...and a notice says why"                    1 "$(notices | grep -c "stage is 'ready-to-merge', not done")"

# --- F2: done, own window ---------------------------------------------------------------------
reset; stage "$W" done
run OWN=t25:3 >/dev/null; rc=$?
ok "F2 done in its own window: exit 0"              0 "$rc"
ok "F2 ...its own window, and only it, is killed"   "kill t25:3 after-notice" "$(cat "$LOG")"
ok "F2 ...one notice, the closing one"              1 "$(notices | grep -c .)"

# --- F3: someone else's window ----------------------------------------------------------------
reset
run OWN=t25:7 >/dev/null; rc=$?
ok "F3 run from another window: refused"            1 "$rc"
ok "F3 ...nothing killed"                           0 "$(grep -c kill "$LOG")"
ok "F3 ...and the notice names it"                  1 "$(notices | grep -c "not ship-5's own terminal")"

# --- F4: no pane ------------------------------------------------------------------------------
reset
(cd "$W" && env -u TMUX_PANE SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t25 OWN=t25:3 bash "$FINISH" >/dev/null 2>&1); rc=$?
ok "F4 no pane to identify: refused"                1 "$rc"
ok "F4 ...nothing killed"                           0 "$(grep -c kill "$LOG")"

# --- F5: not a ship-<slot> worktree -----------------------------------------------------------
reset; stage "$R/.claude/worktrees/other" done
(cd "$R/.claude/worktrees/other" && env SHIPYARD_SLOT=5 SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t25 \
   TMUX_PANE=%9 OWN=t25:3 bash "$FINISH" >/dev/null 2>&1); rc=$?
ok "F5 a worktree that is not ship-5: refused"      1 "$rc"
ok "F5 ...nothing killed"                           0 "$(grep -c kill "$LOG")"

# --- F6: the close fails ----------------------------------------------------------------------
reset
run OWN=t25:3 KILL_RC=1 >/dev/null; rc=$?
ok "F6 a failed close: exit 1"                      1 "$rc"
ok "F6 ...the closing notice, then one saying it failed" 2 "$(notices | grep -c .)"
ok "F6 ...naming the failure"                       1 "$(notices | grep -c 'the close failed')"

# --- F7: agterm -------------------------------------------------------------------------------
# A tree with the slot's session and no companions; `session close` is recorded.
agtermctl() {
  case "$*" in
    "version") return 0 ;;
    "tree --json")
      printf '{"ok":true,"result":{"tree":{"workspaces":[{"name":"ws","sessions":[{"id":"S5","name":"ship-5"},{"id":"P","name":"parent"}]}]}}}\n' ;;
    "session close --target "*) local a="$*"; echo "close ${a##* }" >>"$LOG" ;;
  esac
  return 0
}
export -f agtermctl
mkdir -p "$MB"; printf 'ws' >"$MB/container-agterm"
reset
(cd "$W" && env SHIPYARD_BACKEND=agterm AGTERM_SESSION_ID=P bash "$FINISH" >/dev/null 2>&1); rc=$?
ok "F7 agterm, another session's id: refused"       1 "$rc"
ok "F7 ...nothing closed"                           0 "$(grep -c close "$LOG")"
ok "F7 ...for the right reason: it resolved ship-5 and it is not this one" 1 \
   "$(notices | grep -c "not ship-5's own terminal")"
reset
(cd "$W" && env SHIPYARD_BACKEND=agterm AGTERM_SESSION_ID=S5 bash "$FINISH" >/dev/null 2>&1); rc=$?
ok "F7 agterm, its own id: exit 0"                  0 "$rc"
ok "F7 ...and that session is closed"               "close S5" "$(cat "$LOG")"

# --- F8: production resolution: no SHIPYARD_BACKEND, no SHIPYARD_SESSION, agterm answering ------
# A child is not handed the fleet's backend. `auto` would pick agterm here (the fake above answers
# `version`), find no ship-5 in it and never close — so the pane decides, and tmux tells it which
# session it is in.
reset
(cd "$W" && env -u SHIPYARD_BACKEND -u SHIPYARD_SESSION TMUX_PANE=%9 OWN=t25:3 AGTERM_SESSION_ID=P \
   bash "$FINISH" >/dev/null 2>&1); rc=$?
ok "F8 a tmux child with agterm also answering: exit 0" 0 "$rc"
ok "F8 ...its own window is killed"                 "kill t25:3 after-notice" "$(grep kill "$LOG")"

# --- F9: the closing notice cannot be written: nothing is closed --------------------------------
reset
chmod 555 "$MB"
run OWN=t25:3 >/dev/null; rc=$?
chmod 755 "$MB"
ok "F9 an unwritable mailbox: refused"              1 "$rc"
ok "F9 ...nothing killed"                           0 "$(grep -c kill "$LOG")"

printf '\n%s: %d checks, %d failures\n' "$(basename "$0")" "$CHECKS" "$FAILURES"
[ "$FAILURES" -eq 0 ]
