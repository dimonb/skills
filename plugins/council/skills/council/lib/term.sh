#!/usr/bin/env bash
# term.sh — the terminal a participant lives in. Source only.
#
# Two backends, one API: agterm (a native macOS terminal driven over a control socket by
# `agtermctl`) and tmux. `COUNCIL_BACKEND=agterm|tmux|auto`, default auto: agterm when its
# socket answers, else tmux, and a hard error when neither is there — a room whose
# participants cannot be read from or typed into is worse than one that refuses to start.
#
# The backend MECHANICS no longer live here. They are the one shared agent-console driver
# (shared/driver/agent-driver.sh, vendored beside this file as agent-driver.sh and kept
# byte-identical to its source by scripts/sync-driver.sh + the repo gate). What was a second
# hand-synced copy of that code is now a thin council ADAPTER over it: this file maps council's
# own knobs onto the driver's caller-set variables, keeps council's session-name template, and
# lets every ct_* verb delegate to the matching drv_* one. Everything council must keep identical
# to before — its `<workspace>-ai` container name, its `council-<room>-<peer>` session names, and
# how launch/read/type/submit/capture/kill/focus resolve — is preserved by the mapping below,
# not by a duplicate of the backend logic. If a backend needs fixing, fix it in the shared
# driver; there is no longer a second copy here to keep in step.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# Map council's knobs onto the driver's BEFORE sourcing it. The driver resolves and caches the
# backend once, at source time, so DRV_BACKEND must already carry council's choice or the cache
# would answer for `auto` whatever COUNCIL_BACKEND said. COUNCIL_BACKEND is process-stable, so
# this single mapping reproduces ct_backend's old resolve-and-cache-on-first-call exactly,
# including the `invalid` a bad value used to yield.
#   DRV_BACKEND          <- COUNCIL_BACKEND (default auto).
#   DRV_CONTAINER_SUFFIX  "-ai": council keeps its agent sessions in a `<workspace>-ai` container.
# council sets no container override and does not sanitise the repo stem — the #78 API decision —
# so DRV_CONTAINER_OVERRIDE and DRV_REPO_KEY are left unset; the driver's defaults already match
# council's old repo-key derivation. None of these are exported: the old code put nothing of the
# kind into a launched agent's or the tmux server's environment, and neither does this.
DRV_BACKEND="${COUNCIL_BACKEND:-auto}"
DRV_CONTAINER_SUFFIX="-ai"
. "$(dirname "${BASH_SOURCE[0]}")/agent-driver.sh"

# The container is pinned INSIDE the room: the derived name depends on which workspace the
# launcher was sitting in, so re-deriving it later from another workspace would name an empty
# container. The driver pins under DRV_CONTAINER_PIN_DIR; point it at $ROOM/state on every call,
# because $ROOM is only known at call time — exactly as the old _ct_pin read it.
_ct_pin_dir() { DRV_CONTAINER_PIN_DIR="$ROOM/state"; }

# council's session-name template — the one thing that stays here, because the driver takes a
# RESOLVED name so that callers whose templates differ can share it.
ct_name() { printf 'council-%s-%s' "$(basename "$ROOM")" "$1"; }

# Each ct_* verb is now a thin delegation to the matching drv_* one. The container verbs set the
# pin dir first; the op verbs resolve the peer to its session name with ct_name and hand that to
# the driver, which re-derives the opaque backend handle from it on every call.
ct_backend()       { drv_backend; }
ct_shq()           { drv_shq "$1"; }
ct_container()     { _ct_pin_dir; drv_container; }
ct_container_pin() { _ct_pin_dir; drv_container_pin; }
ct_target()        { _ct_pin_dir; drv_target "$(ct_name "$1")"; }
# Launching is `ct_launch_record` (below, #247): it launches through `drv_launch_handle` and writes
# what was launched into the room's launch record, so there is no separate ct_launch any more.
ct_capture()       { _ct_pin_dir; drv_read   "$(ct_name "$1")"; }
ct_type()          { _ct_pin_dir; drv_tell   "$(ct_name "$1")" "$2"; }
ct_submit()        { _ct_pin_dir; drv_submit "$(ct_name "$1")"; }
ct_kill()          { _ct_pin_dir; drv_kill   "$(ct_name "$1")"; }
ct_focus()         { _ct_pin_dir; drv_focus  "$(ct_name "$1")"; }
# Whether the agent launched into a seat's terminal is still what owns it (#235): `agent`, `none`,
# or no verdict (exit 1). The reading and both directions it can be wrong in are the driver's, at
# `drv_occupant`; the two-read rule council applies to it is `c_seat_no_agent` in lib.sh.
ct_occupant()      { _ct_pin_dir; drv_occupant "$(ct_name "$1")"; }
# The absence verbs, added when `council say` had to stop reporting a live participant as
# having no terminal (#141). `ct_sessions` enumerates the room's container — its EXIT STATUS is
# the fact that matters, "the backend answered", which an empty list does not settle — and
# `ct_absence_class` is the verdict drawn from that status plus the container pin. Both are
# `_ct_pin_dir`-first like every other container verb, because the pin is what stops a call made
# from another workspace naming an empty container.
ct_sessions()      { _ct_pin_dir; drv_sessions; }
ct_absence_class() { _ct_pin_dir; drv_absence_class "$1" "${2:-}" "${3:-}"; }
# Needed as its own verb and not as a bare `drv_pins_elsewhere` at the call site: the class above
# is read through a command substitution, so the `_ct_pin_dir` inside it runs in a subshell and
# never reaches the caller's shell. A remedy line that asked the driver directly would find no pin
# directory and return 1 — and because `say` guards that line with `[ -n "$pin" ]`, the operator
# would be told the room is pinned elsewhere and then given NO backend to pin, the line omitted
# entirely rather than printed empty.
ct_pins_elsewhere() { _ct_pin_dir; drv_pins_elsewhere; }
ct_pin()            { _ct_pin_dir; drv_pin; }
ct_handles()        { drv_handles; }

# --- the launch record (#247) ----------------------------------------------------------------------
# What a seat was launched as. Where it lives, its shape, what it is worth against a seat that
# wants to forge it, and which readers use it are stated first in lib/launch-record.sh. What is
# here is the part that needs a backend: the write (`ct_record_launch`), the launch that feeds it
# (`ct_launch_record`), and the per-seat verdict (`ct_seat_verdicts`).
. "$(dirname "${BASH_SOURCE[0]}")/launch-record.sh"

# ct_record_launch <mode> <peer> <container> <handle> <launched:true|false> — write one seat into
# the record. <mode> is `up-first` for the first seat `up` records, which starts a fresh record at
# generation 1; `up` for the rest; `relaunch`, which advances the generation. A missing or foreign
# record is replaced by a fresh one rather than written into, so a room's first relaunch after the
# upgrade gets a record that knows only the seat it launched. The other seats then read unknown,
# which is what the evidence supports.
ct_record_launch() {
  local mode="$1" peer="$2" container="$3" handle="$4" launched="$5" f rec
  # In THIS shell, before any command substitution: `lr_file` loads policy.sh on demand, but it
  # runs inside `$( )` below, so what it sources there never reaches the write at the end. `up`
  # does not source policy.sh itself, so without this line every record write failed.
  _lr_policy || return 1
  f=$(lr_file) || return 1
  mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
  if [ "$mode" = up-first ] || ! rec=$(lr_read); then
    rec=$(jq -cn --arg room "$(lr_room_path)" --arg cms "$(lr_room_created)" \
            '{room: $room, created_ms: ($cms | tonumber? // $cms), generation: 0, seats: {}}') || return 1
    [ "$mode" = relaunch ] || rec=$(printf '%s' "$rec" | jq -c '.generation = 1') || return 1
  fi
  printf '%s' "$rec" | jq -c --arg mode "$mode" --arg p "$peer" --arg be "$(ct_backend)" \
      --arg c "$container" --arg n "$(ct_name "$peer")" --arg h "$handle" --argjson l "$launched" '
      (if $mode == "relaunch" then .generation += 1 else . end)
      | .seats[$p] = {backend: $be, container: $c, name: $n,
                      handle: (if $h == "" then null else $h end),
                      launched: $l, generation: .generation}' \
    | policy_mailbox_write "$f"
}

# ct_launch_record <mode> <peer> <cwd> <launcher> — launch a seat and write what was launched.
# Exit status is the launch's: 0 started, 1 not started. A launch whose backend returned no handle
# is still 0, because a terminal started, and it is recorded as launched with no handle, which
# every later read reports as unknown. A launch that started but could not be RECORDED also stays
# 0 and warns on stderr, for the same reason: the terminal is up, and its missing record reads
# unknown rather than healthy.
ct_launch_record() {
  local mode="$1" peer="$2" out rc=0 TAB container handle launched=true
  TAB=$(printf '\t')
  _ct_pin_dir
  out=$(drv_launch_handle "$(ct_name "$peer")" "$3" "$4") || rc=$?
  if [ "$rc" = 1 ]; then
    container=$(ct_pin 2>/dev/null) || container=""
    ct_record_launch "$mode" "$peer" "$container" "" false 2>/dev/null || true
    return 1
  fi
  container=${out%%"$TAB"*}; handle=${out#*"$TAB"}
  ct_record_launch "$mode" "$peer" "$container" "$handle" "$launched" \
    || echo "council: $peer started, but its launch record could not be written — whether it is up will read as unknown" >&2
  return 0
}

# ct_seat_verdicts <record-json> <handles-rc> <handles> <peer>... — one line per peer:
#   <peer><TAB>live|absent|unknown<TAB><why>
# `live` means the recorded handle is listed with the recorded container and the seat's name.
# `absent` means the backend answered and neither the handle nor anything with the seat's name is
# there. It is the same verdict for a seat that was never launched (`--me`, or a failed launch),
# which `why` tells apart. `unknown` covers everything the evidence cannot settle. Missing or
# contradicting evidence is never `live` and never `absent`.
#
# THE NAME IS COUNCIL'S, NOT THE RECORD'S. Each entry's `name` must equal `ct_name <peer>`, and a
# mismatch is unknown. Trusting the recorded name let ONE write to the record alone make a live seat
# read gone: rename the entry and give it a handle nobody holds, and nothing matched by handle or by
# name. It also let a dead seat's entry copy a live seat's handle, container and name and read live.
# The container is tied to the pin and the name to the peer, so the handle is the only field the
# record alone decides, and a forged handle finds the real session by name and reads unknown.
ct_seat_verdicts() {
  local rec="$1" hrc="$2" handles="$3" pin names p; shift 3
  pin=$(ct_pin 2>/dev/null) || pin=""
  names=$(for p in "$@"; do printf '%s\t%s\n' "$p" "$(ct_name "$p")"; done \
            | jq -Rn '[inputs | split("\t") | {(.[0]): .[1]}] | add // {}') || return 1
  printf '%s\n' "$@" | jq -rR --argjson rec "$rec" --arg hrc "$hrc" --arg handles "$handles" \
      --arg be "$(ct_backend)" --arg pin "$pin" --argjson names "$names" '
    ($handles | split("\n") | map(select(length > 0) | split("\t")
       | {h: .[0], c: (.[1] // ""), n: (.[2] // "")})) as $hs
    | select(length > 0) | . as $p | $rec.seats[$p] as $s | $names[$p] as $want
    | [$p] + (
      if $s == null then ["unknown", "the launch record has no entry for this seat"]
      elif ($s | type) != "object" then ["unknown", "the launch record entry for this seat is malformed"]
      elif $hrc != "0" then ["unknown", "the \($be) backend did not answer when asked which terminals exist"]
      elif $s.backend != $be then ["unknown", "this seat was launched on \($s.backend), and this run resolved \($be)"]
      elif $s.name != $want then ["unknown", "the launch record names \($s.name) for this seat, and its session is named \($want)"]
      else
        ([$hs[] | select(.c == $s.container and .n == $want)]) as $byname
        | if $s.launched != true then
            (if ($byname | length) > 0
             then ["unknown", "nothing was launched for this seat, yet a session named \($want) is listed"]
             else ["absent", "never-launched"] end)
          elif $pin == "" then ["unknown", "the room has no container pin, and its launch record names \($s.container)"]
          elif $pin != $s.container then ["unknown", "the room pin names \($pin), and the launch record names \($s.container)"]
          elif ($s.handle | type) != "string" then ["unknown", "the seat was launched but the backend returned no handle for it"]
          else
            ([$hs[] | select(.h == $s.handle)]) as $byh
            | if ($byh | length) > 0 then
                (if $byh[0].c == $s.container and $byh[0].n == $want
                 then ["live", $s.handle]
                 else ["unknown", "the recorded handle \($s.handle) now belongs to another terminal (\($byh[0].c)/\($byh[0].n)), so it is stale"] end)
              elif ($byname | length) > 0 then
                ["unknown", "the launched terminal \($s.handle) is gone, yet a session named \($want) is listed: a stale record or a planted name"]
              else ["absent", "gone"] end
          end
      end)
    # The reasons quote pin, record and backend values, which a seat can write, and a reason lands
    # in the one-line operator alarm. So PRINTABLE ASCII ONLY, the same whitelist lib.sh applies to
    # lane names: stripping only the characters that split this line let ESC through, and one pin
    # write of cursor-control bytes could then erase the alarms line on a terminal.
    | map(tostring | gsub("[^ -~]"; " ")) | join("\t")'
}
