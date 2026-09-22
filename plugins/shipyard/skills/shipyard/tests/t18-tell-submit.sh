#!/usr/bin/env bash
# t18-tell-submit.sh — `shipyard-tell.sh <slot> --submit` presses Return on the draft already in
# the box, types NOTHING, records nothing, and answers with the same verdicts and exit codes as a
# directive.
#
# Why it exists (#195): the documented recovery for an `unconfirmed` directive used to be a bash
# one-liner that sourced the lib and called `shipyard_submit`. That call prints nothing either
# way, so an operator could not tell "slot not resolved" from "Return sent and not taken" from "it
# worked". `--submit` routes the same keystroke through tell's own verdict path instead of a
# second one. This file pins the half that makes it safe to reach for: it must never type, since
# typing is exactly what concatenates onto the draft it is there to send.
#
# The rig is t16's: exported shell functions shadow `git` and `tmux`. Here the fake `tmux` also
# LOGS every send-keys call, so the assertion is on what reached the backend, not on a message.
# No live terminal, no agterm, no network.
set -uo pipefail
export LC_ALL=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$DIR/.." && pwd)"
TELL="$SKILL_DIR/shipyard-tell.sh"
[ -f "$TELL" ] || { echo "t18: cannot find shipyard-tell.sh at $TELL" >&2; exit 1; }

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}
has() { printf '%s' "$1" | grep -q -- "$2" && printf yes || printf no; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/t18-tell-submit.XXXXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

FAKE_ROOT="$TMP/repo"; FAKE_GIT="$TMP/gitdir"; MB="$FAKE_GIT/ship-escalations"
KEYS="$TMP/keys"
mkdir -p "$FAKE_ROOT" "$MB"
export FAKE_ROOT FAKE_GIT KEYS
: > "$MB/container-tmux"        # pinned where we resolve, so no `elsewhere` refusal

git() {
  case "${1:-} ${2:-}" in
    "rev-parse --show-toplevel")  printf '%s\n' "$FAKE_ROOT"; return 0 ;;
    "rev-parse --git-common-dir") printf '%s\n' "$FAKE_GIT";  return 0 ;;
    "remote get-url")             printf 'https://github.com/example/example.git\n'; return 0 ;;
  esac
  return 0
}
# FAKE_TURN=starts: once a Return has been logged the pane shows a running turn's footer, so the
# poll sees idle -> running and reads `delivered`. FAKE_TURN=never: the pane stays an idle composer
# holding a draft, so the poll runs to its deadline and reads `unconfirmed`.
tmux() {
  case "${1:-}" in
    list-windows) case "$*" in *window_index*) printf '1 ship-41\n' ;; *) printf 'ship-41\n' ;; esac; return 0 ;;
    has-session)  return 0 ;;
    send-keys)    shift; printf '%s\n' "$*" >> "$KEYS"; return 0 ;;
    capture-pane)
      if [ "${FAKE_TURN:-never}" = starts ] && grep -q ' Enter$' "$KEYS" 2>/dev/null; then
        printf 'some earlier output\n  esc to interrupt\n'
      else
        printf 'some earlier output\n> an unsent draft\n'
      fi
      return 0 ;;
  esac
  return 0
}
export -f git tmux

run_tell() { # <FAKE_TURN> <args...> -> output, then a last line "rc=<n>"
  local turn="$1" out rc=0; shift
  : > "$KEYS"
  out=$( env FAKE_TURN="$turn" SHIPYARD_TELL_SETTLE_DELAY=0.01 \
             SHIPYARD_TELL_CONFIRM_SECS=1 SHIPYARD_TELL_CONFIRM_INTERVAL=0.2 \
             SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t18ex \
         bash "$TELL" "$@" 2>&1 ) || rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
rc_of() { printf '%s' "$1" | sed -n 's/^rc=//p' | tail -1; }
records() { find "$MB" -name 'directive-*' | wc -l | tr -d ' '; }

# --- what reaches the backend ------------------------------------------------------------------
printf '\n── --submit sends Return and nothing else ──\n'
out=$(run_tell starts 41 --submit)
# `-l` is how drv_tell types literal text on tmux. Any such call here would concatenate onto the
# draft this mode exists to send — the one thing it must never do.
ok "types no text"                          0   "$(grep -c -- ' -l ' "$KEYS")"
ok "presses Return exactly once"            1   "$(grep -c ' Enter$' "$KEYS")"
ok "...and nothing else at all"             1   "$(wc -l < "$KEYS" | tr -d ' ')"
ok "records no directive"                   0   "$(records)"
ok "a started turn reads delivered"         0   "$(rc_of "$out")"
ok "...and says so"                         yes "$(has "$out" 'delivered')"

# --- the unconfirmed path: tell's exit code, its own wording -----------------------------------
printf '\n── --submit, no turn starts ──\n'
out=$(run_tell never 41 --submit)
ok "no turn is exit 6, as for a directive"  6   "$(rc_of "$out")"
ok "...naming the Return, not a typed text" yes "$(has "$out" 'pressed Return in ship-41')"
ok "...and warning off compaction"          yes "$(has "$out" 'do NOT compact')"
ok "...still types nothing"                 0   "$(grep -c -- ' -l ' "$KEYS")"

# --- an unresolvable slot is loud, which the old one-liner was not ------------------------------
printf '\n── --submit, no such slot ──\n'
out=$(run_tell never 99 --submit)
ok "an unknown slot is not exit 0"          no  "$( [ "$(rc_of "$out")" = 0 ] && printf yes || printf no )"
ok "...and sends nothing"                   0   "$(wc -l < "$KEYS" | tr -d ' ')"

# --- a directive's own unconfirmed advice points at --submit -----------------------------------
printf '\n── a directive, no turn starts ──\n'
out=$(run_tell never 41 "a directive")
ok "a directive still types its text"       1   "$(grep -c -- ' -l ' "$KEYS")"
ok "...and records itself"                  1   "$(records | awk '{print ($1 > 0)}')"
ok "its advice names --submit"              yes "$(has "$out" 'shipyard-tell.sh 41 --submit')"
ok "...and no longer the silent one-liner"  no  "$(has "$out" 'shipyard_submit')"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 't18-tell-submit: %d checks, all passed\n' "$CHECKS"
  exit 0
fi
printf 't18-tell-submit: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"
exit 1
