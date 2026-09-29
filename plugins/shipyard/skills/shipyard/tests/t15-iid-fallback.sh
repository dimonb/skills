#!/usr/bin/env bash
# t15-iid-fallback.sh — the PR/MR column when ship's state file cannot answer (#124).
#
# PROVENANCE. `slot_iid()` read the number from `.pipeline-state/*.json` and from nowhere else, and
# children write that file late or not at all: one slot read `no MR yet` over a PR that had been
# open for more than an hour with two completed review rounds, and another wrote the file only once
# its PR already existed. The column, and the stage beside it, were therefore blank across exactly
# the part of a run where supervision matters — a day of it spent reading panes and querying the
# forge by hand instead. The fallback asks the forge which PR/MR has the slot worktree's branch as
# its head, which needs no cooperation from the child.
#
# WHAT THIS FILE PINS, and every case is a kill test for one line:
#   1. a slot with NO state file gets its number from the forge;
#   2. the forge is the LAST resort — a slot whose state file answers never reaches it, so the
#      fallback cannot override a child that did its job, and costs no call when it did;
#   3. the base branch is never asked about, and neither is a worktree that has not branched yet;
#   4. only a NUMBER is an answer — tested on the forge arm, though the guard itself sits at
#      slot_iid()'s single exit so it covers the hand-authored state file and the MR-*.json
#      basename too. An iid of `error: …` would be carried into mr_state() and rendered as a PR
#      that is not there, and being non-empty it satisfies the slot graph's `_syg_pr_known` —
#      the failure being fixed, in a new disguise. NOTE what this case does NOT evidence: the
#      fixture puts prose inside valid JSON, in the `number` field, which is a belief about how a
#      CLI fails rather than an observation. A real `gh` that cannot authenticate writes to
#      stderr and exits non-zero with empty stdout, which the `''` arm would catch anyway;
#   4b. an unregistered directory under `.claude/worktrees/` is not a worktree. The only case
#      here whose failure is a WRONG answer rather than a blank: git discovery walks up and
#      returns the supervisor's own branch, so the slot would render the supervisor's own PR;
#   5. the query asks for a PR/MR in ANY state. `--state all` is not a detail: a merged PR whose
#      terminal is still up must keep its number, or the column blanks at the exact moment the
#      slot graph needs `merged` to conclude. Review measured `--state open` shipping 9/9 green
#      here before this case existed, which is #124's own disguise reinstated by one word.
#   6. (#143) the base branch comes from shipyard_default_ref, and its "cannot say" (rc 1) means
#      the forge is NOT asked — an empty base used to mean "nothing to exclude";
#   7. (#143) the branch name is not the child: a MERGED/CLOSED candidate must have this
#      worktree's HEAD as its head (a relaunch on a reused name keeps its old PR's number off the
#      row even when that head is an ancestor), an OPEN one must be HEAD or an ancestor of it and
#      wins over any other, and a fork's same-named branch is never a candidate;
#   8. (#143) a forge CLI that hangs is killed at SHIPYARD_FORGE_TIMEOUT and the report still
#      renders, rather than withholding the tick;
#   9. (#143) a slot with no terminal costs no forge call — unless its stage says the teardown may
#      be due, where lock 1 needs the forge's answer.
#
# The rig is t13-wait.sh's: exported shell functions shadow `git`, `tmux` and `gh`, which works
# where a fake binary on PATH does not because shipyard-lib.sh prepends the system PATH over
# anything a test puts in front. Cost: the report sleeps once per slot for its motion diff, which
# in production is three seconds and made this six-slot run eighteen of its nineteen measured
# seconds. The run below sets SHIPYARD_MOTION_INTERVAL (#203) and says there why that changes no
# answer here. The suite is still in `make test` rather than the per-commit gate.
#
# WHAT A GREEN RUN DOES NOT PROVE, stated so it is not read as more than it is. The `gh` fake
# honours `--jq` by piping its canned JSON through real jq, so the filter in shipyard-report.sh is
# genuinely exercised — but nothing here proves the `--json`/`--state`/`--limit` flags are spelled
# the way the real CLI wants them, and nothing here calls a real forge. A flag typo ships green.
# The GitLab branch of the fallback is not exercised at all: this rig is GitHub-only, because the
# forge is derived from the origin remote and one report run cannot be both. That gap covers the
# `glab mr list --source-branch` call AND the `return` slot_iid()'s GitLab shortcut now needs —
# without it a numeric GitLab slot would print the slot and then fall through, concatenating two
# numbers into an iid that is neither. Delete that `return` and every suite here stays green.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$DIR/.." && pwd)"
REPORT="$SKILL_DIR/shipyard-report.sh"
# shellcheck source=../shipyard-lib.sh
. "$SKILL_DIR/shipyard-lib.sh"

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}

T15TMP=$(mktemp -d "${TMPDIR:-/tmp}/t15-iid.XXXXXXXX") || exit 1
trap 'rm -rf "$T15TMP"' EXIT
FAKE_ROOT="$T15TMP/repo"; FAKE_GIT="$T15TMP/gitdir"; GH_CALLS="$T15TMP/gh-calls"
mkdir -p "$FAKE_ROOT" "$FAKE_GIT/ship-escalations"
: > "$GH_CALLS"

# 51: no state file, on its own branch          -> the forge answers 777.
# 52: a state file that answers 902             -> the forge is never asked.
# 53: no state file, sitting on the base branch -> nothing to ask about.
# 54: no state file, and a CLI answering prose  -> no number, so no iid.
# 55: no state file, detached HEAD (never branched) -> nothing to ask about either. This slot
#     exists because the fake's fallback arm below is otherwise UNREACHABLE: every other slot
#     matches an explicit arm, so a `*) printf 'HEAD'` fixture commented as if it covered the
#     detached case would have covered nothing, and deleting the guard it stands for shipped
#     green. A fixture that reads as coverage and is not is worse than an admitted gap.
# 56: a DIRECTORY that is not a registered worktree -> the one case whose failure is a wrong
#     answer rather than a blank. Git discovery walks up, so `rev-parse` there returns the
#     SUPERVISOR's branch; this fixture gives that branch a PR (555) so a regression renders the
#     supervisor's own change as the slot's instead of merely blanking the column.
# 57: no base branch resolvable at all (no origin/HEAD, no usable upstream, no origin/main|master)
#     -> the forge is not asked. The old guard read that empty answer as "nothing to exclude".
# 58: a relaunch on a REUSED branch name: the only candidate is MERGED with a head that is an
#     ancestor of HEAD but not HEAD -> not this child's PR, so no number. The kept-branch restart
#     path; an ancestry test alone would admit it and paint the old `merged` over a live child.
# 59: a FORK's open PR on the same branch name, listed first, then the child's own MERGED PR whose
#     head is HEAD -> the fork is dropped and the child's merged PR keeps its number.
# 60: a MERGED candidate on HEAD listed first, then an OPEN one whose head is an ancestor of HEAD
#     -> the OPEN one wins.
# 61: an OPEN candidate whose head is NOT in this worktree's history -> rejected.
# 62: the CLI hangs -> killed at SHIPYARD_FORGE_TIMEOUT, no number, and the report still renders.
# 63: no terminal, no stage -> the forge is never asked about its branch.
# 64: no terminal, stage `done`, no number in the state file -> the teardown arm does ask.
for s in 51 52 53 54 55 56 57 58 59 60 61 62 63 64; do mkdir -p "$FAKE_ROOT/.claude/worktrees/ship-$s/.pipeline-state"; done
# The registered set: every slot EXCEPT 56. Physical paths, because the guard compares against
# `pwd -P` and $TMPDIR is a symlink on macOS — a logical path here would make the guard reject
# every slot and the suite would pass for the wrong reason (measured: it reds 4 checks).
WT_LIST=""
for s in 51 52 53 54 55 57 58 59 60 61 62 63 64; do
  p=$(cd "$FAKE_ROOT/.claude/worktrees/ship-$s" && pwd -P)
  WT_LIST="${WT_LIST}worktree $p
"
done
printf '{"pr_number":902,"state":"impl-review"}\n' \
  >"$FAKE_ROOT/.claude/worktrees/ship-52/.pipeline-state/PR-902.json"
printf '{"state":"done"}\n' >"$FAKE_ROOT/.claude/worktrees/ship-64/.pipeline-state/ISSUE-64.json"
export FAKE_ROOT FAKE_GIT GH_CALLS WT_LIST

git() {
  local dir=""
  if [ "${1:-}" = "-C" ]; then dir="$2"; shift 2; fi
  # Slot 57's repository can name no base branch: every tier of shipyard_default_ref fails there.
  case "$dir:$*" in
    *ship-57:"symbolic-ref --quiet --short refs/remotes/origin/HEAD") return 1 ;;
    *ship-57:"symbolic-ref --quiet --short HEAD") printf 'feat/golf\n'; return 0 ;;
    *ship-57:"rev-parse --abbrev-ref @{upstream}") return 128 ;;
    # Only the resolver's ref probes fail. HEAD still resolves, so the resolver is the one thing
    # standing between this slot and a query: a HEAD lookup failing too would mask its removal.
    *ship-57:"rev-parse --verify --quiet "*"^{commit}") return 1 ;;
  esac
  case "$*" in
    # Every worktree's HEAD is `h<slot>`, which is what a candidate's head is compared against.
    "rev-parse --verify --quiet HEAD") printf 'h%s\n' "${dir##*ship-}"; return 0 ;;
    # Ancestry, as the fixtures below need it: `anc-*` heads are in the history, anything else not.
    "merge-base --is-ancestor "*)
      case "$3" in anc-*) return 0 ;; *) return 1 ;; esac ;;
    "rev-parse --show-toplevel")  printf '%s\n' "$FAKE_ROOT"; return 0 ;;
    "rev-parse --git-common-dir") printf '%s\n' "$FAKE_GIT";  return 0 ;;
    "remote get-url origin")      printf 'https://github.com/example/example.git\n'; return 0 ;;
    "symbolic-ref --quiet --short refs/remotes/origin/HEAD") printf 'origin/main\n'; return 0 ;;
    "worktree list --porcelain")  printf '%s' "$WT_LIST"; return 0 ;;
    "rev-parse --abbrev-ref HEAD")
      case "$dir" in
        *ship-51) printf 'feat/alpha\n' ;;
        *ship-52) printf 'feat/bravo\n' ;;
        *ship-53) printf 'main\n' ;;        # the base branch itself
        *ship-54) printf 'feat/delta\n' ;;
        *ship-55) printf 'HEAD\n' ;;        # a worktree that has not branched yet
        *ship-57) printf 'feat/golf\n' ;;
        *ship-58) printf 'feat/hotel\n' ;;
        *ship-59) printf 'feat/india\n' ;;
        *ship-60) printf 'feat/juliet\n' ;;
        *ship-61) printf 'feat/kilo\n' ;;
        *ship-62) printf 'feat/lima\n' ;;
        *ship-63) printf 'feat/mike\n' ;;
        *ship-64) printf 'feat/november\n' ;;
        # Slot 56 and anything else: git walked UP and answered with the SUPERVISOR's branch,
        # which is what a stray directory really produces. Never reached if the guard holds.
        *)        printf 'feat/supervisors-own-branch\n' ;;
      esac
      return 0 ;;
  esac
  return 0
}

tmux() {
  case "${1:-}" in
    # 63 and 64 have no terminal.
    list-windows) printf '1 ship-51\n2 ship-52\n3 ship-53\n4 ship-54\n5 ship-55\n6 ship-56\n7 ship-57\n8 ship-58\n9 ship-59\n10 ship-60\n11 ship-61\n12 ship-62\n'; return 0 ;;
    has-session)  return 0 ;;
    capture-pane) printf '⏺ working\n'; return 0 ;;
  esac
  return 0
}

# Records every `pr list` it is asked for, so the two "never asked" cases are provable rather than
# inferred from an absent number — a lookup that was made and came back empty looks identical in
# the table, and it is the CALL this change must not make.
gh() {
  local a filter="" want=0 out=""
  for a in "$@"; do
    if [ "$want" = 1 ]; then filter="$a"; want=0; continue; fi
    [ "$a" = "--jq" ] && want=1
  done
  case "$*" in
    *"pr list"*)
      printf '%s\n' "$*" >>"$GH_CALLS"
      case "$*" in
        *"--head feat/alpha"*) out='[{"number":777,"state":"OPEN","headRefOid":"h51","isCrossRepository":false}]' ;;
        *"--head feat/bravo"*) out='[{"number":999,"state":"OPEN","headRefOid":"h52","isCrossRepository":false}]' ;;
        # A real CLI that cannot authenticate or is pointed at the wrong repository answers with
        # prose, not a number. Shaped as JSON so it survives the --jq the caller really runs.
        *"--head feat/delta"*) out='[{"number":"error: could not resolve to a Repository","state":"OPEN","headRefOid":"h54","isCrossRepository":false}]' ;;
        # The supervisor's own branch HAS a PR. That is what makes slot 56 a wrong-answer test
        # rather than a blank-column one: without the registration guard the row renders `!555`.
        *"--head feat/supervisors-own-branch"*) out='[{"number":555,"state":"OPEN","headRefOid":"h56","isCrossRepository":false}]' ;;
        *"--head feat/golf"*) out='[{"number":571,"state":"OPEN","headRefOid":"h57","isCrossRepository":false}]' ;;
        *"--head feat/hotel"*) out='[{"number":581,"state":"MERGED","headRefOid":"anc-old","isCrossRepository":false}]' ;;
        *"--head feat/india"*) out='[{"number":591,"state":"OPEN","headRefOid":"h59","isCrossRepository":true},{"number":592,"state":"MERGED","headRefOid":"h59","isCrossRepository":false}]' ;;
        *"--head feat/juliet"*) out='[{"number":601,"state":"MERGED","headRefOid":"h60","isCrossRepository":false},{"number":602,"state":"OPEN","headRefOid":"anc-60","isCrossRepository":false}]' ;;
        *"--head feat/kilo"*) out='[{"number":611,"state":"OPEN","headRefOid":"elsewhere","isCrossRepository":false}]' ;;
        # A hung CLI. Its sleep does not hold stdout: a real hung `gh` is ONE process, which the
        # TERM kills with its pipe; a fake's child would outlive the killed function and keep the
        # caller's $( ) open, which tests the fixture rather than the report.
        *"--head feat/lima"*) sleep 60 </dev/null >/dev/null 2>&1; out='[{"number":621,"state":"OPEN","headRefOid":"h62","isCrossRepository":false}]' ;;
        *"--head feat/mike"*) out='[{"number":631,"state":"OPEN","headRefOid":"h63","isCrossRepository":false}]' ;;
        *"--head feat/november"*) out='[{"number":641,"state":"MERGED","headRefOid":"h64","isCrossRepository":false}]' ;;
        *) out='[]' ;;
      esac ;;
    *"pr view"*) printf 'OPEN\n'; return 0 ;;
    *) return 0 ;;
  esac
  if [ -n "$filter" ]; then printf '%s' "$out" | jq -r "$filter" 2>/dev/null
  else printf '%s\n' "$out"; fi
}
export -f git tmux gh

printf '%s\n' "$(date +%s)" >"$FAKE_GIT/ship-escalations/report-tick"
# SHIPYARD_MOTION_INTERVAL: six slots, and the report waits between two captures for each one —
# eighteen seconds of a nineteen-second file. The faked `capture-pane` above returns a fixed
# string, so both captures are identical at any interval and nothing below reads the ▶️/⏸
# column; production's three-second default is untouched (#203).
# SHIPYARD_FORGE_TIMEOUT: slot 62's fake hangs for sixty seconds, so the report finishing well
# inside that is what proves the call was killed. SHIPYARD_AUTODOWN=0: slot 64 reaches the teardown
# arm, and this file asks what that arm QUERIES, never what it removes.
t0=$(date +%s)
out=$(SHIPYARD_MOTION_INTERVAL="${SHIPYARD_MOTION_INTERVAL:-0.01}" SHIPYARD_STALL_SECS=100000 SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t15ex \
        SHIPYARD_FORGE_TIMEOUT=2 SHIPYARD_AUTODOWN=0 \
        bash "$REPORT" 51 52 53 54 55 56 57 58 59 60 61 62 63 64 2>/dev/null)
elapsed=$(( $(date +%s) - t0 ))

# 1 — the whole point: a child that wrote nothing still gets its PR number.
ok "51: the forge supplies the number no state file held" 1 \
   "$(printf '%s' "$out" | grep -c '^| 51 | !777 |')"
ok "51: ...and the forge state is then resolvable too"    1 \
   "$(printf '%s' "$out" | grep -c '^| 51 .*opened /')"

# 2 — last resort. The state file wins, and the call is not even made: if the fallback ran here it
# would answer 999, so the number alone proves the precedence and the log proves the cost.
ok "52: the state file still wins"                  1 \
   "$(printf '%s' "$out" | grep -c '^| 52 | !902 |')"
ok "52: ...and the forge was never asked"           0 \
   "$(grep -c -- '--head feat/bravo' "$GH_CALLS")"

# 3 — the base branch is not a question. A slot whose worktree never branched sits on it, and
# asking "which PR has main as its head" invites an answer about somebody else's change.
ok "53: the base branch is never asked about"       0 \
   "$(grep -c -- '--head main' "$GH_CALLS")"
ok "53: ...so the column says so honestly"          1 \
   "$(printf '%s' "$out" | grep -c '^| 53 | — .*no MR yet')"

# 4 — only a number is an answer.
ok "54: the forge WAS asked"                        1 \
   "$(grep -c -- '--head feat/delta' "$GH_CALLS")"
ok "54: ...and prose is not taken for an iid"       1 \
   "$(printf '%s' "$out" | grep -c '^| 54 | — .*no MR yet')"
ok "54: ...with no error text rendered as a PR"     0 \
   "$(printf '%s' "$out" | grep -c 'could not resolve to a Repository')"

# 5 — a worktree that has not branched yet. `rev-parse --abbrev-ref HEAD` answers the literal
# `HEAD` when detached, and `--head HEAD` is a question with no useful answer asked once per tick.
ok "55: a detached HEAD is never asked about"       0 \
   "$(grep -c -- '--head HEAD' "$GH_CALLS")"
ok "55: ...and the column says so honestly"         1 \
   "$(printf '%s' "$out" | grep -c '^| 55 | — .*no MR yet')"

# 6 — a directory under .claude/worktrees/ that git never registered. The ONLY case here whose
# failure is a wrong answer rather than a blank column, so it is asserted three ways.
ok "56: an unregistered directory is never asked about" 0 \
   "$(grep -c -- '--head feat/supervisors-own-branch' "$GH_CALLS")"
ok "56: ...so the supervisor's own PR is not shown as the slot's" 0 \
   "$(printf '%s' "$out" | grep -c '^| 56 | !555 |')"
ok "56: ...and the column says so honestly"         1 \
   "$(printf '%s' "$out" | grep -c '^| 56 | — .*no MR yet')"

# 8 — #143: no base branch means no question, rather than an unguarded one.
ok "57: an unresolvable base branch means the forge is not asked" 0 \
   "$(grep -c -- '--head feat/golf' "$GH_CALLS")"
ok "57: ...and the column says so honestly"         1 \
   "$(printf '%s' "$out" | grep -c '^| 57 | — .*no MR yet')"

# 9 — #143: the branch name is not the child.
ok "58: a merged PR whose head is only an ANCESTOR of HEAD is not this child's" 1 \
   "$(printf '%s' "$out" | grep -c '^| 58 | — .*no MR yet')"
ok "59: a fork's same-named PR is dropped"          0 \
   "$(printf '%s' "$out" | grep -c '^| 59 | !591 |')"
ok "59: ...and the child's own merged PR on HEAD keeps its number" 1 \
   "$(printf '%s' "$out" | grep -c '^| 59 | !592 |')"
ok "60: an open candidate wins over a merged one"   1 \
   "$(printf '%s' "$out" | grep -c '^| 60 | !602 |')"
ok "61: an open PR outside this worktree's history is rejected" 1 \
   "$(printf '%s' "$out" | grep -c '^| 61 | — .*no MR yet')"

# 10 — #143: a hung CLI costs its deadline, not the tick.
ok "62: the hung call was made"                     1 \
   "$(grep -c -- '--head feat/lima' "$GH_CALLS")"
ok "62: ...killed, so the report finished long before the fake's 60s" 1 \
   "$([ "$elapsed" -lt 30 ] && echo 1 || echo 0)"
ok "62: ...and its row still rendered, blank"       1 \
   "$(printf '%s' "$out" | grep -c '^| 62 | — .*no MR yet')"

# 11 — #143: a slot with no terminal is not charged a forge call...
ok "63: a gone slot is never asked about"           0 \
   "$(grep -c -- '--head feat/mike' "$GH_CALLS")"
ok "63: ...and still renders its row"               1 \
   "$(printf '%s' "$out" | grep -c '^| 63 | — | — | ⛔ no terminal')"
# ...unless its stage says the teardown may be due, where lock 1 needs `merged`.
ok "64: a gone slot at a terminal stage IS asked"   1 \
   "$(grep -c -- '--head feat/november' "$GH_CALLS")"
ok "64: ...and its row carries the number"          1 \
   "$(printf '%s' "$out" | grep -c '^| 64 | !641 |')"

# 7 — the flags themselves. The call log holds the whole argv, so the three that carry meaning are
# pinned here rather than left to the fake, which answers on `--head` alone and would keep
# reporting green through a silent change to any of them.
#
# Each asserts that NO logged call LACKS the flag, rather than counting the calls that carry it:
# the number of queries this rig makes is an artefact of how many slots reach the forge, so a
# count would have to be re-tuned every time a case is added and would pass for the wrong reason
# if one call quietly stopped happening.
ok "every query asks for a PR in ANY state"         0 \
   "$(grep -v -- '--state all' "$GH_CALLS" | grep -c .)"
ok "...and for the fields the choice among candidates reads" 0 \
   "$(grep -v -- '--json number,state,headRefOid,isCrossRepository' "$GH_CALLS" | grep -c .)"
ok "...and for several candidates, not one"         0 \
   "$(grep -v -- '--limit 10 ' "$GH_CALLS" | grep -c .)"
# ...and the log holds exactly the slots that should reach the forge — 51 54 58 59 60 61 62 64 —
# so the checks above cannot pass vacuously over no calls.
ok "the log they read holds the expected queries"   8 \
   "$(grep -c . "$GH_CALLS")"

unset -f git tmux gh
if [ "$FAILURES" -eq 0 ]; then
  printf 't15-iid-fallback: %d checks, all passed\n' "$CHECKS"; exit 0
fi
printf 't15-iid-fallback: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"; exit 1
