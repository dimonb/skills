#!/usr/bin/env bash
# t9h — `roster.order` decides which lane PATHS a reader opens, so it is validated where it is
# read. It is a file in the room like every other, writable by every participant and reachable
# by a hand-edit or a template with an odd name in it.
#
# The escape is not theoretical. On an unguarded reader, an `.order` entry of `../../<dir>`
# made `recv` deliver a message read from a file OUTSIDE the room, attributed to a peer named
# after that directory, and wrote a cursor for it. The other three shapes are ordinary
# breakage: a non-array `.order` empties the peer list so `recv` returns 4 for ever, a `"` in a
# name makes the deps object invalid JSON so every send fails, and a `*` is glob-expanded by
# the unquoted `for p in $(c_peers)` loops.
#
# The rule is ALL-OR-NOTHING and it is announced: one unusable entry rejects the whole list
# with a diagnostic. A partial list would be worse than none, because it silently redefines
# who the room is. `c_peers` is the only reader that VALIDATES `.order`, and every verb needing
# the peer list goes through it — `relaunch` and `down` included — so there is no second copy of
# this rule to drift. (`c_floor_at` indexes `.order[$i]` directly, which holds only while this
# rule stays all-or-nothing; lib.sh says so where the rule lives.)
#
# THE SHAPE OF THE TEST MATTERS as much as the cases. An earlier attempt at validating this
# same field was reverted after four rounds, each finding the next layer of the same thing:
# an entry split by a newline, a trailing newline that `$( )` strips before a length check
# sees it, and jq's `$` matching BEFORE a final newline so `^[A-Za-z0-9_-]+$` accepts `"ab\n"`.
# The two newline cases below exist for that history, and they are the reason the predicate
# asks whether an entry CONTAINS a character outside the set instead of anchoring a match.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
R="$COUNCIL_TEST_ROOT/t9h-roster-order"; rm -rf "$R"
export COUNCIL_ROOM="$R" ROOM="$R"
fail=0

fresh() { rm -rf "$R"; mkroom "$R" a b; echo "Who is in this room?" > "$R/agenda.md"; }
set_order() { jq --argjson o "$1" '.order = $o' "$R/roster.json" > "$R/r.tmp" && mv "$R/r.tmp" "$R/roster.json"; }
REFUSED='no usable participant list'

# --- 1. a traversing entry must not read a file from outside the room -----------
# The file sits beside the room, not in it. Nothing in a room may reach it.
fresh
outside="$COUNCIL_TEST_ROOT/t9h-outside"; rm -rf "$outside"; mkdir -p "$outside"
jq -c -n '{id:"x-1",from:"x",lamport:1,deps:{},act:"msg",refs:[],to:["*"],
           hand:false,turn:null,round:null,text:"FROM OUTSIDE THE ROOM",
           created_at:"t",sent_ms:0}' > "$outside/000001.json"
set_order '["a","b","../../t9h-outside"]'
out=$(COUNCIL_ME=b bash "$CLI" recv --peek 2>"$R/e"); rc=$?
if printf '%s' "$out" | grep -q "FROM OUTSIDE THE ROOM"; then
  echo "FAIL a traversing roster entry delivered a message from outside the room"; fail=1
else
  echo "ok   a traversing roster entry delivered nothing (recv rc=$rc)"
fi
# Listed rather than probed by name: `[ -e "$R/cursor/b/.." ]` tests the cursor DIRECTORY,
# which always exists, so it reports a failure for every room including a healthy one.
cursors=$(ls -A "$R/cursor/b" 2>/dev/null | paste -sd, -)
if [ "$cursors" = a ]; then
  echo "ok   a traversing roster entry got no cursor of its own"
else
  echo "FAIL cursors under b are '$cursors', want just 'a'"; fail=1
fi
grep -q "$REFUSED" "$R/e" && echo "ok   and the roster was refused out loud" \
  || { echo "FAIL a traversing roster entry was refused silently"; fail=1; }

# --- 2. every other unusable shape is refused, out loud -------------------------
# `"ab\n"` and `"a\nb"` are the two the anchored predicate let through, and they are why this
# one has no anchor at all.
refuses() { # <label> <order-json>
  fresh; set_order "$2"
  bash "$CLI" floor >/dev/null 2>"$R/e"
  if grep -q "$REFUSED" "$R/e"; then echo "ok   refused: $1"
  else echo "FAIL accepted an unusable roster: $1"; fail=1; fi
}
refuses 'a string instead of a list'     '"ab"'
refuses 'an empty list'                  '[]'
refuses 'a name holding a quote'         '["a","b\"x"]'
refuses 'a name that is a glob'          '["a","*"]'
refuses 'a name with a slash'            '["a","x/y"]'
refuses 'a name with a space'            '["a","x y"]'
refuses 'a name with a trailing newline' '["a","ab\n"]'
refuses 'a name with an inner newline'   '["a","a\nb"]'
refuses 'an entry that is not a string'  '["a",7]'
refuses 'an empty name'                  '["a",""]'

# --- 3. no invalid JSON reaches a send ------------------------------------------
# c_deps_json interpolates each name into a JSON key. A `"` in one used to make `send` die
# with "invalid JSON text passed to --argjson"; the point here is that it now fails on the
# ROSTER instead, which says what is actually wrong.
#
# The sender must be the seat that HOLDS THE FLOOR, or c_send refuses one step earlier and
# never reaches the jq call this asserts on — the floor check would then be what stopped it,
# and the assertion would pass on unguarded code. So: an untouched room, turn 0, and `a`.
fresh
set_order '["a","b\"x"]'
COUNCIL_ME=a bash "$CLI" send --act msg "hello" >/dev/null 2>"$R/e"
if grep -q 'invalid JSON' "$R/e"; then
  echo "FAIL a roster name reached jq as invalid JSON"; fail=1
else
  echo "ok   a roster name never reached jq as invalid JSON"
fi
if [ -e "$R/lane/a/000001.json" ]; then
  echo "FAIL a message was written under an unusable roster"; fail=1
else
  echo "ok   no message was written under an unusable roster"
fi

# --- 4. an ordinary roster is not refused ---------------------------------------
# The half that makes the rest mean anything: a guard that rejects everything would pass
# every assertion above.
fresh
bash "$CLI" floor >/dev/null 2>"$R/e"
if grep -q "$REFUSED" "$R/e"; then
  echo "FAIL an ordinary roster was refused"; fail=1
else
  echo "ok   an ordinary roster was not refused"
fi
p=$(say_floor propose '[]' "An ordinary proposal.")
if [ -n "$p" ] && [ "$(bash "$CLI" floor | sed -n 's/.*floor=\([^ ]*\).*/\1/p')" = b ]; then
  echo "ok   an ordinary room still sends, and the floor still rotates"
else
  echo "FAIL an ordinary room broke under the guard"; fail=1
fi
# Names at the edge of the set are names, not near-misses to be rejected for tidiness.
fresh
set_order '["a","B-2_x"]'
bash "$CLI" floor >/dev/null 2>"$R/e"
if grep -q "$REFUSED" "$R/e"; then
  echo "FAIL a legitimate name was refused: B-2_x"; fail=1
else
  echo "ok   letters, digits, '_' and '-' are accepted in any mixture"
fi

# --- every verb that reads .order reads it through the SAME reader ---------------
# `relaunch` used to read `.order` itself and validate the LINES that `$(jq -r)` printed, so it
# accepted rosters every other verb refuses: it regenerated a protocol naming a participant that
# is not in the room, created a regular file where that seat's bell fifo belongs, and reported
# success at rc 0 into a room where the restarted seat could not run a single verb. A second
# copy of this rule is the copy that stops being maintained.
#
# The backend is a name that cannot resolve, so nothing here can open a real terminal; each
# case must fail on the ROSTER, long before that.
#
# Measured against the previous reader: the first FOUR shapes were accepted by it and are what
# this change closes. The fifth, a non-array `.order`, it already refused with its own
# `(.order | type) == "array"` check — so that row is forward cover, not evidence for this
# change, and it is named here rather than left to read as a fifth proof.
for bad in '["a","b\nc"]' '["a","ab\n"]' '["a",7]' '["a",""]' '"ab"'; do
  fresh
  set_order "$bad"
  ( export COUNCIL_ROOM="$R" COUNCIL_BACKEND=none-for-tests
    bash "$CLI" relaunch b >/dev/null 2>"$R/e" )
  if grep -q "$REFUSED" "$R/e"; then
    echo "ok   relaunch refused the roster the other verbs refuse: $bad"
  else
    echo "FAIL relaunch accepted a roster c_peers refuses: $bad"; fail=1
  fi
done
# And it still accepts an ordinary one — a guard that refuses everything proves nothing.
# It gets no further than the terminal it cannot open, which is past every roster check.
fresh
( export COUNCIL_ROOM="$R" COUNCIL_BACKEND=none-for-tests
  bash "$CLI" relaunch b >/dev/null 2>"$R/e" )
if grep -q "$REFUSED" "$R/e"; then
  echo "FAIL relaunch refused an ordinary roster"; fail=1
else
  echo "ok   relaunch still accepts an ordinary roster"
fi

# --- the three consumers of the refusal, each asserted so it cannot silently come back ------
# Each of these guards was added because its absence ended in a false or unreadable durable
# outcome, and each was shipped once with NO assertion: deleting any of the three left the whole
# suite green. A fix with no test that fails without it is the vacuous check AGENTS.md names.
# All three fail against the commit that introduced them.

# v_verdict: no readable participant list means no lap, so no verdict — and `decide` then has
# the empty verdict its own guard is written for. Without this the room reported
# `ready-to-decide` on its first proposal and `decide` wrote `**decided**` at rc 0.
fresh
set_order '["a","x/y"]'
say_floor propose '[]' "A proposal." >/dev/null 2>&1
vout=$(bash "$CLI" verdict 2>/dev/null)
COUNCIL_ME=a bash "$CLI" decide >/dev/null 2>&1
if [ -z "$vout" ] && [ ! -f "$R/board/decision.md" ]; then
  echo "ok   an unreadable roster yields no verdict, and decide writes no record"
else
  echo "FAIL verdict said '$vout' and the record was $([ -f "$R/board/decision.md" ] && echo written || echo absent)"; fail=1
fi

# c_barrier: the opening barrier must stay UP for a roster nobody can read. Without this it
# reported itself closed before anyone had posted — the barrier deleting itself.
fresh
jq '.mode = "roundtable"' "$R/roster.json" > "$R/r.tmp" && mv "$R/r.tmp" "$R/roster.json"
set_order '["a","x/y"]'
if bash "$CLI" floor 2>/dev/null | grep -q '(barrier)'; then
  echo "ok   an unreadable roster leaves the opening barrier up"
else
  echo "FAIL the opening barrier dissolved itself on an unreadable roster"; fail=1
fi

# council rooms: `verdict` prints nothing for such a room and that listing drops stderr, so
# without a fallback the room shows a blank column and reads as ordinary in the one view that
# lists every room at once.
gd="$COUNCIL_TEST_ROOT/t9h-rooms"; rm -rf "$gd"; mkdir -p "$gd"
( cd "$gd" && git init -q . ) 2>/dev/null
mkdir -p "$gd/.git/council"
mkroom "$gd/.git/council/broken" a b
jq '.order = "not-a-list"' "$gd/.git/council/broken/roster.json" > "$gd/r.tmp" \
  && mv "$gd/r.tmp" "$gd/.git/council/broken/roster.json"
rooms_line=$( cd "$gd" && bash "$CLI" rooms 2>/dev/null | sed -n 's/^broken  *//p' )
# Assert the fallback TEXT, not merely a non-empty column: before the guard that yields the
# empty verdict, this listing printed a confident (and wrong) verdict line here, so a
# "non-empty" test passes against the defect and proves nothing.
case "$rooms_line" in
  *"could not be read"*) echo "ok   the room list says an unreadable room could not be read" ;;
  *) echo "FAIL the room list showed '$rooms_line' for an unreadable room"; fail=1 ;;
esac
rm -rf "$gd"

rm -rf "$outside"
[ "$fail" = 0 ] && echo "t9h PASS" || echo "t9h FAIL"
exit $fail
