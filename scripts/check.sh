#!/usr/bin/env bash
# Repo gate. Runs on every commit (`make check`) and must be green before each.
#
# 1. every shell script parses (untracked too, except under a project skills dir)
# 2. every SKILL.md has name+description frontmatter, and its name matches its directory (ditto)
# 3. every plugin manifest is valid JSON, both manifests exist, names agree with the dir
# 4. marketplace entries resolve, and both manifests offer the same plugins as plugins/ on disk
# 5. dogfooding: every COMMITTED entry in a project skills dir is a symlink into plugins/; both
#    agents linked to every packaged skill, that link resolving inside plugins/ staged or not;
#    and no second copy of any SKILL.md
# 6. ship's forge reference files do not carry a copy of the pipeline state enum
# 7. no non-generic strings (structural patterns only; no dependency on any untracked file)
# 8. no non-Latin script in any file, untracked included (the checkable half of "English")
# 9. no council test names the shared temp parent (the pre-run-root shape); see §9 for its limits
# 10. every test on disk is registered in its suite's run-all.sh, for every suite $GATED_SUITES
#     declares, so no test silently stops running
# 11. every vendored copy of a shared module is byte-identical to its module's one canonical source
# 12. every test runner on disk under plugins/ or shared/ is invoked by a Makefile recipe AND
#     declared in $GATED_SUITES, so no whole suite runs nowhere or escapes check 10
set -uo pipefail
cd "$(dirname "$0")/.."
ROOT_P=$(pwd -P)          # physical repo root; see the symlink containment check below
rc=0
fail() { echo "FAIL $*"; rc=1; }

# The two project skills directories, named ONCE and read from here by every consumer: checks 1
# and 2, check 5's listing, its note, its outside-plugins exemption and both of its `for d` loops.
# Two places spelling the same pair differently is how one of them stops being maintained.
SKILL_LINK_DIRS='.claude/skills .agents/skills'

# Every test suite the repo gates, named ONCE and read by BOTH consumers: check 10 walks it to
# assert each suite's tests are registered, and check 12 asserts the reverse — that every runner
# found on disk appears here. Two copies of this list would let the two checks disagree about what
# a suite is, which is precisely the seam a suite slips through.
#
# It stays a hand-maintained DECLARATION on purpose. Deriving it from disk was considered and
# rejected: disk would then be the authority, so a suite directory deleted or renamed wholesale
# would simply stop being in the list, silently, and that is the same coverage loss the two checks
# exist to catch. A declaration cross-checked against disk catches BOTH directions — a suite gone
# from disk reds check 10, a suite missing from this list reds check 12.
#
# Adding a suite therefore means adding it here AND invoking its runner from a Makefile target.
# Neither is optional and neither is silent; check 12 reds until both are done.
GATED_SUITES='shared/driver/tests
shared/flow/tests
shared/adapters/tests
shared/policy/tests
plugins/shipyard/skills/shipyard/tests
plugins/council/skills/council/tests'

# `-c core.quotePath=false` belongs on EVERY listing whose paths reach `under_skill_dirs` or the
# `ls-files -s` parse, not just check 5's. By default git C-quotes a path holding a byte >= 0x80,
# and the predicate then compares `".claude/skills/caf\303\251/SKILL.md"` — quotes and all —
# against `.claude/skills/*`, which never matches: the exemption silently stops applying and a
# valid local skill reds three fabricated failures about a path that does not exist. Getting this
# onto check 5 alone is exactly how that survived one round of review.
#
# A control character, `"` or `\` is C-quoted whatever this setting says. Those still red, with a
# misleading message, and no skill directory in any repo is plausibly named that way. `-z` would
# remove the residue, but its records cannot survive `$( )`, which discards NUL bytes.
GIT_Q='-c core.quotePath=false'
under_skill_dirs() {
  for _d in $SKILL_LINK_DIRS; do
    case "$1" in "$_d"/*) return 0 ;; esac
  done
  return 1
}
# ...and is it UNTRACKED? That distinction is the entire exemption, and "exempt the project
# skills directories" is the wrong summary of it — the one a later edit would implement. A
# COMMITTED file under either directory is check 5's business and must still red.
untracked_local_skill() {
  under_skill_dirs "$1" || return 1
  # Exempt ONLY on the status that means "no such path in the index". `--error-unmatch` returns 0
  # tracked, 1 not tracked, and >1 on an error (no repository, unreadable index) -- and collapsing
  # those last two would turn a git failure into a decision to skip the check, which is the
  # "could not list" read as "nothing to report" that the rest of this file refuses by name.
  git ls-files --error-unmatch -- "$1" >/dev/null 2>&1
  case $? in
    1) return 0 ;;
    *) return 1 ;;
  esac
}
# Why this costs no coverage of anything the repo ships, which is the part worth writing down:
# the argument for checks 1 and 2 reading untracked files is that a brand-new PACKAGED skill's
# SKILL.md is untracked between writing it and `git add`. True, and irrelevant here — a packaged
# skill lives under plugins/, which stays fully checked, untracked included. These two
# directories hold nothing but dogfooding symlinks into plugins/; that is the repo's own rule,
# and asserting it is check 5's job. So an untracked entry here is the person's own business,
# and failing on one only ever blocked unrelated commits.

# ---------------------------------------------------------------- 1. shell syntax
while IFS= read -r f; do
  untracked_local_skill "$f" && continue
  bash -n "$f" || fail "syntax: $f"
done < <(git $GIT_Q ls-files --cached --others --exclude-standard '*.sh')

# ------------------------------------------------- 2. SKILL.md frontmatter + name
while IFS= read -r f; do
  untracked_local_skill "$f" && continue
  head -1 "$f" | grep -q '^---$' || { fail "frontmatter missing: $f"; continue; }
  fm=$(awk 'NR>1 && /^---$/{exit} NR>1' "$f")
  printf '%s\n' "$fm" | grep -q '^name:'        || fail "no name: $f"
  printf '%s\n' "$fm" | grep -q '^description:' || fail "no description: $f"
  want=$(basename "$(dirname "$f")")
  got=$(printf '%s\n' "$fm" | sed -n 's/^name: *//p' | tr -d '"'"'" | head -1)
  [ "$got" = "$want" ] || fail "skill name '$got' != directory '$want': $f"
done < <(git $GIT_Q ls-files --cached --others --exclude-standard '*SKILL.md')

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
# shellcheck disable=SC2086
for d in $SKILL_LINK_DIRS; do
  [ -d "$d" ] || fail "missing project skills dir: $d"
done

# The shape assertions below are driven by what git RECORDS, not by what the filesystem happens
# to hold. "One source of truth per skill" is a statement about COMMITTED content, so an
# untracked directory someone keeps under a project skills dir cannot violate it: it is not in
# the repository, it reaches nobody else, and it shadows nothing in a clone. Iterating the
# filesystem instead (`for e in "$d"/*`) failed on one, and that blocked every commit in the
# repo until the directory was moved — over local state the repo does not own.
#
# Asserting the git MODE states the real rule directly rather than by proxy: `120000` is git's
# symlink mode, and a committed entry recorded as anything else IS the second copy. That makes
# the check indifferent to local state by construction instead of by an exclusion list, and it
# reaches a copy committed one level down (`.claude/skills/x/SKILL.md`) as well.
#
# Deliberately narrower than checks 1 and 2, which DO read untracked files. That is not an
# inconsistency: a new script or SKILL.md is part of the change being made, and catching it
# before `git add` is the point. Incidental local state is not part of any change.
# shellcheck disable=SC2086
skills_ls=$(git $GIT_Q ls-files -s -- $SKILL_LINK_DIRS)
skills_rc=$?
if [ "$skills_rc" -ne 0 ]; then
  # Never read "could not list" as "nothing to report" — the trap sections 7 to 10 each guard.
  fail "could not list tracked project skill entries (git ls-files rc=$skills_rc)"
elif [ -z "$skills_ls" ]; then
  # A listing that matched nothing has not held, it has abstained. Nothing else here would say
  # so: the "packaged skill has both links" loop below reads the FILESYSTEM, so links present on
  # disk but dropped from the index satisfy it while every assertion above silently stops.
  # This arm fires only on a TOTAL drop. ONE link removed from the index leaves the listing
  # non-empty and stays green — a gap that predates this check and is not closed here.
  fail "no tracked entry under .claude/skills or .agents/skills at all (dropped from the index?)"
else
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    mode=${line%% *}
    e=${line#*$'\t'}                    # `git ls-files -s` prints "<mode> <sha> <stage>\t<path>"
    [ "$mode" = 120000 ] \
      || { fail "committed but not a symlink (would be a second copy): $e"; continue; }
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
  done <<< "$skills_ls"
fi

# Untracked entries get a NOTE, never a failure. Staying silent would be defensible — they
# cannot violate a rule about committed content — but someone who expected their local skill to
# be checked should learn here that it is not, rather than read a green gate as coverage.
# Say WHICH checks ignore it. Checks 7 and 8 still read every untracked file wherever it sits —
# a leak or a non-Latin script is high-consequence enough to scan a directory a person edits by
# hand — so an absolute "the gate asserts nothing about it" is false, and would put the note and
# a FAIL about one path in a single run: the shape this note exists to avoid, not to create.
# shellcheck disable=SC2086
untracked_skills=$(git $GIT_Q ls-files --others --exclude-standard --directory -- $SKILL_LINK_DIRS)
while IFS= read -r e; do
  [ -n "$e" ] || continue
  e=${e%/}
  # A link at a packaged skill's own path is NOT local state: the loop at the end of this check
  # asserts it whether or not it is staged. Calling it ignored here would be false, and a gate
  # that prints `note: ... ignored` and `FAIL` about one path in a single run is the shape this
  # note exists to avoid, not to create.
  packaged=""
  for s in plugins/*/skills/"$(basename "$e")"/SKILL.md; do [ -f "$s" ] && packaged=1; done
  [ -n "$packaged" ] && continue
  echo "note: untracked entry $e is local state; checks 1, 2 and 5 ignore it"
done <<< "$untracked_skills"

# A SKILL.md anywhere but plugins/ is a duplicated source of truth (tracked or not). The two
# project skills directories are exempt HERE because they are covered above instead, and more
# precisely: a committed SKILL.md under one of them is not mode 120000, so the mode assertion
# names it as the second copy it is, while an untracked one is the local state the note reports.
# Without this exemption a local skill reddened the gate TWICE — the `--others` reach of this
# loop is the other half of the same false positive, not a separate one.
while IFS= read -r f; do
  case "$f" in plugins/*) continue ;; esac
  under_skill_dirs "$f" && continue
  fail "SKILL.md outside plugins/ (the packaged copy is the only source of truth): $f"
done < <(git $GIT_Q ls-files --cached --others --exclude-standard '*SKILL.md')
# Every packaged skill must HAVE both links. Validating only the links that exist lets a new
# skill ship with no dogfooding at all, which is the invariant this check is here to protect.
#
# A link at a PACKAGED skill's own path is repo-owned by construction, never the incidental local
# state the index-driven loop above declines to judge, so it is checked whether or not it has been
# staged. That is what keeps "How to add a skill" honest: it says to create both links and then
# run the gate, and at that moment the links are untracked, invisible to the listing above, and
# `[ -L ]` alone is satisfied by one that points nowhere.
#
# Links git already has are skipped here, deliberately. The loop above resolved them with the same
# two assertions, and a second identical verdict would hand those assertions a stand-in: delete
# them and this loop would still red, so their probes would keep reporting `caught` over arms that
# no longer exist. Measured: reusing the wording moved two probes from `not proven` to `caught`.
for s in plugins/*/skills/*/SKILL.md; do
  [ -f "$s" ] || continue
  skill=$(basename "$(dirname "$s")")
  # shellcheck disable=SC2086
  for d in $SKILL_LINK_DIRS; do
    [ -L "$d/$skill" ] || { fail "packaged skill '$skill' has no symlink at $d/$skill"; continue; }
    git ls-files --error-unmatch -- "$d/$skill" >/dev/null 2>&1 && continue
    ltgt=$(cd "$d/$skill" 2>/dev/null && pwd -P)
    case "$ltgt" in
      "$ROOT_P/plugins/"*) ;;
      *) fail "packaged skill '$skill' link is not staged and does not resolve into plugins/: $d/$skill -> ${ltgt:-<unresolved>}"; continue ;;
    esac
    # BOTH of the tracked loop's assertions, not just containment: a link into plugins/ that
    # exposes no SKILL.md is the likelier typo of the two, since `plugins/<plugin>` is a real
    # directory sitting one level above the right target.
    [ -f "$d/$skill/SKILL.md" ] \
      || fail "packaged skill '$skill' link is not staged and exposes no SKILL.md: $d/$skill"
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

  # ...and no state may be entered without being RECORDED. The supervisor's status table reads a
  # slot's stage from ship's state file and from nowhere else, so a transition the core does not
  # tell the run to record is a stage that is invisible from outside for as long as it lasts —
  # measured over three consecutive changes, whose stage column read `—` from launch to merge.
  # `done` is included here, unlike the handler arm above: a terminal state is exactly the one a
  # supervisor most needs to see recorded.
  #
  # WHAT THIS IS, stated because a green gate is otherwise read as coverage: a DOCS-CONSISTENCY
  # check over the core's own prose, NOT a runtime guarantee that any run wrote any file. It
  # asserts that the instruction exists at every transition; whether a child obeys it is not
  # checkable from here, and nothing in this repo can check it. The half of #124 that holds
  # regardless of what a child does is shipyard-report.sh's forge fallback, not this arm.
  for st in $states; do
    grep -qF -- "record state=$st" "$core" \
      || fail "state '$st' is in the enum but $core never says \`record state=$st\`"
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
# The same two path roots in their SEPARATOR-ENCODED form. Agent runtimes name per-project state
# directories by flattening an absolute path — every `/` becomes `-` — so `/Users/<name>/<proj>`
# is also disclosed as `-Users-<name>-<proj>`, carrying the same username and on-disk layout while
# matching neither arm above. Nobody types it; it arrives by pasting displayed tool output, and a
# committed instance of exactly that shape passed this gate green.
#
# BOUNDS, because the encoded form is only a hyphen-separated word sequence and must not fire on
# ordinary hyphenated English. Flattening turns the LEADING `/` of an absolute path into a leading
# `-`, so an encoded `/Users/…` or `/home/…` starts its token: the character before it must be
# neither alphanumeric NOR a hyphen. That rules out a hyphenated phrase (`per-users-quota`,
# `nav-home-link` — preceded by a letter) and a GNU-style double-dash long flag (`--users-file`,
# `--home-dir` — preceded by `-`), while still matching the real shapes, where the token follows
# `/`, whitespace, a quote, `=`, `_` or the start of the line. A single-dash long option
# (`-home-dir`) does still red, and that is accepted rather than excluded: it is also exactly how
# `/home/dir` encodes, so a leak gate should err that way. At least one name character must
# follow, so a bare `-Users-` is not a hit.
#
# Two limits taken deliberately, stated so the next editor does not read the bound as wider than
# it is. There is no trailing-separator anchor, because an encoded home directory with nothing
# after it still discloses the username. And unlike the slash arms, which match `/home/` at any
# depth, this one sees only a home root that is the FIRST path component: a layout that puts the
# home root below the filesystem root encodes without a separator in front of the root component,
# so the slash arm catches that shape and this arm does not.
deny="$deny"'|(^|[^A-Za-z0-9-])-(Users|home)-[a-zA-Z0-9._]+'
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
  echo "FAIL: non-generic strings:"; printf '%s\n' "$hits"; rc=1
elif [ "$g" -gt 1 ]; then
  fail "leak check could not run (git grep rc=$g): $hits"
fi

# --------------------------------------------------- 8. English everywhere (script check)
# AGENTS.md says English everywhere — issues, pull requests, comments, code, docs. That rule
# held by judgement alone until a whole plugin shipped its protocol, its runtime messages and
# its decision records in Russian: the files agents READ as instructions, in a language the
# next reader of the repo may not have. So the gate checks what a gate can check — the SCRIPT.
# A non-Latin script in any file the gate can see, untracked included, is the structural half of
# the rule; English prose written in Latin letters is still a judgement call, and this check does
# not pretend otherwise.
#
# `-P` (PCRE) rather than a literal character class, deliberately: writing the ranges out
# would put the very characters this check forbids into the check, which then has to exempt
# itself — and an exemption is how a check stops covering the file most likely to be edited
# by whoever is adding a violation.
nonlatin=$(git grep --untracked -nIP '\p{Cyrillic}|\p{Greek}|\p{Han}|\p{Hiragana}|\p{Katakana}|\p{Hangul}|\p{Arabic}|\p{Hebrew}|\p{Devanagari}|\p{Thai}|\p{Armenian}|\p{Georgian}' -- . 2>&1)
g=$?
if [ "$g" -eq 0 ]; then
  echo "FAIL: non-Latin script (AGENTS.md: English everywhere):"; printf '%s\n' "$nonlatin"; rc=1
elif [ "$g" -gt 1 ]; then
  fail "English check could not run (git grep rc=$g): $nonlatin"
fi

# --------------------------- test suites: ONE listing helper, shared by checks 9 and 10
# The listing logic lives in ONE function, called by check 9 (council-only, the temp-path scan)
# and by check 10 (registration, once per suite). A second hand-written `git ls-files` would be a
# second copy of the traps below — and the copy is the one that goes stale while the original keeps
# being maintained.
#
# Lists the *.sh test files under a suite's tests/ dir (cached + untracked), echoing each path
# RELATIVE to that dir, minus the two files that are not tests. Prints nothing and returns git's
# non-zero status if the listing itself errors.
#
# stderr is deliberately NOT folded in with `2>&1`, unlike sections 7 and 8: a missing directory
# makes `git ls-files` warn and still exit 0, and that captured warning would enter a caller's loop
# as a filename — firing an error arm over a phantom path and leaving the count vacuous with nothing
# saying so.
#
# Exempt on the path RELATIVE to the tests directory, never on the basename — the pathspec crosses
# directories, so a basename match would also exempt a `tests/nested/run-all.sh`, which check 9 must
# still scan and check 10 must still require to be registered. A helper that genuinely is not a test
# belongs in this exemption list — the two names are matched literally, and a `_` prefix means
# nothing to either check, so adding `_foo.sh` and expecting it to be skipped reds the gate pointing
# at the runner instead of at this line.
list_suite_tests() {
  local dir="$1" list rc f rel
  list=$(git ls-files --cached --others --exclude-standard "$dir/*.sh")
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  while IFS= read -r f; do
    # A here-string over an empty listing still yields one empty line.
    [ -n "$f" ] || continue
    rel=${f#"$dir/"}
    case "$rel" in _helpers.sh|run-all.sh) continue ;; esac
    printf '%s\n' "$rel"
  done <<< "$list"
  return 0
}

# --------------- 9. no council test names the shared temp parent (a pre-run-root shape)
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
# `check: OK`. So `list_suite_tests` (above, shared with check 10) captures its status, there is no
# directory guard, and the loop counts what it actually inspected: a check that scanned nothing has
# not held, it has abstained, and those are not the same result.
council_dir=plugins/council/skills/council/tests
council_tests=$(list_suite_tests "$council_dir"); council_rc=$?
if [ "$council_rc" -ne 0 ]; then
  fail "could not list council tests (git ls-files rc=$council_rc)"
else
  scanned=0
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    scanned=$((scanned + 1))
    # grep exits 0 on a match, 1 on none, and >1 on an error. Reading an error as "no match" is
    # how a check reports success having scanned nothing — the same trap section 7 guards against.
    grep -qE 'TMPDIR|council-test' "$council_dir/$rel"
    case $? in
      0) fail "council test names a fixed temp path instead of \$COUNCIL_TEST_ROOT: $council_dir/$rel" ;;
      1) ;;
      *) fail "could not scan council test for a fixed temp path: $council_dir/$rel" ;;
    esac
  done <<< "$council_tests"
  [ "$scanned" -gt 0 ] \
    || fail "scanned no council test at all — expected them under $council_dir/ (moved? renamed?)"
fi

# ------------------ 10. every test on disk is registered in its suite's run-all.sh
# Generalised from council-only to every suite the repo ships, named once in $GATED_SUITES above.
# The list is a hand-maintained DECLARATION, deliberately: derive it from disk instead and a suite
# directory deleted or renamed wholesale stops being noticed, which is the same silent
# coverage-loss this check exists to prevent. What connects it to disk is check 12, which asserts
# in the other direction — every runner ON DISK must appear in this list — so a suite cannot be
# added and left unregistered either. Before that existed, a test could land, pass review, and
# then simply never run again, with no symptom anywhere; and `shared/policy/tests` sat in exactly
# that state from the day it landed. It has also come close by accident: during a run of several
# parallel changes the registration line was the one place they all collided, and a
# resolution that dropped a name would have looked exactly like a clean one.
#
# This check is about a test file's registration INSIDE a runner. Whether that runner is ever
# INVOKED is a separate question, and its own failure class — check 12 owns it.
#
# What this catches and what it does not. The extraction reads the space-separated words out of
# every single-line `tests=(…)` / `tests+=(…)` assignment in the runner (council splits its list
# into a default array and a `--full` one; both are read). Split an array across lines, or build it
# in a loop, and it sees less than is really registered: the gate then reds naming a test that IS
# registered — the wrong message, but loud. It can also OVER-read, and that direction is the silent
# one: a commented-out or superseded `tests=(…)` line left in the runner enrols names nothing
# walks, so a real unregistered test whose name still appears there is masked. Keep the
# registration to one live array (or council's two) and this stays a non-issue. The reverse
# direction (a registration naming a file that is gone) is deliberately not asserted here, because
# the suite already reds on it at runtime, `bash` exiting 127 on the missing path.
#
# A missing input FAILS rather than skips: an errored listing, an empty one (a moved or renamed
# tests dir), a missing runner, an unfindable list, and a comm that could not run each red, so
# "compared nothing" is never read as OK. `list_suite_tests` captures git's status; the comm-rc
# guard proves the comparison RAN (its limit: `pipefail` does not reach into a process
# substitution, so a `sort` that died in either `<(…)` leaves comm at 0 over a truncated list —
# a system-level failure, not a code path). Check 9 owns the council temp-path scan, so a council
# listing error is reported once there; here a genuinely emptied council dir reds this arm too,
# which is louder than the old dedicated skip but never silent.
for suite_dir in $GATED_SUITES; do
  runner=$suite_dir/run-all.sh
  suite_tests=$(list_suite_tests "$suite_dir"); suite_rc=$?
  if [ "$suite_rc" -ne 0 ]; then
    fail "could not list tests under $suite_dir (git ls-files rc=$suite_rc)"
  elif [ -z "$suite_tests" ]; then
    fail "no test on disk under $suite_dir (moved? renamed?)"
  elif [ ! -f "$runner" ]; then
    fail "test runner is missing: $runner"
  else
    reg_lines=$(grep -cE 'tests\+?=\(' "$runner")
    registered=$(sed -n 's/.*tests+\{0,1\}=(\([^)]*\)).*/\1/p' "$runner" \
      | tr ' ' '\n' | sed '/^$/d' | sort -u)
    # `${reg_lines:-0}`, not `$reg_lines`: grep prints nothing when it cannot read the file, and
    # `[ "" -eq 0 ]` is a shell ERROR (`[: : integer expected` on stderr), not a false.
    if [ "${reg_lines:-0}" -eq 0 ] || [ -z "$registered" ]; then
      fail "could not find the test list in $runner (expected a single-line \`tests=(…)\` array)"
    else
      unregistered=$(comm -23 <(printf '%s' "$suite_tests" | sort -u) \
                              <(printf '%s\n' "$registered" | sort -u))
      comm_rc=$?
      if [ "$comm_rc" -ne 0 ]; then
        fail "could not compare the test list against the files on disk for $suite_dir (comm rc=$comm_rc)"
      else
        [ -z "$unregistered" ] || fail \
          "test on disk but not registered in $runner (it never runs): $(printf '%s' "$unregistered" | tr '\n' ' ')"
      fi
    fi
  fi
done

# 11 — every shared/<mod>/ module is one source of truth. Each plugin ships its own copy of a
# shared module because a Codex plugin cannot depend on another plugin, so a symlink cannot cross
# that boundary; the gate is what keeps the copies identical. Generalized from the driver alone to
# EVERY shared/<mod>/ (driver, flow, and any later one such as the escalation policy), so a new
# shared module is covered with NO gate edit — it just needs a lone *.sh canonical and a
# targets.txt. Fails CLOSED: a malformed module (no canonical, several candidates, or no target
# list), a missing or empty list, a missing or drifted copy, and no shared module at all each red,
# so "compared nothing" is never read as OK. `scripts/sync-driver.sh` writes the copies (its name
# is historical — it vendors every module, not the driver alone).
shared_mods=0
for moddir in shared/*/; do
  [ -d "$moddir" ] || continue
  shared_mods=$((shared_mods + 1))
  mod=${moddir%/}
  # canonical = the lone *.sh directly in the module dir; tests/ and examples/ are subdirs and do
  # not count. The glob's literal-on-no-match is filtered by [ -f ], so a module with no direct
  # *.sh counts zero and reds, rather than reading the unexpanded pattern as a filename.
  canonical=""; ncanon=0
  for f in "$mod"/*.sh; do
    [ -f "$f" ] || continue
    ncanon=$((ncanon + 1)); canonical=$f
  done
  if [ "$ncanon" -eq 0 ]; then
    fail "shared module has no canonical *.sh (expected exactly one): $mod"; continue
  elif [ "$ncanon" -gt 1 ]; then
    fail "shared module has several *.sh, cannot pick one canonical: $mod"; continue
  fi
  targets="$mod/targets.txt"
  if [ ! -f "$targets" ]; then
    fail "shared module target list is missing: $targets"; continue
  fi
  mod_n=0
  while IFS= read -r t || [ -n "$t" ]; do
    case "$t" in ''|\#*) continue ;; esac
    mod_n=$((mod_n + 1))
    if [ ! -f "$t" ]; then
      fail "shared module copy is missing (run scripts/sync-driver.sh): $t"
    elif ! cmp -s "$canonical" "$t"; then
      fail "shared module copy drifted from $canonical (run scripts/sync-driver.sh): $t"
    fi
  done < "$targets"
  # A target list that matched nothing means this module compared nothing — loud, not silent.
  [ "$mod_n" -gt 0 ] || fail "shared module target list is empty: $targets"
done
# And no shared module at all means the whole check compared nothing.
[ "$shared_mods" -gt 0 ] || fail "no shared/<mod>/ module found under shared/"

# ------------------ 12. every runner on disk is invoked by a Makefile target AND declared gated
# Check 10 asserts that a test FILE is registered inside its suite's runner. Two things it does
# NOT assert, each its own failure class, each of which has actually happened here:
#
#   * that the runner is ever INVOKED. A suite can land, be internally consistent, pass check 10,
#     and run in no automated invocation at all. `shared/policy/tests` sat in exactly that state
#     from the day it landed — green when run by hand, never run by `make check`, `make test` or
#     CI, with nothing anywhere saying so.
#   * that the suite is in check 10's list AT ALL. That list is a hand-maintained declaration, so
#     a suite added to disk and left out of it is simply never registration-checked. That is the
#     other half of the same incident: policy was missing from the list too.
#
# So this check reads the runners on disk and asserts BOTH directions against them. Together with
# check 10 walking $GATED_SUITES, the declaration and the disk are cross-checked each way: a suite
# gone from disk reds check 10, a suite missing from the declaration reds here, and a suite nobody
# invokes reds here. A suite nothing invokes is coverage the repo believes it has.
#
# Either Makefile target counts. The fast/slow split is deliberate — `make check` stays
# committable and the slow suites live in `make test` — so requiring both would fight it, and
# would red for council and shipyard, which `make check` correctly does not run.
#
# Scope: the pathspecs cover the two trees the repo actually ships, `plugins/` and `shared/`, and
# nothing else. The alternative was to scan every `*/tests/run-all.sh` on disk and then exempt the
# untracked entries under the project skill directories, the way checks 1, 2 and 5 do. Scoping by
# shipped path is the better fit for THIS check: the question is whether the repo's own Makefile
# runs the repo's own suites, and a local skill somebody keeps under `.claude/skills/` is not the
# Makefile's business whether it is tracked or not. Scanning it could only ever produce a false red
# for work that is deliberately none of the gate's concern.
#
# What the invocation test actually matches, stated because a green gate otherwise reads as more
# coverage than it is: a RECIPE line naming the runner — a line beginning with a tab, with the path
# delimited by whitespace or end-of-line. Restricting it to recipe lines is what makes it an
# invocation test rather than a mention test: an unanchored whole-file `grep -F` was tried first
# and a `#`-commented-out `@bash …run-all.sh` line satisfied it, leaving the check green over a
# suite that ran nowhere — the exact defect it exists to catch. The word-boundary requirement is
# the other half: without it a longer path that CONTAINS a shorter one (a vendored copy under
# `plugins/<p>/skills/<s>/shared/<mod>/tests/`) would satisfy the shorter one's assertion too.
# Matching recipe lines rather than named targets keeps it target-agnostic: a later `make
# test-slow` needs no edit here. The residual limit is that a recipe line in a target nothing ever
# invokes still counts; probes 30/30b/30c/30d close that for the four suites `make check` runs, by
# requiring a failing test in each to red `make check` itself.
#
# `$GIT_Q` and the explicit `:(glob)` magic are both load-bearing. Without `core.quotePath=false`
# a path holding a byte >= 0x80 comes back C-quoted and no `-F` match can succeed, reddening the
# gate over a path that, as printed, does not exist. And `:(glob)` pins the wildcard semantics:
# with default pathspecs, `GIT_GLOB_PATHSPECS=1` in the environment makes `*` stop crossing `/`,
# which silently drops the two deeply nested plugins/ runners while leaving four behind — enough
# that the compared-nothing arm below never fires and the check quietly stops asserting anything
# about shipyard and council. With `:(glob)` and `**` the semantics are the same either way, and
# `GIT_LITERAL_PATHSPECS=1` fails closed through that arm instead.
#
# Fails CLOSED: an errored listing, an empty one (both trees moved or renamed), a missing Makefile,
# and a grep that could not run each red, so "compared nothing" is never read as OK. The reverse
# direction — a target naming a runner that is gone — is deliberately not asserted, for check 10's
# reason: `make` already reds on it at runtime, `bash` exiting 127 on the missing path.
#
# `sort -u` is not cosmetic. `--cached` lists every STAGE of an unmerged path, so during a
# conflicted merge or rebase one runner comes back three times; `scanned` would then overcount and
# the same runner would be re-tested twice for nothing. An unresolved index is a normal state for a
# gate that runs before a commit, and this was observed for real while rebasing this very check.
# `$?` after the pipeline is safe because `pipefail` is set at the top of this file — a failing
# `git ls-files` still propagates. (The caveat about pipefail in check 10 is about process
# substitution, `<(…)`, which a plain pipe is not.)
runners=$(git $GIT_Q ls-files --cached --others --exclude-standard \
  ':(glob)plugins/**/tests/run-all.sh' ':(glob)shared/**/tests/run-all.sh' | sort -u)
runners_rc=$?
if [ "$runners_rc" -ne 0 ]; then
  fail "could not list the test runners on disk (git ls-files rc=$runners_rc)"
elif [ ! -f Makefile ]; then
  fail "Makefile is missing — cannot check that the test suites are invoked"
else
  # Recipe lines only, captured ONCE: every consumer below tests the same text, and a second grep
  # of the Makefile would be a second place for the "which lines count" rule to drift.
  recipes=$(grep '^	' Makefile)
  recipes_rc=$?
  # grep exits 1 on no match and >1 on an error. A Makefile with no recipe line at all is a real
  # state (every target empty), and it means nothing is invoked — so it must not be read as an
  # error, and must not be read as OK either: the per-runner arm below then reds for every runner.
  if [ "$recipes_rc" -gt 1 ]; then
    fail "could not read the Makefile's recipe lines (grep rc=$recipes_rc)"
  else
    scanned=0
    while IFS= read -r runner; do
      # A here-string over an empty listing still yields one empty line.
      [ -n "$runner" ] || continue
      scanned=$((scanned + 1))

      # 12a — is it invoked? `.` is the only regex metacharacter a git path can carry here, so
      # escaping it is enough to make the rest a literal match inside an ERE.
      esc=${runner//./\\.}
      printf '%s\n' "$recipes" | grep -qE "(^|[[:space:]])$esc([[:space:]]|\$)"
      case $? in
        0) ;;
        1) fail "test suite runner is invoked by no Makefile target (it never runs): $runner" ;;
        *) fail "could not scan the Makefile for a test runner invocation: $runner" ;;
      esac

      # 12b — is its suite declared in check 10's list? Without this, a suite can be Makefile-wired
      # (green above) and never registration-checked, because check 10 only visits what
      # $GATED_SUITES names. Compare whole entries, not substrings.
      suite=${runner%/run-all.sh}
      declared=no
      while IFS= read -r gated; do
        [ -n "$gated" ] || continue
        [ "$gated" = "$suite" ] && { declared=yes; break; }
      done <<< "$GATED_SUITES"
      [ "$declared" = yes ] || fail \
        "test suite is on disk but not in \$GATED_SUITES, so check 10 never registration-checks it: $suite"
    done <<< "$runners"
    # `scanned`, not `invoked`: this counts what was INSPECTED, and it is the compared-nothing
    # guard, not a claim that anything is invoked. Check 9's identical guard uses the same name.
    [ "$scanned" -gt 0 ] \
      || fail "found no test runner under plugins/ or shared/ (moved? renamed?)"
  fi
fi

[ $rc -eq 0 ] && echo "check: OK"
exit $rc
