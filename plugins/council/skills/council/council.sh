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
  echo "council: нужен bash >= 5, а этот — ${BASH_VERSION:-неизвестный}." >&2
  echo "         macOS несёт bash 3.2 как /bin/bash; поставьте современный (brew install bash)." >&2
  exit 70
fi

# PHYSICAL path, deliberately. This repo (and any dogfooding checkout) reaches the skill
# through a symlink, and plain `pwd` reports the logical path it was reached by. Handing
# that to a participant is not cosmetic: Codex REFUSES a writable root that is a symlink,
# so the participant launches, reads its protocol, and then cannot run a single council
# command — reported by a live participant as "песочница отвергает writable root … потому
# что это симлинк".
SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

usage() {
  cat <<'USAGE'
council.sh <verb> [options]

  Комната
    up      --scenario <name> --agents <spec> [--room <name>] [--turns N]
            [--cwd <dir>] [--me <peer>] [<повестка>|@файл]
    down    [--room <name>] [--purge]
    rooms                                 какие комнаты есть и в каком они состоянии

  Участник (внутри комнаты)
    recv    [--timeout N] [--peek] [--until-floor]     код 4 = таймаут, зови снова
    send    --act <act> [--refs '["id"]'] [--hand] "<текст>"
    floor                                              чей ход и сколько держит

  Смотреть
    status  [--room <name>]        блок супервизора; код 0 = комната закрыта
    claims                         граф аргументов
    verdict [--json]               вердикт: код 0 закрыта, 1 открыта, 2 залипла
    order   [--ids]                тотальный порядок сообщений
    transcript                     стенограмма для человека

  Арбитр
    decide  [--force]              записать ADR на доску и закрыть комнату
    say     <peer> "<текст>"       сказать участнику вне очереди, в его терминал

  Общие опции: --room <name> --me <peer>
  Акты: propose amend object support concede withdraw overrule msg notice decide done

Коды возврата означают СТАТУС, а не успех. `verdict` возвращает 1 на живой комнате, и
пайплайн вроде `council.sh status | grep -q X` под `set -o pipefail` прочитает это как
провал grep. Это уже стоило одного ложного вердикта в тестах — не пайпите статус.
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
    base=$(room_base) || { echo "council: не в git-репозитории, задайте COUNCIL_ROOM" >&2; return 1; }
    printf '%s/%s' "$base" "$ROOM_NAME"; return 0
  fi
  if [ -n "${COUNCIL_ROOM:-}" ]; then printf '%s' "$COUNCIL_ROOM"; return 0; fi
  base=$(room_base) || { echo "council: не в git-репозитории, задайте COUNCIL_ROOM" >&2; return 1; }
  local -a rooms=(); local d
  for d in "$base"/*/; do [ -d "$d" ] && rooms+=("${d%/}"); done
  case "${#rooms[@]}" in
    1) printf '%s' "${rooms[0]}" ;;
    0) echo "council: комнат нет. Создайте: council.sh up --scenario ... --agents ..." >&2; return 1 ;;
    *) echo "council: комнат несколько, укажите --room:" >&2
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
[ -d "$COUNCIL_ROOM" ] || { echo "council: нет такой комнаты: $COUNCIL_ROOM" >&2; exit 1; }
. "$SKILL/lib/lib.sh"

need_me() { [ -n "${COUNCIL_ME:-}" ] || { echo "council: кто вы? задайте COUNCIL_ME или --me <peer>" >&2; exit 2; }; }

case "$VERB" in
  send)   need_me; . "$SKILL/lib/verbs.sh"; v_send "$@" ;;
  recv)   need_me; . "$SKILL/lib/verbs.sh"; v_recv "$@" ;;
  floor)  . "$SKILL/lib/verbs.sh"; v_floor ;;
  order)  . "$SKILL/lib/verbs.sh"; v_order "$@" ;;
  transcript) . "$SKILL/lib/verbs.sh"; v_transcript ;;
  claims) . "$SKILL/lib/verbs.sh"; v_claims "$@" ;;
  verdict) . "$SKILL/lib/verbs.sh"; v_verdict "$@" ;;
  status) . "$SKILL/lib/verbs.sh"; v_status ;;
  decide) need_me; . "$SKILL/lib/verbs.sh"; v_decide "$@" ;;
  say)    . "$SKILL/lib/up.sh"; council_say "$@" ;;
  down)   . "$SKILL/lib/up.sh"; council_down "$@" ;;
  *) echo "council: неизвестный глагол '$VERB'" >&2; usage >&2; exit 2 ;;
esac
