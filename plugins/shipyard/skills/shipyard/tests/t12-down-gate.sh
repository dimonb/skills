#!/usr/bin/env bash
# t12-down-gate.sh — the teardown safety gate (shipyard-down-gate.sh).
#
# NOTHING HERE IS FAKED, with one named exception. Every other file in this suite drives pure
# functions over fixtures, or fakes git on PATH; this one must not, because the defect it closes
# IS git's answer. The old guard asked `@{upstream}..HEAD` and a fake git would have returned
# whatever the fixture author believed that means — which is exactly the belief that was wrong.
# So each case builds a real bare "origin", a real clone, real commits, a real `merge --squash`,
# a real branch deletion and a real worktree, and asks the real git. Cases A and C each print the
# OLD question's answer alongside the new verdict, so the regression is pinned to a measurement
# rather than to a memory of one. The exception is case N, which shadows `git fetch` with a
# counter because counting is the whole assertion there.
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
#      zero, so the gate cleared a slot whose commits were reachable from nowhere else.
#   P  half the branch landed. Must be `unmerged` — partial containment is not containment.
#   D1 the base branch moved ahead after the merge (a sibling slot landed). Must stay `safe`:
#      this is the case tree equality alone cannot carry, and in a fleet it arrives within
#      minutes of every merge.
#   D3 the base branch later edited the SAME REGION the branch touched. The test merge
#      conflicts, so containment is not provable — and that must read `unprovable`, NOT
#      `unmerged`. Collapsing the two was the old guard's shape: one message for "you will lose
#      work" and for "I could not tell", which is what teaches an operator to stop reading.
#   F  a stale remote-tracking ref — teardown follows the merge by seconds, so the clone has
#      often not seen it. The gate fetches once and allows; SHIPYARD_DOWN_FETCH=0 forbids the
#      fetch and the same slot reads `unmerged`. Pins both halves of the one impure step.
#   N  that the fetch happens ONCE PER INVOCATION rather than once per slot. Latching it is the
#      only reason the verdict is returned in globals instead of on stdout; a `$( )` caller
#      forks the latch away, measured at three fetches for three slots against a promise of
#      one, and no assertion here noticed.
#   E  dirty (tracked edit) and dirty (untracked file only) — the half of the old guard that
#      was right, which must not have been loosened on the way past.
#   X  a worktree git cannot read (chmod-000 index): `git status --porcelain` exits 128 with
#      EMPTY stdout, and an empty answer read as "not dirty" let a worktree holding a staged,
#      uncommitted file verdict `safe` and be deleted. Measured. This is the module's own
#      SILENT PASS shape reproduced in the arm that guards real data loss, and it was a
#      REGRESSION: the ancestry guard happened to refuse in this state.
#   S  a stray directory under .claude/worktrees/ that is not a worktree at all — git discovery
#      walks UP and answers about the MAIN checkout, so the gate confidently reports another
#      tree's state as this slot's.
#   R  base-ref resolution: origin/HEAD when set; the branch's upstream when it is not (a
#      `develop`-based single-branch clone, where hardcoding main/master refuses every slot
#      forever — the cry-wolf relocated rather than removed); origin/main as the last resort;
#      `no-default` when the repo has no origin refs at all. Plus the two REJECTIONS that keep
#      a ref from being trusted: an option-shaped ref name (legal git, remote-controlled, and
#      it both injects an option into `git fetch` and makes `git diff --quiet <option> HEAD`
#      answer rc 0 — a false `safe`), and an upstream that is the branch's OWN remote ref
#      (identical to the branch by construction, so every pushed-but-unmerged branch would
#      read `safe`).
#
# NOT COVERED, so a green run is never read as more than it is:
#   * proof 1 (tree equality) is never exercised in ISOLATION — every case that satisfies it
#     also satisfies proof 2.
#   * `shipyard-down.sh` ITSELF is executed by nothing here: its argument parsing, the awk
#     --help extractor, the --list rendering and every refusal message are verified by hand
#     only. Change the verdict vocabulary and this suite stays green while --list falls to its
#     catch-all for healthy slots.
#   * git older than 2.38 has no `merge-tree --write-tree`. The gate degrades correctly there
#     (more refusals, never a wrong allow), but D1's expectation does NOT hold, so the case is
#     SKIPPED with a printed note rather than left to red and read as a gate regression.
#   * every remote is a local path, so no network failure, credential prompt or timeout is
#     exercised — only that the fetch is attempted, and counted.
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
# chmod 000 fixtures (case X) would defeat a plain rm -rf if the case died between the two
# chmods, so restore permissions before removing.
cleanup() { chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

CHECKS=0; FAILURES=0; SKIPS=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}
skip() { SKIPS=$((SKIPS + 1)); printf '  SKIP %s\n         %s\n' "$1" "$2"; }
done_() {
  local tail=''
  [ "$SKIPS" -eq 0 ] || tail=", $SKIPS skipped"
  if [ "$FAILURES" -eq 0 ]; then printf '%s: %d checks, all passed%s\n' "$1" "$CHECKS" "$tail"; return 0; fi
  printf '%s: %d checks, %d FAILED%s\n' "$1" "$CHECKS" "$FAILURES" "$tail"; return 1
}

# Does this git have proof 2? Probed once, against the fixtures' own git.
MERGE_TREE=no
if git merge-tree --write-tree --help >/dev/null 2>&1 || \
   git merge-tree --write-tree HEAD HEAD >/dev/null 2>&1; then MERGE_TREE=yes; fi

# verdict <worktree> — the verdict WORD. Deliberately not a `$( )` wrapper around the real
# function: these call it directly so the module's fetch latch lives in this shell, which is
# the behaviour case N asserts.
verdict() { shipyard_down_verdict "$1"; printf '%s' "$SHIPYARD_DOWN_KIND"; }
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
# The ref is consumed by six places in the caller, two of them `look:` commands an operator is
# told to run. Asserted here because replacing it with garbage broke no other check.
shipyard_down_verdict "$TMP/wtA"
ok "A the verdict names the base ref"                     "origin/main" "$SHIPYARD_DOWN_REF"

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
# `-u` made @{upstream} the branch's OWN remote ref. If that were accepted as the base ref the
# comparison would be the branch against itself, so this must still resolve to origin/main.
ok "B the branch's own remote ref is not the base" "origin/main" \
   "$(shipyard_down_default_ref "$TMP/wtB")"

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
if [ "$MERGE_TREE" = yes ]; then
  ok "D1 base branch moved ahead elsewhere -> still safe" "safe" "$(verdict "$TMP/wtD")"
else
  skip "D1 base branch moved ahead elsewhere" \
       "this git has no 'merge-tree --write-tree' (needs 2.38); the gate correctly falls back to tree equality and refuses"
fi

# Now the base branch edits the same region of the same file. Not provable -> its own word.
printf 'zz\n' >> "$C/a.txt"; git -C "$C" add -A; git -C "$C" commit -qm "append to a.txt too"
git -C "$C" push -q origin main
git -C "$TMP/wtD" fetch -q origin
ok "D3 same region edited later -> unprovable, not unmerged" "unprovable" "$(verdict "$TMP/wtD")"

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
_SHIPYARD_DOWN_FETCHED=''
ok "F stale ref, gate fetches once -> safe" "safe" "$(verdict "$TMP/wtF")"

# ------------------------------------------- N: the fetch is latched per INVOCATION, not per slot
# Three unproven slots in one invocation must produce exactly one fetch. `git` is shadowed by a
# counter that delegates everything else to the real one; this is the file's only fake, and it
# exists because the assertion IS the count.
C=$(repo n)
COUNTER="$TMP/fetches"; : > "$COUNTER"
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
REAL_GIT=$(command -v git)
{ printf '#!/usr/bin/env bash\n'
  printf 'for a in "$@"; do [ "$a" = fetch ] && { printf x >> %s; break; }; done\n' "$COUNTER"
  printf 'exec %s "$@"\n' "$REAL_GIT"
} > "$FAKEBIN/git"
chmod +x "$FAKEBIN/git"
for s in 1 2 3; do
  git -C "$C" switch -q -c "feat/n$s" origin/main
  printf 'n%s\n' "$s" > "$C/n$s.txt"; git -C "$C" add -A; git -C "$C" commit -qm "n$s"
  git -C "$C" switch -q main
  git -C "$C" worktree add -q "$TMP/wtN$s" "feat/n$s"
done
_SHIPYARD_DOWN_FETCHED=''
OLD_PATH=$PATH; PATH="$FAKEBIN:$PATH"
for s in 1 2 3; do shipyard_down_verdict "$TMP/wtN$s"; done
PATH=$OLD_PATH
ok "N three unproven slots share one fetch" "1" "$(wc -c < "$COUNTER" | tr -d ' ')"

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

# -------------------------------------- X: git could not answer, which is not the same as clean
# The regression this closes: `status --porcelain` exits 128 with empty stdout on an unreadable
# index, the emptiness was read as "not dirty", and the containment proofs never consult the
# index — so a worktree holding a staged file verdicted `safe` and was deleted.
C=$(repo x)
git -C "$C" switch -q -c feat/x origin/main
printf 'x1\n' >> "$C/a.txt"; git -C "$C" add -A; git -C "$C" commit -qm x1
git -C "$C" switch -q main
git -C "$C" merge -q --squash feat/x >/dev/null 2>&1
git -C "$C" commit -qm "squashed (#5)"
git -C "$C" push -q origin main
git -C "$C" worktree add -q "$TMP/wtX" feat/x
git -C "$TMP/wtX" fetch -q origin
printf 'the only copy of these notes\n' > "$TMP/wtX/handoff.txt"
git -C "$TMP/wtX" add handoff.txt
ok "X staged file, readable index -> dirty" "dirty" "$(verdict "$TMP/wtX")"
XIDX=$(git -C "$TMP/wtX" rev-parse --git-path index)
chmod 000 "$XIDX"
ok "X status exits non-zero with empty stdout" "128" \
   "$(git -C "$TMP/wtX" status --porcelain >/dev/null 2>&1; echo $?)"
ok "X unreadable index -> unknown, never safe" "unknown" "$(verdict "$TMP/wtX")"
chmod 644 "$XIDX"

# ------------------------------------ S: a path that is not a worktree must not answer for one
# .claude/worktrees/ lives inside the repo, so git discovery walks UP out of a stray directory
# and reports the MAIN checkout's state under the slot's name.
mkdir -p "$C/.claude/worktrees/ship-stray"
printf 'never seen by git\n' > "$C/.claude/worktrees/ship-stray/notes.txt"
ok "S stray directory -> unknown, not the parent repo's answer" "unknown" \
   "$(verdict "$C/.claude/worktrees/ship-stray")"

# ---------------------------------------------------------------- R: base-ref resolution
C=$(repo r)
git -C "$C" remote set-head origin main
ok "R origin/HEAD when it is set" "origin/main" "$(shipyard_down_default_ref "$C")"
git -C "$C" remote set-head origin --delete
ok "R falls back to origin/main"  "origin/main" "$(shipyard_down_default_ref "$C")"

# An option-shaped ref name is legal git and the REMOTE chooses it. It must never be returned:
# in `git fetch` refspec position it is parsed as an option, and `git diff --quiet <option> HEAD`
# answers rc 0 on a clean worktree — a false `safe`.
git -C "$C" update-ref 'refs/remotes/origin/--upload-pack=touch' refs/remotes/origin/main
git -C "$C" symbolic-ref refs/remotes/origin/HEAD 'refs/remotes/origin/--upload-pack=touch'
ok "R an option-shaped origin/HEAD is rejected" "origin/main" "$(shipyard_down_default_ref "$C")"
git -C "$C" symbolic-ref -d refs/remotes/origin/HEAD 2>/dev/null
git -C "$C" update-ref -d 'refs/remotes/origin/--upload-pack=touch' 2>/dev/null

# A repo based on `develop`, with no origin/HEAD — hardcoding main/master refuses every slot in
# it forever, which is the same cry-wolf in a new place. The branch's upstream names the base.
git init -q --bare -b develop "$TMP/dv.git"
git clone -q "$TMP/dv.git" "$TMP/dv" 2>/dev/null
printf 'base\n' > "$TMP/dv/a.txt"; git -C "$TMP/dv" add -A; git -C "$TMP/dv" commit -qm base
git -C "$TMP/dv" push -q -u origin develop
git -C "$TMP/dv" switch -q -c feat/dv origin/develop
printf 'dv1\n' >> "$TMP/dv/a.txt"; git -C "$TMP/dv" add -A; git -C "$TMP/dv" commit -qm dv1
git -C "$TMP/dv" switch -q develop
git -C "$TMP/dv" merge -q --squash feat/dv >/dev/null 2>&1
git -C "$TMP/dv" commit -qm "squashed (#6)"
git -C "$TMP/dv" push -q origin develop
git -C "$TMP/dv" worktree add -q "$TMP/wtDV" feat/dv
git -C "$TMP/wtDV" fetch -q origin
git -C "$TMP/wtDV" remote set-head origin --delete 2>/dev/null
ok "R no origin/HEAD -> the branch's upstream names the base" "origin/develop" \
   "$(shipyard_down_default_ref "$TMP/wtDV")"
ok "R a develop-based repo tears down normally" "safe" "$(verdict "$TMP/wtDV")"

# THE DANGEROUS UPSTREAM. With no origin/HEAD, a branch pushed with `-u` has @{upstream} naming
# its OWN remote ref, whose content equals the branch by construction. Accept that as the base
# ref and every pushed-but-unmerged branch measures `safe` — the old guard's bug rebuilt out of
# new parts. Only this shape reaches the guard: case B never does, because origin/HEAD answers
# first there, so without this the guard is load-bearing and untested at once.
C=$(repo u)
git -C "$C" switch -q -c feat/u origin/main
printf 'u1\n' > "$C/u.txt"; git -C "$C" add -A; git -C "$C" commit -qm u1
git -C "$C" push -q -u origin feat/u
git -C "$C" switch -q main
git -C "$C" worktree add -q "$TMP/wtU" feat/u
git -C "$TMP/wtU" remote set-head origin --delete 2>/dev/null
ok "R the branch's own remote ref is never the base" "origin/main" \
   "$(shipyard_down_default_ref "$TMP/wtU")"
ok "R pushed but unmerged -> unmerged, not safe" "unmerged" "$(verdict "$TMP/wtU")"

# A repo with no origin refs at all cannot be asked the question — and must not be told yes.
git init -q -b main "$TMP/lonely"
printf 'x\n' > "$TMP/lonely/x.txt"
git -C "$TMP/lonely" add -A; git -C "$TMP/lonely" commit -qm x
ok "R no origin refs -> resolution fails" "1" \
   "$( { shipyard_down_default_ref "$TMP/lonely" >/dev/null; echo $?; } )"
ok "R no origin refs -> no-default"       "no-default" "$(verdict "$TMP/lonely")"

done_ t12-down-gate
