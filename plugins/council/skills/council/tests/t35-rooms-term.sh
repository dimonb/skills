#!/usr/bin/env bash
# t35 — `council.sh rooms` and its `term` column (#199).
#
# `rooms` prints `term <live>/<total>` per room so a supervisor with several rooms sees which still
# hold seats, and SKILL.md's monitor procedure tells a supervisor to rely on it. Until this file
# nothing asserted it: replacing the whole subprocess call with `term=""`, so every room printed
# `term ?`, left the suite green. `v_terminals`' answers were asserted through the verb (t27 §9),
# but `council_rooms` is a different code path. It runs BEFORE a room is resolved, iterates
# `room_base()` (the `council/` directory of whatever git dir the caller stands in), and swallows
# the verb's stderr. So this builds a throwaway git dir and drives `rooms` from inside it.
#
# THE ROOMS ARE BUILT BY THE REAL `up`, not by hand, wherever a room needs terminals. t27 asserts
# the `--me` exclusion against a HAND-WRITTEN launch record, whose shape matches `ct_record_launch`
# today. If `up` ever wrote a launcher for the `--me` seat, or recorded it another way, a healthy
# `me,alpha,beta` room would read `term 2/3` again and that fixture would stay green. Here the
# record, the launchers and the pin are whatever `up` wrote.
#
# THE BACKEND IS A SHADOW SKILL, for t27's reason: CI installs no tmux, and a fake can answer
# "the backend did not answer" on demand. The shadow term.sh sources the shipped one and replaces
# only the calls that would reach a live backend: the launch, the enumeration and the kill. The
# fake launch pins the container through the real `drv_container_pin` and hands back a handle
# nobody else holds; the fake kill takes the seat off the backend's list, so a decided room's
# teardown here is the real keeper reaping through the real `ct_kill`.
#
# Rows asserted, each the answer a supervisor acts on:
#   * a live room                         term 2/2
#   * the `--me` seat, from `up --me`     term 2/2 (the seat the human took has no terminal)
#   * a decided room, torn down           term 0/2, and its row still says decided
#   * a room with no launch record at all term -   (never given terminals)
#   * a backend that did not answer       term ?   (not `-`, not a count)
#   * a `terminals` read that died        term ?   (rooms' own fallback for an empty answer)
#   * two repos sharing one container     term ?   after a genuine teardown here, while the other
#     repo's room of the same name still runs. This is the limitation term.sh and SKILL.md state:
#     session names carry no repo, so that teardown cannot be told from a stale record. Asserted
#     so it stays LOUD. A change that makes it read `0/2` has fixed it and should update this
#     case; one that makes it read `2/2` has made a dead room look live.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
REAL_SKILL="$SKILL"

fails=0
ok() { # <what> <expected> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"; fails=$((fails+1)); fi
}

# --- the shadow skill ----------------------------------------------------------------------
SHADOW="$COUNCIL_TEST_ROOT/t35shadow"; rm -rf "$SHADOW"; mkdir -p "$SHADOW/lib"
for e in "$REAL_SKILL"/*; do
  case "${e##*/}" in lib|tests) ;; *) ln -s "$e" "$SHADOW/${e##*/}" ;; esac
done
for e in "$REAL_SKILL"/lib/*; do
  case "${e##*/}" in term.sh) ;; *) ln -s "$e" "$SHADOW/lib/${e##*/}" ;; esac
done
# What the backend lists: one "<handle><TAB><container><TAB><name>" line per session, across every
# room, as one tmux server would. BACKEND_RC is the status the enumeration answers with.
BACKEND="$COUNCIL_TEST_ROOT/t35-backend"; BACKEND_RC="$COUNCIL_TEST_ROOT/t35-backend-rc"
: > "$BACKEND"; printf '0\n' > "$BACKEND_RC"
cat >"$SHADOW/lib/term.sh" <<SHADOWEOF
COUNCIL_BACKEND=tmux
# A room carrying this marker kills the process reading it, so \`terminals\` prints nothing at all.
[ -e "\$ROOM/state/t35-die" ] && kill -KILL \$\$
. "$REAL_SKILL/lib/term.sh"
drv_launch_handle() { # <name> <cwd> <launcher>
  local c; c=\$(drv_container_pin) || return 1
  printf 'h-%s\t%s\t%s\n' "\$1" "\$c" "\$1" >> "$BACKEND"
  printf '%s\th-%s' "\$c" "\$1"
}
drv_kill()     { awk -F'\t' -v n="\$1" '\$3 != n' "$BACKEND" > "$BACKEND.tmp"; mv "$BACKEND.tmp" "$BACKEND"; }
drv_focus()    { :; }
ct_handles()   { cat "$BACKEND"; return "\$(cat "$BACKEND_RC")"; }
ct_sessions()  { cut -f3 "$BACKEND"; return "\$(cat "$BACKEND_RC")"; }
SHADOWEOF
SCLI="$SHADOW/council.sh"

# --- the throwaway repo, and a way to read one row of `rooms` ------------------------------
GD="$COUNCIL_TEST_ROOT/t35-repo"; rm -rf "$GD"; mkdir -p "$GD"
git -C "$GD" init -q . || { echo "t35: git init failed" >&2; exit 1; }
BASE="$GD/.git/council"
rooms()    { ( cd "$GD" && bash "$SCLI" rooms 2>/dev/null ); }
term_of()  { rooms | awk -v r="$1" '$1 == r { print $3 }'; }       # "<live>/<total>", "?" or "-"
row_of()   { rooms | awk -v r="$1" '$1 == r'; }
up() { # <room> <up option>... — a token-mode room, its keeper tracked for _helpers.sh's cleanup
  local r="$1"; shift
  ( cd "$GD" && bash "$SCLI" --room "$r" up --scenario freeform "$@" "x" ) >/dev/null 2>&1
  ROOM_KEEPERS+=("$BASE/$r/state/keeper.pid")
}
backend_has() { cut -f3 "$BACKEND" | grep -c -- "^council-$1-" | tr -d ' '; }
keeper_gone() { # <room> — poll up to ~15s for its keeper to exit
  local k i; k=$(awk 'NR == 1 { print $1 }' "$BASE/$1/state/keeper.pid" 2>/dev/null)
  [ -n "$k" ] || { echo gone; return; }
  for i in $(seq 1 150); do kill -0 "$k" 2>/dev/null || { echo gone; return; }; sleep 0.1; done
  echo alive
}

# --- a live room ----------------------------------------------------------------------------
up live --agents alpha=claude,beta=codex
ok "up launched both seats of the live room"   2     "$(backend_has live)"
ok "a live room reads term 2/2"                "2/2" "$(term_of live)"

# --- the --me seat, from the real `up --me` -------------------------------------------------
# `mine` holds three seats and the human took one: two terminals, and two is the whole room.
up mine --me me --agents me=claude,alpha=claude,beta=codex
ok "up --me launched only the agent seats"     2     "$(backend_has mine)"
ok "...and wrote the --me seat no launcher"    no    "$([ -e "$BASE/mine/state/launch-me.sh" ] && echo yes || echo no)"
ok "the --me seat is not in the rooms total"   "2/2" "$(term_of mine)"
ok "...nor in the terminals verb's"            "2/2" "$( cd "$GD" && COUNCIL_ROOM="$BASE/mine" bash "$SCLI" terminals 2>/dev/null )"

# --- a decided room, torn down by its own keeper ---------------------------------------------
# Driven to ripe through the protocol and closed with `decide`, which asks the keeper to reap; the
# keeper reaps through ct_kill, and the fake takes each seat off the backend's list.
up done --agents alpha=claude,beta=codex
export COUNCIL_ROOM="$BASE/done" ROOM="$BASE/done"
say_floor propose '[]' "Keep one lane per author." >/dev/null
say_floor msg '[]' "Agreed."     >/dev/null
say_floor msg '[]' "Record it."  >/dev/null
say_floor msg '[]' "No objections." >/dev/null
ok "the room to decide is ripe"                ready-to-decide \
   "$( cd "$GD" && bash "$SCLI" verdict 2>/dev/null | awk '{print $1}' )"
( cd "$GD" && COUNCIL_ME=alpha bash "$SCLI" decide ) >/dev/null 2>&1
ok "decide closed the room as decided"         decided "$(cat "$BASE/done/board/status" 2>/dev/null)"
ok "...and its keeper reaped and exited"       gone "$(keeper_gone done)"
ok "...taking both seats off the backend"      0     "$(backend_has done)"
ok "a decided, torn-down room reads term 0/2"  "0/2" "$(term_of done)"
ok "...and its row still says decided"         1     "$(row_of done | grep -c decided)"
unset COUNCIL_ROOM ROOM

# --- a room with no launch record, no pin and no launcher -----------------------------------
# Every hand-built room is this shape: nothing was ever launched for it, which `-` says.
mkroom "$BASE/bare" a b
ok "a room never given terminals reads term -" "-"   "$(term_of bare)"

# --- a backend that does not answer ------------------------------------------------------------
# `v_terminals` prints `?` with its reason on stderr, which `rooms` drops. The row must still say
# `?`: a count would be a guess and `-` would say the room was never launched.
printf '1\n' > "$BACKEND_RC"
ok "an unanswering backend reads term ?"       "?"   "$(term_of live)"
ok "...for the --me room too"                  "?"   "$(term_of mine)"
ok "...and a room with no record is still -"   "-"   "$(term_of bare)"
printf '0\n' > "$BACKEND_RC"
ok "the live room reads 2/2 again once it answers" "2/2" "$(term_of live)"

# --- a terminals read that dies and prints nothing -------------------------------------------
# `rooms` drops the verb's stderr and does not branch on its status, so an empty answer is the one
# thing it has to catch itself. Without its fallback the row printed a bare `term`.
: > "$BASE/mine/state/t35-die"
ok "a read that printed nothing reads term ?"  "?"   "$(term_of mine)"
rm -f "$BASE/mine/state/t35-die"

# --- two repos sharing one container ---------------------------------------------------------
# The same repo basename on tmux (or one agterm workspace) puts another checkout's room of the
# same name into this room's container, under the same session names and different handles. Tear
# this room's seats down and the other repo's are still listed: the launched handles are gone and
# a session with each seat's name is there, which the verdict cannot tell from a planted name.
container=$(cat "$BASE/live/state/container-tmux")
( cd "$GD" && COUNCIL_ROOM="$BASE/live" bash "$SCLI" down ) >/dev/null 2>&1
ok "down took the live room's seats off the backend" 0 "$(backend_has live)"
ok "...and alone it reads term 0/2"            "0/2" "$(term_of live)"
printf 'h-other-%s\t%s\t%s\n' alpha "$container" council-live-alpha \
                              beta  "$container" council-live-beta >> "$BACKEND"
ok "the other repo's same-named room reads here as ?, not 0/2 or 2/2" "?" "$(term_of live)"

rm -rf "$GD"
[ "$fails" = 0 ] && echo "t35 PASS" || echo "t35 FAIL ($fails)"
exit $([ "$fails" = 0 ] && echo 0 || echo 1)
