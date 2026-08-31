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
#   * total order is (lamport, from) -- `lamport` carried IN the message, `from` taken from
#     the lane the file was read at -- so every reader derives the same sequence without
#     asking anyone;
#   * the room's membership is `roster.order`, and BOTH readers build their file list from
#     it, so a lane directory the roster does not list is not part of the room.
export LC_ALL=C
: "${COUNCIL_ROOM:?COUNCIL_ROOM must be set}"
ROOM="$COUNCIL_ROOM"
ME="${COUNCIL_ME:-}"
C_IDLE="${COUNCIL_IDLE:-2}"        # bell-loss fallback, seconds

# What a peer may be called. `up.sh` validates a room's names with this same rule when the room
# is created; this is the canonical definition and up.sh falls back to its own copy only on the
# one path that has no room yet (`up` and `rooms` source up.sh WITHOUT this file).
#
# The character class is what makes a name safe to put in a path: no `/`, and no `.`, so a name
# can be neither a separator nor `..`.
_plain_name() { case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; *) return 0 ;; esac; }

# The roster's peer list — the room's MEMBERSHIP, and the source both readers build their file
# lists from. Read once per shell: c_send would otherwise pay two jq spawns per message just to
# learn who to ring.
#
# `roster.json` is in the room like every other file, so every participant can write it, and
# what it says now decides which paths a reader OPENS. It is therefore gated, all-or-nothing:
# `.order` must be an array, every entry must be a string, and every entry must be a plain name.
# Anything else means the room has NO MEMBERSHIP — not a shortened one.
#
# All-or-nothing is the whole point, and dropping only the bad entries would be worse: c_npeers
# and c_floor_at index `.order` POSITIONALLY, so removing one entry silently rotates the floor
# to a different peer. A room whose roster cannot be read has no floor to compute, and quietly
# computing a different one is exactly the class of divergence this file exists to remove.
#
# Failing this way is "fail closed and visible": the read-only verbs keep working, so a corrupt
# room can still be diagnosed from inside; `status` raises an alarm; and `decide` REFUSES to
# write a record it cannot populate. That last one is the symptom that mattered — before the
# gate, a malformed `.order` made `decide --force` exit 0 having written a durable record
# saying "(there were no objections)" while an objection was open.
_C_PEERS=""
# Load into THIS shell. Call this, not `$(c_peers)`, on a hot path: a command substitution forks,
# and that fork is also why the memo never worked — the assignment landed in a subshell that then
# exited, so every reader paid the jq again.
_c_peers_load() {
  [ -n "$_C_PEERS" ] && return 0
  local raw p
  # One jq: the array-and-all-strings half. `select` would silently DROP a non-string and
  # shorten the list, so the test is over the whole array and emits nothing when it fails.
  raw=$(jq -r 'if (.order | type) == "array" and (.order | map(type == "string") | all)
               then .order[] else empty end' "$ROOM/roster.json" 2>/dev/null)
  if [ -n "$raw" ]; then
    while IFS= read -r p; do
      _plain_name "$p" || { raw=""; break; }
    done <<EOF
$raw
EOF
  fi
  _C_PEERS="$raw"
  [ -n "$_C_PEERS" ]
}
c_peers()  { _c_peers_load || true; printf '%s\n' "$_C_PEERS"; }
# Usable roster? False for malformed AND for empty — both mean the room has no membership.
c_roster_ok() { _c_peers_load; }
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
# and the `roster.json` numerics in c_quorum, c_barrier and v_verdict.
#
# FOUR of those were a live way to run a command in a reader's shell until they were gated:
# the four that reach `$(( ))`, which EVALUATES -- `state/*.lamport`, `state/*.seq`,
# `cursor/*` and `round_deadline_ms`. `round_quorum` and `turns_budget` reach only a
# `[ -lt ]` / `[ -ge ]`, and `[` does NOT evaluate its operands: it prints `integer expected`
# and returns 2. They are gated against the same type confusion, but they were never
# execution. Do not tidy either test into `(( ))` OR `[[ ]]` -- both evaluate, so either
# conversion would turn a diagnostic into a shell. Measured, all three forms.
#
# Two message fields are consumed STRUCTURALLY rather than numerically, so no amount of
# coercion here would have covered them: `.from` and `.id`. Both are handled by taking the
# value from the PATH the file was read at instead of from the message -- but not to the same
# extent, and the difference matters:
#
#   `.from` is overwritten in BOTH readers, c_drain and c_all, so no consumer anywhere sees
#   the message's own claim about its author.
#   `.id`'s SEQUENCE role is replaced in c_drain only, where it decides a cursor position.
#   c_all needs no sequence and derives none, so `.id` reaches every other consumer exactly
#   as the message wrote it.
#
# `.from` is the AUTHOR, and it is now DERIVED, not believed: every reader overwrites it
# with the lane directory the document was read from. A lane has exactly one writer, so the
# lane IS the author, and the room's mechanical rules finally rest on who actually wrote a
# message rather than on what the message says about itself. That is what makes the claim at
# the top of SKILL.md -- "the outcome is computed, not declared" -- true. It was not before:
# `.from` is claims.jq's whole rule for who may close an objection and who may kill a
# proposal, so a participant writing `"from": "<peer>"` into its OWN lane withdrew somebody
# else's proposal and the transcript recorded the victim as having done it.
#
# WHICH ACCIDENTS THIS ACTUALLY COVERS, stated narrowly because the obvious wider claim is
# false. It covers anything that writes a lane FILE without going through c_send: an agent
# that emits the JSON itself rather than calling `send`, one that copies a message it just
# read out of `recv` and re-sends it with the original `.from` intact, a hand-edited file, a
# harness that constructs lane files.
#
# It does NOT cover a seat running with a stale or wrong COUNCIL_ME, though that reads like
# the same thing and was claimed as a motivation for this change. c_send takes the lane PATH
# and `.from` from the same `$ME` (see below), so such a seat writes into the stale lane with
# a MATCHING `.from` -- lane and claim agree, and deriving one from the other changes nothing.
# What a stale COUNCIL_ME really does is write into another seat's lane, or into a lane the
# roster does not list; the second of those is what c_all's roster filter and the `status`
# alarm now catch, and the first is not fixed here at all.
#
# It must be BOTH readers or neither. c_drain feeds `recv`; c_all feeds verdict, status,
# claims, transcript and decide. Deriving in one only would render the same message under
# two different authors depending on which path you came through, and somebody comparing
# `recv` with `transcript` would be debugging a bug that is not there.
#
# `.id` used to be parsed for a sequence number and is likewise taken from the path there. It
# remains a message's own unverified CLAIM in every other position, and that has NOT
# changed: `.id` is still c_canon's winner key -- `($win | index($m.id))` decides whether a
# message counts as valid -- still what c_posted_round0 returns, and still the target of every
# `.refs` lookup in claims.jq. It may not be read as an authenticated anything.
#
# A forged `.id` is worse than "one message is wrongly counted valid", which is how this was
# first written. Duplicating a turn winner's id makes BOTH messages read as valid, so the turn
# count is inflated and the floor advances an extra step -- and because c_conflicts counts
# exactly the messages that lost a turn conflict, the duplicate loses nothing and the
# `⚠️ messages lost a turn conflict` alarm never fires. That alarm is the one a supervisor is
# told to watch for precisely this, so the room misreports and says nothing.
#
# What derivation does NOT buy: `.from` is trustworthy as "which lane wrote this", which is
# not the same as "which agent session wrote this". Nothing stops one seat from writing into
# another seat's lane; the room is not a trust boundary (SKILL.md says so at length) and this
# does not make it one. What it removes is a whole class of ACCIDENT, and with it the gap
# between what the room documents and what it computes.
#
# So: adding an arithmetic use of anything that did not come through `_untrusted` or one of
# those readers still needs its own gate, and so does any new use of a message field as a
# PATH or as something that must parse. `.refs` is not coerced here either, and a wrong-typed
# one still aborts claims.jq and the transcript. `.to` is written by c_send and read nowhere,
# which is a reason to gate it at the first reader that wants it, not a reason it is safe.
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
# Every file read here lives in a room every participant can write, so the single-writer
# invariants at the top of this file are a protocol rule the filesystem does not enforce:
# these are MY files, and a peer that ignores the rule can still put anything in them. The
# results reach `$(( ))` in c_send and in c_new_files, and `$(( ))` EVALUATES what it is
# handed rather than merely parsing it. So an integer gate is the DEFAULT, not something each
# numeric caller remembers: a reader added later that reaches for c_slurp is safe without
# knowing this, and the one caller that wants a WORD has to ask for c_slurp_raw by name.
# Wrong-typed is treated as ABSENT (0), the same rule _untrusted applies to a lane message.
#
# `10#` is the second half of the gate and not decoration, because digits alone are not an
# integer to bash. Both effects are measured, on bash 5.3:
#
#   `$(( 010 + 1 ))` is 9, not 11: a leading zero means OCTAL, so the value is read too LOW.
#   In a cursor that means messages the reader has already consumed are handed to it AGAIN
#   -- re-delivery, not loss, since octal can only ever under-read the same digits.
#
#   `$(( 08 + 1 ))` is an error instead, because 8 is not an octal digit. What it COSTS is
#   what matters, and that is given here as observed behaviour rather than as a rule about
#   bash: three attempts to state the mechanism were each wrong in a different way, and a
#   confident wrong sentence in this block is worse than no sentence. Observed, on bash 5.3,
#   running this code with the gate removed:
#
#     in c_send -- no lane file is written, and `state/<me>.seq` is left holding the poison,
#     so that seat cannot speak again until someone repairs it by hand.
#
#     in c_new_files, which runs inside the `< <( )` feeding c_drain -- the poisoned peer and
#     every peer AFTER it in roster order drop out of the file list. That is the whole list
#     whenever the poisoned peer is the first to emit, which in a room of two always holds,
#     so c_drain reports an empty inbox and that lane goes deaf.
#
#   Both print the same diagnostic on stderr, so noise is not what separates them. What does
#   is the status the caller sees: `send` returns 1, an obvious failure, while `recv` returns
#   4 -- which council.sh's usage and protocol/_channel.md both document as "timeout, call
#   again", the one status a participant is explicitly told to retry and NOT to treat as an
#   error. That is what makes the drain half the dangerous one.
#
#   c_ms above already carries this idiom for exactly the same reason.
c_slurp()   { local v=""; [ -f "$1" ] || { printf 0; return; }; read -r v < "$1" 2>/dev/null
              case "$v" in ''|*[!0-9]*) v=0 ;; *) v=$((10#$v)) ;; esac; printf '%s' "$v"; }
# Verbatim, for the one room file that legitimately holds a word rather than a number:
# board/status, compared as decided|unresolved by c_recorded_status below. A numeric gate here
# would map BOTH words onto 0; no value would then match that comparison, and every room that
# has genuinely closed would report itself OPEN for ever -- `verdict` and `status` would never
# return the 0 a supervising session waits on. Nothing may do arithmetic on this.
c_slurp_raw() { local v=""; [ -f "$1" ] || { printf 0; return; }; read -r v < "$1" 2>/dev/null; printf '%s' "${v:-0}"; }
c_lamport() { c_slurp "$ROOM/state/$ME.lamport"; }

# The room's recorded outcome: `decided`, `unresolved`, or EMPTY for a room that is still open.
# Shared by `verdict` and `claims`, so those two answer alike. `decision` deliberately does NOT
# come through here: it reports whether the record FILE is there to print, which is a different
# question from whether the room is closed, and it must keep working on a half-written one.
#
# It lives here, shared, because the alternative has already failed: when only v_verdict was
# taught this rule, v_claims went on announcing "DECIDED by message <id>" from the mere
# presence of a `decide` message, and one room answered `deliberating` and `DECIDED` in the
# same breath. A rule that has to be remembered by each caller is a rule that holds until the
# next caller.
#
# BOTH halves are required, and each rules out a real state:
#
#   the RECORD -- `board/decision.md` is the room's output, and without it there is nothing to
#   have closed. A `board/status` written on its own would otherwise report a room decided
#   while `decision` says it is open, and `decide` would then refuse with "already decided",
#   so no record could ever be written through the entrypoint: a wedge with no way out.
#
#   the STATUS WORD -- it says WHICH way it closed, and only v_decide writes it, after the
#   record is complete. Absent, unreadable, or holding anything else means NOT CLOSED and the
#   room falls through to its computed verdict; an unrecognised value is treated as absent,
#   the same rule every other untrusted room input follows. `board/status` is in the room like
#   every other file, and the old reader passed whatever it held straight through as the
#   verdict word -- `yes` and `DECIDED` both reached a supervisor as if they were verdicts.
#
# The decide MESSAGE is deliberately not part of this. v_decide sends it last, after both
# files, and that send can legitimately fail -- c_send refuses a sender that does not hold the
# floor, the ordinary case for `decide --force` on a stuck room, and v_decide does not check
# it. Requiring the message is what the code did before, and it left a room that had genuinely
# closed as `unresolved`, record on disk, reporting `deliberating` for ever. So the same reader
# broke the rule in both directions: closed when it was not, and open when it was.
c_recorded_status() {
  # -s, not -f: a record of zero bytes is not a record. `v_decide` opens it with `> "$out"`,
  # which CREATES it the instant the redirect opens, so a decide that dies part-way leaves the
  # file behind; with `-f` the room then read `decided` rc 0 while `decision` printed nothing.
  [ -s "$ROOM/board/decision.md" ] || { printf ''; return; }
  local v; v=$(c_slurp_raw "$ROOM/board/status")
  case "$v" in decided|unresolved) printf '%s' "$v" ;; *) printf '' ;; esac
}
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
# alternative operator untouched.
#
# Nor is asking jq for `type == "number"` enough on its own: a JSON number is not a bash
# integer. `1.5` and `1e400` are both numbers to jq, and both are fatal to `$(( ))` -- and a
# c_barrier that dies mid-function prints NEITHER `open` nor `closed`, so every
# `[ "$(c_barrier)" = open ]` in the room reads false at once and the opening barrier
# silently ceases to exist.
#
# It takes BOTH tests, because each is blind to what the other catches. jq's type test is the
# only thing that can tell the string "30" from the number 30 -- `jq -r` renders them
# identically, so a digits test alone accepts the string. The digits test is the only thing
# that can tell 30 from 1.5 or 1e400 -- all three are `type == "number"`. Anything that fails
# either test is treated as ABSENT and takes the default.
c_int_field() { # <field> <default>  -- a roster integer, or the default if it is not one
  local v; v=$(jq -r --arg k "$1" 'if (.[$k]|type) == "number" then .[$k] else empty end' \
                  "$ROOM/roster.json" 2>/dev/null)
  case "$v" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' $((10#$v)) ;; esac
}
c_quorum() { c_int_field round_quorum ''; }

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
  deadline=$(c_int_field round_deadline_ms 600000)
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
  # WHO a message is from, WHICH LANE it came from and WHERE IN THAT LANE it sits are taken
  # from the PATH it was read at, never from the message. The path is chosen by the READER --
  # c_new_files builds it -- rather than supplied by the thing being read, which is the
  # property that matters here; it is NOT that the path is beyond a peer's reach, because
  # c_new_files builds it out of `roster.order`, and the roster is in the room like everything
  # else. All three of those USES -- two fields, one of them used two ways -- were consumed
  # structurally rather than numerically, so the coercion in _untrusted did not and could not
  # cover them:
  #
  #   `.from` is the author, and OVERWRITING it here is what makes the room's mechanical
  #   rules rest on who wrote a message rather than on what it claims (see the long note at
  #   the head of this file). c_all does the same, and it has to: the two readers disagreeing
  #   would render one message under two authors.
  #
  #   `.from` was also interpolated into the cursor path. A participant that wrote
  #   `"from": "../../../x"` into its OWN lane made the READER create or truncate that file,
  #   with the reader's credentials. It also decided grouping, so claiming a peer's name
  #   merged two lanes and advanced the wrong cursor past unread messages.
  #
  #   `.id` was parsed as `split("-") | last | tonumber`, which is FATAL for jq on
  #   `"noDashHere"`, `"a-x"`, `17`, `null` or `["a-1"]`. jq exited non-zero, the batch came
  #   back empty, and recv reported an empty inbox -- so the cursor never advanced, the
  #   poisoned file was re-read on every later call, and every honest message behind it in
  #   that lane was never delivered. Silently: status, verdict, claims and transcript all
  #   kept working, because none of them uses this parse. A supervisor saw a healthy room
  #   with one deaf participant, which is precisely what the `stuck` alarm cannot show.
  #
  # `input_filename` under `-n` + `inputs` is per-DOCUMENT, so this stays correct even when a
  # peer puts several documents in one lane file.
  #
  # `select(type == "object")` is what makes that true, and it is NOT a tidy-up. jq does not
  # reset its parser at a file boundary: a value whose end is only knowable at EOF -- a bare
  # `null`, `true`, `false` or number with no trailing delimiter -- stays open until the NEXT
  # file's first token closes it, and `input_filename` then reports that next file. So a peer
  # appending four bytes to its own lane could hand a ghost document to a VICTIM's lane and
  # advance the reader's cursor past a message it never saw. `null` is the silent one, since
  # `null + {...}` succeeds in jq where a number or a boolean errors. An object, an array and
  # a string all self-terminate, so dropping everything else removes the vector entirely; it
  # also means one non-object document costs its own message rather than the lane. `null` is
  # the one shape that was never fatal here -- `null + {...}` succeeds, which is exactly why
  # it was the silent one. Content jq cannot PARSE at all is a different case and is still
  # not covered: it aborts the whole batch, as it did before this change.
  #
  # Deriving the lane as `split("/") | .[-2]` is what keeps the cursor write contained: the
  # value is one component of a split path, so it can never itself contain a `/`. `..` is the
  # one component that still points upward, and one `..` climbs exactly one level -- the write
  # survives because `cursor/<me>/` sits inside the room with a level to spare, so a use of
  # this value directly under the room root would escape and needs its own gate.
  local batch
  batch=$(jq -n -c --argjson open "$open" --arg me "$ME" "$C_UNTRUSTED"'
    [ inputs
      | select(type == "object")
      | . + { _lane: (input_filename | split("/") | .[-2])
            , _seq:  (input_filename | split("/") | .[-1] | sub("\\.json$"; "") | tonumber) }
      | .from = ._lane ]
    | _untrusted
    | [ group_by(._lane)[]
      | sort_by(._seq)
      | (if $open then
           (. as $g | ($g | map(.round == 0 and ._lane != $me) | index(true)) as $i
            | if $i == null then $g else $g[0:$i] end)
         else . end)
      | .[] ]
    | sort_by(.lamport, .from)[]' "${files[@]}") || return 1
  [ -n "$batch" ] || return 1
  # `_lane` and `_seq` are this function's own bookkeeping, not part of a message: strip them
  # before anyone sees them, so the shape a participant reads is unchanged.
  printf '%s\n' "$batch" | jq -c 'del(._lane, ._seq)' || return 1
  # Cursors follow what was RELEASED, not what was found on disk.
  local p hi
  while IFS=$'\t' read -r p hi; do
    [ -n "$p" ] && printf '%s' "$hi" | c_atomic "$ROOM/cursor/$ME/$p"
  done < <(printf '%s\n' "$batch" | jq -s -r '
    group_by(._lane)[] | [ (.[0]._lane), (map(._seq) | max) ] | @tsv')
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
  local -a files=(); local p f seen
  # The lane SET comes from the ROSTER, not from a glob of `lane/*/`, and that matters as much
  # as where the author comes from. c_drain has always built its file list from `roster.order`
  # (via c_new_files), so a glob here made the two readers disagree about who is IN the room
  # even once they agreed about who wrote what: a lane directory the roster does not list
  # appeared in transcript, claims and verdict while `recv` never delivered a word of it to
  # anybody. Nobody could read it, nobody could answer it, and only the ungated `overrule`
  # could close an objection raised in it -- so the room could not reach ready-to-decide.
  #
  # It is reachable by ordinary accident, not just by `mkdir`: rename or remove a peer in
  # `roster.json` and its existing `lane/<old>/` is orphaned on the spot, and a seat still
  # running under that name goes on writing into it. A name that was NEVER in the roster does
  # not produce this -- c_send fails outright, because the lane directory does not exist -- so
  # the accident is specifically a name the roster USED to list.
  #
  # The roster is the room's membership, so the roster wins. What must never happen is that
  # such a lane goes SILENT: c_unrostered below counts them and `status` raises an alarm, so a
  # reader can tell "no such message" from "a message exists that this room no longer counts".
  #
  # `_c_peers_load` rather than `$(c_peers)`: this is the hot path of every send, and the
  # command substitution was both a fork and the reason the memo never worked.
  #
  # DE-DUPLICATED, because the glob this replaced deduplicated by construction and the roster
  # does not. A repeated name in `.order` otherwise reads that lane's messages once per entry:
  # the transcript doubles, `c_turns` inflates, `live` climbs past the one proposal
  # `ready-to-decide` requires, and with enough entries the room crosses its turn budget and
  # reports `unresolved` with rc 0 — closed, to a supervisor — having written no record.
  #
  # The `case` is the second half of the path gate. `_plain_name` already rejects `/` and `.`
  # in c_peers, so a name reaching here cannot be `..` or contain a separator; this makes the
  # containment hold at the point of USE as well, so neither end is load-bearing alone. Before
  # both existed, a `.order` entry of `"../../outside"` made this loop read `[0-9]*.json` from
  # outside the room and splice it into the transcript, the claims graph and the record.
  _c_peers_load || true
  seen=" "
  for p in $_C_PEERS; do
    case "$p" in ''|.|..|*/*) continue ;; esac
    case "$seen" in *" $p "*) continue ;; esac
    seen="$seen$p "
    for f in "$ROOM"/lane/"$p"/[0-9]*.json; do [ -e "$f" ] && files+=("$f"); done
  done
  [ "${#files[@]}" -gt 0 ] || return 1
  # The author comes from the LANE DIRECTORY, exactly as in c_drain and for the same reason:
  # `.from` is a claim a message makes about itself, and everything downstream of here --
  # verdict, status, claims, transcript, the decision record -- treats it as the author. This
  # is the reader those consumers come through, so this is where the claim has to stop being
  # believed. Doing it in c_drain alone would give `recv` and `transcript` different authors
  # for one message.
  #
  # That is why the files are handed to jq as ARGUMENTS rather than `cat`ed into it: only
  # `inputs` under `-n` gives `input_filename`, and it is per-DOCUMENT, so a peer putting
  # several messages in one lane file has every one of them attributed to that lane.
  #
  # THIS FUNCTION IS SLOWER THAN THE ONE IT REPLACED, and the correctness argument is what
  # carries it. Child CPU per call, 25 calls per size, three lanes, the real function sourced
  # from each tree (1-minute load ~9-10, stated because it moves the absolute numbers a lot
  # and the comparison not at all):
  #
  #                  before      cat->jq args only     as it stands
  #     12 messages   9.4 ms          8.2 ms            12.6 ms
  #     30 messages  12.2 ms         10.3 ms            15.9 ms
  #     60 messages  15.9 ms         13.6 ms            19.5 ms
  #    300 messages  46.3 ms         45.2 ms            48.9 ms
  #
  # Two changes pulling opposite ways. Handing jq the files instead of `cat`ing them is a win
  # at every size -- one fewer process, worth more than jq's extra opens. Reading the roster
  # gives that back and more: ~4 ms, and it is the JQ EXEC, measured against the alternatives
  # rather than assumed. The validation loop costs nothing over the bare read (4.22 vs 4.38 ms,
  # i.e. noise) and calling `_c_peers_load` instead of `$(c_peers)` saves only the fork, 0.33 ms.
  # There is no cheap version of "ask roster.json who is in the room" while it is read per call.
  #
  # It is on the hot path of every send (c_max_lamport, c_barrier, c_turns all come through
  # here), so this is a real cost, not a rounding error. It buys: an author that cannot be
  # forged, a lane set both readers agree on, and a roster that cannot point a reader outside
  # the room. If that trade is ever revisited, memoising the roster ACROSS calls is the lever --
  # `_C_PEERS` only survives within one shell, and most callers sit inside a command
  # substitution -- not going back to the glob, which loses input_filename and the whole
  # property this function exists to provide. A cheaper derivation is not the lever either:
  # `sub`-based trimming measured ~50% WORSE than the split, and memoising the filename per
  # file bought nothing over deriving it per document.
  #
  # Two earlier versions of this table were wrong, in OPPOSITE directions, and both are left
  # named here rather than quietly replaced. The first measured wall clock on a box at load 211
  # with another suite running and reported a pure slowdown; on a loaded box wall clock measures
  # the queue, not the work. The second measured CPU correctly but measured the function BEFORE
  # the roster read was added to it, and so reported a win that the shipped code does not have.
  # Measure the function as it is committed, or do not put a number here.
  #
  # The derived value is only ever printed and compared here, never used as a path, unlike
  # c_drain's cursor write.
  #
  # Do NOT read that as containment, and do not repeat the argument this comment used to make.
  # It said `lane/*/` cannot glob `..` or a dotfile so the value is a real directory under
  # `lane/` -- true of the glob, and this function no longer uses one. The path component now
  # comes from `roster.order`, which is in the room like everything else, so c_drain's honest
  # framing applies here too: what makes it safe is the gate in c_peers plus the `case` above,
  # not the shape of a glob. A future use of it AS A PATH still needs its own reasoning.
  #
  # Same document gate as c_drain, for the same reason and one more: every caller of c_all
  # swallows its failure (`c_all 2>/dev/null || true`), so ONE non-object document in any lane
  # used to make status, verdict, claims and the transcript report an EMPTY room rather than a
  # broken one. Skipping the document costs one message; aborting costs the whole log. It is
  # also what stops a bare trailing scalar in one lane file being attributed to the NEXT one:
  # jq does not reset its parser at a file boundary, so such a value stays open until the next
  # file's first token and `input_filename` then reports that next file. c_drain carries the
  # full account of that; it applies verbatim here, and now for `.from` as well.
  jq -n -c "$C_UNTRUSTED"'[ inputs
      | select(type == "object")
      | .from = (input_filename | split("/") | .[-2]) ]
    | _untrusted | sort_by(.lamport, .from)[]' "${files[@]}"
}

# Lanes on disk that the roster does not list, and how many messages they hold.
# Prints "<lanes> <messages>".
#
# This is the other half of c_all's roster filter, and it is not optional decoration. Filtering
# without reporting would trade a visible wrong state -- a ghost peer speaking in the transcript
# -- for an invisible one, which is the failure this codebase keeps having: a room that looks
# healthy while something in it is lost. `status` turns this into an alarm.
#
# Deliberately NOT on the hot path: only `status` calls it, once, so the fork per lane costs
# nothing that matters. c_all must stay cheap.
c_unrostered() {
  local d p n=0 m=0 f known
  known=$(c_peers)
  for d in "$ROOM"/lane/*/; do
    [ -d "$d" ] || continue
    p=${d%/}; p=${p##*/}
    # Matched in bash, not with `grep -F`. grep treats a MULTI-LINE pattern as several
    # alternatives, so a lane directory named $'a\nghost' matched the rostered peer `a` and
    # escaped the alarm entirely -- the exact opposite of what a whole-line literal match is
    # for. Wrapping both sides in newlines makes this exact for any byte sequence, and it drops
    # a fork per lane as well.
    case $'\n'"$known"$'\n' in *$'\n'"$p"$'\n'*) continue ;; esac
    n=$((n + 1))
    for f in "$d"[0-9]*.json; do [ -e "$f" ] && m=$((m + 1)); done
  done
  printf '%s %s' "$n" "$m"
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
