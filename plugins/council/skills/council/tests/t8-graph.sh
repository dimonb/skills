#!/usr/bin/env bash
# t8 — two closure rules that a live room needed and the graph did not have.
#   * an amend belongs to ONE proposal (its first proposal-typed ref), so a single
#     amendment cannot rewrite two rival positions into the same words;
#   * `concede` pointing at the sender's OWN proposal kills it — the natural way to yield
#     in favour of somebody else's position.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
R="${TMPDIR:-/tmp}/council-test/t8"; rm -rf "$R"
mkroom "$R" a b
export COUNCIL_ROOM="$R" ROOM="$R"
fail=0

# two rival proposals, as a barrier round would produce
raw_msg a 1 1 0 propose '[]' "позиция a"
raw_msg b 1 2 1 propose '[]' "позиция b"
# one amendment naming BOTH, plus an objection id
raw_msg b 2 3 2 object  '["a-1"]' "возражаю против a"
raw_msg a 2 4 3 amend   '["a-1","b-1","b-2"]' "правка позиции a"

g=$(COUNCIL_ME=a bash "$CLI" claims --raw)
ta=$(printf '%s' "$g" | jq -r '.proposals[] | select(.id=="a-1") | .current_text')
tb=$(printf '%s' "$g" | jq -r '.proposals[] | select(.id=="b-1") | .current_text')
[ "$ta" = "правка позиции a" ] || { echo "FAIL правка не применилась к своему предложению: '$ta'"; fail=1; }
[ "$tb" = "позиция b" ] || { echo "FAIL правка переписала чужое предложение: '$tb'"; fail=1; }
closed=$(printf '%s' "$g" | jq -r '[.proposals[].objections[] | select(.closed_by != null)] | length')
[ "$closed" = 1 ] || { echo "FAIL правка не закрыла возражение, на которое ссылалась"; fail=1; }
echo "правка правит одно предложение и закрывает названное возражение"

# b yields its own position
raw_msg b 3 5 4 concede '["b-1"]' "уступаю свою позицию"
g=$(COUNCIL_ME=a bash "$CLI" claims --raw)
dead=$(printf '%s' "$g" | jq -r '.proposals[] | select(.id=="b-1") | .dead')
live=$(printf '%s' "$g" | jq -r '.live | length')
[ "$dead" = true ] || { echo "FAIL уступка своего предложения его не сняла"; fail=1; }
[ "$live" = 1 ] || { echo "FAIL на столе осталось $live предложений, ждали 1"; fail=1; }
echo "уступка своего предложения снимает его: на столе остаётся одно"
[ "$fail" = 0 ] && echo "t8 PASS" || echo "t8 FAIL"
exit $fail
