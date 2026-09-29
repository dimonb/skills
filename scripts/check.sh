#!/usr/bin/env bash
# Repo gate. Runs on every commit (`make check`) and must be green before each.
#
# 1. every shell script parses (untracked too, except under a project skills dir)
# 2. every SKILL.md has name+description frontmatter, and its name matches its directory (ditto)
# 3. every plugin manifest is valid JSON, both manifests exist, names agree with the dir, and the
#    two manifests of a plugin declare the same version
# 4. marketplace entries resolve, and both manifests offer the same plugins as plugins/ on disk
# 5. dogfooding: every COMMITTED entry in a project skills dir is a symlink into plugins/; both
#    agents linked to every packaged skill, that link resolving inside plugins/ staged or not,
#    and never dropped from the index once HEAD has it; and no second copy of any SKILL.md
# 6. ship's forge reference files do not carry a copy of the pipeline state enum
# 7. no non-generic strings (structural patterns only; no dependency on any untracked file)
# 8. no non-Latin script in any file, untracked included (the checkable half of "English")
# 9. no council test names the shared temp parent (the pre-run-root shape); see §9 for its limits
# 10. every test on disk is registered in its suite's run-all.sh, for every suite $GATED_SUITES
#     declares, so no test silently stops running; and no two tests in one suite share a number
# 11. every vendored copy of a shared module is byte-identical to its module's one canonical source
# 12. every test runner on disk under plugins/ or shared/ is invoked by a Makefile recipe AND
#     declared in $GATED_SUITES, so no whole suite runs nowhere or escapes check 10
# 13. the check-test CI job's pull-request path filter covers every path check-test.sh guards, so
#     the gate-of-the-gate cannot be skipped by a change that could break what it proves; and its
#     triggers carry only the keys it reads: push on main, unfiltered (the backstop that filter
#     rests on), and pull_request narrowed by paths alone
# 14. no pgrep/pkill selects by parent (-P / --parent) without a pattern: on macOS that form
#     lists every process on the machine
# 15. every section cross-reference (a section sign and a number) in a markdown file names a
#     numbered heading that exists, in that file or in ship's core SKILL.md
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
shared/knobs/tests
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
# Each listing below is captured with its status BEFORE the loop that reads it, and an empty one is
# a failure (#58). Read through `done < <(git ls-files ...)` instead, a listing that errored or
# matched nothing was zero iterations with `rc` still 0: the assertion gone and the gate green.
sh_ls=$(git $GIT_Q ls-files --cached --others --exclude-standard '*.sh')
sh_rc=$?
if [ "$sh_rc" -ne 0 ]; then
  fail "could not list shell scripts for the syntax check (check 1) (git ls-files rc=$sh_rc)"
elif [ -z "$sh_ls" ]; then
  fail "the syntax check (check 1) found no shell script to parse (moved? renamed?)"
else
  while IFS= read -r f; do
    untracked_local_skill "$f" && continue
    bash -n "$f" || fail "syntax: $f"
  done <<< "$sh_ls"
fi

# ------------------------------------------------- 2. SKILL.md frontmatter + name
# ONE listing, read here and by check 5's outside-plugins loop, so the two cannot disagree about
# which SKILL.md files exist. A failed or empty listing reds once, and both loops are then skipped.
skillmd_ls=$(git $GIT_Q ls-files --cached --others --exclude-standard '*SKILL.md')
skillmd_rc=$?
if [ "$skillmd_rc" -ne 0 ]; then
  fail "could not list SKILL.md files (checks 2 and 5) (git ls-files rc=$skillmd_rc)"
  skillmd_ls=""
elif [ -z "$skillmd_ls" ]; then
  fail "checks 2 and 5 found no SKILL.md file at all (moved? renamed?)"
fi
while IFS= read -r f; do
  [ -n "$f" ] || continue
  untracked_local_skill "$f" && continue
  head -1 "$f" | grep -q '^---$' || { fail "frontmatter missing: $f"; continue; }
  fm=$(awk 'NR>1 && /^---$/{exit} NR>1' "$f")
  printf '%s\n' "$fm" | grep -q '^name:'        || fail "no name: $f"
  printf '%s\n' "$fm" | grep -q '^description:' || fail "no description: $f"
  want=$(basename "$(dirname "$f")")
  got=$(printf '%s\n' "$fm" | sed -n 's/^name: *//p' | tr -d '"'"'" | head -1)
  [ "$got" = "$want" ] || fail "skill name '$got' != directory '$want': $f"
done <<< "$skillmd_ls"

# --------------------------------------------- 3. plugin manifests: JSON + agreement
# The plugins on disk, listed through git rather than a `plugins/*/` glob, and read by checks 3 and
# 4 alike (#58). Two things follow, and both are the point:
#   * `.gitignore` applies. A raw glob saw every directory, so an untracked scratch directory under
#     plugins/ reddened checks 3 and 4 and nothing could silence it. Now an empty one is invisible
#     (git lists files, not directories) and an ignored one is too — the escape hatch checks 1 and
#     2 always had. An untracked plugin that is NOT ignored is still checked in full: it is what a
#     new plugin looks like before `git add`, and catching it then is why these checks read
#     untracked files at all.
#   * the listing is counted. A glob that matched nothing was a `[ -d ]` false, zero iterations and
#     a green gate; a listing that errored or found no plugin is now a failure.
plugins_ls=$(git $GIT_Q ls-files --cached --others --exclude-standard -- plugins/)
plugins_rc=$?
plugin_dirs=""
if [ "$plugins_rc" -ne 0 ]; then
  fail "could not list plugins/ (checks 3 and 4) (git ls-files rc=$plugins_rc)"
else
  # The first component, whether or not a path follows it: a plugin committed as a directory
  # symlink is ONE entry, `plugins/<name>`, which the glob this replaced followed. `[ -d ]` drops a
  # plain file sitting directly under plugins/.
  plugin_dirs=$(printf '%s\n' "$plugins_ls" | sed -n 's|^plugins/\([^/][^/]*\).*|\1|p' | sort -u \
    | while IFS= read -r n; do [ -d "plugins/$n" ] && printf '%s\n' "$n"; done)
  [ -n "$plugin_dirs" ] || fail "checks 3 and 4 found no plugin under plugins/ (moved? renamed?)"
fi
while IFS= read -r name; do
  [ -n "$name" ] || continue
  p=plugins/$name
  vers=""
  for m in "$p/.claude-plugin/plugin.json" "$p/.codex-plugin/plugin.json"; do
    if [ ! -f "$m" ]; then fail "missing manifest: $m"; continue; fi
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$m" \
      || { fail "invalid JSON: $m"; continue; }
    got=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("name",""))' "$m")
    [ "$got" = "$name" ] || fail "manifest name '$got' != directory '$name': $m"
    # 3d — the version (#20). An installed plugin is cached by its DECLARED version, so the two
    # agents' manifests carrying different ones is one plugin at two versions, drifting apart with
    # nothing to notice. Each must declare one, and the two must be the same string.
    #
    # What this does NOT assert, so a green gate is not read as more: that a change to a plugin
    # bumped its version. That comparison needs a merge base and a judgement about what counts as a
    # change, and it stays a release practice rather than a gate rule, so a merged change can still
    # reach nobody who already installed the plugin until someone bumps the number.
    ver=$(python3 -c 'import json,sys; v=json.load(open(sys.argv[1])).get("version",""); print(v if isinstance(v,str) else "")' "$m")
    if [ -z "$ver" ]; then fail "manifest declares no version string: $m"; continue; fi
    if [ -z "$vers" ]; then vers=$ver
    elif [ "$ver" != "$vers" ]; then
      fail "the two manifests of plugin '$name' carry different versions: '$vers' and '$ver' ($m)"
    fi
  done
  [ -d "$p/skills" ] || fail "plugin has no skills/ directory: $p"
  # A plugin may hold MANY skills; require at least one.
  find "$p/skills" -name SKILL.md -mindepth 2 -maxdepth 2 | grep -q . \
    || fail "plugin has no skills/<skill>/SKILL.md: $p"
done <<< "$plugin_dirs"

# ------------------------------------ 4. marketplace manifests: JSON + entries resolve
for m in .claude-plugin/marketplace.json .agents/plugins/marketplace.json; do
  if [ ! -f "$m" ]; then fail "missing marketplace manifest: $m"; continue; fi
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$m" \
    || { fail "invalid JSON: $m"; continue; }
  # Captured with its status, then counted (#58). Through `done < <(python3 ...)` an entry the
  # extractor could not read — `"source": {"path": 123}` is valid JSON, so the arm above passes it —
  # killed python having printed nothing, the loop ran zero times, and not one entry was asserted.
  entries=$(python3 - "$m" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for p in d.get("plugins", []):
    src = p.get("source")
    path = src if isinstance(src, str) else (src or {}).get("path", "")
    print("%s\t%s" % (p.get("name", ""), path.lstrip("./")))
PY
  )
  entries_rc=$?
  if [ "$entries_rc" -ne 0 ]; then
    fail "could not read the plugin entries of $m (python3 rc=$entries_rc)"; continue
  fi
  [ -n "$entries" ] || { fail "marketplace manifest lists no plugin: $m"; continue; }
  while IFS=$'\t' read -r name path; do
    [ -n "$name" ] || continue
    [ -d "$path" ] || fail "marketplace entry '$name' points at missing dir '$path': $m"
    [ "$(basename "$path")" = "$name" ] \
      || fail "marketplace entry '$name' points at differently-named dir '$path': $m"
  done <<< "$entries"
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
disk=$plugin_dirs          # check 3's listing, already sorted; see the note there
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
  # A listing that matched nothing has not held, it has abstained, and every assertion in the
  # loop below silently stops. This arm names that; the packaged-skill loop at the end of this
  # check also reds each packaged link HEAD has and the index does not, but a non-packaged entry
  # dropped with the rest is reported by this arm alone.
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
# Say WHICH checks ignore it. Checks 7 and 8 still read every untracked file that is not ignored —
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
  echo "note: untracked entry $e is local state; every check but the leak and English scans ignores it"
done <<< "$untracked_skills"

# A SKILL.md anywhere but plugins/ is a duplicated source of truth (tracked or not). The two
# project skills directories are exempt HERE because they are covered above instead, and more
# precisely: a committed SKILL.md under one of them is not mode 120000, so the mode assertion
# names it as the second copy it is, while an untracked one is the local state the note reports.
# Without this exemption a local skill reddened the gate TWICE — the `--others` reach of this
# loop is the other half of the same false positive, not a separate one.
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in plugins/*) continue ;; esac
  under_skill_dirs "$f" && continue
  fail "SKILL.md outside plugins/ (the packaged copy is the only source of truth): $f"
done <<< "$skillmd_ls"
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
    # Untracked is right for a link not yet added. A link HEAD has and the index does not is a
    # staged deletion: the link still resolves on disk, so everything below passes it, and the
    # next commit removes it from every clone (#58). No HEAD at all reads as "not in HEAD".
    if git cat-file -e "HEAD:$d/$skill" 2>/dev/null; then
      fail "packaged skill '$skill' link is in HEAD but dropped from the index, so the next commit deletes it: $d/$skill"
      continue
    fi
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
# The reference files, listed through git (so `.gitignore` applies to an untracked scratch file
# here, as it does to checks 1 and 2) and counted, for the reason checks 1 to 4 now are (#58).
# A git pathspec's `*` crosses `/`, so this reads a `.md` in a subdirectory of references/ too,
# which the glob it replaced did not: stricter, deliberately, since a copy of the enum there is the
# same defect.
ref_dir=plugins/ship/skills/ship/references
if [ ! -f "$core" ]; then
  # With no `else`, a moved or renamed core skipped this whole check: the enum-copy, handler and
  # record assertions all stopped existing and the gate stayed green (#58). This repo has renamed
  # a plugin before, which is how that happens.
  fail "check 6 cannot find the core skill that owns the state enum: $core (moved? renamed?)"
else
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
  refs_ls=$(git $GIT_Q ls-files --cached --others --exclude-standard -- "$ref_dir/*.md")
  refs_rc=$?
  if [ "$refs_rc" -ne 0 ]; then
    fail "could not list the forge reference files (check 6) (git ls-files rc=$refs_rc)"
  elif [ -z "$refs_ls" ]; then
    fail "check 6 found no forge reference file under $ref_dir (moved? renamed?)"
  else
    while IFS= read -r ref; do
      for st in $states; do
        case "$st" in *-*) ;; *) continue ;; esac
        # 0 / 1 / >1, as checks 7 to 9 read grep: an error is not "the name is absent".
        grep -qF -- "$st" "$ref"
        case $? in
          0) fail "forge reference carries the state name '$st' (the core owns it): $ref" ;;
          1) ;;
          *) fail "check 6 could not read forge reference $ref"; break ;;
        esac
      done
    done <<< "$refs_ls"
  fi

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
  # measured: a change whose stage column read `—` across its whole review, because its run wrote
  # the state file late, which is what the instruction is for.
  # `done` is included here, unlike the handler arm above: a terminal state is exactly the one a
  # supervisor most needs to see recorded.
  #
  # WHAT THIS IS, stated because a green gate is otherwise read as coverage, and stated narrowly
  # because the first version of this comment overstated it and two review axes proved the
  # overstatement by mutation. It is a DOCS-CONSISTENCY check over the core's own prose, and it
  # asserts ONLY that each enum state is recorded SOMEWHERE in the core — one unanchored match per
  # state NAME, not one per transition. A state recorded on one path and not on another still
  # passes: `done`, `needs-human`, `ready-to-merge` and `apply` each have more than one transition
  # site, so deleting the instruction from one of them is green here. Which individual transitions
  # carry it is judgement, not gate; a positional arm would be new machinery and is not worth it
  # for prose whose sections move. And NOTHING here is a runtime guarantee that any run wrote any
  # file — whether a child obeys the instruction is not checkable from this repo at all. The half
  # of #124 that holds regardless of what a child does is shipyard-report.sh's forge fallback.
  # The trailing backtick is ANCHORING, not decoration: `grep -F` matches a substring, so an
  # unterminated `record state=spec` is satisfied by `record state=spec-review` — the same prefix
  # hole the sibling handler arm above anchors against, and with the same consequence, a state
  # nothing records passing green. No current enum name prefixes another, so this is a guard
  # against the enum the repo has not written yet; `spec` is check-test probe 6b's own fixture.
  # Every one of the core's record sites is backtick-terminated, so one character closes it.
  for st in $states; do
    grep -qF -- "record state=$st\`" "$core" \
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
# The home root need not be the FIRST path component (#126), just as the slash arms match `/home/`
# at any depth: `/var/home/<name>` flattens to `-var-home-<name>` and the macOS data-volume path
# `/System/Volumes/Data/Users/<name>` to `-System-Volumes-Data-Users-<name>`. So any number of
# encoded components may sit between the token's start and the root, each a `-` and a name. The
# token's start keeps the bound above, which is what still rejects a hyphenated phrase: in
# `nav-home-link` the word before the root has no `-` of its own in front of it.
#
# What the widening costs, taken knowingly: a single-dash option with a word in front of the root
# (`-no-home-dir`) now reds, where only `-home-dir` did before. It is the same shape as
# `/no/home/dir` encoded, so it errs the way this arm already errs, and nothing in the tree
# matches it. One limit stays: there is no trailing-separator anchor, because an encoded home
# directory with nothing after it still discloses the username.
deny="$deny"'|(^|[^A-Za-z0-9-])(-[a-zA-Z0-9._]+)*-(Users|home)-[a-zA-Z0-9._]+'
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
      # UNPROBED: its only trigger is an unreadable file, a no-op as root (see check-test.sh, expect_fail)
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
  # 10b — no two tests in one suite share a number (#149). Two changes developed in parallel both
  # pick "the next free number" off the same `main`, so they pick the same one; after the rebase
  # resolves the registration line, both files run and nothing says the number now means nothing.
  # The number is the whole prefix before the first `-` — `t12`, `t9b` — so the letter-suffix
  # scheme (`t9`, `t9b`, `t9c`) is distinct numbers by construction, and a suite whose files
  # carry no digits (`t-driver.sh`) has no number to collide on and is not read.
  if [ "$suite_rc" -eq 0 ] && [ -n "$suite_tests" ]; then
    dup_nums=$(printf '%s\n' "$suite_tests" | sed -n 's/^\(t[0-9][0-9]*[a-z]*\)-.*/\1/p' \
      | sort | uniq -d)
    for num in $dup_nums; do
      fail "two tests in $suite_dir share the number $num (renumber one): $(printf '%s\n' "$suite_tests" \
        | grep "^$num-" | tr '\n' ' ')"
    done
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
# invokes still counts — and, for the same reason, that this check cannot tell a suite in `check:`
# from one in `test:`, which is deliberate (it is what lets the fast/slow split exist) but means it
# cannot see a suite quietly leaving the per-commit gate. The 30* probes in check-test.sh close
# both, one per suite `make check` runs, by requiring a failing test in each to red `make check`
# itself. Add one whenever that recipe grows: a suite added to it without a probe is exactly how
# the knobs suite was briefly ungated.
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
        # UNPROBED: its only trigger is an unreadable file, a no-op as root (see check-test.sh, expect_fail)
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

# ------------------ 13. the check-test job's PR path filter covers everything its probes mutate
# `make check-test` runs on every push to main and, on a PULL REQUEST, only when the change
# touches a path that could affect what it proves (see .github/workflows/check-test.yml for why).
# That filter is the whole of the risk in skipping it, so it is DERIVED rather than written by
# hand: the derivation is `$GUARDED` in scripts/check-test.sh — the paths that file restores with
# `git checkout --`, i.e. an upper bound on what its probes mutate — and this check asserts the
# filter still covers it.
#
# WHAT IT CATCHES: a path added to `$GUARDED` and not to the filter. That is the direction this
# goes quiet in — a future probe mutates a new tree, the author adds it to `$GUARDED` because
# otherwise the restore misses it, and nothing would otherwise connect that to a CI filter in
# another file.
#
# WHAT IT DOES NOT CATCH, so a green gate is not read as more: it does not verify that `$GUARDED`
# is itself complete. A probe that mutates a path outside it and restores it by hand satisfies
# both this check and check-test's own end-of-run cleanliness assertion. That one is judgement,
# and it is stated in check-test.yml too. Nor does it read the job: it reads the triggers only, so a
# job-level `if:` that skips pushes, or a step that no longer runs `make check-test`, takes the
# backstop away with this check green.
#
# Both inputs are read with a LOUD failure if either cannot be read: a filter check that abstains
# is worse than none, because the job it guards is the one that proves the rest of this file is
# not decoration.
CT_FILE=scripts/check-test.sh
CT_WF=.github/workflows/check-test.yml
if [ ! -f "$CT_FILE" ]; then
  fail "scripts/check-test.sh is missing — cannot check the check-test job's path filter"
elif [ ! -f "$CT_WF" ]; then
  fail "$CT_WF is missing — the gate-of-the-gate has no workflow to run it"
else
  # The single-quoted assignment, on one line, exactly as check-test.sh declares it.
  guarded=$(sed -n "s/^GUARDED='\([^']*\)'.*/\1/p" "$CT_FILE" | head -1)
  # The `on:` block, read BY TRIGGER (#215). A flat scrape of every list item in the file could
  # not see which event a `paths:` list sat under, so a list added under `push:` both removed the
  # unconditional backstop and lent its entries to the pull-request filter, which then read as
  # covering paths it did not. This reads the block by indentation and prints one row per event
  # (`event <name>`), per key under an event (`key <event> <name>`), and per QUOTED list item under
  # such a key (`item <event> <key> <value>`), a key quoted or not. It reads block-style YAML only.
  # For `push:` and `pull_request:`, the events this check is about, a line it cannot place reds
  # below rather than passing: `on:` in flow style (`on: [push]`) reads as a missing `push:`; an
  # event carrying a value on its own line (`push: {paths: [...]}`) prints `inline <event>`; a line
  # under an event that is neither a key nor a `-` item (a flow mapping on the next line, `paths :`)
  # prints `unread <event>`; and an event line it cannot name (`pull_request_target :`) prints
  # `unread ?` and reds whatever it is, since the lines under it would otherwise be credited to the
  # event before it. Where the trigger is in fact unfiltered those are false reds, fixed by writing
  # the block style this file already uses; where it carries a filter they are the red it deserves.
  # A `-` item is read only when it is one quoted scalar with nothing after it but a comment, so an
  # unquoted item or an escape (`'a''b'`) is not read. Every `-` line under a key is still counted
  # (a `raw` row), and under `pull_request:`'s `paths:` and `push:`'s `branches:` a count that
  # disagrees with what was read reds; under any other key of either event the key itself has
  # already red. A key with a value on its own line prints `keyval <event> <key>`, since the lines
  # below it are not its items.
  ct_on=$(awk '
    function name(s) { sub(/:.*/, "", s); gsub(/["\047]/, "", s); return s }
    # A line in column 0 opens a top-level key; only the `on:` block is read.
    /^[^ #]/ { inon = ($0 ~ /^["\047]?on["\047]?:[ ]*(#.*)?$/); next }
    !inon || /^[ ]*(#.*)?$/ { next }
    {
      match($0, /^ */); ind = RLENGTH; line = substr($0, ind + 1)
      if (evind == 0) evind = ind
      if (ind <= evind) {
        if (line ~ /^["\047]?[A-Za-z_][A-Za-z0-9_-]*["\047]?:/) {
          ev = name(line); key = ""; print "event\t" ev
          if (line !~ /^[^:]*:[ \t]*(#.*)?$/) print "inline\t" ev
        } else {
          # An event it cannot name (`pull_request_target :`, `? push`): the lines under it belong
          # to no event it knows, never to the one before it.
          ev = "?"; key = ""; print "unread\t?"
        }
        next
      }
      if (line ~ /^["\047]?[A-Za-z_][A-Za-z0-9_-]*["\047]?:/) {
        key = name(line); print "key\t" ev "\t" key
        # A value on the same line as the key (a flow list, a scalar, a block-scalar indicator): the
        # lines under it, if any, are not list items of that key, whatever they look like.
        if (line !~ /^[^:]*:[ \t]*(#.*)?$/) print "keyval\t" ev "\t" key
        next
      }
      # Neither a key nor a list item, e.g. a flow mapping on the line below its event, or a key
      # with a blank before its colon: a shape this reader cannot place.
      if (line !~ /^-/) { print "unread\t" ev; next }
      if (key == "") next
      print "raw\t" ev "\t" key
      if (line ~ /^- *\047[^\047\t]*\047[ \t]*(#.*)?$/) { v = line; sub(/^- *\047/, "", v); sub(/\047.*/, "", v) }
      else if (line ~ /^- *"[^"\\\t]*"[ \t]*(#.*)?$/) { v = line; sub(/^- *"/, "", v); sub(/".*/, "", v) }
      else next
      print "item\t" ev "\t" key "\t" v
    }
  ' "$CT_WF" 2>&1); ct_rc=$?
  # A REFUSAL, NOT AN ANALYSIS. `paths-ignore:` is the same YAML shape as `paths:` with the
  # opposite meaning, and this check reasons only about an explicit list of paths that DO run the
  # job. An inverted list would need the reverse reasoning, and a check that got it wrong would
  # report full coverage while the job skipped on exactly the paths it was proving were covered.
  # So the key anywhere in the file is red, under any trigger.
  # ANCHORED ON THE KEY, not on the word. An unanchored match would red on PROSE — including the
  # sentence just above that names the construct, and the one in the workflow's own header that
  # explains the refusal, which is the natural next edit somebody makes. That red would be
  # permanent, on a correct file, with full coverage intact.
  if grep -qE '^[[:space:]]*["'\'']?paths-ignore["'\'']?:' "$CT_WF"; then
    fail "$CT_WF uses paths-ignore, which check 13 does not reason about — it checks an explicit list of the paths that run the job, and an inverted list would read as full coverage"
  fi
  # The reader splits lines on LF alone, and YAML also breaks a line at CR, NEL, LS and PS: a key or
  # an entry after one of those, behind a comment, is a line to a YAML parser and none to awk.
  if LC_ALL=C grep -qE "$(printf '\r|\302\205|\342\200\250|\342\200\251')" "$CT_WF"; then
    fail "$CT_WF contains a line break other than LF (CR, NEL, LS or PS), which check 13 does not read — a YAML parser may split a line there that check 13 reads as one"
  fi
  if [ "$ct_rc" -ne 0 ]; then
    fail "could not read the triggers out of $CT_WF (check 13, awk rc=$ct_rc): $ct_on"
  else
    # The backstop the pull-request filter rests on: an unconditional run on every push to main.
    # A `push:` that is gone, or that carries a path filter, turns a too-narrow pull-request filter
    # from one late red at merge into a silent gap.
    if ! printf '%s\n' "$ct_on" | grep -qxF "$(printf 'event\tpush')"; then
      fail "$CT_WF has no push: trigger — check-test's unconditional run on main, the backstop for its pull-request filter, is gone"
    fi
    push_filter=$(printf '%s\n' "$ct_on" | awk -F'\t' '$1 == "key" && $2 == "push" && $3 ~ /^paths(-ignore)?$/ { print $3 }')
    if [ -n "$push_filter" ]; then
      fail "$CT_WF filters its push: trigger by $(printf '%s' "$push_filter" | tr '\n' ' ')— the run on main must be unconditional, it is the backstop for the pull-request filter"
    fi
    # AN ALLOWLIST OF KEYS, not a denylist of the ones seen so far (#58). Under `push:` only
    # `branches:` is accepted, and under `pull_request:` only `paths:`: every other key GitHub
    # honours there narrows when the job runs (`branches-ignore:`, `tags:`, `types:`, a
    # `branches:` on pull requests), and each of those passed green while this check read only the
    # keys it was written about. `paths`/`paths-ignore` are left to the arms that name them.
    for ev in push pull_request; do
      if [ "$ev" = push ]; then allowed=branches; else allowed=paths; fi
      extra=$(printf '%s\n' "$ct_on" | awk -F'\t' -v ev="$ev" -v ok="$allowed" \
        '$1 == "key" && $2 == ev && $3 != ok && $3 !~ /^paths(-ignore)?$/ { print $3 }')
      if [ -n "$extra" ]; then
        fail "$CT_WF's $ev: trigger carries $(printf '%s\n' "$extra" | tr '\n' ' ')— check 13 accepts only $allowed: there, since any other key narrows when check-test runs"
      fi
    done
    # A key under either event with a value on its own line is one whose lines below it the reader
    # would otherwise take for its list items: `branches: >-` over `- 'main'` is a string to YAML.
    for ev in push pull_request; do
      kv=$(printf '%s\n' "$ct_on" | awk -F'\t' -v ev="$ev" '$1 == "keyval" && $2 == ev { print $3 }')
      if [ -n "$kv" ]; then
        fail "$CT_WF writes $(printf '%s\n' "$kv" | tr '\n' ' ')under its $ev: trigger with a value on the key's own line, which check 13 does not read — write it as a block list, as the rest of the file does"
      fi
    done
    # And the one list `push:` may carry is exactly `main`, as a quoted block item. A list without it
    # (`main-old` alone) is a push trigger that never fires on main; and any other entry beside it is
    # refused rather than reasoned about, since a negated pattern (`'!main'`) excludes main again and
    # an alias, an escape (`'main''x'` is main'x to YAML, so it is not read) or an unquoted item may
    # spell one this reader cannot see. So every `-` line under `branches:` must read as `main`. A
    # flow list (`branches: [main]`) or an unquoted `- main` reds too: a false red on a correct file,
    # fixed by the block style. Both counts come from awk's `n + 0`, so neither is ever empty.
    push_raw=$(printf '%s\n' "$ct_on" | awk -F'\t' '$1 == "raw" && $2 == "push" && $3 == "branches" { n++ } END { print n + 0 }')
    push_main=$(printf '%s\n' "$ct_on" | awk -F'\t' '$1 == "item" && $2 == "push" && $3 == "branches" && $4 == "main" { n++ } END { print n + 0 }')
    if [ "$push_main" -eq 0 ]; then
      fail "$CT_WF's push: trigger does not name 'main' under branches: (as a quoted block item) — check-test's unconditional run on main, the backstop for its pull-request filter, is gone"
    elif [ "$push_raw" -ne "$push_main" ]; then
      fail "$CT_WF's push: branches: carries an entry other than 'main' — check 13 accepts exactly 'main' there, since a negated, aliased or unquoted entry could exclude main again"
    fi
    # A key written twice under one of the two events, or either event written twice: YAML parsers
    # disagree on which copy wins, so the copy this reader credits need not be the one that runs.
    dup=$(printf '%s\n' "$ct_on" | awk -F'\t' '
      $1 == "event" && ($2 == "push" || $2 == "pull_request") { print "on." $2 }
      $1 == "key" && ($2 == "push" || $2 == "pull_request") { print $2 "." $3 }' | sort | uniq -d)
    if [ -n "$dup" ]; then
      fail "$CT_WF repeats $(printf '%s\n' "$dup" | tr '\n' ' ')under on: — YAML parsers disagree on which copy wins, so check 13 refuses a repeated key there"
    fi
    # A line at event level it could not name reds whatever event it is, since the lines under it
    # would otherwise be credited to the event before it.
    if printf '%s\n' "$ct_on" | grep -qxF "$(printf 'unread\t?')"; then
      fail "$CT_WF has an event under on: that check 13 cannot read as a key — write it as a block, as the rest of the file does"
    fi
    # A value on the event's own line is flow style, which the reader above does not look inside:
    # `push: {branches: [main], paths: [...]}` would otherwise read as an unfiltered push. And a
    # line under the event that is neither a key nor a list item is one it could not place.
    for ev in push pull_request; do
      if printf '%s\n' "$ct_on" | grep -qxF "$(printf 'inline\t%s' "$ev")"; then
        fail "$CT_WF writes its $ev: trigger in flow style, which check 13 does not read inside — write it as a block, as the rest of the file does"
      fi
      if printf '%s\n' "$ct_on" | grep -qxF "$(printf 'unread\t%s' "$ev")"; then
        fail "$CT_WF has a line under its $ev: trigger that check 13 cannot read as a key or a list item — write it as a block, as the rest of the file does"
      fi
    done
  fi
  # The pull-request filter is the `paths:` list under `pull_request:` and nothing else, so an entry
  # under another trigger cannot stand in for one missing here.
  filter=$(printf '%s\n' "$ct_on" | awk -F'\t' '$1 == "item" && $2 == "pull_request" && $3 == "paths" { print $4 }')
  if [ -z "$guarded" ]; then
    fail "could not read \$GUARDED out of $CT_FILE — the check-test path filter cannot be checked"
  elif [ "$ct_rc" -ne 0 ]; then
    :   # reported above; the arms below would only repeat it as an empty filter
  elif [ -z "$filter" ]; then
    fail "could not read any path filter out of $CT_WF — a pull request would skip check-test entirely"
  else
    # Every entry of the filter is read, or the filter is refused: an entry the reader skips (an
    # unquoted `- docs/**`, an escape) would drop out silently wherever `$GUARDED` does not derive
    # it. And a negated entry (`'!scripts/**'`) takes a guarded tree back out of a filter that still
    # lists it, which the coverage loop below cannot see, so it is refused rather than reasoned about.
    pr_raw=$(printf '%s\n' "$ct_on" | awk -F'\t' '$1 == "raw" && $2 == "pull_request" && $3 == "paths" { n++ } END { print n + 0 }')
    pr_read=$(printf '%s\n' "$filter" | awk 'NF { n++ } END { print n + 0 }')
    if [ "$pr_raw" -ne "$pr_read" ]; then
      fail "$CT_WF's pull_request: paths: has an entry check 13 cannot read (unquoted, aliased or escaped) — write every entry as a quoted block item"
    fi
    if printf '%s\n' "$filter" | grep -q '^!'; then
      fail "$CT_WF's pull_request: paths: carries a negated pattern, which check 13 does not reason about — it could take a guarded tree back out of the filter"
    fi
    for g in $guarded; do
      # A file entry must appear verbatim; a directory entry is covered by `<dir>/**`.
      if [ -f "$g" ]; then want="$g"; else want="$g/**"; fi
      printf '%s\n' "$filter" | grep -qxF -- "$want" \
        || fail "check-test guards '$g' but $CT_WF's path filter has no '$want' — a pull request touching it would skip the gate-of-the-gate"
    done
    # No separate arm for "the filter names the workflow that carries it": `$GUARDED` includes
    # `.github` (check-test's probes mutate this very file), so the loop above already requires
    # `.github/**`, which covers it. If `.github` ever leaves that list, this needs its own arm.
  fi
fi

# ------------------ 14. no pgrep/pkill selecting by parent (-P / --parent) without a pattern
# On macOS, `pgrep -P "$pid"` given NO pattern ignores `-P` and prints every pid on the machine
# (measured: 680 on one desktop session; with a pattern, `pgrep -P "$pid" sleep` filters
# correctly). A test fed that list to `kill -9` and killed every process the user owned, the
# terminal hosting the fleet included, on every resume of the slot that carried it (#265). Reading
# the code did not find it: every `kill` named a value the code believed was a child pid, and the
# defect was in the tool's semantics. So the shape is gated, and the safe form is named in the
# message: `ps -A -o pid= -o ppid=` filtered by awk on the parent column behaves the same on both
# platforms. `pkill` is matched as well because it shares pgrep's option parser on both platforms
# and is the direct-kill form of the same lookup; its no-pattern behaviour was not measured here.
#
# Scope: the same file set as check 1 — every tracked or untracked `*.sh`, minus an untracked
# local skill. What it parses: the tokens after a `pgrep`/`pkill` word up to a shell separator
# (`| ; & ( )` or a backquote) or a `#`, with backslash-continued lines joined first, quoted spans
# and process substitutions read as the awk program's `unquote` and `scan` comments say, and
# redirections (`2>/dev/null`, `2>&1`, `> file`) removed with their targets. A `-P` or
# `--parent` in that span with no non-option word left over after the option arguments are
# consumed is a hit. The command word is read with its quotes stripped, so a lookup inside
# `sh -c "…"` counts. Whole-line comments are skipped, so prose about the trap may quote it.
#
# What it cannot see, stated because a green gate is otherwise read as coverage: a pid list built
# any OTHER way — a different tool, a pattern that matches more than intended, a parent lookup in
# a file that is not `*.sh` (a Makefile recipe, an extensionless script), or `pgrep` reached
# through a variable or an alias. It also over-reads a quoted string that happens to spell the
# shape (`echo "pgrep -P x"`); that reds, loudly, which is the direction to err in. Quoting is
# read one level deep (#272): a quoted span is one word unless it holds the command word. Not
# unwrapped, so a space inside can still split off a fragment that reads as the pattern: an
# escaped quote nested in a quoted command (`sh -c "pgrep -P \"$a $b\""`), and a quoted `)`
# inside a `$(...)` within double quotes, which ends that skip early. A lookup inside a process
# substitution that is itself another lookup's pattern (`pgrep -P "$x" <(pgrep -f y)`) reds,
# loudly. The rule it backs is broader and lives in AGENTS.md: a helper that signals a LIST of
# pids refuses pid 1 and bounds the list, because the list is exactly what a wrong lookup inflates.
pg_files=$(git $GIT_Q ls-files --cached --others --exclude-standard '*.sh'); pg_rc=$?
if [ "$pg_rc" -ne 0 ]; then
  fail "could not list shell files for the parent-pid lookup scan (check 14) (git ls-files rc=$pg_rc)"
else
  pg_list=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    untracked_local_skill "$f" && continue
    # `./` so awk never reads a name such as `x=y.sh` as a variable assignment.
    pg_list+=("./$f")
  done <<< "$pg_files"
  if [ "${#pg_list[@]}" -eq 0 ]; then
    fail "the parent-pid lookup scan (check 14) found no shell file to read (moved? renamed?)"
  else
    # Option letters that take an argument, from the union of the macOS and procps man pages: the
    # argument is consumed so it is never mistaken for the pattern.
    pg_hits=$(awk '
      # An option argument is the next word, never a separator or a comment: `-P` at the end of
      # a command has no argument to consume, and swallowing the `#` would read the comment as
      # the pattern.
      function optarg(t, j, n) {
        if (j < n && t[j+1] != ";" && t[j+1] !~ /^#/) return j + 1
        return j
      }
      # A quoted span is one word: its blanks and separators become \001, so `-P "$a $b"` or
      # `2>"$d/a b"` leaves no fragment to read as the pattern. A span holding the command word is
      # left as it was when it IS the command word: one word (`"pgrep" -P`), or a path or leading
      # blanks ending in it with no separator (`"$d/a b/pgrep" -P`, `" pgrep" -P`, #272), whose
      # blank then splits off only a fragment the command-word test skips. Otherwise it is read as
      # the command it is
      # (`sh -c "cd d && pgrep -P $x"`), its closing quote ending that command so a word after it
      # (`sh -c "..." arg`) is not its pattern. Inside double quotes a `$(...)` is skipped whole,
      # so its own quotes (`"$(pgrep -P "$x" sleep)"`) do not close the outer span.
      function unquote(s,   out, i, n, q, j, c, d, body) {
        out = ""; n = length(s); i = 1
        while (i <= n) {
          q = substr(s, i, 1)
          if (q == "\\") { out = out substr(s, i, 2); i += 2; continue }
          if (q != "\"" && q != "\047") { out = out q; i++; continue }
          d = 0
          for (j = i + 1; j <= n; j++) {
            c = substr(s, j, 1)
            if (q == "\"" && c == "\\") { j++; continue }
            if (q == "\"" && substr(s, j, 2) == "$(") { d++; j++; continue }
            if (d > 0 && c == ")") { d--; continue }
            if (c == q && d == 0) break
          }
          body = substr(s, i + 1, j - i - 1)
          if (body !~ /(^|[^A-Za-z0-9_.-])p(grep|kill)([^A-Za-z0-9_.-]|$)/) {
            gsub(/[ \t|;&()`<>]/, "\001", body); out = out q body q
          } else if (body ~ /[ \t]/ && !(body ~ /(^[ \t]*|[\/\\])p(grep|kill)$/ && body !~ /[|;&()`<>]/))
            out = out q unquote(body) " ; "
          else out = out q body q
          i = j + 1
        }
        return out
      }
      function scan(s, where,   n, t, i, j, tok, base, hasP, pat, k, c, rest, m) {
        if (s ~ /^[ \t]*#/) return
        s = unquote(s)
        # A process substitution is one argument, so `<(true) sleep` leaves `sleep` as the
        # pattern; one that holds the command word (`done < <(pgrep -P "$x")`) is read as the
        # command it is instead. Each pass removes one `<(`, so the loop ends.
        while (match(s, /[<>]\([^)]*\)/)) {
          m = substr(s, RSTART + 2, RLENGTH - 3)
          if (m ~ /(^|[^A-Za-z0-9_.-])p(grep|kill)([^A-Za-z0-9_.-]|$)/) m = " ; " m " ; "
          else m = " psub "
          s = substr(s, 1, RSTART - 1) m substr(s, RSTART + RLENGTH)
        }
        # A redirection and its target are not a pattern, and the incident line itself carried
        # one (`pgrep -P "$cpid" 2>/dev/null`). Removed BEFORE the separators, so the `&` of
        # `2>&1` and `&>` is still attached to its operator here.
        gsub(/[0-9]*(&>>|&>|>>|>&|<&|<<<|<<-|<<|<>|>\||>|<)[ \t]*[^ \t|;&()`]*/, " ", s)
        gsub(/[|;&()`]/, " ; ", s)
        n = split(s, t, /[ \t]+/)
        for (i = 1; i <= n; i++) {
          if (t[i] ~ /^#/) return
          # Quotes and backslashes off the command word, so `sh -c "pgrep -P $x"` and the
          # alias-bypassing `\pgrep` are read as the lookup they are.
          base = t[i]; gsub(/["\047\\]/, "", base); sub(/.*\//, "", base)
          if (base != "pgrep" && base != "pkill") continue
          hasP = 0; pat = 0
          for (j = i + 1; j <= n; j++) {
            tok = t[j]
            if (tok == ";" || tok ~ /^#/) break
            if (tok == "") continue
            if (tok == "--") { if (j < n && t[j+1] != ";") pat = 1; break }
            if (tok ~ /^--/) {
              if (tok ~ /^--parent(=|$)/) hasP = 1
              if (tok ~ /^--(parent|pgroup|group|session|terminal|euid|uid|pidfile|delimiter|ns|nslist|runstates|cgroup|signal)$/) j = optarg(t, j, n)
              continue
            }
            # A pkill signal name (`-TERM`, `-SIGKILL`) is not an option cluster: read letter by
            # letter it would consume the next word as an argument and hide a `-P` behind it.
            # `-P123` is the parent selector with its pid attached, never a signal.
            if (base == "pkill" && tok ~ /^-(SIG)?[A-Z][A-Z0-9+]+$/ && tok !~ /^-P[0-9]/) continue
            if (tok ~ /^-./) {
              for (k = 2; k <= length(tok); k++) {
                c = substr(tok, k, 1)
                if (c == "P") hasP = 1
                if (index("dFgGJMNPrstuU", c)) {
                  rest = substr(tok, k + 1)
                  if (rest == "") j = optarg(t, j, n)
                  break
                }
              }
              continue
            }
            pat = 1
          }
          if (hasP && !pat) print where ": " s0
        }
      }
      # A file ending on a continued line still has its last command scanned.
      FNR == 1 && buf != "" { s0 = buf; buf = ""; scan(s0, prev ":" start) }
      { prev = FILENAME; sub(/^\.\//, "", prev) }
      {
        line = $0
        if (buf == "") start = FNR
        if (line ~ /\\$/) { buf = buf substr(line, 1, length(line) - 1) " "; next }
        s0 = buf line; buf = ""
        scan(s0, prev ":" start)
      }
      END { if (buf != "") { s0 = buf; scan(s0, prev ":" start) } }
    ' "${pg_list[@]}" 2>&1); pg_awk=$?
    if [ "$pg_awk" -ne 0 ]; then
      fail "the parent-pid lookup scan (check 14) could not run (awk rc=$pg_awk): $pg_hits"
    elif [ -n "$pg_hits" ]; then
      echo "FAIL: pgrep/pkill with -P/--parent and no pattern (on macOS it lists EVERY process;"
      echo "      use: ps -A -o pid= -o ppid= | awk -v p=\"\$pid\" '\$2 == p { print \$1 }'):"
      printf '%s\n' "$pg_hits"; rc=1
    fi
  fi
fi

# ------------------ 15. every section cross-reference names a heading that exists
# ship's core SKILL.md is a numbered document, and the other markdown files here cite it and
# themselves by section — `§5.11`, `core §7.B`, `ship's §2.8`. A dangling one is the defect
# AGENTS.md names for a stale flag or state name: an agent follows the pointer, finds nothing, and
# proceeds on whatever it inferred. Inserting or renumbering a section is exactly the edit that
# breaks them, and nothing else here would notice (#213).
#
# What it asserts: every `§N`, `§N.M` or `§N.A` in a markdown file (tracked or untracked, minus an
# untracked local skill, the file set of checks 1 and 2) is the number of a `#`-to-`####` heading in
# THAT file or in the core. A trailing sentence dot is not part of the number (`see §7.`).
#
# What it does not, so a green gate is not read as more: it resolves against the union of the two
# heading sets, never against the file a reference means. A shipyard file citing ship's `§3` is
# satisfied by a `## 3.` of its own, and a `core §N` is satisfied by a same-numbered heading in the
# citing file. It checks that the section EXISTS, not that it still says what the citation claims.
# It reads markdown only: the `§N` in a shell comment (this file's header cites its own checks that
# way) is not read. And a numbered `#` line inside a fenced code block counts as a heading.
#
# Fails CLOSED: an errored listing, an empty one, a core with no numbered heading, a scan that could
# not run, and a scan that found no reference at all each red, so "compared nothing" is never OK.
xr_files=$(git $GIT_Q ls-files --cached --others --exclude-standard '*.md'); xr_rc=$?
if [ "$xr_rc" -ne 0 ]; then
  fail "could not list markdown files for the section cross-reference check (check 15) (git ls-files rc=$xr_rc)"
elif [ ! -f "$core" ]; then
  fail "the section cross-reference check (check 15) cannot find the core it resolves against: $core"
else
  xr_list=()
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    untracked_local_skill "$f" && continue
    xr_list+=("$f")
  done <<< "$xr_files"
  if [ "${#xr_list[@]}" -eq 0 ]; then
    fail "the section cross-reference check (check 15) found no markdown file to read (moved? renamed?)"
  else
    xr_out=$(python3 - "$core" "${xr_list[@]}" <<'PY' 2>&1
import re, sys
HEAD = re.compile(r'^#{1,4} +([0-9]+(?:\.[0-9A-Z]+)*)\.?(?:\s|$)')
REF = re.compile('§([0-9]+(?:\\.[0-9A-Z]+)*)')
def heads(p):
    with open(p, encoding='utf-8', errors='replace') as f:
        return {m.group(1) for m in map(HEAD.match, f) if m}
core = heads(sys.argv[1])
if not core:
    print("NOHEAD"); sys.exit(0)
refs = 0
for p in sys.argv[2:]:
    known = heads(p) | core
    with open(p, encoding='utf-8', errors='replace') as f:
        for i, line in enumerate(f, 1):
            for m in REF.finditer(line):
                refs += 1
                if m.group(1) not in known:
                    print("DANGLING %s:%d: §%s" % (p, i, m.group(1)))
if refs == 0:
    print("NOREF")
PY
    ); xr_py=$?
    if [ "$xr_py" -ne 0 ]; then
      fail "the section cross-reference check (check 15) could not run (python3 rc=$xr_py): $xr_out"
    elif printf '%s\n' "$xr_out" | grep -qx NOHEAD; then
      fail "the section cross-reference check (check 15) found no numbered heading in $core"
    elif printf '%s\n' "$xr_out" | grep -qx NOREF; then
      fail "the section cross-reference check (check 15) found no section reference in any markdown file (moved? renamed?)"
    elif printf '%s\n' "$xr_out" | grep -q '^DANGLING'; then
      echo "FAIL: dangling section cross-reference (no such numbered heading in the file or in $core):"
      printf '%s\n' "$xr_out" | sed -n 's/^DANGLING /  /p'; rc=1
    fi
  fi
fi

[ $rc -eq 0 ] && echo "check: OK"
exit $rc
