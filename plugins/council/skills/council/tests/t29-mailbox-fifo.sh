#!/usr/bin/env bash
# t29 — a FIFO planted in the shared mailbox cannot hang `status` (#246). `say`'s half — its text
# still submitted, its verb still returning — is t21 section 5, which has the faked terminal.
#
# The mailbox is as writable by a participant as the room is, and every council writer into it
# used to open its target with a plain `>`, while the one glob reader handed every match to jq. A
# FIFO in place of any of them blocked the open for as long as nothing read the FIFO: the tick
# printed nothing, and the supervisor's `--alarms-only` loop went quiet about the very stall it was
# armed for. Each case below plants a FIFO where a writer writes or where the glob reads, runs the
# verb under a bound, and asserts that it RETURNED and still printed what it is for.
#
# NOT COVERED, and named so a green run is not read as more: the read residual #246 deferred — a
# regular file swapped for a FIFO between a reader's `[ -f ]` check and its open. That is a race
# inside a few instructions, which no fixture here can hit on purpose; it is named at the code
# (above STALL_ESCALATE_AT in lib/verbs.sh) and in SKILL.md's residuals.
#
# MUTATION CHECK, run by hand when this file changes: put back a plain `>` for the status
# signature or either firing record, or drop the `[ -f ]` prefilter from `_stall_escalate`'s or
# `_stall_sent_note`'s glob read, and the case for that site reports HUNG while the others stay
# green. `policy_escalate`'s write is NOT reached here: its `-e` probe steps over a FIFO already at
# the next free name, so only a FIFO swapped in after the probe could reach that open, and no
# fixture can time that. Its conversion is covered only by t-policy's direct cases on the helper.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"

fails=0
ok() { # <what> <expected> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"; fails=$((fails+1)); fi
}
cnt() { printf '%s' "$1" | grep -c -- "$2"; }

MB="$POLICY_MAILBOX_DIR"; mkdir -p "$MB"
FIFOS=()
plant() { rm -rf "$1"; mkfifo "$1" && FIFOS+=("$1"); } # <path>
# Unblock and remove everything planted so far. Called after every case, so each case stands on
# its own: a FIFO left from one would otherwise hang the next case's verb on the OLD code, and the
# mutation check would then be unable to say which site it had reverted.
unplant() {
  local f
  if [ "${#FIFOS[@]}" -gt 0 ]; then
    for f in "${FIFOS[@]}"; do [ -p "$f" ] && { : <>"$f"; rm -f "$f"; }; done
  fi
  FIFOS=()
}

# bounded <secs> <cmd>... — the command's output followed by `rc=<n>`, or `HUNG` when it had not
# returned within <secs>. No timeout(1): stock macOS ships none, which is the same reason the
# production code cannot bound its own opens. A hung run leaves a descendant blocked in open(2)
# that killing the job does not reach, so every planted FIFO is then opened read-write once, which
# pairs with the blocked opener and lets it finish — otherwise it would outlive the suite.
BOUND_OUT="$COUNCIL_TEST_ROOT/t29-bounded.out"
bounded() {
  local secs="$1" pid i=0 f; shift
  "$@" >"$BOUND_OUT" 2>&1 & pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$i" -ge $(( secs * 10 )) ]; then
      kill "$pid" 2>/dev/null
      if [ "${#FIFOS[@]}" -gt 0 ]; then
        for f in "${FIFOS[@]}"; do [ -p "$f" ] && : <>"$f"; done
      fi
      wait "$pid" 2>/dev/null
      printf 'HUNG'
      return 0
    fi
    sleep 0.1; i=$((i + 1))
  done
  wait "$pid"; i=$?
  cat "$BOUND_OUT"; printf '\nrc=%s' "$i"
}
returned() { case "$1" in *HUNG) printf no ;; *) printf yes ;; esac; }

# The aging pair t27 and t28 use: the room is older than the floor, so the stall lands on the
# ordinary arm and not on the clock-is-wrong one.
age_room() { # <room> <seconds>
  local r="$1" now_ms; now_ms=$(( $(date +%s) * 1000 ))
  jq --argjson c "$(( now_ms - $2 * 1000 ))" '.created_ms = $c' "$r/roster.json" > "$r/roster.tmp"
  mv "$r/roster.tmp" "$r/roster.json"
}
age_messages() { # <room> <seconds>
  local r="$1" now_ms f; now_ms=$(( $(date +%s) * 1000 ))
  for f in "$r"/lane/*/*.json; do
    [ -f "$f" ] || continue
    jq --argjson s "$(( now_ms - $2 * 1000 ))" '.sent_ms = $s' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  done
}
stalled_room() { # <dir>
  rm -rf "$1"; mkroom "$1" a b c
  export COUNCIL_ROOM="$1" ROOM="$1"
  say_floor msg '[]' "Taking a while." >/dev/null
  age_room "$1" 9000; age_messages "$1" 1200
}
SECS=20

# --- 1. the status signature (`--only-changed`) -------------------------------------------------
R="$COUNCIL_TEST_ROOT/t29a"; stalled_room "$R"
plant "$MB/council-status-sig-t29a"
o=$(bounded "$SECS" bash "$CLI" status --only-changed)
ok "a FIFO at the status signature: --only-changed returns"   yes "$(returned "$o")"
ok "...and prints the block"                                  1   "$(cnt "$o" '^=== council')"
ok "...and the signature is a regular file again"             yes "$([ -f "$MB/council-status-sig-t29a" ] && echo yes || echo no)"

unplant
# --- 2. the STALL firing records, one per monitor ------------------------------------------------
R="$COUNCIL_TEST_ROOT/t29b"; stalled_room "$R"
plant "$MB/council-stall-alarms-t29b"
o=$(bounded "$SECS" bash "$CLI" status --alarms-only)
ok "a FIFO at the alarms record: --alarms-only returns"       yes "$(returned "$o")"
ok "...and prints the STALL line"                             1   "$(cnt "$o" '🛑 STALL')"
o=$(bounded "$SECS" bash "$CLI" status --alarms-only)
ok "...and the next tick reads the record it wrote"           1   "$(cnt "$o" '🛑 STALL (still)')"
unplant
R="$COUNCIL_TEST_ROOT/t29c"; stalled_room "$R"
plant "$MB/council-stall-block-t29c"
o=$(bounded "$SECS" bash "$CLI" status --only-changed)
ok "a FIFO at the block record: --only-changed returns"       yes "$(returned "$o")"
ok "...and prints the STALL line"                             1   "$(cnt "$o" 'alarms:.*🛑 STALL')"

unplant
# --- 3. the glob `_stall_escalate` de-duplicates against ----------------------------------------
R="$COUNCIL_TEST_ROOT/t29d"; stalled_room "$R"
plant "$MB/council-planted-1.json"
o=$(bounded "$SECS" bash "$CLI" status)
ok "a FIFO matching the notice glob: status returns"          yes "$(returned "$o")"
ok "...and prints the STALL line"                             1   "$(cnt "$o" '🛑 STALL')"
ok "...and the notice is still pushed"                        1   "$(ls "$MB"/council-t29d-*.json 2>/dev/null | wc -l | tr -d ' ')"
unplant
# The same notice's own next-free name: the `-e` probe steps over it, the write lands on the next.
R="$COUNCIL_TEST_ROOT/t29e"; stalled_room "$R"
plant "$MB/council-t29e-1.json"
o=$(bounded "$SECS" bash "$CLI" status)
ok "a FIFO at the notice's next free name: status returns"    yes "$(returned "$o")"
ok "...and the notice lands on the name after it"             yes "$([ -f "$MB/council-t29e-2.json" ] && echo yes || echo no)"

unplant
# --- 4. the said records `_stall_sent_note` reads -----------------------------------------------
# A said record is read on every firing after the first, so the second tick is the one that opens
# the set; the old single-file name is planted too, since nothing may open that any more either.
R="$COUNCIL_TEST_ROOT/t29f"; stalled_room "$R"
plant "$MB/council-said-t29f.aaaaaaaa"
plant "$MB/council-said-t29f"
bounded "$SECS" bash "$CLI" status --alarms-only >/dev/null
o=$(bounded "$SECS" bash "$CLI" status --alarms-only)
ok "a FIFO among the said records: --alarms-only returns"     yes "$(returned "$o")"
ok "...and reads it as nothing sent"                          1   "$(cnt "$o" 'nothing sent')"

# Last, so the root's removal does not race a blocked open.
unplant

if [ "$fails" -eq 0 ]; then echo "t29-mailbox-fifo: all passed"; exit 0; fi
echo "t29-mailbox-fifo: $fails FAILED"; exit 1
