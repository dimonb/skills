#!/usr/bin/env bash
# shipyard-down-gate.sh — the teardown safety gate. Source only, never execute.
#
# One question, asked about CONTENT: if this worktree is removed, is anything lost?
#
# It used to be asked about ANCESTRY — `@{upstream}..HEAD` — and that is the wrong question at
# exactly the moment teardown happens. Two measured failures, opposite directions:
#
#   * FALSE REFUSAL on the happy path. A slot's branch is created with
#     `git switch -c <branch> origin/<base>`, which sets its upstream to `origin/<base>` (not to
#     its own remote branch, which does not exist yet), and a later push by refspec never
#     updates it. So `@{upstream}..HEAD` is `origin/<base>..HEAD` — the branch's own commits —
#     and after a SQUASH merge none of them is an ancestor of the base branch no matter how
#     completely their content landed. The guard then reported "N commit(s) not in its upstream"
#     about work that was fully merged. Measured: a slot torn down right after
#     `merge --squash --delete-branch`, worktree clean, content identical to the base branch,
#     refused with N=3.
#   * SILENT PASS on the dangerous one. A branch with NO upstream configured makes
#     `@{upstream}` a fatal error; stderr was discarded and `wc -l` counted the empty stdout as
#     ZERO, so a slot whose commits existed nowhere else cleared the gate.
#
# WHAT IS ACTUALLY AT STAKE, measured, because the honest version changes which refusal an
# operator should take seriously. `git worktree remove` does NOT delete the branch: a slot torn
# down with committed, never-pushed work leaves that branch — and `git show <branch>:<file>` —
# intact in the repository. So gate 2 does not protect commits from deletion; it protects a
# change's history from being ORPHANED in a branch nobody will look at again, together with
# whatever IGNORED files the directory carried (untracked ones are gate 1's business — git
# status lists them, so they read as dirty and never reach gate 2). The gate that stands
# between the operator and genuinely unrecoverable content is gate 1, the dirty check — which
# is why a `dirty` refusal deserves MORE weight than an `unmerged` one, not less.
#
# CONTAINMENT IS PROVEN, NEVER ASSUMED. Independent proofs, in order; the first that succeeds wins:
#
#   1. TREE EQUALITY — the worktree's committed tree is byte-identical to the base branch's.
#      Exact, instant, and works on any git.
#   2. MERGE EMPTINESS — merging this branch into the base branch would produce the base
#      branch's own tree, i.e. the branch contributes nothing that is not already there.
#      This is the one that survives the base branch moving ahead, which it always does in a
#      fleet: sibling slots land while this one waits to be torn down, so tree equality stops
#      holding within minutes of the merge even though nothing is missing.
#      Needs `git merge-tree --write-tree` (git >= 2.38); on an older git proof 1 is the whole
#      gate — more refusals, never a wrong allow, but `unmerged` then becomes UNREACHABLE, so
#      those refusals get their own word (`no-proof-tool`) rather than borrowing one that
#      would understate them.
#
#   3. THE MERGED PR/MR'S HEAD (#356) — the worktree's HEAD is the head commit of a PR/MR that
#      the forge reports MERGED, from this branch, from this repository rather than a fork, and
#      into the very base branch proofs 1 and 2 measure against. Tried only when they did not
#      prove containment. It answers the case they cannot: a squash merge after which the base
#      branch edited the same region, so the test merge conflicts (`unprovable`), or removed
#      something the branch added (`unmerged`). Either way the content WAS merged, and what this
#      gate protects against — history orphaned in a branch nobody will look at again — cannot
#      happen: that history is in the base branch's own merge. The TARGET check is the load-
#      bearing half; without it a branch merged into a side branch would pass with its content
#      nowhere in the base branch.
#      It asks the network, so SHIPYARD_DOWN_FETCH=0 forbids it, a local-path remote (no forge)
#      skips it, and every failure — no CLI, no auth, a timeout, a URL the CLI cannot resolve —
#      is NO PROOF, never a pass: the refusal is then exactly what it was without it.
#
# Proof 1 is subsumed by proof 2 whenever merge-tree is available. It is kept because it costs
# one command, answers the commonest case without invoking a merge, and is the whole gate on a
# git too old for the second.
#
# FAILING TO PROVE IS NOT THE SAME AS FINDING UNMERGED WORK, and the two get different words.
# `unmerged` means the test merge SUCCEEDED and still added content to the base branch — the
# branch really does carry something that is not there. `unprovable` means the question could
# not be answered: the test merge conflicted (the base branch has since edited the same region
# this branch touched), or this git is too old for it. The first says do not discard; the
# second says look, then `--force` with a clear conscience. Collapsing them into one message
# was the shape the old guard had, and it is what trains an operator to stop reading.
#
# NOT EVERY FAILURE IS AN ANSWER. `git status` can exit non-zero with empty stdout (an
# unreadable or corrupt index — measured with a chmod-000 index, the state a containerised or
# sudo build inside a worktree leaves behind), and an empty answer read as "not dirty" is
# exactly the SILENT PASS shape above, reproduced in the arm that guards real data loss. So a
# question git could not answer returns `unknown` and refuses. The same applies to a path that
# is not a worktree at all: git discovery would walk UP out of a stray `.claude/worktrees/ship-*`
# directory and cheerfully report the MAIN checkout's state as this slot's.
#
# THIS MODULE WRITES TWICE, both deliberately, neither reversible-by-accident: a single lazy
# `git fetch` of the base branch (shipyard_down_refresh), and the merged tree that
# `merge-tree --write-tree` persists — unreferenced, reclaimed by gc, and required because the
# proof compares the OID it prints against the base branch's tree. Set SHIPYARD_DOWN_FETCH=0 to
# forbid the fetch — and with it proof 3's forge lookup, the module's one other network call;
# there is no way to ask for the merge proof without the object, and no need.

# OUTPUTS of shipyard_down_verdict, set in the CALLER's shell. They are outputs, not knobs:
# nothing reads them as input, and every caller overwrites both.
SHIPYARD_DOWN_KIND=''
SHIPYARD_DOWN_REF=''
# Set only when a `safe` verdict came from proof 3 (below): the merged PR/MR's number, so the
# caller can say which proof it was. Empty for every other outcome, proofs 1 and 2 included.
SHIPYARD_DOWN_MERGED=''

# The base-branch ref every proof below measures against comes from shipyard_default_ref(), in
# shipyard-lib.sh (sourced by shipyard-down.sh before this file). It lived here until the status
# report grew the same question (#143); its tiers, and the option-shape screen that keeps a
# remote-controlled ref name from reaching `git fetch` or `git diff` below, are documented there.

# Can this git run proof 2 at all? `merge-tree --write-tree` arrived in git 2.38, and an older
# one fails the whole option rather than the merge. Probed against the worktree so the answer
# is about THIS repository's git, not about whatever directory the caller happened to be in.
_shipyard_down_have_merge_tree() {
  git -C "$1" merge-tree --write-tree HEAD HEAD >/dev/null 2>&1
}

# rc 0 the content is PROVEN to be in <ref> already
# rc 1 the test merge succeeded and still adds content — genuinely not in <ref>
# rc 2 the merge proof ran and could not settle it (a conflicting test merge)
# rc 3 the merge proof could not run at all (git older than 2.38, or an unusable ref)
# Nothing returns 0 by falling through: an unanswerable question can never read as a clean
# bill of health. 2 and 3 are split because they deserve opposite advice — see the verdict
# words below.
shipyard_down_contained() {
  local wt="$1" ref="$2" tree out
  git -C "$wt" diff --quiet "$ref" HEAD 2>/dev/null && return 0
  tree=$(git -C "$wt" rev-parse --verify --quiet "$ref^{tree}" 2>/dev/null) || return 3
  _shipyard_down_have_merge_tree "$wt" || return 3
  out=$(git -C "$wt" merge-tree --write-tree "$ref" HEAD 2>/dev/null) || return 2
  [ "$(printf '%s\n' "$out" | head -1)" = "$tree" ] && return 0
  return 1
}

# Refresh the base branch once per invocation, and only when a proof has already failed.
# Teardown follows a merge by seconds, so the commonest reason a proof fails is that this
# clone has simply not seen the merge yet — asking the operator to `--force` past a stale ref
# is the cry-wolf this module exists to remove. rc 0 only when a fetch actually happened, so
# the caller retries exactly once and never loops.
#
# The latch only works because shipyard_down_verdict is called WITHOUT a command substitution
# (that is why the verdict is returned in globals): a `$( )` call would set this in a subshell
# and discard it, turning "once per invocation" into once per slot — measured at three fetches
# for three slots, against a promise of one.
#
# The refspec is fully qualified and follows `--` so that no part of it can be read as an
# option (see _shipyard_ref_ok in shipyard-lib.sh), and GIT_TERMINAL_PROMPT=0 keeps a teardown from blocking
# forever on a credential prompt nobody is watching.
# _shipyard_down_remote_of <worktree> <ref> — "<remote><TAB><branch>" for a remote-tracking ref,
# split on a remote git actually has rather than on the first slash: a remote name may itself
# contain one (`git remote add team/fork <url>` is accepted), and splitting by shape then talks to a
# remote called `team`. And the LONGEST matching name wins, because names do nest: git accepts both
# `team` and `team/fork`, and `git remote` lists `team` first, so a first match would split
# `team/fork/main` into remote `team` and branch `fork/main`. Two consumers, the lazy fetch and
# proof 3; rc 1 when no remote of this repository owns the ref.
_shipyard_down_remote_of() {
  local r best=''
  for r in $(git -C "$1" remote 2>/dev/null); do
    case "$2" in "$r/"?*) [ "${#r}" -gt "${#best}" ] && best=$r ;; esac
  done
  [ -n "$best" ] || return 1
  printf '%s\t%s' "$best" "${2#"$best/"}"
}

_SHIPYARD_DOWN_FETCHED=''
shipyard_down_refresh() {
  local wt="$1" ref="$2" rb remote='' branch=''
  [ "${SHIPYARD_DOWN_FETCH:-1}" = 1 ] || return 1
  case " $_SHIPYARD_DOWN_FETCHED " in *" $ref "*) return 1 ;; esac
  _SHIPYARD_DOWN_FETCHED="$_SHIPYARD_DOWN_FETCHED $ref"
  rb=$(_shipyard_down_remote_of "$wt" "$ref") || return 1
  remote=${rb%%"	"*}; branch=${rb#*"	"}
  [ -n "$remote" ] && [ -n "$branch" ] || return 1
  GIT_TERMINAL_PROMPT=0 git -C "$wt" fetch --quiet "$remote" -- \
    "+refs/heads/$branch:refs/remotes/$ref" >/dev/null 2>&1 || return 1
  return 0
}

# shipyard_down_merged_head <worktree> <ref> — proof 3. rc 0 and the PR/MR number on stdout when
# the worktree's HEAD is the head of a merged PR/MR from its branch into <ref>'s branch; rc 1 for
# no proof, whatever the reason. The worktree is already known clean: the verdict asks gate 1
# first, and this is never reached past a dirty tree.
#
# THE REPOSITORY IS NAMED, never left to the CLI's discovery. Run bare in the worktree, `gh` picks
# among the remotes by its own rules (a `set-default`, then remote names), and a fork chosen there
# could answer with a PR merged into the FORK's base branch at the same head — a pass for content
# that is not in <ref>. So the remote is the one <ref> belongs to (_shipyard_down_remote_of), and
# its URL is handed over explicitly. `glab` takes the URL whole (`glab mr list --help`: "Also
# accepts full URL or Git URL"). `gh` takes HOST/OWNER/REPO when the URL's host is a real hostname
# (it has a dot), so neither GH_HOST nor gh's github.com default can send the query to another
# host; and OWNER/REPO alone when the host is an SSH alias (no dot), which gh cannot resolve —
# that one falls to gh's default host, the same one it would use for the alias's own pushes only
# if the alias points there, so an alias for an Enterprise host gets no proof unless GH_HOST says so.
#
# The candidate query mirrors slot_iid_forge in shipyard-report.sh (fork filter, same field
# names), restricted to merged ones. Bounded by forge_bounded, ten candidates.
shipyard_down_merged_head() {
  local wt="$1" ref="$2" rb remote='' base='' url rest host path br head out
  [ "${SHIPYARD_DOWN_FETCH:-1}" = 1 ] || return 1
  rb=$(_shipyard_down_remote_of "$wt" "$ref") || return 1
  remote=${rb%%"	"*}; base=${rb#*"	"}
  [ -n "$remote" ] && [ -n "$base" ] || return 1
  url=$(git -C "$wt" remote get-url "$remote" 2>/dev/null) || return 1
  # A local path or file:// remote has no forge to ask, and asking one anyway would send a CLI
  # off to guess. The same shape screen as _shipyard_ref_ok keeps an option-shaped URL out of
  # the CLI's argument list.
  case "$url" in ''|-*|/*|./*|../*|~*|file://*) return 1 ;; esac
  br=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null) || return 1
  case "$br" in ''|-*) return 1 ;; esac
  head=$(git -C "$wt" rev-parse --verify --quiet HEAD 2>/dev/null) || return 1
  case "$(shipyard_forge "$url")" in
    github)
      # scheme://[user@]host[:port]/path, or scp-like [user@]host:path.
      rest=${url#*://}
      if [ "$rest" != "$url" ]; then host=${rest%%/*}; path=${rest#*/}
      else host=${url%%:*}; path=${url#*:}; fi
      host=${host##*@}; host=${host%%:*}
      path=${path%/}; path=${path%.git}
      case "$path" in */*) ;; *) return 1 ;; esac
      case "$host" in *.*) path="$host/$path" ;; esac
      out=$( (unset GITHUB_TOKEN
              forge_bounded gh pr list -R "$path" --head "$br" --state merged --limit 10 \
                --json number,headRefOid,baseRefName,isCrossRepository \
                --jq '.[] | select(.isCrossRepository | not)
                          | "\(.headRefOid) \(.baseRefName) \(.number)"') 2>/dev/null) ;;
    *)
      out=$( (OAUTH_TOKEN= forge_bounded glab mr list -R "$url" --source-branch "$br" --merged \
                -P 10 -F json \
              | jq -r '.[] | select(.source_project_id == .target_project_id)
                           | "\(.sha) \(.target_branch) \(.iid)"') 2>/dev/null) ;;
  esac
  # Field-exact on the head AND the target: a prefix match on either would let a near miss pass.
  # Through ENVIRON, not `awk -v`, which processes escapes in a branch name (see the report's
  # $MERGEDFILE lookup for the measured case).
  out=$(printf '%s\n' "$out" | H="$head" B="$base" awk \
          '$1""==ENVIRON["H"]"" && $2""==ENVIRON["B"]"" && $3 ~ /^[0-9]+$/ { print $3; exit }')
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# shipyard_down_verdict <worktree> — the whole gate. Sets SHIPYARD_DOWN_KIND and
# SHIPYARD_DOWN_REF in the caller's shell and returns 0 ONLY for `safe`:
#
#   safe          <ref>  content already in the base branch; removing the worktree loses nothing.
#                        SHIPYARD_DOWN_MERGED names the PR/MR when proof 3 is what showed it
#   dirty                uncommitted or untracked changes — refused exactly as before
#   unmerged      <ref>  the branch genuinely carries content the base branch does not have
#   unprovable    <ref>  the test merge conflicted: the base branch has since edited the same
#                        region, so containment is undecidable here. Not a claim of loss.
#   no-proof-tool <ref>  this git predates `merge-tree --write-tree`, so proof 2 never ran and
#                        `unmerged` is UNREACHABLE. Kept separate from `unprovable` because on
#                        such a git EVERY slot that is not byte-identical lands here, including
#                        one holding the only copy of committed work — so the message must not
#                        be the reassuring one. Measured: folding the two told an operator on
#                        git 2.34 to `--force` past exactly the case the gate exists to catch.
#   no-default           no base branch could be discovered to compare against
#   unknown              not a worktree, or git could not answer — the question was never asked
#
# It returns its answer in globals rather than on stdout so that callers do not have to spawn a
# subshell to read it; see shipyard_down_refresh for what that buys.
shipyard_down_verdict() {
  local wt="$1" ref st
  SHIPYARD_DOWN_KIND=unknown
  SHIPYARD_DOWN_REF=''
  SHIPYARD_DOWN_MERGED=''
  # Not a worktree (nor a repository root): git would discover its way UP to the parent repo
  # and answer about that instead, which is a confident answer to a question about the wrong
  # tree. Measured on a stray directory under .claude/worktrees/.
  [ -e "$wt/.git" ] || return 1
  st=$(git -C "$wt" status --porcelain 2>/dev/null) || return 1
  if [ -n "$st" ]; then SHIPYARD_DOWN_KIND=dirty; return 1; fi
  ref=$(shipyard_default_ref "$wt") || { SHIPYARD_DOWN_KIND=no-default; return 1; }
  SHIPYARD_DOWN_REF="$ref"
  shipyard_down_contained "$wt" "$ref"
  case $? in
    0) SHIPYARD_DOWN_KIND=safe; return 0 ;;
    1) SHIPYARD_DOWN_KIND=unmerged ;;
    2) SHIPYARD_DOWN_KIND=unprovable ;;
    *) SHIPYARD_DOWN_KIND=no-proof-tool ;;
  esac
  # A stale remote-tracking ref looks exactly like both of those, so spend the one fetch and
  # ask again before refusing.
  if shipyard_down_refresh "$wt" "$ref"; then
    shipyard_down_contained "$wt" "$ref"
    case $? in
      0) SHIPYARD_DOWN_KIND=safe; return 0 ;;
      1) SHIPYARD_DOWN_KIND=unmerged ;;
      2) SHIPYARD_DOWN_KIND=unprovable ;;
      *) SHIPYARD_DOWN_KIND=no-proof-tool ;;
    esac
  fi
  # Proof 3, last because it is the only one that costs a forge call. It runs after the fetch so
  # a stale ref gets its cheap retry first.
  local n
  if n=$(shipyard_down_merged_head "$wt" "$ref"); then
    SHIPYARD_DOWN_KIND=safe; SHIPYARD_DOWN_MERGED=$n; return 0
  fi
  return 1
}
