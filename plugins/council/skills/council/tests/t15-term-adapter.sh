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
# this file already asserts ct_name and the container verbs. The OP verbs are asserted in their
# own section below (#248), which also checks that no ct_* verb term.sh defines goes unasserted.
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

# --- the OP verbs, and every other delegation (#248) ------------------------------------------
# t21 and t27 replace these verbs wholesale with fakes, so without this section nothing ran the
# shipped bodies. The failure it closes is silent: `ct_no_agent` with its `ct_name` dropped hands
# the driver a bare peer name, which names no session, so the driver returns no verdict, and then
# `say`'s exit-8 refusal and `status`'s NO AGENT line never fire. With `_ct_pin_dir` dropped, a verb
# loses the room's container pin on agterm. The same edit to `ct_type` sends every `say` down the
# absence path.
#
# Each drv_* verb the ct_* verbs probed here delegate to is replaced by a recorder that appends one
# line to a file: its own name, each argument, and the pin directory it saw. (The absence verbs have
# their own probes in the section above.) Each call runs in a fresh subshell with the pin directory
# unset, so a dropped `_ct_pin_dir` reads `unset`, and a dropped `ct_name` shows up as the bare
# peer. A file rather than stdout, because `ct_launch_record` captures what its drv_* call prints.
DRV_CALLS="$ROOT/drv-calls"
dprobe() { # <ct verb> <arg>... — print the drv_* calls it made, one per line
  : > "$DRV_CALLS"
  ( export COUNCIL_BACKEND=tmux ROOM="$ROOM" POLICY_MAILBOX_DIR="$ROOT/probe-mailbox"
    . "$TERM_SH"
    local v
    for v in drv_backend drv_shq drv_target drv_read drv_tell drv_submit drv_kill drv_focus \
             drv_no_agent drv_both_pinned drv_pin drv_handles drv_launch_handle drv_container \
             drv_container_pin; do
      eval "$v() { { printf '%s' $v; [ \$# = 0 ] || printf '|%s' \"\$@\"; printf '|pindir=%s\n' \"\${DRV_CONTAINER_PIN_DIR:-unset}\"; } >> \"\$DRV_CALLS\"; }"
    done
    unset DRV_CONTAINER_PIN_DIR
    "$@" ) >/dev/null 2>&1
  cat "$DRV_CALLS"
}
SN="council-demo-room-alice"; PD="pindir=$ROOM/state"
ok "ct_target resolves the name, sets the pin dir"  "drv_target|$SN|$PD"         "$(dprobe ct_target alice)"
ok "ct_capture -> drv_read"                         "drv_read|$SN|$PD"           "$(dprobe ct_capture alice)"
ok "ct_type -> drv_tell, with the text"             "drv_tell|$SN|hello there|$PD" "$(dprobe ct_type alice 'hello there')"
ok "ct_submit -> drv_submit"                        "drv_submit|$SN|$PD"         "$(dprobe ct_submit alice)"
ok "ct_kill -> drv_kill"                            "drv_kill|$SN|$PD"           "$(dprobe ct_kill alice)"
ok "ct_focus -> drv_focus"                          "drv_focus|$SN|$PD"          "$(dprobe ct_focus alice)"
ok "ct_no_agent -> drv_no_agent, with the gap"      "drv_no_agent|$SN|1|$PD"     "$(dprobe ct_no_agent alice 1)"
ok "ct_both_pinned -> drv_both_pinned"              "drv_both_pinned|$PD"        "$(dprobe ct_both_pinned)"
ok "ct_pin -> drv_pin"                              "drv_pin|$PD"                "$(dprobe ct_pin)"
# ct_container's case at the top of this file runs with no pin present, where the derived name is
# the same with or without the pin directory, so the pin directory is asserted here. The
# ct_container_pin probe is for symmetry: the pin-file case above already reds without it.
ok "ct_container -> drv_container"                  "drv_container|$PD"          "$(dprobe ct_container)"
ok "ct_container_pin -> drv_container_pin"          "drv_container_pin|$PD"      "$(dprobe ct_container_pin)"
# The launch goes through drv_launch_handle; what it RECORDS is the launch-record section's job.
ok "ct_launch_record -> drv_launch_handle"          "drv_launch_handle|$SN|/some/cwd|/some/launcher|$PD" \
   "$(dprobe ct_launch_record up alice /some/cwd /some/launcher | head -1)"
# These three set no pin directory, and need none: the backend and the quoting are process-wide,
# and the handle list is read against the pin by its caller. Only the delegation is asserted.
ok "ct_backend -> drv_backend"                      "drv_backend"                "$(dprobe ct_backend | sed 's/|pindir=.*//')"
ok "ct_shq -> drv_shq, with its argument"           "drv_shq|a b"                "$(dprobe ct_shq 'a b' | sed 's/|pindir=.*//')"
ok "ct_handles -> drv_handles"                      "drv_handles"                "$(dprobe ct_handles | sed 's/|pindir=.*//')"

# NO ct_* VERB GOES UNASSERTED. A verb added to term.sh without a probe above, or in the sections
# before this one, reds here. The ones that delegate to no single drv_* verb are listed with where
# they are asserted instead.
ASSERTED="ct_target ct_capture ct_type ct_submit ct_kill ct_focus ct_no_agent ct_both_pinned ct_pin
          ct_launch_record ct_backend ct_shq ct_handles
          ct_name ct_container ct_container_pin ct_sessions ct_absence_class ct_pins_elsewhere
          ct_record_launch"            # the launch-record section below
NOT_DELEGATIONS="ct_seat_verdicts"    # verdict logic, asserted through `terminals` in t27 and t35
defined=$( export COUNCIL_BACKEND=tmux ROOM="$ROOM"; . "$TERM_SH"; declare -F | awk '$3 ~ /^ct_/ { print $3 }' )
unasserted=$(for f in $defined; do
               case " $(echo $ASSERTED $NOT_DELEGATIONS) " in *" $f "*) ;; *) printf '%s ' "$f" ;; esac
             done)
ok "every ct_* verb term.sh defines is asserted somewhere" "" "$unasserted"

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
