#!/usr/bin/env bash
# t21-say.sh — `council say` must ESTABLISH what it claims.
#
# PROVENANCE. Three defects, all on the one line this file guards, each reported separately
# because each produced a different wrong action by the supervisor reading the output:
#
#   * A MISTYPED PEER read as a dead terminal (#29). `say` went straight to the terminal lookup,
#     so `codx` came back as "participant has no live terminal" — and the documented next move
#     for a dead seat is `relaunch`, which was then the first verb to say the name was not in the
#     room at all. The diagnosis arrived one verb late, from the command that was not the problem.
#   * A LIVE PARTICIPANT read as a dead terminal (#141). `COUNCIL_BACKEND=auto` resolves per
#     PROCESS by probing the agterm control socket, so one failed probe sends the run to the other
#     backend, where this room's seats correctly are not. Same sentence, opposite cause, and the
#     same ending: `relaunch` kills a live agent mid-turn and takes its context with it.
#   * AN UNSUBMITTED MESSAGE read as delivered (#117). The confirmation COUNTED `[supervisor]` in
#     the capture, before and after. But the caller TYPES that very marker into the seat's input
#     box and the capture INCLUDES the box, so the count rose whether or not the submit took —
#     the report was manufactured by the typing it was supposed to be checking. The room then
#     waited on a peer that had never heard anything, and a seat with a populated box is idle and
#     quiet, so nothing anywhere said so.
#
# WHAT IS UNDER TEST IS COUNCIL'S WIRING AND ITS EXIT MAPPING, not the verdicts themselves: the
# delivery rule is `adp_delivery_verdict` and the absence rule is `drv_absence_class`, both in
# shared/ and both covered by their own suites (`shared/adapters/tests/t-turn.sh` over real pane
# captures, `shared/driver/tests/t-driver.sh` over faked backends). That split is the point of the
# change — `say` adopts the shared answers rather than carrying a second one — so duplicating
# their cases here would re-establish exactly what it removed. `drv_absence_class` IS called for
# real below, through council's own `ct_absence_class`, because the wiring is what this file is
# about; only the backend underneath it is faked.
#
# THE SEAM THIS DRIVES. `council_say` sources `$SKILL/lib/term.sh` itself, at call time, so a fake
# cannot be installed by defining `ct_*` beforehand — the real file would overwrite it. Pointing
# `SKILL` at a shadow directory whose `lib/term.sh` holds the fakes is therefore not a trick
# around the design, it is the only seam the function has. `up.sh` is still sourced from the REAL
# skill, so the code under test is the shipped code.
#
# NOT COVERED, so a green run is never read as more than it is: a live terminal on either backend;
# whether the shipped `ct_*` verbs reach the driver correctly (t15 owns that); and the residual
# `adp_delivery_verdict` documents — a turn that starts AND finishes between two samples still
# reads `unconfirmed`, which no test over a scripted screen sequence can distinguish.
#
# up.sh's baseline is bash >= 5 (it sources the shared modules), so re-exec into one if a stock
# bash 3.2 started us — the guard council.sh, t15 and t-driver all use.
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ] && [ -z "${T21_BASH_REEXEC:-}" ]; then
  for _c in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash bash; do
    _p=$(command -v "$_c" 2>/dev/null) || continue
    _v=$("$_p" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null) || continue
    [ "${_v:-0}" -ge 5 ] && exec env T21_BASH_REEXEC=1 "$_p" "$0" "$@"
  done
  echo "t21-say: needs bash >= 5, this one is ${BASH_VERSION:-unknown}." >&2
  exit 70
fi

set -uo pipefail
export LC_ALL=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_SKILL="$(cd "$DIR/.." && pwd -P)"
[ -f "$REAL_SKILL/lib/up.sh" ] || { echo "t21-say: cannot find up.sh under $REAL_SKILL" >&2; exit 1; }

: "${COUNCIL_TEST_ROOT:=$(mktemp -d)}"
ROOT="$COUNCIL_TEST_ROOT/t21"; rm -rf "$ROOT"; mkdir -p "$ROOT" || exit 1

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}
has() { printf '%s' "$1" | grep -q -- "$2" && printf yes || printf no; }

# --- the room ---------------------------------------------------------------------------------
ROOM="$ROOT/demo"; mkdir -p "$ROOM/state"
printf '%s\n' '{"order":["claude","codex"],"mode":"token","decide_by":"unanimous"}' >"$ROOM/roster.json"
export COUNCIL_ROOM="$ROOM" ROOM="$ROOM"

# --- the shadow skill, i.e. the faked terminal ------------------------------------------------
# Every knob is a FILE, not a variable: `ct_capture` is called from inside a command substitution,
# so anything it set in a variable would die with that subshell — which is also exactly why
# `ct_pins_elsewhere` had to become its own verb in the real term.sh.
SHADOW="$ROOT/shadow"; mkdir -p "$SHADOW/lib"
PANES="$ROOT/panes"; mkdir -p "$PANES"      # PANES/pre before the send; then PANES/<n>, then PANES/last
NCALLS="$ROOT/capture-n"                    # how many captures have been taken
TYPED="$ROOT/typed"                         # what ct_type was handed
PINS="$ROOT/pins"; mkdir -p "$PINS"         # the container pins drv_pins_elsewhere reads
SESSIONS="$ROOT/sessions"                   # what ct_sessions prints
SESSIONS_RC="$ROOT/sessions-rc"             # ...and the status it exits with

cat >"$SHADOW/lib/term.sh" <<SHADOWEOF
# A fake council terminal. The DRIVER is real — sourced here exactly as the shipped term.sh does
# it — so \`ct_absence_class\` and \`ct_pins_elsewhere\` run the real \`drv_*\` code over a faked
# pin directory. Only the four verbs that would touch a live backend are stubs.
DRV_BACKEND=tmux
. "$REAL_SKILL/lib/agent-driver.sh"
_ct_pin_dir() { DRV_CONTAINER_PIN_DIR="$PINS"; }
ct_name()    { printf 'council-demo-%s' "\$1"; }
ct_backend() { printf 'tmux'; }
# PHASE-AWARE, and that is the whole point of the marker file. Before anything is typed this
# serves PANES/pre; afterwards it walks PANES/1, PANES/2, … and then stays on PANES/last. A
# call-index-only version could not see the pre-send sample at all: deleting that sample merely
# shifted the whole sequence by one, so every case still read the same screens in the same order
# and all 46 checks stayed green while `delivered` lost the `seen_idle` observation it requires.
# Keyed on the phase rather than the count, dropping it changes which screen the first sample
# reads, which is what case 3h below asserts.
ct_capture() {
  local n f
  if [ -f "$TYPED" ]; then
    n=\$(cat "$NCALLS" 2>/dev/null); n=\$(( \${n:-0} + 1 )); printf '%s\n' "\$n" >"$NCALLS"
    f="$PANES/\$n"; [ -f "\$f" ] || f="$PANES/last"
  else
    f="$PANES/pre"
  fi
  cat "\$f" 2>/dev/null
}
ct_type()   { [ "\${FAKE_TYPE_RC:-0}" = 0 ] || return "\$FAKE_TYPE_RC"; printf '%s\n' "\$2" >>"$TYPED"; }
ct_submit() { [ "\${FAKE_SUBMIT_RC:-0}" = 0 ] || return "\$FAKE_SUBMIT_RC"; return 0; }
ct_sessions() { cat "$SESSIONS" 2>/dev/null; return "\$(cat "$SESSIONS_RC" 2>/dev/null || printf 0)"; }
ct_absence_class()  { _ct_pin_dir; drv_absence_class "\$1" "\${2:-}" "\${3:-}"; }
ct_pins_elsewhere() { _ct_pin_dir; drv_pins_elsewhere; }
SHADOWEOF

# --- the real code under test -----------------------------------------------------------------
SKILL="$REAL_SKILL"
# shellcheck source=../lib/lib.sh
. "$REAL_SKILL/lib/lib.sh"
# shellcheck source=../lib/up.sh
. "$REAL_SKILL/lib/up.sh"

# Screens. Kept minimal on purpose — the anchoring itself is t-turn.sh's job, over committed
# captures of both real clients; these only have to be the right STATE, in the right SHAPE.
#
# THE SHAPE IS LOAD-BEARING AND THE FIRST VERSION OF IT WAS WRONG. A footer line always follows
# the composer on screen, so the last non-empty line is the footer and never the box. Without it,
# a draft screen's box line becomes the last line, the footer arm of `adp_turn_running` reads the
# marker out of the text the caller typed, and the forgery case below reported `delivered` —
# failing 3b, which is exactly what 3b is for. The real fixture this is modelled on is
# `shared/adapters/tests/fixtures/pane-claude-draft.txt`; the module names the footer's absence as
# a residual none of its nine captures showed, so inventing a screen without one tests nothing
# real. Do not drop the footer to "simplify" a case.
FOOTER_IDLE='  ⏵⏵ auto mode on (shift+tab to cycle) · PR #NN'
FOOTER_BUSY='  ⏵⏵ auto mode on (shift+tab to cycle) · PR #NN · esc to interrupt · ← for agents'
IDLE=$'some earlier output\n❯ \n'"$FOOTER_IDLE"
RUNNING=$'some earlier output\n❯ \n'"$FOOTER_BUSY"
QUEUED=$'some earlier output\n❯ Press up to edit queued messages\n'"$FOOTER_IDLE"
# A seat whose box holds text nobody submitted: idle, with a footer, and the draft in between.
draft() { printf 'some earlier output\n❯ %s\n%s\n' "$1" "$FOOTER_IDLE"; }

pane() { printf '%s\n' "$1" >"$PANES/$2"; }     # <screen> pre|<index>|last

# Run `council_say` against a freshly scripted terminal. Every case is its own subshell: `c_peers`
# memoises the roster per shell, and the fakes' counters must not carry over.
run_say() { # <peer> <text> -> stdout+stderr, then a last line "rc=<n>"
  local out rc=0
  out=$( SKILL="$SHADOW" council_say "$1" "$2" 2>&1 ) || rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
reset() { rm -f "$PANES"/* "$NCALLS" "$TYPED" "$SESSIONS" "$SESSIONS_RC" "$PINS"/container-*; }
rc_of() { printf '%s' "$1" | sed -n 's/^rc=//p' | tail -1; }

# ============================================================ 1. IS THERE SUCH A SEAT? (#29)
printf '\n── the roster check ──\n'
reset; : >"$PINS/container-tmux"
out=$(run_say codx 'hello')
ok "a mistyped peer is refused at exit 2"      2   "$(rc_of "$out")"
ok "...naming the roster"                      yes "$(has "$out" 'roster: claude, codex')"
# THE POINT OF THE ISSUE: it must not be reported as a dead terminal, because that sends the
# supervisor to `relaunch` — the verb that was already telling the truth.
ok "...and never as a dead terminal"           no  "$(has "$out" 'no live terminal')"
ok "...and never as a cannot-tell"             no  "$(has "$out" 'cannot tell whether')"
# Nothing may be TYPED at a seat that does not exist. Asserting only the message would leave a
# version that prints the refusal after already injecting the text into some other pane.
ok "...and nothing was typed anywhere"         ""  "$(cat "$TYPED" 2>/dev/null)"

# The first peer in the roster must not be rejected. The fix was first proposed as
# `jq -e '.order | index($p)'`, which is truthy-on-0 by luck and SUBSTRING-matching on a string
# `.order` by accident; `c_peers` is used instead, and this case is what would catch a relapse.
reset; : >"$PINS/container-tmux"; pane "$IDLE" pre; pane "$RUNNING" last
out=$(run_say claude 'hello')
ok "the FIRST roster entry is not rejected"    no  "$(has "$out" 'is not in this room')"

# A substring of a real peer is not a peer. `index()` on a string roster would accept this.
reset; : >"$PINS/container-tmux"
out=$(run_say clau 'hello')
ok "a substring of a peer is still refused"    2   "$(rc_of "$out")"

# ============================================================ 2. IS THE TERMINAL REALLY GONE? (#141)
printf '\n── the absence verdict ──\n'
# 2a. CORROBORATED: the backend answered, and it does not have that seat. This is the common,
#     healthy case — a seat that was torn down — and it must still read as gone, or the fix would
#     alarm on the path an operator uses most and teach them to ignore it.
reset; : >"$PINS/container-tmux"; : >"$SESSIONS"; printf '0\n' >"$SESSIONS_RC"
out=$( FAKE_TYPE_RC=1 run_say codex 'hello' )
ok "2a: answered and absent -> exit 3"         3   "$(rc_of "$out")"
ok "2a: ...and says the seat is gone"          yes "$(has "$out" 'that$')"
ok "2a: ...naming the backend that answered"   yes "$(has "$out" 'backend answered and does not have')"
ok "2a: ...and points at relaunch"             yes "$(has "$out" 'council.sh relaunch codex')"

# 2b. THE INCIDENT: the backend ANSWERED, but this room was launched on the other one. Only the
#     pin can catch this; a reachability check alone passes it straight through to "gone".
reset; : >"$PINS/container-agterm"; : >"$SESSIONS"; printf '0\n' >"$SESSIONS_RC"
out=$( FAKE_TYPE_RC=1 run_say codex 'hello' )
ok "2b: pinned elsewhere -> exit 4, not 3"     4   "$(rc_of "$out")"
ok "2b: ...and refuses to call the seat gone"  no  "$(has "$out" 'has no live terminal')"
ok "2b: ...saying instead that it cannot tell" yes "$(has "$out" 'cannot tell whether')"
ok "2b: ...and warns off the relaunch"         yes "$(has "$out" 'do NOT')"
# The remedy must name the backend to pin. "Pin it" with no value is an instruction the operator
# cannot follow without reading the source — and this is the one line that needed its own ct_ verb
# to work at all, because the class is read through a command substitution.
ok "2b: ...with the pin to set"                yes "$(has "$out" 'COUNCIL_BACKEND=agterm')"
ok "2b: ...and not the OTHER class's remedy"   no  "$(has "$out" 'agtermctl version')"

# 2c. The other half: the backend did not answer at all. No pin disagreement here, so this case
#     fails if reachability is ever dropped in favour of the pin check alone.
reset; : >"$PINS/container-tmux"; : >"$SESSIONS"; printf '1\n' >"$SESSIONS_RC"
out=$( FAKE_TYPE_RC=1 run_say codex 'hello' )
ok "2c: unreachable backend -> exit 4"         4   "$(rc_of "$out")"
ok "2c: ...and refuses to call the seat gone"  no  "$(has "$out" 'has no live terminal')"
ok "2c: ...naming what went unanswered"        yes "$(has "$out" 'did not answer when asked')"
# The class-selected remedy is the only actionable content, and asserting the class alone leaves
# the whole `case` arm deletable with the suite green — every line above it prints unconditionally.
ok "2c: ...and prescribes the backend check"   yes "$(has "$out" 'agtermctl version')"
ok "2c: ...and not the OTHER class's remedy"   no  "$(has "$out" 'COUNCIL_BACKEND=agterm')"

# 2d. THE NARROWEST BLIP: the enumeration answered AND still lists this very seat, so it is the
#     per-session lookup that failed. Both other facts agree here, so a status-and-pin check would
#     call a seat the backend has just listed gone.
reset; : >"$PINS/container-tmux"; printf 'council-demo-codex\n' >"$SESSIONS"; printf '0\n' >"$SESSIONS_RC"
out=$( FAKE_TYPE_RC=1 run_say codex 'hello' )
ok "2d: listed but unreachable -> exit 4"      4   "$(rc_of "$out")"
ok "2d: ...and refuses to call the seat gone"  no  "$(has "$out" 'has no live terminal')"
ok "2d: ...naming the contradiction"           yes "$(has "$out" 'still lists council-demo-codex')"
# The fixture must really be half-blind, or 2d silently degrades into a duplicate of 2c.
ok "2d: ...from the listed class, not unreachable" no "$(has "$out" 'did not answer when asked')"

# ============================================================ 3. DID THE MESSAGE GO? (#117)
printf '\n── the delivery verdict ──\n'
# 3a. THE SHIPPED FALSE POSITIVE, and the reason this file exists. The seat is idle throughout and
#     the text is sitting in its box — which is what the capture shows, marker and all. The old
#     read counted `[supervisor]` and found one more than before, so it printed `delivered`.
reset; : >"$PINS/container-tmux"
pane "$IDLE" pre
draft '[supervisor] hello' >"$PANES/last"
out=$(run_say codex 'hello')
ok "3a: text left in the box is NOT delivered" 6   "$(rc_of "$out")"
ok "3a: ...and says so in those words"         yes "$(has "$out" 'MAY BE SITTING UNSENT')"
ok "3a: ...and never says delivered"           no  "$(has "$out" 'delivered')"
# The census names what was actually sampled, which cannot go stale the way a list of possible
# causes does.
ok "3a: ...and reports the states it sampled"  yes "$(has "$out" 'Sampled: idle')"

# 3b. THE FORGERY, directly. A message whose own text contains the turn marker must not confirm
#     itself: the caller types it into the box, and the box is in the capture. This is the
#     standing rule in AGENTS.md — any predicate that reads a child's screen is forgeable by a
#     child whose work IS that predicate — and it is why the read is anchored per line.
reset; : >"$PINS/container-tmux"
pane "$IDLE" pre
draft '[supervisor] watch the footer flip to esc to interrupt before you carry on' >"$PANES/last"
out=$(run_say codex 'watch the footer flip to esc to interrupt before you carry on')
ok "3b: a marker inside the BOX confirms nothing" 6 "$(rc_of "$out")"
ok "3b: ...and still warns about the box"      yes "$(has "$out" 'MAY BE SITTING UNSENT')"

# 3c. A REAL DELIVERY: idle before, a turn running after. Both positive verdicts need the evidence
#     ABSENT and then PRESENT, so this is what a genuine send looks like.
reset; : >"$PINS/container-tmux"
pane "$IDLE" pre; pane "$RUNNING" last
out=$(run_say codex 'hello')
ok "3c: idle then running -> delivered"        0   "$(rc_of "$out")"
ok "3c: ...and says delivered"                 yes "$(has "$out" '^delivered$')"

# 3d. A BUSY SEAT that queues the message. The hint must appear AFTER a non-queued observation, or
#     a hint left over from an earlier `say` would decide this one.
reset; : >"$PINS/container-tmux"
pane "$IDLE" pre; pane "$QUEUED" last
out=$(run_say codex 'hello')
ok "3d: idle then queued -> queued, exit 0"    0   "$(rc_of "$out")"
ok "3d: ...and says it lands next turn"        yes "$(has "$out" 'next turn boundary')"

# 3e. A seat that was ALREADY mid-turn when we typed cannot yield `delivered` from the turn marker
#     alone — the turn we can see is not evidence that our submit started one.
reset; : >"$PINS/container-tmux"
pane "$RUNNING" pre; pane "$RUNNING" last
out=$( COUNCIL_SAY_CONFIRM_SECS=0 run_say codex 'hello' )
ok "3e: running before and after -> unconfirmed" 6 "$(rc_of "$out")"

# 3f. A SUBMIT THAT FAILED is the one case where the text is DEFINITELY in the box, so it is said
#     outright rather than folded into the sampled verdict.
reset; : >"$PINS/container-tmux"; pane "$IDLE" pre; pane "$IDLE" last
out=$( FAKE_SUBMIT_RC=1 run_say codex 'hello' )
ok "3f: a failed submit -> exit 6"             6   "$(rc_of "$out")"
ok "3f: ...and says the text is unsent"        yes "$(has "$out" 'sitting UNSENT')"
ok "3f: ...and never says delivered"           no  "$(has "$out" 'delivered')"

# 3g. The message really is flattened to one line and carries its prefix. A literal newline would
#     submit the message early, which is why the flatten exists at all.
reset; : >"$PINS/container-tmux"; pane "$IDLE" pre; pane "$RUNNING" last
run_say codex "$(printf 'first line\nsecond line')" >/dev/null
ok "3g: the typed text is ONE line"            1   "$(wc -l <"$TYPED" | tr -d ' ')"
ok "3g: ...carrying the supervisor prefix"     yes "$(has "$(cat "$TYPED")" '^\[supervisor\] first line second line$')"

# 3h. THE PRE-SEND SAMPLE IS LOAD-BEARING, and nothing used to notice it was gone. `delivered`
#     requires an IDLE observation before a running one, and the pre-send sample is what usually
#     supplies it — so deleting that line makes a genuine fast send start reading `unconfirmed`,
#     the alarm-on-the-healthy-path direction. Every post-send screen here is RUNNING, so the only
#     possible source of `seen_idle` is the pre-send sample: with it, `delivered`; without it, the
#     first sample is already `running` and the verdict can never be better than `unconfirmed`.
reset; : >"$PINS/container-tmux"
pane "$IDLE" pre; pane "$RUNNING" 1; pane "$RUNNING" last
out=$( COUNCIL_SAY_CONFIRM_SECS=0 run_say codex 'hello' )
ok "3h: only the pre-send sample can supply idle" 0 "$(rc_of "$out")"
ok "3h: ...so the verdict is delivered"        yes "$(has "$out" '^delivered$')"

# ============================================================ 4. THE KNOBS FAIL CLOSED
printf '\n── the poll knobs ──\n'
# EVERY CASE HERE KEEPS THE SEAT IDLE THROUGHOUT, so the poll must really iterate to its deadline.
# The first version of this section put a RUNNING screen in the first post-send capture, which
# broke the loop on its first sample whatever the knobs said — so it asserted only that a message
# was printed, and could not have caught either of the two defects below.
#
# An unusable window must not break the loop after one sample. That is the single-sleep behaviour
# the poll replaced, and it would be announced only by a stray `integer expression expected` on
# stderr — so it must fall back to the documented default instead.
reset; : >"$PINS/container-tmux"; pane "$IDLE" pre; pane "$RUNNING" last
out=$( COUNCIL_SAY_CONFIRM_SECS=nonsense run_say codex 'hello' )
ok "4: a non-numeric window falls back"        0   "$(rc_of "$out")"
ok "4: ...and says which value it used"        yes "$(has "$out" 'using 10')"
ok "4: ...and does not leak a shell error"     no  "$(has "$out" 'integer expression')"

# 4b. A LEADING ZERO. `08` passes an all-digits test and then makes `$(( … + secs ))` an
#     INVALID-OCTAL expansion error, which aborts the shell — AFTER the message has been typed and
#     submitted. The operator got a raw bash error, no verdict at all, and an invitation to
#     re-send a second copy onto the first: the precise harm this whole file exists to prevent,
#     reintroduced by the guard written to prevent it. Normalised to base ten rather than refused,
#     because a leading zero is a typo with an obvious intent.
reset; : >"$PINS/container-tmux"; pane "$IDLE" pre; pane "$IDLE" last
out=$( COUNCIL_SAY_CONFIRM_SECS=08 run_say codex 'hello' )
ok "4b: a leading zero does not abort"         6   "$(rc_of "$out")"
ok "4b: ...leaking no arithmetic error"        no  "$(has "$out" 'value too great for base')"
# The window value reaches the verdict message, which is how we know 08 was read as 8 and not as
# the default 10 — the fallback would be indistinguishable from a correct parse otherwise.
ok "4b: ...and still reaches a verdict"        yes "$(has "$out" 'no turn was seen to start')"
ok "4b: ...having read 08 as eight seconds"    yes "$(has "$out" '^ *8s and the participant')"
# The window that is too long to compute with must announce its fallback, not truncate in silence.
reset; : >"$PINS/container-tmux"; pane "$IDLE" pre; pane "$RUNNING" last
out=$( COUNCIL_SAY_CONFIRM_SECS=99999999999 run_say codex 'hello' )
ok "4b: an implausible window says so"         yes "$(has "$out" 'implausibly large')"

# 4c. EVERY SPELLING OF ZERO, not the four the first version listed. `sleep 00` is a no-op, so a
#     spelling that slips through turns the bounded poll into a fork storm — measured at 74
#     captures in two seconds against 4. Testing for a non-zero digit is what covers them all at
#     once; these cases exist so the next reader cannot "fix" it back into an enumeration.
reset; : >"$PINS/container-tmux"; pane "$IDLE" pre; pane "$RUNNING" last
out=$( COUNCIL_SAY_CONFIRM_INTERVAL=0 run_say codex 'hello' )
ok "4c: a zero interval falls back"            yes "$(has "$out" 'using 0.5')"
for z in 00 000 0.00 .00 000.000 .; do
  reset; : >"$PINS/container-tmux"; pane "$IDLE" pre; pane "$RUNNING" last
  out=$( COUNCIL_SAY_CONFIRM_INTERVAL="$z" run_say codex 'hello' )
  ok "4c: [$z] falls back too"                 yes "$(has "$out" 'using 0.5')"
done
# ...and a legitimate value is NOT rejected, or the guard would be useless in the other direction.
reset; : >"$PINS/container-tmux"; pane "$IDLE" pre; pane "$RUNNING" last
out=$( COUNCIL_SAY_CONFIRM_INTERVAL=0.05 run_say codex 'hello' )
ok "4c: a small but positive interval is kept" no  "$(has "$out" 'using 0.5')"

# --- done -------------------------------------------------------------------------------------
printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 't21-say: %d checks, all passed\n' "$CHECKS"
  exit 0
fi
printf 't21-say: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"
exit 1
