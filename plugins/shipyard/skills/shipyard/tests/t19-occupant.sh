#!/usr/bin/env bash
# t19-occupant.sh — a terminal whose agent has gone is not an idle child (#172).
#
# PROVENANCE. Three children died in one day leaving their terminals up. Each read, from the
# report, as `⏸ idle/wait` with a plausible ctx figure; the stall block fired and prescribed a
# nudge, and the nudge was typed at a zsh prompt — `zsh: bad pattern: [supervisor` — and recorded
# as sent, because a shell starts no turn to confirm or deny. The fix asks the backend which
# process owns the pane (`drv_occupant` in shared/driver, whose own suite pins the per-backend
# reading against real captures). What this file pins is what shipyard DOES with the answer:
#
#   1. `none` on both reads of a tick is its own row and its own block, never the stall block, and
#      that block bypasses --only-changed while it holds and is news again the tick it clears;
#   2. NO VERDICT CLAIMS NOTHING — a slot whose backend cannot say who owns the pane renders exactly
#      as it did before this change, row and stall clock alike. Asserted by running the report,
#      not by grepping for the line, because the failure it guards is a branch taken, not a line
#      missing;
#   3. one `none` followed by `agent` — a launch caught before its `exec` — is not a death;
#   4. tell and compact refuse a `none` slot with exit 8, typing nothing and recording nothing, and
#      go on exactly as before when there is no verdict.
#
# Executed against the real scripts over a faked tmux, as t13 and t18 do.
set -uo pipefail
export LC_ALL=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$DIR/.." && pwd)"
REPORT="$SKILL_DIR/shipyard-report.sh"
TELL="$SKILL_DIR/shipyard-tell.sh"
COMPACT="$SKILL_DIR/shipyard-compact.sh"

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}
has() { printf '%s' "$1" | grep -q -- "$2" && printf yes || printf no; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/t19-occupant.XXXXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

FAKE_ROOT="$TMP/repo"; FAKE_GIT="$TMP/gitdir"; MB="$FAKE_GIT/ship-escalations"
KEYS="$TMP/keys"; C44="$TMP/c44"
mkdir -p "$FAKE_ROOT" "$MB"
: > "$MB/container-tmux"        # pinned where we resolve, so no `elsewhere` refusal
for s in 41 42 43 44 45 46; do
  mkdir -p "$FAKE_ROOT/.claude/worktrees/ship-$s/.pipeline-state"
  printf '{"pr_number":9%s,"state":"impl-review"}\n' "$s" >"$FAKE_ROOT/.claude/worktrees/ship-$s/.pipeline-state/PR-9$s.json"
done
printf '{"pr_number":945,"state":"ready-to-merge"}\n' >"$FAKE_ROOT/.claude/worktrees/ship-45/.pipeline-state/PR-945.json"
printf '{"pr_number":946,"state":"needs-human"}\n'    >"$FAKE_ROOT/.claude/worktrees/ship-46/.pipeline-state/PR-946.json"
export FAKE_ROOT FAKE_GIT KEYS C44

# The slots, one per case:
#   41  `none` on every read            — the #172 shape (FAKE_OCC=alive turns it back into an agent)
#   42  `agent` on every read           — a healthy idle child, the control
#   43  no verdict: display-message fails — the backend could not say
#   44  `none` once, then `agent`        — a launch caught between its shell and its exec
#   45  `none` on every read, at ready-to-merge with its PR open — a FINISHED change whose agent
#       exited after the hand-off: still finished (merging needs no agent), with the exit annotated
#   46  `none` like 41 (FAKE_OCC too), at needs-human — a class that is NOT `finished`: its dead
#       agent must still read 💀, which is what pins "finished alone" in the exemption
git() {
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
                    *window_index*) printf '1 ship-41\n2 ship-42\n3 ship-43\n4 ship-44\n5 ship-45\n6 ship-46\n' ;;
                    *)              printf 'ship-41\nship-42\nship-43\nship-44\nship-45\nship-46\n' ;;
                  esac; return 0 ;;
    has-session)  return 0 ;;
    send-keys)    shift; printf '%s\n' "$*" >> "$KEYS"; return 0 ;;
    display-message)
      case "$*" in
        *t19ex:1*|*t19ex:6*) if [ "${FAKE_OCC:-dead}" = alive ]; then printf '0 claude\n'; else printf '0 zsh\n'; fi ;;
        *t19ex:2*) printf '0 claude\n' ;;
        *t19ex:3*) return 1 ;;
        *t19ex:5*) if [ "${FAKE_OCC45:-dead}" = alive ]; then printf '0 claude\n'; else printf '0 zsh\n'; fi ;;
        # An EMPTY counter file is the first read — the runners truncate it — so default the empty
        # read too, not just a missing file. Without that the first read was `agent` and the case
        # proved nothing: the one-read-is-enough mutation survived it, which is how this was found.
        *t19ex:4*) n=$(cat "$C44" 2>/dev/null); n=${n:-0}; echo $((n + 1)) > "$C44"
                   if [ "$n" = 0 ]; then printf '0 zsh\n'; else printf '0 claude\n'; fi ;;
      esac
      return 0 ;;
    capture-pane) printf 'some earlier output\n> \n'; return 0 ;;
  esac
  return 0
}
gh() { printf 'OPEN\n'; return 0; }
export -f git tmux gh

run_report() { # [args...] -> the report
  : > "$C44"
  SHIPYARD_MOTION_INTERVAL=0.01 SHIPYARD_STALL_SECS=1800 SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t19ex \
    bash "$REPORT" "$@" 41 42 43 44 45 46 2>/dev/null
}
row() { printf '%s\n' "$1" | grep "^| $2 " | cut -d'|' -f5 | sed 's/^ *//; s/ *$//'; }
# The hyphen goes LAST in tr's set: `'`- '` is a range to GNU tr (backtick to space, reversed —
# an error) and a literal list to BSD tr, so the old spelling passed on macOS and emptied every
# block on Linux CI.
block() { printf '%s\n' "$1" | sed -n "/^### $2/,/^###/p" | grep -o '^- `[0-9]*`' | tr -d '` -' | tr '\n' ' ' | sed 's/ $//'; }
backdate_stall() { # <seconds>
  local f="$MB/report-stall"
  [ -f "$f" ] || { echo "  FAIL backdate_stall: no stall table yet — the fixture asserts nothing"; FAILURES=$((FAILURES + 1)); return 1; }
  awk -F'\t' -v t="$(( $(date +%s) - $1 ))" 'BEGIN{OFS="\t"} NF>=3 {print $1,$2,t}' "$f" >"$f.tmp" && mv "$f.tmp" "$f"
}

printf '\n── the report: a dead agent is its own row and block ──\n'
out=$(run_report)
ok "41 (none, none) reads no agent"            "💀 no agent"  "$(row "$out" 41)"
ok "42 (agent) is the ordinary idle row"       "⏸ idle/wait"  "$(row "$out" 42)"
ok "43 (no verdict) is the ordinary idle row"  "⏸ idle/wait"  "$(row "$out" 43)"
ok "44 (none, then agent) is not a death"      "⏸ idle/wait"  "$(row "$out" 44)"
ok "45 (finished, no agent) stays finished"    "✅ finished (no agent)"  "$(row "$out" 45)"
ok "the NO AGENT block names 41 and 46 only"    "41 46"          "$(block "$out" '💀 NO AGENT')"
ok "45 is under WAITING FOR YOU as before"     "45"           "$(block "$out" '🙋 WAITING FOR YOU')"
ok "...whose action says tell will refuse it"  yes \
   "$(printf '%s\n' "$out" | sed -n '/^### 🙋 WAITING FOR YOU/,/^###/p' | grep '^- `45`' | grep -q 'refuse it with exit 8' && echo yes || echo no)"
ok "46 (needs-human, no agent) is still no agent" "💀 no agent" "$(row "$out" 46)"
ok "...and prescribes no nudge or compaction"  no \
   "$(printf '%s\n' "$out" | sed -n '/^### 💀 NO AGENT/,/^###/p' | grep -q 'bash .*shipyard-\(tell\|compact\)\.sh ' && echo yes || echo no)"

printf '\n── past the stall threshold: no verdict keeps today'"'"'s path ──\n'
backdate_stall 7200
out=$(run_report)
ok "STALLED names every live-or-unknown idle slot, never 41" "42 43 44" "$(block "$out" '🛑 STALLED')"
ok "41 and 46 are still under NO AGENT"                      "41 46"     "$(block "$out" '💀 NO AGENT')"

printf '\n── --only-changed ──\n'
rm -f "$MB/report-sig" "$MB/report-stall"
run_report --only-changed >/dev/null
out=$(run_report --only-changed)
ok "a dead agent breaks the silence on every tick"    yes "$(has "$out" '### 💀 NO AGENT')"
out=$(FAKE_OCC=alive run_report --only-changed)
ok "the tick it clears is news too"                   yes "$(has "$out" '^| 41 ')"
ok "...with no block left"                            no  "$(has "$out" '### 💀 NO AGENT')"
out=$(FAKE_OCC=alive run_report --only-changed)
ok "and then the filter is silent again"              ""  "$out"

# A FINISHED slot's agent dying gets no 💀 block and so no bypass — only the signature can make it
# news. Without `fna=` in it the death changed nothing the filter sees and the monitor printed
# nothing at all, while the comment and SKILL.md called the state visible.
rm -f "$MB/report-sig" "$MB/report-stall"
FAKE_OCC=alive FAKE_OCC45=alive run_report --only-changed >/dev/null
out=$(FAKE_OCC=alive FAKE_OCC45=alive run_report --only-changed)
ok "all alive: the filter is silent"                          ""  "$out"
out=$(FAKE_OCC=alive FAKE_OCC45=dead run_report --only-changed)
ok "a finished slot's agent dying breaks the silence"         yes "$(has "$out" '^| 45 .*✅ finished (no agent)')"
ok "...as a finished row, with no 💀 block"                   no  "$(has "$out" '### 💀 NO AGENT')"
out=$(FAKE_OCC=alive FAKE_OCC45=dead run_report --only-changed)
ok "...and once: the next tick is silent again"               ""  "$out"

run_tell() { # <args...> -> output, then "rc=<n>"
  local out rc=0
  : > "$KEYS"; : > "$C44"
  out=$( env SHIPYARD_MOTION_INTERVAL=0.01 SHIPYARD_TELL_SETTLE_DELAY=0.01 \
             SHIPYARD_TELL_CONFIRM_SECS=1 SHIPYARD_TELL_CONFIRM_INTERVAL=0.2 \
             SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t19ex \
         bash "$TELL" "$@" 2>&1 ) || rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
rc_of() { printf '%s' "$1" | sed -n 's/^rc=//p' | tail -1; }
records() { find "$MB" -name 'directive-*' | wc -l | tr -d ' '; }

printf '\n── tell ──\n'
out=$(run_tell 41 "a directive")
ok "a dead agent is exit 8"                   8   "$(rc_of "$out")"
ok "...with nothing typed"                    0   "$(wc -l < "$KEYS" | tr -d ' ')"
ok "...and nothing recorded"                  0   "$(records)"
ok "...saying why"                            yes "$(has "$out" 'the agent launched into it is not')"
out=$(run_tell 41 --submit)
ok "--submit is refused the same way"         8   "$(rc_of "$out")"
ok "...pressing nothing"                      0   "$(wc -l < "$KEYS" | tr -d ' ')"
out=$(run_tell 43 "a directive")
ok "no verdict goes on as before: it types"   1   "$(grep -c -- ' -l ' "$KEYS")"
ok "...and is not exit 8"                     no  "$( [ "$(rc_of "$out")" = 8 ] && echo yes || echo no )"
out=$(run_tell 44 "a directive")
ok "one none then agent is not refused"       1   "$(grep -c -- ' -l ' "$KEYS")"
out=$(run_tell 42 "a directive")
ok "a live agent is told"                     1   "$(grep -c -- ' -l ' "$KEYS")"

printf '\n── compact ──\n'
: > "$KEYS"
rc=0; out=$(SHIPYARD_MOTION_INTERVAL=0.01 SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t19ex \
            bash "$COMPACT" 41 --no-resume --timeout 1 2>&1) || rc=$?
ok "a dead agent is exit 8"                   8   "$rc"
ok "...with nothing sent, not even Escape"    0   "$(wc -l < "$KEYS" | tr -d ' ')"
ok "...saying why"                            yes "$(has "$out" 'the agent launched into it is not')"
# Compact carries its own copy of the two-read check, so it gets tell's two other cases too: no
# verdict goes on, and one `none` then `agent` goes on. Going on means it sends the Escape; the
# fake never shows a `Compacted` marker, so the run then ends on its own timeout (exit 4).
compact_on() { # <slot> -> "<rc>|<keys sent>"
  local rc=0
  : > "$KEYS"; : > "$C44"
  SHIPYARD_MOTION_INTERVAL=0.01 SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t19ex \
    bash "$COMPACT" "$1" --no-resume --timeout 1 >/dev/null 2>&1 || rc=$?
  printf '%s|%s' "$rc" "$( [ -s "$KEYS" ] && echo sent || echo none )"
}
ok "no verdict goes on: it sends, and is not exit 8"        "4|sent" "$(compact_on 43)"
ok "one none then agent goes on: it sends, not exit 8"      "4|sent" "$(compact_on 44)"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 't19-occupant: %d checks, all passed\n' "$CHECKS"
  exit 0
fi
printf 't19-occupant: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"
exit 1
