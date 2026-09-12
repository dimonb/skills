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
#   3. the base branch is never asked about;
#   4. only a NUMBER is an answer. An unauthenticated or misdirected CLI prints prose on stdout,
#      and an iid of `error: …` would be carried into mr_state() and rendered as a PR that is not
#      there — the failure being fixed, in a new disguise.
#
# The rig is t13-wait.sh's: exported shell functions shadow `git`, `tmux` and `gh`, which works
# where a fake binary on PATH does not because shipyard-lib.sh prepends the system PATH over
# anything a test puts in front. Cost: the report sleeps 3s per slot for its motion diff, so one
# four-slot run is ~12s — which is why this suite is in `make test`, not the per-commit gate.
#
# WHAT A GREEN RUN DOES NOT PROVE, stated so it is not read as more than it is. The `gh` fake
# honours `--jq` by piping its canned JSON through real jq, so the filter in shipyard-report.sh is
# genuinely exercised — but nothing here proves the `--json`/`--state`/`--limit` flags are spelled
# the way the real CLI wants them, and nothing here calls a real forge. A flag typo ships green.
# The GitLab branch of the fallback is not exercised at all: this rig is GitHub-only, because the
# forge is derived from the origin remote and one report run cannot be both.
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

# 51: no state file, on its own branch        -> the forge answers 777.
# 52: a state file that answers 902           -> the forge is never asked.
# 53: no state file, sitting on the base branch -> nothing to ask about.
# 54: no state file, and a CLI answering prose -> no number, so no iid.
for s in 51 52 53 54; do mkdir -p "$FAKE_ROOT/.claude/worktrees/ship-$s/.pipeline-state"; done
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
        *)        printf 'HEAD\n' ;;        # a worktree that has not branched yet
      esac
      return 0 ;;
  esac
  return 0
}

tmux() {
  case "${1:-}" in
    list-windows) printf '1 ship-51\n2 ship-52\n3 ship-53\n4 ship-54\n'; return 0 ;;
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
        bash "$REPORT" 51 52 53 54 2>/dev/null)

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

unset -f git tmux gh
if [ "$FAILURES" -eq 0 ]; then
  printf 't15-iid-fallback: %d checks, all passed\n' "$CHECKS"; exit 0
fi
printf 't15-iid-fallback: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"; exit 1
