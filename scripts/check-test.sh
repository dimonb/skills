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
  rm -rf docs/_probe.md "$SCRATCH" plugins/council/skills/council/tests/t99-probe.sh 2>/dev/null || true
  rmdir docs 2>/dev/null || true
}
trap restore EXIT

pass=0; nocatch=0
expect_fail() {
  if make check >"$SCRATCH/out" 2>&1; then
    echo "NOT CAUGHT: $1"; nocatch=$((nocatch+1))
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

# 8 — the two assertions the gate is most easily made vacuous by, and which the review
# noted were themselves untested: the leak check failing LOUDLY rather than open when it
# cannot scan, and the dual-agent manifest/disk invariant.
sed -i.bak 's/^deny=.\/Users/deny='"'"'(unclosed/' scripts/check.sh
expect_fail "leak check fails LOUDLY on a broken pattern (not open)"
mv scripts/check.sh.bak scripts/check.sh

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
cat > plugins/council/skills/council/tests/t99-probe.sh <<'PROBE'
#!/usr/bin/env bash
R="${TMPDIR:-/tmp}/council-test/t99"; rm -rf "$R"
PROBE
expect_fail "council test naming a fixed temp room path"
rm -f plugins/council/skills/council/tests/t99-probe.sh

echo
echo "assertions proven: $pass   not caught: $nocatch"
[ "$nocatch" -eq 0 ] || exit 1
make check >/dev/null 2>&1 || { echo "gate not green after restore"; exit 1; }
echo "check-test: OK"
