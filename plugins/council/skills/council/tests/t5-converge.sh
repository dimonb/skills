#!/usr/bin/env bash
# t5 — a full deliberation that converges: propose → object → amend closes it →
# a whole lap with nothing new → ready-to-decide → the ADR.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
R="${TMPDIR:-/tmp}/council-test/t5"; rm -rf "$R"
mkroom "$R" a b c
export COUNCIL_ROOM="$R" ROOM="$R"
echo "Где хранить историю комнаты?" > "$R/agenda.md"
v() { bash "$CLI" verdict | cut -d' ' -f1; }

# Whoever holds the floor says the next thing: the rotation belongs to the code, and a
# test that re-derives it is testing its own copy of the formula.
prop=$(say_floor propose '[]' "Хранить историю полосой на автора, общий порядок по Лампорту.")
obj=$(say_floor  object  '["'"$prop"'-1"]' "Тогда читателю нужно сканировать N каталогов на каждый чих.")
say_floor support '[]' "Полоса на автора снимает блокировки, это важнее." >/dev/null
echo "после возражения: $(v)"
[ "$(v)" = deliberating ] || { echo "FAIL ждал deliberating"; exit 1; }
say_floor amend '["'"$prop"'-1","'"$obj"'-1"]' "Хранить полосой на автора; читатель щупает от курсора вверх, каталоги не сканируются." >/dev/null
echo "после правки:     $(v)  (возражение закрыто правкой)"
# теперь круг без новых заявлений: N=3 хода болтовни
say_floor msg '[]' "Согласен с правкой." >/dev/null
say_floor msg '[]' "Возражений нет." >/dev/null
say_floor msg '[]' "Тогда фиксируем." >/dev/null
echo "после круга:      $(v)"
[ "$(v)" = ready-to-decide ] || { echo "FAIL ждал ready-to-decide, получил $(v)"; bash "$CLI" claims; exit 1; }
OUT=$(COUNCIL_ME=a bash "$CLI" decide) || { echo "FAIL decide отказался"; exit 1; }
grep -q "статус: \*\*decided\*\*" "$OUT" || { echo "FAIL в ADR нет статуса decided"; exit 1; }
grep -q "каталоги не сканируются" "$OUT" || { echo "FAIL в ADR не текст правки, а исходное предложение"; exit 1; }
grep -q "закрыто \`" "$OUT" || { echo "FAIL в ADR не записано, чем закрыли возражение"; exit 1; }
echo "после решения:    $(v)"
[ "$(v)" = decided ] || { echo "FAIL комната не закрылась"; exit 1; }
bash "$CLI" status >/dev/null; [ $? = 0 ] || { echo "FAIL status не вернул 0 на решённой комнате"; exit 1; }
echo "--- ADR ---"; sed -n '1,12p' "$OUT"
echo "t5 PASS"
