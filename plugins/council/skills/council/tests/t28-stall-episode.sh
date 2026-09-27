#!/usr/bin/env bash
# t28 — a `🛑 STALL` is an EPISODE, and only its first firing is news (#238, council's half of
# #182). One unbroken hold of the floor prints the full line once, then a one-line delta; the
# third firing with nothing sent becomes `🛑 STALL UNANSWERED` and re-prints the remedy once; and
# none of that ever decides WHETHER the line appears.
#
# The last clause is the load-bearing one. Every new input is mailbox state a seat can write, and
# the rule this repo keeps is that such state may change how an operator-facing line reads and
# never whether it exists — so every tick below also asserts the line is THERE, under both
# monitors, before asserting what it says.
#
# MUTATION CHECK, run by hand when this file changes: delete the `elif … -ge "$STALL_ESCALATE_AT"`
# arm of `_stall_line` in lib/verbs.sh, and every `UNANSWERED` assertion in section 1 goes red
# while the "still printed" ones stay green. That split is what shows the escalation assertions
# are about the arm and not about something the fixture supplies.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
: "${COUNCIL_TEST_ROOT:=$(mktemp -d)}"

fails=0
ok() { # <what> <expected> <got>
  if [ "$2" = "$3" ]; then printf 'ok   %s\n' "$1"
  else printf 'FAIL %s: expected [%s], got [%s]\n' "$1" "$2" "$3"; fails=$((fails+1)); fi
}
cnt() { printf '%s' "$1" | grep -c -- "$2"; }

# The same aging pair t27 uses, and for the same reason: the room is older than the floor, so the
# stall lands on the ordinary arm and not on the clock-is-wrong one.
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
stalled_room() { # <dir> — a room whose floor has been held past the stall threshold
  rm -rf "$1"; mkroom "$1" a b c
  export COUNCIL_ROOM="$1" ROOM="$1"
  say_floor msg '[]' "Taking a while." >/dev/null
  age_room "$1" 9000; age_messages "$1" 1200
  F=$(COUNCIL_ROOM="$1" bash "$CLI" floor | sed -n "s/.*floor=\([^ ]*\).*/\1/p")
}
REMEDY='ANSWERED IN PLACE'
MB="$POLICY_MAILBOX_DIR"

# --- 1. one episode, four firings, under --alarms-only ------------------------------------------
R="$COUNCIL_TEST_ROOT/t28a"; stalled_room "$R"
f1=$(bash "$CLI" status --alarms-only 2>/dev/null)
f2=$(bash "$CLI" status --alarms-only 2>/dev/null)
f3=$(bash "$CLI" status --alarms-only 2>/dev/null)
f4=$(bash "$CLI" status --alarms-only 2>/dev/null)
for i in 1 2 3 4; do
  eval "v=\$f$i"
  ok "firing $i: the stall line is printed"        1 "$(cnt "$v" '🛑 STALL')"
done
ok "firing 1: the full line"                      1 "$(cnt "$f1" "🛑 STALL: $F has held the floor for")"
ok "firing 1: ...with the remedy"                 1 "$(cnt "$f1" "$REMEDY")"
ok "firing 2: one delta line"                     1 "$(cnt "$f2" "🛑 STALL (still): $F — now [0-9]*s, firing 2, first raised 0 min ago; nothing sent")"
ok "firing 2: ...without the remedy"              0 "$(cnt "$f2" "$REMEDY")"
ok "firing 2: ...and not yet escalated"           0 "$(cnt "$f2" '🛑 STALL UNANSWERED')"
ok "firing 3: escalated, nothing sent"            1 "$(cnt "$f3" "🛑 STALL UNANSWERED: $F has held the floor for")"
ok "firing 3: ...re-printing the remedy"          1 "$(cnt "$f3" "$REMEDY")"
ok "firing 4: still escalated"                    1 "$(cnt "$f4" "🛑 STALL UNANSWERED (still): $F — now [0-9]*s, firing 4")"
ok "firing 4: ...as one line, no remedy"          0 "$(cnt "$f4" "$REMEDY")"

# --- 2. something sent: the delta names it and the escalation is withheld ------------------------
R="$COUNCIL_TEST_ROOT/t28b"; stalled_room "$R"
g1=$(bash "$CLI" status --alarms-only 2>/dev/null)
# What `say` writes (t21 section 5 covers that it does); written directly here so this file does
# not need a terminal backend.
printf "%s\t$F\tanswer the prompt in place\n" "$(date +%s)" >>"$MB/council-said-t28b"
g2=$(bash "$CLI" status --alarms-only 2>/dev/null)
g3=$(bash "$CLI" status --alarms-only 2>/dev/null)
ok "sent: firing 2 names what was sent"           1 "$(cnt "$g2" "sent since: say to $F 0 min ago — \"answer the prompt in place\"")"
ok "sent: firing 3 is not escalated"              0 "$(cnt "$g3" '🛑 STALL UNANSWERED')"
ok "sent: ...but still printed, as its delta"     1 "$(cnt "$g3" "🛑 STALL (still): $F — now [0-9]*s, firing 3")"
# A record from BEFORE the first firing is not an answer to this stall, and one from the future is
# not a plausible time — both are ignored rather than read as "sent".
R="$COUNCIL_TEST_ROOT/t28c"; stalled_room "$R"
printf "%s\t$F\told\n%s\t$F\tfuture\n" "$(( $(date +%s) - 600 ))" "$(( $(date +%s) + 600 ))" >"$MB/council-said-t28c"
for i in 1 2 3; do h=$(bash "$CLI" status --alarms-only 2>/dev/null); done
ok "stale and future-dated says are ignored"      1 "$(cnt "$h" "🛑 STALL UNANSWERED: $F")"

# --- 3. the block monitor: printed every tick, with its own memory -------------------------------
R="$COUNCIL_TEST_ROOT/t28d"; stalled_room "$R"
b1=$(bash "$CLI" status --only-changed 2>/dev/null)
b2=$(bash "$CLI" status --only-changed 2>/dev/null)
b3=$(bash "$CLI" status --only-changed 2>/dev/null)
ok "--only-changed: tick 1 prints the full line"  1 "$(cnt "$b1" "alarms:.*🛑 STALL: $F has held")"
ok "--only-changed: tick 2 still prints"          1 "$(cnt "$b2" '^=== council')"
ok "--only-changed: ...its delta"                 1 "$(cnt "$b2" "alarms:.*🛑 STALL (still): $F")"
ok "--only-changed: tick 3 prints, escalated"     1 "$(cnt "$b3" "alarms:.*🛑 STALL UNANSWERED: $F")"
# The fast loop ticking must not spend the block loop's first firing: its first tick in a room the
# fast loop already alarmed on is still the full line.
R="$COUNCIL_TEST_ROOT/t28e"; stalled_room "$R"
bash "$CLI" status --alarms-only >/dev/null 2>&1; bash "$CLI" status --alarms-only >/dev/null 2>&1
b1=$(bash "$CLI" status --only-changed 2>/dev/null)
ok "each monitor keeps its own first firing"      1 "$(cnt "$b1" "$REMEDY")"
# A plain `status` has no memory at all, and does not advance a monitor's.
p=$(bash "$CLI" status 2>/dev/null)
ok "plain status: always the full line"           1 "$(cnt "$p" "🛑 STALL: $F has held the floor for")"
a=$(bash "$CLI" status --alarms-only 2>/dev/null)
ok "...and it did not advance the fast loop"      1 "$(cnt "$a" 'raised 3 times')"

# --- 4. a new episode starts over ---------------------------------------------------------------
R="$COUNCIL_TEST_ROOT/t28f"; stalled_room "$R"
for i in 1 2 3; do bash "$CLI" status --alarms-only >/dev/null 2>&1; done
# The floor moves — a new turn — and the room stalls again at the new count.
say_floor msg '[]' "Done thinking." >/dev/null
age_room "$R" 9000; age_messages "$R" 1200
n1=$(bash "$CLI" status --alarms-only 2>/dev/null)
ok "a new turn is a new episode: full again"      1 "$(cnt "$n1" "$REMEDY")"
ok "...and not escalated"                         0 "$(cnt "$n1" 'UNANSWERED')"

# --- 5. a forged or broken record changes the wording and never the line -------------------------
R="$COUNCIL_TEST_ROOT/t28g"; stalled_room "$R"
EP="$MB/council-stall-alarms-t28g"
# The episode key exactly as the code writes it, so the forged records below MATCH this episode
# and exercise the number checks rather than falling to a key mismatch.
bash "$CLI" status --alarms-only >/dev/null 2>&1
KEY=$(cut -f1-3 "$EP")
ok "the record carries floor, turn and state"     "$F"$'\t'1$'\topen' "$KEY"
for junk in '' 'garbage' "$KEY"$'\tx\t1\t0' "$KEY"$'\t99999999999999999999\t1\t0' \
            "$KEY"$'\t'"$(( $(date +%s) + 9999 ))"$'\t5\t1'; do
  printf '%s\n' "$junk" >"$EP"
  j=$(bash "$CLI" status --alarms-only 2>/dev/null)
  ok "record [$(printf '%s' "$junk" | tr '\t' ' ' | cut -c1-30)]: line printed" 1 "$(cnt "$j" '🛑 STALL')"
  ok "...as a fresh first firing"                 1 "$(cnt "$j" "🛑 STALL: $F has held")"
done
# A leading zero is valid digits and must be read base 10, not as an octal error that aborts the
# verb: `08` firings last time makes this firing 9.
printf '%s\t%s\t08\t0\n' "$KEY" "$(( $(date +%s) - 120 ))" >"$EP"
j=$(bash "$CLI" status --alarms-only 2>/dev/null)
ok "a leading-zero count is read base 10"         1 "$(cnt "$j" '🛑 STALL UNANSWERED: .* raised 9 times over 2 min')"
# An unwritable record directory is no memory, i.e. the full line every tick.
R="$COUNCIL_TEST_ROOT/t28h"; stalled_room "$R"
for i in 1 2 3; do
  u=$(POLICY_MAILBOX_DIR=/dev/null/nope bash "$CLI" status --alarms-only 2>/dev/null)
  ok "no mailbox: tick $i is the full line"       1 "$(cnt "$u" "$REMEDY")"
done
# A forged say is self-revealing: it is printed as a message the operator can check they sent.
R="$COUNCIL_TEST_ROOT/t28i"; stalled_room "$R"
bash "$CLI" status --alarms-only >/dev/null 2>&1
printf "%s\t$F\t\033[2Jforged\n" "$(date +%s)" >>"$MB/council-said-t28i"
s=$(bash "$CLI" status --alarms-only 2>/dev/null)
ok "a forged say is printed, not hidden"          1 "$(cnt "$s" "sent since: say to $F 0 min ago — \"\[2Jforged\"")"
ok "...with its control characters stripped"      0 "$(printf '%s' "$s" | LC_ALL=C grep -c "$(printf '\033')")"

if [ "$fails" -eq 0 ]; then echo "t28-stall-episode: all passed"; exit 0; fi
echo "t28-stall-episode: $fails FAILED"; exit 1
