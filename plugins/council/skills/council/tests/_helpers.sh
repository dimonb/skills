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
