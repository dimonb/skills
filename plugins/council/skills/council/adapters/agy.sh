#!/usr/bin/env bash
# adapter: Antigravity CLI (`agy`). Contract: adapter_cmd <room> <protocol> <skill>.
#
# Its permission model differs from the others in a way that shapes the room, and the
# difference is not the one the other adapters prepare you for.
#
# `--sandbox` is NOT a policy, it just refuses commands. For COMMANDS there is a persisted
# allowlist — an interactive session offers "always allow … for commands that start with
# <prefix>", matched on the LITERAL start of the command, which is why this skill has one
# entrypoint instead of eight scripts.
#
# For FILE READS there is no such grant, and that is what wedges a room. Measured: a path
# NAMED in the launch prompt below is read with no prompt at all, but a path the participant
# DISCOVERS for itself — the agenda, the board, any file it decides to open — raises
#
#     File access / Read: <path> / Allow access to this file?  1. Yes  2. No
#
# every time, with no "always" option in the menu. Adding the room to `trustedWorkspaces`
# does NOT suppress it (verified), and the prompt is interactive-mode only: the same read in
# print mode never asks. While it is up the participant holds the floor and, from inside the
# room, is indistinguishable from one that is thinking (measured once at 626s).
#
# So the only unattended lever this CLI documents is the blanket one, and it is used here.
# It applies to sessions THIS SKILL launches and never to an interactive `agy`. It is a
# workaround, not the fix: see dimonb/skills#7, whose remedy is to stop making a participant
# discover paths at all.
adapter_cmd() {
  local room="$1" proto="$2" skill="$3"
  printf 'exec agy --dangerously-skip-permissions --add-dir %q --add-dir %q \\\n' "$room" "$skill"
  printf '  -i %q\n' "Read $proto and follow it literally. Begin."
}
adapter_notes() {
  printf 'agy (%s): launched with --dangerously-skip-permissions, so it does not prompt.\n' "$1"
  printf '          That flag is why the seat runs unattended: without it a path the\n'
  printf '          participant discovers for itself raises a file-access prompt while it\n'
  printf '          holds the floor, and the menu offers no "always" option. It applies to\n'
  printf '          council-launched sessions only, never to an interactive agy.\n'
}
