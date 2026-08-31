#!/usr/bin/env bash
# t9b — a lane file is written by another participant, so nothing in it is trusted on read.
#
# Two separate failures, one rule. A message whose `.turn` is a string used to reach bash
# arithmetic, and `$(( ))` EVALUATES what it is handed: a crafted lane file ran commands in
# the shell of whoever read the room. And even without an exploit, jq sorts strings ABOVE
# numbers, so one wrong-typed field wins every `max` and `sort_by` and quietly takes the
# room's ordering over.
#
# These messages cannot be produced by `send` -- that is the point. They are written
# straight into a lane, which is exactly what a hostile or buggy participant can do, since
# every participant already holds a writable path to the room.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
R="$COUNCIL_TEST_ROOT/t9b-untrusted"; rm -rf "$R"
mkroom "$R" a b
export COUNCIL_ROOM="$R" ROOM="$R"
echo "Does the room trust what it reads?" > "$R/agenda.md"
fail=0

# A lane message with one field of our choosing, bypassing send entirely.
craft() { # <peer> <field> <value-as-json>
  jq -n --argjson v "$3" --arg f "$2" --arg p "$1" \
    '{id:($p+"-1"),from:$p,lamport:1,deps:{},act:"propose",refs:[],to:["*"],
      hand:false,turn:0,round:null,text:"a crafted proposal",created_at:"test",sent_ms:0}
     | .[$f] = $v' > "$R/lane/$1/000001.json"
  printf '1' > "$R/state/$1.seq"
}

# --- 1. a crafted .turn must not run anything -----------------------------------
# The payload names a scalar that is in scope where the value used to land, and carries no
# space, so `read` cannot split it apart -- both of which a real attacker gets for free.
MARKER="$R/PWNED"; rm -f "$MARKER"
craft a turn "\"turns[\$({touch,$MARKER})]\""
bash "$CLI" verdict >/dev/null 2>&1
bash "$CLI" status  >/dev/null 2>&1
bash "$CLI" claims  >/dev/null 2>&1
bash "$CLI" floor   >/dev/null 2>&1
COUNCIL_ME=b bash "$CLI" send --act msg "hello" >/dev/null 2>&1
if [ -e "$MARKER" ]; then
  echo "FAIL a crafted .turn executed a command in the reader's shell"; fail=1
else
  echo "ok   a crafted .turn ran nothing"
fi

# --- 2. a wrong-typed .turn is treated as absent, not as a turn -----------------
# A string turn used to win claims.jq's `max` and be reported as the room's last claim,
# which drove the no-new-claims window far negative.
rm -rf "$R"; mkroom "$R" a b; echo "q" > "$R/agenda.md"
craft a turn '"999"'
line=$(bash "$CLI" verdict)
since=$(bash "$CLI" verdict --json | jq -r .since_last_claim)
if [ "$since" -lt 0 ]; then
  echo "FAIL a string .turn drove the window negative: $line"; fail=1
else
  echo "ok   a string .turn did not drive the window negative (since=$since)"
fi
if bash "$CLI" claims | grep -q "at turn: 999"; then
  echo "FAIL a string .turn was reported as the room's last claim"; fail=1
else
  echo "ok   a string .turn was not reported as the room's last claim"
fi

# A string turn is also not a TURN. claims.jq coerces `.turn` for its own arithmetic, so
# the two assertions above pass even without the coercion on read -- but the turn counter
# and the floor rotation read the message directly, and they are what a peer would take
# over: an uncoerced string turn is counted as a turn consumed and moves the floor to
# somebody who never held it.
if bash "$CLI" floor | grep -q 'turns=0'; then
  echo "ok   a string .turn was not counted as a turn consumed"
else
  echo "FAIL a string .turn was counted as a turn: $(bash "$CLI" floor)"; fail=1
fi

# --- 3. a wrong-typed .lamport must not take the ordering over ------------------
# jq sorts strings above every number, so this message would otherwise sort last for good
# and set every reader's clock from it.
rm -rf "$R"; mkroom "$R" a b; echo "q" > "$R/agenda.md"
craft a lamport '"99999"'
say b msg '[]' "second"
first_id=$(bash "$CLI" order --ids 2>/dev/null | head -1)
if [ "$first_id" = "a-1" ]; then
  echo "ok   a string .lamport did not take the canonical order over"
else
  echo "FAIL a string .lamport reordered the room (first message is $first_id, want a-1)"; fail=1
fi

# --- 4. a wrong-typed .hand must not buy a free turn ----------------------------
# `.hand` decides whether a message consumes a turn. `select(.hand == false ...)` excludes
# anything that is not the boolean false, while `(.hand // false)` still counts the message
# valid -- so an uncoerced non-boolean is a message that takes no turn and never loses a
# turn conflict. Its author can post for as long as it likes and the floor never moves on.
rm -rf "$R"; mkroom "$R" a b; echo "q" > "$R/agenda.md"
craft a hand '"no"'
fl=$(bash "$CLI" floor)
case "$fl" in *"turns=1"*) echo "ok   a wrong-typed .hand still consumed its turn" ;;
  *) echo "FAIL a wrong-typed .hand dodged turn accounting: $fl"; fail=1 ;; esac

# --- 5. a wrong-typed .refs must not abort the argument graph -------------------
# `.refs` is the one field here that is read neither as a number nor as a boolean: its readers
# ITERATE it, and a value of another type ABORTS jq mid-stream rather than answering wrongly.
# Every caller swallows that failure, so the damage lands in `board/decision.md` — the room's
# one durable output — which was written with a blank verdict, blank turn counts and
# "(there were no objections)" over a transcript showing an objection. `decide` exited 0.
#
# Both readers are asserted because they fail at different widths: claims.jq iterates `.refs`
# only for `amend` and for a proposer's `concede`, while v_transcript's `join` aborts on EVERY
# act — and v_transcript renders the record's transcript and `status`'s last messages.
rm -rf "$R"; mkroom "$R" a b; echo "q" > "$R/agenda.md"
say_floor propose '[]' "Adopt the thing." >/dev/null
say_floor object '["a-1"]' "This breaks the thing." >/dev/null
raw_msg a 2 9 2 amend '"a-1"' "an amendment whose refs is a string"

claims=$(bash "$CLI" claims 2>/dev/null); crc=$?
if [ "$crc" = 0 ] && printf '%s' "$claims" | grep -q 'OPEN b-1'; then
  echo "ok   a string .refs left the argument graph readable, objection still open"
else
  echo "FAIL a string .refs broke the argument graph (rc=$crc)"; fail=1
fi
tr_out=$(bash "$CLI" transcript 2>/dev/null); trc=$?
if [ "$trc" = 0 ] && [ "$(printf '%s\n' "$tr_out" | grep -c .)" = 3 ]; then
  echo "ok   a string .refs left the transcript whole (3 messages)"
else
  echo "FAIL a string .refs truncated the transcript (rc=$trc): $(printf '%s' "$tr_out" | grep -c .) lines"; fail=1
fi
COUNCIL_ME=a bash "$CLI" decide --force >/dev/null 2>&1
if grep -q "This breaks the thing" "$R/board/decision.md" 2>/dev/null; then
  echo "ok   the decision record still names the objection"
else
  echo "FAIL the decision record dropped the objection it exists to record"; fail=1
fi

# --- 6. a .lamport that is a NUMBER but not an integer must not stall the clock --
# `_untrusted` used to coerce `.lamport` to a number, which is not the same as to a bash
# integer: c_drain's `[ "$seen" -gt "$mine" ]` errors on `1.5` with `integer expected`, and
# that error short-circuits the `&&` which advances the reader's clock. The reader then goes
# on stamping messages below what it has already read, silently and for good. c_max_lamport
# gates the identical expression one line further down; this is its sibling.
rm -rf "$R"; mkroom "$R" a b; echo "q" > "$R/agenda.md"
craft a lamport '1.5'
COUNCIL_ME=b bash "$CLI" recv --peek >/dev/null 2>&1
clock=$(cat "$R/state/b.lamport" 2>/dev/null)
case "$clock" in
  ''|*[!0-9]*) echo "FAIL a non-integer .lamport reached the reader's clock as '$clock'"; fail=1 ;;
  *) if [ "$clock" -ge 1 ]; then echo "ok   a non-integer .lamport still advanced the reader's clock (=$clock)"
     else echo "FAIL a non-integer .lamport left the reader's clock at $clock"; fail=1; fi ;;
esac

# --- 7. the room still works normally afterwards --------------------------------
rm -rf "$R"; mkroom "$R" a b; echo "q" > "$R/agenda.md"
p=$(say_floor propose '[]' "An ordinary proposal.")
[ -n "$p" ] && echo "ok   an ordinary room still sends and reads" \
            || { echo "FAIL a normal send broke"; fail=1; }

[ "$fail" = 0 ] && echo "t9b PASS" || echo "t9b FAIL"
exit $fail
