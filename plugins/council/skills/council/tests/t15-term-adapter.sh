#!/usr/bin/env bash
# t15 — the council terminal ADAPTER (lib/term.sh) over the shared drv_* driver.
#
# lib/term.sh no longer carries the backend mechanics; it maps council's knobs onto the shared
# driver (lib/agent-driver.sh) and delegates each ct_* verb to the matching drv_*. The driver's
# own mechanics are covered by shared/driver/tests/t-driver.sh; THIS file asserts only the
# council-specific glue the migration introduced, and that the naming stays byte-identical to
# before: the `-ai` container suffix on agterm and none on tmux, the pin file under $ROOM/state,
# the council-<room>-<peer> session-name template, and the COUNCIL_BACKEND -> DRV_BACKEND mapping
# including the refusal a bad value yields. Everything here is a pure read over environment
# variables — no live terminal, no agtermctl, no tmux: an explicit COUNCIL_BACKEND resolves the
# driver's backend without invoking any CLI, so the container derivation is deterministic.
#
# term.sh sources the driver, whose baseline interpreter is bash >= 5, so re-exec into one if a
# stock bash 3.2 started us (the guard council.sh and t-driver.sh use), or a bash-5-only construct
# in the driver would surface here as a confusing syntax error rather than a clear version message.
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ] && [ -z "${T15_BASH_REEXEC:-}" ]; then
  for _c in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash bash; do
    _p=$(command -v "$_c" 2>/dev/null) || continue
    _v=$("$_p" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null) || continue
    [ "${_v:-0}" -ge 5 ] && exec env T15_BASH_REEXEC=1 "$_p" "$0" "$@"
  done
  echo "t15: needs bash >= 5, this one is ${BASH_VERSION:-unknown}." >&2
  exit 70
fi

set -uo pipefail
export LC_ALL=C
SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TERM_SH="$SKILL/lib/term.sh"
[ -f "$TERM_SH" ] || { echo "t15: cannot find term.sh at $TERM_SH" >&2; exit 1; }

ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$ROOT"' EXIT

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}

ROOM="$ROOT/demo-room"          # its basename drives ct_name
mkdir -p "$ROOM/state"

# --- ct_name — council's own template, the one thing that stays in the adapter ---------------
got=$( export COUNCIL_BACKEND=tmux ROOM="$ROOM"; . "$TERM_SH"; ct_name alice )
ok "ct_name is council-<room>-<peer>" "council-demo-room-alice" "$got"

# --- the container suffix: -ai on agterm, none on tmux --------------------------------------
# Both derive from the same repo stem (same cwd), so their relationship is asserted without
# hard-coding the machine's repo name. AGTERM_WORKSPACE_ID is unset so agterm takes the repo-stem
# fallback rather than a live workspace name.
tmux_c=$( export COUNCIL_BACKEND=tmux ROOM="$ROOM"; . "$TERM_SH"; ct_container )
agt_c=$(  export COUNCIL_BACKEND=agterm ROOM="$ROOM"; unset AGTERM_WORKSPACE_ID; . "$TERM_SH"; ct_container )
ok "tmux container carries no -ai suffix" "$tmux_c"    "${agt_c%-ai}"
ok "agterm container appends -ai"         "$tmux_c-ai" "$agt_c"

# --- the pin lives under $ROOM/state, keyed by backend — exactly where it did pre-migration --
pin_v=$( export COUNCIL_BACKEND=tmux ROOM="$ROOM"; . "$TERM_SH"; ct_container_pin )
ok "ct_container_pin writes \$ROOM/state/container-tmux" "$pin_v" "$(cat "$ROOM/state/container-tmux" 2>/dev/null)"

# --- COUNCIL_BACKEND -> DRV_BACKEND: an unresolvable value refuses (exit 1), the headless path -
rc=0
( export COUNCIL_BACKEND=none-for-tests ROOM="$ROOM"; . "$TERM_SH"; ct_container ) >/dev/null 2>&1 || rc=$?
ok "an unresolvable backend refuses (exit 1)" 1 "$rc"

# --- the ABSENCE verbs: ct_sessions / ct_absence_class / ct_pins_elsewhere -------------------
# WHY THESE ARE HERE AND NOT IN t21-say.sh. t21 drives `council_say`, which sources term.sh at
# CALL time, so the only seam it has is a shadow `lib/term.sh` — and a shadow means the SHIPPED
# verbs never execute. Measured: gutting the real `ct_sessions()` to `{ return 0; }`, which
# restores the exact #141 defect (an unreachable backend read as "answered, nothing there", so
# `say` exits 3 "that seat is gone" and sends the operator to `relaunch` on a live agent), left
# the whole council suite green. So the wiring is asserted here, against the real file, the way
# this file already asserts ct_name and the container verbs. Note what that does NOT amount to:
# for the OP verbs — ct_capture, ct_type, ct_submit, ct_kill, ct_focus, ct_launch_record,
# ct_target — nothing in the council suite asserts what the drv_* call was handed. (Several tests
# do REACH one: t13-relaunch drives the real ct_launch_record to prove regeneration happens before
# the launch, t16-keeper-canary drives _ct_launch_owned, and the launch-record section below fakes
# drv_launch_handle to assert what gets RECORDED. None checks the driver's arguments.) So
# "t15 covers the ct_* delegations" would be too broad a claim to make anywhere.
#
# THE ONE PROPERTY EACH MUST HAVE is `_ct_pin_dir` FIRST. Without it the driver has no pin
# directory, so `ct_pins_elsewhere` returns 1 — and because `say` guards that remedy with
# `[ -n "$pin" ]`, the operator is told the room was launched on another backend and then given NO
# backend to pin, the line omitted entirely. That is the exact thing t21's case 2b was written to
# catch but cannot, because it runs its own copy of these verbs.
#
# Faked at the drv_* layer, AFTER sourcing term.sh, so the real ct_* bodies run: each fake records
# what it was handed, including the pin directory the delegation was supposed to set.
#
# The tmux pin the ct_container_pin case above wrote is REMOVED first, so the probe below has
# exactly one pin to report, the other backend's, and it does so only if the pin directory was set.
# (With both present `drv_pins_elsewhere` reports the other one too, #132; that rule is asserted in
# shared/driver/tests, not here.)
rm -f "$ROOM/state/container-tmux"
: > "$ROOM/state/container-agterm"     # a pin for a backend we are NOT resolving

probe=$( export COUNCIL_BACKEND=tmux ROOM="$ROOM"
         . "$TERM_SH"
         drv_sessions() { printf 'PINDIR=%s\n' "${DRV_CONTAINER_PIN_DIR:-unset}"; }
         ct_sessions )
ok "ct_sessions sets the pin dir before delegating" "PINDIR=$ROOM/state" "$probe"

probe=$( export COUNCIL_BACKEND=tmux ROOM="$ROOM"
         . "$TERM_SH"
         drv_absence_class() { printf 'rc=%s list=%s name=%s pindir=%s' \
                                 "$1" "${2:-}" "${3:-}" "${DRV_CONTAINER_PIN_DIR:-unset}"; }
         ct_absence_class 0 "council-demo-room-alice" "council-demo-room-bob" )
ok "ct_absence_class passes all three arguments through" \
   "rc=0 list=council-demo-room-alice name=council-demo-room-bob pindir=$ROOM/state" "$probe"

# The real driver function, not a fake: this is the one whose value reaches an operator, and the
# pin file above makes the answer non-empty only if the pin directory was actually set.
probe=$( export COUNCIL_BACKEND=tmux ROOM="$ROOM"; . "$TERM_SH"; ct_pins_elsewhere )
ok "ct_pins_elsewhere reads \$ROOM/state, so the remedy has a value" "agterm" "$probe"
rm -f "$ROOM/state/container-agterm"

# --- the launch record (#247): what `up` and `relaunch` write -------------------------------------
# The readers of this record are exercised in t27, over a record written as `up` would write it.
# THIS is the writer, driven through the real `ct_launch_record` with only `drv_launch_handle`
# faked, so the handle recorded is the one the launch returned and not one looked up afterwards.
MB="$ROOT/mailbox"; mkdir -p "$MB"
printf '{"order":["a","b","me"],"created_ms":4242}\n' > "$ROOM/roster.json"
LR="$MB/council-launch-demo-room"
# The fake answers with the handle named in $ROOT/next-handle, or with the rc in $ROOT/next-rc.
lr_run() { # <shell text using ct_*> — run it with the real term.sh and a faked launch
  ( export COUNCIL_BACKEND=tmux ROOM="$ROOM" POLICY_MAILBOX_DIR="$MB"
    . "$TERM_SH"
    drv_launch_handle() {
      local rc; rc=$(cat "$ROOT/next-rc" 2>/dev/null || printf 0)
      [ "$rc" = 1 ] && return 1
      printf 'fake-container\t%s' "$([ "$rc" = 2 ] || cat "$ROOT/next-handle")"
      return "$rc"
    }
    eval "$1" )
}
lr_q() { jq -r "$1" "$LR" 2>/dev/null; }
printf 'fake-container\n' > "$ROOM/state/container-tmux"

printf '0' > "$ROOT/next-rc"; printf '@1' > "$ROOT/next-handle"
lr_run 'ct_launch_record up-first a /tmp /dev/null'; rc=$?
printf '@2' > "$ROOT/next-handle"
lr_run 'ct_launch_record up b /tmp /dev/null'
lr_run 'ct_record_launch up me fake-container "" false'
ok "up: the launch reports success"                    0 "$rc"
ok "up: the record is at generation 1"                 1 "$(lr_q .generation)"
ok "up: each seat carries the handle its launch returned" "@1 @2" "$(lr_q '"\(.seats.a.handle) \(.seats.b.handle)"')"
ok "up: ...with its backend, container and name"       "tmux fake-container council-demo-room-a" \
   "$(lr_q '"\(.seats.a.backend) \(.seats.a.container) \(.seats.a.name)"')"
ok "up: the --me seat is recorded as not launched"     "false null" "$(lr_q '"\(.seats.me.launched) \(.seats.me.handle)"')"
ok "up: the record is bound to this room"              "4242 $(cd "$ROOM" && pwd -P)" "$(lr_q '"\(.created_ms) \(.room)"')"
ok "up: the record is not a *.json mailbox entry"      0 "$(ls "$MB"/*.json 2>/dev/null | wc -l | tr -d ' ')"
ok "up: lr_read accepts it"                            0 "$(lr_run 'lr_read >/dev/null'; echo $?)"

# A RELAUNCH ADVANCES THE GENERATION, and rewrites only the seat it launched.
printf '@7' > "$ROOT/next-handle"
lr_run 'ct_launch_record relaunch a /tmp /dev/null'
ok "relaunch: the generation advances"                 2 "$(lr_q .generation)"
ok "relaunch: the seat carries the NEW handle"         "@7 2" "$(lr_q '"\(.seats.a.handle) \(.seats.a.generation)"')"
ok "relaunch: the other seats are left as they were"   "@2 1" "$(lr_q '"\(.seats.b.handle) \(.seats.b.generation)"')"

# A launch that went through without a handle is recorded as launched with none, which every read
# then reports as unknown, and the launch itself still reports success because a terminal started.
printf '2' > "$ROOT/next-rc"
lr_run 'ct_launch_record relaunch b /tmp /dev/null'; rc=$?
ok "no handle: the launch still reports success"       0 "$rc"
ok "no handle: recorded as launched with no handle"    "true null 3" "$(lr_q '"\(.seats.b.launched) \(.seats.b.handle) \(.generation)"')"
# A failed launch is recorded as not launched, and reports the failure.
printf '1' > "$ROOT/next-rc"
lr_run 'ct_launch_record relaunch b /tmp /dev/null'; rc=$?
ok "failed launch: reported as a failure"              1 "$rc"
ok "failed launch: recorded as not launched"           "false null" "$(lr_q '"\(.seats.b.launched) \(.seats.b.handle)"')"
printf '0' > "$ROOT/next-rc"

# A record for another room — an earlier room of the same name, purged and recreated — is not
# written into. A relaunch starts a fresh one that knows only the seat it launched.
jq '.created_ms = 1' "$LR" > "$LR.tmp" && mv "$LR.tmp" "$LR"
ok "a foreign record: lr_read refuses it, rc 4"        4 "$(lr_run 'lr_read >/dev/null'; echo $?)"
printf '@9' > "$ROOT/next-handle"
lr_run 'ct_launch_record relaunch a /tmp /dev/null'
ok "a foreign record is replaced, not extended"        "4242 1 a" "$(lr_q '"\(.created_ms) \(.generation) \(.seats | keys | join(","))"')"
# No record at all: lr_read says so, in the words the operator will see.
rm -f "$LR"
ok "no record: lr_read is rc 1"                        1 "$(lr_run 'lr_read >/dev/null'; echo $?)"
ok "...and says what that means"                       1 "$(lr_run 'lr_read' | grep -c 'predates launch records, or the record was removed')"
# The write goes through policy_mailbox_write, so a FIFO planted at the path cannot block it.
rm -f "$LR"; mkfifo "$LR"
( lr_run 'ct_launch_record up-first a /tmp /dev/null' ) & wpid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$wpid" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$wpid" 2>/dev/null; then kill "$wpid" 2>/dev/null; r=blocked; else r=returned; fi
ok "a FIFO at the record's path does not block the write" returned "$r"
ok "...and the record replaced it"                     "@9" "$(lr_q .seats.a.handle)"
rm -f "$LR" "$ROOM/state/container-tmux" "$ROOM/roster.json" "$ROOT/next-rc" "$ROOT/next-handle"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then echo "t15 PASS ($CHECKS checks)"; else echo "t15 FAIL ($FAILURES/$CHECKS)"; exit 1; fi
