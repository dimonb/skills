#!/usr/bin/env bash
# launch-record.sh — where a room's launch record lives, and reading it. Source only.
#
# WHAT A SEAT WAS LAUNCHED AS, written at launch and read by every question about whether it is
# still up (#247). Before this, those reads matched a session NAME (`council-<room>-<peer>`) inside
# a container named by a pin in the room. Retargeting or deleting the pin, or starting a session
# with that name, made a live seat read gone or a dead one read alive. The record holds the handle
# the backend ASSIGNED at launch (`drv_launch_handle`), and a read matches on that.
#
# WHY A FILE OF ITS OWN: the readers must be able to ask whether a record exists WITHOUT sourcing
# term.sh, because sourcing term.sh resolves a terminal backend (on agterm, a control-socket probe),
# and a room with no pin, no launcher and no record should not pay that to be told it has none.
# Nothing here touches a backend. The write, which needs the backend and the session name, is
# `ct_record_launch` in term.sh, and the verdict is `ct_seat_verdicts` beside it.
#
# WHERE: `<mailbox>/council-launch-<room>`, beside `status`' signature (`_status_sigfile`), so it is
# outside the room and survives `down`. It has no `.json` suffix so the mailbox's escalation
# readers, which glob `*.json`, never see it. It is written only through `policy_mailbox_write`, so
# a FIFO planted at the path cannot block `up` or `relaunch`. The READ is `[ -f ]`-gated, with the
# usual window between the check and the open: the FIFO read residual #204 names.
#
# SHAPE: {room, created_ms, generation, seats: {<peer>: {backend, container, name, handle,
# launched, generation}}}. `up` writes it at generation 1 with an entry for EVERY roster seat, and
# `relaunch` advances the generation and rewrites one seat. A seat nothing was launched for (the
# `--me` seat, a failed launch) has `launched: false` and a null handle. `room` and `created_ms`
# bind the record to one room, so a record left by an earlier room of the same name reads as
# foreign. `down` leaves the record in place, and `down --purge` removes it with the room.
#
# ACCIDENT-GRADE, like the rest of #204. The mailbox is as writable by a seat as the room is, so
# this raises what a forgery costs and does not prevent one. The routes that remain: a coordinated
# edit of the pin and the record together, and manipulating the backend itself (a session created
# with a recycled tmux window id AND the recorded container and name). What it does close is the
# single write: retargeting the pin, deleting it, or planting a same-named session now reads
# UNKNOWN rather than healthy.
#
# SCOPE. The readers that use it are the three #247 names: `_room_terminals` (the closed-room
# alarm's count, and the `terminals` verb behind `rooms`' term column) and `_seat_liveness`.
# `say`'s and `relaunch`'s absence checks, and the keeper's reap, still address a seat by name
# through `ct_*`. That boundary was chosen, and reaching past it is its own change.
_LR_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)

_lr_policy() {
  command -v policy_mailbox_dir >/dev/null 2>&1 && command -v policy_mailbox_write >/dev/null 2>&1 \
    && return 0
  [ -f "$_LR_LIB/policy.sh" ] && . "$_LR_LIB/policy.sh" || return 1
  command -v policy_mailbox_write >/dev/null 2>&1
}

# The room's canonical path. `up` names a room by its physical path and a reader may reach it
# through COUNCIL_ROOM spelled any way at all (a symlink, a trailing slash), so both the file name
# and the binding below use this form. Otherwise a room read through another spelling would look
# as if it had no record.
lr_room_path() { (cd "$ROOM" 2>/dev/null && pwd -P) || printf '%s' "${ROOM%/}"; }

# lr_file — the record's path for $ROOM, or rc 1 when the mailbox cannot be resolved.
lr_file() {
  local mb
  _lr_policy || return 1
  mb=$(policy_mailbox_dir) || return 1
  printf '%s/council-launch-%s' "$mb" "$(basename "$(lr_room_path)")"
}

# The roster's `created_ms`, which binds a record to this room rather than to an earlier one that
# had the same name. Empty when the roster cannot say.
lr_room_created() { jq -r '.created_ms // empty | tostring' "$ROOM/roster.json" 2>/dev/null; }

# lr_read — this room's record on stdout, rc 0. Otherwise the REASON on stdout and a status that
# says which: 1 no record exists, 3 the mailbox cannot be resolved, 4 a record exists but is
# unreadable or belongs to another room. The reason is worded for an operator. An unknown caused
# by a missing record must say so, so that an old room's `?` reads as expected rather than as a
# fault, and a deleted record reads exactly the same way.
lr_read() {
  local f rec
  if ! f=$(lr_file); then
    printf 'the escalation mailbox cannot be resolved, so the launch record cannot be read'; return 3
  fi
  if [ ! -f "$f" ]; then
    printf 'this room has no launch record (it predates launch records, or the record was removed)'
    return 1
  fi
  rec=$(jq -ce --arg room "$(lr_room_path)" --arg cms "$(lr_room_created)" '
          select(type == "object" and (.seats | type) == "object"
                 and .room == $room and (.created_ms | tostring) == $cms)' "$f" 2>/dev/null) \
    || { printf 'the launch record in the mailbox is unreadable or belongs to another room'; return 4; }
  printf '%s' "$rec"
}

# lr_forget — remove this room's record (`down --purge`, whose room is gone with it).
lr_forget() { local f; f=$(lr_file) && rm -f "$f"; }
