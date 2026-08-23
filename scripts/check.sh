#!/usr/bin/env bash
# Repo gate. Runs on every commit (`make check`) and must be green before each.
#
# 1. every shell script parses
# 2. every SKILL.md has name+description frontmatter, and its name matches its directory
# 3. every plugin manifest is valid JSON, both manifests exist, names agree with the dir
# 4. every marketplace entry resolves to a real plugin directory
# 5. dogfooding integrity: the agents' skill dirs are symlinks into plugins/, and no
#    tracked regular file duplicates a packaged SKILL.md
# 6. ship's forge reference files do not carry a copy of the pipeline state enum
# 7. no machine-specific or company-private strings anywhere in tracked files
set -uo pipefail
cd "$(dirname "$0")/.."
rc=0
fail() { echo "FAIL $*"; rc=1; }

# ---------------------------------------------------------------- 1. shell syntax
while IFS= read -r f; do
  bash -n "$f" || fail "syntax: $f"
done < <(git ls-files '*.sh')

# ------------------------------------------------- 2. SKILL.md frontmatter + name
while IFS= read -r f; do
  head -1 "$f" | grep -q '^---$' || { fail "frontmatter missing: $f"; continue; }
  fm=$(awk 'NR>1 && /^---$/{exit} NR>1' "$f")
  printf '%s\n' "$fm" | grep -q '^name:'        || fail "no name: $f"
  printf '%s\n' "$fm" | grep -q '^description:' || fail "no description: $f"
  want=$(basename "$(dirname "$f")")
  got=$(printf '%s\n' "$fm" | sed -n 's/^name: *//p' | tr -d '"'"'" | head -1)
  [ "$got" = "$want" ] || fail "skill name '$got' != directory '$want': $f"
done < <(git ls-files '*SKILL.md')

# --------------------------------------------- 3. plugin manifests: JSON + agreement
for d in plugins/*/; do
  [ -d "$d" ] || continue
  p=${d%/}; name=$(basename "$p")
  for m in "$p/.claude-plugin/plugin.json" "$p/.codex-plugin/plugin.json"; do
    if [ ! -f "$m" ]; then fail "missing manifest: $m"; continue; fi
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$m" \
      || { fail "invalid JSON: $m"; continue; }
    got=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("name",""))' "$m")
    [ "$got" = "$name" ] || fail "manifest name '$got' != directory '$name': $m"
  done
  [ -d "$p/skills" ] || fail "plugin has no skills/ directory: $p"
  # A plugin may hold MANY skills; require at least one.
  find "$p/skills" -name SKILL.md -mindepth 2 -maxdepth 2 | grep -q . \
    || fail "plugin has no skills/<skill>/SKILL.md: $p"
done

# ------------------------------------ 4. marketplace manifests: JSON + entries resolve
for m in .claude-plugin/marketplace.json .agents/plugins/marketplace.json; do
  if [ ! -f "$m" ]; then fail "missing marketplace manifest: $m"; continue; fi
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$m" \
    || { fail "invalid JSON: $m"; continue; }
  while IFS=$'\t' read -r name path; do
    [ -n "$name" ] || continue
    [ -d "$path" ] || fail "marketplace entry '$name' points at missing dir '$path': $m"
    [ "$(basename "$path")" = "$name" ] \
      || fail "marketplace entry '$name' points at differently-named dir '$path': $m"
  done < <(python3 - "$m" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for p in d.get("plugins", []):
    src = p.get("source")
    path = src if isinstance(src, str) else (src or {}).get("path", "")
    print("%s\t%s" % (p.get("name", ""), path.lstrip("./")))
PY
  )
done

# ------------------------------------------------------ 5. dogfooding: links, no copies
for d in .claude/skills .agents/skills; do
  [ -d "$d" ] || { fail "missing project skills dir: $d"; continue; }
  for e in "$d"/*; do
    # -e follows the link, so a BROKEN symlink is not -e. Test -L too or it is skipped.
    [ -e "$e" ] || [ -L "$e" ] || continue
    [ -L "$e" ] || { fail "not a symlink (would be a second copy): $e"; continue; }
    [ -f "$e/SKILL.md" ] || fail "broken symlink: $e"
    case "$(cd "$(dirname "$e")" && readlink "$(basename "$e")")" in
      */plugins/*) ;;
      *) fail "symlink does not point into plugins/: $e" ;;
    esac
  done
done
# A tracked SKILL.md outside plugins/ is a duplicated source of truth.
while IFS= read -r f; do
  case "$f" in plugins/*) ;; *) fail "SKILL.md tracked outside plugins/: $f" ;; esac
done < <(git ls-files '*SKILL.md')

# ------------------------------ 6. no copy of the pipeline state enum in a forge file
# The core owns the state names. A copy inside a per-forge reference file is exactly the
# stale-enum failure both source variants of ship warned about, so assert it cannot exist.
core=plugins/ship/skills/ship/SKILL.md
if [ -f "$core" ]; then
  for ref in plugins/ship/skills/ship/references/*.md; do
    [ -f "$ref" ] || continue
    for st in need-issue issue-ready spec-review impl-review ready-to-merge needs-human; do
      if grep -qF -- "$st" "$ref"; then
        fail "forge reference carries the state name '$st' (the core owns it): $ref"
      fi
    done
  done
fi

# -------------------------------------- 7. machine-specific / company-private strings
# `--untracked` is load-bearing: plain `git grep` sees only tracked files, so a brand-new
# file carrying a leak would pass the gate right up until the commit that adds it. It still
# honours .gitignore, so ignored working material is not scanned.
# The two gate scripts are excluded: they necessarily CONTAIN these patterns — one as its
# pattern list, the other as its test fixtures. Anchored patterns only.
deny='/Users/[a-zA-Z0-9._-]+|/home/[a-zA-Z0-9._-]+|[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'
deny="$deny"'|\.local/bin/|gitlab\.yandexcloud\.net|infra\.finlab\.team|finlab'
deny="$deny"'|tillabuy|opsally|whatsin-?town|ebaconline|\bebac\b'
deny="$deny"'|(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}|glpat-[A-Za-z0-9_-]{16,}'
deny="$deny"'|-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[baprs]-[A-Za-z0-9-]{10,}'
if git grep --untracked -nIiE "$deny" -- . ':!scripts/check.sh' ':!scripts/check-test.sh' >/dev/null 2>&1; then
  echo "FAIL: machine-specific or private strings in tracked files:"
  git grep --untracked -nIiE "$deny" -- . ':!scripts/check.sh' ':!scripts/check-test.sh'
  rc=1
fi

[ $rc -eq 0 ] && echo "check: OK"
exit $rc
