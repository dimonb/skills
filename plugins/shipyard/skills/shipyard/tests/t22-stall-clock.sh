#!/usr/bin/env bash
# t22-stall-clock.sh — what the stall clock may NOT count as a child standing still (#142, #155).
#
# PROVENANCE. Two inputs that describe the supervisor's own instruments, not the child, reached the
# stall clock and disarmed it by making it restart:
#
#   1. #142 — the clock's key carried the forge state, and `since` carries only on an exact match.
#      A forge read that fails turns `opened` into `?`, so an INTERMITTENT forge rebased the clock of
#      a child whose screen had not changed by a byte, and 🛑 STALLED could need eight consecutive
#      good reads to fire. The fixture is the one #142 asks for: three ticks, a byte-identical pane,
#      a forge fake that fails only the middle one, asserting `since` is NOT rebased;
#   2. #155 — an empty capture is what a FAILED read returns, and two failed reads compared equal
#      and rendered `⏸ idle/wait`. An empty capture is no observation: the tick gets no motion
#      verdict, does not fire, and writes back the row it read, so the next readable tick's clock
#      is neither rebased nor fed a screen hash nobody saw.
#
# Executed against the real report over a faked tmux and gh, as t13 and t19 do.
set -uo pipefail
export LC_ALL=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$DIR/.." && pwd)"
REPORT="$SKILL_DIR/shipyard-report.sh"

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}
has() { grep -q -- "$2" <<<"$1" && printf yes || printf no; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/t22-stall-clock.XXXXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

FAKE_ROOT="$TMP/repo"; FAKE_GIT="$TMP/gitdir"; MB="$FAKE_GIT/ship-escalations"
CAPS="$TMP/caps"
mkdir -p "$FAKE_ROOT" "$MB"
: > "$MB/container-tmux"        # pinned where we resolve, so no `elsewhere` refusal
mkdir -p "$FAKE_ROOT/.claude/worktrees/ship-51/.pipeline-state"
printf '{"pr_number":951,"state":"impl-review"}\n' >"$FAKE_ROOT/.claude/worktrees/ship-51/.pipeline-state/PR-951.json"
export FAKE_ROOT FAKE_GIT CAPS

# One slot, 51: an idle child at impl-review with its PR open.
#   FAKE_GH=fail    the forge read fails, so the state reads `?`
#   FAKE_CAP=blank  both captures come back empty — a failed read
#   FAKE_CAP=first  only the FIRST capture of the tick is empty
#   FAKE_CAP=second only the SECOND is — the one whose hash the clock stores
git() {
  # The report asks `git -C <root> remote get-url origin` to pick the forge; without this arm it
  # read as gitlab, `glab` answered nothing, every tick's state was `?`, and the flicker case below
  # passed against the unfixed report — it had nothing to flicker.
  [ "${1:-}" = -C ] && shift 2
  case "${1:-} ${2:-}" in
    "rev-parse --show-toplevel")  printf '%s\n' "$FAKE_ROOT"; return 0 ;;
    "rev-parse --git-common-dir") printf '%s\n' "$FAKE_GIT";  return 0 ;;
    "remote get-url")             printf 'https://github.com/example/example.git\n'; return 0 ;;
  esac
  return 0
}
tmux() {
  case "${1:-}" in
    list-windows) case "$*" in
                    *window_index*) printf '1 ship-51\n' ;;
                    *)              printf 'ship-51\n' ;;
                  esac; return 0 ;;
    has-session)  return 0 ;;
    display-message) printf '0 claude\n'; return 0 ;;
    capture-pane)
      n=$(cat "$CAPS" 2>/dev/null); n=${n:-0}; echo $((n + 1)) > "$CAPS"
      case "${FAKE_CAP:-}" in
        blank) return 0 ;;
        first) [ "$n" = 0 ] && return 0 ;;
        second) [ "$n" = 1 ] && return 0 ;;
      esac
      printf 'some earlier output\n> \n'; return 0 ;;
  esac
  return 0
}
gh() { [ "${FAKE_GH:-}" = fail ] && return 1; printf 'OPEN\n'; return 0; }
export -f git tmux gh

run_report() { # [args...] -> the report
  : > "$CAPS"
  SHIPYARD_MOTION_INTERVAL=0.01 SHIPYARD_STALL_SECS=1800 SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t22ex \
    bash "$REPORT" "$@" 51 2>/dev/null
}
row() { printf '%s\n' "$1" | grep "^| $2 " | cut -d'|' -f5 | sed 's/^ *//; s/ *$//'; }
stalled() { has "$1" '^### 🛑 STALLED'; }
since_of() { awk -F'\t' '$1 == "51" { print $3 }' "$MB/report-stall" 2>/dev/null; }
backdate_stall() { # <seconds>
  local f="$MB/report-stall"
  [ -f "$f" ] || { echo "  FAIL backdate_stall: no stall table yet — the fixture asserts nothing"; FAILURES=$((FAILURES + 1)); return 1; }
  awk -F'\t' -v t="$(( $(date +%s) - $1 ))" 'BEGIN{OFS="\t"} NF>=3 {$3=t; print}' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
}
fresh() { rm -f "$MB/report-sig" "$MB/report-stall" "$MB/report-tick" "$MB/report-episodes"; }

printf '\n── #142: a flickering forge does not rebase the clock ──\n'
fresh
out=$(run_report)
ok "tick 1: the slot is idle"                    "⏸ idle/wait"  "$(row "$out" 51)"
ok "...with its PR read as open"                 yes            "$(has "$out" '^| 51 .*| opened / impl-review |')"
backdate_stall 1200
t0=$(since_of)
out=$(FAKE_GH=fail run_report)
ok "tick 2: the forge read failed (state ?)"     yes            "$(has "$out" '^| 51 .*| ? / impl-review |')"
ok "...and since is NOT rebased"                 "$t0"          "$(since_of)"
backdate_stall 2400
t0=$(since_of)
out=$(run_report)
ok "tick 3: the forge is back, since still held" "$t0"          "$(since_of)"
ok "...and STALLED fires on schedule"            yes            "$(stalled "$out")"
# --only-changed still reads the forge state: its signature is SIG, not the clock's key, so a
# state change stays news even though it no longer restarts the clock.
run_report --only-changed >/dev/null
out=$(FAKE_GH=fail run_report --only-changed)
ok "--only-changed still prints the state change" yes           "$(has "$out" '^| 51 ')"

printf '\n── #155: an empty capture is no verdict, never idle ──\n'
fresh
run_report >/dev/null
backdate_stall 7200
before=$(cat "$MB/report-stall")
out=$(FAKE_CAP=blank run_report)
ok "two failed reads render unreadable, not idle" "❔ unreadable" "$(row "$out" 51)"
ok "...do not fire, though the clock is past due" no            "$(stalled "$out")"
ok "...and write back the row they read, verbatim" "$before"    "$(cat "$MB/report-stall")"
out=$(run_report)
ok "the next readable tick keeps the clock and fires" yes       "$(stalled "$out")"

fresh
run_report >/dev/null
backdate_stall 7200
before=$(cat "$MB/report-stall")
out=$(FAKE_CAP=first run_report)
ok "one failed read of two is unreadable too"     "❔ unreadable" "$(row "$out" 51)"
ok "...and leaves the row untouched"              "$before"     "$(cat "$MB/report-stall")"
out=$(FAKE_CAP=second run_report)
ok "so is a failed SECOND read"                   "❔ unreadable" "$(row "$out" 51)"
ok "...whose empty hash is not stored"            "$before"     "$(cat "$MB/report-stall")"

fresh
out=$(FAKE_CAP=blank run_report)
ok "with no row to carry, an unreadable tick writes none" no \
   "$( [ -s "$MB/report-stall" ] && echo yes || echo no )"

# A supervision gap still restarts the clock on an unreadable tick: the stale row is dropped
# rather than carried past time nobody watched.
fresh
run_report >/dev/null
backdate_stall 7200
printf '%s\n' "$(( $(date +%s) - 7200 ))" >"$MB/report-tick"
FAKE_CAP=blank run_report >/dev/null
out=$(run_report)
ok "after a gap, the unreadable tick carried no clock" no       "$(stalled "$out")"

# A screen that stays unreadable never alarms, so its start and its end must be news.
fresh
run_report --only-changed >/dev/null
out=$(run_report --only-changed)
ok "readable and unchanged: the filter is silent" ""            "$out"
out=$(FAKE_CAP=blank run_report --only-changed)
ok "the tick it becomes unreadable is news"       yes           "$(has "$out" '^| 51 .*❔ unreadable')"
out=$(FAKE_CAP=blank run_report --only-changed)
ok "...once"                                      ""            "$out"
out=$(run_report --only-changed)
ok "and the tick it clears is news too"           yes           "$(has "$out" '^| 51 ')"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 't22-stall-clock: %d checks, all passed\n' "$CHECKS"
  exit 0
fi
printf 't22-stall-clock: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"
exit 1
