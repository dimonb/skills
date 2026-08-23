#!/usr/bin/env bash
# adapter: Antigravity CLI (`agy`). Contract: adapter_cmd <room> <protocol> <skill>.
#
# Its permission model differs from the others in a way that shapes the room: `--sandbox`
# is NOT a policy, it just refuses commands, and there is no per-run allowlist flag. In an
# interactive session it offers "always allow … for commands that start with <prefix>",
# matched on the LITERAL start of the command — which is exactly why this skill has one
# entrypoint instead of eight scripts. Grant it once for `bash <skill>/council.sh` and the
# room runs unattended; forget to, and the participant sits on a permission prompt holding
# the floor, which from outside is indistinguishable from a wedged session (measured: 626s).
adapter_cmd() {
  local room="$1" proto="$2" skill="$3"
  printf 'exec agy --add-dir %q --add-dir %q \\\n' "$room" "$skill"
  printf '  -i %q\n' "Прочитай $proto и следуй ему буквально. Начинай."
}
adapter_notes() {
  printf 'agy (%s): первый запуск спросит доверие к папке и разрешение на команду.\n' "$1"
  printf '          выберите «always allow … commands that start with» (цифра в меню),\n'
  printf '          иначе участник будет держать слово, ожидая вашего клика.\n'
}
