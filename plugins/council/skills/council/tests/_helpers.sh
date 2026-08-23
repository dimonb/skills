#!/usr/bin/env bash
# Shared test scaffolding. A test room is built directly, without terminals: these tests
# cover the transport and the protocol, not the agents.
export LC_ALL=C
SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLI="$SKILL/council.sh"

mkroom() { # <dir> <peer>... — a room with no terminals attached
  local room="$1"; shift
  rm -rf "$room"
  ( SKILL="$SKILL"; . "$SKILL/lib/up.sh"; _mkroom "$room" "$@" )
  # kill the room's keeper when this test exits, or it outlives the run
  trap 'kill "$(cat "$ROOM_KEEPER" 2>/dev/null)" 2>/dev/null' EXIT
  ROOM_KEEPER="$room/state/keeper.pid"
  printf '%s\n' "$@" | jq -R . | jq -s --argjson t 30 \
    '{order:., mode:"token", decide_by:"unanimous", order_rotate:true,
      turn_deadline_ms:3000, turns_budget:$t, created_at:"test"}' > "$room/roster.json"
}
say() { # <peer> <act> <refs-json> <text>
  COUNCIL_ROOM="$ROOM" COUNCIL_ME="$1" bash "$CLI" send --act "$2" --refs "$3" "$4" >/dev/null
}
verdict1() { COUNCIL_ROOM="$ROOM" bash "$CLI" verdict | cut -d' ' -f1; }

# Speak as whoever currently holds the floor. Tests of the deliberation layer care about
# WHAT is said, not by whom, and hard-coding a speaker order would make them re-derive the
# rotation — the very thing the code is there to own.
say_floor() { # <act> <refs-json> <text>
  local who
  who=$(COUNCIL_ROOM="$ROOM" bash "$CLI" floor | sed -n 's/.*floor=\([^ ]*\).*/\1/p')
  [ -n "$who" ] || { echo "say_floor: не смог определить, чей ход" >&2; return 1; }
  COUNCIL_ROOM="$ROOM" COUNCIL_ME="$who" bash "$CLI" send --act "$1" --refs "$2" "$3" >/dev/null || return $?
  printf '%s' "$who"
}

# Write a message straight into a lane, bypassing council.sh. Only for testing the parts
# that a legal `send` can no longer reach on purpose.
raw_msg() { # <peer> <seq> <lamport> <turn> <act> <refs-json> <text>
  local peer="$1" seq="$2" lam="$3" turn="$4" act="$5" refs="$6" text="$7"
  local f; f=$(printf '%s/lane/%s/%06d.json' "$ROOM" "$peer" "$seq")
  jq -n --arg id "$peer-$seq" --arg from "$peer" --argjson lam "$lam" --argjson turn "$turn" \
        --arg act "$act" --argjson refs "$refs" --arg text "$text" \
    '{id:$id,from:$from,lamport:$lam,deps:{},act:$act,refs:$refs,to:["*"],
      hand:false,turn:$turn,round:null,text:$text,created_at:"test",sent_ms:0}' > "$f"
  printf '%s' "$seq" > "$ROOM/state/$peer.seq"
}

c_peers_list() { jq -r '.order[]' "$ROOM/roster.json"; }
