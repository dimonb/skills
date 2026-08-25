#!/usr/bin/env bash
# Shared test scaffolding. A test room is built directly, without terminals: these tests
# cover the transport and the protocol, not the agents.
export LC_ALL=C
SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CLI="$SKILL/council.sh"

# One root per RUN, not one per test name. Two suites at once — the normal case on a machine
# driving a fleet of sessions — otherwise delete each other's rooms mid-drain, and the failure
# lands on whichever test was unlucky rather than on the one that caused it. run-all.sh exports
# this so every test of a run shares a root; a test started on its own makes its own.
if [ -z "${COUNCIL_TEST_ROOT:-}" ]; then
  mkdir -p "${TMPDIR:-/tmp}/council-test" || exit 1
  COUNCIL_TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/council-test/run.XXXXXXXX") || exit 1
  export COUNCIL_TEST_ROOT
  COUNCIL_TEST_ROOT_OWNED=1
fi

# EVERY room's keeper, not just the last one. A test may build several — t7 builds two — and a
# single variable here left the earlier keepers running. Each holds one fifo per participant open
# and loops for as long as its room exists, so they have to be tracked to be stopped.
ROOM_KEEPERS=()

# Take the keepers down and remove the root this test owns. A keeper polls `while [ -d "$room" ]`
# (lib/up.sh), so removing the root reaps them within five seconds anyway; killing them first
# makes it immediate and also covers a root this test does not own. Nothing else will ever do it:
# one root per run means no later run reuses this path, so a root left behind here is a directory
# and a live process that survive until the machine reboots.
#
# An EXIT trap alone is the right and only handler. Bash runs it when the shell dies on an
# untrapped fatal signal as well as on a normal exit, so a killed test cleans up too; SIGKILL is
# the one exception and nothing can catch that. Do NOT add INT/TERM traps: a TRAPPED signal is
# deferred until the current foreground command returns, so `trap 'exit 143' TERM` turns a prompt
# kill into one that waits for whatever the test is wedged on — which for a test blocked on a
# fifo is forever. Measured on bash 5.3: 60s to die with that trap, 0s without it, and the
# cleanup ran either way.
_council_test_cleanup() {
  local rc=$?
  local k
  if [ "${#ROOM_KEEPERS[@]}" -gt 0 ]; then
    for k in "${ROOM_KEEPERS[@]}"; do kill "$(cat "$k" 2>/dev/null)" 2>/dev/null; done
  fi
  [ "${COUNCIL_TEST_ROOT_OWNED:-0}" = 1 ] && rm -rf "$COUNCIL_TEST_ROOT"
  return $rc
}
trap _council_test_cleanup EXIT

mkroom() { # <dir> <peer>... — a room with no terminals attached
  local room="$1"; shift
  rm -rf "$room"
  ( SKILL="$SKILL"; . "$SKILL/lib/up.sh"; _mkroom "$room" "$@" )
  ROOM_KEEPERS+=("$room/state/keeper.pid")
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
  [ -n "$who" ] || { echo "say_floor: could not work out whose turn it is" >&2; return 1; }
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
