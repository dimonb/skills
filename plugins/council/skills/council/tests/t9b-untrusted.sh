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

# --- 5. the room still works normally afterwards --------------------------------
rm -rf "$R"; mkroom "$R" a b; echo "q" > "$R/agenda.md"
p=$(say_floor propose '[]' "An ordinary proposal.")
[ -n "$p" ] && echo "ok   an ordinary room still sends and reads" \
            || { echo "FAIL a normal send broke"; fail=1; }

[ "$fail" = 0 ] && echo "t9b PASS" || echo "t9b FAIL"
exit $fail
