#!/usr/bin/env bash
# t23 — `decide` must tell the room it closed, and must not report a clean close when it could not.
#
# The room's record is written before the announcement goes out, so the two halves of a close can
# come apart: the record on disk while the room is never told. That asymmetry is the defect. A seat
# learns the room is over by polling `council.sh decision` (protocol/_channel.md makes the record
# the single stop signal), and the announcement is what RINGS each seat so that poll happens now
# rather than after its `recv` times out. Lose the announcement and the room stays asleep while the
# supervisor is told everything landed.
#
# Two things are pinned, and the second is the one that was actually broken:
#
#   1. The announcement lands even when the closer does not hold the floor. `decide` is a chair
#      action taken out of band, so the rotation has nothing to say about it — it goes `--hand`,
#      which precedes both the floor check and the barrier check in c_send.
#   2. When the announcement genuinely cannot be sent, `decide` does NOT exit 0. It still prints
#      the record (the close stands — the record is on disk and re-running `decide` answers 3),
#      but it exits 4 and says the room was not told.
#
# Why the suite did not catch this: t5 decides as a hard-coded peer after a fixed number of turns,
# and that count happens to leave the floor with exactly that peer, so its assertion passes on a
# coincidence of the rotation. t14 reads the floor first and decides as its holder, for the same
# reason. Neither ever closes a room from a seat that does not hold the floor, which is the
# ordinary case for a supervisor and the one that was silently ringing nobody.
#
# The turn assertion is not decoration either. The narrow fix the issue proposed — exempting
# `decide` from the floor check the way `skip` is exempt — would send the announcement but stamp
# `turn=$(c_turns)` on it, i.e. land a bookkeeping message on top of whoever legitimately holds
# that turn, for c_canon to settle against a real contribution. `--hand` consumes no turn, and
# that is asserted rather than assumed.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
R="$COUNCIL_TEST_ROOT/t23-decide-announces"; rm -rf "$R"
export COUNCIL_ROOM="$R" ROOM="$R"
fail=0

# Drive a fresh three-peer room to ready-to-decide. Every line is spoken by whoever holds the
# floor, so this never depends on where the rotation stopped — which is the bug's whole subject.
ripe() {
  rm -rf "$R"; mkroom "$R" a b c
  echo "Should the log keep one lane per author?" > "$R/agenda.md"
  local prop obj
  prop=$(say_floor propose '[]' "Keep the history as one lane per author.")
  obj=$(say_floor  object  '["'"$prop"'-1"]' "Then a reader scans N directories on every poll.")
  say_floor amend '["'"$prop"'-1","'"$obj"'-1"]' "One lane per author; readers probe upward from a cursor." >/dev/null
  say_floor msg '[]' "Agreed."       >/dev/null
  say_floor msg '[]' "No objections." >/dev/null
  say_floor msg '[]' "Record it."     >/dev/null
}

floor_holder() { bash "$CLI" floor | sed -n 's/.*floor=\([^ ]*\).*/\1/p'; }
# A seat that is NOT the floor holder — the supervisor's ordinary position, and the one the old
# code refused with exit 6 and then discarded.
not_the_holder() {
  local h; h=$(floor_holder)
  c_peers_list | grep -v "^$h\$" | head -1
}
# The announcement, as it sits in the log. One line of compact JSON, or nothing.
decide_msg() { bash "$CLI" order 2>/dev/null | jq -c 'select(.act == "decide")' | head -1; }
# Turns the room counts. c_turns excludes hand messages and turn-less ones, so this is exactly
# the quantity a stray announcement would inflate.
turns_now() { bash "$CLI" verdict --json 2>/dev/null | jq -r .turns; }

# --- 1. the room is told, by a closer that does not hold the floor --------------------
ripe
outsider=$(not_the_holder)
[ -n "$outsider" ] || { echo "FAIL could not pick a non-holder"; exit 1; }
before=$(turns_now)
written=$(COUNCIL_ME="$outsider" bash "$CLI" decide); rc=$?
if [ "$rc" != 0 ]; then
  echo "FAIL decide by a non-holder exited $rc, expected 0"; fail=1
elif [ ! -s "$written" ]; then
  echo "FAIL decide printed no usable record path"; fail=1
fi

msg=$(decide_msg)
if [ -z "$msg" ]; then
  echo "FAIL the room was never told — no act:decide message in the log (this is the bug)"; fail=1
else
  from=$(printf '%s' "$msg" | jq -r .from)
  hand=$(printf '%s' "$msg" | jq -r .hand)
  turn=$(printf '%s' "$msg" | jq -r '.turn // "null"')
  [ "$from" = "$outsider" ] || { echo "FAIL announcement came from '$from', expected '$outsider'"; fail=1; }
  [ "$hand" = true ]        || { echo "FAIL announcement is hand=$hand — it would compete for a turn"; fail=1; }
  [ "$turn" = null ]        || { echo "FAIL announcement stamped turn $turn — it must consume none"; fail=1; }
fi

after=$(turns_now)
[ "$after" = "$before" ] || { echo "FAIL the announcement consumed a turn ($before -> $after)"; fail=1; }

# It must also read as an in-order message, or the record's own transcript marks the close
# "(out of turn)". c_canon calls a hand message valid; assert it rather than trusting that.
if [ -n "$msg" ]; then
  valid=$(bash "$CLI" order 2>/dev/null | jq -r 'select(.act == "decide") | .valid' | head -1)
  [ "$valid" = true ] || { echo "FAIL the announcement reads as invalid ($valid)"; fail=1; }
fi
[ "$(verdict1)" = decided ] || { echo "FAIL the room did not close"; fail=1; }
# Only on a pass. A summary line printed next to its own FAILs reads as a success to anyone
# skimming the run, which is the shape this whole file is about.
[ "$fail" = 0 ] && echo "non-holder close:   exit 0, room told, hand=true, turns $before -> $after"

# --- 2. an announcement that cannot be sent is not reported as a clean close ----------
# The send is failed at the filesystem: c_atomic writes `<lane>/NNNNNN.json.tmp.$$` and moves it,
# so a lane the closer cannot write fails the write and c_send returns 1. Everything before it —
# the record, board/status — has already happened, which is precisely the state under test.
#
# Skipped for a root runner, which ignores the mode bits and would make this assertion vacuous.
if [ "$(id -u)" = 0 ]; then
  echo "announcement fails: SKIPPED (running as root — mode bits do not apply)"
else
  ripe
  outsider=$(not_the_holder)
  # Both guards matter. Without the -n test an empty $outsider would chmod "$R/lane" itself; and
  # without the trap, a test killed between the two chmods leaves a mode-500 directory that
  # `rm -rf` CANNOT remove while it still holds files, so run-all.sh's EXIT trap fails and the
  # whole run root leaks permanently. The suite's ceiling group-kills a wedged test, so this is a
  # reachable path rather than a hypothetical one.
  [ -n "$outsider" ] || { echo "FAIL could not pick a non-holder"; exit 1; }
  # CHAINED onto _helpers.sh's trap, never replacing it — a bare `trap … EXIT` here would drop
  # _council_test_cleanup, which is what kills this room's keeper and the test's background jobs.
  # `( exit $rc )` restores $? before delegating, because _council_test_cleanup opens with
  # `local rc=$?` and would otherwise report the chmod's status as the test's exit code.
  _t23_restore_lane() {
    local rc=$?
    chmod 700 "$R/lane/$outsider" 2>/dev/null
    ( exit $rc ); _council_test_cleanup
  }
  trap _t23_restore_lane EXIT
  chmod 500 "$R/lane/$outsider" || { echo "FAIL could not make the lane read-only"; exit 1; }
  err="$COUNCIL_TEST_ROOT/t23.err"
  written=$(COUNCIL_ME="$outsider" bash "$CLI" decide 2>"$err"); rc=$?
  chmod 700 "$R/lane/$outsider"

  [ "$rc" = 4 ] || { echo "FAIL a refused announcement exited $rc, expected 4"; fail=1; }
  # The record is the room's output and `decision` is the protocol's stop signal, so a caller
  # that captures stdout must still get the path — the close really did happen.
  if [ -z "$written" ] || [ ! -s "$written" ]; then
    echo "FAIL the record path was withheld on the failure path"; fail=1
  fi
  [ "$(cat "$R/board/status")" = decided ] || { echo "FAIL board/status was not written"; fail=1; }
  [ -z "$(decide_msg)" ] || { echo "FAIL a decide message exists — the send did not actually fail"; fail=1; }
  # The operator must be told which of the two states they are in: record written, room not told.
  grep -q 'the record is written' "$err" || { echo "FAIL stderr does not say the record stands"; fail=1; }
  grep -q 'not told'             "$err" || { echo "FAIL stderr does not say the room was not told"; fail=1; }
  # And the room is genuinely closed, so a supervisor that retries gets the already-decided answer
  # rather than a second record. That is what makes exit 4 safe to not retry on.
  COUNCIL_ME="$outsider" bash "$CLI" decide >/dev/null 2>&1; rc2=$?
  [ "$rc2" = 3 ] || { echo "FAIL a re-run after the failed announcement exited $rc2, expected 3"; fail=1; }
  [ "$fail" = 0 ] && echo "announcement fails: exit 4, record printed, status decided, re-run answers 3"
fi

# --- 2b. a record that could not be written is not reported as a close -----------------
# The defect one step ABOVE the announcement, and strictly worse than it: the record and
# board/status were bare redirects whose failure the shell reports to nobody, so `decide` printed
# the path of a file that does not exist, announced "decision written" to the room, and exited 0 —
# while every reader still saw the room as open. The room was told a lie about a record that was
# not there. Exit 1 (not 4): 4 means the record IS written, and the two must never be confused.
if [ "$(id -u)" = 0 ]; then
  echo "record unwritable: SKIPPED (running as root — mode bits do not apply)"
else
  ripe
  outsider=$(not_the_holder)
  [ -n "$outsider" ] || { echo "FAIL could not pick a non-holder"; exit 1; }
  _t23_restore_board() {
    local rc=$?
    chmod 700 "$R/board" 2>/dev/null
    ( exit $rc ); _council_test_cleanup
  }
  trap _t23_restore_board EXIT
  chmod 500 "$R/board" || { echo "FAIL could not make board/ read-only"; exit 1; }
  err2="$COUNCIL_TEST_ROOT/t23b.err"
  out2=$(COUNCIL_ME="$outsider" bash "$CLI" decide 2>"$err2"); rc3=$?
  chmod 700 "$R/board"

  [ "$rc3" = 1 ] || { echo "FAIL an unwritable record exited $rc3, expected 1"; fail=1; }
  # No path on stdout: the room is NOT closed, so a caller must not be handed a record to read.
  [ -z "$out2" ] || { echo "FAIL a record path was printed for a record that was never written: '$out2'"; fail=1; }
  [ ! -s "$R/board/decision.md" ] || { echo "FAIL a record exists — the write did not actually fail"; fail=1; }
  # And the room must not have been told a decision was written.
  [ -z "$(decide_msg)" ] || { echo "FAIL the room was told a decision was written that does not exist"; fail=1; }
  grep -q 'NOT closed' "$err2" || { echo "FAIL stderr does not say the room is not closed"; fail=1; }
  # The room is genuinely still live, so the ordinary close still works afterwards.
  [ "$(verdict1)" = ready-to-decide ] || { echo "FAIL the room did not stay open, got $(verdict1)"; fail=1; }
  [ "$fail" = 0 ] && echo "record unwritable: exit 1, no path, room untouched and still open"

  # board/status on its OWN, because the fixture above cannot separate the two guards: both files
  # live in board/, so making that directory unwritable fires the record guard first and leaves the
  # status guard unexercised — and an unexercised guard is the thing this suite keeps finding. A
  # writable board/ with a read-only, EMPTY status file reaches it: empty means c_recorded_status
  # still reads the room as open, so this is a live room whose close gets half-way.
  ripe
  outsider=$(not_the_holder)
  : > "$R/board/status"
  chmod 400 "$R/board/status" || { echo "FAIL could not make board/status read-only"; exit 1; }
  err3="$COUNCIL_TEST_ROOT/t23c.err"
  out3=$(COUNCIL_ME="$outsider" bash "$CLI" decide 2>"$err3"); rc4=$?
  chmod 600 "$R/board/status"
  [ "$rc4" = 1 ] || { echo "FAIL an unwritable board/status exited $rc4, expected 1"; fail=1; }
  [ -z "$out3" ] || { echo "FAIL a record path was printed though the close did not complete: '$out3'"; fail=1; }
  grep -q 'board/status could not be' "$err3" || { echo "FAIL stderr does not name board/status as what failed"; fail=1; }
  [ -z "$(decide_msg)" ] || { echo "FAIL the room was told about a close that did not complete"; fail=1; }
  [ "$fail" = 0 ] && echo "status unwritable: exit 1, no path, the failure is named"
fi

# --- 3. a closed room releases `recv --until-floor`, and an OPEN one still waits --------
# The announcement is `--hand`, so it moves no floor — and `recv --until-floor` returns only when
# the floor becomes yours. Without an explicit release a seat that is not the holder when the room
# closes waits out its whole --timeout (540 s by default) with the record already on disk, and
# protocol/_channel.md prescribes exactly that loop, so it is the ordinary path.
#
# THE SECOND ASSERTION IS THE LOAD-BEARING ONE. The release can only ever return EARLIER, so the
# only way to get this wrong is to release too eagerly — which no assertion about a CLOSED room can
# catch. The open-room case is the one that fails if the predicate is broadened.
elapsed_ms() { # <start-ms>
  printf '%s' $(( $(date +%s)*1000 - $1 ))
}
ripe
outsider=$(not_the_holder)

# An open room must still wait: a short timeout, and we require it to have used it up (rc 4).
t0=$(( $(date +%s) * 1000 ))
COUNCIL_ME="$outsider" bash "$CLI" recv --until-floor --timeout 2 >/dev/null 2>&1; rc_open=$?
open_ms=$(elapsed_ms "$t0")
[ "$rc_open" = 4 ] || { echo "FAIL an OPEN room released --until-floor early (rc $rc_open) — the release is too eager"; fail=1; }
[ "$open_ms" -ge 1500 ] || { echo "FAIL an OPEN room returned after ${open_ms}ms, so it did not wait"; fail=1; }

# Now close it, and the same call must come back promptly instead of burning its timeout.
COUNCIL_ME=$(floor_holder) bash "$CLI" decide >/dev/null || { echo "FAIL could not close the room"; fail=1; }
t1=$(( $(date +%s) * 1000 ))
COUNCIL_ME="$outsider" bash "$CLI" recv --until-floor --timeout 20 >/dev/null 2>&1; rc_closed=$?
closed_ms=$(elapsed_ms "$t1")
[ "$rc_closed" = 0 ] || { echo "FAIL a CLOSED room did not release --until-floor (rc $rc_closed)"; fail=1; }
[ "$closed_ms" -lt 10000 ] || { echo "FAIL a CLOSED room took ${closed_ms}ms to release — it waited for the timeout"; fail=1; }
# Plain `recv` is untouched by the release: it already returned on any drained message.
COUNCIL_ME="$outsider" bash "$CLI" recv --peek >/dev/null 2>&1
[ "$fail" = 0 ] && echo "until-floor:        open room waits (${open_ms}ms, rc 4), closed room releases (${closed_ms}ms, rc 0)"

[ "$fail" = 0 ] && echo "t23 passed"
exit $fail
