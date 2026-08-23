#!/usr/bin/env bash
# Repo gate: every shell script parses, every SKILL.md has name+description frontmatter,
# every plugin manifest is valid JSON. Seed version — extend as the repo grows.
set -uo pipefail
cd "$(dirname "$0")/.."
rc=0

while IFS= read -r f; do
  bash -n "$f" || { echo "FAIL syntax: $f"; rc=1; }
done < <(find . -name '*.sh' -not -path './.git/*' -not -path './.claude/worktrees/*')

while IFS= read -r f; do
  head -1 "$f" | grep -q '^---$' || { echo "FAIL frontmatter missing: $f"; rc=1; continue; }
  awk 'NR>1 && /^---$/{exit} NR>1' "$f" | grep -q '^name:' || { echo "FAIL no name: $f"; rc=1; }
  awk 'NR>1 && /^---$/{exit} NR>1' "$f" | grep -q '^description:' || { echo "FAIL no description: $f"; rc=1; }
done < <(find . -name 'SKILL.md' -not -path './.git/*' -not -path './.claude/worktrees/*')

while IFS= read -r f; do
  python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" || { echo "FAIL json: $f"; rc=1; }
done < <(find . -name 'plugin.json' -o -name 'marketplace.json' | grep -v '/.git/')

# No machine-specific leakage in tracked files.
if git grep -nI -E '/Users/[a-zA-Z0-9._-]+|dimonb@|\.local/bin/' -- . ':!scripts/check.sh' ':!AGENTS.md' | grep -v '^$'; then
  echo "FAIL: machine-specific paths in tracked files"; rc=1
fi

[ $rc -eq 0 ] && echo "check: OK"
exit $rc
