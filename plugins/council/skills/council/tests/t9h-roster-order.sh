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
# with a diagnostic, the way `council relaunch` already treats the same file. A partial list
# would be worse than none, because it silently redefines who the room is.
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

rm -rf "$outside"
[ "$fail" = 0 ] && echo "t9h PASS" || echo "t9h FAIL"
exit $fail
