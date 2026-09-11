#!/usr/bin/env bash
# shipyard-down-gate.sh — the teardown safety gate. Source only, never execute.
#
# One question, asked about CONTENT: if this worktree is removed, is anything lost?
#
# It used to be asked about ANCESTRY — `@{upstream}..HEAD` — and that is the wrong question at
# exactly the moment teardown happens. Two measured failures, opposite directions:
#
#   * FALSE REFUSAL on the happy path. A slot's branch is created with
#     `git switch -c <branch> origin/<base>`, which sets its upstream to `origin/<base>` (not to
#     its own remote branch, which does not exist yet), and a later push by refspec never
#     updates it. So `@{upstream}..HEAD` is `origin/<base>..HEAD` — the branch's own commits —
#     and after a SQUASH merge none of them is an ancestor of the base branch no matter how
#     completely their content landed. The guard then reported "N commit(s) not in its upstream"
#     about work that was fully merged. Measured: a slot torn down right after
#     `merge --squash --delete-branch`, worktree clean, content identical to the base branch,
#     refused with N=3.
#   * SILENT PASS on the dangerous one. A branch with NO upstream configured makes
#     `@{upstream}` a fatal error; stderr was discarded and `wc -l` counted the empty stdout as
#     ZERO, so a slot whose commits existed nowhere else cleared the gate.
#
# WHAT IS ACTUALLY AT STAKE, measured, because the honest version changes which refusal an
# operator should take seriously. `git worktree remove` does NOT delete the branch: a slot torn
# down with committed, never-pushed work leaves that branch — and `git show <branch>:<file>` —
# intact in the repository. So gate 2 does not protect commits from deletion; it protects a
# change's history from being ORPHANED in a branch nobody will look at again, together with
# whatever untracked and ignored files the directory carried. The gate that stands between the
# operator and genuinely unrecoverable content is gate 1, the dirty check — which is why a
# `dirty` refusal deserves MORE weight than an `unmerged` one, not less.
#
# CONTAINMENT IS PROVEN, NEVER ASSUMED. Two independent proofs, first one that succeeds wins:
#
#   1. TREE EQUALITY — the worktree's committed tree is byte-identical to the base branch's.
#      Exact, instant, and works on any git.
#   2. MERGE EMPTINESS — merging this branch into the base branch would produce the base
#      branch's own tree, i.e. the branch contributes nothing that is not already there.
#      This is the one that survives the base branch moving ahead, which it always does in a
#      fleet: sibling slots land while this one waits to be torn down, so tree equality stops
#      holding within minutes of the merge even though nothing is missing.
#      Needs `git merge-tree --write-tree` (git >= 2.38); on an older git it simply fails and
#      the gate falls back to proof 1 — more refusals, never a wrong allow.
#
# Proof 1 is subsumed by proof 2 whenever merge-tree is available. It is kept because it costs
# one command, answers the commonest case without invoking a merge, and is the whole gate on a
# git too old for the second.
#
# FAILING TO PROVE IS NOT THE SAME AS FINDING UNMERGED WORK, and the two get different words.
# `unmerged` means the test merge SUCCEEDED and still added content to the base branch — the
# branch really does carry something that is not there. `unprovable` means the question could
# not be answered: the test merge conflicted (the base branch has since edited the same region
# this branch touched), or this git is too old for it. The first says do not discard; the
# second says look, then `--force` with a clear conscience. Collapsing them into one message
# was the shape the old guard had, and it is what trains an operator to stop reading.
#
# NOT EVERY FAILURE IS AN ANSWER. `git status` can exit non-zero with empty stdout (an
# unreadable or corrupt index — measured with a chmod-000 index, the state a containerised or
# sudo build inside a worktree leaves behind), and an empty answer read as "not dirty" is
# exactly the SILENT PASS shape above, reproduced in the arm that guards real data loss. So a
# question git could not answer returns `unknown` and refuses. The same applies to a path that
# is not a worktree at all: git discovery would walk UP out of a stray `.claude/worktrees/ship-*`
# directory and cheerfully report the MAIN checkout's state as this slot's.
#
# THIS MODULE WRITES TWICE, both deliberately, neither reversible-by-accident: a single lazy
# `git fetch` of the base branch (shipyard_down_refresh), and the merged tree that
# `merge-tree --write-tree` persists — unreferenced, reclaimed by gc, and required because the
# proof compares the OID it prints against the base branch's tree. Set SHIPYARD_DOWN_FETCH=0 to
# forbid the fetch; there is no way to ask for the proof without the object, and no need.

# OUTPUTS of shipyard_down_verdict, set in the CALLER's shell. They are outputs, not knobs:
# nothing reads them as input, and every caller overwrites both.
SHIPYARD_DOWN_KIND=''
SHIPYARD_DOWN_REF=''

# An option-shaped ref name is legal git (`git check-ref-format 'refs/heads/--depth=1'` passes)
# and a REMOTE controls the name its HEAD points at, which a clone copies into
# refs/remotes/origin/HEAD. Two things go wrong if one reaches us, and both were measured:
# handed to `git fetch` in refspec position it is parsed as an OPTION (`--upload-pack=<cmd>`
# executes, via a shell, for local-path and file:// remotes), and handed to `git diff` it makes
# `git diff --quiet <option> HEAD` degenerate into a HEAD-vs-worktree comparison, which is rc 0
# on a worktree already proven clean — a false `safe`. Rejecting the SHAPE here, at the one
# place a ref enters this module, closes both at once.
_shipyard_down_ref_ok() {
  case "$1" in
    -*|*/-*|'') return 1 ;;
    *) return 0 ;;
  esac
}

# The base-branch ref a slot is measured against, discovered rather than assumed — this skill
# ships to repositories whose base branch is not `main` and whose forge remote is not `origin`.
# In order:
#
#   1. origin/HEAD's target, the canonical answer where a clone recorded one.
#   2. The branch's own @{upstream}, but ONLY when it is not this branch's own remote-tracking
#      ref. That guard is load-bearing, not defensive: a branch pushed with `-u` has
#      @{upstream} == <remote>/<its own name>, whose content is identical to the branch BY
#      CONSTRUCTION, so measuring containment against it would call every pushed-but-unmerged
#      branch `safe` — the old guard's bug with a new mechanism. What makes the upstream useful
#      here is the OTHER case: `git switch -c <branch> origin/<base>` leaves it naming the BASE
#      branch, which is exactly the ref we want and the only one a single-branch clone has.
#   3. origin/main, then origin/master — a last resort, not a definition.
#
# Prints the ref name (e.g. `origin/main`); rc 1 when none resolves, which the caller must treat
# as "cannot ask the question" rather than as a verdict.
shipyard_down_default_ref() {
  local wt="$1" r b up
  r=$(git -C "$wt" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  if _shipyard_down_ref_ok "$r" && git -C "$wt" rev-parse --verify --quiet "$r^{commit}" >/dev/null 2>&1; then
    printf '%s' "$r"; return 0
  fi
  b=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null)
  up=$(git -C "$wt" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)
  if [ -n "$b" ] && [ "${up#*/}" != "$b" ] && _shipyard_down_ref_ok "$up" \
     && git -C "$wt" rev-parse --verify --quiet "$up^{commit}" >/dev/null 2>&1; then
    printf '%s' "$up"; return 0
  fi
  for r in origin/main origin/master; do
    if git -C "$wt" rev-parse --verify --quiet "$r^{commit}" >/dev/null 2>&1; then
      printf '%s' "$r"; return 0
    fi
  done
  return 1
}

# rc 0 the content is PROVEN to be in <ref> already
# rc 1 the test merge succeeded and still adds content — genuinely not in <ref>
# rc 2 the question could not be answered (unusable ref, conflicting merge, git too old)
# Nothing returns 0 by falling through: an unanswerable question can never read as a clean
# bill of health.
shipyard_down_contained() {
  local wt="$1" ref="$2" tree out
  git -C "$wt" diff --quiet "$ref" HEAD 2>/dev/null && return 0
  tree=$(git -C "$wt" rev-parse --verify --quiet "$ref^{tree}" 2>/dev/null) || return 2
  out=$(git -C "$wt" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 2
  [ "$(printf '%s\n' "$out" | head -1)" = "$tree" ] && return 0
  return 1
}

# Refresh the base branch once per invocation, and only when a proof has already failed.
# Teardown follows a merge by seconds, so the commonest reason a proof fails is that this
# clone has simply not seen the merge yet — asking the operator to `--force` past a stale ref
# is the cry-wolf this module exists to remove. rc 0 only when a fetch actually happened, so
# the caller retries exactly once and never loops.
#
# The latch only works because shipyard_down_verdict is called WITHOUT a command substitution
# (that is why the verdict is returned in globals): a `$( )` call would set this in a subshell
# and discard it, turning "once per invocation" into once per slot — measured at three fetches
# for three slots, against a promise of one.
#
# The refspec is fully qualified and follows `--` so that no part of it can be read as an
# option (see _shipyard_down_ref_ok), and GIT_TERMINAL_PROMPT=0 keeps a teardown from blocking
# forever on a credential prompt nobody is watching.
_SHIPYARD_DOWN_FETCHED=''
shipyard_down_refresh() {
  local wt="$1" ref="$2" remote branch
  [ "${SHIPYARD_DOWN_FETCH:-1}" = 1 ] || return 1
  case " $_SHIPYARD_DOWN_FETCHED " in *" $ref "*) return 1 ;; esac
  _SHIPYARD_DOWN_FETCHED="$_SHIPYARD_DOWN_FETCHED $ref"
  remote=${ref%%/*}; branch=${ref#*/}
  GIT_TERMINAL_PROMPT=0 git -C "$wt" fetch --quiet "$remote" -- \
    "+refs/heads/$branch:refs/remotes/$ref" >/dev/null 2>&1 || return 1
  return 0
}

# shipyard_down_verdict <worktree> — the whole gate. Sets SHIPYARD_DOWN_KIND and
# SHIPYARD_DOWN_REF in the caller's shell and returns 0 ONLY for `safe`:
#
#   safe        <ref>  content already in the base branch; removing the worktree loses nothing
#   dirty              uncommitted or untracked changes — refused exactly as before
#   unmerged    <ref>  the branch genuinely carries content the base branch does not have
#   unprovable  <ref>  containment could not be proven (later edit to the same region, old git)
#   no-default         no base branch could be discovered to compare against
#   unknown            not a worktree, or git could not answer — the question was never asked
#
# It returns its answer in globals rather than on stdout so that callers do not have to spawn a
# subshell to read it; see shipyard_down_refresh for what that buys.
shipyard_down_verdict() {
  local wt="$1" ref st
  SHIPYARD_DOWN_KIND=unknown
  SHIPYARD_DOWN_REF=''
  # Not a worktree (nor a repository root): git would discover its way UP to the parent repo
  # and answer about that instead, which is a confident answer to a question about the wrong
  # tree. Measured on a stray directory under .claude/worktrees/.
  [ -e "$wt/.git" ] || return 1
  st=$(git -C "$wt" status --porcelain 2>/dev/null) || return 1
  if [ -n "$st" ]; then SHIPYARD_DOWN_KIND=dirty; return 1; fi
  ref=$(shipyard_down_default_ref "$wt") || { SHIPYARD_DOWN_KIND=no-default; return 1; }
  SHIPYARD_DOWN_REF="$ref"
  shipyard_down_contained "$wt" "$ref"
  case $? in
    0) SHIPYARD_DOWN_KIND=safe; return 0 ;;
    1) SHIPYARD_DOWN_KIND=unmerged ;;
    *) SHIPYARD_DOWN_KIND=unprovable ;;
  esac
  # A stale remote-tracking ref looks exactly like both of those, so spend the one fetch and
  # ask again before refusing.
  if shipyard_down_refresh "$wt" "$ref"; then
    shipyard_down_contained "$wt" "$ref"
    case $? in
      0) SHIPYARD_DOWN_KIND=safe; return 0 ;;
      1) SHIPYARD_DOWN_KIND=unmerged ;;
      *) SHIPYARD_DOWN_KIND=unprovable ;;
    esac
  fi
  return 1
}
