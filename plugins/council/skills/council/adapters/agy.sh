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
  printf '  -i %q\n' "Read $proto and follow it literally. Begin."
}
adapter_notes() {
  printf 'agy (%s): the first launch asks to trust the directory and to allow the command.\n' "$1"
  printf '          pick "always allow … commands that start with" (a number in the menu),\n'
  printf '          or the participant will hold the floor waiting for your click.\n'
}
