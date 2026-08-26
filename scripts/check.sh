#!/usr/bin/env bash
# Repo gate. Runs on every commit (`make check`) and must be green before each.
#
# 1. every shell script parses
# 2. every SKILL.md has name+description frontmatter, and its name matches its directory
# 3. every plugin manifest is valid JSON, both manifests exist, names agree with the dir
# 4. marketplace entries resolve, and both manifests offer the same plugins as plugins/ on disk
# 5. dogfooding: both agents linked to every packaged skill, links contained in plugins/,
#    and no second copy of any SKILL.md
# 6. ship's forge reference files do not carry a copy of the pipeline state enum
# 7. no non-generic strings (structural patterns only; no dependency on any untracked file)
# 8. no non-Latin script in any tracked file (the checkable half of "English everywhere")
# 9. no council test names the shared temp parent (the pre-run-root shape); see §9 for its limits
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT_P=$(pwd -P)          # physical repo root; see the symlink containment check below
rc=0
fail() { echo "FAIL $*"; rc=1; }

# ---------------------------------------------------------------- 1. shell syntax
while IFS= read -r f; do
  bash -n "$f" || fail "syntax: $f"
done < <(git ls-files --cached --others --exclude-standard '*.sh')

# ------------------------------------------------- 2. SKILL.md frontmatter + name
while IFS= read -r f; do
  head -1 "$f" | grep -q '^---$' || { fail "frontmatter missing: $f"; continue; }
  fm=$(awk 'NR>1 && /^---$/{exit} NR>1' "$f")
  printf '%s\n' "$fm" | grep -q '^name:'        || fail "no name: $f"
  printf '%s\n' "$fm" | grep -q '^description:' || fail "no description: $f"
  want=$(basename "$(dirname "$f")")
  got=$(printf '%s\n' "$fm" | sed -n 's/^name: *//p' | tr -d '"'"'" | head -1)
  [ "$got" = "$want" ] || fail "skill name '$got' != directory '$want': $f"
done < <(git ls-files --cached --others --exclude-standard '*SKILL.md')

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
# The two manifests must offer the SAME plugins, and exactly the ones on disk. Validating each
# file in isolation lets a plugin reach one agent's users and not the other's — the dual-agent
# invariant this whole repo exists to establish, ungated.
mnames() {
  python3 - "$1" <<'PY'
import json, sys
try: d = json.load(open(sys.argv[1]))
except Exception: sys.exit(0)
for p in d.get("plugins", []):
    print(p.get("name", ""))
PY
}
cc=$(mnames .claude-plugin/marketplace.json | sort)
cx=$(mnames .agents/plugins/marketplace.json | sort)
disk=$(for d in plugins/*/; do [ -d "$d" ] && basename "${d%/}"; done | sort)
[ "$cc" = "$cx" ] || fail "the two marketplace manifests list different plugins:
  claude: $(echo "$cc" | tr '\n' ' ')
  codex:  $(echo "$cx" | tr '\n' ' ')"
[ "$cc" = "$disk" ] || fail "marketplace plugins do not match plugins/ on disk:
  manifest: $(echo "$cc" | tr '\n' ' ')
  on disk:  $(echo "$disk" | tr '\n' ' ')"

# ------------------------------------------------------ 5. dogfooding: links, no copies
for d in .claude/skills .agents/skills; do
  [ -d "$d" ] || { fail "missing project skills dir: $d"; continue; }
  for e in "$d"/*; do
    # -e follows the link, so a BROKEN symlink is not -e. Test -L too or it is skipped.
    [ -e "$e" ] || [ -L "$e" ] || continue
    [ -L "$e" ] || { fail "not a symlink (would be a second copy): $e"; continue; }
    [ -f "$e/SKILL.md" ] || fail "broken symlink: $e"
    # Assert CONTAINMENT of the resolved target, not a substring of the link text: a
    # substring test accepts `../../../../../tmp/plugins/x/skills/x` and any absolute path
    # containing `/plugins/`, and an agent opened in a clone would read that out-of-tree
    # SKILL.md as instructions. Resolve it and require it to be under this repo's plugins/.
    # Compare PHYSICAL against PHYSICAL. `$PWD` is the LOGICAL path `cd` set, so matching a
    # `pwd -P` result against it fails on every checkout reached through a symlink — a clone
    # under /tmp on macOS (/tmp -> /private/tmp), a symlinked home, an automounted project
    # dir — and the message then names a target that is plainly inside the repo.
    tgt=$(cd "$e" 2>/dev/null && pwd -P)
    case "$tgt" in
      "$ROOT_P/plugins/"*) ;;
      *) fail "symlink target is outside this repo's plugins/: $e -> ${tgt:-<unresolved>}" ;;
    esac
  done
done
# A SKILL.md anywhere but plugins/ is a duplicated source of truth (tracked or not).
while IFS= read -r f; do
  case "$f" in plugins/*) ;; *) fail "SKILL.md outside plugins/ (the packaged copy is the only source of truth): $f" ;; esac
done < <(git ls-files --cached --others --exclude-standard '*SKILL.md')
# Every packaged skill must HAVE both links. Validating only the links that exist lets a new
# skill ship with no dogfooding at all, which is the invariant this check is here to protect.
for s in plugins/*/skills/*/SKILL.md; do
  [ -f "$s" ] || continue
  skill=$(basename "$(dirname "$s")")
  for d in .claude/skills .agents/skills; do
    [ -L "$d/$skill" ] || fail "packaged skill '$skill' has no symlink at $d/$skill"
  done
done

# ------------------------------ 6. no copy of the pipeline state enum in a forge file
# The core owns the state names. A copy inside a per-forge reference file is exactly the
# stale-enum failure both source variants of ship warned about, so assert it cannot exist.
core=plugins/ship/skills/ship/SKILL.md
if [ -f "$core" ]; then
  # Derive the enum ONCE and use it for both assertions below. A second, hand-maintained
  # copy of the state list inside this gate would be a copy of an enum going stale, inside
  # the check written to stop copies of an enum going stale.
  # Match only a line whose value CONTAINS `|`, i.e. the enum itself, and require exactly one
  # such line. `head -1` over any `"state": "` line would silently pick up a later single-value
  # example instead, leaving one state to check and the rest unasserted — a vacuous version of
  # the very check written to stop a state existing without a handler.
  enum_lines=$(grep -cE '"state": "[^"]*\|[^"]*"' "$core")
  states=$(sed -n 's/.*"state": "\([^"]*|[^"]*\)".*/\1/p' "$core" | tr '|' ' ')
  if [ "$enum_lines" != 1 ] || [ -z "$states" ]; then
    fail "cannot find exactly one state enum in $core (found $enum_lines candidate line(s))"
    states=""
  fi

  # Only the hyphenated names are searched for in the forge files: the single-word states
  # (`apply`, `archive`, `done`) are ordinary English that legitimately appears in prose, so
  # matching them would be all false positives.
  for ref in plugins/ship/skills/ship/references/*.md; do
    [ -f "$ref" ] || continue
    for st in $states; do
      case "$st" in *-*) ;; *) continue ;; esac
      if grep -qF -- "$st" "$ref"; then
        fail "forge reference carries the state name '$st' (the core owns it): $ref"
      fi
    done
  done

  # And no state may exist that the state machine cannot enter. A stage named in the enum
  # with no handler is the failure the launcher skill documents as its own worst: a
  # supervisor believing in a stage that does not exist reads a real stall as business as
  # usual. `done` is exempt — it is terminal, reached from inside another handler.
  for st in $states; do
    [ "$st" = done ] && continue
    # Match the backticked name exactly. An unanchored `.*$st` would let `spec` be satisfied
    # by the `spec-review` heading — a substring match makes this very check vacuous, which
    # is how the first version of it passed while the defect it was written for was present.
    grep -qF -- "### 7." "$core" && grep -qE "^### 7\.[A-Z] — \`$st\`" "$core" \
      || fail "state '$st' is in the enum but has no '### 7.x — \`$st\`' handler in $core"
  done
fi

# ------------------------------------------------- 7. non-generic strings (leak check)
# STRUCTURAL patterns only, and no dependency on any untracked file. These are generic —
# wrong in anybody's repo — which is exactly why they belong in a shared gate.
#
# Names private to one person, company or project are deliberately NOT here. They are not
# this repo's concern: guarding a private name belongs to the machine that knows it, as a
# global hook or a secret-scanner config, not to one repository's gate. What this repo
# enforces instead is the absolute rule that no such name appears in a tracked file at all
# (AGENTS.md, rule zero).
#
# `--untracked` is load-bearing: plain `git grep` sees only tracked files, so a brand-new file
# carrying a leak would pass right up until the commit that adds it. It still honours
# .gitignore, so ignored working material is not scanned.
#
# CAUTION when editing these patterns: `git grep -E` does NOT support `\b`. It matches a
# literal `b`, so `\bfoo\b` matches "bfoob" and NOT "foo" — silently inverting the pattern.
# Write `(^|[^a-z])foo([^a-z]|$)` instead. Plain `grep -E` DOES support `\b`, so testing a
# pattern with grep and shipping it to git grep is precisely how this bites.
deny='/Users/[a-zA-Z0-9._-]+|/home/[a-zA-Z0-9._-]+|[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}'
deny="$deny"'|\.local/bin/|\.config/(gh|glab)-[a-zA-Z0-9._-]+'
deny="$deny"'|(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}|glpat-[A-Za-z0-9_-]{16,}'
deny="$deny"'|-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[baprs]-[A-Za-z0-9-]{10,}'
deny="$deny"'|TZ=[A-Za-z]+/[A-Za-z_]+'

# Fail LOUDLY, and never confuse "clean" with "could not scan". git grep exits 0 on a match,
# 1 on no match, and >1 on an error — an invalid regex, a bad pathspec, or not being inside a
# git repository at all. Reading >1 as "no match" would make the only control against the
# highest-consequence defect class report success having scanned nothing.
hits=$(git grep --untracked -nIiE "$deny" -- . ':!scripts/check.sh' ':!scripts/check-test.sh' 2>&1)
g=$?
if [ "$g" -eq 0 ]; then
  echo "FAIL: non-generic strings in tracked files:"; printf '%s\n' "$hits"; rc=1
elif [ "$g" -gt 1 ]; then
  fail "leak check could not run (git grep rc=$g): $hits"
fi

# --------------------------------------------------- 8. English everywhere (script check)
# AGENTS.md says English everywhere — issues, pull requests, comments, code, docs. That rule
# held by judgement alone until a whole plugin shipped its protocol, its runtime messages and
# its decision records in Russian: the files agents READ as instructions, in a language the
# next reader of the repo may not have. So the gate checks what a gate can check — the SCRIPT.
# A non-Latin script in a tracked file is the structural half of the rule; English prose
# written in Latin letters is still a judgement call, and this check does not pretend
# otherwise.
#
# `-P` (PCRE) rather than a literal character class, deliberately: writing the ranges out
# would put the very characters this check forbids into the check, which then has to exempt
# itself — and an exemption is how a check stops covering the file most likely to be edited
# by whoever is adding a violation.
nonlatin=$(git grep --untracked -nIP '\p{Cyrillic}|\p{Greek}|\p{Han}|\p{Hiragana}|\p{Katakana}|\p{Hangul}|\p{Arabic}|\p{Hebrew}|\p{Devanagari}|\p{Thai}|\p{Armenian}|\p{Georgian}' -- . 2>&1)
g=$?
if [ "$g" -eq 0 ]; then
  echo "FAIL: non-Latin script in tracked files (AGENTS.md: English everywhere):"; printf '%s\n' "$nonlatin"; rc=1
elif [ "$g" -gt 1 ]; then
  fail "English check could not run (git grep rc=$g): $nonlatin"
fi

# ------------------- 9. council test rooms come from the run root, never a fixed path
# A room path fixed by the test's own name let two concurrent suites delete each other's rooms
# mid-run. The collision did not surface as an I/O error — it surfaced as an asymmetric protocol
# failure ("the participants disagreed about who won turn 1"), which is convincing false evidence
# against the very transport the suite exists to verify. A harness bug that frames the code under
# test is worse than the bug it hides, so it gets a gate rather than a comment.
#
# Only the two files that CREATE the run root may name the shared temp parent; every other test
# builds under $COUNCIL_TEST_ROOT, or makes its own `mktemp -d`.
#
# What this actually catches, stated honestly because a green gate is otherwise read as coverage:
# it is a grep for the PRE-RUN-ROOT SHAPE — a path spelled with `TMPDIR` or `council-test` — which
# is the shape a test copied from an older checkout carries, and the one that caused the incident.
# It is NOT a proof that a room derives from the run root. A test inventing some other fixed path
# (`R=/tmp/mine`) would reintroduce the collision and pass, and a test merely mentioning `TMPDIR`
# in a comment is rejected though it is harmless. Both were measured; a cleverer matcher was tried
# and was worse, losing the near-miss `council-test-t99` and rejecting legitimate tests that need
# no temp directory at all. So: a heuristic against the shape that actually recurs, not a linter.
#
# The same trap lives one level up, in the FILE LISTING, and it bit this check twice. A process
# substitution discards the lister's exit status, so a failing `git ls-files` silently becomes
# zero iterations; and a `[ -d ]` guard around the loop skips it silently when the directory is
# not where it is expected. Either way the assertion stops existing and the gate still prints
# `check: OK`. So the listing runs BEFORE the loop with its status captured, there is no
# directory guard, and the loop counts what it actually inspected: a check that scanned nothing
# has not held, it has abstained, and those are not the same result.
tests_dir=plugins/council/skills/council/tests
tests_list=$(git ls-files --cached --others --exclude-standard "$tests_dir/*.sh")
g=$?
if [ "$g" -ne 0 ]; then
  fail "could not list council tests (git ls-files rc=$g)"
else
  scanned=0
  while IFS= read -r f; do
    # A here-string over an empty listing still yields one empty line.
    [ -n "$f" ] || continue
    case "${f##*/}" in _helpers.sh|run-all.sh) continue ;; esac
    scanned=$((scanned + 1))
    # grep exits 0 on a match, 1 on none, and >1 on an error. Reading an error as "no match" is
    # how a check reports success having scanned nothing — the same trap section 7 guards against.
    grep -qE 'TMPDIR|council-test' "$f"
    case $? in
      0) fail "council test names a fixed temp path instead of \$COUNCIL_TEST_ROOT: $f" ;;
      1) ;;
      *) fail "could not scan council test for a fixed temp path: $f" ;;
    esac
  done <<< "$tests_list"
  [ "$scanned" -gt 0 ] \
    || fail "scanned no council test at all — expected them under $tests_dir/ (moved? renamed?)"
fi

[ $rc -eq 0 ] && echo "check: OK"
exit $rc
