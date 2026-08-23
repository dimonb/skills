#!/usr/bin/env bash
# lib.sh — transport core for a council room. Source only, never execute.
#
# Callers reach this through `council.sh <verb>`, which resolves the room and exports
# COUNCIL_ROOM / COUNCIL_ME before sourcing.
#
# Invariants this file is built on, all of which remove a lock rather than take one:
#   * lane/<peer>/NNNNNN.json  — exactly ONE writer (that peer), ever;
#   * cursor/<me>/<peer>       — exactly ONE writer (me), ever;
#   * state/<me>.*             — exactly ONE writer (me), ever;
#   * every file lands via write-tmp-then-rename, so a reader never sees a half file;
#   * total order is (lamport, from), carried IN the message, so every reader derives
#     the same sequence without asking anyone.
export LC_ALL=C
: "${COUNCIL_ROOM:?COUNCIL_ROOM must be set}"
ROOM="$COUNCIL_ROOM"
ME="${COUNCIL_ME:-}"
C_IDLE="${COUNCIL_IDLE:-2}"        # bell-loss fallback, seconds

# The roster never changes while a room lives, so read it once: c_send would
# otherwise pay two jq spawns per message just to learn who to ring.
_C_PEERS=""
c_peers()  { [ -n "$_C_PEERS" ] || _C_PEERS=$(jq -r '.order[]' "$ROOM/roster.json"); printf '%s\n' "$_C_PEERS"; }
c_npeers() { c_peers | wc -l | tr -d ' '; }
c_now()    { date -u +%Y-%m-%dT%H:%M:%SZ; }
# bash 5 gives us sub-second time without spawning anything.
c_ms()     { local t=${EPOCHREALTIME/./}; echo $(( 10#$t / 1000 )); }

# write-then-rename: same directory, so the rename is atomic on any sane fs.
c_atomic() { local p="$1" t="$1.tmp.$$"; cat > "$t" && mv -f "$t" "$p"; }

# The doorbell. One byte, fire and forget.
# Backgrounded inside a subshell: the child is reparented immediately, so a peer whose
# fifo has no reader can never wedge the sender and can never leave us a zombie.
c_ring() { local f="$ROOM/bell/$1.fifo"; [ -p "$f" ] || return 0; ( printf '.' > "$f" & ) ; }

# Read with the builtin, not `cat`: these three are on the hot path of every drain,
# and a fork each is what turned a millisecond wake into a quarter-second one.
c_slurp()   { local v=""; [ -f "$1" ] || { printf 0; return; }; read -r v < "$1" 2>/dev/null; printf '%s' "${v:-0}"; }
c_lamport() { c_slurp "$ROOM/state/$ME.lamport"; }
c_seq()     { c_slurp "$ROOM/state/$ME.seq"; }
c_cursor()  { c_slurp "$ROOM/cursor/$ME/$1"; }

c_deps_json() {
  local p out=""
  for p in $(c_peers); do
    if [ "$p" = "$ME" ]; then out="$out\"$p\":$(c_seq),"; else out="$out\"$p\":$(c_cursor "$p"),"; fi
  done
  printf '{%s}' "${out%,}"
}

# --- send ----------------------------------------------------------------------
# c_send --act A [--refs '["id"]'] [--to '["*"]'] [--hand] [--text T]
c_send() {
  local act=msg refs='[]' to='["*"]' hand=false text=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --act)  act="$2";  shift 2 ;;
      --refs) refs="$2"; shift 2 ;;
      --to)   to="$2";   shift 2 ;;
      --text) text="$2"; shift 2 ;;
      --hand) hand=true; shift ;;
      *) echo "c_send: unknown arg $1" >&2; return 2 ;;
    esac
  done
  local seq lam id f deps turn
  seq=$(( $(c_seq) + 1 ))
  lam=$(( $(c_lamport) + 1 ))
  deps=$(c_deps_json)
  # Which turn this message claims. A hand (raised out of turn) claims none.
  # Two peers CAN claim the same turn — see c_canon for how that is settled.
  if [ "$hand" = true ]; then turn=null; else turn=$(c_turns); fi
  id="$ME-$seq"
  f=$(printf '%s/lane/%s/%06d.json' "$ROOM" "$ME" "$seq")
  jq -n --arg id "$id" --arg from "$ME" --argjson lam "$lam" --argjson deps "$deps" \
        --arg act "$act" --argjson refs "$refs" --argjson to "$to" --argjson hand "$hand" \
        --arg text "$text" --arg at "$(c_now)" --argjson ms "$(c_ms)" --argjson turn "$turn" \
    '{id:$id,from:$from,lamport:$lam,deps:$deps,act:$act,refs:$refs,to:$to,
      hand:$hand,turn:$turn,text:$text,created_at:$at,sent_ms:$ms}' | c_atomic "$f" || return 1
  # my own counters — only I write them, so no ordering hazard with the message file
  printf '%s' "$seq" | c_atomic "$ROOM/state/$ME.seq"
  printf '%s' "$lam" | c_atomic "$ROOM/state/$ME.lamport"
  local p
  for p in $(c_peers); do [ "$p" = "$ME" ] || c_ring "$p"; done
  printf '%s\n' "$id"
}

# --- receive -------------------------------------------------------------------
# Files in my inbox that I have not consumed yet, one path per line.
# A lane has exactly one writer and its numbering is gapless, so we probe upward from
# the cursor and stop at the first missing file: O(new), not O(everything ever said).
# Globbing the whole lane instead is what made the first spike quadratic.
c_new_files() {
  local p cur n f
  for p in $(c_peers); do
    [ "$p" = "$ME" ] && continue
    cur=$(c_cursor "$p"); n=$((cur + 1))
    while :; do
      printf -v f '%s/lane/%s/%06d.json' "$ROOM" "$p" "$n"
      [ -e "$f" ] || break
      printf '%s\n' "$f"
      n=$((n + 1))
    done
  done
}

# Consume everything pending: print it in total order, advance cursors and my clock.
# Returns 1 (and prints nothing) when the inbox is empty.
c_drain() {
  local -a files=(); local -A hi=(); local f p n
  while IFS= read -r f; do
    files+=("$f")
    p="${f%/*}"; p="${p##*/}"          # .../lane/<peer>/NNNNNN.json
    n="${f##*/}"; n=$((10#${n%.json}))
    [ "${hi[$p]:-0}" -lt "$n" ] && hi[$p]=$n
  done < <(c_new_files)
  [ "${#files[@]}" -gt 0 ] || return 1
  local batch
  batch=$(cat "${files[@]}" | jq -s -c 'sort_by(.lamport, .from)[]') || return 1
  printf '%s\n' "$batch"
  for p in "${!hi[@]}"; do printf '%s' "${hi[$p]}" | c_atomic "$ROOM/cursor/$ME/$p"; done
  local seen mine
  seen=$(printf '%s\n' "$batch" | jq -s 'max_by(.lamport).lamport')
  mine=$(c_lamport)
  [ "$seen" -gt "$mine" ] && printf '%s' "$seen" | c_atomic "$ROOM/state/$ME.lamport"
  return 0
}

# Block until something arrives. fd 3 is my bell, opened RDWR by the caller so that
# open() never blocks and a bell rung with nobody listening is buffered, not lost.
c_bell_open() { exec 3<> "$ROOM/bell/$ME.fifo"; }
c_bell_wait() { read -r -t "${1:-$C_IDLE}" -N 1 -u 3 _ 2>/dev/null; return 0; }
c_bell_drain() { while read -r -t 0 -u 3 2>/dev/null && read -r -t 0.01 -N 1 -u 3 _ 2>/dev/null; do :; done; }

# --- total order / floor --------------------------------------------------------
# Every message in the room, in the one order everybody agrees on.
c_all() {
  local -a files=(); local f
  for f in "$ROOM"/lane/*/[0-9]*.json; do [ -e "$f" ] && files+=("$f"); done
  [ "${#files[@]}" -gt 0 ] || return 1
  cat "${files[@]}" | jq -s -c 'sort_by(.lamport, .from)[]'
}

# --- canonicalisation ----------------------------------------------------------
# The floor is a function of the log you have READ, not of the log. A peer that has not
# drained a lane counts fewer turns than reality and can therefore speak while somebody
# else legitimately holds the floor. (Found by Codex in room cx2, on the first try; none
# of t1-t3 caught it, because three shells react in milliseconds and the race window is
# almost nil.)
#
# So a claim on a turn is a CLAIM, not a fact, and the tie is settled the same way
# everything else here is: deterministically, from the message itself. Of all messages
# claiming turn N, the lowest (lamport, from) keeps it; the others are demoted to
# out-of-turn — nothing is lost, nobody blocks, and every reader reaches the same verdict
# without asking anyone. A demoted author simply takes the floor again.
c_canon() {
  # `|| true`: an EMPTY room is a normal state, not an error. c_all reports "nothing
  # here" with exit 1, and under `set -e` + pipefail in a caller that propagated
  # through the command substitution and killed the very first send in a fresh room.
  { c_all 2>/dev/null || true; } | jq -s -c '
    sort_by(.lamport, .from)
    | ( [ .[] | select(.hand == false and .turn != null) ]
        | group_by(.turn) | map(sort_by(.lamport, .from) | .[0].id) ) as $win
    | [ .[] | . as $m | $m + {
          valid: ( ($m.hand // false) or ($m.turn == null)
                   or (($win | index($m.id)) != null) ) } ]
    | .[]'
}

# A message consumes a turn unless it was raised out of turn, or lost a turn conflict.
c_turns() { c_canon | jq -s '[.[] | select(.hand == false and .turn != null and .valid)] | length'; }

# The floor is a pure function of the log: no token file to lose or duplicate.
# Order rotates one step per lap so the same peer is not always the anchor.
c_floor_at() { # <turns-consumed>
  local t="$1" n lap idx
  n=$(c_npeers)
  lap=$(( t / n )); idx=$(( (t % n + lap) % n ))
  jq -r --argjson i "$idx" '.order[$i]' "$ROOM/roster.json"
}
c_floor() { c_floor_at "$(c_turns)"; }
c_next_after() { # who speaks after the current holder
  c_floor_at "$(( $(c_turns) + 1 ))"
}
# When did the current holder get the floor? Timestamp of the last turn-consuming
# message — derived from the log, so no extra state to keep in sync.
c_last_turn_ms() {
  c_canon | jq -s 'map(select(.hand == false and .turn != null and .valid))
                   | if length == 0 then 0 else (max_by(.lamport).sent_ms) end'
}

# How many turns claimed a slot somebody else won — the number the supervisor watches.
c_conflicts() {
  c_canon | jq -s '[.[] | select(.hand == false and .turn != null and (.valid | not))] | length'
}
