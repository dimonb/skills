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
