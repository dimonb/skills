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
#  10. (#317) a merged or closed candidate that stopped being open BEFORE the slot's launch record
#      says it was launched is not this child's — the kept-branch relaunch before its first
#      commit, whose HEAD is still the old PR's head — while no launch record skips that test;
#  11. (#317) a candidate that fails is shown as an ANNOTATION, `!N?`, and never reaches mr_state:
#      the head moved on the forge, the reused name and the relaunch all render the forge's number
#      marked unverified instead of a blank, and none of them can paint a live child finished;
#  12. (#317) the GitLab arm, in a second report run over a gitlab origin with a `glab` fake: a
#      fork is dropped, an open MR whose head is an ancestor wins, a merged one on HEAD keeps its
#      number, a merged one from before the launch is an annotation, and a numeric slot is its own
#      iid without a forge call.
#  13. (#329) the report runs clean under a real bash 3.2 over live slots that reach the forge
#      fallback, and renders the same rows as above; skipped, saying so, where no 3.2 exists.
#
# The rig is t13-wait.sh's: exported shell functions shadow `git`, `tmux`, `gh` and `glab`, which
# works where a fake binary on PATH does not because shipyard-lib.sh prepends the system PATH over
# anything a test puts in front. Cost: the report sleeps once per slot for its motion diff, which
# in production is three seconds and was once almost all of this file's measured time. The run
# below sets SHIPYARD_MOTION_INTERVAL (#203) and says there why that changes no
# answer here. The suite is still in `make test` rather than the per-commit gate.
#
# WHAT A GREEN RUN DOES NOT PROVE, stated so it is not read as more than it is. The `gh` fake
# honours `--jq` by piping its canned JSON through real jq, so the filter in shipyard-report.sh is
# genuinely exercised — but nothing here proves the `--json`/`--state`/`--limit` flags are spelled
# the way the real CLI wants them, and nothing here calls a real forge. A flag typo ships green.
# The `glab` fake's JSON carries the field names a real `glab mr list -F json` (1.90) returned
# when #317 ran one against a public project — `iid`, `state` in lower case, `sha`, the two project
# ids, `merged_at` with milliseconds and `closed_at` null on a merge — so the filter is exercised
# against that shape; a later glab that renames a field still ships green here. Real `gh`'s built-in
# jq is gojq, not the jq the fake pipes through; `try`, `sub` and `fromdateiso8601` were run on both.
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
#     ancestor of HEAD but not HEAD -> not this child's PR, so no iid, only the `!581?`
#     annotation. The kept-branch restart path; an ancestry test alone would admit it and paint
#     the old `merged` over a live child.
# 59: a FORK's open PR on the same branch name, listed first, then the child's own MERGED PR whose
#     head is HEAD and which merged AFTER the slot's launch record -> the fork is dropped and the
#     child's merged PR keeps its number.
# 60: a MERGED candidate on HEAD listed first, then an OPEN one whose head is an ancestor of HEAD
#     -> the OPEN one wins.
# 61: an OPEN candidate whose head is NOT in this worktree's history — a head moved on the forge
#     and never pulled -> no iid, only the `!611?` annotation.
# 62: the CLI hangs -> killed at SHIPYARD_FORGE_TIMEOUT, no number, and the report still renders.
# 63: no terminal, no stage -> the forge is never asked about its branch.
# 64: no terminal, stage `done`, no number in the state file -> the teardown arm does ask, and
#     with NO launch record the merge time is not tested, so its merged PR keeps its number.
# 65: a kept-branch relaunch before its first commit: the only candidate is MERGED on HEAD, and
#     it merged BEFORE the slot's launch record -> no iid, only the `!651?` annotation.
# 66: 65's shape on the GONE-slot teardown arm (no terminal, stage `done`) -> the same annotation,
#     so the arm that feeds lock 1 never takes an unverified number for `merged`.
# 67: a failing candidate listed FIRST (merged, head only an ancestor), then the child's own merged
#     PR on HEAD whose merge time is missing -> the verified one wins over the earlier hint, and a
#     time that cannot be read skips the launch test rather than failing it.
# 68: a CLOSED (not merged) PR on HEAD, closed before the launch -> the same annotation as a merge.
GH_SLOTS="51 52 53 54 55 56 57 58 59 60 61 62 63 64 65 66 67 68"
# The GitLab run's slots (header case 12; the `#317 — the GitLab arm` section below). Non-numeric
# but one, because a numeric GitLab slot IS its iid and never reaches the forge — which 71 pins.
#   gfork:   a fork's opened MR listed first, then the child's own merged one on HEAD -> the latter;
#   ganc:    a merged MR on HEAD, then an opened one whose head is an ancestor -> the opened one;
#   gold:    a merged MR on HEAD that merged before the launch record -> annotation only;
#   71:      numeric -> `!71`, and glab is never asked about its branch.
GL_SLOTS="gfork ganc gold 71"
for s in $GH_SLOTS $GL_SLOTS; do mkdir -p "$FAKE_ROOT/.claude/worktrees/ship-$s/.pipeline-state"; done
# The registered set: every slot EXCEPT 56. Physical paths, because the guard compares against
# `pwd -P` and $TMPDIR is a symlink on macOS — a logical path here would make the guard reject
# every slot and the suite would pass for the wrong reason (measured: it reds 4 checks).
WT_LIST=""
for s in $GH_SLOTS $GL_SLOTS; do
  [ "$s" = 56 ] && continue
  p=$(cd "$FAKE_ROOT/.claude/worktrees/ship-$s" && pwd -P)
  WT_LIST="${WT_LIST}worktree $p
"
done
printf '{"pr_number":902,"state":"impl-review"}\n' \
  >"$FAKE_ROOT/.claude/worktrees/ship-52/.pipeline-state/PR-902.json"
printf '{"state":"done"}\n' >"$FAKE_ROOT/.claude/worktrees/ship-64/.pipeline-state/ISSUE-64.json"
printf '{"state":"done"}\n' >"$FAKE_ROOT/.claude/worktrees/ship-66/.pipeline-state/ISSUE-66.json"
# Launch records, in the shape shipyard-launch.sh writes. Every merge time below is either
# 2026-01-01 (before a launch) or 2026-06-01 (after one); the launches are all 2026-03-01.
for s in 59 60 65 66 67 68 gfork ganc gold; do
  printf '{"id":"launch-%s","slot":"%s","kind":"launch","status":"info","started_at":"2026-03-01T00:00:00Z"}\n' "$s" "$s" \
    >"$FAKE_GIT/ship-escalations/launch-$s.json"
done
GH_VIEWS="$T15TMP/gh-views"; GLAB_CALLS="$T15TMP/glab-calls"; : > "$GH_VIEWS"; : > "$GLAB_CALLS"
FAKE_ORIGIN='https://github.com/example/example.git'
export FAKE_ROOT FAKE_GIT GH_CALLS GH_VIEWS GLAB_CALLS WT_LIST FAKE_ORIGIN

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
    "remote get-url origin")      printf '%s\n' "$FAKE_ORIGIN"; return 0 ;;
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
        *ship-65) printf 'feat/oscar\n' ;;
        *ship-66) printf 'feat/papa\n' ;;
        *ship-67) printf 'feat/quebec\n' ;;
        *ship-68) printf 'feat/romeo\n' ;;
        *ship-gfork) printf 'feat/gl-fork\n' ;;
        *ship-ganc)  printf 'feat/gl-anc\n' ;;
        *ship-gold)  printf 'feat/gl-old\n' ;;
        *ship-71)    printf 'feat/gl-numeric\n' ;;
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
    # 63, 64 and 66 have no terminal.
    list-windows) printf '1 ship-51\n2 ship-52\n3 ship-53\n4 ship-54\n5 ship-55\n6 ship-56\n7 ship-57\n8 ship-58\n9 ship-59\n10 ship-60\n11 ship-61\n12 ship-62\n13 ship-65\n14 ship-gfork\n15 ship-ganc\n16 ship-gold\n17 ship-71\n18 ship-67\n19 ship-68\n'; return 0 ;;
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
      # One line per call: the report's --jq filter spans several lines.
      a="$*"; printf '%s\n' "${a//$'\n'/ }" >>"$GH_CALLS"
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
        *"--head feat/hotel"*) out='[{"number":581,"state":"MERGED","headRefOid":"anc-old","isCrossRepository":false,"closedAt":"2026-06-01T00:00:00Z"}]' ;;
        *"--head feat/india"*) out='[{"number":591,"state":"OPEN","headRefOid":"h59","isCrossRepository":true,"closedAt":null},{"number":592,"state":"MERGED","headRefOid":"h59","isCrossRepository":false,"closedAt":"2026-06-01T00:00:00Z"}]' ;;
        *"--head feat/juliet"*) out='[{"number":601,"state":"MERGED","headRefOid":"h60","isCrossRepository":false,"closedAt":"2026-06-01T00:00:00Z"},{"number":602,"state":"OPEN","headRefOid":"anc-60","isCrossRepository":false,"closedAt":null}]' ;;
        *"--head feat/kilo"*) out='[{"number":611,"state":"OPEN","headRefOid":"elsewhere","isCrossRepository":false}]' ;;
        # A hung CLI. Its sleep does not hold stdout: a real hung `gh` is ONE process, which the
        # TERM kills with its pipe; a fake's child would outlive the killed function and keep the
        # caller's $( ) open, which tests the fixture rather than the report.
        *"--head feat/lima"*) sleep 60 </dev/null >/dev/null 2>&1; out='[{"number":621,"state":"OPEN","headRefOid":"h62","isCrossRepository":false}]' ;;
        *"--head feat/mike"*) out='[{"number":631,"state":"OPEN","headRefOid":"h63","isCrossRepository":false}]' ;;
        *"--head feat/november"*) out='[{"number":641,"state":"MERGED","headRefOid":"h64","isCrossRepository":false,"closedAt":"2026-01-01T00:00:00Z"}]' ;;
        # Merged on HEAD, but before the slot's launch record: the kept-branch relaunch.
        *"--head feat/oscar"*) out='[{"number":651,"state":"MERGED","headRefOid":"h65","isCrossRepository":false,"closedAt":"2026-01-01T00:00:00Z"}]' ;;
        *"--head feat/papa"*) out='[{"number":661,"state":"MERGED","headRefOid":"h66","isCrossRepository":false,"closedAt":"2026-01-01T00:00:00Z"}]' ;;
        *"--head feat/quebec"*) out='[{"number":671,"state":"MERGED","headRefOid":"anc-67","isCrossRepository":false,"closedAt":"2026-06-01T00:00:00Z"},{"number":672,"state":"MERGED","headRefOid":"h67","isCrossRepository":false,"closedAt":null}]' ;;
        *"--head feat/romeo"*) out='[{"number":681,"state":"CLOSED","headRefOid":"h68","isCrossRepository":false,"closedAt":"2026-01-01T00:00:00Z"}]' ;;
        *) out='[]' ;;
      esac ;;
    # Logged, so an annotation reaching mr_state is provable: none may ever be asked about.
    *"pr view"*) printf '%s\n' "$*" >>"$GH_VIEWS"; printf 'OPEN\n'; return 0 ;;
    *) return 0 ;;
  esac
  if [ -n "$filter" ]; then printf '%s' "$out" | jq -r "$filter" 2>/dev/null
  else printf '%s\n' "$out"; fi
}

# The GitLab arm's fake. Its JSON is shaped as a real `glab mr list -F json` answered (see the
# header): lower-case state, `merged_at` with milliseconds, `closed_at` null on a merge. No `--jq`:
# the report pipes glab's stdout through real jq itself. `mr view` is logged like `pr view`.
glab() {
  case "$*" in
    *"mr list"*)
      printf '%s\n' "$*" >>"$GLAB_CALLS"
      case "$*" in
        *"--source-branch feat/gl-fork "*) printf '%s\n' '[{"iid":811,"state":"opened","sha":"hgfork","source_project_id":2,"target_project_id":1,"merged_at":null,"closed_at":null},{"iid":812,"state":"merged","sha":"hgfork","source_project_id":1,"target_project_id":1,"merged_at":"2026-06-01T00:00:00.213Z","closed_at":null}]' ;;
        *"--source-branch feat/gl-anc "*) printf '%s\n' '[{"iid":821,"state":"merged","sha":"hganc","source_project_id":1,"target_project_id":1,"merged_at":"2026-06-01T00:00:00.213Z","closed_at":null},{"iid":822,"state":"opened","sha":"anc-ganc","source_project_id":1,"target_project_id":1,"merged_at":null,"closed_at":null}]' ;;
        *"--source-branch feat/gl-old "*) printf '%s\n' '[{"iid":831,"state":"merged","sha":"hgold","source_project_id":1,"target_project_id":1,"merged_at":"2026-01-01T00:00:00.213Z","closed_at":null}]' ;;
        *"--source-branch feat/gl-numeric "*) printf '%s\n' '[{"iid":841,"state":"opened","sha":"h71","source_project_id":1,"target_project_id":1,"merged_at":null,"closed_at":null}]' ;;
        *) printf '[]\n' ;;
      esac ;;
    *"mr view"*) printf '%s\n' "$*" >>"$GH_VIEWS"; printf '{"state":"opened"}\n' ;;
  esac
  return 0
}
export -f git tmux gh glab

printf '%s\n' "$(date +%s)" >"$FAKE_GIT/ship-escalations/report-tick"
# SHIPYARD_MOTION_INTERVAL: the report waits between two captures for every live slot, which at the
# production interval was almost all of this file's time. The faked `capture-pane` above returns a fixed
# string, so both captures are identical at any interval and nothing below reads the ▶️/⏸
# column; production's three-second default is untouched (#203).
# SHIPYARD_FORGE_TIMEOUT: slot 62's fake hangs for sixty seconds, so the report finishing well
# inside that is what proves the call was killed. SHIPYARD_AUTODOWN=0: slot 64 reaches the teardown
# arm, and this file asks what that arm QUERIES, never what it removes.
t0=$(date +%s)
out=$(SHIPYARD_MOTION_INTERVAL="${SHIPYARD_MOTION_INTERVAL:-0.01}" SHIPYARD_STALL_SECS=100000 SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t15ex \
        SHIPYARD_FORGE_TIMEOUT=2 SHIPYARD_AUTODOWN=0 \
        bash "$REPORT" $GH_SLOTS 2>/dev/null)
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
# 58 and 61 fail every rule, so each is the forge's number marked unverified, `!N?`, over a state
# of `no MR yet`: mr_state was not asked, which the `pr view` log below proves for all three.
ok "58: a merged PR whose head is only an ANCESTOR of HEAD is not this child's" 1 \
   "$(printf '%s' "$out" | grep -c '^| 58 | !581? | .*no MR yet')"
ok "59: a fork's same-named PR is dropped"          0 \
   "$(printf '%s' "$out" | grep -c '^| 59 | !591 |')"
ok "59: ...and the child's own merged PR on HEAD keeps its number" 1 \
   "$(printf '%s' "$out" | grep -c '^| 59 | !592 |')"
ok "60: an open candidate wins over a merged one"   1 \
   "$(printf '%s' "$out" | grep -c '^| 60 | !602 |')"
ok "61: an open PR outside this worktree's history is only an annotation" 1 \
   "$(printf '%s' "$out" | grep -c '^| 61 | !611? | .*no MR yet')"

# #317 — a merge from before the launch is the old PR of a kept-branch relaunch.
ok "65: a merged PR on HEAD that merged before the launch is only an annotation" 1 \
   "$(printf '%s' "$out" | grep -c '^| 65 | !651? | .*no MR yet')"
ok "67: a verified merged PR wins over an earlier failing candidate" 1 \
   "$(printf '%s' "$out" | grep -c '^| 67 | !672 |')"
ok "68: a CLOSED PR on HEAD closed before the launch is only an annotation" 1 \
   "$(printf '%s' "$out" | grep -c '^| 68 | !681? | .*no MR yet')"
ok "...and no annotation ever reached mr_state"     0 \
   "$(grep -cE 'pr view ~?(581|611|651|661|671|681)( |$)' "$GH_VIEWS")"
ok "...while a verified number did, so that log is not empty" 1 \
   "$(grep -cE 'pr view 777( |$)' "$GH_VIEWS")"

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
# Its PR merged "before" a launch — but it has no launch record, so that test is skipped: a blank
# here would take the `merged` a finished child's teardown needs.
ok "64: ...and its row carries the number, with no launch record to test against" 1 \
   "$(printf '%s' "$out" | grep -c '^| 64 | !641 |')"
# 66 is 65 on this arm: the annotation must not become the iid lock 1 reads `merged` from. The
# `pr view` log check above covers 661 as well.
ok "66: a gone slot's pre-launch merge is only an annotation too" 1 \
   "$(printf '%s' "$out" | grep -c '^| 66 | !661? | — | ⛔ no terminal')"

# The forge deadline's PRODUCTION default, asserted rather than trusted: the run above shrinks it,
# so a default quietly lowered to suit this file would stay green here and kill slow calls live.
ok "the forge timeout still defaults to 20s"        1 \
   "$(grep -Fc 'knob_uint "${SHIPYARD_FORGE_TIMEOUT:-}" 20)' "$REPORT")"
ok "...and a zero deadline is refused, with a warning" 1 \
   "$(SHIPYARD_FORGE_TIMEOUT=0 SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t15ex SHIPYARD_MOTION_INTERVAL=0.01 \
        SHIPYARD_STALL_SECS=100000 SHIPYARD_AUTODOWN=0 bash "$REPORT" 53 2>&1 >/dev/null \
      | grep -c 'SHIPYARD_FORGE_TIMEOUT is not a usable')"

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
   "$(grep -v -- '--json number,state,headRefOid,isCrossRepository,closedAt' "$GH_CALLS" | grep -c .)"
ok "...and for several candidates, not one"         0 \
   "$(grep -v -- '--limit 10 ' "$GH_CALLS" | grep -c .)"
# ...and the log holds exactly the slots that should reach the forge — 51 54 58 59 60 61 62 64 65
# 66 67 68 — so the checks above cannot pass vacuously over no calls.
ok "the log they read holds the expected queries"   12 \
   "$(grep -c . "$GH_CALLS")"

# #317 — the GitLab arm, in its own run, because the forge is derived from the origin remote.
FAKE_ORIGIN='https://gitlab.com/example/example.git'; export FAKE_ORIGIN
: > "$GH_VIEWS"
glout=$(SHIPYARD_MOTION_INTERVAL="${SHIPYARD_MOTION_INTERVAL:-0.01}" SHIPYARD_STALL_SECS=100000 SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t15ex \
          SHIPYARD_FORGE_TIMEOUT=2 SHIPYARD_AUTODOWN=0 \
          bash "$REPORT" $GL_SLOTS 2>/dev/null)
ok "gitlab: a fork's MR is dropped"                 0 \
   "$(printf '%s' "$glout" | grep -c '^| gfork | !811')"
ok "gitlab: ...and the child's own merged MR on HEAD keeps its number" 1 \
   "$(printf '%s' "$glout" | grep -c '^| gfork | !812 |')"
ok "gitlab: an opened MR whose head is an ancestor wins" 1 \
   "$(printf '%s' "$glout" | grep -c '^| ganc | !822 |')"
ok "gitlab: ...and its state is read from glab"     1 \
   "$(printf '%s' "$glout" | grep -c '^| ganc .*opened /')"
ok "gitlab: a merge from before the launch is only an annotation" 1 \
   "$(printf '%s' "$glout" | grep -c '^| gold | !831? | .*no MR yet')"
ok "gitlab: ...which never reached mr_state"        0 \
   "$(grep -cE 'mr view ~?831( |$)' "$GH_VIEWS")"
# The shortcut itself: without it the slot reaches glab and renders 841. Its `return` is NOT pinned,
# and cannot be from a report run: the loop asks `slot_iid <slot> local` first, which stops before
# the forge arm, so a numeric GitLab slot never makes the second call the `return` guards.
ok "gitlab: a numeric slot is its own iid"          1 \
   "$(printf '%s' "$glout" | grep -c '^| 71 | !71 |')"
ok "gitlab: ...and glab is never asked about its branch" 0 \
   "$(grep -c -- '--source-branch feat/gl-numeric' "$GLAB_CALLS")"
ok "gitlab: every query asks for any state, several candidates, as JSON" 0 \
   "$(grep -v -- '--all -P 10 -F json' "$GLAB_CALLS" | grep -c .)"
ok "gitlab: ...over the three non-numeric slots"    3 \
   "$(grep -c . "$GLAB_CALLS")"

# #329 — THE BASH 3.2 FLOOR, over live slots. The report is run by stock macOS /bin/bash 3.2, and
# its per-slot path (slot_iid, slot_iid_forge, slot_launch_epoch, iid_label, the row loop) is only
# reached over a live slot, so the floor is checked here, over GitHub slots that reach the forge
# fallback, rather than over an empty workspace. The interpreter is found, not assumed: `bash` on
# PATH is 5.x on the CI runner and on any Mac with a newer bash in front, and /bin/bash is 5.x on
# Linux. SHIPYARD_TEST_BASH32 names one explicitly. With none, this section says it did not run,
# which on the Linux CI runner is every run — there the per-slot path's 3.2 cleanliness rests on a
# macOS run of this file. The exported fakes above reach a 3.2 child: Apple's 3.2.57 reads the
# `BASH_FUNC_<name>%%` form bash 5 exports (checked below rather than trusted, since a floor
# whose fakes never loaded would fail for the wrong reason).
FAKE_ORIGIN='https://github.com/example/example.git'; export FAKE_ORIGIN
B32=""
for b in "${SHIPYARD_TEST_BASH32:-}" /bin/bash; do
  [ -n "$b" ] && [ -x "$b" ] || continue
  [ "$("$b" -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)" = 3 ] && { B32=$b; break; }
done
if [ -z "$B32" ]; then
  printf '  skip the bash 3.2 floor: no bash 3.2 interpreter here (/bin/bash is %s; set SHIPYARD_TEST_BASH32)\n' \
    "$(/bin/bash -c 'echo "$BASH_VERSION"' 2>/dev/null || echo absent)"
else
  ok "3.2 floor: the exported fakes reach a $B32 child" yes \
     "$("$B32" -c 'type gh >/dev/null 2>&1 && echo yes || echo no')"
  : > "$GH_CALLS"
  out32=$(SHIPYARD_MOTION_INTERVAL="${SHIPYARD_MOTION_INTERVAL:-0.01}" SHIPYARD_STALL_SECS=100000 SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t15ex \
            SHIPYARD_FORGE_TIMEOUT=2 SHIPYARD_AUTODOWN=0 \
            "$B32" "$REPORT" 51 58 59 64 65 2>"$T15TMP/b32.err")
  ok "3.2 floor: the report writes nothing to stderr" "" "$(cat "$T15TMP/b32.err")"
  ok "3.2 floor: the forge was asked for the slots that reach it" 5 "$(grep -c . "$GH_CALLS")"
  ok "3.2 floor: 51's number comes from the forge"      1 "$(printf '%s' "$out32" | grep -c '^| 51 | !777 |')"
  ok "3.2 floor: ...and its state from mr_state"        1 "$(printf '%s' "$out32" | grep -c '^| 51 .*opened /')"
  ok "3.2 floor: an ancestor-only merge is an annotation" 1 "$(printf '%s' "$out32" | grep -c '^| 58 | !581? | .*no MR yet')"
  ok "3.2 floor: a fork is dropped for the child's own"  1 "$(printf '%s' "$out32" | grep -c '^| 59 | !592 |')"
  ok "3.2 floor: the gone-slot teardown arm keeps its number" 1 "$(printf '%s' "$out32" | grep -c '^| 64 | !641 |')"
  ok "3.2 floor: a pre-launch merge is an annotation"    1 "$(printf '%s' "$out32" | grep -c '^| 65 | !651? | .*no MR yet')"
fi

unset -f git tmux gh glab
if [ "$FAILURES" -eq 0 ]; then
  printf 't15-iid-fallback: %d checks, all passed\n' "$CHECKS"; exit 0
fi
printf 't15-iid-fallback: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"; exit 1
