#!/usr/bin/env bash
# t9d — a reader must take a message's PROVENANCE from the path it read it at, never from
# the message. Two fields used to be believed, by two different mechanisms, with two
# different consequences. They are asserted separately here on purpose: one fix delivers
# both, and a single assertion would hide whichever half regressed.
#
# `.from` was interpolated into the cursor path, so a participant writing
# `"from": "../../../x"` into its OWN lane made the READER create or truncate that file,
# with the reader's credentials. The content is only a sequence number, so it is a
# truncate/create primitive rather than code execution — which still reaches the room's
# roster.json or a victim's state/*.seq.
#
# `.id` was parsed as `split("-") | last | tonumber`. That is fatal for jq on a string with
# no dash, a non-numeric tail, or any non-string at all: jq exits non-zero, the batch is
# empty, and recv reports an empty inbox. The cursor never advances, so the poisoned file is
# re-read and re-fails forever and every honest message behind it in that lane is never
# delivered. This is the dangerous half, because it is SILENT: status, verdict, claims and
# transcript all keep working, so the room reports health while one participant is deaf.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
R="$COUNCIL_TEST_ROOT/t9d-lane-provenance"; rm -rf "$R"
export COUNCIL_ROOM="$R" ROOM="$R"
fail=0

fresh() { rm -rf "$R"; mkroom "$R" a b; echo "Whose message is this, really?" > "$R/agenda.md"; }

# A lane message with fields of our choosing, written straight into a lane — which is
# exactly what any participant can do, and what `send` deliberately cannot produce.
craft() { # <lane> <seq> <field> <value-as-json>
  local lane="$1" seq="$2" field="$3" value="$4"
  local f; f=$(printf '%s/lane/%s/%06d.json' "$ROOM" "$lane" "$seq")
  jq -n --argjson v "$value" --arg f "$field" --arg id "$lane-$seq" --arg from "$lane" \
    '{id:$id,from:$from,lamport:1,deps:{},act:"msg",refs:[],to:["*"],
      hand:false,turn:null,round:null,text:"crafted",created_at:"test",sent_ms:0}
     | .[$f] = $v' > "$f"
  printf '%s' "$seq" > "$ROOM/state/$lane.seq"
}

# --- 1. a crafted .from must not make the reader write outside the room ---------
fresh
ESC="$COUNCIL_TEST_ROOT/t9d-ESCAPED.txt"; rm -f "$ESC"
craft a 1 from '"../../../t9d-ESCAPED.txt"'
COUNCIL_ME=b bash "$CLI" recv --timeout 1 >/dev/null 2>&1
if [ -e "$ESC" ]; then
  echo "FAIL a crafted .from made the reader write outside the room ($ESC)"; fail=1
  rm -f "$ESC"
else
  echo "ok   a crafted .from wrote nothing outside the room"
fi
# and the cursor went where it belongs — keyed by the LANE, so the lane still advances.
cur=$(cat "$R/cursor/b/a" 2>/dev/null || echo MISSING)
if [ "$cur" = 1 ]; then echo "ok   the cursor advanced on the lane the file came from"
else echo "FAIL the cursor did not follow the lane: cursor/b/a=$cur (want 1)"; fail=1; fi

# --- 2. a crafted .from must not be able to advance ANOTHER lane's cursor -------
# Grouping used to key off `.from` too, so claiming a peer's name merged two lanes and moved
# the wrong cursor — past messages the reader had never seen.
fresh
craft a 1 from '"b"'
COUNCIL_ME=b bash "$CLI" recv --timeout 1 >/dev/null 2>&1
ca=$(cat "$R/cursor/b/a" 2>/dev/null || echo MISSING)
if [ "$ca" = 1 ]; then echo "ok   a .from naming another peer still advanced only its own lane"
else echo "FAIL grouping followed the crafted .from: cursor/b/a=$ca (want 1)"; fail=1; fi

# --- 3. a crafted .id must not stop the inbox ------------------------------------
# Each shape below killed jq outright. After each, the HONEST message behind it in the same
# lane must still be delivered — that is the property, not merely "recv did not crash".
for bad in '"noDashHere"' '"a-notanumber"' '17' 'null' '["a-1"]'; do
  fresh
  craft a 1 id "$bad"
  # an ordinary later message in the same lane, written the same way
  jq -n '{id:"a-2",from:"a",lamport:2,deps:{},act:"msg",refs:[],to:["*"],
          hand:false,turn:null,round:null,text:"an honest later message",
          created_at:"test",sent_ms:0}' > "$R/lane/a/000002.json"
  printf '2' > "$R/state/a.seq"
  out=$(COUNCIL_ME=b bash "$CLI" recv --timeout 1 2>/dev/null)
  if printf '%s' "$out" | grep -q "an honest later message"; then
    echo "ok   a crafted .id ($bad) did not stop the inbox"
  else
    echo "FAIL a crafted .id ($bad) wedged the lane — the honest message never arrived"; fail=1
  fi
done

# --- 4. and the wedge does not come back on the NEXT call ------------------------
# The failure was survivable-looking precisely because it repeated: the cursor never moved,
# so the poisoned file was re-read forever. Drain twice and require the second to be empty.
fresh
craft a 1 id '"noDashHere"'
COUNCIL_ME=b bash "$CLI" recv --timeout 1 >/dev/null 2>&1
cur=$(cat "$R/cursor/b/a" 2>/dev/null || echo MISSING)
out2=$(COUNCIL_ME=b bash "$CLI" recv --timeout 1 2>/dev/null); rc2=$?
if [ "$cur" = 1 ] && [ "$rc2" = 4 ] && [ -z "$out2" ]; then
  echo "ok   the poisoned message was consumed once and did not re-arrive"
else
  echo "FAIL the poisoned message was not retired: cursor=$cur rc=$rc2 out='$out2'"; fail=1
fi

# --- 5. no internal bookkeeping leaks into what a participant reads --------------
# The lane and the sequence are carried through c_drain as _lane/_seq. They are this
# transport's own working state, and a participant parses what recv prints.
fresh
say a msg '[]' "an ordinary message"
out=$(COUNCIL_ME=b bash "$CLI" recv --timeout 1 2>/dev/null)
if printf '%s' "$out" | jq -e 'has("_lane") or has("_seq")' >/dev/null 2>&1; then
  echo "FAIL recv leaked internal bookkeeping: $out"; fail=1
else
  echo "ok   recv printed a message with no internal fields"
fi

# --- 6. several documents in ONE lane file are still attributed correctly --------
# A peer controls its own file's CONTENT, so it can put more than one message in it. The
# lane and the sequence must still come from the path, for every one of them.
fresh
{ jq -c -n '{id:"a-1",from:"../../../nope",lamport:1,deps:{},act:"msg",refs:[],to:["*"],
             hand:false,turn:null,round:null,text:"first",created_at:"t",sent_ms:0}'
  jq -c -n '{id:"a-2",from:"../../../nope",lamport:2,deps:{},act:"msg",refs:[],to:["*"],
             hand:false,turn:null,round:null,text:"second",created_at:"t",sent_ms:0}'
} > "$R/lane/a/000001.json"
printf '1' > "$R/state/a.seq"
ESC2="$COUNCIL_TEST_ROOT/nope"; rm -f "$ESC2"
out=$(COUNCIL_ME=b bash "$CLI" recv --timeout 1 2>/dev/null)
n=$(printf '%s' "$out" | grep -c . || true)
cur=$(cat "$R/cursor/b/a" 2>/dev/null || echo MISSING)
if [ ! -e "$ESC2" ] && [ "$n" = 2 ] && [ "$cur" = 1 ]; then
  echo "ok   two documents in one lane file were both attributed to that lane"
else
  echo "FAIL multi-document lane file mishandled: escaped=$([ -e "$ESC2" ] && echo yes || echo no) lines=$n cursor=$cur"; fail=1
  rm -f "$ESC2"
fi

# --- 7. the room still works normally afterwards --------------------------------
fresh
p=$(say_floor propose '[]' "An ordinary proposal.")
[ -n "$p" ] && echo "ok   an ordinary room still sends and reads" \
            || { echo "FAIL a normal send broke"; fail=1; }

[ "$fail" = 0 ] && echo "t9d PASS" || echo "t9d FAIL"
exit $fail
