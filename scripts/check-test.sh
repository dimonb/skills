#!/usr/bin/env bash
# Prove every assertion in scripts/check.sh actually fires.
#
# A gate that has never failed is decoration: it can be vacuous — a pattern that matches
# nothing, a loop over an empty glob, an unanchored match that any neighbouring line
# satisfies — and look exactly like a gate that works. So each case here injects ONE
# violation, requires the gate to fail, and restores.
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
  rm -rf docs/_probe.md "$SCRATCH" \
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
# Pass $2 for any probe whose arm has a neighbour that can substitute for it. EIGHT probes below
# still need one and do not have it — the two hollow-plugin probes, `second copy of a SKILL.md`,
# `broken dogfooding symlink`, `SKILL.md with no name:`, `missing marketplace manifest`,
# `invalid JSON in a marketplace manifest` and `missing project skills dir`. Delete the arm any of
# them names and this suite still reports it caught, so those eight arms have no kill test. They
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

# 5a — a real file where a symlink belongs, i.e. a second copy of a SKILL.md
rm .claude/skills/ship
mkdir -p .claude/skills/ship
cp "$CORE" .claude/skills/ship/SKILL.md
expect_fail "second copy of a SKILL.md instead of a symlink"
rm -rf .claude/skills/ship; link ship .claude/skills

# 5b — a broken symlink. `[ -e ]` follows the link, so this is the case that once slipped.
ln -sfn ../../plugins/ship/skills/gone .claude/skills/ship
expect_fail "broken dogfooding symlink"
link ship .claude/skills

# 5c — a symlink that resolves OUTSIDE the repo but whose text contains `/plugins/`, which a
# substring check would accept. An agent opened in a clone would read that as instructions.
mkdir -p "$SCRATCH/plugins/ship/skills/ship"
cp "$CORE" "$SCRATCH/plugins/ship/skills/ship/SKILL.md"
ln -sfn "$SCRATCH/plugins/ship/skills/ship" .claude/skills/ship
expect_fail "symlink target outside the repo"
link ship .claude/skills

# 5d — a packaged skill with no symlink at all
rm .agents/skills/shipyard
expect_fail "packaged skill with no dogfooding symlink"
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

# Outside .claude/skills and .agents/skills on purpose: placing it under either would trip
# the "not a symlink" branch of check 5 first, and a probe that fires the wrong check
# proves nothing about the one it names.
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

mv .agents/skills "$SCRATCH/agents-skills"
expect_fail "missing project skills dir"
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

echo
echo "assertions proven: $pass   not caught: $nocatch"
[ "$nocatch" -eq 0 ] || exit 1
make check >/dev/null 2>&1 || { echo "gate not green after restore"; exit 1; }
echo "check-test: OK"
