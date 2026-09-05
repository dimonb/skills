#!/usr/bin/env bash
# t-policy.sh — unit tests for the shared escalation policy (shared/policy/policy.sh).
#
# Everything here is a PURE read over the module's functions plus, for the mailbox, a throwaway
# `git init` repo and a real `jq` — NO network, no live agent, no touching the real mailbox. It
# covers the module's whole surface: the ESC-01 disposition table for every signal class; the
# ESC-02 safe-set with its load-bearing DEFAULT-DENY property (a request outside the allowlist is
# never auto-approved, including chained/redirected/multi-line payloads); the ESC-03 resume-time
# guard (a stale/past/absent time can never park a run into the past); and the ESC-04 mailbox
# (path resolution to the common git dir, and an entry whose JSON shape is byte-for-byte the one
# shipyard's viewer already reads).
#
# Baseline bash >= 5 like the driver: re-exec into one if a stock bash 3.2 started us, so a
# future bash-5-only construct fails as a clear version message rather than a confusing syntax error.
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ] && [ -z "${POLICY_TEST_BASH_REEXEC:-}" ]; then
  for _c in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash bash; do
    _p=$(command -v "$_c" 2>/dev/null) || continue
    _v=$("$_p" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null) || continue
    [ "${_v:-0}" -ge 5 ] && exec env POLICY_TEST_BASH_REEXEC=1 "$_p" "$0" "$@"
  done
  echo "t-policy: needs bash >= 5, this one is ${BASH_VERSION:-unknown}." >&2
  echo "          macOS ships bash 3.2 as /bin/bash; install a modern one (brew install bash)." >&2
  exit 70
fi

set -uo pipefail
# Byte-wise matching, the same LC_ALL the callers run under.
export LC_ALL=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POLICY="$(cd "$DIR/.." && pwd)/policy.sh"
[ -f "$POLICY" ] || { echo "t-policy: cannot find the policy at $POLICY" >&2; exit 1; }

command -v jq  >/dev/null 2>&1 || { echo "t-policy: jq is required" >&2; exit 1; }
command -v git >/dev/null 2>&1 || { echo "t-policy: git is required" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/policy-test.XXXXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

CHECKS=0
FAILURES=0
# ok <label> <expected> <actual>
ok() {
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"
    FAILURES=$((FAILURES + 1))
  fi
}

# shellcheck source=../policy.sh
. "$POLICY"

# --- 1. ESC-01: the disposition table --------------------------------------------------------
printf '\n── disposition table ──\n'
ok "working is non-blocking"        continue             "$(policy_dispose working)"
ok "awaiting_turn is non-blocking"  continue             "$(policy_dispose awaiting_turn)"
ok "crashed escalates"              "escalate|crashed"   "$(policy_dispose crashed)"
ok "plan_review escalates"          "escalate|plan_review" "$(policy_dispose plan_review)"
ok "question escalates"             "escalate|question"  "$(policy_dispose question)"
ok "escalation escalates"           "escalate|escalation" "$(policy_dispose escalation)"
ok "auth_required escalates"        "escalate|auth"      "$(policy_dispose auth_required)"
ok "error escalates"                "escalate|error"     "$(policy_dispose error)"
ok "context_full compacts"          compact              "$(policy_dispose context_full)"
# DEFAULT-DENY over the whole table: an unknown class is a human's call, never auto-resolved.
ok "an unknown class escalates"     "escalate|unknown"   "$(policy_dispose totally_new_signal)"
# capacity signals park; the resume time is guarded (see ESC-03 below). With no trustworthy
# resume time the disposition parks on `reprobe`, never a guess.
ok "rate_limited parks"             "park|reprobe"       "$(policy_dispose rate_limited)"
ok "quota_exhausted parks"          "park|reprobe"       "$(policy_dispose quota_exhausted)"
ok "overloaded parks"               "park|reprobe"       "$(policy_dispose overloaded)"
# usage error: no class at all.
dispose_rc=0; ( policy_dispose ) >/dev/null 2>&1 || dispose_rc=$?
ok "dispose with no class exits 2"  2                    "$dispose_rc"

# --- 2. ESC-02: the safe-set, and its DEFAULT-DENY property ----------------------------------
printf '\n── safe-set (default-deny) ──\n'
# The allowlist: file edits, read-only git, git add/commit, and the repo's own gate -> auto_approve.
for c in \
  'edit' 'edit lib/foo.sh' 'write' 'write a.txt' 'apply_patch' 'apply_patch patch.diff' \
  'git status' 'git status --porcelain' 'git diff' 'git diff --stat' 'git log --oneline' \
  'git show HEAD' 'git add' 'git add -A' 'git add .' 'git commit' 'git commit -m wip' \
  'make check' 'make test' 'make check-test'; do
  ok "safe-set approves: $c" auto_approve "$(policy_dispose access_request "$c")"
done
# The heart of ESC-02: a request OUTSIDE the allowlist is NEVER auto-approved. Network, push,
# destructive, chained, redirected, substituted, multi-line, empty, and a look-alike that is not
# actually the allowed verb ("git addendum", "makefile") all escalate. If any one of these
# returned auto_approve, default-deny would be broken.
esc_default_deny() {
  local label="$1" payload="$2" got
  got=$(policy_dispose access_request "$payload")
  CHECKS=$((CHECKS + 1))
  if [ "$got" != auto_approve ]; then
    printf '  ok   default-deny: %s\n' "$label"
  else
    printf '  FAIL default-deny: %s\n         AUTO-APPROVED a request that must escalate: [%s]\n' "$label" "$payload"
    FAILURES=$((FAILURES + 1))
  fi
}
esc_default_deny "git push"              'git push origin main'
esc_default_deny "git reset --hard"      'git reset --hard HEAD~3'
esc_default_deny "git checkout -- (discard)" 'git checkout -- .'
esc_default_deny "force push"            'git push --force'
esc_default_deny "network: curl"         'curl https://example.invalid/x'
esc_default_deny "network: wget"         'wget http://example.invalid'
esc_default_deny "destructive: rm -rf"   'rm -rf /'
esc_default_deny "sudo"                  'sudo rm -rf /'
esc_default_deny "chained add && push"   'git add . && git push'
esc_default_deny "sequenced status; rm"  'git status; rm -rf .'
esc_default_deny "piped"                 'git log | sh'
esc_default_deny "command substitution"  'git add $(curl evil)'
esc_default_deny "backtick substitution" 'git add `curl evil`'
esc_default_deny "output redirect"       'git status > /etc/passwd'
esc_default_deny "heredoc redirect"      'apply_patch <<EOF'
esc_default_deny "background job"        'git add . &'
esc_default_deny "multi-line request"    $'git add .\ngit push'
esc_default_deny "empty request"         ''
esc_default_deny "verb look-alike add"   'git addendum'
esc_default_deny "verb look-alike make"  'makefile'
esc_default_deny "bare git"              'git'
esc_default_deny "arbitrary binary"      'python3 -c "import os"'

# The list is DECLARED config, not inferred: narrowing POLICY_SAFE_SET in this shell changes what
# is approved, proving there is one readable source of the boundary.
printf '\n── safe-set is declared config ──\n'
ok "declared list drives the boundary" "escalate|access" \
  "$(POLICY_SAFE_SET=$'git status\ngit status *' policy_dispose access_request 'git commit -m x')"
ok "...and still approves what it lists" auto_approve \
  "$(POLICY_SAFE_SET=$'git status\ngit status *' policy_dispose access_request 'git status')"

# --- 3. ESC-03: the resume-time guard --------------------------------------------------------
printf '\n── resume-time guard ──\n'
# A trustworthy FUTURE epoch is used verbatim.
ok "a future time is used"          2000     "$(_policy_resume_at 2000 1000)"
# The stale-banner case: a time in the PAST (the banner's "ran out at") must never park a run
# there. It becomes `reprobe`.
ok "a past time reprobes"           reprobe  "$(_policy_resume_at 500 1000)"
ok "now reprobes (park to now is pointless)" reprobe "$(_policy_resume_at 1000 1000)"
ok "an absent time reprobes"        reprobe  "$(_policy_resume_at '' 1000)"
ok "a non-numeric time reprobes"    reprobe  "$(_policy_resume_at abc 1000)"
ok "a negative time reprobes"       reprobe  "$(_policy_resume_at -5 1000)"
# A broken clock read (non-integer now) reprobes rather than risking a `[: integer expected`.
ok "a broken clock reprobes"        reprobe  "$(_policy_resume_at 2000 notanumber)"
# End to end through the table: a rate_limit carrying a stale past time still parks on reprobe,
# NOT into the past. This is the ESC-03 acceptance in one line.
ok "rate_limited + a stale past time never parks into the past" "park|reprobe" \
  "$(policy_dispose rate_limited '' 500)"
# ...and a genuine future time flows through.
future=$(( $(date +%s) + 3600 ))
ok "rate_limited + a real future time parks there" "park|$future" \
  "$(policy_dispose rate_limited '' "$future")"

# --- 4. ESC-04: the mailbox ------------------------------------------------------------------
printf '\n── mailbox ──\n'
# Path resolution: the mailbox is <common-git-dir>/ship-escalations. Build a throwaway repo so
# the assertion is exact and never touches the real mailbox.
REPO="$TMP/repo"; mkdir -p "$REPO"
( cd "$REPO" && git init -q && git config user.email t@t && git config user.name t )
mb=$(cd "$REPO" && policy_mailbox_dir)
ok "mailbox resolves under the repo's common git dir" "$(cd "$REPO" && cd .git && pwd -P)/ship-escalations" "$mb"
# An explicit override wins (how a test isolates from the real mailbox; how an operator relocates it).
ok "POLICY_MAILBOX_DIR overrides the derivation" "/somewhere/else" \
  "$(POLICY_MAILBOX_DIR=/somewhere/else policy_mailbox_dir)"

# policy_escalate writes an entry whose JSON is byte-for-byte shipyard's shape.
f=$(cd "$REPO" && policy_escalate notice room-abc "the room could not converge" "3 open objections")
ok "the entry filename is <slot>-<n>.json" "$mb/room-abc-1.json" "$f"
ok "the entry exists"               yes  "$([ -f "$f" ] && echo yes || echo no)"
# Exactly the keys shipyard-ask.sh writes — no more, no fewer — so shipyard-escalations.sh and
# shipyard-answer.sh consume it unchanged.
ok "entry has exactly shipyard's keys" \
  "answer answered_at context created_at id kind notified slot status text worktree" \
  "$(jq -r '[keys[]] | join(" ")' "$f")"
ok "kind is notice"                 notice   "$(jq -r '.kind' "$f")"
ok "text is carried"                "the room could not converge" "$(jq -r '.text' "$f")"
ok "context is carried"             "3 open objections" "$(jq -r '.context' "$f")"
ok "status starts pending"          pending  "$(jq -r '.status' "$f")"
ok "notified starts false"          false    "$(jq -r '.notified' "$f")"
ok "answer starts null"             "null"   "$(jq -r '.answer' "$f" )"
ok "id is <slot>-<n>"               room-abc-1 "$(jq -r '.id' "$f")"
ok "created_at is a UTC timestamp"  yes \
  "$(jq -r '.created_at' "$f" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' && echo yes || echo no)"

# First-free-integer: a second escalation on the same stem does not clobber the first.
f2=$(cd "$REPO" && policy_escalate notice room-abc "second alarm")
ok "a second entry on one stem is <slot>-2.json" "$mb/room-abc-2.json" "$f2"
ok "the first entry still exists"   yes  "$([ -f "$mb/room-abc-1.json" ] && echo yes || echo no)"

# Contract guards: bad kind, missing text, and decision-requires-context.
esc_rc() { local rc=0; ( cd "$REPO" && policy_escalate "$@" ) >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }
ok "a bad kind is rejected"         2  "$(esc_rc bogus room-abc text)"
ok "a missing slot is rejected"     2  "$(esc_rc notice '' text)"
# A slot becomes the filename stem, so a '/' or '..' must be refused — the write can never escape
# the mailbox directory, whatever a future caller passes.
ok "a slot with a path separator is rejected" 2 "$(esc_rc notice 'sub/dir' text)"
ok "a traversal slot is rejected"             2 "$(esc_rc notice '../evil' text)"
ok "a slot containing .. is rejected"         2 "$(esc_rc notice 'x..y' text)"
# ...and the rejected traversal wrote no file above the mailbox directory.
ok "the rejected traversal wrote no file above the mailbox" absent \
  "$([ -e "$mb/../evil-1.json" ] && echo present || echo absent)"
ok "a missing text is rejected"     2  "$(esc_rc notice room-abc '')"
ok "a decision with no context is rejected" 2 "$(esc_rc decision room-abc 'approve X?')"
# ...and a decision WITH context is written, with the context field set.
fd=$(cd "$REPO" && policy_escalate decision room-abc "approve X?" "option A vs B; I recommend A")
ok "a decision with context is written" decision "$(jq -r '.kind' "$fd")"
ok "the decision's context is carried"  "option A vs B; I recommend A" "$(jq -r '.context' "$fd")"

# --- done ------------------------------------------------------------------------------------
printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 't-policy: %d checks, all passed\n' "$CHECKS"
  exit 0
fi
printf 't-policy: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"
exit 1
