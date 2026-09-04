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
set -uo pipefail
cd "$(dirname "$0")/.."

CORE=plugins/ship/skills/ship/SKILL.md
TESTS_DIR=plugins/council/skills/council/tests
RUNNER=$TESTS_DIR/run-all.sh
GUARDED='.claude .agents plugins scripts .claude-plugin'

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
  echo "this test restores with 'git checkout --', which cannot recover untracked files" >&2
  exit 2
fi

SCRATCH=$(mktemp -d)
# Built from code points rather than written out, for the reason enprobe gives below: a literal
# would put the very bytes under test into this file. `ö` is Latin, so check 8 permits it either
# way -- what is under test is git's C-quoting, which fires on any byte >= 0x80.
NONASCII=$(printf '_probe-n\303\266n')
restore() {
  # shellcheck disable=SC2086
  git checkout -- $GUARDED 2>/dev/null || true
  # Only the entries this test replaces, never a whole directory.
  for s in .claude/skills .agents/skills; do
    rm -rf "$s/ship" "$s/shipyard" 2>/dev/null || true
  done
  # shellcheck disable=SC2086
  git checkout -- $GUARDED 2>/dev/null || true
  # Untracked probe files: `git checkout --` cannot bring these back OR take them away, so an
  # interrupt between writing one and its inline rm would leave it. A stray t99-probe.sh reds the
  # gate on its own assertion and then blocks the next run on the dirty-tree guard above.
  rm -rf docs/_probe.md "$SCRATCH" .claude/skills/_probe-local \
    plugins/ship/skills/_probe-skill .claude/skills/_probe-skill .agents/skills/_probe-skill \
    .claude/skills/_probe-tracked plugins/ship/skills/_probe-pkg plugins/ship/skills/ship/_probe.sh \
    ".claude/skills/$NONASCII" ".agents/skills/$NONASCII" "plugins/ship/skills/$NONASCII" \
    "$TESTS_DIR/t99-probe.sh" "$TESTS_DIR/t98-unregistered.sh" "$TESTS_DIR/nested" 2>/dev/null || true
  rmdir docs 2>/dev/null || true
}
trap restore EXIT

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
# Pass $2 for any probe whose arm has a neighbour that can substitute for it. FIVE probes below
# still need one and do not have it — the two hollow-plugin probes, `SKILL.md with no name:`,
# `missing marketplace manifest` and `invalid JSON in a marketplace manifest`. Delete the arm any
# of them names and this suite still reports it caught, so those five arms have no kill test. They
# are pre-existing and tracked in the follow-up issue rather than pinned here; do not read the
# absence of a $2 as evidence that a probe does not need one.
expect_fail() {
  if make check >"$SCRATCH/out" 2>&1; then
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
  if ! make check >"$SCRATCH/out" 2>&1; then
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

if make check >"$SCRATCH/out" 2>&1; then
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
expect_fail "missing .codex-plugin manifest"
git checkout -- plugins/ship/.codex-plugin/plugin.json

# 3b — a manifest's name disagrees with its directory
perl -pi -e 's/"name": "ship"/"name": "shipx"/' plugins/ship/.claude-plugin/plugin.json
expect_fail "manifest name != directory"
git checkout -- plugins/ship/.claude-plugin/plugin.json

# 3c — invalid JSON
printf 'oops' >> plugins/ship/.claude-plugin/plugin.json
expect_fail "invalid JSON in a plugin manifest"
git checkout -- plugins/ship/.claude-plugin/plugin.json

# 4a — a marketplace entry pointing at a directory that does not exist, with the basename
# still matching the entry name, so ONLY the existence branch can fire.
perl -pi -e 's{"source": "./plugins/ship"}{"source": "./plugins/gone/ship"}' .claude-plugin/marketplace.json
expect_fail "marketplace entry -> missing directory"
git checkout -- .claude-plugin/marketplace.json

# 4b — an entry pointing at a real directory under a DIFFERENT name, so only the
# name-agreement branch can fire. Split from 4a because one probe tripping both branches
# proves neither: deleting either check would leave the assertion passing.
perl -pi -e 's{"source": "./plugins/ship"}{"source": "./plugins/shipyard"}' .claude-plugin/marketplace.json
expect_fail "marketplace entry -> differently-named directory"
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
expect_fail "the two marketplace manifests list different plugins"
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
expect_fail "state enum copied into a forge reference"
git checkout -- plugins/ship/skills/ship/references/forge-github.md

# 6b — a state in the enum with no handler. `spec` is the real historical case: it is a
# PREFIX of `spec-review`, so an unanchored check passes and proves nothing.
perl -pi -e 's{"state": "need-issue\|issue-ready\|}{"state": "need-issue|issue-ready|spec|}' "$CORE"
expect_fail "enum state with no §7 handler"
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
probe 'someone@example.invalid'             'e-mail address'
probe 'run ~/.local/bin/mytool'             'personal bin path'
probe 'CFG=$HOME/.config/gh-someone'        'personal tool config dir'
probe 'ghp_AbCdEfGhIjKlMnOpQrStUvWx'        'GitHub token'
probe 'glpat-AbCdEfGhIjKlMnOpQrSt'          'GitLab token'
probe 'xoxb-AbCdEfGhIjKlMnOpQrSt'           'Slack token'
probe '-----BEGIN RSA PRIVATE KEY-----'     'private key header'
probe "date TZ=Europe/Somewhere"            'hardcoded timezone'

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
expect_fail "marketplace plugins do not match plugins/ on disk"
git checkout -- .claude-plugin .agents/plugins

# 9 — SKILL.md frontmatter: each field, and a skill tracked outside plugins/
perl -0pi -e 's/^---\nname: ship\n/---\nnome: ship\n/' "$CORE"
expect_fail "SKILL.md with no name:"
git checkout -- "$CORE"

perl -pi -e 's/^description: "Drive one change/descriptio: "Drive one change/' "$CORE"
expect_fail "SKILL.md with no description:"
git checkout -- "$CORE"

# Outside .claude/skills and .agents/skills on purpose — check 5 exempts those two paths from
# this loop, so a probe placed there would red NOTHING and report `NOT CAUGHT`. (It used to be the
# opposite problem: the old filesystem-driven check 5 caught it first, on the wrong arm. The
# placement is right either way, but the reason inverted, and the `expect_pass` probe at the end
# of this file now asserts precisely that a SKILL.md there stays green.)
mkdir -p docs/stray
printf -- '---\nname: stray\ndescription: A stray skill outside plugins/.\n---\n' \
  > docs/stray/SKILL.md
expect_fail "SKILL.md outside plugins/"
rm -rf docs/stray

# 10 — a plugin with manifests but no skills tree, then one with an empty skills tree
mkdir -p plugins/hollow/.claude-plugin plugins/hollow/.codex-plugin
printf '{"name":"hollow","description":"d"}\n' > plugins/hollow/.claude-plugin/plugin.json
printf '{"name":"hollow","description":"d","skills":"./skills/"}\n' > plugins/hollow/.codex-plugin/plugin.json
expect_fail "plugin with no skills/ directory"
mkdir -p plugins/hollow/skills
expect_fail "plugin with an empty skills/ directory"
rm -rf plugins/hollow

# 11 — the remaining gate assertions, so that "every assertion" is literally true
perl -0pi -e 's/\A---\n/name: ship\n/' "$CORE"
expect_fail "SKILL.md with no frontmatter"
git checkout -- "$CORE"

mv .agents/plugins/marketplace.json "$SCRATCH/mp.json"
expect_fail "missing marketplace manifest"
mv "$SCRATCH/mp.json" .agents/plugins/marketplace.json

printf 'oops' >> .agents/plugins/marketplace.json
expect_fail "invalid JSON in a marketplace manifest"
git checkout -- .agents/plugins/marketplace.json

# Moving the directory leaves its index entries behind, so check 5's link assertions and the
# packaged-skill loop red as well; $2 pins this probe to the arm it names.
mv .agents/skills "$SCRATCH/agents-skills"
expect_fail "missing project skills dir" "missing project skills dir"
mv "$SCRATCH/agents-skills" .agents/skills

perl -pi -e 's/^  "state": "need-issue/  "sate": "need-issue/' "$CORE"
expect_fail "state enum not found in the core skill"
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
# Kill condition: revert check 9 to `done < <(git ls-files …)` and this must report NOT CAUGHT.
cp scripts/check.sh "$SCRATCH/check9-list.bak"
perl -pi -e 's{"\$tests_dir/\*\.sh"\)}{"\$tests_dir/*.sh"; exit 128)}' scripts/check.sh
expect_fail "council-test listing fails LOUDLY when git ls-files errors (not open)"
cp "$SCRATCH/check9-list.bak" scripts/check.sh

# 14b — the listing succeeds and matches nothing, which is what a moved or renamed tests
# directory looks like: zero iterations, no error anywhere, and the assertion silently gone.
cp scripts/check.sh "$SCRATCH/check9-empty.bak"
perl -pi -e 's{^tests_dir=plugins/council/skills/council/tests$}{tests_dir=plugins/council/skills/council/tests-moved-away}' scripts/check.sh
expect_fail "council-test scan fails LOUDLY when it inspects no file at all"
cp "$SCRATCH/check9-empty.bak" scripts/check.sh

# 15 — a council test on disk that the runner never runs. Untracked, which is the state it is in
# during the `make check` just before `git add`, and deliberately free of the pre-run-root shape
# so that check 9 cannot fire and claim the catch instead.
cat > "$TESTS_DIR/t98-unregistered.sh" <<'PROBE'
#!/usr/bin/env bash
R="$COUNCIL_TEST_ROOT/t98"; rm -rf "$R"
PROBE
expect_fail "council test on disk but not registered in run-all.sh"
rm -f "$TESTS_DIR/t98-unregistered.sh"

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
perl -pi -e 's{^runner=\$tests_dir/run-all\.sh$}{runner=\$tests_dir/run-all-gone.sh}' scripts/check.sh
expect_fail "council test runner missing" "council test runner is missing"
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
rm -rf .claude/skills/_probe-local

# 19e — the counter-tests that keep 19b-d from being a hole. The SAME two violations under
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

# 25 — check 11: a vendored driver copy that drifts from the canonical reds the gate. Backup and
# restore by hand (not `git checkout --`) so the probe holds whether or not the spike is committed.
cp plugins/council/skills/council/lib/agent-driver.sh "$SCRATCH/drv-copy.bak"
printf '# drift\n' >> plugins/council/skills/council/lib/agent-driver.sh
expect_fail "shared driver copy drifted from canonical" "shared driver copy drifted"
cp "$SCRATCH/drv-copy.bak" plugins/council/skills/council/lib/agent-driver.sh

# 26 — check 11 fails CLOSED: a missing vendored copy reds too, it does not silently pass.
mv plugins/shipyard/skills/shipyard/agent-driver.sh "$SCRATCH/drv-copy2.bak"
expect_fail "a missing shared driver copy" "shared driver copy is missing"
mv "$SCRATCH/drv-copy2.bak" plugins/shipyard/skills/shipyard/agent-driver.sh

# 27 — check 11 fails CLOSED: a missing canonical reds the gate, it does not silently pass. Backup
# and restore by hand (like 25/26). check 1's bash -n also reds on the still-tracked missing file,
# so the unique $2 "shared driver canonical is missing" is what keeps this probe on check 11's arm.
mv shared/driver/agent-driver.sh "$SCRATCH/drv-canonical.bak"
expect_fail "a missing shared driver canonical" "shared driver canonical is missing"
mv "$SCRATCH/drv-canonical.bak" shared/driver/agent-driver.sh

# 28 — check 11 fails CLOSED: a missing target list reds the gate. targets.txt is not a *.sh file,
# so no other check touches it — this arm has no backstop but this probe.
mv shared/driver/targets.txt "$SCRATCH/drv-targets.bak"
expect_fail "a missing shared driver target list" "shared driver target list is missing"
mv "$SCRATCH/drv-targets.bak" shared/driver/targets.txt

# 29 — check 11's "compared nothing" guard: a target list with no active entries (only comments or
# blanks) reds the gate rather than passing green having compared zero copies. Same no-backstop arm
# as 28, and the one most likely to rot silently if the driver_n>0 guard is ever dropped.
cp shared/driver/targets.txt "$SCRATCH/drv-targets-empty.bak"
printf '# only a comment, no target paths\n' > shared/driver/targets.txt
expect_fail "an empty shared driver target list" "shared driver target list is empty"
cp "$SCRATCH/drv-targets-empty.bak" shared/driver/targets.txt

echo
echo "assertions proven: $pass   not proven: $nocatch"
[ "$nocatch" -eq 0 ] || exit 1
make check >/dev/null 2>&1 || { echo "gate not green after restore"; exit 1; }
echo "check-test: OK"
