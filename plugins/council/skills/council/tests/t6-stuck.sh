#!/usr/bin/env bash
# t6 — the two ways a room ends without agreement, both of which must be VISIBLE:
#   STUCK       a whole lap went by, the objection is still open, nobody said anything new
#               (this is the polite-echo failure that was invisible before);
#   unresolved  the turn budget ran out — an honest record, not a hidden failure.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
R="${TMPDIR:-/tmp}/council-test/t6"; rm -rf "$R"
mkroom "$R" a b c
export COUNCIL_ROOM="$R" ROOM="$R"
jq '.turns_budget = 9' "$R/roster.json" > "$R/roster.tmp" && mv "$R/roster.tmp" "$R/roster.json"
echo "Брать ли на себя ещё один режим расписания?" > "$R/agenda.md"
v() { bash "$CLI" verdict | cut -d' ' -f1; }
fail=0

prop=$(say_floor propose '[]' "Добавить режим swarm сразу вместе с token.")
say_floor object '["'"$prop"'-1"]' "Swarm требует правила стабильности, иначе доставка врёт про порядок. Это отдельная работа." >/dev/null
echo "возражение поставлено: $(v)"
# круг вежливого эха: три хода, ни одного нового заявления
say_floor msg '[]' "Понимаю обе стороны." >/dev/null
say_floor msg '[]' "Да, вопрос непростой." >/dev/null
say_floor msg '[]' "Согласен, что непростой." >/dev/null
echo "после круга эха:    $(v)"
[ "$(v)" = stuck ] || { echo "FAIL ждал stuck, получил $(v)"; fail=1; }
bash "$CLI" status > "$R/log/status.stuck" 2>&1
grep -q "STUCK" "$R/log/status.stuck" || { echo "FAIL status не поднял тревогу STUCK; вывод:"; cat "$R/log/status.stuck"; fail=1; }
COUNCIL_ME=a bash "$CLI" decide >/dev/null 2>&1 && { echo "FAIL decide согласился решать залипшую комнату"; fail=1; }
echo "decide на залипшей комнате: отказался (правильно)"
# добиваем бюджет
for _t in "Ну да." "Ага." "Мгм." "Всё ещё думаю."; do say_floor msg '[]' "$_t" >/dev/null; done
echo "после бюджета:      $(v)"
[ "$(v)" = unresolved ] || { echo "FAIL ждал unresolved, получил $(v)"; fail=1; }
OUT=$(COUNCIL_ME=a bash "$CLI" decide --force) || { echo "FAIL --force не записал unresolved"; fail=1; }
grep -q "статус: \*\*unresolved\*\*" "$OUT" || { echo "FAIL в ADR не unresolved"; fail=1; }
grep -q "Осталось открытым" "$OUT" || { echo "FAIL ADR не перечислил незакрытое"; fail=1; }
grep -q "правила стабильности" "$OUT" || { echo "FAIL ADR потерял текст открытого возражения"; fail=1; }
echo "--- незакрытое из ADR ---"; sed -n '/## Осталось открытым/,/## Стенограмма/p' "$OUT" | head -5
[ "$fail" = 0 ] && echo "t6 PASS" || echo "t6 FAIL"
exit $fail
