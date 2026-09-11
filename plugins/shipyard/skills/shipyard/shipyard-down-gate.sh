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
#     completely their content landed. The guard then reports "N commit(s) not in its upstream"
#     about work that is fully merged. Measured: a slot torn down right after
#     `merge --squash --delete-branch`, worktree clean, content identical to the base branch,
#     refused with N=3.
#   * SILENT PASS on the dangerous one. A branch with NO upstream configured makes
#     `@{upstream}` a fatal error; stderr was discarded and `wc -l` counted the empty stdout as
#     ZERO, so a worktree holding work that was never pushed anywhere passed the gate and was
#     removed. The gate that exists to protect unpushed work was blind to the one case where
#     nothing else would have caught it.
#
# Both dissolve once the question is content. This module proves containment, and refuses when
# it cannot: `--force` stays the way through, but now it is reached by a message that means it.
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
# THE RESIDUAL, stated because a guard whose limits are undocumented gets trusted past them:
# if the base branch later edits the SAME REGION of the SAME FILE the branch touched, the test
# merge conflicts and neither proof succeeds, so a fully-merged slot is still refused. That is
# the conservative direction — it asks a human rather than discarding work — and the message
# says what could not be proven instead of naming a commit count that means nothing.
#
# Everything here is a pure read over git, with one deliberate exception: a single lazy
# `git fetch` of the base branch (see shipyard_down_refresh) when the proof fails and a stale
# remote-tracking ref is the likely reason. Set SHIPYARD_DOWN_FETCH=0 to forbid even that.

# The base-branch ref every slot is measured against: origin/HEAD's target, else origin/main,
# else origin/master. Prints the ref name (e.g. `origin/main`); rc 1 when none of the three
# resolves, which the caller must treat as "cannot ask the question" rather than as a verdict.
shipyard_down_default_ref() {
  local wt="$1" r
  r=$(git -C "$wt" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)
  if [ -n "$r" ] && git -C "$wt" rev-parse --verify --quiet "$r^{commit}" >/dev/null 2>&1; then
    printf '%s' "$r"; return 0
  fi
  for r in origin/main origin/master; do
    if git -C "$wt" rev-parse --verify --quiet "$r^{commit}" >/dev/null 2>&1; then
      printf '%s' "$r"; return 0
    fi
  done
  return 1
}

# rc 0 only when the worktree's committed content is PROVEN to be in <ref> already. Every
# failure mode — a missing ref, an old git, a conflicting test merge — returns 1, so an
# unanswerable question can never read as a clean bill of health.
shipyard_down_contained() {
  local wt="$1" ref="$2" tree out
  git -C "$wt" diff --quiet "$ref" HEAD 2>/dev/null && return 0
  tree=$(git -C "$wt" rev-parse --verify --quiet "$ref^{tree}" 2>/dev/null) || return 1
  out=$(git -C "$wt" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 1
  [ "$(printf '%s\n' "$out" | head -1)" = "$tree" ]
}

# Refresh the base branch once per invocation, and only when a proof has already failed.
# Teardown follows a merge by seconds, so the commonest reason a proof fails is that this
# clone has simply not seen the merge yet — asking the operator to `--force` past a stale ref
# is the cry-wolf this module exists to remove. rc 0 only when a fetch actually happened, so
# the caller retries exactly once and never loops.
_SHIPYARD_DOWN_FETCHED=''
shipyard_down_refresh() {
  local wt="$1" ref="$2"
  [ "${SHIPYARD_DOWN_FETCH:-1}" = 1 ] || return 1
  case " $_SHIPYARD_DOWN_FETCHED " in *" $ref "*) return 1 ;; esac
  _SHIPYARD_DOWN_FETCHED="$_SHIPYARD_DOWN_FETCHED $ref"
  git -C "$wt" fetch --quiet origin "${ref#origin/}" >/dev/null 2>&1 || return 1
  return 0
}

# shipyard_down_verdict <worktree> — the whole gate, as one word plus the ref it used.
# Prints "<verdict> <ref>" and returns 0 ONLY for `safe`:
#
#   safe        <ref>  content already in the base branch; removing the worktree loses nothing
#   dirty              uncommitted or untracked changes — refused exactly as before
#   unmerged    <ref>  containment could not be proven against the base branch
#   no-default         no origin/HEAD, origin/main or origin/master to compare against
#
# Dirty is tested first and on its own: a worktree with live edits is refused whatever its
# commits say, which is the half of the old guard that was always right.
shipyard_down_verdict() {
  local wt="$1" ref
  if [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
    printf 'dirty'; return 1
  fi
  ref=$(shipyard_down_default_ref "$wt") || { printf 'no-default'; return 1; }
  if shipyard_down_contained "$wt" "$ref"; then printf 'safe %s' "$ref"; return 0; fi
  if shipyard_down_refresh "$wt" "$ref" && shipyard_down_contained "$wt" "$ref"; then
    printf 'safe %s' "$ref"; return 0
  fi
  printf 'unmerged %s' "$ref"; return 1
}
