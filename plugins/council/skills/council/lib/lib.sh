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
export LC_ALL=C
: "${COUNCIL_ROOM:?COUNCIL_ROOM must be set}"
ROOM="$COUNCIL_ROOM"
ME="${COUNCIL_ME:-}"
C_IDLE="${COUNCIL_IDLE:-2}"        # bell-loss fallback, seconds

# The roster never changes while a room lives, so read it once: c_send would
# otherwise pay two jq spawns per message just to learn who to ring.
#
# `roster.json` is a file in the room, so every participant can write it — and what comes out
# of here is INTERPOLATED INTO LANE PATHS by c_new_files, into JSON keys by c_deps_json, and
# word-split by two unquoted `for p in $(c_peers)` loops. Ungated, an `.order` entry of
# `"../../outside"` made `recv` deliver a message read from a file OUTSIDE the room, attributed
# to a peer called `outside`, and wrote a cursor for it. Measured on a two-seat room; a
# hand-edited roster or a template with an odd name is all it takes.
#
# So the roster is validated where it is READ, and all-or-nothing: one unusable entry rejects
# the whole list with a diagnostic, which is what `council relaunch` already does with the same
# rule (see `_plain_name` and the roster block in up.sh). A partial list would be worse than
# none — it silently redefines who the room is.
#
# THE SHAPE OF THE TEST IS THE POINT, and it is chosen against the specific ways an earlier
# attempt at this was defeated. Validate the ENTRIES of the JSON value, inside jq, never the
# lines that `$(jq ...)` prints: command substitution strips a trailing newline and splits an
# embedded one, so an entry of `"a\nb"` becomes two accepted peers and an entry of `"a\n"`
# passes a length check that never sees the byte. And there is deliberately NO ANCHOR here:
# jq's `$` matches before a final newline, so `^[A-Za-z0-9_-]+$` ACCEPTS `"ab\n"` — the exact
# hole that a `^...$` version shipped with. Asking instead whether the string contains a
# character outside the set has no end-of-string semantics to get wrong, so every entry that
# survives is a bare word: no `/`, no `..`, no quote, no glob character, no whitespace, no
# newline. That is what makes the two unquoted `for p in $(c_peers)` loops below safe by
# construction rather than by care.
#
# What this does NOT do, stated because a green guard reads as coverage: two entries differing
# only in case (`a` and `A`) still probe one lane on a case-insensitive filesystem, and an
# exactly duplicated entry still reads its lane twice. Both are pre-existing properties of
# c_new_files, neither is made worse here, and neither is folded away — normalising case would
# change who is in the room without saying so.
_C_PEERS=""
_C_PEERS_RC=""
c_peers() {
  if [ -z "$_C_PEERS_RC" ]; then
    _C_PEERS=$(jq -r '
      if (.order | type) != "array" then empty
      elif (.order | length) == 0 then empty
      elif ([ .order[]
              | select(type == "string" and length > 0 and (test("[^A-Za-z0-9_-]") | not)) ]
            | length) != (.order | length) then empty
      else .order[] end' "$ROOM/roster.json" 2>/dev/null)
    if [ -n "$_C_PEERS" ]; then
      _C_PEERS_RC=0
    else
      _C_PEERS_RC=1
      echo "council: this room's roster has no usable participant list — refusing to read it (a name is letters, digits, '_' and '-')" >&2
    fi
  fi
  [ "$_C_PEERS_RC" = 0 ] || return 1
  printf '%s\n' "$_C_PEERS"
}
c_npeers() { c_peers | wc -l | tr -d ' '; }
c_now()    { date -u +%Y-%m-%dT%H:%M:%SZ; }
# bash 5 gives us sub-second time without spawning anything.
c_ms()     { local t=${EPOCHREALTIME/./}; echo $(( 10#$t / 1000 )); }

# --- trusting nothing another participant wrote ---------------------------------
# Every field below arrives in a file some OTHER participant wrote, so none of it is believed
# on read. A value of the wrong type is treated as ABSENT rather than trusted: `.turn` and
# `.round` fall back to null, `.lamport` and `.sent_ms` to 0, `.refs` to the empty list, and
# `.hand` to a real boolean.
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
# READ THIS BEFORE YOU TRUST IT. What is covered is the six fields above, of a LANE
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
# roster does not list. Neither is fixed here: the first is not an authorship problem at all,
# and the second is the reader divergence recorded on issue #66 and described at c_all.
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
# PATH or as something that must parse. `.to` is written by c_send and read nowhere, which is
# a reason to gate it at the first reader that wants it, not a reason it is safe.
#
# `.refs` is here now, and it is the one field of the six that is coerced for a reason other
# than ordering or arithmetic: an ARRAY is what its readers iterate, and a value of any other
# type ABORTS jq mid-stream. That is not a wrong answer, it is no answer, and the callers
# swallow it -- so the damage lands in the room's durable output. Measured on a two-seat room
# with one live proposal and one real objection, plus one message whose `.refs` was the string
# `"a-1"`: `decide --force` exited 0 having written a record with a blank verdict, both turn
# counts blank, and "(there were no objections)" under the heading whose whole job is to
# record objections -- while the transcript three lines below it showed the objection.
#
# Two readers, and they fail at different widths, which is why the fix belongs HERE and not in
# either of them: claims.jq iterates `.refs` only for `amend` and for a proposer's `concede`,
# so most acts pass through it untouched, while v_transcript's `.refs|join(",")` aborts on
# EVERY act -- and v_transcript renders both the record's transcript and `status`'s last
# messages. One coercion at the reader covers both, and every consumer written after this one.
#
# Coerced to an array OF STRINGS, not merely to an array. `join` converts numbers, booleans
# and nulls, but aborts on an object or an array element, so `map(select(type == "string"))`
# is what makes "after this, `.refs` iterates and joins" true rather than nearly true. Every
# id the room mints is `<peer>-<seq>`, a string; anything else in there was never a reference.
#
# `.lamport` and `.sent_ms` are held to a non-negative INTEGER below 2^53, not to jq's
# "number". Both reach bash: `.lamport` through c_drain's `[ "$seen" -gt "$mine" ]` and
# `.sent_ms` through the floor age in `floor` and `status`. `[` does not evaluate its operands,
# so this was never execution -- it printed `integer expected` and returned 2, which
# short-circuits the `&&` that advances the reader's clock. A single message carrying
# `"lamport": 1.5` therefore left every later reader's clock behind what it had already read,
# silently and for good. 2^53 is where a double stops counting integers exactly, and past it
# jq prints exponent notation (`1E+400`) that no `[ -gt ]` can read; `floor` also normalises
# jq 1.7 literal preservation, so `1e15` comes out as digits rather than as `1E+15`.
C_UNTRUSTED='def _int: if type == "number" and . >= 0 and . < 9007199254740992 then floor else 0 end;
def _untrusted: map(
    .turn    |= (if type == "number" then . else null end)
  | .round   |= (if type == "number" then . else null end)
  | .lamport |= _int
  | .sent_ms |= _int
  | .refs    |= (if type == "array" then map(select(type == "string")) else [] end)
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

# --- surviving a lane file that does not parse ----------------------------------
# jq reads a whole run of files as ONE stream, which is what makes `input_filename` work and
# what both readers below are built on. The price is that a single unparseable byte anywhere
# aborts the run: `recv` came back 4 with its cursor unmoved — permanently, and 4 is the one
# status a participant is explicitly told to retry — while `status`, `verdict`, `claims` and
# the transcript all reported an EMPTY room rather than a broken one.
#
# jq cannot recover from a parse error mid-stream, so the recovery is the caller's: run the
# stream as before, and only IF IT FAILS, ask each file on its own and re-run over the ones
# that answered. A healthy room never reaches this and pays nothing for it — measured rather
# than asserted, by the method of the table at c_all: child CPU per call, 25 calls per size,
# three lanes, one room built once and read from both trees, two runs at 1-minute load ~4:
#
#                  before        this
#     12 messages  6.6 / 6.7     6.9 / 6.6 ms
#     30 messages  9.4 / 9.2     9.3 / 9.5
#     60 messages  13.3 / 13.6   13.6 / 13.6
#    300 messages  46.9 / 44.6   46.7 / 46.5
#
# Read that as "unchanged", which is the only claim it supports: every difference is smaller
# than the spread between two runs of the SAME tree. The added code is one branch that a
# healthy room never takes, so there is nothing here that ought to cost anything — the table
# is here to check that belief, not to advertise a win.
#
# One non-parsing file then costs its own message instead of the whole log, which is exactly
# the trade `select(type == "object")` already makes for a document that parses but is not an
# object. It is deliberately NOT silent: a lane holding bytes nobody can read is a fact about
# the room, and a reader that quietly routes around it hides a corruption that will not repair
# itself.
#
# Retrying is only safe because both programs SLURP — `[ inputs | ... ]` — so a parse error
# aborts before a single value has been emitted. A future rewrite that streams `inputs`
# straight to the output would emit the documents before the bad file and then emit them again
# on the retry; it would have to capture the first attempt instead.
_C_GOOD=()
_c_parseable() { # <file>... -> fills _C_GOOD with the ones jq can read
  _C_GOOD=(); local f
  for f in "$@"; do
    if jq empty "$f" >/dev/null 2>&1; then _C_GOOD+=("$f")
    else echo "council: skipping a lane file that is not readable JSON: $f" >&2; fi
  done
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
  # it was the silent one. Content jq cannot PARSE at all is a different case, and it is
  # covered by the retry below rather than by this filter: a filter runs after a document has
  # been read, and a byte that does not parse is never a document.
  #
  # Deriving the lane as `split("/") | .[-2]` is what keeps the cursor write contained: the
  # value is one component of a split path, so it can never itself contain a `/`. `..` is the
  # one component that still points upward, and one `..` climbs exactly one level -- the write
  # survives because `cursor/<me>/` sits inside the room with a level to spare, so a use of
  # this value directly under the room root would escape and needs its own gate.
  local batch prog
  prog='
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
    | sort_by(.lamport, .from)[]'
  batch=$(jq -n -c --argjson open "$open" --arg me "$ME" "$C_UNTRUSTED$prog" "${files[@]}") \
    || { _c_parseable "${files[@]}"
         [ "${#_C_GOOD[@]}" -gt 0 ] || return 1
         batch=$(jq -n -c --argjson open "$open" --arg me "$ME" "$C_UNTRUSTED$prog" "${_C_GOOD[@]}") || return 1; }
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
#
# `[ -p ]` before the open, because `exec 3<>` SUCCEEDS on a regular file and the read that
# follows then returns instantly at EOF instead of sleeping -- and that read is the only sleep
# in v_recv's loop. A room whose bells are ordinary files does not fail; it spins for the
# whole timeout. Measured over an identical 3-second `recv`, child CPU user/sys: 0.038/0.070
# with a real fifo, 0.868/1.683 with a regular file in its place.
#
# Nothing repairs a bell that stopped being a fifo: `_mkroom` writes one only when there is no
# `-p` there, and it does not run again over a live room. An archive-and-restore of a room
# directory, or any copy that does not preserve fifos, produces exactly this -- so the reader
# has to survive it rather than assume it away. Falling back to a real sleep makes bell loss
# degrade to the poll this transport already documents as its fallback (C_IDLE above), which
# is the behaviour a participant gets anyway when a bell is merely missed.
_C_BELL=0
# NO redirection on the `exec` below, however tempting `2>/dev/null` looks on a line that can
# fail. `exec` with no command applies its redirections to the CURRENT SHELL and KEEPS them:
# a `2>/dev/null` here silences the whole process for the rest of its life, and the first
# version of this function did exactly that — every later diagnostic in a `recv`, including
# the one three lines down and jq's own account of an unreadable lane file, went to
# /dev/null. Caught by a test that asserted a message reached stderr; nothing else would have.
c_bell_open() {
  if [ -p "$ROOM/bell/$ME.fifo" ] && exec 3<> "$ROOM/bell/$ME.fifo"; then
    _C_BELL=1
  else
    _C_BELL=0
    echo "council: $ROOM/bell/$ME.fifo is not a fifo — polling instead of waiting on the bell" >&2
  fi
}
c_bell_wait() {
  if [ "$_C_BELL" = 1 ]; then read -r -t "${1:-$C_IDLE}" -N 1 -u 3 _ 2>/dev/null
  else sleep "${1:-$C_IDLE}"; fi
  return 0
}
c_bell_drain() { while read -r -t 0 -u 3 2>/dev/null && read -r -t 0.01 -N 1 -u 3 _ 2>/dev/null; do :; done; }

# --- total order / floor --------------------------------------------------------
# Every message in the room, in the one order everybody agrees on.
c_all() {
  local -a files=(); local f
  for f in "$ROOM"/lane/*/[0-9]*.json; do [ -e "$f" ] && files+=("$f"); done
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
  # It is also CHEAPER than the `cat` it replaced, at every size — one fewer process to spawn,
  # worth more than jq's extra per-file opens. Child CPU per call, 25 calls per size, three
  # lanes, this function sourced from each tree, two runs at 1-minute load ~17-19 (the load is
  # stated because it moves the absolutes a lot and the comparison not at all):
  #
  #                  before        this
  #     12 messages  11.8 / 14.6   9.6 / 8.7 ms
  #     30 messages  14.8 / 13.5   12.4 / 12.4
  #     60 messages  20.0 / 17.8   16.6 / 16.2
  #    300 messages  58.5 / 52.8   53.9 / 48.5
  #
  # Take the method as seriously as the numbers: three earlier versions of this table were
  # wrong. The first measured wall clock on a box at load 211 with another suite running, where
  # wall clock measures the queue and not the work. The second measured CPU correctly but
  # measured a version of this function that had not yet grown a roster read, and so reported a
  # win the shipped code did not have. The third claimed c_floor_at had dropped a jq exec; a
  # PATH shim counting execs showed it had not. Measure the function AS COMMITTED, say what the
  # machine was doing, or put no number here at all.
  #
  # THE LANE SET IS THE GLOB, and that is a deliberate choice rather than an oversight. It
  # differs from c_drain, which builds its list from `roster.order` via c_new_files, so the two
  # readers do NOT agree about which lanes are the room: a lane directory the roster does not
  # list shows up here -- in transcript, claims and verdict -- while `recv` never delivers a
  # word of it to anybody. Renaming a peer in roster.json orphans its lane exactly that way.
  # That divergence is real and is recorded on issue #66; it is NOT fixed here.
  #
  # It was fixed here once, by taking the lane set from `roster.order` to match c_drain, and
  # that was reverted after four review rounds. The reason is worth keeping, because the fix
  # looks obviously right and is not: `roster.json` is writable by every participant, so making
  # it decide which paths this function OPENS turns an untrusted, unnormalised string list into
  # both a set of filesystem paths and a positionally-indexed array. Each round found the next
  # layer of that -- a `..` entry reading files from outside the room; duplicate entries reading
  # one lane many times; a malformed roster blanking every reader while `decide --force` wrote a
  # durable record saying "(there were no objections)"; then, in the gate written to stop all
  # three, an entry containing a newline splitting into several accepted peers, and finally a
  # single TRAILING newline surviving because jq's `$` matches before a final newline and `$( )`
  # strips what the length check would have caught. Two of those ended in a false decision
  # record at rc 0, which is the worst outcome this codebase has.
  #
  # The glob has none of those properties to get wrong: it enumerates real directories, so it
  # cannot escape `lane/`, cannot name the same lane twice, and cannot be case-confused on a
  # case-insensitive filesystem. Anyone reopening this should start from that, and should
  # expect the validation -- not the substitution -- to be where the difficulty is.
  #
  # The derived value is only ever printed and compared here, never used as a path, and the
  # glob cannot produce `..` or a dotfile, so it is a real directory name under `lane/`. A
  # future use of it AS A PATH would need c_drain's reasoning about `..` re-done from scratch.
  #
  # Same document gate as c_drain, for the same reason and one more: every caller of c_all
  # swallows its failure (`c_all 2>/dev/null || true`), so ONE non-object document in any lane
  # used to make status, verdict, claims and the transcript report an EMPTY room rather than a
  # broken one. Skipping the document costs one message; aborting costs the whole log. It is
  # also what stops a bare trailing scalar in one lane file being attributed to the NEXT one:
  # jq does not reset its parser at a file boundary, so such a value stays open until the next
  # file's first token and `input_filename` then reports that next file. c_drain carries the
  # full account of that; it applies verbatim here, and now for `.from` as well.
  #
  # And the retry, for the case the filter above cannot reach: a byte that does not PARSE is
  # never a document, so no filter runs on it. See _c_parseable — including why writing this
  # attempt's output straight to stdout stays correct.
  local prog='[ inputs
      | select(type == "object")
      | .from = (input_filename | split("/") | .[-2]) ]
    | _untrusted | sort_by(.lamport, .from)[]'
  jq -n -c "$C_UNTRUSTED$prog" "${files[@]}" && return 0
  _c_parseable "${files[@]}"
  [ "${#_C_GOOD[@]}" -gt 0 ] || return 1
  jq -n -c "$C_UNTRUSTED$prog" "${_C_GOOD[@]}"
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
  # A room with no readable participant list has no floor to compute, and both lines below
  # divide by this count. That is an arithmetic precondition rather than a second gate on the
  # roster: c_peers has already refused the list and said why on stderr, and `$(( t / 0 ))`
  # would answer it with `division by 0` followed by an unbound `$idx` under `set -u` — a
  # crash whose message names neither the room nor the roster. Returning empty here reaches
  # the callers as "the floor is nobody's", which is what they already print for this room.
  [ "$n" -gt 0 ] || return 1
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

# How long this room has existed, in seconds — or NOTHING, which means "this room cannot say".
#
# It exists for one reason: `sent_ms` above is written by another participant, and a floor age
# derived from it is only as good as that peer's clock. One message stamped with a tiny
# `sent_ms` made `status` report `STALL: <peer> has held the floor for 1787859798s` — a false
# alarm on the ONE signal a supervisor is told to act on, which is how a supervisor is taught
# to ignore it. A held time longer than the room has existed is not a long wait; it is
# evidence that the clock which produced it is wrong, and the caller reports it as that.
#
# `created_ms` is written once, by `up`, when the room is created, and NOTHING refreshes it —
# not `relaunch`, not a later `up`. That is load-bearing rather than incidental: a refreshed
# timestamp makes the room permanently young, every held time then exceeds its age, and the
# STALL alarm is suppressed for good. Suppressing a true alarm is worse than raising a false
# one, so the value must only ever be able to make this function's answer OLDER.
#
# Empty for a room created before this was recorded, and for a `created_ms` that is not a
# plausible past instant. Both keep the caller's previous behaviour exactly, which is what
# lets an old room go on working rather than start reporting a clock problem it does not have.
c_room_age_s() {
  local ms now
  ms=$(c_int_field created_ms 0)
  [ "$ms" -gt 0 ] || return 1
  now=$(c_ms)
  # A room stamped in the future says nothing about how long anything has been held.
  [ "$now" -gt "$ms" ] || return 1
  printf '%s' $(( (now - ms) / 1000 ))
}

# How many turns claimed a slot somebody else won — the number the supervisor watches.
c_conflicts() {
  c_canon | jq -s '[.[] | select(.hand == false and .turn != null and (.valid | not))] | length'
}
