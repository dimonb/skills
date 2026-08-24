#!/usr/bin/env bash
# t14 — the read-only verbs that keep a participant off the room's paths.
#
# A room lives inside the git dir, and an agent whose file trust follows the working tree
# asks permission for every read in there — which stalls the participant while it holds the
# floor. `agenda` and `decision` exist so those reads travel the entrypoint instead, so what
# this test guards is their CONTRACT: what they print, and what they exit with. A wrong exit
# code here is not cosmetic — a participant that reads one as breakage stops instead of
# speaking, which is the failure the verbs were added to remove.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
R="${TMPDIR:-/tmp}/council-test/t14"; rm -rf "$R"
mkroom "$R" a b c
export COUNCIL_ROOM="$R" ROOM="$R"
v() { bash "$CLI" verdict | cut -d' ' -f1; }

# --- agenda, when there is none ------------------------------------------------------
# `mkroom` writes no agenda.md, exactly like a room built by hand. This must NOT be an
# error: `up` writes this same placeholder when it is given no agenda.
out=$(bash "$CLI" agenda); rc=$?
[ "$rc" = 0 ] || { echo "FAIL agenda with no file exited $rc, expected 0"; exit 1; }
[ "$out" = "(no agenda given)" ] || { echo "FAIL agenda with no file said: $out"; exit 1; }
echo "no agenda file:     exit 0, '$out'"

# --- agenda, the normal case ---------------------------------------------------------
printf 'Where should the room keep its history?\nSecond line, kept verbatim.\n' > "$R/agenda.md"
out=$(bash "$CLI" agenda); rc=$?
[ "$rc" = 0 ] || { echo "FAIL agenda exited $rc, expected 0"; exit 1; }
[ "$out" = "$(cat "$R/agenda.md")" ] || { echo "FAIL agenda did not print the file verbatim"; exit 1; }
echo "agenda:             exit 0, $(printf '%s' "$out" | wc -l | tr -d ' ') lines, verbatim"

# `agenda` must not need to know who is asking — a participant runs it before anything else,
# and `--me` is the launcher's business, not the agenda's.
( unset COUNCIL_ME; bash "$CLI" agenda >/dev/null ) \
  || { echo "FAIL agenda needs COUNCIL_ME, it must not"; exit 1; }

# --- decision, while the room is open ------------------------------------------------
# Exit 1 is a STATUS here, the same way `verdict` reports a live room. The message goes to
# stdout so a participant that captured the output sees why it is empty.
out=$(bash "$CLI" decision); rc=$?
[ "$rc" = 1 ] || { echo "FAIL decision on an open room exited $rc, expected 1"; exit 1; }
case "$out" in *"no decision yet"*) ;; *) echo "FAIL decision on an open room said: $out"; exit 1 ;; esac
echo "open room:          exit 1, '$out'"

# --- decision, after a real decide ---------------------------------------------------
prop=$(say_floor propose '[]' "Keep the history as one lane per author.")
obj=$(say_floor  object  '["'"$prop"'-1"]' "Then a reader scans N directories on every poll.")
say_floor amend '["'"$prop"'-1","'"$obj"'-1"]' "One lane per author; readers probe upward from a cursor." >/dev/null
say_floor msg '[]' "Agreed." >/dev/null
say_floor msg '[]' "No objections." >/dev/null
say_floor msg '[]' "Record it." >/dev/null
[ "$(v)" = ready-to-decide ] || { echo "FAIL expected ready-to-decide, got $(v)"; exit 1; }
# Decide as whoever holds the floor. `decide` posts an `act: decide` message, and c_send
# refuses one from a peer that is not the floor holder — so a hard-coded chair makes this
# test depend on where the rotation happens to have stopped. What that refusal does to the
# room is a separate defect, deliberately not exercised here.
chair=$(bash "$CLI" floor | sed -n 's/.*floor=\([^ ]*\).*/\1/p')
[ -n "$chair" ] || { echo "FAIL could not read the floor holder"; exit 1; }
written=$(COUNCIL_ME="$chair" bash "$CLI" decide) || { echo "FAIL decide refused"; exit 1; }
[ "$(v)" = decided ] || { echo "FAIL the room did not close, got $(v)"; exit 1; }

out=$(bash "$CLI" decision); rc=$?
[ "$rc" = 0 ] || { echo "FAIL decision on a decided room exited $rc, expected 0"; exit 1; }
[ "$out" = "$(cat "$written")" ] || { echo "FAIL decision did not print the record verbatim"; exit 1; }
case "$out" in *"status: **decided**"*) ;; *) echo "FAIL the record read back does not say decided"; exit 1 ;; esac
echo "decided room:       exit 0, $(printf '%s' "$out" | wc -l | tr -d ' ') lines, verbatim"

# --- the protocol a participant receives must not hand out a path --------------------
# The whole point of the verbs. If the rendered protocol still tells a participant to open a
# file in the room, the prompt class comes straight back — and it comes back silently,
# because nothing else in the suite reads the protocol at all.
#
# Check the WHOLE surface, not just the channel file: `up` renders each protocol as the
# channel rules PLUS the scenario's role block, and runs the `__ROOM__` substitution over
# both halves. Grepping only the channel file would leave the other half of every rendered
# protocol unguarded, which is the vacuous shape this repo has been bitten by before.
proto="$SKILL/protocol/_channel.md"
if grep -nE '__ROOM__/[a-z]' "$proto" "$SKILL"/scenarios/*.md; then
  echo "FAIL a participant's protocol still points at a path inside the room"; exit 1
fi
for verb in agenda protocol decision; do
  grep -q "council.sh $verb" "$proto" || { echo "FAIL the protocol never mentions council.sh $verb"; exit 1; }
done
echo "protocol surface:   no room paths in channel or scenarios, all three verbs named"

# --- the self-participant's protocol is reachable without a path ---------------------
# `up` writes protocol-<peer>.md for EVERY peer but launches no terminal for the one named
# by --me, so that participant is handed its role by nothing. Without this verb its only
# route to its own rules is the path the rules themselves forbid.
printf 'You are peer a. Your role: proposer.\n' > "$R/protocol-a.md"
out=$(COUNCIL_ME=a bash "$CLI" protocol); rc=$?
[ "$rc" = 0 ] || { echo "FAIL protocol exited $rc, expected 0"; exit 1; }
[ "$out" = "$(cat "$R/protocol-a.md")" ] || { echo "FAIL protocol did not print the file verbatim"; exit 1; }
# A peer with no protocol file is a real error, unlike a missing agenda: it means the room
# was built wrong, and silently printing nothing would leave the participant with no rules.
COUNCIL_ME=b bash "$CLI" protocol >/dev/null 2>&1
[ $? = 2 ] || { echo "FAIL protocol for a peer with no file did not exit 2"; exit 1; }
echo "protocol verb:      exit 0 verbatim, exit 2 when the room has none"

echo "t14 PASS"
