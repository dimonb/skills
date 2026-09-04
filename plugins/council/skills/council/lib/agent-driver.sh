# agent-driver.sh — the ONE agent-console driver, shared by shipyard and council.
#
# SOURCE OF TRUTH: shared/driver/agent-driver.sh. Do NOT edit the vendored copies under
# plugins/*/skills/*/ — edit here, then run `scripts/sync-driver.sh`. The repo gate
# (scripts/check.sh, check 11) fails if any copy drifts from this file.
#
# Why a vendored copy and not a symlink or an import: a Codex plugin is installed as a
# self-contained directory and cannot depend on another plugin, so each plugin must carry its
# own copy of shared code. The gate — not the filesystem — is what makes the copies one source
# of truth. This is the same "one source, enforced" idea the dogfood symlinks give, adapted to
# a boundary a symlink cannot cross.
#
# STATUS: spike stub. Only the interface (the `drv_*` contract) is fixed here; the agterm|tmux
# bodies and the per-kind adapters land in a later change.

# Bumping this is the cheapest way to prove sync + the drift gate end to end.
_DRV_VERSION=0

# Backend selection: agterm when agtermctl answers, else tmux. Returns the name on stdout.
drv_backend() { :; }               # -> agterm|tmux

# Launch an agent console in its own session and return an opaque handle.
drv_launch() { :; }                # <kind> <cwd> <goal-file> -> session

# Send input to a session, and commit it (newline / Enter).
drv_tell()   { :; }                # <session> <text>
drv_submit() { :; }                # <session>

# Read a session's current transcript.
drv_read()   { :; }                # <session> -> text

# Read one normalized signal from a session (the AgentSignal vocabulary).
drv_signal() { :; }                # <session> -> kind|class|blocking|resume_at|payload

# End a session (closing its pane HUP-reaps the subtree).
drv_kill()   { :; }                # <session>
drv_focus()  { :; }                # <session>
