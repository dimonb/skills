#!/usr/bin/env bash
# t23-agy.sh — the agy child: what it is launched with, and every per-kind path that degrades for
# it on purpose (SKILL.md, "An `agy` child, and what it does without").
#
# Each degradation is pinned in the direction that keeps an operator informed: the launch refuses a
# repo where agy cannot find `ship`, the ctx column claims nothing, `tell` says why it cannot
# confirm, `compact` refuses before typing anything, and the stall classifier grants no banner
# exemption. The rendered argv itself is pinned in shared/adapters/tests/t-callers.sh.
#
# The rig is t5's and t18's: exported shell functions shadow `tmux`, `git` and the agent binary.
# No live terminal, no agent, no network.
set -uo pipefail
export LC_ALL=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$DIR/.." && pwd)"

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}
has() { grep -q -- "$2" <<<"$1" && printf yes || printf no; }
rc_of() { printf '%s' "$1" | sed -n 's/^rc=//p' | tail -1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/t23-agy.XXXXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
# agy's global skill directories live under HOME; an empty one keeps this machine's out of it.
mkdir -p "$TMP/home"

# --- 1. the launch ---------------------------------------------------------------------------
printf '\n── launch (dry run) ──\n'
dry_launch() { # <repo> -> output, then "rc=<n>"
  local rc=0 out
  out=$( cd "$1" || exit 1
         tmux() { echo 'no server running on /tmp/t23-fake' >&2; return 1; }
         agy() { :; }; export -f tmux agy
         unset CLAUDECODE CLAUDE_CODE_SESSION_ID CODEX_SESSION_ID CODEX_THREAD_ID \
           SHIPYARD_ENV_PASS SHIPYARD_ENV_SCRUB SHIPYARD_EFFORT
         HOME="$TMP/home" SHIPYARD_AGENT=agy SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t23ex \
           SHIPYARD_DRY=1 bash "$SKILL_DIR/shipyard-launch.sh" '#42' 2>&1 ) || rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
new_repo() { # <dir> [with-ship]
  git init -q "$1"
  if [ -n "${2:-}" ]; then
    mkdir -p "$1/.agents/skills/ship"; printf -- '---\nname: ship\n---\n' >"$1/.agents/skills/ship/SKILL.md"
  fi
  git -C "$1" -c user.email=shipyard-test -c user.name=shipyard-test add -A >/dev/null 2>&1
  git -C "$1" -c user.email=shipyard-test -c user.name=shipyard-test commit -q --allow-empty -m fixture
}

new_repo "$TMP/noship"
out=$(dry_launch "$TMP/noship")
ok "a repo where agy finds no ship skill refuses the launch" 1 "$(rc_of "$out")"
ok "...naming where agy looks"          yes "$(has "$out" '.agents/skills/')"
ok "...before any launcher is written"  no  "$([ -e "$TMP/noship/.git/ship-escalations/launch-42.sh" ] && echo yes || echo no)"

new_repo "$TMP/withship" 1
out=$(dry_launch "$TMP/withship")
L="$TMP/withship/.git/ship-escalations/launch-42.sh"
ok "with .agents/skills/ship the dry launch succeeds" 0 "$(rc_of "$out")"
ok "...as agy"                          yes "$(has "$out" 'dry-run: agent agy,')"
ok "...propagating nothing, and saying so" yes "$(has "$out" 'dry-run: env      none')"
ok "...leaving the effort to ship"      yes "$(has "$out" 'dry-run: effort   runtime default (ship decides)')"
ok "...and passing no --effort"         0 "$(grep -c -- '--effort' "$TMP/withship/.git/ship-escalations/launch-42.sh" 2>/dev/null)"
ok "...and the trust prompt named"      yes "$(has "$out" 'agy asks whether to trust .claude/worktrees/ship-42')"
ok "the launcher cds into the child's worktree" 1 \
   "$(grep -c "^cd '.*/.claude/worktrees/ship-42' || exit 1$" "$L" 2>/dev/null)"
ok "...and execs agy unattended"        1 "$(grep -c '^exec agy --dangerously-skip-permissions' "$L" 2>/dev/null)"
ok "...with /ship and the protocol text in one -i argument" 1 \
   "$(grep -c "^  -i '/ship #42\$" "$L" 2>/dev/null)"
ok "...reading the protocol file at launch" 1 \
   "$(grep -c '"$(cat .*/protocol-42.md'"'"')"$' "$L" 2>/dev/null)"
ok "the scrub list covers agy's per-session variables" 4 \
   "$(grep -cE '^unset ANTIGRAVITY_(CONVERSATION_ID|TRAJECTORY_ID|CSRF_TOKEN|LS_ADDRESS)$' "$L" 2>/dev/null)"
ok "the protocol names agy's skill syntax" yes "$(has "$(cat "$TMP/withship/.git/ship-escalations/protocol-42.md")" 'Your one job is `/ship`')"

# The worktree is shipyard's to create for agy, as for codex.
(
  cd "$TMP/withship" || exit 1
  . "$SKILL_DIR/shipyard-lib.sh"
  shipyard_agent_prepare_worktree agy "$TMP/withship" "$TMP/withship/.claude/worktrees/ship-42"
) >/dev/null 2>&1
ok "an agy child's worktree is created before launch" yes \
   "$([ -e "$TMP/withship/.claude/worktrees/ship-42/.git" ] && echo yes || echo no)"

# --- 2. ctx, tell and compact against a slot launched as agy ----------------------------------
FAKE_ROOT="$TMP/repo"; FAKE_GIT="$TMP/gitdir"; MB="$FAKE_GIT/ship-escalations"; KEYS="$TMP/keys"
mkdir -p "$FAKE_ROOT" "$MB"
: > "$MB/container-tmux"
printf '{"agent":"agy"}\n' > "$MB/launch-41.json"
printf '{"agent":"claude"}\n' > "$MB/launch-42.json"
export FAKE_ROOT FAKE_GIT KEYS
git() {
  case "${1:-} ${2:-}" in
    "rev-parse --show-toplevel")  printf '%s\n' "$FAKE_ROOT"; return 0 ;;
    "rev-parse --git-common-dir") printf '%s\n' "$FAKE_GIT";  return 0 ;;
    "remote get-url")             printf 'https://github.com/example/example.git\n'; return 0 ;;
  esac
  return 0
}
# The pane is agy's own idle screen, footer included; it never changes, as agy's never reads
# running to the shared turn read.
tmux() {
  case "${1:-}" in
    list-windows) case "$*" in *window_index*) printf '1 ship-41\n2 ship-42\n' ;; *) printf 'ship-41\nship-42\n' ;; esac; return 0 ;;
    has-session)  return 0 ;;
    send-keys)    shift; printf '%s\n' "$*" >> "$KEYS"; return 0 ;;
    capture-pane) printf '> \n? for shortcuts        example-model · high\n'; return 0 ;;
  esac
  return 0
}
export -f git tmux

printf '\n── ctx ──\n'
AGY_PANE=$(cat "$DIR/../../../../../shared/adapters/tests/fixtures/pane-agy-idle.txt" 2>/dev/null)
ok "the agy idle capture carries a per-turn token line" yes "$(has "$AGY_PANE" 'Thought for 3s, 552 tokens')"
ok "an agy slot's ctx column claims nothing" "- —" \
   "$( ROOT="$FAKE_ROOT"; . "$SKILL_DIR/shipyard-lib.sh"; . "$SKILL_DIR/shipyard-ctx.sh"; ctx_probe 41 "$AGY_PANE" )"
ok "...while the same pane on a claude slot would be scraped" "552" \
   "$( ROOT="$FAKE_ROOT"; . "$SKILL_DIR/shipyard-ctx.sh"; ctx_pane_tokens "$AGY_PANE" )"

printf '\n── tell ──\n'
run_tell() { # <slot> <text> -> output, then "rc=<n>"
  local out rc=0
  : > "$KEYS"
  out=$( env SHIPYARD_TELL_SETTLE_DELAY=0.01 SHIPYARD_TELL_CONFIRM_SECS=1 \
             SHIPYARD_TELL_CONFIRM_INTERVAL=0.2 SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t23ex \
         bash "$SKILL_DIR/shipyard-tell.sh" "$1" "$2" 2>&1 ) || rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
out=$(run_tell 41 "first directive to the agy slot")
ok "a send to an agy child ends unconfirmed (exit 6)" 6 "$(rc_of "$out")"
ok "...saying the kind is why"          yes "$(has "$out" 'ship-41 is an agy child, whose turn state shipyard cannot read')"
out=$(run_tell 42 "first directive to the claude slot")
ok "a claude slot on the same screen gets no agy line" no "$(has "$out" 'is an agy child')"

printf '\n── compact ──\n'
: > "$KEYS"
out=$( SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=t23ex bash "$SKILL_DIR/shipyard-compact.sh" 41 2>&1 ); rc=$?
ok "compacting an agy child is refused (exit 9)" 9 "$rc"
ok "...saying agy has no /compact"      yes "$(has "$out" 'agy has no /compact')"
ok "...having sent nothing"             0 "$(wc -l < "$KEYS" | tr -d ' ')"

# --- 3. the stall classifier grants agy no banner exemption -----------------------------------
printf '\n── wait classifier ──\n'
LIMIT='⚠ Usage limit reached · continuing automatically at 2am'
( FAILURES=0
  . "$SKILL_DIR/shipyard-lib.sh"
  ok "a banner on a claude screen parks it" wait \
     "$(shipyard_wait_state "$LIMIT" in-review apply claude | cut -f1)"
  ok "the same banner on an agy screen does not" 1 \
     "$(shipyard_wait_state "$LIMIT" in-review apply agy >/dev/null 2>&1; echo $?)"
  ok "a finished agy child is still finished" finished \
     "$(shipyard_wait_state '' concluded ready-to-merge agy | cut -f2)"
  ok "no kind reads as claude" wait \
     "$(shipyard_wait_state "$LIMIT" in-review apply | cut -f1)"
  exit "$FAILURES" ) || FAILURES=$((FAILURES + $?))
CHECKS=$((CHECKS + 4))

printf '\n'
if [ "$FAILURES" -eq 0 ]; then printf 't23-agy: %d checks, all passed\n' "$CHECKS"; exit 0; fi
printf 't23-agy: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"
exit 1
