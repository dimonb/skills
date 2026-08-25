#!/usr/bin/env bash
# adapter: Antigravity CLI (`agy`). Contract: adapter_cmd <room> <protocol> <skill>.
#
# Its permission model differs from the others in a way that shapes the room, and the
# difference is not the one the other adapters prepare you for.
#
# `--sandbox` is NOT a policy, it just refuses commands. For COMMANDS there is a persisted
# allowlist — an interactive session offers "always allow … for commands that start with
# <prefix>", matched on the LITERAL start of the command, which is why this skill has one
# entrypoint instead of eight scripts. (Even that is finickier than it reads: `agy` puts the
# environment in front of the command it runs, so a prefix written as `bash <skill>/…` never
# matches what it actually executes.)
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
# It applies to sessions THIS SKILL launches and never to an interactive `agy`.
#
# The flag is still a workaround, but it now covers less. The room's own files no longer have
# to be discovered at all: the protocol is handed over as ARGV below rather than as a path to
# read, and the agenda and the decision record are reached through `council.sh agenda` and
# `council.sh decision`. What is left under the flag is everything OUTSIDE the room — a
# `review` participant reading the codebase it was asked to review derives those paths itself,
# and there is no grant to persist for them. Dropping the flag needs that solved first.
adapter_cmd() {
  local room="$1" proto="$2" skill="$3"
  printf 'exec agy --dangerously-skip-permissions --add-dir %q --add-dir %q \\\n' "$room" "$skill"
  # Content, not a path. Naming the path is measured to be enough today, but that is
  # undocumented behaviour of one CLI; handing the text over does not depend on it, and it is
  # what the `claude` adapter already does with its system prompt.
  printf '  -i "Follow this protocol literally. Begin.\n\n$(cat %q)"\n' "$proto"
}
adapter_notes() {
  printf 'agy (%s): launched with --dangerously-skip-permissions, so it does not prompt.\n' "$1"
  printf '          That flag is why the seat runs unattended: without it a path the\n'
  printf '          participant discovers for itself raises a file-access prompt while it\n'
  printf '          holds the floor, and the menu offers no "always" option. It applies to\n'
  printf '          council-launched sessions only, never to an interactive agy.\n'
  printf '          The room itself no longer needs it — the protocol arrives as an argument\n'
  printf '          and the agenda and record are verbs — but files a participant opens\n'
  printf '          OUTSIDE the room still do.\n'
  printf '          The first launch in a directory agy has not seen also asks you to trust\n'
  printf '          it; the flag does not answer that one for you.\n'
}
