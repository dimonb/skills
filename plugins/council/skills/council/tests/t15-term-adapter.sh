#!/usr/bin/env bash
# t15 — the council terminal ADAPTER (lib/term.sh) over the shared drv_* driver.
#
# lib/term.sh no longer carries the backend mechanics; it maps council's knobs onto the shared
# driver (lib/agent-driver.sh) and delegates each ct_* verb to the matching drv_*. The driver's
# own mechanics are covered by shared/driver/tests/t-driver.sh; THIS file asserts only the
# council-specific glue the migration introduced, and that the naming stays byte-identical to
# before: the `-ai` container suffix on agterm and none on tmux, the pin file under $ROOM/state,
# the council-<room>-<peer> session-name template, and the COUNCIL_BACKEND -> DRV_BACKEND mapping
# including the refusal a bad value yields. Everything here is a pure read over environment
# variables — no live terminal, no agtermctl, no tmux: an explicit COUNCIL_BACKEND resolves the
# driver's backend without invoking any CLI, so the container derivation is deterministic.
#
# term.sh sources the driver, whose baseline interpreter is bash >= 5, so re-exec into one if a
# stock bash 3.2 started us (the guard council.sh and t-driver.sh use), or a bash-5-only construct
# in the driver would surface here as a confusing syntax error rather than a clear version message.
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ] && [ -z "${T15_BASH_REEXEC:-}" ]; then
  for _c in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash bash; do
    _p=$(command -v "$_c" 2>/dev/null) || continue
    _v=$("$_p" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null) || continue
    [ "${_v:-0}" -ge 5 ] && exec env T15_BASH_REEXEC=1 "$_p" "$0" "$@"
  done
  echo "t15: needs bash >= 5, this one is ${BASH_VERSION:-unknown}." >&2
  exit 70
fi

set -uo pipefail
export LC_ALL=C
SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TERM_SH="$SKILL/lib/term.sh"
[ -f "$TERM_SH" ] || { echo "t15: cannot find term.sh at $TERM_SH" >&2; exit 1; }

ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$ROOT"' EXIT

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}

ROOM="$ROOT/demo-room"          # its basename drives ct_name
mkdir -p "$ROOM/state"

# --- ct_name — council's own template, the one thing that stays in the adapter ---------------
got=$( export COUNCIL_BACKEND=tmux ROOM="$ROOM"; . "$TERM_SH"; ct_name alice )
ok "ct_name is council-<room>-<peer>" "council-demo-room-alice" "$got"

# --- the container suffix: -ai on agterm, none on tmux --------------------------------------
# Both derive from the same repo stem (same cwd), so their relationship is asserted without
# hard-coding the machine's repo name. AGTERM_WORKSPACE_ID is unset so agterm takes the repo-stem
# fallback rather than a live workspace name.
tmux_c=$( export COUNCIL_BACKEND=tmux ROOM="$ROOM"; . "$TERM_SH"; ct_container )
agt_c=$(  export COUNCIL_BACKEND=agterm ROOM="$ROOM"; unset AGTERM_WORKSPACE_ID; . "$TERM_SH"; ct_container )
ok "tmux container carries no -ai suffix" "$tmux_c"    "${agt_c%-ai}"
ok "agterm container appends -ai"         "$tmux_c-ai" "$agt_c"

# --- the pin lives under $ROOM/state, keyed by backend — exactly where it did pre-migration --
pin_v=$( export COUNCIL_BACKEND=tmux ROOM="$ROOM"; . "$TERM_SH"; ct_container_pin )
ok "ct_container_pin writes \$ROOM/state/container-tmux" "$pin_v" "$(cat "$ROOM/state/container-tmux" 2>/dev/null)"

# --- COUNCIL_BACKEND -> DRV_BACKEND: an unresolvable value refuses (exit 1), the headless path -
rc=0
( export COUNCIL_BACKEND=none-for-tests ROOM="$ROOM"; . "$TERM_SH"; ct_container ) >/dev/null 2>&1 || rc=$?
ok "an unresolvable backend refuses (exit 1)" 1 "$rc"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then echo "t15 PASS ($CHECKS checks)"; else echo "t15 FAIL ($FAILURES/$CHECKS)"; exit 1; fi
