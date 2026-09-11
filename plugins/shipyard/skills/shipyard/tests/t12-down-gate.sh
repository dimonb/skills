#!/usr/bin/env bash
# t12-down-gate.sh — the teardown safety gate (shipyard-down-gate.sh).
#
# NOTHING HERE IS FAKED. Every other file in this suite drives pure functions over fixtures, or
# fakes git on PATH; this one must not, because the defect it closes IS git's answer. The old
# guard asked `@{upstream}..HEAD` and a fake git would have returned whatever the fixture author
# believed that means — which is exactly the belief that was wrong. So each case builds a real
# bare "origin", a real clone, real commits, a real `merge --squash`, a real branch deletion and
# a real worktree, and asks the real git. Cases A and C below each print the OLD question's
# answer alongside the new verdict, so the regression is pinned to a measurement rather than to
# a memory of one.
#
# The properties, each tracing to a live failure (suite law: no property without a defect):
#   A  squash-merged, remote branch deleted, upstream left pointing at the base branch — the
#      measured false refusal (a clean, fully merged slot reported as "3 commit(s) not in its
#      upstream"). Must be `safe`, and the old question must still answer 3, or the case has
#      stopped reproducing the bug and proves nothing.
#   B  squash-merged with the remote branch KEPT — the accidental control that isolated the
#      trigger: this one always passed, and must keep passing.
#   C  work committed and never pushed, with no upstream configured at all — the silent PASS.
#      `@{upstream}` is fatal, its stderr was discarded, and `wc -l` read the empty stdout as
#      zero, so the gate removed a worktree holding the only copy. Must be `unmerged`.
#   P  half the branch landed. Must be `unmerged` — partial containment is not containment.
#   D1 the base branch moved ahead after the merge (a sibling slot landed). Must stay `safe`:
#      this is the case tree equality alone cannot carry, and in a fleet it arrives within
#      minutes of every merge.
#   D3 the base branch later edited the SAME REGION the branch touched. The test merge
#      conflicts, so containment is NOT provable and the gate refuses. Asserted as the
#      refuse-when-unproven invariant, not as an ambition: make it provable some day and this
#      expectation should be changed deliberately, in the same commit.
#   F  a stale remote-tracking ref — teardown follows the merge by seconds, so the clone has
#      often not seen it. The gate fetches once and allows; SHIPYARD_DOWN_FETCH=0 forbids the
#      fetch and the same slot reads `unmerged`. Pins both halves of the one impure step.
#   E  dirty (tracked edit) and dirty (untracked file only) — the half of the old guard that
#      was right, which must not have been loosened on the way past.
#   R  base-ref resolution: origin/HEAD when set, origin/main when it is not, `no-default`
#      when the repo has no origin refs at all.
#
# NOT COVERED, so a green run is never read as more than it is: proof 1 (tree equality) is
# never exercised in ISOLATION — every case that satisfies it also satisfies proof 2, so an
# old git (< 2.38, no `merge-tree --write-tree`) takes a path nothing here walks. The fetch
# case uses a local file:// remote, so no network failure, credential prompt or timeout is
# exercised either.
set -uo pipefail
export LC_ALL=C

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../shipyard-down-gate.sh
. "$SKILL_DIR/shipyard-down-gate.sh"

# Hermetic git: no user identity, no global/system config, no init.defaultBranch surprise from
# the machine this runs on. Without this the suite passes or fails according to whoever's
# ~/.gitconfig is in scope, which is the same class of cry-wolf the module itself removes.
#
# The identity below is deliberately NOT address-shaped. git takes any ident string, and the
# repo's leak gate denies the address shape wherever it appears — a fixture address would red
# the gate for every commit after this one, which is a poor trade for a field nothing reads.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=shipyard-test GIT_AUTHOR_EMAIL=shipyard-test
export GIT_COMMITTER_NAME=shipyard-test GIT_COMMITTER_EMAIL=shipyard-test

TMP=$(mktemp -d "${TMPDIR:-/tmp}/shipyard-t12.XXXXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}
done_() {
  if [ "$FAILURES" -eq 0 ]; then printf '%s: %d checks, all passed\n' "$1" "$CHECKS"; return 0; fi
  printf '%s: %d checks, %d FAILED\n' "$1" "$CHECKS" "$FAILURES"; return 1
}

# verdict <worktree> — just the word, which is what every assertion is about.
verdict() { local v; v=$(shipyard_down_verdict "$1"); printf '%s' "${v%% *}"; }
# old_guard <worktree> — the question the gate used to ask, verbatim, including the discarded
# stderr and the `wc -l` that turned a fatal error into a zero.
old_guard() { git -C "$1" log --oneline '@{upstream}..HEAD' 2>/dev/null | wc -l | tr -d ' '; }

# repo <name> — a bare origin plus a clone on `main` with one commit. Prints the clone's path.
repo() {
  local n="$1" o="$TMP/$1.git" c="$TMP/$1"
  git init -q --bare -b main "$o"
  git clone -q "$o" "$c" 2>/dev/null
  printf 'base\n' > "$c/a.txt"; printf 'other\n' > "$c/o.txt"
  git -C "$c" add -A; git -C "$c" commit -qm base
  git -C "$c" push -q -u origin main
  printf '%s' "$c"
}

# ---------------------------------------------------------------- A: the measured false refusal
C=$(repo a)
# `switch -c <branch> origin/main` is how ship starts a change, and it sets the branch's
# upstream to origin/main — NOT to a remote branch of its own, which does not exist yet.
git -C "$C" switch -q -c feat/a origin/main
for i in 1 2 3; do printf 'a%s\n' "$i" >> "$C/a.txt"; git -C "$C" add -A; git -C "$C" commit -qm "a$i"; done
# Pushed by refspec, the way the forge reference prescribes: this does NOT update the upstream.
git -C "$C" push -q origin feat/a:feat/a
git -C "$C" switch -q main
git -C "$C" merge -q --squash feat/a >/dev/null 2>&1
git -C "$C" commit -qm "squashed (#1)"
git -C "$C" push -q origin main
git -C "$C" push -q origin --delete feat/a
git -C "$C" worktree add -q "$TMP/wtA" feat/a
git -C "$TMP/wtA" fetch -q origin

ok "A the old question still answers 3 (case reproduces)" "3" "$(old_guard "$TMP/wtA")"
ok "A squash-merged, branch deleted -> safe"              "safe" "$(verdict "$TMP/wtA")"

# ---------------------------------------------------------------- B: remote branch kept
C=$(repo b)
git -C "$C" switch -q -c feat/b origin/main
printf 'b1\n' >> "$C/a.txt"; git -C "$C" add -A; git -C "$C" commit -qm b1
git -C "$C" push -q -u origin feat/b
git -C "$C" switch -q main
git -C "$C" merge -q --squash feat/b >/dev/null 2>&1
git -C "$C" commit -qm "squashed (#2)"
git -C "$C" push -q origin main
git -C "$C" worktree add -q "$TMP/wtB" feat/b
git -C "$TMP/wtB" fetch -q origin
ok "B squash-merged, remote branch kept -> safe" "safe" "$(verdict "$TMP/wtB")"

# ---------------------------------------------------------------- C: the silent pass
C=$(repo c)
# No upstream at all: `switch -c` from a LOCAL ref configures none, and nothing is pushed.
git -C "$C" switch -q -c feat/c
printf 'c1\n' > "$C/c.txt"; git -C "$C" add -A; git -C "$C" commit -qm c1
git -C "$C" switch -q main
git -C "$C" worktree add -q "$TMP/wtC" feat/c
ok "C the old question answered 0 for unpushed work" "0"        "$(old_guard "$TMP/wtC")"
ok "C committed, never pushed -> unmerged"          "unmerged" "$(verdict "$TMP/wtC")"

# ---------------------------------------------------------------- P: partially merged
C=$(repo p)
git -C "$C" switch -q -c feat/p origin/main
printf 'p1\n' > "$C/p1.txt"; git -C "$C" add -A; git -C "$C" commit -qm p1
printf 'p2\n' > "$C/p2.txt"; git -C "$C" add -A; git -C "$C" commit -qm p2
git -C "$C" switch -q main
git -C "$C" checkout -q feat/p -- p1.txt
git -C "$C" add -A; git -C "$C" commit -qm "only p1 landed"
git -C "$C" push -q origin main
git -C "$C" worktree add -q "$TMP/wtP" feat/p
ok "P only half the branch landed -> unmerged" "unmerged" "$(verdict "$TMP/wtP")"

# ------------------------------------------------- D1/D3: the base branch moves on after the merge
C=$(repo d)
git -C "$C" switch -q -c feat/d origin/main
for i in 1 2 3; do printf 'd%s\n' "$i" >> "$C/a.txt"; git -C "$C" add -A; git -C "$C" commit -qm "d$i"; done
git -C "$C" switch -q main
git -C "$C" merge -q --squash feat/d >/dev/null 2>&1
git -C "$C" commit -qm "squashed (#3)"
git -C "$C" push -q origin main
git -C "$C" worktree add -q "$TMP/wtD" feat/d
git -C "$TMP/wtD" fetch -q origin
ok "D0 right after the merge -> safe" "safe" "$(verdict "$TMP/wtD")"

# A sibling slot lands its own change. Tree equality is gone; containment is not.
printf 'sibling\n' > "$C/s.txt"; git -C "$C" add -A; git -C "$C" commit -qm "sibling slot landed"
printf 'tail\n' >> "$C/o.txt"; git -C "$C" add -A; git -C "$C" commit -qm "and edits another file"
git -C "$C" push -q origin main
git -C "$TMP/wtD" fetch -q origin
ok "D1 base branch moved ahead elsewhere -> still safe" "safe" "$(verdict "$TMP/wtD")"

# Now the base branch edits the same region of the same file. Not provable -> refuse.
printf 'zz\n' >> "$C/a.txt"; git -C "$C" add -A; git -C "$C" commit -qm "append to a.txt too"
git -C "$C" push -q origin main
git -C "$TMP/wtD" fetch -q origin
ok "D3 same region edited later -> refuses (unproven)" "unmerged" "$(verdict "$TMP/wtD")"

# ---------------------------------------------------------------- F: the stale remote-tracking ref
C=$(repo f)
git -C "$C" switch -q -c feat/f origin/main
printf 'f1\n' >> "$C/a.txt"; git -C "$C" add -A; git -C "$C" commit -qm f1
git -C "$C" push -q origin feat/f:feat/f
git -C "$C" switch -q main
git -C "$C" worktree add -q "$TMP/wtF" feat/f
# Merge on the REMOTE only, through a second clone, so $TMP/wtF's origin/main stays stale —
# which is the state a teardown seconds after `gh pr merge` actually finds.
git clone -q "$TMP/f.git" "$TMP/f-other" 2>/dev/null
git -C "$TMP/f-other" fetch -q origin
git -C "$TMP/f-other" merge -q --squash origin/feat/f >/dev/null 2>&1
git -C "$TMP/f-other" commit -qm "squashed (#4)"
git -C "$TMP/f-other" push -q origin main
ok "F stale ref, fetch forbidden -> unmerged" "unmerged" \
   "$(SHIPYARD_DOWN_FETCH=0 verdict "$TMP/wtF")"
# The fetch is latched per invocation; this file is one invocation, so clear the latch to let
# the second half run the fetch it is asserting.
_SHIPYARD_DOWN_FETCHED=''
ok "F stale ref, gate fetches once -> safe" "safe" "$(verdict "$TMP/wtF")"

# ---------------------------------------------------------------- E: dirty stays refused
C=$(repo e)
git -C "$C" worktree add -q "$TMP/wtE" --detach origin/main
ok "E untouched worktree at the base branch -> safe" "safe" "$(verdict "$TMP/wtE")"
printf 'edit\n' >> "$TMP/wtE/a.txt"
ok "E tracked edit -> dirty"     "dirty" "$(verdict "$TMP/wtE")"
git -C "$TMP/wtE" checkout -q -- a.txt
printf 'x\n' > "$TMP/wtE/untracked.txt"
ok "E untracked file only -> dirty" "dirty" "$(verdict "$TMP/wtE")"
rm -f "$TMP/wtE/untracked.txt"

# ---------------------------------------------------------------- R: base-ref resolution
C=$(repo r)
git -C "$C" remote set-head origin main
ok "R origin/HEAD when it is set" "origin/main" "$(shipyard_down_default_ref "$C")"
git -C "$C" remote set-head origin --delete
ok "R falls back to origin/main"  "origin/main" "$(shipyard_down_default_ref "$C")"

# A repo with no origin refs at all cannot be asked the question — and must not be told yes.
git init -q -b main "$TMP/lonely"
printf 'x\n' > "$TMP/lonely/x.txt"
git -C "$TMP/lonely" add -A; git -C "$TMP/lonely" commit -qm x
ok "R no origin refs -> resolution fails" "1" \
   "$( { shipyard_down_default_ref "$TMP/lonely" >/dev/null; echo $?; } )"
ok "R no origin refs -> no-default"       "no-default" "$(verdict "$TMP/lonely")"

done_ t12-down-gate
