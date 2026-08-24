#!/usr/bin/env bash
# t4 — two messages claiming the same turn, and how the room settles it.
#
# `send` now checks the floor at stamp time, so it will refuse rather than produce this on
# purpose; the case survives through a `skip` racing the holder it is skipping, and through
# any future writer that gets it wrong. The settlement itself is what matters here, so the
# two messages are written straight into their lanes — deterministically, no racing.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
R="${TMPDIR:-/tmp}/council-test/t4"; rm -rf "$R"
mkroom "$R" a b c
export COUNCIL_ROOM="$R" ROOM="$R"
fail=0

COUNCIL_ME=a bash "$CLI" send --act propose "ход 0 от a" >/dev/null
raw_msg b 1 2 1 object '["a-1"]' "ход 1 от b"
raw_msg c 1 2 1 object '["a-1"]' "ход 1 от c"

claims=$(bash "$CLI" order | jq -s '[.[] | select(.turn == 1)] | length')
[ "$claims" = 2 ] || { echo "FAIL подготовка: на ход 1 претендует $claims сообщений, нужно 2"; fail=1; }

# every participant must settle it the same way, and only one way
for p in a b c; do
  COUNCIL_ME=$p bash -c '. '"$SKILL"'/lib/lib.sh; c_canon' \
    | jq -r 'select(.turn == 1) | "\(.id) valid=\(.valid)"' | sort > "$R/log/verdict.$p"
done
cmp -s "$R/log/verdict.a" "$R/log/verdict.b" && cmp -s "$R/log/verdict.a" "$R/log/verdict.c" \
  || { echo "FAIL участники разошлись в том, кто выиграл ход 1"; fail=1; }
winners=$(grep -c "valid=true" "$R/log/verdict.a" || true)
losers=$(grep -c "valid=false" "$R/log/verdict.a" || true)
[ "$winners" = 1 ] && [ "$losers" = 1 ] || { echo "FAIL победителей=$winners проигравших=$losers, нужно 1/1"; fail=1; }
lost=$(grep "valid=false" "$R/log/verdict.a" | cut -d' ' -f1)
bash "$CLI" order | jq -e --arg i "$lost" 'select(.id==$i) | .text' >/dev/null \
  || { echo "FAIL проигравшее сообщение исчезло из лога"; fail=1; }
turns=$(COUNCIL_ME=a bash -c '. '"$SKILL"'/lib/lib.sh; c_turns')
[ "$turns" = 2 ] || { echo "FAIL после разрешения ходов $turns, ждали 2"; fail=1; }
echo "ход 1 заявлен дважды; все трое рассудили одинаково; проигравший ($lost) остался в логе"

# and the check that makes this rare: a participant that lost the floor while composing
# is refused outright instead of stamping the next free turn
holder=$(bash "$CLI" floor | sed -n 's/.*floor=\([^ ]*\).*/\1/p')
notme=$(c_peers_list | grep -v "^$holder$" | head -1)
out=$(COUNCIL_ME="$notme" bash "$CLI" send --act msg "говорю не в свой ход" 2>&1); rc=$?
[ "$rc" = 6 ] || { echo "FAIL реплика вне очереди принята (код $rc): $out"; fail=1; }
echo "реплика вне очереди ($notme при слове у $holder) отклонена кодом 6"
[ "$fail" = 0 ] && echo "t4 PASS" || echo "t4 FAIL"
exit $fail
