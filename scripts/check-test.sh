#!/usr/bin/env bash
# Prove every assertion in scripts/check.sh actually fires.
#
# A gate that has never failed is decoration: it can be vacuous — a pattern that matches
# nothing, a loop that iterates over nothing, a test skipped by a guard above it — and look
# exactly like a gate that works. So each case here injects ONE violation, requires the gate
# to fail, and restores. Both of the bugs this file was written to catch were real: a broken
# symlink slipped past an `[ -e ]` guard, and the denylist never saw an untracked file.
#
# Requires a clean working tree (it restores with `git checkout --`). Run: make check-test
set -uo pipefail
cd "$(dirname "$0")/.."

# The dirty-tree guard comes FIRST, and the restore trap is installed only after it
# passes. Installing the trap earlier makes the guard's own early exit run the restore —
# which is `git checkout --`, so refusing to run would DISCARD the very uncommitted work
# the guard exists to protect. That happened once; hence the ordering and this comment.
if ! git diff --quiet || ! git diff --cached --quiet; then
  echo "refusing to run: working tree is dirty (this test restores files with git checkout)" >&2
  exit 2
fi

SCRATCH=$(mktemp -d)
restore() {
  git checkout -- plugins .claude-plugin .agents scripts 2>/dev/null || true
  rm -rf docs/_probe.md "$SCRATCH" 2>/dev/null || true
  rm -rf .claude/skills .agents/skills 2>/dev/null || true
  git checkout -- .claude .agents 2>/dev/null || true
  rmdir docs 2>/dev/null || true
}
trap restore EXIT

pass=0; nocatch=0
expect_fail() {
  if make check >"$SCRATCH/out" 2>&1; then
    echo "NOT CAUGHT: $1"; nocatch=$((nocatch+1))
  else
    echo "caught:     $1   ->  $(grep -m1 '^FAIL' "$SCRATCH/out" | cut -c1-84)"
    pass=$((pass+1))
  fi
}

if make check >"$SCRATCH/out" 2>&1; then
  echo "clean:      baseline"; pass=$((pass+1))
else
  echo "BASELINE DIRTY — the gate fails before any violation is injected:"
  cat "$SCRATCH/out"; exit 1
fi

link() { ln -sfn "../../plugins/$1/skills/$1" ".claude/skills/$1"; }

# 1 — shell syntax
printf 'if true; then\n' >> plugins/shipyard/skills/shipyard/shipyard-lib.sh
expect_fail "broken shell syntax"
git checkout -- plugins/shipyard/skills/shipyard/shipyard-lib.sh

# 2 — a skill's frontmatter name disagrees with its directory
perl -pi -e 's/^name: ship$/name: shipp/' plugins/ship/skills/ship/SKILL.md
expect_fail "skill name != directory"
git checkout -- plugins/ship/skills/ship/SKILL.md

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

# 4 — a marketplace entry pointing at nothing
perl -pi -e 's{"source": "./plugins/ship"}{"source": "./plugins/nope"}' .claude-plugin/marketplace.json
expect_fail "marketplace entry -> missing directory"
git checkout -- .claude-plugin/marketplace.json

# 5a — a real file where a symlink belongs, i.e. a second copy of a SKILL.md
rm .claude/skills/ship
mkdir -p .claude/skills/ship
cp plugins/ship/skills/ship/SKILL.md .claude/skills/ship/SKILL.md
expect_fail "second copy of a SKILL.md instead of a symlink"
rm -rf .claude/skills/ship; link ship

# 5b — a broken symlink. `[ -e ]` follows the link, so this is the case that once slipped.
ln -sfn ../../plugins/ship/skills/gone .claude/skills/ship
expect_fail "broken dogfooding symlink"
link ship

# 6 — a pipeline state name copied into a per-forge reference file
printf '\nStages: need-issue then ready-to-merge.\n' >> plugins/ship/skills/ship/references/forge-github.md
expect_fail "pipeline state enum copied into a forge reference"
git checkout -- plugins/ship/skills/ship/references/forge-github.md

# 7 — the denylist, one probe per class. The probe file is UNTRACKED on purpose: that is
# the state a leak is in when `make check` runs just before `git add`.
mkdir -p docs
probe() {
  printf '%s\n' "$1" > docs/_probe.md
  expect_fail "denylist: $2"
  rm -f docs/_probe.md
}
probe '/Users/someone/secret/path'       'absolute home path (macOS)'
probe '/home/someone/secret/path'        'absolute home path (Linux)'
probe 'someone@example-corp.com'         'e-mail address'
probe 'ci.internal.finlab'               'internal hostname fragment'
probe 'the tillabuy migration'           'private project slug'
probe 'glpat-AbCdEfGhIjKlMnOpQrSt'       'GitLab token'
probe 'ghp_AbCdEfGhIjKlMnOpQrStUvWx'     'GitHub token'
probe '-----BEGIN RSA PRIVATE KEY-----'  'private key header'
rmdir docs 2>/dev/null || true

echo
echo "assertions proven: $pass   not caught: $nocatch"
[ "$nocatch" -eq 0 ] || exit 1
make check >/dev/null 2>&1 || { echo "gate not green after restore"; exit 1; }
echo "check-test: OK"
