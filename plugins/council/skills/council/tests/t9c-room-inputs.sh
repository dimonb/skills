#!/usr/bin/env bash
# t9c — the room's NUMERIC files are written by peers too, so none of them is believed either.
#
# t9b covers a lane MESSAGE. This covers everything else a participant can write that a
# reader then hands to `$(( ))`, which EVALUATES rather than parses. Four inputs, four
# different victims:
#
#   state/<peer>.lamport   -> c_max_lamport's `mine` -> `lam=$(( ... + 1 ))`   on the next send
#   state/<peer>.seq       -> `seq=$(( $(c_seq) + 1 ))`                        on the next send
#   cursor/<me>/<peer>     -> `n=$(( cur + 1 ))`                               on the next recv
#   roster round_deadline_ms -> `$(( deadline * 2 ))`                          on any status
#
# The last is the worst of them for reach rather than for mechanism: `rooms` runs `verdict`
# in every room, so a supervisor merely listing rooms triggers it — and a supervisor is
# typically the least sandboxed session in a fleet.
#
# The payload names a scalar in scope at the arithmetic site and carries no whitespace, so
# `read` cannot split it apart. An unbound name would be stopped by `set -u`, which is why a
# naive `a[$(...)]` looks inert and this does not.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
R="$COUNCIL_TEST_ROOT/t9c-room-inputs"; rm -rf "$R"
export COUNCIL_ROOM="$R" ROOM="$R"
fail=0

fresh() { rm -rf "$R"; mkroom "$R" a b; echo "Does the room trust its own files?" > "$R/agenda.md"; }
payload() { printf 'OPTIND[$({touch,%s})]' "$1"; }

# <label> <marker> — the marker must NOT exist by now.
assert_inert() {
  if [ -e "$2" ]; then echo "FAIL $1 ran a command in the reader's shell"; fail=1
  else echo "ok   $1 ran nothing"; fi
}

# --- 1. a crafted state/<peer>.lamport must not run anything --------------------
fresh
M="$R/PWNED-lamport"; rm -f "$M"
payload "$M" > "$R/state/b.lamport"
COUNCIL_ME=b bash "$CLI" send --act msg "hello" >/dev/null 2>&1
assert_inert "a crafted state/<peer>.lamport" "$M"

# --- 2. a crafted state/<peer>.seq must not run anything ------------------------
fresh
M="$R/PWNED-seq"; rm -f "$M"
payload "$M" > "$R/state/b.seq"
COUNCIL_ME=b bash "$CLI" send --act msg "hello" >/dev/null 2>&1
assert_inert "a crafted state/<peer>.seq" "$M"

# --- 3. a crafted cursor/<me>/<peer> must not run anything ----------------------
# The hottest path in a room: every recv reads every cursor.
fresh
M="$R/PWNED-cursor"; rm -f "$M"
payload "$M" > "$R/cursor/b/a"
COUNCIL_ME=b bash "$CLI" recv --timeout 1 >/dev/null 2>&1
assert_inert "a crafted cursor/<me>/<peer>" "$M"

# --- 4. a crafted roster round_deadline_ms must not run anything ----------------
# Reached through c_barrier, so the room must be a roundtable one and a position must exist
# — otherwise `first` is 0 and c_barrier returns before the arithmetic.
fresh
M="$R/PWNED-deadline"; rm -f "$M"
jq --arg d "$(payload "$M")" '.mode = "roundtable" | .round_deadline_ms = $d' \
  "$R/roster.json" > "$R/roster.next" && mv "$R/roster.next" "$R/roster.json"
COUNCIL_ME=a bash "$CLI" send --act propose "a position" >/dev/null 2>&1
bash "$CLI" status  >/dev/null 2>&1
bash "$CLI" verdict >/dev/null 2>&1
assert_inert "a crafted roster round_deadline_ms" "$M"

# --- 5. a crafted turns_budget is treated as absent, not as a budget ------------
# Not an execution path — `[ -ge ]` errors rather than evaluating — but the same class, and
# `// 30` does not defend it: a string is truthy in jq, so the alternative never fires.
fresh
jq '.turns_budget = "999999"' "$R/roster.json" > "$R/roster.next" && mv "$R/roster.next" "$R/roster.json"
b=$(bash "$CLI" verdict --json 2>/dev/null | jq -r .budget)
if [ "$b" = 30 ]; then echo "ok   a string turns_budget fell back to the default (budget=$b)"
else echo "FAIL a string turns_budget was believed: budget=$b"; fail=1; fi

# --- 5b. a NON-INTEGER roster number is treated as absent too --------------------
# jq's `type == "number"` is not enough on its own: 1.5 and 1e400 are both numbers and both
# are fatal to `$(( ))`. A c_barrier that dies mid-function prints NEITHER open nor closed,
# and every caller tests `= open`, so the opening barrier would silently cease to exist.
for bad in '0.5' '1e400'; do
  fresh
  jq --argjson d "$bad" '.mode = "roundtable" | .round_deadline_ms = $d' \
    "$R/roster.json" > "$R/roster.next" && mv "$R/roster.next" "$R/roster.json"
  COUNCIL_ME=a bash "$CLI" send --act propose "a position" >/dev/null 2>&1
  err=$(bash "$CLI" status 2>&1 >/dev/null | grep -c 'arithmetic\|integer expected' || true)
  b=$(bash "$CLI" floor 2>/dev/null)
  if [ "$err" = 0 ] && [ -n "$b" ]; then
    echo "ok   a non-integer round_deadline_ms ($bad) fell back to the default"
  else
    echo "FAIL a non-integer round_deadline_ms ($bad) reached bash: errors=$err floor='$b'"; fail=1
  fi
done

# --- 5b2. the other two c_int_field call sites ----------------------------------
# The helper being right is not the same as every caller routing through it. Reverting either
# of these two call sites on its own left the whole suite green, which is the same
# zero-coverage shape that let the first version of the quorum gate ship unasserted.
fresh
jq '.mode = "roundtable" | .round_quorum = 1.5' \
  "$R/roster.json" > "$R/roster.next" && mv "$R/roster.next" "$R/roster.json"
COUNCIL_ME=a bash "$CLI" send --act propose "a position" >/dev/null 2>&1
err=$(bash "$CLI" floor 2>&1 >/dev/null | grep -c 'integer expected' || true)
if [ "$err" = 0 ]; then echo "ok   a non-integer round_quorum produced no bash diagnostic"
else echo "FAIL a non-integer round_quorum reached the numeric test: $err diagnostic(s)"; fail=1; fi

# `1e400` renders as 1E+400, which is not digits -- and it would otherwise land in the JSON a
# supervisor and the decision record read, as the room's budget.
for bad in '2.5' '1e400'; do
  fresh
  jq --argjson b "$bad" '.turns_budget = $b' \
    "$R/roster.json" > "$R/roster.next" && mv "$R/roster.next" "$R/roster.json"
  got=$(bash "$CLI" verdict --json 2>/dev/null | jq -r .budget)
  if [ "$got" = 30 ]; then echo "ok   a non-integer turns_budget ($bad) fell back to the default"
  else echo "FAIL a non-integer turns_budget ($bad) was believed: budget=$got"; fail=1; fi
done

# --- 5c. a wrong-typed round_quorum leaves no diagnostic on the floor path -------
# The quorum reaches `[ "$quorum" -lt 2 ]`. `// empty` never fired for a string, because a
# string is truthy in jq, so every floor/status/send/recv in a roundtable room used to carry
# `[: abc: integer expected` on stderr and the deadline+quorum close stayed disabled.
fresh
jq '.mode = "roundtable" | .round_quorum = "abc"' \
  "$R/roster.json" > "$R/roster.next" && mv "$R/roster.next" "$R/roster.json"
COUNCIL_ME=a bash "$CLI" send --act propose "a position" >/dev/null 2>&1
err=$(bash "$CLI" floor 2>&1 >/dev/null | grep -c 'integer expected' || true)
if [ "$err" = 0 ]; then echo "ok   a wrong-typed round_quorum produced no bash diagnostic"
else echo "FAIL a wrong-typed round_quorum reached the numeric test: $err diagnostic(s)"; fail=1; fi

# --- 5d. a leading zero is not octal, and 08/09 are not fatal -------------------
# Digits alone are not an integer to bash, and the two failures differ. `$(( 010 + 1 ))` is 9
# rather than 11, because a leading zero means octal, so the cursor is read too LOW and the
# reader is handed messages it has already consumed -- octal can only ever under-read the
# same digits, so this is re-delivery and never loss. `$(( 08 + 1 ))` is an error instead,
# because 8 is not an octal digit, and it unwinds the subshell c_new_files runs in: the file
# list comes back empty and the lane goes deaf for good. That second one is #38's wedge,
# arriving through the gate that was added to close it.
# Written straight into the lane rather than through `send`: twelve messages do not fit in
# one participant's turns, and turn-taking is not what is under test here.
lane12() { local i; for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
             raw_msg a "$i" "$i" null msg '[]' "msg-$i"; done; }

# `010` is decimal ten. Read as octal it is eight, so the reader would re-deliver msg-9 and
# msg-10 -- messages it has already consumed. Assert on msg-9 specifically: it is the one the
# two readings disagree about, and `grep '"text":"msg-9"'` cannot match msg-10 or later.
fresh; lane12
printf '010' > "$R/cursor/b/a"
out=$(COUNCIL_ME=b bash "$CLI" recv --timeout 1 2>/dev/null)
if printf '%s' "$out" | grep -q '"text":"msg-9"'; then
  echo "FAIL a leading-zero cursor was read as octal (msg-9 re-delivered past cursor 10)"; fail=1
elif printf '%s' "$out" | grep -q '"text":"msg-11"'; then
  echo "ok   a leading-zero cursor was read as decimal, not octal"
else
  echo "FAIL a leading-zero cursor delivered neither reading: $(printf '%s' "$out" | grep -c .) line(s)"; fail=1
fi

# `08` and `09` are not octal digits, so `$(( 08 + 1 ))` is a FATAL bash error rather than a
# wrong answer. It kills the subshell c_new_files runs in, so the file list comes back empty
# and the lane goes deaf for good -- with no error a supervisor would see.
fresh; lane12
printf '08' > "$R/cursor/b/a"
out=$(COUNCIL_ME=b bash "$CLI" recv --timeout 1 2>/dev/null)
if printf '%s' "$out" | grep -q '"text":"msg-9"'; then
  echo "ok   an 08 cursor was not fatal and delivered from 9 on"
else
  echo "FAIL an 08 cursor deafened the lane: $(printf '%s' "$out" | grep -c .) line(s)"; fail=1
fi

# --- 6. board/status still reads as a WORD --------------------------------------
# The one room file c_slurp's callers read that legitimately holds a word rather than a
# number. A blanket numeric gate would map decided AND unresolved onto 0, and the `= 0`
# fallback above it would then report an unresolved room as decided — the room ran out of
# turns and the record says the opposite.
fresh
say_floor propose '[]' "An ordinary proposal." >/dev/null
who=$(bash "$CLI" floor | sed -n 's/.*floor=\([^ ]*\).*/\1/p')
COUNCIL_ME="$who" bash "$CLI" decide --force >/dev/null 2>&1
for want in unresolved decided; do
  printf '%s' "$want" > "$R/board/status"
  v=$(bash "$CLI" verdict --json 2>/dev/null | jq -r .verdict)
  if [ "$v" = "$want" ]; then echo "ok   board/status '$want' still reads back as '$want'"
  else echo "FAIL board/status was coerced: verdict=$v (want $want)"; fail=1; fi
done

# --- 7. the room still works normally afterwards --------------------------------
fresh
p=$(say_floor propose '[]' "An ordinary proposal.")
[ -n "$p" ] && echo "ok   an ordinary room still sends and reads" \
            || { echo "FAIL a normal send broke"; fail=1; }

[ "$fail" = 0 ] && echo "t9c PASS" || echo "t9c FAIL"
exit $fail
