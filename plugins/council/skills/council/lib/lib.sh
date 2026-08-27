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

# --- trusting nothing another participant wrote ---------------------------------
# Every numeric field below arrives in a file some OTHER participant wrote, so none of it
# is believed on read. A value of the wrong type is treated as ABSENT rather than trusted:
# `.turn` and `.round` fall back to null, `.lamport` and `.sent_ms` to 0, and `.hand` to a
# real boolean.
#
# Two different things go wrong without this, and they are worth naming separately.
#
# jq's total order sorts strings ABOVE every number, so one message carrying a string
# `.turn` or `.lamport` wins every `max` and every `sort_by` in the room and takes the
# ordering over -- no exploit needed, a typo does it.
#
# And such a value then reaches bash arithmetic, which EVALUATES what it is handed rather
# than merely parsing it. A lane file whose `.turn` is `turns[$(...)]` ran commands in the
# shell of whoever read the room. Coercing at the two places a LANE MESSAGE enters the
# process -- c_all and c_drain -- means no consumer downstream has to remember a check,
# which is the version that decays: the next consumer is written by someone who never saw
# this comment.
#
# READ THIS BEFORE YOU TRUST IT. What is covered is the five fields above, of a LANE
# MESSAGE, and nothing else. It is NOT a room-wide guarantee, and the room is writable by
# every participant, not just its own lane. The other numeric room inputs are gated at their
# own readers rather than here -- `state/*.lamport`, `state/*.seq` and `cursor/*` in c_slurp,
# and the `roster.json` numerics in c_quorum, c_barrier and v_verdict. Each of those was a
# live way to run a command in a reader's shell until it was gated, because they reach
# `$(( ))` and `$(( ))` evaluates. Separately, `.from` is interpolated into a path in c_drain
# without being checked against the roster, which is not execution but does let one
# participant make another create or truncate a file outside the room; that one is still open
# and tracked on its own. So: adding an arithmetic use of anything that did not come through
# `_untrusted` or one of those readers still needs its own gate.
C_UNTRUSTED='def _untrusted: map(
    .turn    |= (if type == "number" then . else null end)
  | .round   |= (if type == "number" then . else null end)
  | .lamport |= (if type == "number" then . else 0 end)
  | .sent_ms |= (if type == "number" then . else 0 end)
  | .hand     = (.hand == true)); '

# write-then-rename: same directory, so the rename is atomic on any sane fs.
c_atomic() { local p="$1" t="$1.tmp.$$"; cat > "$t" && mv -f "$t" "$p"; }

# The doorbell. One byte, fire and forget.
# Backgrounded inside a subshell: the child is reparented immediately, so a peer whose
# fifo has no reader can never wedge the sender and can never leave us a zombie.
c_ring() { local f="$ROOM/bell/$1.fifo"; [ -p "$f" ] || return 0; ( printf '.' > "$f" & ) ; }

# Read with the builtin, not `cat`: these are on the hot path of every drain, and a fork
# each is what turned a millisecond wake into a quarter-second one. That is also why the
# gate below is inlined rather than layered over c_slurp_raw -- a wrapper would pay back
# the fork this comment exists to avoid.
#
# Every file read here is written by ANOTHER participant, and every caller but one feeds
# the result to `$(( ))`, which EVALUATES what it is handed rather than merely parsing it.
# So an integer gate is the DEFAULT, not something each numeric caller remembers: a reader
# added later that reaches for c_slurp is safe without knowing this, and the one caller
# that wants a WORD has to ask for c_slurp_raw by name. Wrong-typed is treated as ABSENT
# (0), the same rule _untrusted applies to a lane message.
c_slurp()   { local v=""; [ -f "$1" ] || { printf 0; return; }; read -r v < "$1" 2>/dev/null
              case "$v" in ''|*[!0-9]*) v=0 ;; esac; printf '%s' "$v"; }
# Verbatim, for the one room file that legitimately holds a word rather than a number:
# board/status, compared as decided|unresolved. A numeric gate there would map BOTH onto 0
# and report a room that ran out of turns as decided. Nothing may do arithmetic on this.
c_slurp_raw() { local v=""; [ -f "$1" ] || { printf 0; return; }; read -r v < "$1" 2>/dev/null; printf '%s' "${v:-0}"; }
c_lamport() { c_slurp "$ROOM/state/$ME.lamport"; }
# The highest clock anywhere in the room, mine included.
c_max_lamport() {
  local mine disk
  mine=$(c_lamport)
  disk=$({ c_all 2>/dev/null || true; } | jq -s 'if length == 0 then 0 else (max_by(.lamport).lamport) end')
  # c_send feeds this straight into `lam=$(( ... + 1 ))`, so BOTH paths out of here have to
  # be integers -- the value read off disk, gated on the next line, and `mine`, which is what
  # this function returns whenever the comparison below is false or errors. `mine` is gated
  # at its source now, in c_slurp; it used to arrive unchecked, and a crafted
  # state/<peer>.lamport therefore ran a command in the shell of whoever sent next.
  case "$disk" in ''|*[!0-9]*) disk=0 ;; esac
  [ "$disk" -gt "$mine" ] && printf '%s' "$disk" || printf '%s' "$mine"
}
c_seq()     { c_slurp "$ROOM/state/$ME.seq"; }
c_cursor()  { c_slurp "$ROOM/cursor/$ME/$1"; }

c_deps_json() {
  local p out=""
  for p in $(c_peers); do
    if [ "$p" = "$ME" ]; then out="$out\"$p\":$(c_seq),"; else out="$out\"$p\":$(c_cursor "$p"),"; fi
  done
  printf '{%s}' "${out%,}"
}

# --- the opening barrier (mode: roundtable) -------------------------------------
# Turn-taking rotates the anchor; it does not remove it. In a room of two or three the
# second speaker still sees the first position before forming its own — which is exactly
# the case `debate` exists for. So a roundtable room runs its FIRST lap as a barrier:
# everyone writes a position without waiting for a turn, and nobody READS anyone else's
# until the round is complete. After that lap the room is turn-taking again, so no
# delivery-stability rule is needed: from there on only one participant speaks at a time.
#
# The barrier is held on the READ side, and its state is derived from the log — every
# participant computes the same answer without asking anyone.
c_mode()   { jq -r '.mode // "token"' "$ROOM/roster.json"; }
# roster.json lives in the room, so every participant can write it -- and both numbers
# below reach bash: the quorum a `[ -lt ]`, the deadline a `$(( deadline * 2 ))`. `// empty`
# and `// 600000` do NOT defend that, because a STRING is truthy in jq and sails through the
# alternative operator untouched. Ask for the type instead, and treat anything else as absent.
c_quorum() { jq -r 'if (.round_quorum|type) == "number" then .round_quorum else empty end' "$ROOM/roster.json"; }

# Positions posted in the opening round, as JSON lines.
c_round0() { { c_all 2>/dev/null || true; } | jq -c 'select(.round == 0)'; }

# open | closed. Closed for good once everyone has posted, or once the deadline has passed
# with a quorum — one participant that never starts must not hold the room forever.
c_barrier() {
  [ "$(c_mode)" = roundtable ] || { printf 'closed'; return; }
  local n posted quorum first deadline
  n=$(c_npeers)
  posted=$(c_round0 | wc -l | tr -d ' ')
  [ "$posted" -ge "$n" ] && { printf 'closed'; return; }
  # A quorum below 2 is not a quorum: at N=2 the N-1 default would let ONE position plus a
  # deadline close the round, which is the barrier deleting itself. (Raised, blind and
  # independently, by a Codex participant inside the very room deciding this question.)
  quorum=$(c_quorum); [ -n "$quorum" ] || quorum=$(( n - 1 )); [ "$quorum" -lt 2 ] && quorum=2
  first=$(c_round0 | jq -s 'if length == 0 then 0 else (min_by(.sent_ms).sent_ms) end')
  case "$first" in ''|*[!0-9]*) first=0 ;; esac
  deadline=$(jq -r 'if (.round_deadline_ms|type) == "number" then .round_deadline_ms else 600000 end' "$ROOM/roster.json")
  [ "$first" = 0 ] && { printf 'open'; return; }
  local age=$(( $(c_ms) - first ))
  if [ "$age" -gt "$deadline" ] && [ "$posted" -ge "$quorum" ]; then
    printf 'closed'
  elif [ "$age" -gt $(( deadline * 2 )) ]; then
    # The backstop. With the quorum clamped to 2, an N=2 room whose partner never speaks
    # would otherwise wait forever — the freeze the deadline exists to prevent, moved one
    # step down. Past twice the deadline the round closes with whatever it has.
    printf 'closed'
  else
    printf 'open'
  fi
}
c_posted_round0() { c_round0 | jq -r --arg me "$ME" 'select(.from == $me) | .id' | head -1; }

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
  local seq lam id f deps turn round=null
  seq=$(( $(c_seq) + 1 ))
  # My clock must dominate everything I am about to COUNT, not merely everything I have
  # read. c_turns counts messages on disk, so a participant can legitimately stamp turn 22
  # while its own clock still sits below the author of turn 21 — and then the canonical
  # (lamport, from) order disagrees with the turn order, which makes a transcript show a
  # reply before what it replies to. Observing a message by counting it is still observing
  # it, so the clock rises to match.
  lam=$(( $(c_max_lamport) + 1 ))
  deps=$(c_deps_json)
  # Which turn this message claims. A hand (raised out of turn) claims none, and neither
  # does an opening position: the whole point of the barrier round is that N participants
  # write at once, so making them compete for turn 0 would demote all but one of them.
  if [ "$hand" = true ]; then
    turn=null
  elif [ "$(c_barrier)" = open ]; then
    if [ -n "$(c_posted_round0)" ]; then
      echo "council: the round is not complete — you have stated your position, wait for the others" >&2
      return 5
    fi
    round=0; turn=null
  else
    turn=$(c_turns)
    # Check the floor AT STAMP TIME, not before composing. A participant that legitimately
    # held the floor a moment ago may have lost it while it was writing, and it would then
    # stamp the next FREE turn — no conflict for c_canon to settle, and the room silently
    # stops being turn-taking. (Every message after the first such slip reads as
    # out-of-turn: caught exactly that way, by t3, once the check became slow enough to
    # widen the window.) `skip` is exempt: it is by definition spoken for somebody else.
    if [ "$act" != skip ] && [ "$(c_floor_at "$turn")" != "$ME" ]; then
      echo "council: the floor is no longer yours (turn $turn belongs to $(c_floor_at "$turn")) — drain your inbox and wait for your turn" >&2
      return 6
    fi
  fi
  id="$ME-$seq"
  f=$(printf '%s/lane/%s/%06d.json' "$ROOM" "$ME" "$seq")
  jq -n --arg id "$id" --arg from "$ME" --argjson lam "$lam" --argjson deps "$deps" \
        --arg act "$act" --argjson refs "$refs" --argjson to "$to" --argjson hand "$hand" \
        --arg text "$text" --arg at "$(c_now)" --argjson ms "$(c_ms)" --argjson turn "$turn" \
        --argjson round "$round" \
    '{id:$id,from:$from,lamport:$lam,deps:$deps,act:$act,refs:$refs,to:$to,
      hand:$hand,turn:$turn,round:$round,text:$text,created_at:$at,sent_ms:$ms}' | c_atomic "$f" || return 1
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
  local -a files=(); local f
  while IFS= read -r f; do files+=("$f"); done < <(c_new_files)
  [ "${#files[@]}" -gt 0 ] || return 1
  # While the opening barrier is open, an opening position is WITHHELD from every other
  # participant — that is the whole mechanism. A lane stops at its withheld message rather
  # than skipping it, so nothing is lost and the cursor never runs past unread words.
  local open=false; [ "$(c_barrier)" = open ] && open=true
  local batch
  batch=$(cat "${files[@]}" | jq -s -c --argjson open "$open" --arg me "$ME" "$C_UNTRUSTED"'
    def seqof: (.id | split("-") | last | tonumber);
    _untrusted
    | [ group_by(.from)[]
      | sort_by(seqof)
      | (if $open then
           (. as $g | ($g | map(.round == 0 and .from != $me) | index(true)) as $i
            | if $i == null then $g else $g[0:$i] end)
         else . end)
      | .[] ]
    | sort_by(.lamport, .from)[]') || return 1
  [ -n "$batch" ] || return 1
  printf '%s\n' "$batch"
  # Cursors follow what was RELEASED, not what was found on disk.
  local p hi
  while IFS=$'\t' read -r p hi; do
    [ -n "$p" ] && printf '%s' "$hi" | c_atomic "$ROOM/cursor/$ME/$p"
  done < <(printf '%s\n' "$batch" | jq -s -r '
    def seqof: (.id | split("-") | last | tonumber);
    group_by(.from)[] | [ (.[0].from), (map(seqof) | max) ] | @tsv')
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
  cat "${files[@]}" | jq -s -c "$C_UNTRUSTED"'_untrusted | sort_by(.lamport, .from)[]'
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
# A CLOSED barrier round counts as one whole lap: turn-taking then resumes at lap 1, with
# the rotation already applied, and the opening positions never compete for a turn.
c_turns() {
  local base=0
  if [ "$(c_mode)" = roundtable ] && [ "$(c_barrier)" = closed ]; then base=$(c_npeers); fi
  local n; n=$(c_canon | jq -s '[.[] | select(.hand == false and .turn != null and .valid)] | length')
  echo $(( base + n ))
}

# How many turns have gone by since the last NEW claim; -1 when the room holds no claim.
#
# ONE pass over the canonical log, deliberately. "turns consumed now" and "turns consumed
# when the last claim landed" have to be read from the SAME snapshot, or their difference
# is not a measurement of anything. Deriving the second from the graph's `last_claim_turn`
# got that wrong three separate ways.
#
# It was off by one: `last_claim_turn` is the turn a claim STAMPED, turns are stamped from
# zero, so a claim posted this very instant read as one turn of silence and both thresholds
# fired a whole turn early -- half a lap in a two-peer room.
#
# It could not see a claim that stamps no turn, and two kinds do not: an opening position
# in a barrier round, and anything raised out of turn with `--hand`. A hand-raised
# objection therefore left the window untouched, and `stuck` fired in the very tick that
# objection arrived -- a false alarm on the one signal a supervisor is told to act on,
# which is how a supervisor is taught to ignore it.
#
# And the barrier lap had to be added back by the caller, from a SECOND reading of
# `c_barrier` taken after `c_turns` had already taken its own. Those two disagree if the
# round closes between them, and the counter goes negative. Here the base cancels: both
# counts are on one scale, so it never enters the subtraction at all.
c_turns_since_last_claim() {
  local n
  n=$(c_canon | jq -s '
    reduce .[] as $x ({n: 0, last: null};
      (.n + (if ($x.hand == false and $x.turn != null and $x.valid) then 1 else 0 end)) as $n
      | { n: $n,
          last: (if ($x.act == "propose" or $x.act == "amend" or $x.act == "object")
                 then $n else .last end) })
    | if .last == null then -1 else .n - .last end')
  case "$n" in -1) ;; ''|*[!0-9]*) n=-1 ;; esac
  printf '%s' "$n"
}

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
  local ms
  ms=$(c_canon | jq -s 'map(select(.hand == false and .turn != null and .valid))
                        | if length == 0 then 0 else (max_by(.lamport).sent_ms) end')
  case "$ms" in ''|*[!0-9]*) ms=0 ;; esac
  printf '%s' "$ms"
}

# How many turns claimed a slot somebody else won — the number the supervisor watches.
c_conflicts() {
  c_canon | jq -s '[.[] | select(.hand == false and .turn != null and (.valid | not))] | length'
}
