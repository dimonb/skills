#!/usr/bin/env bash
# t9g — WHICH LANES are the room, and what happens to one that is not.
#
# Sibling of t9e. That file pins who a message is FROM; this one pins which lanes a reader
# counts at all. They were two different answers in two readers: c_drain has always built its
# file list from `roster.order`, while c_all globbed `lane/*/`. So a lane the roster does not
# list appeared in transcript, claims and verdict as a peer holding the floor and raising
# objections, while `recv` never delivered a word of it to anybody. Nobody could read it,
# nobody could answer it, and since only the ungated `overrule` can close an objection its
# author never conceded, the room could not reach ready-to-decide.
#
# It needs no `mkdir` to happen. Rename a peer in roster.json and its existing lane is
# orphaned on the spot — one of the accidents issue #66 named, though not for this reason: it
# is not an authorship defect at all, and deriving a message's author does not touch it.
#
# BOTH directions are asserted, and the second is the one that rots quietly. Filtering the
# lane set without REPORTING the exclusion would trade a visibly wrong room for an invisible
# one, which is the failure this codebase keeps having. A test that pinned only the exclusion
# would let the reporting half disappear and nothing would ever say so.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
R="$COUNCIL_TEST_ROOT/t9g-lane-membership"; rm -rf "$R"
export COUNCIL_ROOM="$R" ROOM="$R"
fail=0

fresh() { rm -rf "$R"; mkroom "$R" a b; echo "Which lanes are this room?" > "$R/agenda.md"; }

# A message in a lane, written without going through council.sh — the only way to put one in
# a lane the roster does not list, since c_send writes to lane/$COUNCIL_ME/ and a seat with an
# unrostered COUNCIL_ME is exactly the accident being modelled.
plant() { # <lane> <seq> <act> <refs-json> <text>
  mkdir -p "$ROOM/lane/$1"
  jq -n --arg id "$1-$2" --arg from "$1" --arg act "$3" --argjson refs "$4" --arg text "$5" --argjson l "$2" \
    '{id:$id,from:$from,lamport:$l,deps:{},act:$act,refs:$refs,to:["*"],
      hand:false,turn:null,round:null,text:$text,created_at:"test",sent_ms:0}' \
    > "$(printf '%s/lane/%s/%06d.json' "$ROOM" "$1" "$2")"
}
id_of() { bash "$CLI" order 2>/dev/null | jq -r --arg a "$1" 'select(.act == $a) | .id' | head -1; }
set_order() { jq --argjson o "$1" '.order = $o' "$R/roster.json" > "$R/r.next" && mv "$R/r.next" "$R/roster.json"; }

# --- 1. a lane the roster DOES list is read -------------------------------------
# The direction that must not be broken by filtering. Asserted first and explicitly, because
# every other assertion here is about exclusion and a filter that excluded everything would
# satisfy them all.
fresh
say_floor propose '[]' "An ordinary proposal." >/dev/null
if bash "$CLI" transcript 2>/dev/null | grep -q 'An ordinary proposal.' \
   && [ "$(bash "$CLI" verdict --json 2>/dev/null | jq -r .live)" = 1 ]; then
  echo "ok   a rostered lane is still read"
else
  echo "FAIL filtering the lane set lost a rostered lane's messages"; fail=1
fi

# --- 2. a lane the roster does NOT list is excluded from every reader ------------
# Before, this message was in transcript/claims/verdict but not in recv. Now it is in neither,
# which is the point: the two readers agree on the room's membership.
fresh
say_floor propose '[]' "An ordinary proposal." >/dev/null
# The planted text must not collide with the alarm wording that case 3 greps for: `status`
# echoes the transcript tail, so a message saying "not in the roster" would satisfy case 3's
# grep on a tree with no alarm at all. That is precisely the shape where a guard passes
# because the fixture makes its own assertion true — it was caught here by running this file
# against the pre-change code, where case 3 went green with `alarms: —`.
# The ghost objection must REFERENCE the live proposal. With refs:[] it attaches to no
# proposal, so `.open` is 0 in every tree and that conjunct asserts nothing — it read as a
# pass against the pre-change code while the bug was fully present. Referencing the proposal
# is what makes the case exercise the harm the header names: pre-change the room sat at
# `stuck` for ever over an objection nobody could answer.
plant ghost 1 object "$(jq -cn --arg i "$(id_of propose)" '[$i]')" "GHOSTMSG objecting from nowhere"
n_transcript=$(bash "$CLI" transcript 2>/dev/null | grep -c 'GHOSTMSG' || true)
open=$(bash "$CLI" verdict --json 2>/dev/null | jq -r .open)
recv_out=$(COUNCIL_ME=b bash "$CLI" recv --timeout 1 2>/dev/null)
n_recv=$(printf '%s' "$recv_out" | grep -c 'GHOSTMSG' || true)
if [ "$n_transcript" = 0 ] && [ "$open" = 0 ] && [ "$n_recv" = 0 ]; then
  echo "ok   an unrostered lane is counted by neither reader (transcript=$n_transcript open=$open recv=$n_recv)"
else
  echo "FAIL an unrostered lane leaked into a reader: transcript=$n_transcript open=$open recv=$n_recv"; fail=1
fi

# --- 3. and it is REPORTED, not silently dropped --------------------------------
# The half that would rot. `status` is where a supervisor already looks.
# Read the ALARMS LINE, not the whole of `status` — status also echoes the last few
# transcript lines, so grepping its full output tests the fixture as much as the alarm.
alarms=$(bash "$CLI" status 2>/dev/null | sed -n 's/^alarms://p')
if printf '%s' "$alarms" | grep -q 'not in the roster'; then
  echo "ok   status raises an alarm naming the unrostered lane"
else
  echo "FAIL an unrostered lane was dropped silently — alarms:$alarms"; fail=1
fi
# and it counts the messages, so a reader can tell an empty stray directory from a lost lane
if printf '%s' "$alarms" | grep -qE '1 lane\(s\).*1 message\(s\)'; then
  echo "ok   the alarm counts the lanes and the messages they hold"
else
  echo "FAIL the alarm does not report how much is uncounted — alarms:$alarms"; fail=1
fi

# --- 4. a room with no stray lane raises no such alarm --------------------------
# Otherwise the alarm is noise, and an alarm that is always on is one a supervisor learns to
# ignore — which is how the real one gets missed.
fresh
say_floor propose '[]' "An ordinary proposal." >/dev/null
if bash "$CLI" status 2>/dev/null | sed -n 's/^alarms://p' | grep -q 'not in the roster'; then
  echo "FAIL an ordinary room raised the unrostered-lane alarm"; fail=1
else
  echo "ok   an ordinary room raises no unrostered-lane alarm"
fi

# --- 5. the accident that needs no mkdir: a peer renamed in the roster ----------
# #66's own third accident story. The lane is orphaned by the rename alone.
fresh
p=$(say_floor propose '[]' "Adopt the thing.")
jq --arg old "$p" '.order = [ .order[] | if . == $old then "renamed" else . end ]' \
  "$R/roster.json" > "$R/r.next" && mv "$R/r.next" "$R/roster.json"
live=$(bash "$CLI" verdict --json 2>/dev/null | jq -r .live)
alarmed=$(bash "$CLI" status 2>/dev/null | sed -n 's/^alarms://p' | grep -c 'not in the roster' || true)
if [ "$live" = 0 ] && [ "$alarmed" -ge 1 ]; then
  echo "ok   a renamed peer's orphaned lane stops counting and is reported"
else
  echo "FAIL a renamed peer's lane was mishandled: live=$live alarmed=$alarmed (want 0 and >=1)"; fail=1
fi

# --- 6. a path-shaped roster entry must not read outside lane/ ------------------
# Taking the lane set from the roster made roster.json decide which paths a reader OPENS, and
# roster.json is in the room like every other file. The glob it replaced could not escape
# `lane/`; this must not either. Both fixtures below were reproduced against the ungated code:
# `..` pulled a file from the room root into the transcript, and `../../outside` one from
# outside the room entirely — where a planted `act: overrule` closes objections, ungated.
for bad in '".."' '"../../outside"'; do
  fresh
  say_floor propose '[]' "An ordinary proposal." >/dev/null
  printf '%s' 'OUTSIDE' > "$COUNCIL_TEST_ROOT/outside.marker"
  jq -cn '{id:"x-1",from:"x",lamport:9,deps:{},act:"object",refs:[],to:["*"],
           hand:false,turn:null,round:null,text:"ESCAPEDMSG",created_at:"t",sent_ms:0}' \
    > "$R/000001.json"                                   # the room root, reachable via ..
  mkdir -p "$COUNCIL_TEST_ROOT/outside"
  cp "$R/000001.json" "$COUNCIL_TEST_ROOT/outside/000001.json"
  set_order "$(jq -cn --argjson b "$bad" '["a","b",$b]')"
  out=$(bash "$CLI" transcript 2>/dev/null; bash "$CLI" claims 2>/dev/null)
  if printf '%s' "$out" | grep -q 'ESCAPEDMSG'; then
    echo "FAIL a roster entry of $bad read a file from outside lane/ into the room"; fail=1
  else
    echo "ok   a roster entry of $bad read nothing from outside lane/"
  fi
done

# --- 7. a roster that names one lane twice is MALFORMED, not deduplicated -------
# Exact duplicates and case variants alike. The room cannot state its membership unambiguously,
# so it has none — rejected, alarmed, and `decide` refuses. Deduplicating instead would be a
# silent normalisation: on a case-SENSITIVE filesystem `abc` and `ABC` are two different peers,
# so folding them would change the membership without saying so.
#
# Both shapes must be covered, because they failed differently. Exact duplicates read a lane
# once per entry; case variants defeated a byte-comparison dedup entirely on a case-INsensitive
# filesystem (APFS, which this repo sits on), giving eight copies of one lane's messages, eight
# live proposals, silent alarms, and `decide --force` writing a durable record at rc 0.
for dup in '[range(40) | "a"] + ["b"]' '["abc","Abc","aBc","ABC","b"]'; do
  fresh
  p=$(say_floor propose '[]' "An ordinary proposal.")
  set_order "$(jq -cn "$dup")"
  live=$(bash "$CLI" verdict --json 2>/dev/null | jq -r .live)
  COUNCIL_ME="$p" bash "$CLI" decide --force >/dev/null 2>&1; drc=$?
  alarmed=$(bash "$CLI" status 2>/dev/null | sed -n 's/^alarms://p' | grep -c 'no usable' || true)
  if [ "$live" = 0 ] && [ "$drc" != 0 ] && [ ! -f "$R/board/decision.md" ] && [ "$alarmed" -ge 1 ]; then
    echo "ok   a roster naming one lane twice is rejected, not deduplicated ($dup)"
  else
    echo "FAIL a duplicate-naming roster was accepted: live=$live decide=$drc alarmed=$alarmed ($dup)"; fail=1
  fi
done

# --- 8. a malformed roster means NO membership, and decide must REFUSE ----------
# The contract: fail closed and visible. The read-only verbs keep working so a corrupt room can
# still be diagnosed from inside, `status` alarms, and the one path that must never produce a
# wrong answer — the durable record — refuses. Before the gate, `decide --force` exited 0
# having written a record saying "(there were no objections)" while an objection was open.
for bad in '"a"' '{"a":1}' '["a",2]' '["a","../b"]' '[]' '["a","b\nghost"]' '["a","b",""]' '["a",null]'; do
  fresh
  p=$(say_floor propose '[]' "An ordinary proposal.")
  say_floor object "$(jq -cn --arg i "$(id_of propose)" '[$i]')" "No." >/dev/null
  set_order "$bad"
  # COUNCIL_ME must be set, or council.sh's `need_me` exits 2 before v_decide runs at all —
  # which looks exactly like the refusal this case is asserting. Caught by running the case
  # against a tree with no roster gate, where it "passed" without ever reaching the code.
  COUNCIL_ME="$p" bash "$CLI" decide --force >/dev/null 2>&1; drc=$?
  alarmed=$(bash "$CLI" status 2>/dev/null | sed -n 's/^alarms://p' | grep -c 'no usable' || true)
  if [ "$drc" != 0 ] && [ ! -f "$R/board/decision.md" ] && [ "$alarmed" -ge 1 ]; then
    echo "ok   roster order=$bad — decide refused (rc $drc), no record, status alarmed"
  else
    echo "FAIL roster order=$bad — decide rc=$drc record=$([ -f "$R/board/decision.md" ] && echo YES || echo NO) alarmed=$alarmed"; fail=1
  fi
done

# --- 9. and a usable roster is still usable ------------------------------------
# The guard against buying every case above by rejecting every roster.
fresh
p=$(say_floor propose '[]' "An ordinary proposal.")
say_floor msg '[]' "nothing new" >/dev/null
say_floor msg '[]' "nor here" >/dev/null
COUNCIL_ROOM="$R" COUNCIL_ME="$p" bash "$CLI" decide >/dev/null 2>&1
v=$(bash "$CLI" verdict 2>/dev/null | cut -d' ' -f1)
if [ "$v" = decided ] && [ -s "$R/board/decision.md" ]; then
  echo "ok   an ordinary roster still reaches a decision and writes a record"
else
  echo "FAIL the roster gate broke an ordinary room: verdict=$v record=$([ -s "$R/board/decision.md" ] && echo YES || echo NO)"; fail=1
fi

[ "$fail" = 0 ] && echo "t9g PASS" || echo "t9g FAIL"
exit $fail
