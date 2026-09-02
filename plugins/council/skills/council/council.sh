#!/usr/bin/env bash
# council.sh — the ONE entrypoint of the council skill. Every participant and every
# supervisor action goes through `council.sh <verb>`.
#
# Why one script and not eight: a participant's permission allowlist matches on the
# literal START of a command. With eight scripts an agent needs eight separate grants,
# and the first lap of every room stalls waiting for a human to click through them —
# measured, in the probe that produced this design: one participant held the floor for
# 626 seconds because it was waiting on a permission prompt, which from the outside is
# indistinguishable from a wedged session. One entrypoint = one allowlist entry.
#
# Two caveats that one entrypoint does NOT buy, both learned from a live room:
#   * a prefix grant only matches if the agent runs the command as written. `agy` prepends
#     the environment inline (`COUNCIL_ROOM=… COUNCIL_ME=… bash …`) even though its launcher
#     already exported both, so a grant on `bash <skill>/council.sh` never matches. A seat this
#     skill launches does not need one — see adapters/agy.sh for what it carries instead;
#   * a command grant says nothing about FILE reads. A path the participant DERIVES is a
#     separate permission question for some agents, which is why `protocol`, `agenda` and
#     `decision` are verbs here rather than paths in the protocol.
set -uo pipefail
export LC_ALL=C
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

# Re-exec under a modern bash if we were started by an old one.
#
# `#!/usr/bin/env bash` picks up whatever is first in PATH, and on a stock macOS that is
# bash 3.2 — no associative arrays, no `read -N`, no EPOCHREALTIME, all three of which this
# code uses. A participant that runs `bash <skill>/council.sh` gets the system bash and a
# stack of syntax errors that look like a broken skill rather than a wrong interpreter.
# Found exactly that way: by a Codex participant, on its first turn in a live room.
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ] && [ -z "${COUNCIL_BASH_REEXEC:-}" ]; then
  for _c in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash bash; do
    _p=$(command -v "$_c" 2>/dev/null) || continue
    _v=$("$_p" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null) || continue
    [ "${_v:-0}" -ge 5 ] && exec env COUNCIL_BASH_REEXEC=1 "$_p" "$0" "$@"
  done
  echo "council: needs bash >= 5, this one is ${BASH_VERSION:-unknown}." >&2
  echo "         macOS ships bash 3.2 as /bin/bash; install a modern one (brew install bash)." >&2
  exit 70
fi

# PHYSICAL path, deliberately. This repo (and any dogfooding checkout) reaches the skill
# through a symlink, and plain `pwd` reports the logical path it was reached by. Handing
# that to a participant is not cosmetic: Codex REFUSES a writable root that is a symlink,
# so the participant launches, reads its protocol, and then cannot run a single council
# command — reported by a live participant as "the sandbox rejects the writable root …
# because it is a symlink".
SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

usage() {
  cat <<'USAGE'
council.sh <verb> [options]

  The room
    up      --scenario <name> --agents <spec> [--room <name>] [--turns N]
            [--cwd <dir>] [--me <peer>] [<agenda>|@file]
    relaunch <peer> [--cwd <dir>]         put one seat back up, in place, mid-room
    down    [--room <name>] [--purge]
    rooms                                 which rooms exist and what state they are in

  Participant (inside a room)
    recv    [--timeout N] [--peek] [--until-floor]     exit 4 = timeout, call again
    send    --act <act> [--refs '["id"]'] [--hand] "<text>"
    floor                                              who holds it and for how long
    protocol                                           your own role and the channel rules
    agenda                                             the question — read this first
    decision                                           the record, once the room has closed

  Looking on
    status  [--room <name>]        the supervisor block; exit 0 = the room is closed
    claims                         the argument graph
    verdict [--json]               verdict: exit 0 closed, 1 open, 2 stuck
                                   (1 with NO output = the roster could not be read)
    order   [--ids]                the total order of messages
    transcript                     the transcript, for a human

  Closing the room
    decide  [--force]              write the ADR on the board and close the room
    say     <peer> "<text>"        speak to a participant out of band, in its terminal

  Common options: --room <name> --me <peer>
  Acts: propose amend object support concede withdraw overrule msg notice decide done

`decision` returns 1 while the room is still open — that is a status, not a failure.

Exit codes mean STATUS, not success. `verdict` returns 1 for a live room, so a pipeline like
`council.sh status | grep -q X` under `set -o pipefail` reads that as a failing grep. It has
already cost one false verdict in the tests — do not pipe status.
USAGE
}

# --- room resolution ------------------------------------------------------------
# Decided by the council itself (room `tri`, see the skill doc): the room lives in the
# SHARED git dir. It is then one path for every worktree of the repo, git never touches
# it, and `git clean` cannot eat a discussion in progress.
room_base() {
  local gcd
  gcd=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  case "$gcd" in /*) ;; *) gcd="$(pwd -P)/$gcd" ;; esac
  gcd=$(cd "$gcd" 2>/dev/null && pwd -P) || return 1
  printf '%s/council' "$gcd"
}

resolve_room() { # honours --room, then $COUNCIL_ROOM, then the only room there is
  local base
  if [ -n "${ROOM_NAME:-}" ]; then
    base=$(room_base) || { echo "council: not in a git repository, set COUNCIL_ROOM" >&2; return 1; }
    printf '%s/%s' "$base" "$ROOM_NAME"; return 0
  fi
  if [ -n "${COUNCIL_ROOM:-}" ]; then printf '%s' "$COUNCIL_ROOM"; return 0; fi
  base=$(room_base) || { echo "council: not in a git repository, set COUNCIL_ROOM" >&2; return 1; }
  local -a rooms=(); local d
  for d in "$base"/*/; do [ -d "$d" ] && rooms+=("${d%/}"); done
  case "${#rooms[@]}" in
    1) printf '%s' "${rooms[0]}" ;;
    0) echo "council: no rooms. Create one: council.sh up --scenario ... --agents ..." >&2; return 1 ;;
    *) echo "council: several rooms, name one with --room:" >&2
       printf '  %s\n' "${rooms[@]##*/}" >&2; return 1 ;;
  esac
}

# --- global options, accepted before or after the verb --------------------------
# The verb may appear anywhere: `council.sh --room r verdict` and `council.sh verdict
# --room r` both work. Requiring it first is the kind of wart every participant trips on
# once, and the error it produces ("unknown verb --room") points at the wrong thing.
ROOM_NAME=""; ARGS=(); VERB=""
while [ $# -gt 0 ]; do
  case "$1" in
    --room) ROOM_NAME="${2:-}"; shift 2 ;;
    --me)   COUNCIL_ME="${2:-}"; export COUNCIL_ME; shift 2 ;;
    *)      if [ -z "$VERB" ]; then VERB="$1"; else ARGS+=("$1"); fi; shift ;;
  esac
done
VERB="${VERB:-help}"
set -- ${ARGS+"${ARGS[@]}"}

case "$VERB" in help|-h|--help) usage; exit 0 ;; esac

if [ "$VERB" = up ]; then . "$SKILL/lib/up.sh"; council_up "$@"; exit $?; fi
if [ "$VERB" = rooms ]; then . "$SKILL/lib/up.sh"; council_rooms; exit $?; fi

COUNCIL_ROOM=$(resolve_room) || exit 1
export COUNCIL_ROOM
[ -d "$COUNCIL_ROOM" ] || { echo "council: no such room: $COUNCIL_ROOM" >&2; exit 1; }
. "$SKILL/lib/lib.sh"

need_me() { [ -n "${COUNCIL_ME:-}" ] || { echo "council: who are you? set COUNCIL_ME or --me <peer>" >&2; exit 2; }; }

case "$VERB" in
  send)   need_me; . "$SKILL/lib/verbs.sh"; v_send "$@" ;;
  recv)   need_me; . "$SKILL/lib/verbs.sh"; v_recv "$@" ;;
  floor)  . "$SKILL/lib/verbs.sh"; v_floor ;;
  protocol) . "$SKILL/lib/verbs.sh"; v_protocol ;;
  agenda) . "$SKILL/lib/verbs.sh"; v_agenda ;;
  decision) . "$SKILL/lib/verbs.sh"; v_decision ;;
  order)  . "$SKILL/lib/verbs.sh"; v_order "$@" ;;
  transcript) . "$SKILL/lib/verbs.sh"; v_transcript ;;
  claims) . "$SKILL/lib/verbs.sh"; v_claims "$@" ;;
  verdict) . "$SKILL/lib/verbs.sh"; v_verdict "$@" ;;
  status) . "$SKILL/lib/verbs.sh"; v_status ;;
  decide) need_me; . "$SKILL/lib/verbs.sh"; v_decide "$@" ;;
  say)    . "$SKILL/lib/up.sh"; council_say "$@" ;;
  relaunch) . "$SKILL/lib/up.sh"; council_relaunch "$@" ;;
  down)   . "$SKILL/lib/up.sh"; council_down "$@" ;;
  *) echo "council: unknown verb '$VERB'" >&2; usage >&2; exit 2 ;;
esac
