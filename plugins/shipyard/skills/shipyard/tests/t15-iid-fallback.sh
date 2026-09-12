#!/usr/bin/env bash
# t15-iid-fallback.sh — the PR/MR column when ship's state file cannot answer (#124).
#
# PROVENANCE. `slot_iid()` read the number from `.pipeline-state/*.json` and from nowhere else, and
# three consecutive children wrote no state file at all. The column therefore read `no MR yet`, and
# the stage `—`, from launch to merge over open, reviewed, mergeable pull requests — for a whole
# day of supervision, which was spent reading panes and querying the forge by hand instead. The
# fallback asks the forge which PR/MR has the slot worktree's branch as its head, which needs no
# cooperation from the child.
#
# WHAT THIS FILE PINS, and every case is a kill test for one line:
#   1. a slot with NO state file gets its number from the forge;
#   2. the forge is the LAST resort — a slot whose state file answers never reaches it, so the
#      fallback cannot override a child that did its job, and costs no call when it did;
#   3. the base branch is never asked about, and neither is a worktree that has not branched yet;
#   4. only a NUMBER is an answer. An unauthenticated or misdirected CLI prints prose on stdout,
#      and an iid of `error: …` would be carried into mr_state() and rendered as a PR that is not
#      there — the failure being fixed, in a new disguise;
#   5. the query asks for a PR/MR in ANY state. `--state all` is not a detail: a merged PR whose
#      terminal is still up must keep its number, or the column blanks at the exact moment the
#      slot graph needs `merged` to conclude. Review measured `--state open` shipping 9/9 green
#      here before this case existed, which is #124's own disguise reinstated by one word.
#
# The rig is t13-wait.sh's: exported shell functions shadow `git`, `tmux` and `gh`, which works
# where a fake binary on PATH does not because shipyard-lib.sh prepends the system PATH over
# anything a test puts in front. Cost: the report sleeps 3s per slot for its motion diff, so one
# five-slot run is ~15s — which is why this suite is in `make test`, not the per-commit gate.
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
for s in 51 52 53 54 55; do mkdir -p "$FAKE_ROOT/.claude/worktrees/ship-$s/.pipeline-state"; done
printf '{"pr_number":902,"state":"impl-review"}\n' \
  >"$FAKE_ROOT/.claude/worktrees/ship-52/.pipeline-state/PR-902.json"
export FAKE_ROOT FAKE_GIT GH_CALLS

git() {
  local dir=""
  if [ "${1:-}" = "-C" ]; then dir="$2"; shift 2; fi
  case "$*" in
    "rev-parse --show-toplevel")  printf '%s\n' "$FAKE_ROOT"; return 0 ;;
    "rev-parse --git-common-dir") printf '%s\n' "$FAKE_GIT";  return 0 ;;
    "remote get-url origin")      printf 'https://github.com/example/example.git\n'; return 0 ;;
    "symbolic-ref --quiet --short refs/remotes/origin/HEAD") printf 'origin/main\n'; return 0 ;;
    "rev-parse --abbrev-ref HEAD")
      case "$dir" in
        *ship-51) printf 'feat/alpha\n' ;;
        *ship-52) printf 'feat/bravo\n' ;;
        *ship-53) printf 'main\n' ;;        # the base branch itself
        *ship-54) printf 'feat/delta\n' ;;
        *)        printf 'HEAD\n' ;;        # slot 55: a worktree that has not branched yet
      esac
      return 0 ;;
  esac
  return 0
}

tmux() {
  case "${1:-}" in
    list-windows) printf '1 ship-51\n2 ship-52\n3 ship-53\n4 ship-54\n5 ship-55\n'; return 0 ;;
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
        *"--head feat/alpha"*) out='[{"number":777}]' ;;
        *"--head feat/bravo"*) out='[{"number":999}]' ;;
        # A real CLI that cannot authenticate or is pointed at the wrong repository answers with
        # prose, not a number. Shaped as JSON so it survives the --jq the caller really runs.
        *"--head feat/delta"*) out='[{"number":"error: could not resolve to a Repository"}]' ;;
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
out=$(SHIPYARD_STALL_SECS=100000 SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t15ex \
        bash "$REPORT" 51 52 53 54 55 2>/dev/null)

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

# 6 — the flags themselves. The call log holds the whole argv, so the three that carry meaning are
# pinned here rather than left to the fake, which answers on `--head` alone and would keep
# reporting green through a silent change to any of them.
#
# Each asserts that NO logged call LACKS the flag, rather than counting the calls that carry it:
# the number of queries this rig makes is an artefact of how many slots reach the forge, so a
# count would have to be re-tuned every time a case is added and would pass for the wrong reason
# if one call quietly stopped happening.
ok "every query asks for a PR in ANY state"         0 \
   "$(grep -v -- '--state all' "$GH_CALLS" | grep -c .)"
ok "...and for the number field"                    0 \
   "$(grep -v -- '--json number' "$GH_CALLS" | grep -c .)"
ok "...and takes only the first"                    0 \
   "$(grep -v -- '--limit 1' "$GH_CALLS" | grep -c .)"
# ...and the log is non-empty, so the three checks above cannot pass vacuously over no calls.
ok "the log they read is not empty"                 2 \
   "$(grep -c . "$GH_CALLS")"

unset -f git tmux gh
if [ "$FAILURES" -eq 0 ]; then
  printf 't15-iid-fallback: %d checks, all passed\n' "$CHECKS"; exit 0
fi
printf 't15-iid-fallback: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"; exit 1
