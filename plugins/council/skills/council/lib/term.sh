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
# drv_launch echoes the session name on success; ct_launch never wrote to stdout, and its callers
# run it uncaptured before council prints its own summary — so swallow that echo here while
# preserving the exit status the callers branch on.
ct_launch()        { _ct_pin_dir; drv_launch "$(ct_name "$1")" "$2" "$3" >/dev/null; }
ct_capture()       { _ct_pin_dir; drv_read   "$(ct_name "$1")"; }
ct_type()          { _ct_pin_dir; drv_tell   "$(ct_name "$1")" "$2"; }
ct_submit()        { _ct_pin_dir; drv_submit "$(ct_name "$1")"; }
ct_kill()          { _ct_pin_dir; drv_kill   "$(ct_name "$1")"; }
ct_focus()         { _ct_pin_dir; drv_focus  "$(ct_name "$1")"; }
