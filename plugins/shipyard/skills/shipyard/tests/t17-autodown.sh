#!/usr/bin/env bash
# t17-autodown.sh — a merged slot tears itself down (#181), and the teardown gate that made
# automating it safe (#139(1)).
#
# PROVENANCE. A merged slot is finished work, and it sat there — terminal and worktree — until
# somebody remembered `shipyard-down.sh` (#181 counts eight torn down by hand in one week), and the
# report exits by itself once nothing is in flight, which makes the fleet feel self-cleaning
# while the worktrees remain. Automating that meant putting a monitor in front of the one path
# in this repo where acting on a wrong answer removes a live child's worktree, so the two
# halves below are one change: the gate first, then the trigger.
#
# PART A — shipyard-down.sh, on REAL git. Faking git here would only replay a belief about what
# `worktree remove` does, which is the mistake t12 exists to record; so each case builds a real
# bare origin, a real clone and a real registered worktree, and asks the real git whether the
# directory is still there afterwards. Only `tmux` is faked, because the backend is the one
# thing a test cannot have.
#   A1 the happy path still works: a resolvable terminal is killed and the worktree removed —
#      and NO enumeration is spent doing it. The guard is asked only when a run closed
#      nothing, because an enumeration between the close and the removal would let a backend
#      that has not caught up refuse the teardown the operator just asked for.
#   A2 target unresolvable, backend ANSWERS and STILL LISTS the slot: refused, worktree kept.
#      The narrowest blip and the one that ends in a teardown — `drv_target` makes its own
#      backend call, so it can fail while the enumeration succeeds.
#   A3 target unresolvable, backend answers and does NOT list it: proceeds. Without this case
#      a guard that refused everything would pass A2 and A4 and break teardown entirely.
#   A4 target unresolvable, backend does NOT ANSWER: refused, worktree kept. This is #139(1)'s
#      measured scenario — one failed agterm socket probe under SHIPYARD_BACKEND=auto skipped
#      the kill silently and removed the worktree of a child alive in the other backend, and
#      the run printed only `removed worktree …`.
#   A5 the same state with --force: removed. --force stays a human act and still overrides
#      every gate; a guard that could not be overridden would be a new way to be stuck.
#   A6 a DIRTY worktree is still refused. The content gate is what the automatic path must go
#      through rather than around, so a regression there is the one that matters most.
#
# PART B — the trigger, inside shipyard-report.sh. The rig is t15's (exported shell functions
# shadow `git`, `tmux` and `gh`), with one addition: the report runs out of a TEMP DIRECTORY of
# symlinks to the real scripts, in which `shipyard-down.sh` is a recorder. That makes the call
# observable without giving production a test-only seam, and it means a report that stops
# invoking the teardown reds here rather than passing on a mocked-out path.
#   B1 ONE merged tick tears nothing down — the trigger may not be a single observation of the
#      forge, which is the property the whole design was asked for.
#   B2 the SECOND consecutive one does, calling shipyard-down.sh with the slot and NOTHING
#      else. The absence of `--force` is asserted as its own check: it is a binding condition,
#      and a flag added later would otherwise ship green.
#   B3 lock 2 — a non-terminal ship stage never fires, however merged the PR is. `merged` is
#      not "child done": the forge says one PR ended while the child is still posting its
#      record and writing its state file.
#   B4 lock 3 — a BUSY terminal never fires. Somebody (or the child) is using it.
#   B5 `closed` never fires. A closed PR's content is not in the base branch, so the content
#      gate would refuse by construction; it is left out on purpose, and this case pins that
#      decision so a later reader does not add it back as an obvious omission.
#   B6 merged -> `?` -> merged does NOT fire on the third tick. #142 documents the two failure
#      modes behind it — `mr_state` mapping any unrecognised answer to `?`, and a failing iid
#      lookup falling back to `no MR yet` — for the sequences `opened -> ? -> opened` and
#      `opened -> no MR yet -> opened`, found by review of #138 rather than measured in the
#      wild. Neither mode is state-specific, so the same intermittency produces this one. A kill
#      test for the unconditional rewrite of $MERGEDFILE: preserve the file when empty, as the
#      stall table beside it does, and this case goes RED on the third tick. (Measured: two of
#      B6's assertions fail. "Goes green" is this suite's idiom for a case that proves nothing,
#      and this sentence said it by accident — the exact reading that invites a maintainer to
#      prune B6 as padding and reinstate the flicker path.)
#   B7 a refusal is RENDERED, with the exact command, and no teardown is claimed. Without the
#      block, a slot the automatic path declines would be QUIETER than one nobody looked at —
#      it keeps its worktree and, once its terminal goes, stops being enumerated.
#   B8 SHIPYARD_AUTODOWN=0 tears nothing down, ever.
#   B9 SHIPYARD_AUTODOWN_TICKS=1 is refused with a warning and does not fire on one tick.
#      knob_uint admits 0 and 1 — for a poll window that is legitimate — so the floor lives in
#      the caller, and without it the operator's own typo removes the consecutive-tick lock.
#   B10 the NO-TERMINAL arm: a slot whose terminal is gone, whose absence the backend
#      corroborates, and whose work is merged and finished IS torn down. That shape is the one
#      that accumulates — it is not enumerated in discovery mode, so only a named-slot monitor
#      ever sees it again.
#
# WHAT A GREEN RUN DOES NOT PROVE. Part B's `gh` is a fake, so nothing here proves the forge
# really answers MERGED for a merged PR; both parts fake `tmux`, so nothing proves a real
# agterm session closes or that a real socket blip produces the classes A2/A4 stage. The agterm
# arm of the backend is not exercised at all. No case runs the report against the real
# `shipyard-down.sh`, so the two halves meet only through the argv Part B records.
#
# THREE LINES MUTATION TESTING FOUND UNGUARDED, named here rather than left to be rediscovered:
# the in-flight accounting of a reaping tick (both call sites can be made to count a reaped slot
# in flight with everything below still green); lock 3's absence arm on the no-terminal path
# (making `shipyard_absence_report` never refuse changes nothing here, because shipyard-down.sh's
# own guard catches it one level down — which is worth knowing, not a gap to close twice); and
# `A4: ...at a non-zero exit`, which holds even with the guard deleted, because an unreachable
# backend independently makes the run exit 1 through the continuity-cleanup warning. A4's other
# two checks do fail, so the case is not vacuous — that one line just proves less than it looks.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$DIR/.." && pwd)"
DOWN="$SKILL_DIR/shipyard-down.sh"

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}
present() { [ -d "$1" ] && echo 1 || echo 0; }

# An identity for the real commits Part A makes, without touching the runner's own config and
# WITHOUT an address shape: the repo's leak gate denies that shape wherever it appears, so a
# fixture address here would red the gate for every commit after this one. Same arrangement as
# t12, and for the same reason.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=shipyard-test GIT_AUTHOR_EMAIL=shipyard-test
export GIT_COMMITTER_NAME=shipyard-test GIT_COMMITTER_EMAIL=shipyard-test

T17TMP=$(mktemp -d "${TMPDIR:-/tmp}/t17-autodown.XXXXXXXX") || exit 1
trap 'rm -rf "$T17TMP"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# PART A — shipyard-down.sh and the absence guard, on real git
# ─────────────────────────────────────────────────────────────────────────────
printf 'part A — shipyard-down.sh + shipyard_absence_report (real git)\n'

A="$T17TMP/a"
mkdir -p "$A"
git init -q --bare "$A/origin.git"
git clone -q "$A/origin.git" "$A/repo" 2>/dev/null
(
  cd "$A/repo" || exit 1
  echo one >file.txt
  git add file.txt
  git commit -q -m base
  git push -q origin HEAD:main
  git remote set-head origin main >/dev/null 2>&1
  # Every slot sits on a branch whose tree is identical to origin/main, which is the content
  # gate's cheapest `safe` proof — so any refusal below is the guard under test and not the gate.
  for s in 71 72 73 74 75 76; do
    git worktree add -q -b "feat/s$s" "$A/repo/.claude/worktrees/ship-$s" origin/main
  done
  echo scratch >"$A/repo/.claude/worktrees/ship-76/untracked.txt"   # A6
) || { echo "part A: rig setup failed"; exit 1; }

A_WINS="$A/wins"; A_ENUM="$A/enum"; A_ENUM_RC="$A/enum-rc"
A_KILLS="$A/kills"; A_ENUM_CALLS="$A/enum-calls"
export A_WINS A_ENUM A_ENUM_RC A_KILLS A_ENUM_CALLS
# `ship-79` is always enumerated and never torn down, so the last-slot continuity cleanup at the
# foot of shipyard-down.sh always sees a non-empty fleet and cannot add an exit code of its own
# to the ones asserted here.
printf 'ship-79\n' >"$A_ENUM"
printf '1 ship-79\n' >"$A_WINS"
printf '0\n' >"$A_ENUM_RC"
: >"$A_KILLS"; : >"$A_ENUM_CALLS"

tmux() {
  local rc
  case "${1:-}" in
    list-windows)
      case "$*" in
        *'#{window_index}'*) cat "$A_WINS"; return 0 ;;              # drv_target
        *)                                                            # drv_sessions
          printf '%s\n' "$*" >>"$A_ENUM_CALLS"
          rc=$(cat "$A_ENUM_RC" 2>/dev/null || echo 0)
          [ "$rc" = 0 ] || { echo 'lost server' >&2; return "$rc"; }
          cat "$A_ENUM"; return 0 ;;
      esac ;;
    has-session) return 0 ;;
    capture-pane) printf 'idle\n'; return 0 ;;
    kill-window) printf '%s\n' "$*" >>"$A_KILLS"; return 0 ;;
  esac
  return 0
}
export -f tmux

A_OUT="$A/out"
# Writes the run's combined output to $A_OUT and RETURNS the script's exit status. Deliberately
# not `out=$(a_run ...)`: a command substitution forks, so a status stashed in a variable inside
# it never reaches the caller — and every exit-code assertion below would read the last value the
# parent happened to hold.
a_run() {
  ( cd "$A/repo" && SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t17a bash "$DOWN" "$@" ) >"$A_OUT" 2>&1
}

# A1 — the happy path, and the cost of the guard on it.
printf '1 ship-79\n2 ship-71\n' >"$A_WINS"
: >"$A_ENUM_CALLS"
a_run 71; a1_rc=$?
ok "A1: a resolvable terminal is killed"             1 "$(grep -c 'ship-71\|t17a:2' "$A_KILLS")"
ok "A1: ...its worktree is removed"                  0 "$(present "$A/repo/.claude/worktrees/ship-71")"
ok "A1: ...at exit 0"                                0 "$a1_rc"
# 1, not 0: shipyard-down.sh always enumerates ONCE at its foot, for the last-slot continuity
# cleanup. The assertion that matters is the DIFFERENCE from A2 below, where the guard is asked
# and the count is 2 — delete the `killed = 0` condition in front of the guard and this reads 2.
A1_ENUMS=$(grep -c . "$A_ENUM_CALLS")
ok "A1: ...and the guard spent no enumeration on it" 1 "$A1_ENUMS"

# A2 — `listed`: the enumeration answers and still has the slot, so the per-slot lookup is what
# failed. Slot 72 is absent from the window list (drv_target cannot resolve it) but present in
# the enumeration.
printf '1 ship-79\n' >"$A_WINS"
printf 'ship-79\nship-72\n' >"$A_ENUM"
: >"$A_KILLS"; : >"$A_ENUM_CALLS"
a_run 72; a2_rc=$?
a2=$(cat "$A_OUT")
ok "A2: a slot the backend still lists is refused"   1 "$(printf '%s' "$a2" | grep -c 'could not be corroborated')"
ok "A2: ...naming the class it saw"                  1 "$(printf '%s' "$a2" | grep -c 'still lists')"
ok "A2: ...at a non-zero exit"                       1 "$a2_rc"
ok "A2: ...with the worktree kept"                   1 "$(present "$A/repo/.claude/worktrees/ship-72")"
ok "A2: ...and nothing killed"                       0 "$(grep -c . "$A_KILLS")"
ok "A2: ...and the guard DID spend one, unlike A1"   $((A1_ENUMS + 1)) "$(grep -c . "$A_ENUM_CALLS")"

# A3 — corroborated gone: the guard must not refuse this, or teardown stops working entirely.
printf 'ship-79\n' >"$A_ENUM"
a_run 73; a3_rc=$?
ok "A3: a corroborated absence proceeds"             0 "$(present "$A/repo/.claude/worktrees/ship-73")"
ok "A3: ...at exit 0"                                0 "$a3_rc"

# A4 — #139(1) itself: the backend does not answer at all.
printf '1\n' >"$A_ENUM_RC"
a_run 74; a4_rc=$?
a4=$(cat "$A_OUT")
ok "A4: an unreachable backend is refused"           1 "$(printf '%s' "$a4" | grep -c 'could not be corroborated')"
ok "A4: ...at a non-zero exit"                       1 "$a4_rc"
ok "A4: ...with the worktree kept"                   1 "$(present "$A/repo/.claude/worktrees/ship-74")"

# A5 — and --force still overrides it, because a guard nobody can get past is a new way to be stuck.
a_run 75 --force
ok "A5: --force removes it anyway"                   0 "$(present "$A/repo/.claude/worktrees/ship-75")"

# A6 — the content gate must not have been loosened on the way past.
printf '0\n' >"$A_ENUM_RC"
a_run 76
a6=$(cat "$A_OUT")
ok "A6: a dirty worktree is still refused"           1 "$(printf '%s' "$a6" | grep -c 'uncommitted or untracked')"
ok "A6: ...with the worktree kept"                   1 "$(present "$A/repo/.claude/worktrees/ship-76")"

unset -f tmux

# ─────────────────────────────────────────────────────────────────────────────
# PART B — the trigger, inside shipyard-report.sh
# ─────────────────────────────────────────────────────────────────────────────
printf 'part B — the trigger (shipyard-report.sh)\n'

# The symlink farm. Every file beside the real report, except the teardown, which is a
# recorder: the report resolves its siblings from its own $BASH_SOURCE directory, so this
# exercises the real production call site with nothing stubbed inside the report itself.
FARM="$T17TMP/farm"
mkdir -p "$FARM"
for f in "$SKILL_DIR"/*; do
  [ -f "$f" ] || continue
  case "$(basename "$f")" in shipyard-down.sh) continue ;; esac
  ln -s "$f" "$FARM/$(basename "$f")"
done
DOWN_CALLS="$T17TMP/down-calls"
DOWN_RC_FILE="$T17TMP/down-rc"
: >"$DOWN_CALLS"; printf '0\n' >"$DOWN_RC_FILE"
cat >"$FARM/shipyard-down.sh" <<'FAKEDOWN'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOWN_CALLS"
rc=$(cat "$DOWN_RC_FILE" 2>/dev/null || echo 0)
if [ "$rc" != 0 ]; then
  echo "refused: ship-$1 has uncommitted or untracked changes" >&2
  exit "$rc"
fi
echo "closed t17b:1"
echo "removed worktree /nowhere"
FAKEDOWN
chmod +x "$FARM/shipyard-down.sh"
export DOWN_CALLS DOWN_RC_FILE

B_ROOT="$T17TMP/b/repo"; B_GIT="$T17TMP/b/gitdir"
B_STATES="$T17TMP/b/forge-states"   # <iid> TAB OPEN|MERGED|CLOSED, rewritten per tick
B_WINS="$T17TMP/b/wins"             # drv_target's window list
B_ENUM="$T17TMP/b/enum"             # drv_sessions' answer
B_SCREEN="$T17TMP/b/screen"         # what capture-pane returns; its LAST line decides idle/busy
mkdir -p "$B_ROOT" "$B_GIT/ship-escalations" "$T17TMP/b"
printf '\xe2\x9d\xaf \n' >"$B_SCREEN"   # an input prompt at the foot of the screen = idle
export B_ROOT B_GIT B_STATES B_WINS B_ENUM B_SCREEN

git() {
  local dir=""
  if [ "${1:-}" = "-C" ]; then dir="$2"; shift 2; fi
  case "$*" in
    "rev-parse --show-toplevel")  printf '%s\n' "$B_ROOT"; return 0 ;;
    "rev-parse --git-common-dir") printf '%s\n' "$B_GIT";  return 0 ;;
    "remote get-url origin")      printf 'https://github.com/example/example.git\n'; return 0 ;;
    "symbolic-ref --quiet --short refs/remotes/origin/HEAD") printf 'origin/main\n'; return 0 ;;
    "worktree list --porcelain")  return 0 ;;
    "rev-parse --abbrev-ref HEAD") printf 'main\n'; return 0 ;;
  esac
  return 0
}
tmux() {
  case "${1:-}" in
    list-windows)
      case "$*" in
        *'#{window_index}'*) cat "$B_WINS" ;;
        *)                   cat "$B_ENUM" ;;
      esac
      return 0 ;;
    has-session)  return 0 ;;
    capture-pane) cat "$B_SCREEN"; return 0 ;;
  esac
  return 0
}
gh() {
  local a filter="" want=0 iid="" st
  for a in "$@"; do
    if [ "$want" = 1 ]; then filter="$a"; want=0; continue; fi
    [ "$a" = "--jq" ] && want=1
  done
  case "$*" in
    *"pr view"*)
      for a in "$@"; do case "$a" in [0-9]*) iid="$a"; break ;; esac; done
      st=$(grep -F "$iid	" "$B_STATES" 2>/dev/null | head -1 | cut -f2)
      [ -n "$st" ] || st=UNKNOWN
      if [ -n "$filter" ]; then printf '{"state":"%s"}' "$st" | jq -r "$filter" 2>/dev/null
      else printf '%s\n' "$st"; fi
      return 0 ;;
  esac
  return 0
}
export -f git tmux gh

b_slot() { # <slot> <iid> <stage>
  mkdir -p "$B_ROOT/.claude/worktrees/ship-$1/.pipeline-state"
  printf '{"pr_number":%s,"state":"%s"}\n' "$2" "$3" \
    >"$B_ROOT/.claude/worktrees/ship-$1/.pipeline-state/PR-$2.json"
}
b_reset() { : >"$DOWN_CALLS"; rm -f "$B_GIT/ship-escalations/report-merged"; }
b_tick() { # [<VAR=value> ...] -- <slot> ...
  local envs=() slots=() seen=0 a
  for a in "$@"; do
    if [ "$a" = "--" ]; then seen=1; continue; fi
    if [ "$seen" = 0 ]; then envs+=("$a"); else slots+=("$a"); fi
  done
  printf '%s\n' "$(date +%s)" >"$B_GIT/ship-escalations/report-tick"
  # ${a[@]+"${a[@]}"} and not "${a[@]}": expanding an EMPTY array under `set -u` is a fatal
  # unbound-variable error in bash 3.2, which is what /bin/bash is on macOS — the interpreter
  # this suite exists to keep the production code runnable under. Every b_tick call with no env
  # override passes an empty `envs`, so the plain form aborted the whole file at the first such
  # call outside a $( ) and 19 of the checks below never ran. No automated invocation saw it
  # (run-all.sh, the Makefile and CI all reach a modern bash through PATH), which is exactly why
  # it is spelled out here. `slots` gets the same treatment: it is non-empty at every call site
  # today, so it is latent rather than broken, and the two should not differ.
  env SHIPYARD_STALL_SECS=100000 SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t17b ${envs[@]+"${envs[@]}"} \
    bash "$FARM/shipyard-report.sh" ${slots[@]+"${slots[@]}"} 2>/dev/null
}

# --- B1/B2: one tick is not enough, two are; and the argv carries no flags ------------------
b_reset
b_slot 61 861 ready-to-merge
printf '1 ship-61\n' >"$B_WINS"; printf 'ship-61\n' >"$B_ENUM"
printf '861\tMERGED\n' >"$B_STATES"

t1out=$(b_tick -- 61)
ok "B1: one merged tick tears nothing down"          0 "$(grep -c . "$DOWN_CALLS")"
ok "B1: ...and the row is the ordinary merged row"   1 "$(printf '%s' "$t1out" | grep -c '^| 61 | !861 .*merged /')"

t2out=$(b_tick -- 61)
ok "B2: the second consecutive merged tick fires"    1 "$(grep -c '^61$' "$DOWN_CALLS")"
ok "B2: ...exactly once"                             1 "$(grep -c . "$DOWN_CALLS")"
ok "B2: ...with NO --force, ever"                    0 "$(grep -c -- '--force' "$DOWN_CALLS")"
ok "B2: ...and the report says what it removed"      1 "$(printf '%s' "$t2out" | grep -c 'TORN DOWN — merged, finished')"
ok "B2: ...and the row shows it"                     1 "$(printf '%s' "$t2out" | grep -c '^| 61 .*torn down')"

# --- B3: lock 2 — a non-terminal ship stage never fires ------------------------------------
b_reset
b_slot 62 862 impl-review
printf '1 ship-62\n' >"$B_WINS"; printf 'ship-62\n' >"$B_ENUM"
printf '862\tMERGED\n' >"$B_STATES"
b_tick -- 62 >/dev/null
b3out=$(b_tick -- 62)
ok "B3: merged but mid-review is never torn down"    0 "$(grep -c . "$DOWN_CALLS")"
ok "B3: ...and stays in the table as a live slot"    1 "$(printf '%s' "$b3out" | grep -c '^| 62 | !862 .*merged / impl-review')"

# --- B4: lock 3 — a busy terminal never fires ----------------------------------------------
b_reset
b_slot 63 863 ready-to-merge
printf '1 ship-63\n' >"$B_WINS"; printf 'ship-63\n' >"$B_ENUM"
printf '863\tMERGED\n' >"$B_STATES"
printf 'thinking about it\n' >"$B_SCREEN"     # no input prompt on the last line = busy
b_tick -- 63 >/dev/null
b_tick -- 63 >/dev/null
ok "B4: a busy terminal is never torn down"          0 "$(grep -c . "$DOWN_CALLS")"
printf '\xe2\x9d\xaf \n' >"$B_SCREEN"

# --- B5: `closed` is not a trigger ---------------------------------------------------------
b_reset
b_slot 64 864 ready-to-merge
printf '1 ship-64\n' >"$B_WINS"; printf 'ship-64\n' >"$B_ENUM"
printf '864\tCLOSED\n' >"$B_STATES"
b_tick -- 64 >/dev/null
b_tick -- 64 >/dev/null
ok "B5: a closed PR is never torn down"              0 "$(grep -c . "$DOWN_CALLS")"

# --- B6: the flicker. merged -> ? -> merged must still be ONE consecutive run ---------------
b_reset
b_slot 65 865 ready-to-merge
printf '1 ship-65\n' >"$B_WINS"; printf 'ship-65\n' >"$B_ENUM"
printf '865\tMERGED\n' >"$B_STATES"
b_tick -- 65 >/dev/null
printf '865\tWHAT\n' >"$B_STATES"          # an unresolvable answer: mr_state renders `?`
b_tick -- 65 >/dev/null
printf '865\tMERGED\n' >"$B_STATES"
b6out=$(b_tick -- 65)
ok "B6: a flicker between two merged ticks resets the count" 0 "$(grep -c . "$DOWN_CALLS")"
ok "B6: ...and the slot is still rendered, not dropped"      1 "$(printf '%s' "$b6out" | grep -c '^| 65 | !865 ')"
b_tick -- 65 >/dev/null
ok "B6: ...and two consecutive ticks after it still fire"    1 "$(grep -c '^65$' "$DOWN_CALLS")"

# --- B7: a refusal is rendered, with the exact command, and claims nothing ------------------
b_reset; printf '1\n' >"$DOWN_RC_FILE"
b_slot 66 866 done
printf '1 ship-66\n' >"$B_WINS"; printf 'ship-66\n' >"$B_ENUM"
printf '866\tMERGED\n' >"$B_STATES"
b_tick -- 66 >/dev/null
b7=$(b_tick -- 66)
ok "B7: the teardown was attempted"                  1 "$(grep -c '^66$' "$DOWN_CALLS")"
ok "B7: ...the refusal is rendered"                  1 "$(printf '%s' "$b7" | grep -c 'AWAITING REMOVAL')"
ok "B7: ...carrying the gate's own words"            1 "$(printf '%s' "$b7" | grep -c 'uncommitted or untracked')"
ok "B7: ...and the exact command to run"             1 "$(printf '%s' "$b7" | grep -c 'shipyard-down.sh 66$')"
ok "B7: ...with no teardown claimed"                 0 "$(printf '%s' "$b7" | grep -c 'TORN DOWN — merged, finished')"
printf '0\n' >"$DOWN_RC_FILE"

# --- B8/B9: the knobs -----------------------------------------------------------------------
b_reset
b_slot 67 867 ready-to-merge
printf '1 ship-67\n' >"$B_WINS"; printf 'ship-67\n' >"$B_ENUM"
printf '867\tMERGED\n' >"$B_STATES"
b_tick SHIPYARD_AUTODOWN=0 -- 67 >/dev/null
b_tick SHIPYARD_AUTODOWN=0 -- 67 >/dev/null
ok "B8: SHIPYARD_AUTODOWN=0 tears nothing down"      0 "$(grep -c . "$DOWN_CALLS")"

b_reset
b_slot 68 868 ready-to-merge
printf '1 ship-68\n' >"$B_WINS"; printf 'ship-68\n' >"$B_ENUM"
printf '868\tMERGED\n' >"$B_STATES"
printf '%s\n' "$(date +%s)" >"$B_GIT/ship-escalations/report-tick"
b9err=$( env SHIPYARD_STALL_SECS=100000 SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t17b \
           SHIPYARD_AUTODOWN_TICKS=1 bash "$FARM/shipyard-report.sh" 68 2>&1 >/dev/null )
ok "B9: a threshold of 1 is refused, loudly"         1 "$(printf '%s' "$b9err" | grep -c 'single forge read')"
ok "B9: ...and one tick still tears nothing down"    0 "$(grep -c . "$DOWN_CALLS")"

# --- B10: the no-terminal arm ---------------------------------------------------------------
# The shape that accumulates: no terminal, a worktree still on disk, the work merged and the
# child finished. The backend ANSWERS and does not list it, which is the corroboration the
# idle read is replaced by here.
b_reset
b_slot 69 869 done
printf '1 ship-79\n' >"$B_WINS"; printf 'ship-79\n' >"$B_ENUM"
printf '869\tMERGED\n' >"$B_STATES"
b10a=$(b_tick -- 69)
ok "B10: one tick on a gone slot tears nothing down" 0 "$(grep -c . "$DOWN_CALLS")"
ok "B10: ...and it renders as having no terminal"    1 "$(printf '%s' "$b10a" | grep -c '^| 69 .*no terminal')"
b10b=$(b_tick -- 69)
ok "B10: the second one tears it down"               1 "$(grep -c '^69$' "$DOWN_CALLS")"
ok "B10: ...and says so"                             1 "$(printf '%s' "$b10b" | grep -c 'TORN DOWN — merged, finished')"

# --- B11: the iid guard, which had no test at all ------------------------------------------
# A SUCCESSFUL reap leaves its row behind — the count is appended before the teardown runs — and
# the mailbox outlives the fleet while slot numbers are reused. The `prev_iid = iid` test is the
# only thing standing between that stale row and a brand-new child being torn down on its FIRST
# forge read, which is the single-observation trigger the whole mechanism exists to refuse.
# Deleting the condition left all other checks green, so this is written as its kill test:
# seed exactly what a completed reap leaves, then run ONE tick with a different PR number.
b_reset
b_slot 70 870 ready-to-merge
printf '1 ship-70\n' >"$B_WINS"; printf 'ship-70\n' >"$B_ENUM"
printf '870\tMERGED\n' >"$B_STATES"
printf '70\t999\t2\n' >"$B_GIT/ship-escalations/report-merged"
b_tick -- 70 >/dev/null
ok "B11: a stale count under a REUSED slot does not fire" 0 "$(grep -c . "$DOWN_CALLS")"
ok "B11: ...and the row is rewritten for the new PR"      1 \
   "$(grep -c '^70	870	1$' "$B_GIT/ship-escalations/report-merged")"

# --- B12: an open escalation HOLDS the teardown --------------------------------------------
# The slot is finished by every other measure — merged, stage terminal, terminal idle — and is
# idle only BECAUSE it asked the operator something. Tearing it down destroys the session that
# asked; worse, `shipyard-answer.sh` then exits 0 and claims the child will pick the answer up,
# because its fallback to `shipyard-tell.sh` is gated on `kind = notice`. Every other B case
# runs with an empty mailbox, so nothing pinned this until now.
b_reset
b_slot 71 871 ready-to-merge
printf '1 ship-71\n' >"$B_WINS"; printf 'ship-71\n' >"$B_ENUM"
printf '871\tMERGED\n' >"$B_STATES"
printf '{"kind":"question","status":"pending","slot":"71","text":"migrate or defer?"}\n' \
  >"$B_GIT/ship-escalations/71-1.json"
b_tick -- 71 >/dev/null
b12=$(b_tick -- 71)
ok "B12: an open question holds the teardown"        0 "$(grep -c . "$DOWN_CALLS")"
ok "B12: ...and the hold is rendered, not silent"    1 "$(printf '%s' "$b12" | grep -c 'HELD — finished and merged')"
ok "B12: ...naming the remedy as answering it"       1 "$(printf '%s' "$b12" | grep -c 'tears itself down on the next tick')"
ok "B12: ...and no teardown is claimed"              0 "$(printf '%s' "$b12" | grep -c 'TORN DOWN — merged, finished')"
# ...and the control: the SAME slot with the record answered IS torn down, so the hold is what
# the escalation does and not some other property of the fixture.
printf '{"kind":"question","status":"answered","slot":"71","text":"migrate or defer?"}\n' \
  >"$B_GIT/ship-escalations/71-1.json"
b_reset
b_tick -- 71 >/dev/null
b_tick -- 71 >/dev/null
ok "B12: ...while an ANSWERED one does not hold it"  1 "$(grep -c '^71$' "$DOWN_CALLS")"

# --- B13: an UNREADABLE record must hold too, and the hold must not be silenceable ----------
# AGENTS.md: untrusted evidence may annotate an operator-facing signal, never suppress one.
# `slot_pending`'s jq prints an empty string for a truncated or non-JSON record (measured), so the
# esc column reads 0 — and `shipyard-ask.sh` is what writes that record, so a child killed
# mid-write can silence its own protection and be destroyed while its question is open. The hold
# therefore reads `slot_unsettled`, which fails closed. Two halves, because the rule is per OUTPUT:
# the teardown must not happen, AND the operator must be told on every tick it is held, not once.
b_reset
b_slot 72 872 ready-to-merge
printf '1 ship-72\n' >"$B_WINS"; printf 'ship-72\n' >"$B_ENUM"
printf '872\tMERGED\n' >"$B_STATES"
printf '{"kind":"question","status":"pending"' >"$B_GIT/ship-escalations/72-1.json"   # truncated
b13a=$(b_tick -- 72)
b13b=$(b_tick -- 72)
ok "B13: an unreadable record holds the teardown"    0 "$(grep -c . "$DOWN_CALLS")"
ok "B13: ...and says so"                             1 "$(printf '%s' "$b13b" | grep -c 'HELD — finished and merged')"
# The esc column genuinely reads 0 here — that is the defect being guarded against, and the block
# explains the discrepancy rather than hiding it. Asserting it keeps the two counts from being
# quietly unified later, which would reopen the hole.
ok "B13: ...while the esc column still reads none"   1 "$(printf '%s' "$b13b" | grep -c '^| 72 .*| — | — |')"
ok "B13: ...and the block explains the difference"   1 "$(printf '%s' "$b13b" | grep -c 'could not parse counts here')"

# --- B14: the hold survives --only-changed silence ------------------------------------------
# The per-slot signature is partly built from values the child writes, so leaving the hold to it
# would let the supervised party decide whether the supervisor is told. A held slot must break the
# silence on EVERY tick, like STALLED — news once is not enough for a state that needs an action.
b_reset
b_slot 73 873 ready-to-merge
printf '1 ship-73\n' >"$B_WINS"; printf 'ship-73\n' >"$B_ENUM"
printf '873\tMERGED\n' >"$B_STATES"
printf '{"kind":"question","status":"pending"}\n' >"$B_GIT/ship-escalations/73-1.json"
b_tick -- --only-changed 73 >/dev/null
b_tick -- --only-changed 73 >/dev/null
b14=$(b_tick -- --only-changed 73)
ok "B14: a held slot breaks --only-changed silence every tick" 1 \
   "$(printf '%s' "$b14" | grep -c 'HELD — finished and merged')"
ok "B14: ...and still tears nothing down"            0 "$(grep -c . "$DOWN_CALLS")"

printf '\n%s: %d checks, %d failures\n' "$(basename "$0")" "$CHECKS" "$FAILURES"
[ "$FAILURES" -eq 0 ]
