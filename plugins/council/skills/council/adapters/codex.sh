#!/usr/bin/env bash
# adapter: Codex CLI. Contract: adapter_cmd <room> <protocol> <skill>, adapter_notes <peer>.
#
# Verified on codex-cli 0.149.0: `-s workspace-write` plus `--add-dir` lets it write into a
# room outside its cwd, and its shell tool tolerates a block of at least 200s, so a blocking
# `recv --timeout 180` is safe. `-a` (ask-for-approval) exists only on the interactive
# command, not on `codex exec`.
adapter_cmd() {
  local room="$1" proto="$2" skill="$3"
  printf 'exec codex -s workspace-write -a never --add-dir %q --add-dir %q \\\n' "$room" "$skill"
  printf '  %q\n' "Прочитай $proto и следуй ему буквально. Начинай."
}
adapter_notes() {
  printf 'codex (%s): первый запуск в незнакомом каталоге спросит доверие к нему.\n' "$1"
  printf '            пока вы не ответите, участник держит слово и выглядит зависшим.\n'
}
