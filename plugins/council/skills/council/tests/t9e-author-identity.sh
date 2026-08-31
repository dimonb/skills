#!/usr/bin/env bash
# t9e — WHO a message is from. The author is derived from the lane the file was read at, in
# every reader, and a message's own `.from` is overwritten rather than believed.
#
# This is the property the whole deliberation layer rests on and nothing used to check.
# `claims.jq` is author-gated in three of its four closing rules — only an objection's own
# author withdraws or concedes it, only a proposal's own author kills it — and it compared
# a field the message declares about itself. So a participant writing `"from": "<peer>"`
# into its OWN lane dropped somebody else's proposal, and the transcript recorded the
# victim as having done it. No hostility is required to produce that message: a relaunched
# seat with a stale COUNCIL_ME writes it, and so does a model copying a worked `send`
# example including its `from` value.
#
# The cases below are written against the ROOM's answers — verdict, transcript, floor —
# rather than against the derivation itself, because the derivation is not the point: a
# reader could derive correctly and still be ignored by the rule that matters.
#
# Case 4 is the load-bearing one and the reason this file exists as much as any forgery
# case. Two readers take messages off disk — c_drain (feeds `recv`) and c_all (feeds
# verdict, status, claims, transcript, decide). Deriving in one and not the other renders a
# single message under two different authors depending on which path you came through, and
# somebody comparing `recv` against `transcript` would then be debugging a bug that is not
# there. It must be both or neither, and this asserts both.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
R="$COUNCIL_TEST_ROOT/t9e-author-identity"; rm -rf "$R"
export COUNCIL_ROOM="$R" ROOM="$R"
fail=0

fresh() { # <peer>...
  rm -rf "$R"; mkroom "$R" "$@"; echo "Who actually said that?" > "$R/agenda.md"
}

# A message written straight into a lane with an author of our choosing — which is exactly
# what any participant can do, and what `send` cannot produce: c_send takes both the lane
# path and `.from` from its own COUNCIL_ME, so for honest traffic the two always agree.
forge() { # <lane-written-to> <seq> <claimed-from> <act> <refs-json> <text>
  local lane="$1" seq="$2" claim="$3" act="$4" refs="$5" text="$6"
  local f; f=$(printf '%s/lane/%s/%06d.json' "$ROOM" "$lane" "$seq")
  jq -n --arg id "$lane-$seq" --arg from "$claim" --arg act "$act" \
        --argjson refs "$refs" --arg text "$text" \
    '{id:$id,from:$from,lamport:9,deps:{},act:$act,refs:$refs,to:["*"],
      hand:false,turn:null,round:null,text:$text,created_at:"test",sent_ms:0}' > "$f"
  printf '%s' "$seq" > "$ROOM/state/$lane.seq"
}

# The ids of what is on the table, read back out of the room rather than reconstructed.
id_of() { bash "$CLI" order 2>/dev/null | jq -r --arg a "$1" 'select(.act == $a) | .id' | head -1; }
live_open() { bash "$CLI" verdict --json 2>/dev/null | jq -r '[.live, .open] | @tsv'; }

# --- 1. a forged withdraw must not kill somebody else's proposal ----------------
# The issue's first reproduction, verbatim: the room went from `deliberating` with one live
# proposal to `no-proposal`, and the transcript credited the withdrawal to its victim.
fresh a b
p=$(say_floor propose '[]' "Adopt the thing.")
read -r live0 open0 <<<"$(live_open)"
other=$(c_peers_list | grep -v "^$p$" | head -1)
forge "$other" 1 "$p" withdraw "$(jq -c -n --arg i "$(id_of propose)" '[$i]')" "never mind"
read -r live1 open1 <<<"$(live_open)"
if [ "$live0" = 1 ] && [ "$live1" = 1 ]; then
  echo "ok   a forged withdraw did not kill the proposal (live $live0 -> $live1)"
else
  echo "FAIL a forged withdraw killed somebody else's proposal (live $live0 -> $live1)"; fail=1
fi

# --- 2. and it is recorded against whoever really wrote it ----------------------
# Attribution is not cosmetic here: the transcript and the decision record are the room's
# two durable outputs, and a supervisor reads them to work out what happened.
line=$(bash "$CLI" transcript 2>/dev/null | grep 'never mind')
if printf '%s' "$line" | grep -q "^\[$other withdraw"; then
  echo "ok   the transcript named the lane that wrote it, not the name it claimed"
else
  echo "FAIL the transcript believed the claimed author: $line"; fail=1
fi

# --- 3. a forged concede must not close somebody else's objection ---------------
# Three seats, deliberately. In a two-seat room the only lane available to the forger is
# the proposal author's own, and a `concede` from the proposal's author legitimately kills
# the proposal — so the case would pass for the wrong reason and prove nothing.
fresh a b c
p=$(say_floor propose '[]' "Adopt the thing.")
pid=$(id_of propose)
# The objection has to REFERENCE the proposal, or claims.jq attaches it to nothing and the
# room reports zero open objections — which reads as a pass here for entirely the wrong
# reason.
o=$(say_floor object "$(jq -c -n --arg i "$pid" '[$i]')" "That breaks the other thing.")
oid=$(id_of object)
third=$(c_peers_list | grep -v "^$p$" | grep -v "^$o$" | head -1)
read -r live0 open0 <<<"$(live_open)"
forge "$third" 1 "$o" concede "$(jq -c -n --arg i "$oid" '[$i]')" "fine, you win"
read -r live1 open1 <<<"$(live_open)"
if [ "$open0" = 1 ] && [ "$open1" = 1 ] && [ "$live1" = 1 ]; then
  echo "ok   a forged concede closed nothing (open $open0 -> $open1, live $live1)"
else
  echo "FAIL a forged concede closed an objection its author never conceded (open $open0 -> $open1, live $live1)"; fail=1
fi
# The objection must still be attributed to the seat that raised it, and the proposal to
# its own author — a derivation that got those wrong would also read as "nothing closed".
if bash "$CLI" claims 2>/dev/null | grep -q "OPEN $oid ($o)" \
   && bash "$CLI" claims 2>/dev/null | grep -q "proposal $pid from $p"; then
  echo "ok   the objection and the proposal are still attributed to their real authors"
else
  echo "FAIL attribution moved: $(bash "$CLI" claims 2>/dev/null | grep -E "OPEN|proposal")"; fail=1
fi

# --- 4. recv and transcript must agree about the author -------------------------
# The two readers are separate code (c_drain and c_all). Deriving in one only is worse than
# deriving in neither: the same message renders under two authors depending on the path,
# and the disagreement looks like a bug somewhere else entirely.
fresh a b c
forge a 1 b msg '[]' "which reader are you?"
via_recv=$(COUNCIL_ME=c bash "$CLI" recv --timeout 1 2>/dev/null \
             | jq -r 'select(.text == "which reader are you?") | .from')
via_all=$(bash "$CLI" order 2>/dev/null \
             | jq -r 'select(.text == "which reader are you?") | .from')
if [ "$via_recv" = a ] && [ "$via_all" = a ]; then
  echo "ok   recv and the canonical log both named the writing lane"
else
  echo "FAIL the two readers disagree: recv=$via_recv canonical=$via_all (want a and a)"; fail=1
fi

# --- 5. the honest author-gated path still works --------------------------------
# The fix must not buy case 1 by breaking the rule it protects: a real withdraw from the
# proposal's real author still has to kill the proposal.
fresh a b
p=$(say_floor propose '[]' "Adopt the thing.")
pid=$(id_of propose)
COUNCIL_ROOM="$R" COUNCIL_ME="$p" bash "$CLI" send --act withdraw \
  --refs "$(jq -c -n --arg i "$pid" '[$i]')" --hand "I withdraw it" >/dev/null 2>&1
read -r live1 open1 <<<"$(live_open)"
if [ "$live1" = 0 ]; then
  echo "ok   an honest withdraw by the proposal's own author still kills it"
else
  echo "FAIL derivation broke the legitimate close path (live=$live1, want 0)"; fail=1
fi

# --- 6. the opening round's waiting list is derived too -------------------------
# `floor` tells a supervisor which seats the barrier is still waiting for, and it built that
# list from `.from`. A round-0 message claiming a peer's name therefore reported the wrong
# seat as having spoken and the wrong seat as late — the supervisor is told to go and look
# at a terminal that is doing nothing wrong, while the one that never started is invisible.
rm -rf "$R"; mkroom "$R" a b c; echo "q" > "$R/agenda.md"
jq '.mode = "roundtable"' "$R/roster.json" > "$R/roster.next" && mv "$R/roster.next" "$R/roster.json"
# sent_ms must be NOW: c_barrier closes the round once the oldest position is older than
# round_deadline_ms, and a toy timestamp closes it on the spot — the case would then stop
# testing the open barrier it exists for.
NOW_MS=$(( $(date +%s) * 1000 ))
round0() { # <lane> <claimed-from> <lamport> <text>
  jq -c -n --arg p "$1" --arg f "$2" --argjson l "$3" --arg t "$4" --argjson ms "$NOW_MS" \
    '{id:($p+"-1"),from:$f,lamport:$l,deps:{},act:"propose",refs:[],to:["*"],
      hand:false,turn:null,round:0,text:$t,created_at:"t",sent_ms:$ms}' > "$R/lane/$1/000001.json"
  printf '1' > "$R/state/$1.seq"
}
round0 a a 1 "a opening position"
round0 b c 2 "b writing, claiming to be c"      # the accident: a stale identity in seat b
waiting=$(bash "$CLI" floor 2>/dev/null | sed -n 's/.*waiting=\([^ ]*\).*/\1/p')
if [ "$waiting" = c ]; then
  echo "ok   the barrier is still waiting for the seat that has not spoken"
else
  echo "FAIL the barrier believed a claimed author: waiting=$waiting (want c)"; fail=1
fi

# --- 7. an ordinary room is unaffected ------------------------------------------
fresh a b
p=$(say_floor propose '[]' "An ordinary proposal.")
line=$(bash "$CLI" transcript 2>/dev/null | grep 'An ordinary proposal.')
if [ -n "$p" ] && printf '%s' "$line" | grep -q "^\[$p propose\]"; then
  echo "ok   an ordinary room still sends, reads and attributes normally"
else
  echo "FAIL a normal send or its attribution broke: '$line'"; fail=1
fi

[ "$fail" = 0 ] && echo "t9e PASS" || echo "t9e FAIL"
exit $fail
