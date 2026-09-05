#!/usr/bin/env bash
# t18 — the room's turn cycle as a DECLARED FLOW GRAPH (FLOW-04). Turn/round admission is decided
# in ONE place — the guard evaluating the graph — so no reader re-derives the opening barrier and a
# wedged or slow reader cannot desync the round (the #74 "hold the opening barrier in every reader"
# class). It pins four things:
#   1. c_phase tracks the room lifecycle from the declared graph: a token room begins at
#      `exchange`, advances to `closing` (ready-to-decide) and to `` (decided); a roundtable room
#      begins at `opening` and advances to `exchange` when the round completes;
#   2. the opening gate is ONE authority — c_round_open / c_round_closed / c_round_complete and the
#      graph's `opening` node all derive from c_barrier, so overriding that one function moves them
#      together and none holds a private copy of the rule;
#   3. the opening accessors are exit-status-identical to the `[ "$(c_barrier)" = open|closed ]`
#      tests they replaced, on every input — the (unreachable) print-nothing case included, where
#      the room is treated as NOT verifiably closed (fail-closed);
#   4. the phase is a PURE FUNCTION OF THE LOG: a reader that has not drained its inbox computes the
#      same phase as one fully caught up, so its staleness cannot desync the round.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
fail=0

# c_phase as a seat would compute it — sourcing the room's own code with SKILL exported, exactly
# as council.sh runs it (v_verdict, reached through the graph's closure predicate, reads
# lib/claims.jq at "$SKILL/lib/claims.jq").
phase() { # <room> <peer>
  SKILL="$SKILL" COUNCIL_ROOM="$1" COUNCIL_ME="$2" \
    bash -c '. "$SKILL/lib/lib.sh"; . "$SKILL/lib/verbs.sh"; c_phase'
}

# ------------------------------------------------- 1a. c_phase over a token room's lifecycle
R="$COUNCIL_TEST_ROOT/t18"; rm -rf "$R"
mkroom "$R" a b c                          # token mode by default: no opening barrier
export COUNCIL_ROOM="$R" ROOM="$R"
echo "Where should the room keep its history?" > "$R/agenda.md"

# A token room has c_barrier == closed from the start, so the graph is already past `opening`.
[ "$(phase "$R" a)" = exchange ] \
  || { echo "FAIL a fresh token room is not at 'exchange' (got '$(phase "$R" a)')"; fail=1; }

# Drive it to ready-to-decide (t5's recipe: propose, object, an amend that closes it, then a full
# lap of chatter). The phase must advance to `closing`.
prop=$(say_floor propose '[]' "Keep one lane per author, total order by Lamport clock.")
obj=$(say_floor  object  '["'"$prop"'-1"]' "Then a reader scans N directories per poll.")
say_floor amend '["'"$prop"'-1","'"$obj"'-1"]' "One lane per author; probe upward from the cursor." >/dev/null
say_floor msg '[]' "Agreed." >/dev/null
say_floor msg '[]' "No objections." >/dev/null
say_floor msg '[]' "Then record it." >/dev/null
[ "$(bash "$CLI" verdict | cut -d' ' -f1)" = ready-to-decide ] \
  || { echo "FAIL the fixture did not reach ready-to-decide"; fail=1; }
[ "$(phase "$R" a)" = closing ] \
  || { echo "FAIL a ready-to-decide room is not at 'closing' (got '$(phase "$R" a)')"; fail=1; }

# Decide, and the graph closes: c_phase is empty (the room is decided). The phase stays empty even
# though the verdict flips from `ready-to-decide` to `decided` — the `closing` node's OR-with-record
# keeps it monotonic rather than falling back to `exchange`. (stderr is suppressed: the record is
# written before decide's own trailing `decide` message, whose floor check can legitimately refuse
# the caller, exactly as in t5.)
COUNCIL_ME=a bash "$CLI" decide >/dev/null 2>&1 || { echo "FAIL decide refused"; fail=1; }
[ -z "$(phase "$R" a)" ] \
  || { echo "FAIL a decided room's phase is not empty (got '$(phase "$R" a)')"; fail=1; }
echo "c_phase tracks a token room: exchange -> closing -> decided (empty)"

# ------------------------------------------------- 1b. c_phase over a roundtable room's opening
R2="$COUNCIL_TEST_ROOT/t18b"; rm -rf "$R2"
mkroom "$R2" a b c
export COUNCIL_ROOM="$R2" ROOM="$R2"
jq '.mode="roundtable" | .round_deadline_ms=600000' "$R2/roster.json" > "$R2/r.tmp" && mv "$R2/r.tmp" "$R2/roster.json"
[ "$(phase "$R2" a)" = opening ] \
  || { echo "FAIL a fresh roundtable room is not at 'opening' (got '$(phase "$R2" a)')"; fail=1; }
say a propose '[]' "position a"
[ "$(phase "$R2" a)" = opening ] \
  || { echo "FAIL an open round is not at 'opening' after one of three positions"; fail=1; }
say b propose '[]' "position b"
say c propose '[]' "position c"
[ "$(phase "$R2" a)" = exchange ] \
  || { echo "FAIL a completed round did not advance to 'exchange' (got '$(phase "$R2" a)')"; fail=1; }
echo "c_phase tracks a roundtable room: opening (through the positions) -> exchange on completion"

# ...and the guard's phase is SURFACED to a supervisor through the CLI — the production use of
# c_phase. `status` runs v_status, which reads the phase via c_phase -> flow_phase over the graph.
sout=$(COUNCIL_ROOM="$R2" COUNCIL_ME=a bash "$CLI" status 2>/dev/null)
case "$sout" in *"phase: exchange"*) ;; *) echo "FAIL status did not surface 'phase: exchange' via the guard"; fail=1 ;; esac
echo "status surfaces the room phase through the guard (c_phase is used in production, not only in tests)"

# ------------------------------------------------- 2+3. the opening gate is ONE authority
# Override the single computation (c_barrier) and read every consumer of the opening decision. All
# move together — the accessors, and the graph's `opening` node through c_phase — so none holds a
# private copy. Each line is "<c_round_open $?> <c_round_closed $?> <c_round_complete $?> <c_phase>".
# The empty case pins the fail-closed stance: neither open nor closed is TRUE, so `! c_round_closed`
# (round not verifiably closed) is what the decide gate reads.
R3="$COUNCIL_TEST_ROOT/t18c"; rm -rf "$R3"; mkroom "$R3" a b c
auth=$(SKILL="$SKILL" COUNCIL_ROOM="$R3" COUNCIL_ME=a bash -c '
  . "$SKILL/lib/lib.sh"; . "$SKILL/lib/verbs.sh"
  c_barrier() { printf "%s" "$FORCE"; }         # force the one authority the readers share
  for FORCE in open closed ""; do
    printf "%s %s %s %s\n" \
      "$(c_round_open;     echo $?)" \
      "$(c_round_closed;   echo $?)" \
      "$(c_round_complete; echo $?)" \
      "$(c_phase)"
  done')
exp=$'0 1 1 opening\n1 0 0 exchange\n1 1 1 opening'
[ "$auth" = "$exp" ] || {
  echo "FAIL the opening decision is not one shared authority:"
  echo "  expected: [$exp]"
  echo "  actual:   [$auth]"
  fail=1
}
echo "the opening gate is one authority: overriding c_barrier moves the accessors and c_phase together"

# ------------------------------------------------- 4. the phase is a pure function of the log
# A wedged reader (cursor at 0, never drained) and a fully-caught-up one compute the SAME phase,
# because c_phase reads the log, not the reader's cursor. Shown at both lifecycle points.
R4="$COUNCIL_TEST_ROOT/t18d"; rm -rf "$R4"; mkroom "$R4" a b c
export COUNCIL_ROOM="$R4" ROOM="$R4"
jq '.mode="roundtable" | .round_deadline_ms=600000' "$R4/roster.json" > "$R4/r.tmp" && mv "$R4/r.tmp" "$R4/roster.json"
say a propose '[]' "position a"          # round still open; c has drained nothing
[ "$(phase "$R4" c)" = "$(phase "$R4" a)" ] && [ "$(phase "$R4" c)" = opening ] \
  || { echo "FAIL an open round: a wedged reader disagrees on the phase (c=$(phase "$R4" c) a=$(phase "$R4" a))"; fail=1; }
say b propose '[]' "position b"
say c propose '[]' "position c"          # round complete; c STILL has not drained a or b
COUNCIL_ROOM="$R4" COUNCIL_ME=a bash "$CLI" recv >/dev/null 2>&1 || true   # a drains; c does not
[ "$(phase "$R4" c)" = "$(phase "$R4" a)" ] && [ "$(phase "$R4" c)" = exchange ] \
  || { echo "FAIL a completed round: a wedged reader disagrees on the phase (c=$(phase "$R4" c) a=$(phase "$R4" a))"; fail=1; }
echo "the phase is the log's, not the reader's: a wedged seat and a caught-up seat agree"

# Rooms this file built are its own to remove, so a keeper does not outlive it under later tests.
rm -rf "$R" "$R2" "$R3" "$R4"

[ "$fail" = 0 ] && echo "t18 PASS" || echo "t18 FAIL"
exit $fail
