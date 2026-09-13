#!/usr/bin/env bash
# t16-tell-knobs.sh — `shipyard tell`'s two poll knobs must never abort it or spin it.
#
# PROVENANCE, and why this file is in SHIPYARD's suite rather than only in the shared module's.
# Both defects below were found while fixing `council say`, but they were not council's: they were
# in THIS file's released code, reached through validation whose own comment claimed to prevent
# them. The shared `knob_uint` / `knob_interval` now hold the rules and `shared/knobs/tests`
# asserts them as pure functions — but a rule is only worth what its CALLER does with it, and the
# caller that shipped the defect is here. This file pins the wiring:
#
#   * `SHIPYARD_TELL_CONFIRM_SECS=08` passed `_shipyard_admission_uint`'s all-digits test and then
#     made `DEADLINE=$(( $(date +%s) + CONFIRM_SECS ))` an invalid-octal EXPANSION, which kills a
#     non-interactive shell. It aborted at that line — AFTER `shipyard_type` and `shipyard_submit`
#     had already run. So the directive was in flight, the supervisor got a raw bash error and no
#     delivery verdict, and the documented next move (re-send) types a second copy onto the first.
#     That is the precise harm the confirm-poll exists to prevent, in the file that implements it.
#   * `SHIPYARD_TELL_CONFIRM_INTERVAL` rejected zero by ENUMERATING `0|0.|0.0|.0`, so `00`, `000`,
#     `0.00`, `.00` and `000.000` all passed and made `sleep` a no-op — the bounded poll became a
#     fork storm against a live child's terminal.
#
# WHAT IS ASSERTED HERE is the caller's behaviour, not the validator's: that the script survives
# each value, reports a verdict, and honours the value it was given. The per-spelling matrix lives
# in `shared/knobs/tests/t-knobs.sh`; duplicating it here would be the copy this whole change
# exists to remove.
#
# The rig is t13-wait.sh's and t14-signal.sh's: exported shell functions shadow `git` and `tmux`,
# which works where a fake binary on PATH does not, because shipyard-lib.sh prepends the system
# PATH. No live terminal, no agterm, no network.
set -uo pipefail
export LC_ALL=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$DIR/.." && pwd)"
TELL="$SKILL_DIR/shipyard-tell.sh"
[ -f "$TELL" ] || { echo "t16: cannot find shipyard-tell.sh at $TELL" >&2; exit 1; }

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}
has() { printf '%s' "$1" | grep -q -- "$2" && printf yes || printf no; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/t16-tell-knobs.XXXXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

FAKE_ROOT="$TMP/repo"; FAKE_GIT="$TMP/gitdir"; MB="$FAKE_GIT/ship-escalations"
mkdir -p "$FAKE_ROOT" "$MB"
export FAKE_ROOT FAKE_GIT
: > "$MB/container-tmux"        # pinned where we resolve, so no `elsewhere` refusal

git() {
  case "${1:-} ${2:-}" in
    "rev-parse --show-toplevel")  printf '%s\n' "$FAKE_ROOT"; return 0 ;;
    "rev-parse --git-common-dir") printf '%s\n' "$FAKE_GIT";  return 0 ;;
    "remote get-url")             printf 'https://github.com/example/example.git\n'; return 0 ;;
  esac
  return 0
}
# A live slot that never starts a turn: the enumeration and the per-slot lookup both answer, so the
# script reaches its poll — and every capture is an idle composer, so the poll runs to its deadline
# and returns `unconfirmed`. That is the path both knobs are on.
tmux() {
  case "${1:-}" in
    list-windows) case "$*" in *window_index*) printf '1 ship-41\n' ;; *) printf 'ship-41\n' ;; esac; return 0 ;;
    has-session)  return 0 ;;
    capture-pane) printf 'some earlier output\n> \n' ; return 0 ;;
  esac
  return 0
}
export -f git tmux

run_tell() { # <env assignments...> -> output, then a last line "rc=<n>"
  local out rc=0
  out=$( env "$@" SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t16ex \
         bash "$TELL" 41 "a directive" 2>&1 ) || rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
rc_of() { printf '%s' "$1" | sed -n 's/^rc=//p' | tail -1; }

# --- the baseline: a short window, so the rest are comparable and the file stays fast ----------
printf '\n── the window ──\n'
out=$(run_tell SHIPYARD_TELL_CONFIRM_SECS=1 SHIPYARD_TELL_CONFIRM_INTERVAL=0.2)
ok "a usable window reaches a verdict"      6   "$(rc_of "$out")"
ok "...reported as unconfirmed"             yes "$(has "$out" 'was typed and submitted, but no turn')"

# THE OCTAL ABORT. Before the fix this killed the shell at the deadline line, so there was no
# verdict at all and rc was 1. The directive had already been typed and submitted by then.
out=$(run_tell SHIPYARD_TELL_CONFIRM_SECS=08 SHIPYARD_TELL_CONFIRM_INTERVAL=0.2)
ok "a leading zero does not abort"          6   "$(rc_of "$out")"
ok "...leaking no arithmetic error"         no  "$(has "$out" 'value too great for base')"
ok "...and still reports a verdict"         yes "$(has "$out" 'was typed and submitted, but no turn')"
# Read as EIGHT, not silently as the ten-second default. The verdict message quotes the window it
# actually used, so this distinguishes a correct parse from a fallback — without it, a fix that
# simply refused `08` would pass every other assertion here.
ok "...having read 08 as eight seconds"     yes "$(has "$out" '8s and the child never said')"

# A window too long to compute with must fall back and SAY so, not truncate in silence.
out=$(run_tell SHIPYARD_TELL_CONFIRM_SECS=99999999999 SHIPYARD_TELL_CONFIRM_INTERVAL=0.2)
ok "an unusable window says so"             yes "$(has "$out" 'not a usable whole number')"
ok "...and does not abort"                  6   "$(rc_of "$out")"

# --- the interval -------------------------------------------------------------------------------
printf '\n── the interval ──\n'
# THE SPELLINGS THE OLD ENUMERATION MISSED. Two of them, as the smallest set that proves the shape
# test replaced the list; the full matrix is shared/knobs/tests' job.
for z in 00 0.00; do
  out=$(run_tell SHIPYARD_TELL_CONFIRM_SECS=1 SHIPYARD_TELL_CONFIRM_INTERVAL="$z")
  ok "[$z] falls back"                      yes "$(has "$out" 'not a usable positive number')"
done
# ...and the spelling the old list DID catch still falls back, so the replacement did not narrow it.
out=$(run_tell SHIPYARD_TELL_CONFIRM_SECS=1 SHIPYARD_TELL_CONFIRM_INTERVAL=0)
ok "[0] still falls back"                   yes "$(has "$out" 'not a usable positive number')"
# ...and a legitimate value is NOT rejected, or the guard is useless in the other direction.
out=$(run_tell SHIPYARD_TELL_CONFIRM_SECS=1 SHIPYARD_TELL_CONFIRM_INTERVAL=0.05)
ok "a small positive interval is kept"      no  "$(has "$out" 'not a usable positive number')"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 't16-tell-knobs: %d checks, all passed\n' "$CHECKS"
  exit 0
fi
printf 't16-tell-knobs: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"
exit 1
