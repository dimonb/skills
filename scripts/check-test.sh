#!/usr/bin/env bash
# Prove every assertion in scripts/check.sh actually fires.
#
# A gate that has never failed is decoration: it can be vacuous — a pattern that matches
# nothing, a loop over an empty glob, an unanchored match that any neighbouring line
# satisfies — and look exactly like a gate that works. So each case here injects ONE
# violation, requires the gate to fail, and restores.
#
# A few cases run the other way and require the gate to stay GREEN. A check that reds on
# something the repo does not own is the same defect seen from the other side: it blocks every
# commit until the local state is moved, and a red gate never says which of the two it is.
#
# Every bug this file has caught was real:
#   * a broken symlink slipped past an `[ -e ]` guard (-e follows the link);
#   * the leak check never saw untracked files (plain `git grep` is tracked-only);
#   * its own restore trap was installed before the dirty-tree guard, so refusing to run
#     still ran `git checkout --` and discarded uncommitted work;
#   * the state/handler check matched `spec` against the `spec-review` heading, so it passed
#     while the very defect it was written for was present.
#
# Requires a clean working tree, INCLUDING untracked files under the paths it restores:
# the restore uses `git checkout --`, which cannot bring back a file that was never in git.
# Run: make check-test
#
# This suite invokes `bash scripts/check.sh` directly, NOT `make check`. The two diverged when
# `make check` began also running the driver, flow, adapter and policy suites (see the Makefile):
# check-test proves check.sh's STATIC assertions fire, so it must not itself be gated on a test
# suite passing, nor pay those suites' runtime on every one of its ~60 probes. The deliberate
# exceptions all use `make check` on purpose: the final "green after restore" check, and the probes
# that prove `make check` actually RUNS each suite it names (30, 30b, 30c, 30d, 30e) — one per
# suite in the `check:` recipe, because check 12 accepts either Makefile target and so cannot see
# a suite that has quietly moved out of the per-commit gate.
set -uo pipefail
cd "$(dirname "$0")/.."

CORE=plugins/ship/skills/ship/SKILL.md
TESTS_DIR=plugins/council/skills/council/tests
RUNNER=$TESTS_DIR/run-all.sh
# The Makefile is guarded like the rest: check 12's probes mutate it (they delete a suite's
# invocation, and one removes the file), so the dirty-tree guard must refuse to run over
# uncommitted Makefile work and the restore must bring it back. Every one of those probes reverts
# with `git checkout --`, so an interrupt between the mutation and the revert is recovered by the
# trap rather than leaving the repo without a working `make check`.
#
# `.github` joined for the same reason and on the same rule: check 13's probes mutate the
# check-test workflow, so an interrupt between a mutation and its revert would otherwise leave the
# repo with a broken or empty CI file and nothing to put it back.
#
# THIS LIST IS ALSO READ BY THE GATE. check.sh check 13 derives the check-test job's pull-request
# path filter from it, so adding an entry here is a change the gate will insist you finish. And
# the assertion at the very bottom of this file asserts the whole tree is clean when the run ends,
# which is what keeps the list honest in the other direction: a probe that mutates a path outside
# it reds the run that added it, instead of the next person's.
GUARDED='.claude .agents plugins scripts .claude-plugin shared Makefile .github'

# Built from code points rather than written out, for the reason enprobe gives below: a literal
# would put the very bytes under test into this file. `ö` is Latin, so check 8 permits it either
# way -- what is under test is git's C-quoting, which fires on any byte >= 0x80.
NONASCII=$(printf '_probe-n\303\266n')
# Untracked probe files: `git checkout --` cannot bring these back OR take them away, so an
# interrupt between writing one and its inline rm would leave it. A stray t99-probe.sh reds the
# gate on its own assertion and then blocks the next run on the dirty-tree guard below. Named ONCE
# here because two readers need the list: the restore removes these paths, and the entry guard
# names any it finds as this file's own leftovers rather than as a repository violation (#136).
PROBE_FILES=(
  docs/_probe.md docs/stray .claude/skills/_probe-local
  plugins/ship/skills/_probe-skill .claude/skills/_probe-skill .agents/skills/_probe-skill
  .claude/skills/_probe-tracked plugins/ship/skills/_probe-pkg plugins/ship/skills/ship/_probe.sh
  ".claude/skills/$NONASCII" ".agents/skills/$NONASCII" "plugins/ship/skills/$NONASCII"
  plugins/hollow
  "$TESTS_DIR/t99-probe.sh" "$TESTS_DIR/t98-unregistered.sh" "$TESTS_DIR/nested"
  shared/driver/tests/_probe-unreg.sh plugins/shipyard/skills/shipyard/tests/_probe-unreg.sh
  shared/flow/tests/_probe-unreg.sh shared/flow/extra.sh
  shared/adapters/tests/_probe-unreg.sh shared/policy/tests/_probe-unreg.sh
  shared/knobs/tests/_probe-unreg.sh
  plugins/shipyard/skills/shipyard/tests/t1-probe-dup.sh "$TESTS_DIR/t1z-probe.sh"
  plugins/_probe-scratch plugins/_probe-scratch-empty
  plugins/ship/skills/ship/references/_probe-scratch plugins/ship/skills/ship/references/_probe-dangling.md
  plugins/ship/skills/ship/references/_probe-ignored.md
  plugins/_probe-link
  # No probe writes this any more (#58); a run of the version before, killed inside 36g, did, and
  # listing it keeps that one leftover named and recoverable rather than a bare `BASELINE DIRTY`.
  docs/_probe-note.md
)

# THE RUN MARKER (#136). While a run is in flight its probes are in the tree, and from outside a
# live probe and one a killed run left behind are the same file with the same edit. That cost a
# supervisor a wrong revert: a probe applied to a Makefile was read as a leftover and reverted in
# the middle of the run that owned it. So a run holds this file from just before its trap is armed
# until the trap has restored, recording its pid and start time. A reader tells the two apart with
# `ps -p <pid>`: the pid alive and running this script means live; the file present and the pid
# gone means the run was killed (SIGKILL, which no trap can catch) and what it left is stale.
# It lives in the worktree's own git directory, so it is never committed, never shows in
# `git status` (which the end-of-run assertion reads), and each worktree has its own.
# ONE WINDOW WHERE IT DOES NOT HOLD: section 36 below proves these arms by faking a dead run's
# marker for a nested run, then letting that run's --recover remove it, and rewrites this run's
# own marker only when it is done. During those few seconds the file names a dead pid, or is
# absent, while this run is live — and one of those probes edits the Makefile with no marker at
# all, so a run SIGKILLed right there leaves an edit --recover will not claim as its own.
MARKER=$(git rev-parse --git-path check-test.running)

restore() {
  # A probe that exports a throwaway index may be interrupted before it unsets it, and restoring
  # against that index would check out whatever it holds and lose whatever it lacks.
  unset GIT_INDEX_FILE
  # shellcheck disable=SC2086
  git checkout -- $GUARDED 2>/dev/null || true
  # Only the entries this test replaces, never a whole directory.
  for s in .claude/skills .agents/skills; do
    rm -rf "$s/ship" "$s/shipyard" 2>/dev/null || true
  done
  # shellcheck disable=SC2086
  git checkout -- $GUARDED 2>/dev/null || true
  rm -rf "${PROBE_FILES[@]}" ${SCRATCH:+"$SCRATCH"} 2>/dev/null || true
  rmdir docs 2>/dev/null || true
  # Last, so the marker says "in progress" for as long as anything of this run is in the tree.
  rm -f "$MARKER"
}

# A marker whose pid is still running THIS script is a live run: refuse, and say that its fixtures
# must be left alone. The command is checked as well as the pid, so a pid the system has since
# reused for something else reads as the dead run it is.
prev=""
if [ -f "$MARKER" ]; then
  prev_pid=$(sed -n 's/^pid=\([0-9][0-9]*\)$/\1/p' "$MARKER" | head -1)
  prev_started=$(sed -n 's/^started=//p' "$MARKER" | head -1)
  if [ -n "$prev_pid" ] && ps -p "$prev_pid" -o command= 2>/dev/null | grep -q 'check-test\.sh'; then
    echo "refusing to run: a check-test run is in progress in this worktree (pid $prev_pid, started ${prev_started:-unknown})" >&2
    echo "the probe fixtures in the tree are that run's LIVE probes, not leftovers: do not revert them; it restores them itself" >&2
    exit 2
  fi
  prev="a check-test run in this worktree did not finish (pid ${prev_pid:-unknown}, started ${prev_started:-unknown}, no longer running)"
fi
left_over=()
for p in "${PROBE_FILES[@]}"; do
  if [ -e "$p" ] || [ -L "$p" ]; then left_over+=("$p"); fi
done
explain_leftovers() {
  if [ -n "$prev" ]; then echo "$prev" >&2; fi
  if [ "${#left_over[@]}" -gt 0 ]; then
    echo "check-test's own probe fixtures are in the tree, left by a run that did not finish — not a repository violation:" >&2
    printf '  %s\n' "${left_over[@]}" >&2
  else
    # A probe's edit to a TRACKED file looks like anybody's edit, so a marker alone does not say
    # whose the changes are, and --recover would discard them either way.
    echo "no probe fixture was found, so the changes listed may be that run's probe edits or your own work" >&2
  fi
  echo "inspect them, then 'bash scripts/check-test.sh --recover' restores $GUARDED and removes the probe files (it discards every change listed)" >&2
}

# --recover: the restore a killed run never got to, run on request. It refuses a live run above,
# like any other invocation, and discards what it lists, which is why it is never run implicitly.
if [ "${1:-}" = "--recover" ]; then
  # shellcheck disable=SC2086
  dirty=$(git status --porcelain --untracked-files=all -- $GUARDED)
  if [ -z "$prev" ] && [ "${#left_over[@]}" -eq 0 ]; then
    if [ -n "$dirty" ]; then
      # Nothing marks these as a run's leftovers, so they are treated as the user's work.
      echo "refusing to recover: no marker of an unfinished run and no probe fixture, so the changes under $GUARDED are not assumed to be check-test's:" >&2
      printf '%s\n' "$dirty" >&2
      exit 2
    fi
    echo "nothing to recover: no marker of an unfinished run, no probe fixture and no change under $GUARDED"
    exit 0
  fi
  echo "recovering: restoring $GUARDED and removing check-test's probe files; discarding:"
  if [ -n "$dirty" ]; then printf '%s\n' "$dirty"; fi
  if [ "${#left_over[@]}" -gt 0 ]; then printf '  %s\n' "${left_over[@]}"; fi
  SCRATCH=""
  restore
  echo "recovered"
  exit 0
fi

# The guard comes FIRST and the trap is installed only after it passes. Installing the trap
# earlier makes the guard's own early exit run the restore, which would discard exactly the
# uncommitted work the guard exists to protect. `--untracked-files=all` is the other half:
# `git diff` cannot see an untracked file, so without it a local unversioned skill under
# .claude/skills is invisible here and destroyed by the restore below.
# shellcheck disable=SC2086
dirty=$(git status --porcelain --untracked-files=all -- $GUARDED)
if [ -n "$dirty" ]; then
  echo "refusing to run: uncommitted or untracked changes under $GUARDED" >&2
  printf '%s\n' "$dirty" >&2
  if [ -n "$prev" ] || [ "${#left_over[@]}" -gt 0 ]; then
    explain_leftovers
  else
    echo "this test restores with 'git checkout --', which cannot recover untracked files" >&2
  fi
  exit 2
fi
# A leftover outside $GUARDED passes the guard above (`docs/` is untracked, so it cannot be in that
# list), and would otherwise surface as `BASELINE DIRTY`, which reads as the repository being in a
# bad state rather than as this script's previous run having died.
if [ "${#left_over[@]}" -gt 0 ]; then
  echo "refusing to run:" >&2
  explain_leftovers
  exit 2
fi
if [ -n "$prev" ]; then echo "note: $prev; nothing it left was found in the tree"; fi

# The tree as it was ADMITTED, so the assertion at the bottom reports what this run changed
# rather than what it found. The entry guard above is scoped to $GUARDED and the assertion is
# not — deliberately, since its whole job is to catch a probe mutating something OUTSIDE that
# list — and without this snapshot the two scopes disagree: an uncommitted AGENTS.md or
# .planning/ edit (an ordinary state here) is admitted at the start and then blamed on a probe
# five minutes later, with the remedy line naming the wrong fix. An alarm that fires on the
# normal case is one the reader learns to ignore.
PRE_STATUS=$(git status --porcelain --untracked-files=all)

SCRATCH=$(mktemp -d)
write_marker() {
  printf 'pid=%s\nstarted=%s\n' "$$" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"
}
write_marker
trap restore EXIT
# Measured on bash 3.2 and 5.x: the EXIT trap already runs on HUP, INT and TERM, but an INT exits
# 0. These make the exit status name the signal and keep the restore from resting on that
# behaviour. SIGKILL cannot be trapped; the marker above is what covers it. No probe below covers
# these traps, since one would have to signal a full nested run; they were checked by hand.
trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM

pass=0; nocatch=0
# $1 is the label. $2, OPTIONAL, is a fixed string the gate's output must contain.
#
# Without $2 a probe asserts only that SOMETHING reddened, and that is not enough wherever two
# arms are layered so that the outer one catches whatever the inner one would. Check 10 has
# exactly that shape: a missing runner means no test list, and no test list means every test on
# disk reads as unregistered — so deleting the inner arm still reds, on the neighbour, and the
# probe keeps reporting `caught` over an assertion that no longer exists. Both of check 10's
# diagnostic arms were vacuous in this way when they were written, and nothing said so.
#
# Pass $2 for any probe whose arm has a neighbour that can substitute for it — and when unsure,
# pass it: a pin costs nothing, and the absence of one is exactly how arms once sat here with no
# kill test, reported `caught` over a neighbour's red (#58). Do not read a missing $2 as evidence
# that a probe does not need one.
#
# Separately, some arms have no probe at all. They are not listed here: each carries an `UNPROBED:`
# comment on the line above it in check.sh, so `grep -n UNPROBED: scripts/check.sh` is the list, and
# a new unprobed arm joins it by being marked where it is written rather than by someone updating a
# count in this file (a count here went stale on the next addition, #58). The ones marked today are
# per-item "this matcher errored" arms whose only trigger is an unreadable file, which is a no-op
# when the gate runs as root, so they cannot be probed portably. Their siblings that error on a
# LISTING rather than a per-item read are probed (for example 14a, 21, 32f, 34f, 37g), because a
# listing's exit status can be forced directly.
expect_fail() {
  if bash scripts/check.sh >"$SCRATCH/out" 2>&1; then
    echo "NOT CAUGHT: $1"; nocatch=$((nocatch+1))
  elif [ -n "${2:-}" ] && ! grep -qF -- "$2" "$SCRATCH/out"; then
    # Reddened, but on a different assertion than the one this probe names: the named arm is
    # unproven, which is the same result as NOT CAUGHT and must not be reported as a pass.
    echo "WRONG ARM:  $1"
    echo "            expected: $2"
    echo "            got:      $(grep -m1 '^FAIL' "$SCRATCH/out" | cut -c1-70)"
    nocatch=$((nocatch+1))
  else
    echo "caught:     $1   ->  $(grep -m1 '^FAIL' "$SCRATCH/out" | cut -c1-80)"
    pass=$((pass+1))
  fi
}

# The mirror of expect_fail, for the cases where the gate must NOT red. $1 is the label. $2,
# OPTIONAL, is a fixed string the GREEN output must contain — the mirror of expect_fail's pin, and
# needed for the same reason: exit status alone cannot tell "the check correctly ignored this"
# from "the check, and everything it was supposed to say about it, is gone". The note check 5
# prints is the only output in this gate that no `fail` arm backs, so it is the one thing here
# that can rot in total silence.
expect_pass() {
  if ! bash scripts/check.sh >"$SCRATCH/out" 2>&1; then
    echo "REDDENED:   $1   ->  $(grep -m1 '^FAIL' "$SCRATCH/out" | cut -c1-80)"
    nocatch=$((nocatch+1))
  elif [ -n "${2:-}" ] && ! grep -qF -- "$2" "$SCRATCH/out"; then
    echo "MISSING:    $1"
    echo "            expected in the green output: $2"
    nocatch=$((nocatch+1))
  elif [ -n "${3:-}" ] && grep -qF -- "$3" "$SCRATCH/out"; then
    # $3 is the mirror of $2: a string the green output must NOT contain. Part of what this gate
    # does is DECLINE to say something, and a presence pin cannot express that -- a probe for it
    # would report green whether the line appeared or not.
    echo "UNWANTED:   $1"
    echo "            must not appear in the green output: $3"
    nocatch=$((nocatch+1))
  else
    echo "green:      $1"
    pass=$((pass+1))
  fi
}

if bash scripts/check.sh >"$SCRATCH/out" 2>&1; then
  echo "clean:      baseline"; pass=$((pass+1))
else
  echo "BASELINE DIRTY — the gate fails before any violation is injected:"
  cat "$SCRATCH/out"; exit 1
fi

link() { ln -sfn "../../plugins/$1/skills/$1" "$2/$1"; }

# 1 — shell syntax
printf 'if true; then\n' >> plugins/shipyard/skills/shipyard/shipyard-lib.sh
expect_fail "broken shell syntax"
git checkout -- plugins/shipyard/skills/shipyard/shipyard-lib.sh

# 2 — a skill's frontmatter name disagrees with its directory
perl -pi -e 's/^name: ship$/name: shipp/' "$CORE"
expect_fail "skill name != directory"
git checkout -- "$CORE"

# 3a — one of the two plugin manifests is missing
rm plugins/ship/.codex-plugin/plugin.json
# Pinned (#58): with the guard's `continue` gone, the JSON arm below reds on the same file.
expect_fail "missing .codex-plugin manifest" "missing manifest: plugins/ship/.codex-plugin/plugin.json"
git checkout -- plugins/ship/.codex-plugin/plugin.json

# 3b — a manifest's name disagrees with its directory
perl -pi -e 's/"name": "ship"/"name": "shipx"/' plugins/ship/.claude-plugin/plugin.json
expect_fail "manifest name != directory" "manifest name 'shipx' != directory 'ship'"
git checkout -- plugins/ship/.claude-plugin/plugin.json

# 3c — invalid JSON
printf 'oops' >> plugins/ship/.claude-plugin/plugin.json
# Pinned (#58): with the guard's `continue` gone, the name arm reds on the same file.
expect_fail "invalid JSON in a plugin manifest" "invalid JSON: plugins/ship/.claude-plugin/plugin.json"
git checkout -- plugins/ship/.claude-plugin/plugin.json

# 3d — the two manifests of one plugin declare different versions (#20), and one declares none.
# Pinned: nothing else in check 3 reads the version, but a pin is what says which arm fired.
perl -pi -e 's/"version": "[^"]*"/"version": "99.0.0"/' plugins/ship/.codex-plugin/plugin.json
expect_fail "the two manifests of a plugin carry different versions" \
  "the two manifests of plugin 'ship' carry different versions"
git checkout -- plugins/ship/.codex-plugin/plugin.json
perl -ni -e 'print unless /"version":/' plugins/ship/.claude-plugin/plugin.json
expect_fail "a plugin manifest declares no version" \
  "manifest declares no version string: plugins/ship/.claude-plugin/plugin.json"
git checkout -- plugins/ship/.claude-plugin/plugin.json

# 4a — a marketplace entry pointing at a directory that does not exist, with the basename
# still matching the entry name, so ONLY the existence branch can fire.
perl -pi -e 's{"source": "./plugins/ship"}{"source": "./plugins/gone/ship"}' .claude-plugin/marketplace.json
expect_fail "marketplace entry -> missing directory" "points at missing dir 'plugins/gone/ship'"
git checkout -- .claude-plugin/marketplace.json

# 4b — an entry pointing at a real directory under a DIFFERENT name, so only the
# name-agreement branch can fire. Split from 4a because one probe tripping both branches
# proves neither: deleting either check would leave the assertion passing.
perl -pi -e 's{"source": "./plugins/ship"}{"source": "./plugins/shipyard"}' .claude-plugin/marketplace.json
expect_fail "marketplace entry -> differently-named directory" "points at differently-named dir 'plugins/shipyard'"
git checkout -- .claude-plugin/marketplace.json

# 4c — the two marketplace manifests disagree about which plugins exist. Drop an entry
# entirely rather than renaming one: a rename also trips the per-entry name check, and a
# probe that fires two checks at once proves neither.
python3 - <<'PY'
import json
p = ".agents/plugins/marketplace.json"
d = json.load(open(p))
d["plugins"] = d["plugins"][:1]
json.dump(d, open(p, "w"), indent=2)
PY
expect_fail "the two marketplace manifests list different plugins" "the two marketplace manifests list different plugins"
git checkout -- .agents/plugins/marketplace.json

# 5a — an entry COMMITTED under a project skills directory as something other than a symlink,
# i.e. a second copy in the making. This is ALSO the probe that keeps checks 1 and 2's exemption
# from being a hole: that exemption turns on `git ls-files --error-unmatch`, and this entry is in
# the index, so it must still red.
#
# The assertion reads the INDEX, and the restore trap's `git checkout --` cannot undo a staged
# add — the destructive shape the guard at the top of this file exists to prevent. So the entry
# goes into a THROWAWAY index: git reads whatever GIT_INDEX_FILE names, so a copy of the real one
# can be given a fake entry and discarded. Measured: the repo's own index stays byte-identical and
# the working tree stays clean, so an interrupt leaves nothing but a scratch file. The blob is
# hashed WITHOUT `-w`, so nothing reaches the object database either — check.sh reads the working
# tree, never the blob. Unlike a widened pathspec this exercises the real directories, so nothing
# here rests on the assertion being pointed at the right place.
cp "$(git rev-parse --git-path index)" "$SCRATCH/fake-index"
mkdir -p .claude/skills/_probe-tracked
# `name:` disagrees with the directory ON PURPOSE. Checks 1 and 2 exempt an entry here only while
# it is UNTRACKED, and this one is in the index -- so the same fixture proves the mode arm fires
# AND that the exemption stayed untracked-only. With a conforming fixture that second half was
# unprovable: measured, deleting the `--error-unmatch` line (exempting by DIRECTORY alone, the
# wrong summary check.sh warns about) left the whole suite reporting every assertion proven.
printf -- '---\nname: totally-different\ndescription: A probe skill.\n---\n' \
  > .claude/skills/_probe-tracked/SKILL.md
GIT_INDEX_FILE="$SCRATCH/fake-index" git update-index --add --cacheinfo \
  "100644,$(git hash-object .claude/skills/_probe-tracked/SKILL.md),.claude/skills/_probe-tracked/SKILL.md"
export GIT_INDEX_FILE="$SCRATCH/fake-index"
expect_fail "committed non-symlink under a project skills dir" "committed but not a symlink"
expect_fail "committed SKILL.md there is still read by check 2" \
  "skill name 'totally-different' != directory '_probe-tracked'"
unset GIT_INDEX_FILE
rm -rf .claude/skills/_probe-tracked

# 5b — a broken symlink. `[ -e ]` follows the link, so this is the case that once slipped.
ln -sfn ../../plugins/ship/skills/gone .claude/skills/ship
expect_fail "broken dogfooding symlink" "broken symlink"
link ship .claude/skills

# 5c — a symlink that resolves OUTSIDE the repo but whose text contains `/plugins/`, which a
# substring check would accept. An agent opened in a clone would read that as instructions.
mkdir -p "$SCRATCH/plugins/ship/skills/ship"
cp "$CORE" "$SCRATCH/plugins/ship/skills/ship/SKILL.md"
ln -sfn "$SCRATCH/plugins/ship/skills/ship" .claude/skills/ship
expect_fail "symlink target outside the repo" "symlink target is outside this repo's plugins/"
link ship .claude/skills

# 5d — a packaged skill with no symlink at all. Removing the link leaves the INDEX entry
# behind, so check 5's own "broken symlink" arm reds too; $2 is what keeps this probe reporting
# on the arm it names rather than on that neighbour.
rm .agents/skills/shipyard
expect_fail "packaged skill with no dogfooding symlink" "has no symlink at"
link shipyard .agents/skills

# 6a — a pipeline state name copied into a per-forge reference file
printf '\nStages: need-issue then ready-to-merge.\n' >> plugins/ship/skills/ship/references/forge-github.md
expect_fail "state enum copied into a forge reference" "forge reference carries the state name 'need-issue'"
git checkout -- plugins/ship/skills/ship/references/forge-github.md

# 6b — a state in the enum with no handler. `spec` is the real historical case: it is a
# PREFIX of `spec-review`, so an unanchored check passes and proves nothing.
perl -pi -e 's{"state": "need-issue\|issue-ready\|}{"state": "need-issue|issue-ready|spec|}' "$CORE"
expect_fail "enum state with no §7 handler" "state 'spec' is in the enum but has no"
git checkout -- "$CORE"

# 6c — a state the core enters but never tells the run to RECORD, which is how a stage becomes
# invisible to the supervisor's table (#124). `archive` is the fixture because it occurs exactly
# once; the arm is pinned by message because the enum-derivation arm above it reds on the same
# file and would otherwise substitute for it.
perl -pi -e 's/record state=archive/state=archive/' "$CORE"
expect_fail "enum state never recorded" 'never says `record state=archive`'
git checkout -- "$CORE"

# 6d — the kill test for 6c's ANCHOR, which 6c itself cannot provide: `archive` is a prefix of
# nothing, so dropping the arm's trailing backtick leaves 6c passing. This adds a state that IS a
# prefix of a recorded one (`spec` before `spec-review`) and records none of it. Unanchored, the
# grep finds `record state=spec-review` and the gate goes green over a state nothing records;
# anchored, it reds.
#
# The `### 7.Z` handler is what keeps this probe pointed at ONE arm. Without it 6b's neighbouring
# no-handler arm reds too, and a probe that fires two arms proves neither — the first version of
# this probe renamed an existing heading to `7.CC`, which that arm's `^### 7\.[A-Z] — ` regex
# rejects, so it reported `caught` off the wrong assertion.
perl -pi -e 's{"state": "need-issue\|issue-ready\|}{"state": "need-issue|issue-ready|spec|}' "$CORE"
perl -pi -e 's{^## 8\. }{### 7.Z — `spec`\n\nA probe handler, so only the recording arm can red.\n\n## 8. }' "$CORE"
expect_fail "enum state satisfied only by a longer name" 'never says `record state=spec`'
git checkout -- "$CORE"

# 7 — the leak check: ONE probe per structural pattern, so a typo in any single alternative
# cannot ship silently. The probe file is UNTRACKED on purpose: that is the state a leak is
# in when `make check` runs just before `git add`. Every fixture is invented.
mkdir -p docs
probe() {
  printf '%s\n' "$1" > docs/_probe.md
  expect_fail "leak: $2"
  rm -f docs/_probe.md
}
probe '/Users/someone/secret/path'          'absolute home path (macOS)'
probe '/home/someone/secret/path'           'absolute home path (Linux)'
# The same two roots separator-encoded (#122). These are kill tests for the NEW arm only: the
# fixtures carry no `/Users/` or `/home/`, so no other alternative can substitute for it — and the
# two probes above are the kill tests for the pre-existing slash arm, which this change leaves
# untouched. Both arms therefore stay proven; deleting either reds here. The first fixture starts
# at the line boundary to exercise the `(^|...)` branch, the second sits after a `/` the way a real
# flattened path does.
probe '-Users-someone-work-project/state.json' 'encoded home path (macOS)'
probe 'projects/-home-someone-work-project/log' 'encoded home path (Linux)'
# ...and with the home root BELOW the filesystem root (#126), the two layouts that issue measured
# passing green: a home under `/var/home/`, and the macOS data-volume path a resolved path prints.
# Neither fixture carries `/Users/` or `/home/`, and neither has a separator in front of its root
# component, so only the widened intermediate-component part of the arm can catch them.
probe 'projects/-var-home-someone-work-proj/session.jsonl' 'encoded home path below the root (var/home)'
probe '-System-Volumes-Data-Users-someone-proj' 'encoded home path below the root (data volume)'
probe 'someone@example.invalid'             'e-mail address'
probe 'run ~/.local/bin/mytool'             'personal bin path'
probe 'CFG=$HOME/.config/gh-someone'        'personal tool config dir'
probe 'ghp_AbCdEfGhIjKlMnOpQrStUvWx'        'GitHub token'
probe 'glpat-AbCdEfGhIjKlMnOpQrSt'          'GitLab token'
probe 'xoxb-AbCdEfGhIjKlMnOpQrSt'           'Slack token'
probe '-----BEGIN RSA PRIVATE KEY-----'     'private key header'
probe "date TZ=Europe/Somewhere"            'hardcoded timezone'

# And the other direction for the same arm: the encoded form is a hyphen-separated word sequence,
# so the bounds must not red on ordinary hyphenated English or on a double-dash long flag. A
# SINGLE-dash long option is deliberately not in this fixture, because it does red and check.sh
# says why. No pin is needed on this one — "the arm was deleted" is already excluded by the red
# probes above, so green here can only mean the bounds held. The last two phrases pin the bound
# the #126 widening must keep: a hyphenated phrase with SEVERAL words before the root, and a
# double-dash flag with a word before it, both of which a start-of-token bound that let the
# intermediate components begin anywhere would red.
printf '%s\n' 'a per-users-quota note, a nav-home-link class, --users-file and --home-dir' \
  'the site-wide-nav-home-link and --no-home-dir' > docs/_probe.md
expect_pass "leak: hyphenated prose and double-dash long flags are not encoded home paths"
rm -f docs/_probe.md

# 7b — English everywhere: the script check. Each fixture is BUILT from code points instead
# of being written out, because a literal would put a violation into this very file — and
# check 8, unlike the leak check, deliberately exempts nothing under scripts/.
enprobe() {
  printf '%b\n' "$1" > docs/_probe.md
  expect_fail "non-Latin script: $2"
  rm -f docs/_probe.md
}
enprobe '\u043f\u0440\u0438\u0432\u0435\u0442'  'Cyrillic'
enprobe '\u03b1\u03b2\u03b3'                      'Greek'
enprobe '\u6f22\u5b57'                             'Han'
enprobe '\u0641\u0642'                             'Arabic'
rmdir docs 2>/dev/null || true

# 8 — the assertions the gate is most easily made vacuous by, and which the review noted were
# themselves untested: the leak check and the English check each failing LOUDLY rather than open
# when they cannot scan, and the dual-agent manifest/disk invariant.
sed -i.bak 's/^deny=.\/Users/deny='"'"'(unclosed/' scripts/check.sh
expect_fail "leak check fails LOUDLY on a broken pattern (not open)"
mv scripts/check.sh.bak scripts/check.sh

# And check 8's own "could not run" arm, which had no probe while its neighbour above did. Same
# technique: break its PCRE to an invalid one, so `git grep -P` exits 128 on every file and only
# the error arm can fire. Without this the arm is vacuous — reverting the check to a bare
# `if [ "$g" -eq 0 ]` would read the error as "no violation" and still pass check-test.
cp scripts/check.sh "$SCRATCH/check8.bak"
perl -pi -e 's/\\p\{Cyrillic\}/(unclosed/' scripts/check.sh
expect_fail "English check fails LOUDLY when git grep errors (not open)"
cp "$SCRATCH/check8.bak" scripts/check.sh

python3 - <<'PY'
import json
for p in (".claude-plugin/marketplace.json", ".agents/plugins/marketplace.json"):
    d = json.load(open(p))
    d["plugins"] = [e for e in d["plugins"] if e.get("name") != "shipyard"]
    json.dump(d, open(p, "w"), indent=2)
PY
expect_fail "marketplace plugins do not match plugins/ on disk" "marketplace plugins do not match plugins/ on disk"
git checkout -- .claude-plugin .agents/plugins

# 9 — SKILL.md frontmatter: each field, and a skill tracked outside plugins/
perl -0pi -e 's/^---\nname: ship\n/---\nnome: ship\n/' "$CORE"
# Pinned (#58): the name-vs-directory arm reds on the same edit (`'' != directory`).
expect_fail "SKILL.md with no name:" "no name: $CORE"
git checkout -- "$CORE"

perl -pi -e 's/^description: "Drive one change/descriptio: "Drive one change/' "$CORE"
expect_fail "SKILL.md with no description:" "no description: $CORE"
git checkout -- "$CORE"

# Outside .claude/skills and .agents/skills on purpose — check 5 exempts those two paths from
# this loop, so a probe placed there would red NOTHING and report `NOT CAUGHT`. (It used to be the
# opposite problem: the old filesystem-driven check 5 caught it first, on the wrong arm. The
# placement is right either way, but the reason inverted, and the `expect_pass` probe at the end
# of this file now asserts precisely that a SKILL.md there stays green.)
mkdir -p docs/stray
printf -- '---\nname: stray\ndescription: A stray skill outside plugins/.\n---\n' \
  > docs/stray/SKILL.md
expect_fail "SKILL.md outside plugins/" "SKILL.md outside plugins/"
rm -rf docs/stray

# 10 — a plugin with manifests but no skills tree, then one with an empty skills tree. Both
# manifests carry the same version, so check 3d cannot be the arm that reds. Each is pinned (#58):
# an unregistered plugin also reds the manifests-vs-disk arm, and the missing tree reds the
# empty-tree arm too, so unpinned, deleting either arm left its probe reporting `caught`.
mkdir -p plugins/hollow/.claude-plugin plugins/hollow/.codex-plugin
printf '{"name":"hollow","version":"0.1.0","description":"d"}\n' > plugins/hollow/.claude-plugin/plugin.json
printf '{"name":"hollow","version":"0.1.0","description":"d","skills":"./skills/"}\n' > plugins/hollow/.codex-plugin/plugin.json
expect_fail "plugin with no skills/ directory" "plugin has no skills/ directory: plugins/hollow"
mkdir -p plugins/hollow/skills
expect_fail "plugin with an empty skills/ directory" "plugin has no skills/<skill>/SKILL.md: plugins/hollow"
rm -rf plugins/hollow

# 11 — the remaining gate assertions, so that "every assertion" is literally true
perl -0pi -e 's/\A---\n/name: ship\n/' "$CORE"
expect_fail "SKILL.md with no frontmatter" "frontmatter missing: $CORE"
git checkout -- "$CORE"

# Both pinned (#58): each also leaves the two manifests listing different plugins, which reds on
# its own, so unpinned neither probe could tell its arm from that neighbour.
mv .agents/plugins/marketplace.json "$SCRATCH/mp.json"
expect_fail "missing marketplace manifest" "missing marketplace manifest: .agents/plugins/marketplace.json"
mv "$SCRATCH/mp.json" .agents/plugins/marketplace.json

printf 'oops' >> .agents/plugins/marketplace.json
expect_fail "invalid JSON in a marketplace manifest" "invalid JSON: .agents/plugins/marketplace.json"
git checkout -- .agents/plugins/marketplace.json

# Moving the directory leaves its index entries behind, so check 5's link assertions and the
# packaged-skill loop red as well; $2 pins this probe to the arm it names.
mv .agents/skills "$SCRATCH/agents-skills"
expect_fail "missing project skills dir" "missing project skills dir"
mv "$SCRATCH/agents-skills" .agents/skills

perl -pi -e 's/^  "state": "need-issue/  "sate": "need-issue/' "$CORE"
expect_fail "state enum not found in the core skill" "cannot find exactly one state enum"
git checkout -- "$CORE"

# 12 — a council test that builds its room at a path fixed by its own name. This is the shape
# every test had before the run root existed, so it is the shape a new test copied from an old
# checkout would carry. Untracked, so the restore cannot remove it: delete it explicitly.
#
# Registered in the runner as well, so that ONLY check 9 can fire: an unregistered probe file
# also trips check 10, and a probe that fires two checks at once proves neither.
perl -pi -e 's{^tests=\(}{tests=(t99-probe.sh }' "$RUNNER"
cat > "$TESTS_DIR/t99-probe.sh" <<'PROBE'
#!/usr/bin/env bash
R="${TMPDIR:-/tmp}/council-test/t99"; rm -rf "$R"
PROBE
expect_fail "council test naming a fixed temp room path"
rm -f "$TESTS_DIR/t99-probe.sh"
git checkout -- "$RUNNER"

# 12b — the exemption for the two non-test files applies to the path RELATIVE to the tests
# directory, not to the basename. The pathspec crosses directories, so under a basename match a
# `nested/run-all.sh` carrying the very shape check 9 exists to catch was skipped and the gate
# stayed green. Registered, again so only check 9 can fire.
perl -pi -e 's{^tests=\(}{tests=(nested/run-all.sh }' "$RUNNER"
mkdir -p "$TESTS_DIR/nested"
cat > "$TESTS_DIR/nested/run-all.sh" <<'PROBE'
#!/usr/bin/env bash
R="${TMPDIR:-/tmp}/council-test/nested"; rm -rf "$R"
PROBE
expect_fail "nested run-all.sh exempted by basename alone"
rm -rf "$TESTS_DIR/nested"
git checkout -- "$RUNNER"

# 13 — and check 9 must fail LOUDLY when grep cannot scan, not read the error as "no violation".
# Same technique as the leak-check probe above: break the check's own pattern to an invalid ERE,
# so grep exits >1 on every file and only the error arm can fire. Without this probe the arm is
# vacuous — reverting it to the old `grep -q ... && fail` one-liner still passes check-test.
cp scripts/check.sh "$SCRATCH/check9.bak"
perl -pi -e "s/'TMPDIR\|council-test'/'(unclosed'/" scripts/check.sh
expect_fail "council-test scan fails LOUDLY when grep errors (not open)"
cp "$SCRATCH/check9.bak" scripts/check.sh

# 14 — and the same two failure modes one level UP, in check 9's file listing, which is where
# they hid while the grep arm above was already probed. Both are edited into check.sh rather
# than reproduced for real (by renaming the tests directory) on purpose: an interrupted run
# leaves only a modified script, which the restore trap's `git checkout --` undoes, whereas an
# interrupted `git mv` leaves a renamed directory staged in the index that it cannot undo.
#
# 14a — the listing itself errors. `exit 128` inside the command substitution, and NOT the
# obvious broken pathspec: a bad pathspec makes git fatal before printing anything, so the empty
# listing lands on 14b's arm and the probe still reds with the listing arm DELETED — vacuous, and
# caught by the wrong assertion's message. Forcing the status while leaving the output intact
# keeps the listing non-empty, so the zero-count arm cannot explain the failure and only the
# listing arm can. It is also the one case the counter can never see: paths emitted, then a
# non-zero exit — which no real `git ls-files` produces, but the arm keys on the status alone.
#
# The injection is in the SHARED list_suite_tests, so ONE broken listing feeds BOTH check 9
# (council) AND check 10's per-suite loop. That means this one fixture proves two arms — and each
# needs its OWN $2 pin, or it slides onto the other: with no pin, deleting check 9's arm still reds
# via check 10's `could not list tests under`, and deleting check 10's arm still reds via check 9's
# `could not list council tests`. Two pinned assertions over the one injection close both.
cp scripts/check.sh "$SCRATCH/check9-list.bak"
perl -pi -e 's{"\$dir/\*\.sh"\)}{"\$dir/*.sh"; exit 128)}' scripts/check.sh
expect_fail "check 9 listing fails LOUDLY when git ls-files errors (not open)" \
  "could not list council tests"
expect_fail "check 10 listing fails LOUDLY when git ls-files errors (not open)" \
  "could not list tests under"
cp "$SCRATCH/check9-list.bak" scripts/check.sh

# 14b — the listing succeeds and matches nothing, which is what a moved or renamed tests
# directory looks like: zero iterations, no error anywhere, and the assertion silently gone.
cp scripts/check.sh "$SCRATCH/check9-empty.bak"
perl -pi -e 's{^council_dir=plugins/council/skills/council/tests$}{council_dir=plugins/council/skills/council/tests-moved-away}' scripts/check.sh
expect_fail "council-test scan fails LOUDLY when it inspects no file at all"
cp "$SCRATCH/check9-empty.bak" scripts/check.sh

# 14c — check 10's empty-suite arm (`no test on disk under $suite_dir`), which was a no-op `:` skip
# in the council-only version and is now an active fail. Point check 10 at a real directory that
# holds no *.sh, so list_suite_tests returns empty with rc 0 — and at a NON-council one, so check 9
# (council-only) cannot fire and claim the catch. The $2 pin is load-bearing: delete this arm and
# the loop falls through to the missing-runner arm (that dir has no run-all.sh), which reds on a
# different message, so the pin reports WRONG ARM, not caught.
#
# The bogus entry is APPENDED to $GATED_SUITES rather than replacing a real one, and that matters
# now that check 12 reads the same list: replacing `shared/driver/tests` would ALSO strip a real
# suite from the declaration, so check 12's declaration arm would red too and the probe would fire
# two checks at once — which proves neither. Appending leaves all six real suites declared, so only
# check 10 reacts. `\x27` is a literal single quote, so the whole perl program stays inside shell
# single quotes.
cp scripts/check.sh "$SCRATCH/check10-empty.bak"
perl -pi -e 's{^GATED_SUITES=\x27shared/driver/tests$}{GATED_SUITES=\x27plugins/ship/skills/ship/references\nshared/driver/tests}' scripts/check.sh
expect_fail "check 10 empty-suite arm fires for a non-council suite with no tests" \
  "no test on disk under"
cp "$SCRATCH/check10-empty.bak" scripts/check.sh

# 15 — a council test on disk that the runner never runs. Untracked, which is the state it is in
# during the `make check` just before `git add`, and deliberately free of the pre-run-root shape
# so that check 9 cannot fire and claim the catch instead.
cat > "$TESTS_DIR/t98-unregistered.sh" <<'PROBE'
#!/usr/bin/env bash
R="$COUNCIL_TEST_ROOT/t98"; rm -rf "$R"
PROBE
expect_fail "council test on disk but not registered in run-all.sh" \
  "test on disk but not registered in"
rm -f "$TESTS_DIR/t98-unregistered.sh"

# 15b — the generalisation itself: an unregistered test must red for the DRIVER suite too, not only
# council. Untracked (the state a new test is in at the `make check` just before `git add`), and
# free of council's temp-path shape so check 9 (council-only) cannot fire and claim the catch. The
# $2 pin keeps it on check 10's unregistered arm.
printf '#!/usr/bin/env bash\ntrue\n' > shared/driver/tests/_probe-unreg.sh
expect_fail "driver test on disk but not registered in run-all.sh" \
  "test on disk but not registered in"
rm -f shared/driver/tests/_probe-unreg.sh

# 15c — ...and for the SHIPYARD suite.
printf '#!/usr/bin/env bash\ntrue\n' > plugins/shipyard/skills/shipyard/tests/_probe-unreg.sh
expect_fail "shipyard test on disk but not registered in run-all.sh" \
  "test on disk but not registered in"
rm -f plugins/shipyard/skills/shipyard/tests/_probe-unreg.sh

# 15d — ...and for the FLOW suite. With 15, 15b, 15c, 15e and 15f this proves the check 10 loop
# actually visits every suite, not just whichever one happens to be first. Without this probe,
# dropping shared/flow/tests from check 10's loop would go uncaught (the sibling probes still pass).
# The fixture path is already in the restore trap's cleanup list.
printf '#!/usr/bin/env bash\ntrue\n' > shared/flow/tests/_probe-unreg.sh
expect_fail "flow test on disk but not registered in run-all.sh" \
  "test on disk but not registered in"
rm -f shared/flow/tests/_probe-unreg.sh

# 15e — ...and for the ADAPTERS suite, the fifth entry in check 10's loop. Same reason as 15d: the
# sibling probes all still pass with shared/adapters/tests dropped from the list, so without this
# one the suite could stop being gated for registration and nothing would say so.
printf '#!/usr/bin/env bash\ntrue\n' > shared/adapters/tests/_probe-unreg.sh
expect_fail "adapters test on disk but not registered in run-all.sh" \
  "test on disk but not registered in"
rm -f shared/adapters/tests/_probe-unreg.sh

# 15f — ...and for the POLICY suite, which is the one that had no gated registration at all: it ran
# in no automated invocation from the day it landed, so nothing would have noticed a test dropped
# from its `tests` array either.
printf '#!/usr/bin/env bash\ntrue\n' > shared/policy/tests/_probe-unreg.sh
expect_fail "policy test on disk but not registered in run-all.sh" \
  "test on disk but not registered in"
rm -f shared/policy/tests/_probe-unreg.sh

# 15g — ...and for the KNOBS suite. WHAT THE 15* FAMILY ACTUALLY PROVES, stated once here rather
# than as a running count in each: that check 10's walk reaches each suite's own run-all.sh and
# parses its list. It is NOT what an earlier version of this comment claimed — dropping an entry
# from $GATED_SUITES is caught loudly by check 12, and by this script's own baseline guard, which
# refuses to start at all. That claim was written here and measured false one round later, which
# is a fair warning about writing a rationale without running it. Add a probe whenever
# $GATED_SUITES grows; the reason is the walk, not the declaration.
printf '#!/usr/bin/env bash\ntrue\n' > shared/knobs/tests/_probe-unreg.sh
expect_fail "knobs test on disk but not registered in run-all.sh" \
  "test on disk but not registered in"
rm -f shared/knobs/tests/_probe-unreg.sh

# 16 — and check 10 must say it cannot find the list, rather than comparing the files on disk
# against an empty set. BOTH assignments are renamed: renaming only `tests=(` leaves the `--full`
# `tests+=(` line, whose four names extract fine, so the probe would land on the unregistered arm
# instead — caught, but by the wrong assertion, which proves nothing about this one.
perl -pi -e 's/^tests=\(/TESTS=(/; s/tests\+=\(/TESTS+=(/' "$RUNNER"
expect_fail "run-all.sh test list not found (not compared against an empty set)" \
  "could not find the test list in"
git checkout -- "$RUNNER"

# 17 — and the runner itself gone. Repointed inside check.sh rather than moved for real: the
# real move trips check 1 as well, because `git ls-files --cached` still lists the file from the
# INDEX and `bash -n` then fails on the missing path — two assertions from one probe, which
# proves neither. Check 9 is unaffected either way, its exemption naming run-all.sh literally.
# The expected message is load-bearing: with no runner there is no list either, so the
# `could not find the test list` arm reds too and would report this one caught while it slept.
cp scripts/check.sh "$SCRATCH/check10-runner.bak"
perl -pi -e 's{^\s*runner=\$suite_dir/run-all\.sh$}{  runner=\$suite_dir/run-all-gone.sh}' scripts/check.sh
expect_fail "test runner missing" "test runner is missing"
cp "$SCRATCH/check10-runner.bak" scripts/check.sh

# 18 — and check 10 must not read a comparison that never ran as "nothing unregistered". Same
# technique as 13 and 17: break the comparator's name so it cannot execute, leaving only the
# status arm. Without this probe that arm is vacuous — delete it and the suite still reports
# every assertion caught, which is how it shipped in the commit that added it.
cp scripts/check.sh "$SCRATCH/check10-comm.bak"
perl -pi -e 's/\$\(comm -23 /\$(comm-does-not-exist -23 /' scripts/check.sh
expect_fail "test-list comparison fails LOUDLY when comm errors (not open)" \
  "could not compare the test list"
cp "$SCRATCH/check10-comm.bak" scripts/check.sh

# 19 — the false positive check 5 exists to NOT have: an untracked entry under a project
# skills directory must leave the gate GREEN. It is not in the repository, it reaches nobody else
# and it shadows nothing in a clone, so it cannot violate "one source of truth per skill" — and
# failing on one blocked every commit in the repo until the directory was moved.
mkdir -p .claude/skills/_probe-local
expect_pass "untracked directory under a project skills dir" \
  "note: untracked entry .claude/skills/_probe-local"

# 19b — ...and with a SKILL.md in it, which is the natural thing to keep there. That file
# reddened a SECOND assertion, the `--others` reach of "SKILL.md outside plugins/", so an empty
# directory alone leaves half the false positive unproven. Its name disagrees with its directory
# on purpose: that is the shape that kept the original symptom alive through CHECK 2 after check 5
# had been fixed, and the three probes here are the issue's own reproduction.
printf -- '---\nname: totally-different\ndescription: A local, unversioned skill.\n---\n' \
  > .claude/skills/_probe-local/SKILL.md
expect_pass "untracked local skill whose name disagrees with its directory"

# 19c — check 2's other arm.
printf 'not frontmatter at all\n' > .claude/skills/_probe-local/SKILL.md
expect_pass "untracked local skill with no frontmatter"

# 19d — and check 1: a script bash cannot parse, which blocked every commit just as loudly.
printf 'if true; then\n' > .claude/skills/_probe-local/helper.sh
expect_pass "untracked local skill carrying an unparseable script"

# 19d2 — the same false positive for check 12, which is why that check is scoped to plugins/ and
# shared/ rather than scanning every `*/tests/run-all.sh` on disk. A local skill somebody keeps
# under a project skills directory may perfectly well carry its own test suite; the repo's Makefile
# has no business running it, and reddening the gate over one would block every commit here for
# work that is deliberately none of the gate's concern. Scoped out, so it must stay green.
#
# The $3 pin is weaker than it looks, said plainly rather than left to be read as coverage: a
# check 12 that DID scan this path would red, so `expect_pass` catches that on its own, and all $3
# adds is rejecting a check that names the path without failing on it. What it cannot see is the
# other way this probe could go vacuously green — check 12 scanning nothing at all — because that
# is indistinguishable here from the carve-out working. Probe 32c is what covers that direction.
mkdir -p .claude/skills/_probe-local/tests
printf '#!/usr/bin/env bash\ntrue\n' > .claude/skills/_probe-local/tests/run-all.sh
expect_pass "untracked local skill carrying its own test runner" "" \
  ".claude/skills/_probe-local/tests/run-all.sh"
rm -rf .claude/skills/_probe-local

# 19e — the counter-tests that keep 19b-d2 from being a hole. The SAME two violations under
# plugins/, where untracked content is still read in full, because that is what the repo ships and
# a packaged skill's SKILL.md is untracked in the moment between writing it and `git add`.
mkdir -p plugins/ship/skills/_probe-pkg
printf -- '---\nname: totally-different\ndescription: A probe skill.\n---\n' \
  > plugins/ship/skills/_probe-pkg/SKILL.md
expect_fail "untracked packaged SKILL.md whose name disagrees with its directory" \
  "skill name 'totally-different' != directory '_probe-pkg'"
rm -rf plugins/ship/skills/_probe-pkg

printf 'if true; then\n' > plugins/ship/skills/ship/_probe.sh
expect_fail "untracked script under plugins/ that bash cannot parse" \
  "syntax: plugins/ship/skills/ship/_probe.sh"
rm -f plugins/ship/skills/ship/_probe.sh

# 20 — and check 5 must say the listing found nothing rather than pass having asserted nothing.
# Repointed inside check.sh, like 14b: `git ls-files -s` over a pathspec matching no tracked file
# warns about nothing and exits 0, so this lands on the empty arm and only on it.
#
# This anchor and probe 21's match the ASSIGNMENT (`^skills_ls=$(git ...)$`) rather than the exact
# command, which is looser than every other anchor in this file and deliberate. What these two
# probes care about is that the listing is replaced; the flags on it are not their subject, and
# pinning them cost two silent no-ops in two consecutive commits — each caught only because a
# no-op reports NOT CAUGHT rather than passing. Renaming the variable still breaks it loudly,
# which is the property worth keeping.
cp scripts/check.sh "$SCRATCH/check5-empty.bak"
perl -pi -e 's{^skills_ls=\$\(git .*\)$}{skills_ls=\$(git ls-files -s -- .claude/skills-moved-away)}' scripts/check.sh
expect_fail "project skill listing fails LOUDLY when it lists nothing" \
  "no tracked entry under"
cp "$SCRATCH/check5-empty.bak" scripts/check.sh

# 21 — and it must not read a listing that ERRORED as an empty one. `exit 128` inside the
# substitution, like 14a: a pathspec matching nothing is not an error (probe 20 depends on that),
# so the status has to be forced — and forcing it while the output stays non-empty is what stops
# the empty arm from explaining the failure instead.
cp scripts/check.sh "$SCRATCH/check5-rc.bak"
perl -pi -e 's{^skills_ls=\$\(git .*\)$}{skills_ls=\$(git ls-files -s -- \$SKILL_LINK_DIRS; exit 128)}' scripts/check.sh
expect_fail "project skill listing fails LOUDLY when git ls-files errors" \
  "could not list tracked project skill entries"
cp "$SCRATCH/check5-rc.bak" scripts/check.sh

# 22 — a packaged skill's own link is repo-owned, so check 5 asserts it whether or not it has
# been staged. That window is the one AGENTS.md's "How to add a skill" opens: create both links
# (step 3), run the gate (step 5), `git add` after. The fixture is a new skill in an EXISTING
# plugin because that is the shape AGENTS.md calls typical, and because a new PLUGIN cannot reach
# the window at all — checks 3 and 4 red on an unlisted plugins/* directory first.
#
# 22a first requires the correct case to stay GREEN: these assertions run over untracked paths, so
# getting them wrong would put back a false positive on the very procedure the repo documents.
mkdir -p plugins/ship/skills/_probe-skill
printf -- '---\nname: _probe-skill\ndescription: A probe skill.\n---\n' \
  > plugins/ship/skills/_probe-skill/SKILL.md
ln -sfn ../../plugins/ship/skills/_probe-skill .agents/skills/_probe-skill
ln -sfn ../../plugins/ship/skills/_probe-skill .claude/skills/_probe-skill
expect_pass "unstaged packaged skill whose links are correct" "" \
  "note: untracked entry .claude/skills/_probe-skill"

# 22b — a link that resolves nowhere, with nothing staged. `[ -L ]` alone is satisfied by it,
# which is exactly why that test is not enough on its own.
ln -sfn ../../plugins/ship/skills/gone .claude/skills/_probe-skill
expect_fail "unstaged packaged-skill link that resolves nowhere" \
  "link is not staged and does not resolve into plugins/"

# 22c — and one resolving OUTSIDE the repo, which a substring test on the link text would
# accept. The same branch as 22b reached with a target that resolves rather than an empty one, and
# the shape that would let an agent opened in a clone read an out-of-tree SKILL.md as instructions.
mkdir -p "$SCRATCH/outside/_probe-skill"
printf -- '---\nname: _probe-skill\ndescription: A probe skill.\n---\n' \
  > "$SCRATCH/outside/_probe-skill/SKILL.md"
ln -sfn "$SCRATCH/outside/_probe-skill" .claude/skills/_probe-skill
expect_fail "unstaged packaged-skill link resolving outside the repo" \
  "link is not staged and does not resolve into plugins/"

# 22d — and a link INTO plugins/ that exposes no SKILL.md, which is the likelier typo of the two:
# `plugins/<plugin>` is a real directory one level above the right target, so containment alone
# accepts it. This is the assertion the tracked loop has always made and this loop nearly missed.
ln -sfn ../../plugins/ship .claude/skills/_probe-skill
expect_fail "unstaged packaged-skill link exposing no SKILL.md" \
  "link is not staged and exposes no SKILL.md"
rm -rf plugins/ship/skills/_probe-skill .claude/skills/_probe-skill .agents/skills/_probe-skill

# 23 — the exemption must survive git's path quoting. `git ls-files` C-quotes a path holding a
# byte >= 0x80, and a quoted string matches none of the prefixes the predicate tests, so the
# exemption silently stops applying and a valid local skill reds three fabricated failures about a
# path that does not exist. That shipped once already: the flag went onto check 5's two listings
# and not onto the two that feed checks 1 and 2.
mkdir -p ".claude/skills/$NONASCII"
printf -- '---\nname: totally-different\ndescription: A local, unversioned skill.\n---\n' \
  > ".claude/skills/$NONASCII/SKILL.md"
printf 'if true; then\n' > ".claude/skills/$NONASCII/helper.sh"
expect_pass "untracked local skill whose directory name is not ASCII" \
  "note: untracked entry .claude/skills/$NONASCII"
rm -rf ".claude/skills/$NONASCII"

# 23b — the same name on a PACKAGED skill, which is checked in full and must stay green.
mkdir -p "plugins/ship/skills/$NONASCII"
printf -- '---\nname: %s\ndescription: A probe skill.\n---\n' "$NONASCII" \
  > "plugins/ship/skills/$NONASCII/SKILL.md"
ln -sfn "../../plugins/ship/skills/$NONASCII" ".claude/skills/$NONASCII"
ln -sfn "../../plugins/ship/skills/$NONASCII" ".agents/skills/$NONASCII"
expect_pass "packaged skill whose directory name is not ASCII"

# 23c — and the same links COMMITTED, which is the only way to reach check 5's own `ls-files -s`
# listing. That listing is the fifth and last place the quoting flag has to be, and it is the one
# site with no probe: the other four are covered by 23 and 23b, while this one was covered only by
# accident, through probe 20's and probe 21's anchors happening to contain the flag's literal text
# until those anchors were loosened. Drop `$GIT_Q` from that line and the gate prints four
# fabricated failures — `broken symlink` and `symlink target is outside this repo's plugins/`,
# twice each, about C-quoted paths that do not exist. Same throwaway index as probe 5a: the repo's
# own index is untouched and the link blobs are hashed without `-w`.
cp "$(git rev-parse --git-path index)" "$SCRATCH/fake-index-nonascii"
for d in .claude/skills .agents/skills; do
  GIT_INDEX_FILE="$SCRATCH/fake-index-nonascii" git update-index --add --cacheinfo \
    "120000,$(printf '%s' "../../plugins/ship/skills/$NONASCII" | git hash-object --stdin),$d/$NONASCII"
done
export GIT_INDEX_FILE="$SCRATCH/fake-index-nonascii"
expect_pass "committed packaged-skill links whose directory name is not ASCII"
unset GIT_INDEX_FILE
rm -rf "plugins/ship/skills/$NONASCII" ".claude/skills/$NONASCII" ".agents/skills/$NONASCII"

# 24 — the predicate must fail CLOSED. Forced inside check.sh, like probes 14a and 21: only the
# status can be forced, because no real path makes `--error-unmatch` error. Collapsing "not in the
# index" and "git failed" would turn a git failure into a decision to skip the check, which is the
# "could not list" read as "nothing to report" that the rest of this gate refuses by name.
cp scripts/check.sh "$SCRATCH/check-predicate.bak"
perl -pi -e 's{^  git ls-files --error-unmatch -- "\$1" >/dev/null 2>&1$}{  git ls-files --error-unmatch -- "\$1" >/dev/null 2>&1; (exit 128)}' scripts/check.sh
mkdir -p .claude/skills/_probe-local
printf -- '---\nname: totally-different\ndescription: A local, unversioned skill.\n---\n' \
  > .claude/skills/_probe-local/SKILL.md
expect_fail "the untracked predicate fails CLOSED when git errors" \
  "skill name 'totally-different' != directory '_probe-local'"
rm -rf .claude/skills/_probe-local
cp "$SCRATCH/check-predicate.bak" scripts/check.sh

# 25 — check 11: a vendored copy that drifts from its canonical reds the gate. Backup and restore
# by hand (not `git checkout --`) so the probe holds whether or not the module is committed. The
# fixture drifts a DRIVER copy; probe 29b drifts a FLOW copy, so the one generalized loop is proven
# to reach both modules.
cp plugins/council/skills/council/lib/agent-driver.sh "$SCRATCH/drv-copy.bak"
printf '# drift\n' >> plugins/council/skills/council/lib/agent-driver.sh
expect_fail "shared driver copy drifted from canonical" "shared module copy drifted"
cp "$SCRATCH/drv-copy.bak" plugins/council/skills/council/lib/agent-driver.sh

# 26 — check 11 fails CLOSED: a missing vendored copy reds too, it does not silently pass.
mv plugins/shipyard/skills/shipyard/agent-driver.sh "$SCRATCH/drv-copy2.bak"
expect_fail "a missing shared driver copy" "shared module copy is missing"
mv "$SCRATCH/drv-copy2.bak" plugins/shipyard/skills/shipyard/agent-driver.sh

# 27 — check 11 fails CLOSED: a module with no canonical *.sh reds the gate — the generalized form
# of "the canonical is missing". Backup and restore by hand (like 25/26). check 1's bash -n also
# reds on the still-tracked missing file, so the unique $2 "shared module has no canonical" is what
# keeps this probe on check 11's arm.
mv shared/driver/agent-driver.sh "$SCRATCH/drv-canonical.bak"
expect_fail "a module with no canonical *.sh" "shared module has no canonical"
mv "$SCRATCH/drv-canonical.bak" shared/driver/agent-driver.sh

# 28 — check 11 fails CLOSED: a missing target list reds the gate. targets.txt is not a *.sh file,
# so no other check touches it — this arm has no backstop but this probe.
mv shared/driver/targets.txt "$SCRATCH/drv-targets.bak"
expect_fail "a missing shared module target list" "shared module target list is missing"
mv "$SCRATCH/drv-targets.bak" shared/driver/targets.txt

# 29 — check 11's per-module "compared nothing" guard: a target list with no active entries (only
# comments or blanks) reds the gate rather than passing green having compared zero copies. Same
# no-backstop arm as 28, and the one most likely to rot silently if the per-module count guard is
# ever dropped.
cp shared/driver/targets.txt "$SCRATCH/drv-targets-empty.bak"
printf '# only a comment, no target paths\n' > shared/driver/targets.txt
expect_fail "an empty shared module target list" "shared module target list is empty"
cp "$SCRATCH/drv-targets-empty.bak" shared/driver/targets.txt

# 29b — the generalization actually REACHES the flow module, not just the driver: a drifted flow
# copy reds too. Without this, check 11 could iterate the driver alone and this suite would not
# notice. Backup/restore by hand, like 25.
cp plugins/council/skills/council/lib/flow.sh "$SCRATCH/flow-copy.bak"
printf '# drift\n' >> plugins/council/skills/council/lib/flow.sh
expect_fail "a drifted flow copy reds too (the loop reaches every module)" "shared module copy drifted"
cp "$SCRATCH/flow-copy.bak" plugins/council/skills/council/lib/flow.sh

# 29c — ...and a missing flow copy reds, the flow module's fail-closed arm.
mv plugins/shipyard/skills/shipyard/flow.sh "$SCRATCH/flow-copy2.bak"
expect_fail "a missing flow copy" "shared module copy is missing"
mv "$SCRATCH/flow-copy2.bak" plugins/shipyard/skills/shipyard/flow.sh

# 29d — a NEW malformed-module arm the generalization introduced: a module with SEVERAL *.sh has no
# unique canonical and reds loudly rather than picking one at random. The stray file is untracked,
# so the restore trap removes it explicitly.
printf '# a second script\ntrue\n' > shared/flow/extra.sh
expect_fail "a module with several *.sh has no unique canonical" "shared module has several *.sh"
rm -f shared/flow/extra.sh

# 29e — the top-level "compared nothing" guard: if no shared/<mod>/ exists at all, the whole check
# must red rather than pass having scanned zero modules. Repointed inside check.sh (like 14b/20) so
# the loop's glob matches nothing — moving shared/ for real would trip check 1 and others.
cp scripts/check.sh "$SCRATCH/check11-nomod.bak"
perl -pi -e 's{^for moddir in shared/\*/; do$}{for moddir in shared/none-xyz-*/; do}' scripts/check.sh
expect_fail "check 11 reds when no shared module exists at all" "no shared/<mod>/ module found under shared/"
cp "$SCRATCH/check11-nomod.bak" scripts/check.sh

# 30 — option B: `make check` (the Makefile target, NOT scripts/check.sh) actually RUNS the driver
# suite, so a driver-suite regression reds every commit. This is the one probe that must invoke
# `make check`: it tests the Makefile wiring, not a check.sh assertion. t-driver.sh is overwritten
# with a failing stub rather than having a line appended — appending is unreliable when the real
# file exits before reaching it. The stub still parses (check 1) and is still registered (check
# 10), so scripts/check.sh stays green and only the suite run reds. Restored via git checkout.
printf '#!/usr/bin/env bash\nexit 1\n' > shared/driver/tests/t-driver.sh
if make check >"$SCRATCH/out" 2>&1; then
  echo "NOT CAUGHT: make check does not run the driver suite (a driver failure did not red it)"
  nocatch=$((nocatch+1))
else
  echo "caught:     make check runs the driver suite   ->  a failing driver test reds make check"
  pass=$((pass+1))
fi
git checkout -- shared/driver/tests/t-driver.sh

# 30b — ...and `make check` RUNS the flow suite too, so a flow-guard regression reds every commit.
# Same technique as 30: overwrite t-flow.sh with a failing stub (it still parses for check 1 and is
# still registered for check 10, so scripts/check.sh stays green and only the suite run reds).
printf '#!/usr/bin/env bash\nexit 1\n' > shared/flow/tests/t-flow.sh
if make check >"$SCRATCH/out" 2>&1; then
  echo "NOT CAUGHT: make check does not run the flow suite (a flow failure did not red it)"
  nocatch=$((nocatch+1))
else
  echo "caught:     make check runs the flow suite   ->  a failing flow test reds make check"
  pass=$((pass+1))
fi
git checkout -- shared/flow/tests/t-flow.sh

# 30c — ...and `make check` RUNS the adapter suite, so a regression in the module both skills'
# launches now go through reds every commit. Same technique as 30 and 30b. This is the probe that
# would catch the Makefile line being dropped while check 10 still asserts the suite's
# registration — which would leave the suite listed, looking gated, and never run at commit time.
printf '#!/usr/bin/env bash\nexit 1\n' > shared/adapters/tests/t-adapters.sh
if make check >"$SCRATCH/out" 2>&1; then
  echo "NOT CAUGHT: make check does not run the adapter suite (an adapter failure did not red it)"
  nocatch=$((nocatch+1))
else
  echo "caught:     make check runs the adapter suite   ->  a failing adapter test reds make check"
  pass=$((pass+1))
fi
git checkout -- shared/adapters/tests/t-adapters.sh

# 30d — ...and `make check` RUNS the policy suite, which is the whole point of #111: that suite ran
# in no automated invocation at all. Check 12 asserts a Makefile RECIPE names the runner; this
# asserts the naming actually causes it to run, which a recipe in a target nothing invokes would
# not. Same technique as 30, 30b and 30c.
printf '#!/usr/bin/env bash\nexit 1\n' > shared/policy/tests/t-policy.sh
if make check >"$SCRATCH/out" 2>&1; then
  echo "NOT CAUGHT: make check does not run the policy suite (a policy failure did not red it)"
  nocatch=$((nocatch+1))
else
  echo "caught:     make check runs the policy suite   ->  a failing policy test reds make check"
  pass=$((pass+1))
fi
git checkout -- shared/policy/tests/t-policy.sh

# 30e — ...and `make check` RUNS the knobs suite. THIS IS THE AXIS ITS OWN CHANGE MISSED, which is
# why the comment says so: that change added the suite, registered it (15g) and named it in both
# Makefile targets, and stopped there — so moving its line out of `check:` into `test:` alone left
# `make check-test` reporting every assertion proven while a deliberately failing `t-knobs.sh` kept
# `make check` green. Check 12 cannot see it: it accepts EITHER target by design, which is what
# lets the fast/slow split exist. Only executing the gate can. #111 is the same hole for the policy
# suite, and this is that hole reopened by the next suite to be added — so the rule, not the count:
# every suite `make check` runs needs a probe here, added in the same change that adds the suite.
printf '#!/usr/bin/env bash\nexit 1\n' > shared/knobs/tests/t-knobs.sh
if make check >"$SCRATCH/out" 2>&1; then
  echo "NOT CAUGHT: make check does not run the knobs suite (a knobs failure did not red it)"
  nocatch=$((nocatch+1))
else
  echo "caught:     make check runs the knobs suite   ->  a failing knobs test reds make check"
  pass=$((pass+1))
fi
git checkout -- shared/knobs/tests/t-knobs.sh

# 31 — the mirror of 30 for the STATIC gate: `make check` must also invoke scripts/check.sh, not
# only the fast test suites. When this suite switched its ~60 probes from `make check` to
# `bash scripts/check.sh` (so it tests the static gate directly and does not pay those suites'
# runtime), it lost the coverage every one of those probes used to give for free — that make check
# runs check.sh at all. Inject a check.sh-caught violation into a script the fast suites do NOT
# run, and require `make check` to red. If the Makefile's `@bash scripts/check.sh` line were ever
# dropped while the suite lines stayed (a Makefile merge resolution — the exact shape check 10's
# own comment cites), make check would run only the fast suites (green) and this reports NOT
# CAUGHT. Uses `make check`, not `bash scripts/check.sh`, on purpose; $2 pins it to check 1's arm.
printf '\nif true; then\n' >> plugins/shipyard/skills/shipyard/shipyard-lib.sh
if make check >"$SCRATCH/out" 2>&1; then
  echo "NOT CAUGHT: make check does not run scripts/check.sh (a check.sh violation did not red it)"
  nocatch=$((nocatch+1))
elif ! grep -qF -- "syntax:" "$SCRATCH/out"; then
  echo "WRONG ARM:  make check runs scripts/check.sh"
  echo "            expected: syntax:"
  echo "            got:      $(grep -m1 '^FAIL' "$SCRATCH/out" | cut -c1-70)"
  nocatch=$((nocatch+1))
else
  echo "caught:     make check runs scripts/check.sh (a check.sh violation reds make check)"
  pass=$((pass+1))
fi
git checkout -- plugins/shipyard/skills/shipyard/shipyard-lib.sh

# 32 — check 12's invocation arm: a suite runner that no Makefile recipe names. This is the
# failure the check was added for, and the state the repo was actually in — reproduced by deleting
# the policy suite's invocation from BOTH targets, which is also what a Makefile merge resolution
# that drops a line leaves behind. Both lines must go: one target is enough to satisfy check 12
# (32b proves that), so deleting only `check`'s would leave the gate correctly green and this probe
# would report NOT CAUGHT over an assertion that is working. `@` is escaped in the pattern because
# perl would otherwise interpolate `@bash` as an array.
perl -ni -e 'print unless m{^\t\@bash shared/policy/tests/run-all\.sh$}' Makefile
expect_fail "check 12: a suite runner invoked by no Makefile target" \
  "test suite runner is invoked by no Makefile target"
git checkout -- Makefile

# 32a — the same arm, for the ADAPTERS suite, so the runner loop is proven to visit more than
# whichever entry comes first. Without this, check 12 could stop examining every runner but one and
# 32 would still report caught.
perl -ni -e 'print unless m{^\t\@bash shared/adapters/tests/run-all\.sh$}' Makefile
expect_fail "check 12: the invocation arm fires for a second suite too (adapters)" \
  "test suite runner is invoked by no Makefile target"
git checkout -- Makefile

# 32b — the mirror, and the requirement it protects: EITHER target counts. The fast/slow split is
# deliberate — `make check` stays committable and the slow suites live in `make test` — so a check
# that demanded both would fight the Makefile's own design and red for council and shipyard, which
# `make check` correctly does not run. Remove the policy suite from `check` only, leave it in
# `test`, and the gate must stay green.
perl -ni -e 'if (!$done && m{^\t\@bash shared/policy/tests/run-all\.sh$}) { $done = 1; next } print' Makefile
expect_pass "check 12: a runner in only one Makefile target still counts as invoked"
git checkout -- Makefile

# 32c — the invocation arm must reject a COMMENTED-OUT recipe line, which is the whole reason the
# match is scoped to recipe lines rather than grepping the file. The first implementation used an
# unanchored `grep -F` over the whole Makefile, and this exact mutation left it GREEN over a suite
# that ran nowhere — the defect the check exists to catch, inside the check itself. Deleting the
# `^\t` scoping reintroduces it and this probe reds.
perl -pi -e 's{^\t\@bash shared/policy/tests/run-all\.sh$}{# was: \@bash shared/policy/tests/run-all.sh}' Makefile
expect_fail "check 12: a commented-out recipe line is not an invocation" \
  "test suite runner is invoked by no Makefile target"
git checkout -- Makefile

# 32d — check 12's DECLARATION arm: a suite on disk that $GATED_SUITES does not name. Check 10 only
# visits what that list names, so without this arm a suite could be Makefile-wired (invocation arm
# green) and never registration-checked — which is the other half of how shared/policy/tests
# shipped. Removing the adapters entry is the honest reproduction: it is a real suite, on disk, with
# its Makefile recipe intact, so ONLY the declaration arm can red.
cp scripts/check.sh "$SCRATCH/check12-decl.bak"
perl -ni -e 'print unless m{^shared/adapters/tests$}' scripts/check.sh
expect_fail "check 12: a suite on disk that \$GATED_SUITES does not declare" \
  "not in \$GATED_SUITES"
cp "$SCRATCH/check12-decl.bak" scripts/check.sh

# 32e — check 12's empty-listing arm: the runner scan succeeds and matches nothing, which is what
# both shipped trees being moved or renamed looks like. Zero iterations, no error anywhere, and the
# assertion silently gone — the same shape as 14b for check 9. `git ls-files` exits 0 over a
# pathspec that matches nothing, so without this arm the check would abstain and print OK.
# The pattern tracks check 12's `:(glob)` pathspecs; if those are ever reworded this substitution
# stops matching, the mutation silently no-ops, and the probe reports NOT CAUGHT rather than
# passing vacuously — which is the right way round, and is how this probe was caught needing an
# update when the pathspecs gained their glob magic.
cp scripts/check.sh "$SCRATCH/check12-empty.bak"
perl -pi -e 's{plugins/\*\*/tests/run-all\.sh}{plugins-none-xyz/**/tests/run-all.sh}; s{shared/\*\*/tests/run-all\.sh}{shared-none-xyz/**/tests/run-all.sh}' scripts/check.sh
expect_fail "check 12 reds when the runner scan matches nothing at all" \
  "found no test runner under plugins/ or shared/"
cp "$SCRATCH/check12-empty.bak" scripts/check.sh

# 32f — check 12's errored-listing arm, in the shape probes 14a and 21 use: force a non-zero status
# out of the `git ls-files` substitution while leaving its OUTPUT non-empty, so the empty-listing
# arm above cannot fire instead and claim the catch. Without this the arm has no kill test: a
# broken pathspec is not an error, so nothing else would ever exercise it, and deleting the `fail`
# would leave `make check-test` reporting every assertion proven.
cp scripts/check.sh "$SCRATCH/check12-rc.bak"
perl -pi -e 'if (m{:\(glob\)}) { s{ \| sort -u\)$}{ | sort -u; exit 128)} }' scripts/check.sh
expect_fail "check 12 reds when the runner listing itself errors" \
  "could not list the test runners on disk"
cp "$SCRATCH/check12-rc.bak" scripts/check.sh

# 32g — and check 12's missing-Makefile arm, so "there is nothing to compare against" is never
# read as OK. The $2 pin is load-bearing here: delete the `[ ! -f Makefile ]` arm and the per-runner
# grep exits 2, so the `*)` arm reds on a different message and an unpinned probe would report
# `caught` over a deleted assertion. Restored with `git checkout --`, so an interrupt here is
# recovered by the trap rather than leaving the repo without a Makefile (which is why it joined
# $GUARDED).
rm -f Makefile
expect_fail "check 12 reds when the Makefile is missing" \
  "Makefile is missing"
git checkout -- Makefile

# 33 — check 13's coverage arm: a path this file GUARDS that the check-test CI job's pull-request
# filter does not name. That job runs in full on every push to `main` and, on a pull request, only
# when the change touches a path that could affect what it proves — so the filter is the whole of
# the risk in skipping it, and the direction it goes quiet in is a probe being added that mutates a
# NEW tree. The author adds that tree to $GUARDED (or the restore misses it) and nothing else would
# connect it to a workflow file. Removing one entry from the filter is the honest reproduction.
perl -ni -e "print unless m{^ *- 'shared/\\*\\*'\$}" .github/workflows/check-test.yml
expect_fail "check 13: a \$GUARDED path the check-test job's filter does not cover" \
  "path filter has no 'shared/**'"
git checkout -- .github/workflows/check-test.yml

# 33b — the same arm from the other side: $GUARDED grows and the filter does not. This is the
# likelier way round in practice, and it is a DIFFERENT mutation — 33 deletes from the filter, this
# adds to the guarded list — so neither substitutes for the other.
# The injected name must be one NO filter entry can cover. `docs` was used here and stopped being
# a valid probe the moment `docs/**` was deliberately added to the filter: check 13 then found the
# entry, reddened nothing, and this probe recorded `not proven` — failing the whole run over an
# arm that is in fact fine. A token that exists nowhere cannot acquire that problem.
perl -pi -e "s{^GUARDED='([^']*)'}{GUARDED='\$1 _probe-guarded-tree'}" scripts/check-test.sh
expect_fail "check 13: a path added to \$GUARDED but not to the filter" \
  "path filter has no '_probe-guarded-tree/**'"
git checkout -- scripts/check-test.sh

# 33b2 — check 13's REFUSAL arm. `paths-ignore:` is the same YAML shape as `paths:` with the
# opposite meaning, and check 13 reasons only about an explicit list of the paths that run the
# job — so without this arm an inverted list would be read as one, reporting full coverage while
# the job skipped on exactly the paths it was proving were covered.
perl -pi -e 's/^    paths:$/    paths-ignore:/' .github/workflows/check-test.yml
expect_fail "check 13: paths-ignore is refused rather than misread" \
  "uses paths-ignore"
git checkout -- .github/workflows/check-test.yml
# 33b3 — and the same key quoted, which is the same key to YAML.
perl -pi -e "s/^    paths:\$/    'paths-ignore':/" .github/workflows/check-test.yml
expect_fail "check 13: a quoted paths-ignore is refused too" \
  "uses paths-ignore"
git checkout -- .github/workflows/check-test.yml

# 33c — and the two loud arms, so a filter check that ABSTAINS can never be mistaken for one that
# passed. A check that goes quiet over the job proving every other check is not decoration is the
# worst shape this file guards against.
: > .github/workflows/check-test.yml
expect_fail "check 13: an unreadable path filter is loud, not silent" \
  "could not read any path filter"
git checkout -- .github/workflows/check-test.yml

perl -pi -e "s{^GUARDED='[^']*'}{GUARDED_RENAMED=''}" scripts/check-test.sh
expect_fail "check 13: an unreadable \$GUARDED is loud, not silent" \
  "could not read \$GUARDED"
git checkout -- scripts/check-test.sh

# 33d — the backstop (#215): a `paths:` list under `push:` makes the run on main conditional. The
# flat scrape this replaced read the new entry as one more pull-request filter entry and said
# nothing. Every pull-request entry stays in place, so only the push arm can fire.
perl -0pi -e "s{(\n  push:\n    branches:\n      - 'main'\n)}{\$1    paths:\n      - 'docs/**'\n}" .github/workflows/check-test.yml
expect_fail "check 13: a path filter under push: is refused" \
  "filters its push: trigger by paths"
git checkout -- .github/workflows/check-test.yml
# 33d2 — the same filter in flow style, which a block reader would read as an unfiltered push...
perl -0pi -e "s{\n  push:\n    branches:\n      - 'main'\n}{\n  push: {branches: [main], paths: ['docs/**']}\n}" .github/workflows/check-test.yml
expect_fail "check 13: a flow-style push: trigger is refused" \
  "writes its push: trigger in flow style"
git checkout -- .github/workflows/check-test.yml
# 33d3 — ...and under a quoted key, which a reader of bare keys would file under `branches:`.
perl -0pi -e "s{(\n  push:\n    branches:\n      - 'main'\n)}{\$1    \"paths\":\n      - 'docs/**'\n}" .github/workflows/check-test.yml
expect_fail "check 13: a quoted paths key under push: is read as the key it is" \
  "filters its push: trigger by paths"
git checkout -- .github/workflows/check-test.yml
# 33d4 — and the flow mapping moved to the line below its event, where it is neither a key nor an
# item: a line the reader cannot place reds instead of being skipped.
perl -0pi -e "s{\n  push:\n    branches:\n      - 'main'\n}{\n  push:\n    {branches: [main], paths: ['docs/**']}\n}" .github/workflows/check-test.yml
expect_fail "check 13: a line under push: that is neither a key nor an item is refused" \
  "cannot read as a key or a list item"
git checkout -- .github/workflows/check-test.yml
# 33d5 — the same under pull_request:, after its complete paths list, where nothing else reds.
perl -0pi -e "s{(\n *- 'docs/\\*\\*'\n)}{\$1    {types: [opened]}\n}" .github/workflows/check-test.yml
expect_fail "check 13: a line under pull_request: that is neither a key nor an item is refused" \
  "has a line under its pull_request: trigger"
git checkout -- .github/workflows/check-test.yml
# 33d6 — an EVENT line it cannot name: without its own red, the `paths:` under it would be credited
# to the event before it, so `plugins/**` dropped from pull_request: would read as still covered.
perl -0pi -e "s{\n *- 'plugins/\\*\\*'\n}{\n}; s{\npermissions:}{  pull_request_target :\n    paths:\n      - 'plugins/**'\n\npermissions:}" .github/workflows/check-test.yml
expect_fail "check 13: an event line it cannot name is refused" \
  "has an event under on: that check 13 cannot read"
git checkout -- .github/workflows/check-test.yml
# 33e — and the backstop removed outright.
perl -0pi -e 's{\n  push:\n    branches:\n      - \x27main\x27\n}{\n}' .github/workflows/check-test.yml
expect_fail "check 13: a workflow with no push: trigger reds" \
  "has no push: trigger"
git checkout -- .github/workflows/check-test.yml
# 33i — the key allowlist (#58). Each key below narrows when the job runs and passed green while
# check 13 read only the keys it was written about. `branches:` stays in place under push: in the
# first two, so the must-name-main arm cannot claim the red.
perl -0pi -e "s{(\n  push:\n    branches:\n      - 'main'\n)}{\$1    branches-ignore:\n      - 'main'\n}" .github/workflows/check-test.yml
expect_fail "check 13: branches-ignore under push: is refused" \
  "push: trigger carries branches-ignore"
git checkout -- .github/workflows/check-test.yml
perl -0pi -e "s{(\n  push:\n    branches:\n      - 'main'\n)}{\$1    tags:\n      - 'v*'\n}" .github/workflows/check-test.yml
expect_fail "check 13: tags under push: is refused" \
  "push: trigger carries tags"
git checkout -- .github/workflows/check-test.yml
perl -0pi -e "s{(\n  pull_request:\n)}{\$1    branches:\n      - 'release'\n}" .github/workflows/check-test.yml
expect_fail "check 13: branches under pull_request: is refused" \
  "pull_request: trigger carries branches"
git checkout -- .github/workflows/check-test.yml
perl -0pi -e "s{(\n  pull_request:\n)}{\$1    types:\n      - 'closed'\n}" .github/workflows/check-test.yml
expect_fail "check 13: types under pull_request: is refused" \
  "pull_request: trigger carries types"
git checkout -- .github/workflows/check-test.yml
# 33j — push: branches: is exactly main. A list without it, spelt as a near miss so that a match
# loosened to a substring would pass it; one that excludes it again; and an entry beside it the
# reader cannot read (unquoted), which only the count of `-` lines sees.
perl -0pi -e "s{(\n  push:\n    branches:\n      - )'main'\n}{\$1'main-old'\n}" .github/workflows/check-test.yml
expect_fail "check 13: a push: branches list without main reds" \
  "push: trigger does not name 'main'"
git checkout -- .github/workflows/check-test.yml
perl -0pi -e "s{(\n  push:\n    branches:\n      - 'main'\n)}{\$1      - '!main'\n}" .github/workflows/check-test.yml
expect_fail "check 13: a negated pattern under push: branches reds" \
  "push: branches: carries an entry other than 'main'"
git checkout -- .github/workflows/check-test.yml
perl -0pi -e "s{(\n  push:\n    branches:\n      - 'main'\n)}{\$1      - release\n}" .github/workflows/check-test.yml
expect_fail "check 13: an unreadable entry beside main under push: branches reds" \
  "push: branches: carries an entry other than 'main'"
git checkout -- .github/workflows/check-test.yml
# 33k — a value on the key's own line: `>-` makes the list below it a string to YAML, yet its
# `- 'main'` would read as an item. Nothing else reds here.
perl -0pi -e "s{(\n  push:\n    branches:)\n}{\$1 >-\n}" .github/workflows/check-test.yml
expect_fail "check 13: a key under push: with a value on its own line is refused" \
  "with a value on the key's own line"
git checkout -- .github/workflows/check-test.yml
# 33k2 — the same under pull_request:, where the list below still reads as a complete filter.
perl -0pi -e "s{(\n  pull_request:\n    paths:)\n}{\$1 >-\n}" .github/workflows/check-test.yml
expect_fail "check 13: a key under pull_request: with a value on its own line is refused" \
  "under its pull_request: trigger with a value on the key's own line"
git checkout -- .github/workflows/check-test.yml
# 33j4 — a YAML escape: `'main''x'` is main'x, a branch that is not main. An item regex that stops at
# the first closing quote would read it as `main`.
perl -0pi -e "s{(\n  push:\n    branches:\n      - )'main'\n}{\$1'main''x'\n}" .github/workflows/check-test.yml
expect_fail "check 13: an escaped quote in the only push: branch is not read as main" \
  "push: trigger does not name 'main'"
git checkout -- .github/workflows/check-test.yml
# 33l — the pull-request filter reads every entry or reds: an unquoted one beside the complete
# list, where the coverage loop stays green because every entry $GUARDED derives is still there...
perl -0pi -e "s{(\n *- 'docs/\\*\\*'\n)}{\$1      - scripts/extra/**\n}" .github/workflows/check-test.yml
expect_fail "check 13: an unreadable pull_request: paths: entry is refused" \
  "has an entry check 13 cannot read"
git checkout -- .github/workflows/check-test.yml
# 33l2 — ...and a negated one, which takes a guarded tree back out of a list that still names it.
perl -0pi -e "s{(\n *- 'docs/\\*\\*'\n)}{\$1      - '!scripts/**'\n}" .github/workflows/check-test.yml
expect_fail "check 13: a negated pull_request: paths: entry is refused" \
  "pull_request: paths: carries a negated pattern"
git checkout -- .github/workflows/check-test.yml
# 33l3 — the same negation spelt as a double-quoted escape (`\x21` is `!`), which a reader that read
# a backslash inside double quotes would take for a plain entry.
perl -0pi -e "s{(\n *- 'docs/\\*\\*'\n)}{\$1      - \"\\\\x21scripts/**\"\n}" .github/workflows/check-test.yml
expect_fail "check 13: an escaped double-quoted pull_request: paths: entry is not read" \
  "has an entry check 13 cannot read"
git checkout -- .github/workflows/check-test.yml
# 33l4 — a tab inside the quotes is part of the value, but the reader's rows are tab-separated, so a
# reader that kept it would split `scripts/**` back off it and read a path the filter does not hold.
perl -0pi -e "s{(\n *- 'docs/\\*\\*'\n)}{\$1      - 'scripts/**\t'\n}" .github/workflows/check-test.yml
expect_fail "check 13: a tab inside a quoted pull_request: paths: entry is not read" \
  "has an entry check 13 cannot read"
git checkout -- .github/workflows/check-test.yml
# 33l5 — the same tab inside a DOUBLE-quoted entry, which is a separate regex in the reader (#314):
# reverting its tab exclusion (`[^"\\\t]` to `[^"\\]`) passed every probe above.
perl -0pi -e "s{(\n *- 'docs/\\*\\*'\n)}{\$1      - \"scripts/**\t\"\n}" .github/workflows/check-test.yml
expect_fail "check 13: a tab inside a double-quoted pull_request: paths: entry is not read" \
  "has an entry check 13 cannot read"
git checkout -- .github/workflows/check-test.yml
# 33n — a line break awk does not split on (a lone CR) hides a second entry behind a comment.
perl -0pi -e "s{(\n  push:\n    branches:\n      - 'main')\n}{\$1 #\r      - '!main'\n}" .github/workflows/check-test.yml
expect_fail "check 13: a line break other than LF is refused" \
  "contains a line break other than LF"
git checkout -- .github/workflows/check-test.yml
# 33o — a key written twice under one event: parsers disagree on which copy wins, and one that keeps
# the last would run check-test on `docs/**` alone. This reader credits both lists, so the coverage
# loop stays green and nothing else reds.
perl -0pi -e "s{(\n *- 'docs/\\*\\*'\n)}{\$1    paths:\n      - 'docs/**'\n}" .github/workflows/check-test.yml
expect_fail "check 13: a repeated key under pull_request: is refused" \
  "repeats pull_request.paths"
git checkout -- .github/workflows/check-test.yml
# 33p — the file's SHAPE (#314): check 13 reads one document with one block-style `on:`, and reds
# every other shape rather than reading it wrongly. Most fixtures below only add to the file and
# leave the committed `on:` block intact, so the trigger arms above stay green; every one is pinned
# on its own shape arm's message, whatever else reds beside it.
# A second `on:` after the committed one, in block style and in flow style: a parser that keeps the
# last copy runs check-test on neither push nor pull request.
printf 'on:\n  workflow_dispatch:\n' >> .github/workflows/check-test.yml
expect_fail "check 13: a second block-style top-level on: is refused" \
  "has 2 top-level on: keys"
git checkout -- .github/workflows/check-test.yml
printf 'on: [workflow_dispatch]\n' >> .github/workflows/check-test.yml
expect_fail "check 13: a second flow-style top-level on: is refused" \
  "has 2 top-level on: keys"
git checkout -- .github/workflows/check-test.yml
# 33p2 — the only `on:` in flow style, which the reader does not look inside.
perl -0pi -e "s{\non:\n.*?\n\npermissions:}{\non: [push, pull_request]\n\npermissions:}s" .github/workflows/check-test.yml
expect_fail "check 13: a flow-style top-level on: is refused" \
  "writes its top-level on: in flow style"
git checkout -- .github/workflows/check-test.yml
# 33p3 — a multi-document file: a parser that reads the first document runs its triggers, not these.
# The leading document carries an `on:` of its own, so the on-count arm would red too; the pin is
# the marker arm, and the trailing `...` below has no second `on:` to lean on.
perl -0pi -e 's{\A}{on: [workflow_dispatch]\njobs: {}\n---\n}' .github/workflows/check-test.yml
expect_fail "check 13: a document marker after line 1 is refused" \
  "carries a YAML document marker"
git checkout -- .github/workflows/check-test.yml
printf '...\n' >> .github/workflows/check-test.yml
expect_fail "check 13: a document end marker is refused" \
  "carries a YAML document marker"
git checkout -- .github/workflows/check-test.yml
# ...and a line-1 marker carrying content: `--- |` makes the whole document one string to YAML.
perl -0pi -e 's{\A}{--- |\n}' .github/workflows/check-test.yml
expect_fail "check 13: a line-1 document marker with content after it is refused" \
  "carries a YAML document marker"
git checkout -- .github/workflows/check-test.yml
# 33p4 — the top-level allowlist: `true:` is the key `on:` is to a YAML 1.1 parser, so a block under
# it is a second trigger key the on-count arm cannot see...
printf 'true:\n  workflow_dispatch:\n' >> .github/workflows/check-test.yml
expect_fail "check 13: a top-level key outside the allowlist is refused" \
  "has top-level key true"
git checkout -- .github/workflows/check-test.yml
# 33p5 — ...and a column-0 line that is no plain key: `on :` is the key `on` to YAML.
printf 'on :\n  workflow_dispatch:\n' >> .github/workflows/check-test.yml
expect_fail "check 13: a column-0 line it cannot read as a key is refused" \
  "cannot read as a top-level key"
git checkout -- .github/workflows/check-test.yml
# 33p6 — the event allowlist under `on:`: an event this check reasons nothing about.
perl -0pi -e "s{\non:\n}{\non:\n  workflow_dispatch:\n}" .github/workflows/check-test.yml
expect_fail "check 13: an event under on: outside the allowlist is refused" \
  "on: carries event workflow_dispatch"
git checkout -- .github/workflows/check-test.yml
# 33p7 — and the two spellings the shape arms must NOT refuse: a quoted `"on":` is the same key, and
# a `---` on line 1 opens the one document rather than a second.
perl -0pi -e 's{\non:\n}{\n"on":\n}' .github/workflows/check-test.yml
expect_pass "check 13: a quoted top-level on: is read as on:"
git checkout -- .github/workflows/check-test.yml
perl -0pi -e 's{\A}{---\n}' .github/workflows/check-test.yml
expect_pass "check 13: a document start marker on line 1 is accepted"
git checkout -- .github/workflows/check-test.yml
# 33f — an entry under ANOTHER trigger cannot stand in for one missing from the pull-request
# filter. Under the flat scrape this line was read as coverage, so dropping `shared/**` from
# `pull_request:` passed green. `pull_request_target:` rather than `push:`, so the push arm above
# cannot claim the red.
perl -0pi -e "s{\non:\n}{\non:\n  pull_request_target:\n    paths:\n      - 'shared/**'\n}; s{\n *- 'shared/\\*\\*'\n( *- 'Makefile')}{\n\$1}" .github/workflows/check-test.yml
expect_fail "check 13: an entry under another trigger does not cover the pull-request filter" \
  "path filter has no 'shared/**'"
git checkout -- .github/workflows/check-test.yml
# 33g — the reader's fail-closed arm: an awk error is never read as an empty filter.
cp scripts/check.sh "$SCRATCH/check13.bak"
perl -pi -e 's{^(\s*)# A line in column 0 opens a top-level key.*$}{$1) (}' scripts/check.sh
expect_fail "check 13 reds when its trigger reader cannot run" \
  "could not read the triggers out of"
cp "$SCRATCH/check13.bak" scripts/check.sh
# 33h — the missing-file arms, pinned. Unpinned, each was fully substituted by a neighbour: a
# missing check-test.sh yields an empty `$GUARDED`, and a missing workflow now fails the trigger
# reader. Repointed inside check.sh rather than deleted, so this file is never removed while it runs.
perl -pi -e 's{^CT_FILE=scripts/check-test\.sh$}{CT_FILE=scripts/_no-such-check-test.sh}' scripts/check.sh
expect_fail "check 13 reds when check-test.sh is missing" \
  "scripts/check-test.sh is missing"
cp "$SCRATCH/check13.bak" scripts/check.sh
perl -pi -e 's{^CT_WF=\.github/workflows/check-test\.yml$}{CT_WF=.github/workflows/_no-such.yml}' scripts/check.sh
expect_fail "check 13 reds when its workflow is missing" \
  "is missing — the gate-of-the-gate has no workflow"
cp "$SCRATCH/check13.bak" scripts/check.sh

# 34 — check 14: a parent-pid lookup with no pattern reds (#265). The fixture is TEXT: the gate
# only reads it, nothing here or in check.sh executes it, and it opens with `exit 0` besides. The
# command word comes from a variable so that this file never spells the shape check 14 matches —
# the gate scans this file too, and exempting it would leave the likeliest place to add a
# violation unscanned.
PG=pgrep
SH_PROBE=plugins/ship/skills/ship/_probe.sh
printf '#!/usr/bin/env bash\nexit 0\nkids=$(%s -P "$x")\n' "$PG" > "$SH_PROBE"
expect_fail "check 14: a parent-pid pgrep with no pattern" \
  "pgrep/pkill with -P/--parent and no pattern"
# 34b — the long spelling, through a pipe, is the same lookup.
printf '#!/usr/bin/env bash\nexit 0\n%s --parent "$x" | head\n' "$PG" > "$SH_PROBE"
expect_fail "check 14: the --parent spelling with no pattern" \
  "pgrep/pkill with -P/--parent and no pattern"
# 34c — and the mirror: WITH a pattern the lookup filters correctly on both platforms, so the
# check must stay green on it. Without this, an arm that fired on every `-P` would read as caught.
printf '#!/usr/bin/env bash\nexit 0\nkids=$(%s -P "$x" sleep)\n' "$PG" > "$SH_PROBE"
expect_pass "check 14: a parent-pid pgrep WITH a pattern stays green"
# 34d — the incident's own line: a redirection after the options is not a pattern. The first
# draft of check 14 read `2>/dev/null` as one and passed exactly this line.
printf '#!/usr/bin/env bash\nexit 0\norphans=$(%s -P "$cpid" 2>/dev/null | tr x y)\n' "$PG" > "$SH_PROBE"
expect_fail "check 14: the incident line, with a redirection after the options" \
  "pgrep/pkill with -P/--parent and no pattern"
# 34e — the lookup inside a quoted `sh -c` string: the command word carries the quote.
printf '#!/usr/bin/env bash\nexit 0\nkids=$(sh -c "%s -P $x")\n' "$PG" > "$SH_PROBE"
expect_fail "check 14: a no-pattern lookup inside sh -c \"...\"" \
  "pgrep/pkill with -P/--parent and no pattern"
# 34e2 — and the alias-bypassing backslash form.
printf '#!/usr/bin/env bash\nexit 0\nkids=$(\\%s -P "$x")\n' "$PG" > "$SH_PROBE"
expect_fail "check 14: a backslash-escaped command word" \
  "pgrep/pkill with -P/--parent and no pattern"
# 34e3 — a quoted word holding a space is one word (#272): split on whitespace, `$b"` read as the
# pattern and this passed. Then the same through a redirect target, and a word after the quoted
# `sh -c` string, which is sh's argument and not pgrep's pattern.
printf '#!/usr/bin/env bash\nexit 0\nkids=$(%s -P "$a $b")\n' "$PG" > "$SH_PROBE"
expect_fail "check 14: a quoted -P argument holding a space" \
  "pgrep/pkill with -P/--parent and no pattern"
printf '#!/usr/bin/env bash\nexit 0\nkids=$(%s -P "$x" 2>"$d/a b")\n' "$PG" > "$SH_PROBE"
expect_fail "check 14: a quoted redirect target holding a space" \
  "pgrep/pkill with -P/--parent and no pattern"
printf '#!/usr/bin/env bash\nexit 0\nkids=$(sh -c "%s -P $x" arg)\n' "$PG" > "$SH_PROBE"
expect_fail "check 14: a word after the quoted sh -c string" \
  "pgrep/pkill with -P/--parent and no pattern"
# 34e4 — a quoted command that does not open with the lookup is still read as a command, so
# collapsing quoted words did not blind the sh -c case.
printf '#!/usr/bin/env bash\nexit 0\nkids=$(sh -c "cd /d && %s -P $x")\n' "$PG" > "$SH_PROBE"
expect_fail "check 14: a lookup later in a quoted sh -c string" \
  "pgrep/pkill with -P/--parent and no pattern"
# 34e5 — and the mirror: a process substitution before the pattern is one argument, so the real
# pattern after it is reached and the line stays green.
printf '#!/usr/bin/env bash\nexit 0\nkids=$(%s -P "$x" <(true) sleep)\n' "$PG" > "$SH_PROBE"
expect_pass "check 14: a process substitution before the pattern stays green"
# 34e6 — what reading quotes must NOT lose: a quoted command word, a lookup inside a process
# substitution, and one inside a `$(...)` within double quotes (all caught before quotes were
# read, and missed by a draft that read them), plus the single-quoted form of 34e3's word after
# an `sh -c` string...
printf '#!/usr/bin/env bash\nexit 0\nkids=$("%s" -P "$x")\n' "$PG" > "$SH_PROBE"
expect_fail "check 14: a quoted command word" \
  "pgrep/pkill with -P/--parent and no pattern"
printf '#!/usr/bin/env bash\nexit 0\nkids=$(sh -c \047%s -P $x\047 arg)\n' "$PG" > "$SH_PROBE"
expect_fail "check 14: a word after a single-quoted sh -c string" \
  "pgrep/pkill with -P/--parent and no pattern"
printf '#!/usr/bin/env bash\nexit 0\nwhile read -r p; do :; done < <(%s -P "$x")\n' "$PG" > "$SH_PROBE"
expect_fail "check 14: a lookup inside a process substitution" \
  "pgrep/pkill with -P/--parent and no pattern"
printf '#!/usr/bin/env bash\nexit 0\nkids="$(sh -c "%s -P $x")"\n' "$PG" > "$SH_PROBE"
expect_fail "check 14: a quoted sh -c inside a double-quoted \$(...)" \
  "pgrep/pkill with -P/--parent and no pattern"
# 34e7 — ...and the mirror: the quotes of a `$(...)` within double quotes do not close the outer
# span, so a lookup there WITH a pattern stays green.
printf '#!/usr/bin/env bash\nexit 0\nkids="$(%s -P "$x" sleep)"\n' "$PG" > "$SH_PROBE"
expect_pass "check 14: a double-quoted \$(...) lookup WITH a pattern stays green"
# 34e8 — a quoted command word that IS the command word, though it holds a blank (#272): on a
# path holding a space, in either quote style, and with a leading blank. Each was read as a
# nested command, cut off from its `-P`, and passed.
PK=pkill
printf '#!/usr/bin/env bash\nexit 0\nkids=$("$d/a b/%s" -P "$x")\n' "$PG" > "$SH_PROBE"
expect_fail "check 14: a quoted command word on a path holding a space" \
  "pgrep/pkill with -P/--parent and no pattern"
printf '#!/usr/bin/env bash\nexit 0\n\047/opt/my tools/%s\047 -P "$x"\n' "$PK" > "$SH_PROBE"
expect_fail "check 14: a single-quoted pkill path holding a space" \
  "pgrep/pkill with -P/--parent and no pattern"
printf '#!/usr/bin/env bash\nexit 0\nkids=$(" %s" -P "$x")\n' "$PG" > "$SH_PROBE"
expect_fail "check 14: a quoted command word with a leading blank" \
  "pgrep/pkill with -P/--parent and no pattern"
# ...while a quoted command string that merely ENDS in the command word is still read as the
# command it is: a draft that kept every such span whole hid the lookup at its start.
printf '#!/usr/bin/env bash\nexit 0\nkids=$(sh -c "%s -P $x; /usr/bin/%s")\n' "$PG" "$PG" > "$SH_PROBE"
expect_fail "check 14: a lookup in a quoted sh -c string that ends in the command word" \
  "pgrep/pkill with -P/--parent and no pattern"
# 34e9 — and the mirrors: the same quoted path WITH a pattern, and a quoted path as the pattern.
printf '#!/usr/bin/env bash\nexit 0\nkids=$("$d/a b/%s" -P "$x" sleep)\n' "$PG" > "$SH_PROBE"
expect_pass "check 14: a quoted command path holding a space WITH a pattern stays green"
printf '#!/usr/bin/env bash\nexit 0\nkids=$(%s -P "$x" "/opt/a b/%s")\n' "$PG" "$PG" > "$SH_PROBE"
expect_pass "check 14: a quoted path holding a space as the pattern stays green"
rm -f "$SH_PROBE"

# 34f — check 14's fail-closed arms, in the shapes 14a and 14b use. The listing errors with its
# output intact, so the empty-list arm cannot explain the red...
cp scripts/check.sh "$SCRATCH/check14.bak"
perl -pi -e "s{^(pg_files=\\\$\\(git .*'\\*\\.sh')\\)}{\$1; exit 128)}" scripts/check.sh
expect_fail "check 14 reds when its shell-file listing errors" \
  "could not list shell files for the parent-pid lookup scan"
cp "$SCRATCH/check14.bak" scripts/check.sh
# 34g — ...the listing succeeds and matches nothing: awk handed no file would read stdin and
# report no hit, so this arm is what stops an empty scan reading as a clean one...
perl -pi -e "s{^(pg_files=\\\$\\(git .*)'\\*\\.sh'\\)}{\$1'*.no-such-ext')}" scripts/check.sh
expect_fail "check 14 reds when it finds no shell file to scan" \
  "found no shell file to read"
cp "$SCRATCH/check14.bak" scripts/check.sh
# 34h — ...and the matcher itself fails: an awk error is never read as "no hits".
perl -pi -e 's{^(\s*function optarg\(t, j, n\) \{)$}{$1 ) (}' scripts/check.sh
expect_fail "check 14 reds when its matcher cannot run" \
  "parent-pid lookup scan (check 14) could not run"
cp "$SCRATCH/check14.bak" scripts/check.sh

# 35 — check 10b: two tests in one suite sharing a number red (#149). Registered, so that check
# 10's unregistered arm cannot fire and claim the catch, and in the SHIPYARD suite so the arm is
# proven to run outside council.
SY_DIR=plugins/shipyard/skills/shipyard/tests
perl -pi -e 's{^tests=\(}{tests=(t1-probe-dup.sh }' "$SY_DIR/run-all.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$SY_DIR/t1-probe-dup.sh"
expect_fail "check 10b: two tests in one suite share a number" \
  "share the number t1"
rm -f "$SY_DIR/t1-probe-dup.sh"
git checkout -- "$SY_DIR/run-all.sh"
# 35b — the letter-suffix scheme (`t9`, `t9b`) is distinct numbers by construction, so a new
# suffix next to an existing number stays green.
perl -pi -e 's{^tests=\(}{tests=(t1z-probe.sh }' "$RUNNER"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TESTS_DIR/t1z-probe.sh"
expect_pass "check 10b: a letter suffix on an existing number stays green"
rm -f "$TESTS_DIR/t1z-probe.sh"
git checkout -- "$RUNNER"

# 37 — check 15, section cross-references (#213). 37a is the issue's own kill test: a reference in
# the core renumbered past its last subsection, the edit shape that breaks these for real.
perl -pi -e 's/§5\.11/§5.99/' "$CORE"
expect_fail "a dangling section cross-reference in the core" "§5.99"
git checkout -- "$CORE"
# 37b — the same in an untracked file, resolving against neither its own headings nor the core's.
mkdir -p docs
printf 'see §42.7 for the details\n' > docs/_probe.md
expect_fail "a dangling section cross-reference in an untracked file" "docs/_probe.md:1: §42.7"
# 37c — ...and resolved by a heading of the file's own, including a bare section with a trailing
# sentence dot, which is not part of the number.
printf '## 42. A probe\n\n### 42.7 Its subsection\n\nsee §42.7, and all of §42.\n' > docs/_probe.md
expect_pass "a section cross-reference resolved by the file's own heading"
rm -f docs/_probe.md
# 37d — the scan cannot run: a markdown file it cannot open (a dangling symlink) is a red, never a
# file quietly skipped.
ln -s "$SCRATCH/no-such-file" docs/_probe.md
expect_fail "check 15 fails LOUDLY when its scan cannot run (not open)" "check 15) could not run"
rm -f docs/_probe.md
rmdir docs 2>/dev/null || true
# 37e — an untracked local skill is none of this check's business, like checks 1, 2, 5 and 14;
# 37b is the counter-test that keeps the exemption from reaching any other untracked file.
mkdir -p .claude/skills/_probe-local
printf -- '---\nname: _probe-local\ndescription: A local skill.\n---\n\nsee §42.7\n' \
  > .claude/skills/_probe-local/SKILL.md
expect_pass "a dangling reference in an untracked local skill stays green"
rm -rf .claude/skills/_probe-local
# 37f — the fail-closed arms: a core with no numbered heading, a core that is gone, and a listing
# that matched no markdown file at all.
perl -pi -e 's/^(#{1,4}) +([0-9])/$1 x$2/' "$CORE"
expect_fail "check 15 fails LOUDLY when the core has no numbered heading" \
  "check 15) found no numbered heading"
git checkout -- "$CORE"
rm "$CORE"
expect_fail "check 15 fails LOUDLY when the core is missing" "cannot find the core it resolves against"
git checkout -- "$CORE"
GIT_LITERAL_PATHSPECS=1 expect_fail "check 15 fails LOUDLY when it lists no markdown file" \
  "check 15) found no markdown file to read"
# 37g — the listing errors, in 34f's shape: the output is kept, so only its status can red.
cp scripts/check.sh "$SCRATCH/check15.bak"
perl -pi -e "s{^(xr_files=\\\$\\(git .*'\\*\\.md')\\)}{\$1; exit 128)}" scripts/check.sh
expect_fail "check 15 fails LOUDLY when its markdown listing errors (not open)" \
  "could not list markdown files for the section cross-reference check"
cp "$SCRATCH/check15.bak" scripts/check.sh
# 37h — the scan finds no reference at all, in 34g's shape: the listing narrowed to one file that
# carries none. The core is read for its headings only, so it cannot supply one.
mkdir -p docs
printf 'no section reference here\n' > docs/_probe.md
perl -pi -e "s{^(xr_files=\\\$\\(git .*)'\\*\\.md'\\)}{\$1'docs/_probe.md')}" scripts/check.sh
expect_fail "check 15 fails LOUDLY when it finds no section reference" \
  "found no section reference in any markdown file"
cp "$SCRATCH/check15.bak" scripts/check.sh
rm -f docs/_probe.md
rmdir docs 2>/dev/null || true

# 38 — the listings of checks 1 to 6, each captured with its status and counted (#58). Before,
# every one was a `done < <(...)` or a raw glob, so a listing that errored or matched nothing ran
# zero iterations and the gate printed `check: OK` with the assertion gone. Each arm is proven in
# the shapes 14a and 14b use: the status forced with the output kept (so only the status arm can
# red), and the listing repointed at nothing (what a moved or renamed tree looks like). Edited
# into check.sh rather than reproduced by moving a tree, for 14's reason: an interrupted `git mv`
# is staged, and the restore cannot undo it. Every one is pinned, since several share a listing.
cp scripts/check.sh "$SCRATCH/check38.bak"
c38() { expect_fail "$1" "$2"; cp "$SCRATCH/check38.bak" scripts/check.sh; }
perl -pi -e "s{^(sh_ls=.*'\\*\\.sh')\\)\$}{\$1; exit 128)}" scripts/check.sh
c38 "check 1 listing fails LOUDLY when git ls-files errors" "could not list shell scripts for the syntax check"
perl -pi -e "s{^(sh_ls=.*)'\\*\\.sh'\\)\$}{\$1'*.shx')}" scripts/check.sh
c38 "check 1 fails LOUDLY when it finds no shell script" "the syntax check (check 1) found no shell script"
perl -pi -e "s{^(skillmd_ls=.*'\\*SKILL\\.md')\\)\$}{\$1; exit 128)}" scripts/check.sh
c38 "checks 2 and 5 listing fails LOUDLY when git ls-files errors" "could not list SKILL.md files"
perl -pi -e "s{^(skillmd_ls=.*)'\\*SKILL\\.md'\\)\$}{\$1'*SKILL.mdx')}" scripts/check.sh
c38 "checks 2 and 5 fail LOUDLY when they find no SKILL.md" "found no SKILL.md file at all"
perl -pi -e 's{^(plugins_ls=.*-- plugins/)\)$}{$1; exit 128)}' scripts/check.sh
c38 "checks 3 and 4 listing fails LOUDLY when git ls-files errors" "could not list plugins/"
perl -pi -e 's{^(plugins_ls=.*-- )plugins/\)$}{${1}plugins-moved/)}' scripts/check.sh
c38 "checks 3 and 4 fail LOUDLY when they find no plugin" "found no plugin under plugins/"
perl -pi -e 's{^core=plugins/ship/skills/ship/SKILL\.md$}{core=plugins/shipcore/skills/ship/SKILL.md}' scripts/check.sh
c38 "check 6 reds when the core skill is gone, rather than skipping itself" "check 6 cannot find the core skill"
perl -pi -e "s{^(  refs_ls=.*\\.md\")\\)\$}{\$1; exit 128)}" scripts/check.sh
c38 "check 6 reference listing fails LOUDLY when git ls-files errors" "could not list the forge reference files"
perl -pi -e 's{^ref_dir=plugins/ship/skills/ship/references$}{ref_dir=plugins/ship/skills/ship/refs}' scripts/check.sh
c38 "check 6 fails LOUDLY when it finds no forge reference file" "check 6 found no forge reference file"

# 38b — check 4's extractor dies on a value that is valid JSON: the issue's own reproduction. The JSON
# arm passes it, so only the captured status can red; before, not one entry was asserted.
perl -pi -e 's{"path": "\./plugins/ship"}{"path": 123}' .agents/plugins/marketplace.json
expect_fail "check 4 reds when it cannot read a manifest's entries" \
  "could not read the plugin entries of .agents/plugins/marketplace.json"
git checkout -- .agents/plugins/marketplace.json
# 38c — ...and a manifest with no entry at all. The manifests-vs-disk arm reds on the same edit, so
# the pin is what says this arm fired.
python3 - <<'PY'
import json
for p in (".claude-plugin/marketplace.json", ".agents/plugins/marketplace.json"):
    d = json.load(open(p))
    d["plugins"] = []
    json.dump(d, open(p, "w"), indent=2)
PY
expect_fail "check 4 reds on a manifest that lists no plugin" "marketplace manifest lists no plugin"
git checkout -- .claude-plugin .agents/plugins

# 38d — check 6's grep erroring on a reference file is not "the state name is absent". A dangling
# symlink is a file the listing names and grep cannot open, the technique 37d uses; check 15 reds on
# it too, so the pin keeps this probe on check 6's arm.
ln -s "$SCRATCH/no-such-file" plugins/ship/skills/ship/references/_probe-dangling.md
expect_fail "check 6 fails LOUDLY when grep cannot read a reference" "check 6 could not read forge reference"
rm -f plugins/ship/skills/ship/references/_probe-dangling.md

# 38e — a packaged skill's link dropped from the index while it still resolves on disk: a staged
# deletion that the next commit makes, and that every other link assertion passes. A throwaway
# index, as in 5a, so the repo's own index is never touched and an interrupt leaves a scratch file.
cp "$(git rev-parse --git-path index)" "$SCRATCH/drop-index"
GIT_INDEX_FILE="$SCRATCH/drop-index" git rm -q --cached -- .claude/skills/ship
export GIT_INDEX_FILE="$SCRATCH/drop-index"
expect_fail "a packaged skill's link dropped from the index reds" \
  "packaged skill 'ship' link is in HEAD but dropped from the index"
unset GIT_INDEX_FILE

# 38f — the other direction (#58): incidental untracked state under plugins/ is none of checks 3, 4
# and 6's business once git is not listing it. An empty scratch directory (git lists files, not
# directories), and one whose own `.gitignore` ignores everything in it — the escape hatch a raw
# glob never honoured; either reds a checks 3 and 4 that went back to `plugins/*/`. Under
# references/, every fixture carries a real state name, in two places that prove different things:
#   * directly under it, ignored through `core.excludesFile` pointed at a file in $SCRATCH for this
#     one run, so no ignore file lands in the tree -- a `references/.gitignore` is a name a person
#     might keep there, and `--recover` removes every path in PROBE_FILES. This is the one a check 6
#     that went back to its `references/*.md` glob would red on;
#   * in a subdirectory, ignored by its own `.gitignore`. The glob never reached there, so this one
#     proves only that the recursive git pathspec honours `--exclude-standard`.
# The hollow-plugin probe (10) is the counter-test: an untracked plugin that is NOT ignored is still
# checked in full.
# 38g — a plugin that is a directory symlink is ONE listing entry, `plugins/<name>`, with no path
# below it. The glob checks 3 and 4 used to iterate followed it, so the listing must keep it: here
# it points at a real plugin under another name, which only check 3 reading it can report.
ln -s ship plugins/_probe-link
expect_fail "checks 3 and 4 still read a plugin that is a directory symlink" \
  "manifest name 'ship' != directory '_probe-link'"
rm -f plugins/_probe-link

REFS=plugins/ship/skills/ship/references
mkdir -p plugins/_probe-scratch-empty plugins/_probe-scratch "$REFS/_probe-scratch"
printf '*\n' > plugins/_probe-scratch/.gitignore
printf 'notes\n' > plugins/_probe-scratch/notes.md
# The setting lives in this process's environment only, never in any config file. It REPLACES the
# excludes file git would otherwise read, so that file is seeded with the one the baseline run saw
# -- the configured `core.excludesFile`, else git's default location -- and the probe line is
# appended to it (#58): without the seed, a file the user's own ignore rules hide (an ignored
# `references/todo.local.md` naming a state) would reappear for this run alone and red it with
# nothing wrong in the repo. For the same reason a `GIT_CONFIG_COUNT` the caller already passes is
# extended, not overwritten.
user_excl=$(git config --path core.excludesFile 2>/dev/null) \
  || user_excl="${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore"
{
  if [ -f "$user_excl" ]; then cat "$user_excl"; echo; fi
  printf '/%s/_probe-ignored.md\n' "$REFS"
} > "$SCRATCH/probe-exclude"
printf 'Stages: need-issue then ready-to-merge.\n' > "$REFS/_probe-ignored.md"
printf '*\n' > "$REFS/_probe-scratch/.gitignore"
printf 'Stages: need-issue then ready-to-merge.\n' > "$REFS/_probe-scratch/notes.md"
cfg_n=${GIT_CONFIG_COUNT:-0}
case $cfg_n in ''|*[!0-9]*) cfg_n=0 ;; esac
cfg_prev=${GIT_CONFIG_COUNT-unset}
export GIT_CONFIG_COUNT=$((cfg_n + 1)) "GIT_CONFIG_KEY_$cfg_n=core.excludesFile" \
  "GIT_CONFIG_VALUE_$cfg_n=$SCRATCH/probe-exclude"
expect_pass "an empty or ignored scratch directory under plugins/ stays green"
unset "GIT_CONFIG_KEY_$cfg_n" "GIT_CONFIG_VALUE_$cfg_n"
if [ "$cfg_prev" = unset ]; then unset GIT_CONFIG_COUNT; else export GIT_CONFIG_COUNT="$cfg_prev"; fi
rm -rf plugins/_probe-scratch-empty plugins/_probe-scratch "$REFS/_probe-scratch" "$REFS/_probe-ignored.md"

# 39 — check 16, the macOS floor job against the tests that need it (#337). 39a is the issue's own
# kill test: a floor test the job stops running. 39b-39d, 39h and 39i pin what the derivation counts
# and what it does not; 39e-39g are the fail-closed arms.
FLWF=.github/workflows/ci.yml
FLT=plugins/shipyard/skills/shipyard/tests/t1-totals.sh
perl -pi -e 's{^(\s*run: )bash (plugins/shipyard/skills/shipyard/tests/t19-occupant\.sh)\s*$}{$1true $2\n}' "$FLWF"
expect_fail "a floor test the macOS job does not run" \
  "t19-occupant.sh runs code under /bin/bash, which is 5.x on Linux, but the macOS bash32-floor job"
git checkout -- "$FLWF"
# 39b — a test outside the job that starts running code under /bin/bash reds...
printf '/bin/bash -c true\n' >> "$FLT"
expect_fail "a new /bin/bash line in a test the job does not run" "t1-totals.sh runs code under /bin/bash"
git checkout -- "$FLT"
# 39c — ...unless that line says it is not a floor, where it is written.
printf '/bin/bash -c true   # floor-exempt: probe\n' >> "$FLT"
expect_pass "a /bin/bash line marked floor-exempt stays green"
git checkout -- "$FLT"
# 39d — a re-exec candidate list, a comment and a message name the path without running it there.
printf 'for c in /opt/homebrew/bin/bash /usr/bin/bash; do :; done\n# runs under /bin/bash\necho "stock /bin/bash is 3.2"\n' >> "$FLT"
expect_pass "a re-exec candidate, a comment and an echo naming /bin/bash stay green"
git checkout -- "$FLT"
# 39h — a floor line followed by more than a pipe buffer of text is still derived. The derivation's
# last stage used to be `grep -q`, whose early exit SIGPIPEs the stage feeding it under pipefail, so
# a file like t7 (its match 30 KB from the end) dropped out about three runs in ten. About 1.3 MB of
# live lines after the match puts it past GNU grep's read buffer as well as BSD grep's (80 KB still
# passed under GNU `-q` every time), so a return to `-q` reds here on either platform.
perl -0pi -e 's{\A(#![^\n]*\n)}{$1/bin/bash -c true\n}' "$FLT"
perl -e 'print ": padding line so the floor match sits far from the end of the file\n" x 20000' >> "$FLT"
expect_fail "a floor line far from the end of a test is still derived" "t1-totals.sh runs code under /bin/bash"
git checkout -- "$FLT"
# 39i — the `${X:-/bin/bash}` default is a floor too: it is how t15 picks its interpreter.
printf 'b=${SOME_BASH:-/bin/bash}\n' >> "$FLT"
expect_fail "a \${X:-/bin/bash} default in a test the job does not run" "t1-totals.sh runs code under /bin/bash"
git checkout -- "$FLT"
# 39e — a job step naming a file that is not there.
perl -pi -e 's{tests/t19-occupant\.sh}{tests/t19-gone.sh}' "$FLWF"
expect_fail "the macOS job runs a test that does not exist" \
  "runs a test that does not exist: plugins/shipyard/skills/shipyard/tests/t19-gone.sh"
git checkout -- "$FLWF"
# 39f — the job renamed: nothing to compare against is a red, never a pass.
perl -pi -e 's{^  bash32-floor:}{  bash32-floor-renamed:}' "$FLWF"
expect_fail "check 16 fails LOUDLY when it finds no floor job" 'check 16) found no `run: bash <path>` step'
git checkout -- "$FLWF"
# 39g — the derivation matches nothing: a floor check that found no floor test compared nothing.
cp scripts/check.sh "$SCRATCH/check16.bak"
perl -pi -e 's{\)/bin/bash\(\[}{)/bin/NO-SUCH-BASH([}' scripts/check.sh
expect_fail "check 16 fails LOUDLY when it derives no floor test" \
  "check 16) found no test that runs anything under /bin/bash"
cp "$SCRATCH/check16.bak" scripts/check.sh

# 36 — this file's own entry arms (#136): the run marker and the leftover-fixture refusal. They are
# not gate assertions, so they are proven by running this script a second time, NESTED, and reading
# how it refuses. Every nested run below must refuse before it arms a trap or mutates anything,
# because a nested run that got past its entry guards would start a second full run over this
# tree. So each one without --recover (which never reaches a run) is given a non-Latin byte that
# reds the gate — in a file under `docs/`, the exact state #136 measured, or in 36g inside its own
# Makefile edit — which makes a broken arm fall to another refusal, or to `BASELINE DIRTY`, and
# report here as a wrong arm rather than run.
# $1 label, $2 the exit status wanted, $3 a fixed string the nested output must contain, then the
# nested run's arguments.
expect_nested() {
  local label=$1 want=$2 pin=$3 got; shift 3
  bash scripts/check-test.sh "$@" >"$SCRATCH/nested" 2>&1; got=$?
  if [ "$got" -ne "$want" ]; then
    echo "NOT CAUGHT: $label (nested exit $got, wanted $want): $(grep -m1 . "$SCRATCH/nested" | cut -c1-70)"
    nocatch=$((nocatch+1))
  elif ! grep -qF -- "$pin" "$SCRATCH/nested"; then
    echo "WRONG ARM:  $label"
    echo "            expected: $pin"
    echo "            got:      $(grep -m1 . "$SCRATCH/nested" | cut -c1-70)"
    nocatch=$((nocatch+1))
  else
    echo "caught:     $label"
    pass=$((pass+1))
  fi
}
mkdir -p docs
printf 'probe \320\226\n' > docs/_probe.md
# 36a — this run's own marker names a live run, so a second run refuses and says the fixtures in
# the tree are live. This is the case that cost the wrong revert.
expect_nested "a second run refuses while this one is live" 2 "a check-test run is in progress"
# 36b — the marker of a run that died, with its leftover outside $GUARDED: named as this file's own
# fixture, not reported as a repository violation. A pid that has just exited stands in for it.
( : ) & dead=$!; wait "$dead"
printf 'pid=%s\nstarted=probe\n' "$dead" > "$MARKER"
expect_nested "a killed run's leftover is named as check-test's own" 2 "left by a run that did not finish"
# 36c — the same marker with a probe edit under $GUARDED: the dirty-tree refusal says whose it
# most likely is.
printf '# probe\n' >> Makefile
# Pinned on the dirty-tree refusal's own line, since the leftover arm prints the attribution too;
# the attribution is then required of that same output.
expect_nested "a killed run's edit under \$GUARDED is attributed to it" 2 "uncommitted or untracked changes under"
if ! grep -qF "did not finish (pid $dead" "$SCRATCH/nested"; then
  echo "NOT CAUGHT: the dirty-tree refusal does not name the dead run"; nocatch=$((nocatch+1))
fi
# 36d — --recover restores both and removes the marker.
expect_nested "--recover restores what a killed run left" 0 "recovered" --recover
if [ -e docs/_probe.md ] || [ -e "$MARKER" ] || ! git diff --quiet -- Makefile; then
  echo "NOT CAUGHT: --recover left something behind"; nocatch=$((nocatch+1))
fi
# 36e — a marker whose pid is alive but running something else (a reused pid) is a dead run, not a
# live one: without the command check it would block every run as 'in progress' for ever.
mkdir -p docs
printf 'probe \320\226\n' > docs/_probe.md
( exec sleep 60 ) & other=$!
# Until the exec lands, the child still shows this script's command line, which reads as live.
for _ in $(seq 1 100); do
  ps -p "$other" -o command= 2>/dev/null | grep -q 'check-test\.sh' || break
done
printf 'pid=%s\nstarted=probe\n' "$other" > "$MARKER"
expect_nested "a marker naming a reused pid reads as a dead run" 2 "did not finish (pid $other"
kill "$other" 2>/dev/null; wait "$other" 2>/dev/null
rm -f "$MARKER" docs/_probe.md
# 36f — --recover with no marker and no probe fixture does not treat a change as a leftover: it
# would otherwise discard the user's own work on request of a stale hint.
printf '# probe\n' >> Makefile
expect_nested "--recover refuses changes nothing marks as check-test's" 2 "not assumed to be check-test's" --recover
git checkout -- Makefile
# 36g — a dead run's marker with an edit under $GUARDED and NO probe fixture: the refusal names the
# run but says the edit may be the user's own. The gate-reddening byte rides IN that edit (#58), so
# no probe fixture exists for the fixture branch to claim the output with, and nothing untracked is
# left for a SIGKILL here to strand: the Makefile is under $GUARDED, so the next run's dirty-tree
# refusal names it and --recover restores it. A separate untracked note file did both jobs before and
# was neither listed by that refusal nor by --recover.
( : ) & dead=$!; wait "$dead"
printf 'pid=%s\nstarted=probe\n' "$dead" > "$MARKER"
printf '# probe \320\226\n' >> Makefile
expect_nested "a dead run's marker without a fixture does not claim the edit" 2 "no probe fixture was found"
git checkout -- Makefile
rm -f "$MARKER"
expect_nested "--recover with nothing to recover" 0 "nothing to recover" --recover
rmdir docs 2>/dev/null || true
# Not probed: the `note:` line for a stale marker over a clean tree. A nested run there passes every
# guard, so only a gate arm (BASELINE DIRTY) would stop it — and if that arm regressed, the nested
# run would start a full run of its own, reach this same probe and nest again without end.
write_marker

echo
echo "assertions proven: $pass   not proven: $nocatch"
[ "$nocatch" -eq 0 ] || exit 1
make check >/dev/null 2>&1 || { echo "gate not green after restore"; exit 1; }

# THE WHOLE TREE, not just $GUARDED, and that difference is the point. Every probe above restores
# with `git checkout -- $GUARDED`, so $GUARDED is an upper bound on what this file may mutate —
# which is exactly the property check 13 derives the CI path filter from. Nothing enforced it:
# a probe that mutated a path outside the list would restore nothing, leave the tree dirty, and
# be noticed only by whoever ran `make check-test` NEXT and hit the dirty-tree guard at the top —
# which in CI, on a fresh checkout every time, is nobody, ever.
#
# So assert it here, on the run that would introduce it. `--untracked-files=all` for the same
# reason the guard at the top uses it: `git diff` cannot see a file that was never in git, and a
# stray probe file is the commonest way this fails.
post=$(git status --porcelain --untracked-files=all)
# Only what THIS RUN changed: subtract the snapshot taken at admission. An empty snapshot makes
# `grep -vxF -f` pass every line through, which is the right answer — on a clean tree every
# remaining entry is new.
#
# `-x` IS LOAD-BEARING AND DROPPING IT FAILS SILENTLY IN THE GREEN DIRECTION. The pattern file
# holds one empty line whenever the snapshot is empty. With `-x` an empty pattern matches only an
# empty line, so `-v` keeps every real entry; WITHOUT `-x` it matches every line, `-v` discards
# all of them, and `$left` is unconditionally empty — this assertion then passes on any tree,
# including one a probe left dirty, which is the single thing it exists to catch. Verified both
# ways on GNU grep 3.12 and on BSD grep: with `-x`, two of two lines survive; without it, zero.
# So do not "simplify" this to `grep -vF`.
#
# One residual, since a guard whose limits are undocumented gets trusted past them: subtraction is
# by whole status LINE, so a probe that mutates a file which was ALREADY dirty at admission and
# outside $GUARDED leaves the line unchanged (` M path` before and after) and is subtracted with
# it. The entry guard above rules this out for every $GUARDED path; outside that list it is the
# price of not crying wolf over an ordinary uncommitted edit.
left=$(printf '%s\n' "$post" | grep -vxF -f <(printf '%s\n' "$PRE_STATUS") | grep -v '^$')
if [ -n "$left" ]; then
  echo "check-test left the tree dirty — a probe mutated something it does not restore:"
  printf '%s\n' "$left"
  echo "add its path to \$GUARDED (and to the CI filter check 13 derives from it), or restore it inline"
  echo "(paths already dirty when this run started are excluded, so every line above is this run's)"
  exit 1
fi
echo "check-test: OK"
