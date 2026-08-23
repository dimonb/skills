#!/usr/bin/env bash
# shipyard-lib.sh — shared helpers for the `shipyard` skill. Source only, never execute.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# The terminal a child lives in — agterm (default) or tmux — sits behind the shipyard_*
# functions in shipyard-backend.sh. Nothing else in this skill calls agtermctl or tmux.
# shellcheck source=shipyard-backend.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/shipyard-backend.sh"

# Escalation mailbox. Lives in the SHARED .git (git-common-dir), so the very same
# path resolves from the main worktree (parent watcher) and from
# .claude/worktrees/ship-<slot> (child session). Never committed by construction.
shipyard_mailbox() {
  local gcd
  gcd=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$gcd" in /*) ;; *) gcd="$(pwd -P)/$gcd" ;; esac
  gcd=$(cd "$gcd" 2>/dev/null && pwd -P) || return 1
  printf '%s/ship-escalations' "$gcd"
}

shipyard_mailbox_ensure() {
  local mb; mb=$(shipyard_mailbox) || return 1
  mkdir -p "$mb" || return 1
  printf '%s' "$mb"
}

# Slot of the current session: $SHIPYARD_SLOT, else derived from the worktree name.
shipyard_slot() {
  if [ -n "${SHIPYARD_SLOT:-}" ]; then printf '%s' "$SHIPYARD_SLOT"; return; fi
  local top b
  top=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  b=$(basename "$top")
  case "$b" in ship-*) printf '%s' "${b#ship-}" ;; *) printf '%s' "$b" ;; esac
}

shipyard_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# --- the child's Claude identity ------------------------------------------------
# A child is NOT spawned from the parent's shell: agterm spawns it from the app (GUI
# environment), and tmux spawns it from a server whose environment was frozen whenever
# that server happened to start. Either way the parent's environment does not reach it
# — so anything that decides WHICH Claude the child is must be re-asserted explicitly
# in the launcher, AFTER the login profile has run and possibly set its own value.
#
# CLAUDE_HOME / CLAUDE_CONFIG_DIR are exactly that: they select the config dir, hence
# the skills, settings and memory the child sees. A parent running under a non-default
# one (e.g. a per-project config dir) that lets the child fall back to the profile default
# gets a child with different skills — including, possibly, no `/ship` at all.
#
# Per-session variables go the other way: they must be SCRUBBED. Handing a child the
# parent's CLAUDE_CODE_MESSAGING_SOCKET/TOKEN points it at the parent's IPC channel.
SHIPYARD_ENV_PASS_DEFAULT="CLAUDE_HOME CLAUDE_CONFIG_DIR"
SHIPYARD_ENV_SCRUB_DEFAULT="CLAUDECODE CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_SESSION_ID \
CLAUDE_CODE_CHILD_SESSION CLAUDE_PID CLAUDE_CODE_MESSAGING_SOCKET \
CLAUDE_CODE_MESSAGING_TOKEN CLAUDE_EFFORT SHIPYARD_SLOT"

# Emit `export X=…` / `unset X` lines for the launcher. Only variables actually set in
# the parent are exported, so an unset CLAUDE_HOME stays unset rather than becoming "".
shipyard_env_preamble() {
  local v
  for v in ${SHIPYARD_ENV_PASS:-$SHIPYARD_ENV_PASS_DEFAULT}; do
    if [ -n "${!v+set}" ]; then printf 'export %s=%q\n' "$v" "${!v}"; fi
  done
  printf 'unset %s\n' "${SHIPYARD_ENV_SCRUB:-$SHIPYARD_ENV_SCRUB_DEFAULT}"
}

# One line naming what will be propagated, for the launch log and the mailbox record.
shipyard_env_summary() {
  local v out=""
  for v in ${SHIPYARD_ENV_PASS:-$SHIPYARD_ENV_PASS_DEFAULT}; do
    if [ -n "${!v+set}" ]; then out="$out $v=${!v}"; else out="$out $v=<unset>"; fi
  done
  printf '%s' "${out# }"
}

shipyard_esc_file() {
  local mb; mb=$(shipyard_mailbox) || return 1
  printf '%s/%s.json' "$mb" "$1"
}

# In-place jq update of a json file.
shipyard_json_set() {
  local f="$1"; shift
  local tmp="$f.tmp.$$"
  jq "$@" "$f" >"$tmp" 2>/dev/null && mv "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}

# --- payload input ------------------------------------------------------------
# Long technical payloads (answers, directives, escalation context) travel as a
# shell ARGUMENT, so the CALLER's shell expands them before this code ever runs.
# In a double-quoted argument `foo` is command substitution and $(x)/$VAR expand,
# so an identifier in backticks is silently replaced by the output of running it
# — usually empty. The record is then written, and looks fine, minus the words
# that mattered.
#
# This is not hypothetical and it is not only an operator error: it has eaten a
# term out of a child's escalation ("the two overlapped and  could not dedupe
# them") and out of a parent's decision ("#N IS THE TRAP.  inside a transaction
# is rejected"). Both read as merely clumsy rather than corrupted, which is what
# makes it expensive.
#
# `shipyard_payload` gives every caller an input channel that no shell touches:
#   shipyard_payload "@/path/to/file"   read the file verbatim
#   shipyard_payload "@-"               read stdin verbatim (heredoc, pipe)
#   shipyard_payload "literal text"     unchanged, for short single-line messages
shipyard_payload() {
  local v="$1"
  case "$v" in
    '@-')  cat ;;
    '@'?*) local p="${v#@}"
           [ -f "$p" ] || { echo "error: payload file not found: $p" >&2; return 1; }
           cat "$p" ;;
    *)     printf '%s' "$v" ;;
  esac
}

# Resolve the container ONCE, here at the end — shipyard-backend.sh cannot do it itself: it is
# sourced from the top of this file, before shipyard_mailbox (which the pin lookup needs) is
# defined. Every dispatch asks via `$(shipyard_container)`, i.e. from a subshell, so without
# this each one would re-read the pin file and, unpinned, re-query the agterm tree.
# A failure here is not fatal: it just leaves the cache empty and the lookup lazy.
_SHIPYARD_CONTAINER=$(shipyard_container 2>/dev/null) || _SHIPYARD_CONTAINER=""
