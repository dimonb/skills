#!/usr/bin/env bash
# t7 — the opening barrier of `mode: roundtable`.
#   * an opening position is invisible to everyone else until the round is complete;
#   * when the last one lands, all of them are released at once, in one order;
#   * the round counts as one lap, and the room is turn-taking from there on;
#   * a participant that never posts does not hold the room: the deadline plus a quorum
#     closes the round without it.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
fail=0

# ---------------------------------------------------------------- 1. the barrier holds
R="${TMPDIR:-/tmp}/council-test/t7"; rm -rf "$R"
mkroom "$R" a b c
export COUNCIL_ROOM="$R" ROOM="$R"
jq '.mode="roundtable" | .round_deadline_ms=600000' "$R/roster.json" > "$R/r.tmp" && mv "$R/r.tmp" "$R/roster.json"

seen() { COUNCIL_ROOM="$R" COUNCIL_ME="$1" bash "$CLI" recv --peek | jq -r '.id' | paste -sd, -; }

# a participant that owes a position must be released at once: in a barrier round there is
# no floor holder to wait for, and --until-floor would otherwise wait forever (a live Codex
# participant did exactly that the first time a roundtable room ran).
COUNCIL_ME=a timeout 12 bash "$CLI" recv --until-floor --timeout 8 >/dev/null
[ $? = 0 ] || { echo "FAIL участник, который ещё не высказался, не отпущен из --until-floor"; fail=1; }

say a propose '[]' "позиция a: барьер только на первый круг"

# ...and one that HAS posted keeps waiting for the round, not for a turn
COUNCIL_ME=a timeout 12 bash "$CLI" recv --until-floor --timeout 6 >/dev/null
[ $? = 4 ] || { echo "FAIL высказавшийся участник не ждёт сбора круга"; fail=1; }
echo "recv в барьере: должника отпускает сразу, высказавшегося держит"
[ -z "$(seen b)" ] || { echo "FAIL b увидел позицию a до сбора круга: $(seen b)"; fail=1; }
say b propose '[]' "позиция b: барьер вообще не нужен"
[ -z "$(seen c)" ] || { echo "FAIL c увидел чужие позиции до сбора круга: $(seen c)"; fail=1; }
echo "барьер держит: b и c не видят ничего, хотя две позиции уже записаны"

# a second position from the same participant is refused, not silently queued
COUNCIL_ROOM="$R" COUNCIL_ME=a bash "$CLI" send --act msg "и ещё вот что" >/dev/null 2>&1
[ $? = 5 ] || { echo "FAIL вторая реплика в открытом круге не отклонена"; fail=1; }

# ------------------------------------------------------- 2. the last one releases all
say c propose '[]' "позиция c: барьер нужен и дальше первого круга"
got=$(seen b)
[ "$got" = "a-1,c-1" ] || { echo "FAIL b получил '$got', ждали обе чужие позиции сразу"; fail=1; }
echo "круг собран: b получил обе чужие позиции одним пакетом ($got)"

# ---------------------------------------------- 3. one lap consumed, token from here on
turns=$(COUNCIL_ME=a bash -c '. '"$SKILL"'/lib/lib.sh; c_turns')
[ "$turns" = 3 ] || { echo "FAIL после круга ходов $turns, ждали 3 (один круг)"; fail=1; }
floor=$(bash "$CLI" floor | sed -n 's/.*floor=\([a-z]*\).*/\1/p')
[ "$floor" = b ] || { echo "FAIL слово у '$floor', по ротации ждали b"; fail=1; }
say b object '["a-1"]' "возражаю против позиции a"
turns=$(COUNCIL_ME=a bash -c '. '"$SKILL"'/lib/lib.sh; c_turns')
[ "$turns" = 4 ] || { echo "FAIL обычный ход после круга не посчитан: $turns"; fail=1; }
conf=$(bash "$CLI" floor | sed -n 's/.*conflicts=\([0-9]*\).*/\1/p')
[ "$conf" = 0 ] || { echo "FAIL позиции круга подрались за ход: конфликтов $conf"; fail=1; }
echo "круг = один лап, дальше token: ходов $turns, конфликтов $conf"

# ------------------------------------------- 4. a silent participant does not hold it
R2="${TMPDIR:-/tmp}/council-test/t7b"; rm -rf "$R2"
mkroom "$R2" a b c
ROOM="$R2"; export COUNCIL_ROOM="$R2"
jq '.mode="roundtable" | .round_deadline_ms=1000 | .round_quorum=2' "$R2/roster.json" > "$R2/r.tmp" && mv "$R2/r.tmp" "$R2/roster.json"
COUNCIL_ME=a bash "$CLI" send --act propose "позиция a" >/dev/null
COUNCIL_ME=b bash "$CLI" send --act propose "позиция b" >/dev/null
st=$(COUNCIL_ME=a bash -c '. '"$SKILL"'/lib/lib.sh; c_barrier')
[ "$st" = open ] || { echo "FAIL круг закрылся до дедлайна при 2 из 3"; fail=1; }
sleep 1.5
st=$(COUNCIL_ME=a bash -c '. '"$SKILL"'/lib/lib.sh; c_barrier')
[ "$st" = closed ] || { echo "FAIL круг не закрылся по дедлайну с кворумом: $st"; fail=1; }
got=$(COUNCIL_ROOM="$R2" COUNCIL_ME=c bash "$CLI" recv --peek | jq -r '.id' | paste -sd, -)
[ "$got" = "a-1,b-1" ] || { echo "FAIL после дедлайна не отдали собранное: '$got'"; fail=1; }
echo "молчащий участник не держит комнату: круг закрыт по дедлайну, позиции отданы"

# ...and the latecomer must not reopen or rewrite the round it missed. (Raised by a live
# Codex participant while writing its own position in a roundtable room.)
# c missed the round entirely; out of turn it is refused like anyone else, so let the
# rotation come round to it and check what its first message then IS.
rc0=$(COUNCIL_ME=c bash "$CLI" send --act msg "я опоздал" >/dev/null 2>&1; echo $?)
[ "$rc0" = 6 ] || { echo "FAIL опоздавший заговорил вне очереди (код $rc0)"; fail=1; }
while [ "$(bash "$CLI" floor | sed -n 's/.*floor=\([^ ]*\).*/\1/p')" != c ]; do
  say_floor msg '[]' "ход" >/dev/null || break
done
COUNCIL_ME=c bash "$CLI" send --act msg "я опоздал, но дождался очереди" >/dev/null
late=$(bash "$CLI" order | jq -r 'select(.from=="c") | .round')
[ "$late" = null ] || { echo "FAIL опоздавшая реплика записана как позиция круга (round=$late)"; fail=1; }
st=$(COUNCIL_ME=a bash -c '. '"$SKILL"'/lib/lib.sh; c_barrier')
[ "$st" = closed ] || { echo "FAIL опоздавший переоткрыл круг: $st"; fail=1; }
turns=$(COUNCIL_ME=a bash -c '. '"$SKILL"'/lib/lib.sh; c_turns')
[ "$turns" -ge 3 ] || { echo "FAIL счёт ходов после закрытого круга сбит: $turns"; fail=1; }
echo "опоздавший не переоткрывает круг: его реплика — обычный ход, круг остался закрытым"

[ "$fail" = 0 ] && echo "t7 PASS" || echo "t7 FAIL"
exit $fail
