# canary.sh — seeing an OWNER's death as EOF on a FIFO canary, shared by shipyard and council.
#
# SOURCE OF TRUTH: shared/canary/canary.sh. Do NOT edit the vendored copies under
# plugins/*/skills/*/ — edit here, then run `scripts/sync-driver.sh`. The repo gate
# (scripts/check.sh, check 11) fails if any copy drifts from this file.
#
# Source only, never execute. Sourced into a shell that may run `set -u`, so every optional
# variable is read as `${VAR:-}`. Needs bash >= 4.4: `{var}` redirections, and `$!` naming a
# process substitution's pid.
#
# WHAT THIS IS FOR. Both skills bind a background process to the life of an owner through a canary:
# the owner holds a FIFO's write end, the watching process inherits its read end, and every writer
# gone means the owner died, for any reason, SIGKILL included — seen WITHOUT `$PPID`/`kill -0`,
# both of which read a reparented process as alive. The consumers are shipyard's owner-hold
# continuity watcher (`shipyard_continuity_pause` in shipyard-continuity.sh) and council's `--hold`
# room keeper (`_keeper_loop` in lib/up.sh). Nothing here knows which one is calling.
#
# WHY NOT A PLAIN `read -t` ON THE CANARY (#275, #279). On macOS, select() readiness for EOF on a
# FIFO can be LOST: when the last writer closes just as a select on the read end times out, that
# select reports a timeout, and in every stuck process observed each later `read -t` timed out
# too, although a plain read() on the same fd returned 0 at once, on every attempt. So a watcher
# whose owner died at that instant polled forever. Measured in shipyard (#275) with a perl probe on
# the watcher's own inherited fd, with no writer open anywhere: a select probe saw the fd unreadable
# from the second poll on, and a blocking sysread returned EOF immediately. Measured again in
# council's keeper (#279), where the loop was the same `read -t -u <canary>`: `sample` put every
# stuck keeper in `read_builtin -> shtimer_select -> pselect`, system-wide `lsof` showed the canary
# held by the keeper's read end alone, and each was still polling 33 s after its owner died.
#
# So the watching process never selects on the canary. A SENTINEL — a process substitution, so a
# child in the caller's own process group — blocks in a plain `read` on it and writes one `eof`
# line into an anonymous pipe when that read ends, and the caller's `read -t` waits on that pipe.
# The sentinel's read is the blocking kind, and what the caller selects on is DATA in a pipe, which
# does not have that edge.
#
# THE RESIDUAL: this rests on the blocking read() path seeing FIFO EOF, which was measured on the
# platform where the select edge was found, not proven from kernel source. A blocked read has no
# timeout to race, which is the part of the failure that was observed, but a lost wakeup for a
# blocked reader would still leave the sentinel, and so the caller, waiting. Nothing here detects
# that case.
#
# WHAT A SENTINEL INHERITS. A process substitution inherits every fd open in the caller when it is
# started. It holds the canary's READ end, so it can never keep an owner's death from being seen;
# anything else the caller had open it keeps too, until the owner's death ends its read. A caller
# that exits for another reason while its owner lives and must not leave those fds held calls
# `canary_sentinel_stop`.

# canary_sentinel_start <canary-read-fd> — start the sentinel. Sets CANARY_SENTINEL_FD to the pipe's
# read end and CANARY_SENTINEL_PID to its pid; returns 1, leaving both empty, when the pipe cannot
# be made. Stray bytes on the canary are read and ignored, so the line means EOF — every writer gone
# — or a failed read, which is treated as EOF, as a direct read was. The `2>/dev/null` is scoped by
# the braces: on a bare `exec` it would stay on the calling shell and silence its stderr from then
# on.
canary_sentinel_start() {
  local cfd="$1"
  CANARY_SENTINEL_FD=""; CANARY_SENTINEL_PID=""
  { exec {CANARY_SENTINEL_FD}< <(
      while read -r -u "$cfd" _ 2>/dev/null; do :; done
      printf 'eof\n'); } 2>/dev/null || { CANARY_SENTINEL_FD=""; return 1; }
  CANARY_SENTINEL_PID=$!
}

# canary_owner_gone <canary-read-fd-or-empty> <interval> — wait up to <interval> seconds and say
# whether the owner is gone. Returns 0 to keep looping, 1 when the owner is gone. With no canary fd
# it is a plain sleep. With one, through the sentinel above (started on first use): a `read -t` on
# the sentinel's pipe that times out (rc > 128) means the sentinel is still blocked on the canary,
# so a writer (the live owner) still holds it; an `eof` line means every writer is gone and the
# owner has died, and it arrives AT ONCE, so the caller acts immediately rather than an interval
# late. A sentinel pipe that ends WITHOUT that line means the sentinel itself was signalled, not
# that the owner died: its pipe is dropped, this call sleeps out its interval, and the next call
# starts a new sentinel. If no sentinel can be started, the canary is read directly, which is right
# except for the select edge described above.
canary_owner_gone() {
  local cfd="$1" interval="$2" rc line=""
  if [ -z "$cfd" ]; then sleep "$interval"; return 0; fi
  if [ -z "${CANARY_SENTINEL_FD:-}" ] \
    && ! canary_sentinel_start "$cfd"; then
    read -r -t "$interval" -u "$cfd" _ 2>/dev/null; rc=$?
    [ "$rc" -eq 0 ] && return 0
    [ "$rc" -gt 128 ] && return 0
    return 1
  fi
  read -r -t "$interval" -u "$CANARY_SENTINEL_FD" line 2>/dev/null; rc=$?
  [ "$rc" -gt 128 ] && return 0
  # The sentinel has written its line and is exiting, so its pid is no longer one to signal.
  [ "$rc" -eq 0 ] && [ "$line" = eof ] && { CANARY_SENTINEL_PID=""; return 1; }
  { exec {CANARY_SENTINEL_FD}<&-; } 2>/dev/null || true
  CANARY_SENTINEL_FD=""; CANARY_SENTINEL_PID=""
  sleep "$interval"
  return 0
}

# canary_sentinel_stop — end a running sentinel and close its pipe; a no-op when none is running.
# For a caller leaving while its owner lives (see WHAT A SENTINEL INHERITS). It signals one pid, the
# one `canary_sentinel_start` recorded from `$!`, and only a positive integer above 1: `kill` reads
# 0 as the caller's whole process group and -1 as every process it may signal.
canary_sentinel_stop() {
  case "${CANARY_SENTINEL_PID:-}" in
    ''|*[!0-9]*|0*|1) ;;   # 0* as well: `kill` reads a leading-zero pid such as 01 as 1
    *) kill -TERM "$CANARY_SENTINEL_PID" 2>/dev/null || true ;;
  esac
  if [ -n "${CANARY_SENTINEL_FD:-}" ]; then
    { exec {CANARY_SENTINEL_FD}<&-; } 2>/dev/null || true
  fi
  CANARY_SENTINEL_FD=""; CANARY_SENTINEL_PID=""
}
