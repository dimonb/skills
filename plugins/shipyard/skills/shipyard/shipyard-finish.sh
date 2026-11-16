#!/usr/bin/env bash
# shipyard-finish.sh — a FINISHED child closes its own terminal (#355). Run by the child, from its
# own worktree, as the very last thing it does once ship has recorded `done`.
#
#   bash <SKILL>/shipyard-finish.sh
#
# WHY THE CHILD AND NOT THE REPORT. Step 6 tears a merged slot down only once its terminal is gone,
# because no screen read is one an unattended destructive path may act on (#156). A child that
# never closed its terminal therefore kept its slot forever, and finished slots piled up until
# somebody noticed. The child is the one party that knows it is finished without reading a screen,
# so it closes the terminal, and the existing path does the rest with every gate unchanged: the
# absence corroborated, merged on consecutive ticks, stage terminal, no open escalation, and
# `shipyard-down.sh` without flags. This script destroys NOTHING itself — the worktree, the branch
# and the mailbox records all stay.
#
# It refuses, closing nothing, unless all of these hold:
#   * ship's own state file in this worktree reads `done`. Not `ready-to-merge`: there a human
#     still owes the merge, and a child in a no-merge repo waits for it. ship also records `done`
#     for a PR/MR CLOSED without merging, and the child closes its terminal then too — the work is
#     over either way. The report never tears such a slot down (it needs `merged`); it stays a
#     `⛔ no terminal` row for a person, and its content gate will say what is unmerged.
#   * the terminal it would close is the one it is running in — `$AGTERM_SESSION_ID` on agterm,
#     the pane's own window on tmux. So it cannot be aimed at a sibling, and run anywhere but in a
#     child's own terminal it does nothing.
# The driver's own refusals then apply: a session with companions is never closed (exit 3), nor
# one whose companions cannot be read (exit 4).
#
# ORDERING. The closing notice is written to the mailbox BEFORE the close, by this same process,
# so the child's last record cannot race its terminal going away. If the close then fails, a
# second notice says so and why, and the terminal stays for the report's 🏁 FINISHED block — the
# backstop that names a finished slot whose terminal is still up. A closing notice that cannot be
# written stops the close the same way.
#
# Exit: 0 the close was sent (normally this process dies with its terminal first); 1 refused, or
# the close failed; 2 usage.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# THE BACKEND IS THE ONE THIS PROCESS RUNS IN, not whatever `auto` would pick. A child is not handed
# the fleet's SHIPYARD_BACKEND or SHIPYARD_SESSION, and `auto` prefers agterm whenever agtermctl
# answers — so a child of a tmux fleet on a machine where agterm also runs resolved agterm, found
# no `ship-<slot>` there, and never closed itself. The pane says which one it is: a tmux pane wins
# (a tmux server started inside agterm passes AGTERM_SESSION_ID down to its panes), then an agterm
# session. And on tmux the container is the pane's own session, read from tmux itself. Set before
# the library is sourced, because the driver resolves and caches its backend at source time. The
# own-terminal check below is what makes any of this safe: whatever is resolved, only the terminal
# this process runs in can be closed.
if [ -z "${SHIPYARD_BACKEND:-}" ]; then
  if [ -n "${TMUX_PANE:-}" ]; then SHIPYARD_BACKEND=tmux
  elif [ -n "${AGTERM_SESSION_ID:-}" ]; then SHIPYARD_BACKEND=agterm
  fi
fi
if [ "${SHIPYARD_BACKEND:-}" = tmux ] && [ -z "${SHIPYARD_SESSION:-}" ] && [ -n "${TMUX_PANE:-}" ]; then
  SHIPYARD_SESSION=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}' 2>/dev/null) || SHIPYARD_SESSION=''
fi
# shellcheck source=shipyard-lib.sh
. "$DIR/shipyard-lib.sh"

case "${1:-}" in
  '') ;;
  -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "usage: shipyard-finish.sh   (no arguments: it closes the terminal it runs in)" >&2; exit 2 ;;
esac

notice() { bash "$DIR/shipyard-ask.sh" --kind notice "$1" >/dev/null 2>&1; }
refuse() {
  echo "shipyard-finish: not closing — $1" >&2
  notice "finish refused, terminal left up: $1" || true
  exit 1
}

top=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "shipyard-finish: not inside a git worktree" >&2; exit 1; }
SLOT=$(shipyard_slot) || { echo "shipyard-finish: cannot tell which slot this is" >&2; exit 1; }
shipyard_slot_check "$SLOT" 2>/dev/null || { echo "shipyard-finish: '$SLOT' is not a slot name" >&2; exit 1; }
# A worktree that is not `ship-<slot>` is not a child's, whatever SHIPYARD_SLOT says.
[ "$(basename "$top")" = "ship-$SLOT" ] \
  || { echo "shipyard-finish: $top is not slot $SLOT's worktree (ship-$SLOT)" >&2; exit 1; }

stage=$(shipyard_stage_of "$top")
[ "$stage" = done ] || refuse "ship's stage is '${stage:-none}', not done"

own=''
case "$(shipyard_backend)" in
  agterm) own=${AGTERM_SESSION_ID:-} ;;
  tmux)   [ -n "${TMUX_PANE:-}" ] \
            && own=$(tmux display-message -p -t "$TMUX_PANE" '#{session_name}:#{window_index}' 2>/dev/null) ;;
esac
target=$(shipyard_target "$SLOT" 2>/dev/null) || target=''
[ -n "$own" ] || refuse "cannot tell which terminal this is running in"
[ -n "$target" ] || refuse "the $(shipyard_backend) backend has no terminal named ship-$SLOT"
[ "$own" = "$target" ] || refuse "this is not ship-$SLOT's own terminal"

# A closing notice that could not be written is a reason NOT to close: the terminal is then the
# only place the child's end is visible, and the report's 🏁 FINISHED block names it either way.
notice "finished: ship recorded done; closing terminal ship-$SLOT (the worktree stays for teardown)" \
  || refuse "the closing notice could not be written to the mailbox"
err=$(shipyard_kill "$SLOT" 2>&1 >/dev/null) && exit 0
refuse "the close failed: $(printf '%s' "$err" | tr '\n' ' ')"
