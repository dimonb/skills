#!/usr/bin/env bash
# t32 — an ad hoc room's supervision writes land in the room; a supervised room's still reach the
# shared mailbox (#178).
#
# Every other test inherits POLICY_MAILBOX_DIR from _helpers.sh, which is exactly why none of them
# could see this defect: a room built by hand, OUTSIDE the suite, inherits nothing, and its
# `unresolved` close used to push "a human should look" into the real `.git/ship-escalations/` of
# whatever repo the caller stood in. So this file UNSETS the override and builds its own repo.
#
# The property has several parts, and B is the one a mistake here would break silently:
#   A  an ad hoc room (not directly under `<git dir>/council/`) writes into `<room>/mailbox/`, and
#      NOTHING reaches the repo's mailbox;
#   B  a supervised room (where `up` puts rooms) still pushes into the repo's mailbox, the same as
#      before, from any directory inside the repo. A real room must never stop escalating.
#   C  an explicit POLICY_MAILBOX_DIR still wins for an ad hoc room.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_helpers.sh
. "$DIR/_helpers.sh"
unset POLICY_MAILBOX_DIR

ROOT="$COUNCIL_TEST_ROOT/t32"; rm -rf "$ROOT"; mkdir -p "$ROOT" || exit 1
REPO="$ROOT/repo"; mkdir -p "$REPO/sub"
( cd "$REPO" && git init -q . ) || { echo "t32: git init failed" >&2; exit 1; }
GD=$(cd "$REPO/.git" && pwd -P)
REAL_MB="$GD/ship-escalations"

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}
present() { [ -e "$1" ] && printf yes || printf no; }
n_entries() { ls "$1"/council-*.json 2>/dev/null | wc -l | tr -d ' '; }

# An unconverged room, force-closed: the one close that pushes a notice.
close_unresolved() { # <room> <cwd>
  local r="$1" cwd="$2"
  mkroom "$r" a b
  ( cd "$cwd" && export COUNCIL_ROOM="$r" ROOM="$r"
    say_floor propose '[]' "Do the thing." >/dev/null
    COUNCIL_ME=b bash "$CLI" send --act object --hand --refs '["a-1"]' "Not yet." >/dev/null
    COUNCIL_ME=a bash "$CLI" decide --force >/dev/null 2>&1 )
}

# --- A. an ad hoc room, run from inside the repo ---------------------------------------------------
RA="$ROOT/scratch/probe"; mkdir -p "$ROOT/scratch"
close_unresolved "$RA" "$REPO/sub"
ok "A: the room recorded unresolved"                 unresolved "$(cat "$RA/board/status" 2>/dev/null)"
ok "A: the notice landed in the room"                yes "$(present "$RA/mailbox/council-probe-1.json")"
ok "A: nothing reached the repo's mailbox"           0   "$(n_entries "$REAL_MB")"
# The other writers resolve through the same mailbox, so they land beside it.
( cd "$REPO" && COUNCIL_ROOM="$RA" bash "$CLI" status --only-changed >/dev/null 2>&1 )
ok "A: status's signature landed in the room"        yes "$(present "$RA/mailbox/council-status-sig-probe")"
ok "A: ...and not in the repo's mailbox"             no  "$(present "$REAL_MB/council-status-sig-probe")"

# A directory named `council` is not enough: it has to be inside a git dir.
RA2="$ROOT/council/lookalike"; mkdir -p "$ROOT/council"
close_unresolved "$RA2" "$REPO"
ok "A: a council/ dir outside a git dir is ad hoc"   yes "$(present "$RA2/mailbox/council-lookalike-1.json")"
ok "A: ...and still nothing in the repo's mailbox"   0   "$(n_entries "$REAL_MB")"

# --- B. a supervised room, where `up` puts it ------------------------------------------------------
mkdir -p "$GD/council"
RB="$GD/council/real"
close_unresolved "$RB" "$REPO/sub"
ok "B: a supervised room still pushes to the repo"   yes "$(present "$REAL_MB/council-real-1.json")"
ok "B: ...and writes no mailbox of its own"          no  "$(present "$RB/mailbox")"
# Reached through a symlinked spelling, it is the same room and the same answer.
ln -s "$GD/council" "$ROOT/link"
RB2="$GD/council/real2"
close_unresolved "$RB2" "$REPO"
ok "B: set up a second supervised room"              yes "$(present "$REAL_MB/council-real2-1.json")"
( cd "$REPO" && COUNCIL_ROOM="$ROOT/link/real2" bash "$CLI" status --only-changed >/dev/null 2>&1 )
ok "B: a symlinked spelling is still supervised"     yes "$(present "$REAL_MB/council-status-sig-real2")"

# A bare common dir under safe.bareRepository=explicit, the bare-repo-with-worktrees layout: git
# refuses to DISCOVER it, so a check that asked git from inside it read a real room as ad hoc.
BARE="$ROOT/bare.git"; ( git init -q --bare "$BARE" ) || { echo "t32: git init --bare failed" >&2; exit 1; }
BGD=$(cd "$BARE" && pwd -P); mkdir -p "$BGD/council"
( export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=explicit
  close_unresolved "$BGD/council/bare" "$REPO" )
ok "B: a bare common dir under explicit is supervised" no "$(present "$BGD/council/bare/mailbox")"
ok "B: ...so its notice went to the resolved mailbox"  yes "$(present "$REAL_MB/council-bare-1.json")"
# An inherited GIT_DIR names some other repository; it must not decide what this room is.
OTHER="$ROOT/other"; mkdir -p "$OTHER"; ( cd "$OTHER" && git init -q . )
( export GIT_DIR="$OTHER/.git"; close_unresolved "$GD/council/inherited" "$REPO" )
ok "B: an inherited GIT_DIR does not make it ad hoc"   no "$(present "$GD/council/inherited/mailbox")"

# --- C. the explicit override wins ------------------------------------------------------------------
RC="$ROOT/scratch/explicit"; MC="$ROOT/explicit-mb"
( export POLICY_MAILBOX_DIR="$MC"; close_unresolved "$RC" "$REPO" )
ok "C: an explicit POLICY_MAILBOX_DIR wins"          yes "$(present "$MC/council-explicit-1.json")"
ok "C: ...and the room keeps no mailbox"             no  "$(present "$RC/mailbox")"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then printf 't32-adhoc-mailbox: %d checks, all passed\n' "$CHECKS"; exit 0; fi
printf 't32-adhoc-mailbox: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"
exit 1
