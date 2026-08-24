#!/usr/bin/env bash
# adapter: Claude Code. Contract: adapter_cmd <room> <protocol> <skill>, adapter_notes <peer>.
adapter_cmd() {
  local room="$1" proto="$2" skill="$3"
  printf 'exec claude --permission-mode auto --add-dir %q --add-dir %q \\\n' "$room" "$skill"
  printf '  --append-system-prompt "$(cat %q)" \\\n' "$proto"
  printf '  %q\n' "You are a participant in a council room. Read the agenda and join the loop."
}
adapter_notes() { :; }
