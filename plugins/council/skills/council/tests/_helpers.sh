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

# THE KEEPER'S POLL PERIOD, for every room this suite builds. Production is five seconds and
# stays five seconds (`lib/up.sh`, `_keeper_ensure`); this is a twentieth of it, which is what
# makes t16, t19 and t26 finish in seconds instead of minutes. It is not a shortcut around a
# slow test: those files' waits were sized against the production constant, so the constant was
# their runtime — `sleep 7  # longer than the five-second poll` and its neighbours.
#
# SHRINKING IT IS SAFE FOR EVERY CASE THAT HAS NO OPINION ABOUT THE PERIOD, WHICH IS MOST OF
# THEM, AND IT IS NOT SAFE FOR THE REST — so the exceptions do not inherit it. t19 case G's whole
# premise is a keeper superseded DURING its canary read, which needs the read still to be
# blocked while the test mutates the pid file; it drives `_keeper_loop` directly and passes its
# own long period, and says so there. Any future case whose premise is "inside one poll" must do
# the same rather than rely on this value.
#
# `${:-}` so an outer override still wins: that is what makes an A/B measurement of this change
# possible (run the suite with COUNCIL_KEEPER_POLL_INTERVAL=5 to get the old timings on today's
# box), and it matches how POLICY_MAILBOX_DIR above is set.
export COUNCIL_KEEPER_POLL_INTERVAL="${COUNCIL_KEEPER_POLL_INTERVAL:-0.05}"

# TWO RECV BOUNDS, AND THEY ARE NOT INTERCHANGEABLE. `recv --timeout N` is used for two different
# measurements, and a single value for both is what made the t9* files load-sensitive: one of them
# wants a generous bound and the other cannot have one.
#
#   * RECV_WAIT — WAITING FOR SOMETHING. The messages are on disk and the case asserts what comes
#     back. A generous bound costs NOTHING on the happy path, because `recv` returns as soon as it
#     has them; it is only ever paid when the thing never arrives, which is a real failure. What a
#     tight bound buys instead is a case that reds because a loaded box took longer to fork `bash`
#     and `jq` than to answer the question — measured on t9d, green alone and red under a
#     concurrent run of the suite.
#
#   * RECV_NOTHING — ASSERTING NOTHING ARRIVES. There is no event to wait for, so the full window
#     is paid on EVERY run by construction, and lengthening it lengthens the suite for nothing
#     while shortening it genuinely weakens the assertion. It stays short, and that shortness is a
#     deliberate trade rather than an oversight: a message the reader withholds for longer than
#     this would be released and this case would miss it.
#
# Named apart so a reader cannot take one for the other — the same discipline that keeps
# `knob_uint` and `knob_interval` separate in shared/knobs. A case that fits neither takes its own
# number and says why.
RECV_WAIT="${COUNCIL_TEST_RECV_WAIT:-15}"
RECV_NOTHING="${COUNCIL_TEST_RECV_NOTHING:-1}"

# hold <seconds> <pid>... — the window an assertion that NOTHING HAPPENED has to wait out, spent
# CHECKING rather than sleeping. Returns early the moment any of the pids is gone, so the case
# below it reds at once instead of after the full wait; otherwise it returns when the window is
# up and the checks that follow run against a keeper that has had its chances and declined them.
#
# A negative has no event to wait for, so this is the one shape in the suite where a window is
# unavoidable. What it must not be is a fixed `sleep` sized against a production constant. Two
# things were wrong with that and only one of them was speed: `sleep 7` against a five-second
# poll gave the keeper 1.4 poll periods to misbehave in — a thin margin that reads as a generous
# one — and it learned nothing during the other 5.6 seconds. At this suite's 0.05s keeper period
# the default window below is twenty times the poll, so the margin goes UP as the wait goes down.
#
# The window is in whole seconds and deliberately far longer than the period it outwaits: under
# the load a full `make test` puts on a box a keeper can be scheduled late, and a window sized to
# the period alone is how a suite starts failing for reasons that are not about the code (#164).
hold() { # <seconds> <pid>...
  local secs="$1"; shift
  local i n p
  n=$(( secs * 20 ))                       # 0.05s per probe
  for ((i=0;i<n;i++)); do
    for p in "$@"; do kill -0 "$p" 2>/dev/null || return 0; done
    sleep 0.05
  done
  return 0
}

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
# (lib/up.sh), so removing the root reaps them within one poll period anyway — five seconds in
# production, a twentieth of that for this suite (see COUNCIL_KEEPER_POLL_INTERVAL above); killing
# them first makes it immediate and also covers a root this test does not own. Nothing else will
# ever do it:
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
