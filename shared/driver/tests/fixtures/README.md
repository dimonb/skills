# Driver test fixtures

## `agterm-foreground.json`

A real `agtermctl tree --json`, captured, then reduced. It is the evidence behind
`drv_occupant`'s agterm arm, so it must not be rebuilt from the expression it guards.

How it was taken: three sessions were created in the workspace holding a live agent child, with
`agtermctl session new --no-select`:

| session | created with | what it shows |
|---|---|---|
| `probe-exited` | `--wait --command "sh -c 'exit 0'"` | a command that exited, the pane held open at "Press any key to close" |
| `probe-shell` | no `--command` | a login shell sitting at its prompt — the shape of a terminal whose agent has gone |
| `probe-sleep` | `--command "zsh -lc 'exec sleep 600'"` | a live non-shell process that was `exec`ed the way a launcher `exec`s its agent |

After four seconds the tree was dumped and the probes were closed. `agent-live` is a live agent
child in that same workspace, captured WHILE it was running a shell tool (the capture command
itself), so a busy agent reads the same as an idle one.

Reductions, and only these: the other workspaces and sessions were dropped, the workspace was
renamed `proj`, the live agent's session was renamed `agent-live`, every `id` was replaced by its
session's name, every key but `id`, `name` and `foreground` was removed (keys are dropped, never
added), and the live agent's `foreground` argv was cut to its first word — the rest carries its
launch arguments, which include local paths.

**The two empty panes carry no `foreground` key at all, and that is agterm's output, not a
reduction.** agterm omits the field rather than sending `null`. The first version of this fixture
was built with a `{name, foreground}` projection, which prints `null` for a missing key, and so
recorded a `null` agterm never sent; a driver written against it passed its tests and gave no
verdict on the real app. It was caught by running the driver against a live session, which is
the check to repeat after any recapture.

Recapture it the same way if agterm's tree changes shape; do not edit it by hand.

## `tmux-occupant.tsv`

`tmux display-message -p '#{pane_dead} #{pane_current_command}'` for four windows on a PRIVATE
server (`tmux -L <name>`, killed afterwards), tmux 3.7b, read four seconds after creation:

| window | created with | what it shows |
|---|---|---|
| `probe-shell` | no command | a login shell at its prompt: `pane_current_command` names the shell |
| `probe-sleep` | `zsh -lc 'exec sleep 600'` | an `exec`ed live process — the launcher shape |
| `probe-dead` | `sh -c 'sleep 1; exit 0'`, `remain-on-exit on` | a pane kept after its command exited: `pane_dead` is 1 |
| `probe-wrapper` | `bash -c 'sleep 600; true'` | a live process run by a wrapper WITHOUT `exec`: tmux names the wrapper shell, which is the false `none` `drv_occupant` documents |

Unreduced: each line is the window name, a tab, and tmux's output verbatim.
