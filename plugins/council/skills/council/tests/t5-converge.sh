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
say() { local me="$1" act="$2" refs="$3" text="$4"
  COUNCIL_ME="$me" bash "$CLI" send --act "$act" --refs "$refs" "$text" >/dev/null; }
v() { bash "$CLI" verdict | cut -d' ' -f1; }

say a propose '[]'              "Хранить историю полосой на автора, общий порядок по Лампорту."
say b object  '["a-1"]'         "Тогда читателю нужно сканировать N каталогов на каждый чих."
say c support '["a-1"]'         "Полоса на автора снимает блокировки, это важнее."
echo "после возражения: $(v)"
[ "$(v)" = deliberating ] || { echo "FAIL ждал deliberating"; exit 1; }
say a amend   '["a-1","b-1"]'   "Хранить полосой на автора; читатель щупает от курсора вверх, каталоги не сканируются."
echo "после правки:     $(v)  (возражение закрыто правкой)"
# теперь круг без новых заявлений: N=3 хода болтовни
say b msg '[]' "Согласен с правкой."
say c msg '[]' "Возражений нет."
say a msg '[]' "Тогда фиксируем."
echo "после круга:      $(v)"
[ "$(v)" = ready-to-decide ] || { echo "FAIL ждал ready-to-decide, получил $(v)"; bash "$CLI" claims; exit 1; }
OUT=$(COUNCIL_ME=a bash "$CLI" decide) || { echo "FAIL decide отказался"; exit 1; }
grep -q "статус: \*\*decided\*\*" "$OUT" || { echo "FAIL в ADR нет статуса decided"; exit 1; }
grep -q "каталоги не сканируются" "$OUT" || { echo "FAIL в ADR не текст правки, а исходное предложение"; exit 1; }
grep -q "закрыто \`a-2\`" "$OUT" || { echo "FAIL в ADR не записано, чем закрыли возражение"; exit 1; }
echo "после решения:    $(v)"
[ "$(v)" = decided ] || { echo "FAIL комната не закрылась"; exit 1; }
bash "$CLI" status >/dev/null; [ $? = 0 ] || { echo "FAIL status не вернул 0 на решённой комнате"; exit 1; }
echo "--- ADR ---"; sed -n '1,12p' "$OUT"
echo "t5 PASS"
