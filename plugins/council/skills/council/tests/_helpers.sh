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

# Keep every escalation these tests trigger inside the run root. `decide` on an unconverged room
# now routes a needs-human notice to the shared mailbox (ESC-04), which policy.sh resolves to the
# common git dir by default — i.e. the REAL .git/ship-escalations of whatever checkout the suite
# runs in. Pointing POLICY_MAILBOX_DIR at the run root makes those writes land in the temp tree the
# EXIT trap already removes, so a test never pollutes a developer's mailbox. `${:-}` so an explicit
# outer override still wins.
export POLICY_MAILBOX_DIR="${POLICY_MAILBOX_DIR:-$COUNCIL_TEST_ROOT/ship-escalations}"

# EVERY room's keeper, not just the last one. A test may build several — t7 builds two — and a
# single variable here left the earlier keepers running. Each holds one fifo per participant open
# and loops for as long as its room exists, so they have to be tracked to be stopped.
ROOM_KEEPERS=()

# Signal a room's keeper, never whatever its pid file happens to hold. `kill` reads a `0` as
# EVERY PROCESS IN THE SENDER'S PROCESS GROUP, so `kill "$(cat keeper.pid)"` over a stale or
# hand-written pid file takes down the test that is running — and `kill -9` of a process group
# cannot be caught, so the cleanup that was meant to tidy up is the thing that kills the suite.
# That is not hypothetical: it is how the accident behind issue #67's second point was found,
# by a probe script whose own cleanup did exactly this.
#
# The rule is duplicated here rather than taken from `lib/up.sh` ON PURPOSE. `_keeper_pid` over
# there is one of the things these tests assert, and a harness whose safety depends on the code
# under test being correct is not a test of that code — t13 makes the same argument about its
# terminal backend. Ten digits at most, so `$(( ))` cannot wrap a 64-bit integer into somebody
# else's live pid.
kill_keeper() { # <pid-file> [signal]
  local v=""
  [ -s "$1" ] || return 0
  read -r v < "$1" 2>/dev/null
  case "$v" in ''|*[!0-9]*) return 0 ;; esac
  [ "${#v}" -le 10 ] || return 0
  v=$((10#$v)); [ "$v" -gt 0 ] || return 0
  kill ${2:+"$2"} "$v" 2>/dev/null || true
}

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
  local k p i
  if [ "${#ROOM_KEEPERS[@]}" -gt 0 ]; then
    for k in "${ROOM_KEEPERS[@]}"; do kill_keeper "$k"; done
  fi
  # The listeners a test backgrounds itself are NOT keepers: they hold a bell fifo, they poll
  # nothing, and removing the root does not touch them. Their parent dies with the test, so
  # they reparent to init, and no later run reuses the room name — nothing will ever reap
  # them and they last until the machine reboots. One was found here three days old.
  #
  # Each such test also takes its own down, on its LAST line — which is the one line an early
  # exit skips: a failed assertion above it, the runner's timeout ceiling, a plain kill. Doing
  # it here instead puts it on every exit path, and covers tests not yet written.
  #
  # `$(jobs -p)` inside this trap lists the JOBS OF THE SHELL THAT SET IT, not of the
  # substitution's subshell — the job table is inherited for reporting. Measured on bash 5.3.
  local -a bg=(); bg=( $(jobs -p 2>/dev/null) )
  if [ "${#bg[@]}" -gt 0 ]; then
    # TERM first, then CONT — in that order and not the reverse. A SIGSTOPped child does not
    # act on TERM until something lets it run again, and t3 stops a peer on purpose; sending
    # CONT first would instead give it a window to block on its fifo afresh. Measured: STOP
    # then TERM leaves it alive, and the queued TERM is delivered the moment CONT arrives.
    kill "${bg[@]}" 2>/dev/null
    kill -CONT "${bg[@]}" 2>/dev/null
    # A bounded wait, then KILL for whatever ignored TERM. Not `wait`: a job blocked on a fifo
    # read may never return, and this trap must not be the thing that hangs.
    local alive
    for i in 1 2 3 4 5 6 7 8 9 10; do
      alive=0
      for p in "${bg[@]}"; do kill -0 "$p" 2>/dev/null && { alive=1; break; }; done
      [ "$alive" = 1 ] || break
      sleep 0.1
    done
    kill -9 "${bg[@]}" 2>/dev/null
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
  # `created_ms` the way `up` writes it: once, at creation, from the same clock `c_ms` reads.
  # A test that wants a room which records no creation time deletes the field.
  printf '%s\n' "$@" | jq -R . | jq -s --argjson t 30 --argjson cms "$(( 10#${EPOCHREALTIME/./} / 1000 ))" \
    '{order:., mode:"token", decide_by:"unanimous", order_rotate:true,
      turn_deadline_ms:3000, turns_budget:$t, created_at:"test", created_ms:$cms}' > "$room/roster.json"
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
