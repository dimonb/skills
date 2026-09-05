#!/usr/bin/env bash
# t-flow.sh — unit tests for the shared flow-guard interpreter (shared/flow/flow.sh).
#
# Everything here is a PURE drive of a declared graph against a FAKED driver — drv_tell /
# drv_submit / drv_signal are stubbed in this file, and `flow_sleep` is a no-op — so NO live
# terminal, no agent, no network, no real time. It covers the interpreter's whole surface:
# graph declaration (flow_node), the mechanical predicate vocabulary (signal / artifact / budget /
# check), the per-node poll loop, done -> on_done transitions incl. emit, block -> policy (park and
# resume), the default-deny policy seam, and the two structural guarantees the issue names — that
# no transition prompts a model, and the interpreter carries no skill-specific branch.
#
# The interpreter's baseline is bash >= 5 (associative arrays), so re-exec into one if a stock bash
# 3.2 started us (the same guard t-driver.sh and council.sh use).
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ] && [ -z "${FLOW_TEST_BASH_REEXEC:-}" ]; then
  for _c in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash bash; do
    _p=$(command -v "$_c" 2>/dev/null) || continue
    _v=$("$_p" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null) || continue
    [ "${_v:-0}" -ge 5 ] && exec env FLOW_TEST_BASH_REEXEC=1 "$_p" "$0" "$@"
  done
  echo "t-flow: needs bash >= 5, this one is ${BASH_VERSION:-unknown}." >&2
  echo "        macOS ships bash 3.2 as /bin/bash; install a modern one (brew install bash)." >&2
  exit 70
fi

set -uo pipefail
export LC_ALL=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLOW="$(cd "$DIR/.." && pwd)/flow.sh"
DEMO="$(cd "$DIR/.." && pwd)/examples/demo-graph.sh"
[ -f "$FLOW" ] || { echo "t-flow: cannot find the interpreter at $FLOW" >&2; exit 1; }
[ -f "$DEMO" ] || { echo "t-flow: cannot find the example graph at $DEMO" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/flow-test.XXXXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

CHECKS=0
FAILURES=0
# ok <label> <expected> <actual>
ok() {
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"
    FAILURES=$((FAILURES + 1))
  fi
}

# --- the faked driver ------------------------------------------------------------------------
# drv_tell / drv_submit log their argv so a test can assert exactly what the agent was told (and,
# crucially, that a predicate evaluation told it NOTHING). drv_signal returns whatever token the
# test has put in $FAKE_SIG, and exits 1 for a dead token, matching the real driver's contract.
TELLLOG="$TMP/tell.log"
: > "$TELLLOG"
FAKE_SIG="live|busy"
drv_tell()   { printf 'TELL %s :: %s\n' "$1" "$2" >> "$TELLLOG"; }
drv_submit() { printf 'SUBMIT %s\n' "$1" >> "$TELLLOG"; }
drv_signal() { printf '%s' "$FAKE_SIG"; case "$FAKE_SIG" in *dead*) return 1 ;; *) return 0 ;; esac; }

# A file-backed counter, so a `check` predicate can model "becomes true after N polls" — the check
# runs in a subshell (flow.sh isolates it), so an in-memory counter would not survive; a file does.
CNT="$TMP/counter"
_probe_after() {          # arg1 = threshold; returns 0 once this has been called >= threshold times
  local n; n=$(cat "$CNT" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s' "$n" > "$CNT"
  [ "$n" -ge "$1" ]
}
reset_counter() { printf '0' > "$CNT"; }

# shellcheck source=../flow.sh
. "$FLOW"
# The interpreter times out real nodes after 600 polls; keep the suite's own default small so a
# never-completing node blocks quickly. Individual cases override as needed.
export FLOW_MAX_POLLS=5
# A no-op sleep keeps the poll loop instantaneous.
flow_sleep() { :; }

# --- 1. flow_node: declaration + validation --------------------------------------------------
printf '\n── flow_node declaration ──\n'
flow_reset
flow_node alpha --enter "hi" --done-when "artifact /x" --on-done "goto:beta" --on-block policy
flow_node beta  --done-when "signal idle" --on-done close
ok "a declared node is known"              0 "$(_flow_known alpha; echo $?)"
ok "a second declared node is known"       0 "$(_flow_known beta; echo $?)"
ok "an undeclared node is not known"        1 "$(_flow_known gamma; echo $?)"
ok "enter is stored verbatim"              "hi"          "${_FLOW_ENTER[alpha]:-}"
ok "done_when is stored verbatim"          "artifact /x" "${_FLOW_DONE_WHEN[alpha]:-}"
ok "on_done is stored verbatim"            "goto:beta"   "${_FLOW_ON_DONE[alpha]:-}"
# Re-declaring extends, it does not wipe unnamed fields.
flow_node alpha --enter "bye"
ok "re-declaring updates only the named field" "bye"        "${_FLOW_ENTER[alpha]:-}"
ok "...and leaves the others intact"           "goto:beta" "${_FLOW_ON_DONE[alpha]:-}"
# Validation.
badopt_rc=0; ( flow_node z --nope x ) 2>/dev/null || badopt_rc=$?
ok "an unknown flow_node option is refused"  2 "$badopt_rc"
noval_rc=0; ( flow_node z --enter ) 2>/dev/null || noval_rc=$?
ok "a flag with no value is refused"          2 "$noval_rc"
noname_rc=0; ( flow_node "" --enter x ) 2>/dev/null || noname_rc=$?
ok "a missing node name is refused"           2 "$noname_rc"

# --- 2. the mechanical predicate vocabulary --------------------------------------------------
# Evaluated directly, and — the point of FLOW-02 — with the tell log watched: evaluating any
# predicate must prompt the agent NOTHING.
printf '\n── predicate vocabulary (and: no agent prompt in a predicate) ──\n'
: > "$TELLLOG"
ok "signal: token contained"      0 "$(_flow_pred_met 'live|idle' 0 'signal idle'; echo $?)"
ok "signal: token absent"          1 "$(_flow_pred_met 'live|busy' 0 'signal idle'; echo $?)"
: > "$TMP/exists"
ok "artifact: present"             0 "$(_flow_pred_met '' 0 "artifact $TMP/exists"; echo $?)"
ok "artifact: absent"               1 "$(_flow_pred_met '' 0 "artifact $TMP/nope"; echo $?)"
ok "budget: reached"               0 "$(_flow_pred_met '' 5 'budget 3'; echo $?)"
ok "budget: not yet"                1 "$(_flow_pred_met '' 2 'budget 3'; echo $?)"
ok "check: command exits 0"        0 "$(_flow_pred_met '' 0 'check true'; echo $?)"
ok "check: command exits 1"         1 "$(_flow_pred_met '' 0 'check false'; echo $?)"
ok "an empty predicate is never met" 1 "$(_flow_pred_met 'live|idle' 9 ''; echo $?)"
ok "an unknown predicate kind is not met" 1 "$(_flow_pred_met '' 0 'bogus x' 2>/dev/null; echo $?)"
ok "evaluating predicates prompted the agent nothing" 0 "$(wc -l < "$TELLLOG" | tr -d ' ')"

# --- 3. end to end over the example graph ----------------------------------------------------
# The acceptance run: a declared graph driven start to finish against the fake. collect completes
# on an artifact, transitions to confirm, which completes on an idle signal and emits a marker.
printf '\n── example graph, end to end ──\n'
. "$DEMO"
: > "$TELLLOG"
REPORT="$TMP/report"; DONE="$TMP/done"
: > "$REPORT"                     # the report already exists, so collect completes at once
rm -f "$DONE"
e2e_rc=0
( FLOW_DEMO_REPORT="$REPORT" FLOW_DEMO_DONE="$DONE" FAKE_SIG="live|idle" FLOW_SESSION=s
  flow_demo_graph
  flow_run collect ) || e2e_rc=$?
ok "the example graph runs to a clean close" 0 "$e2e_rc"
ok "the confirm node emitted its artifact"   0 "$([ -f "$DONE" ]; echo $?)"
# Both nodes entered, collect before confirm.
c_line=$(grep -n 'Produce the report' "$TELLLOG" | head -1 | cut -d: -f1)
f_line=$(grep -n 'Confirm the report' "$TELLLOG" | head -1 | cut -d: -f1)
ok "collect entered"  0 "$([ -n "$c_line" ]; echo $?)"
ok "confirm entered"  0 "$([ -n "$f_line" ]; echo $?)"
ok "collect entered before confirm" 0 "$([ -n "$c_line" ] && [ -n "$f_line" ] && [ "$c_line" -lt "$f_line" ]; echo $?)"

# --- 4. a node advances ONLY on its mechanical predicate --------------------------------------
# The agent stays busy the whole time (never idle, so it never stalls); the node must not advance
# until the `check` predicate turns true on exactly the 3rd poll — no earlier, no signal-driven
# short-cut.
printf '\n── advance only on the predicate ──\n'
reset_counter
: > "$TMP/reached-b"
adv_rc=0
( flow_reset
  flow_node a --done-when 'check _probe_after 3' --on-done goto:b
  flow_node b --done-when 'budget 0' --emit "$TMP/reached-b" --on-done close
  FAKE_SIG="live|busy" FLOW_SESSION=s FLOW_MAX_POLLS=10 flow_run a ) || adv_rc=$?
ok "the graph closed"                       0 "$adv_rc"
ok "it advanced on exactly the 3rd check"    3 "$(cat "$CNT")"
ok "and reached the second node"             0 "$([ -f "$TMP/reached-b" ]; echo $?)"

# busy + never-done must poll to the budget and then BLOCK (it must not falsely complete). Here the
# block is routed by an explicit on_block goto, proving the timeout path.
printf '\n── busy + never done -> timeout is a block ──\n'
: > "$TMP/timedout"
to_rc=0
( flow_reset
  flow_node work --done-when "artifact $TMP/never" --on-block goto:ontimeout
  flow_node ontimeout --done-when 'budget 0' --emit "$TMP/timedout" --on-done close
  FAKE_SIG="live|busy" FLOW_SESSION=s FLOW_MAX_POLLS=3 flow_run work ) || to_rc=$?
ok "a timeout routed by on_block reaches its target" 0 "$to_rc"
ok "the timeout target ran"                            0 "$([ -f "$TMP/timedout" ]; echo $?)"

# --- 5. a blocking signal defers to policy ---------------------------------------------------
# The agent goes idle without the completion fact ever appearing -> the node blocks -> default
# on_block `policy` -> default-deny stub returns `human` -> the run parks and stops.
printf '\n── block defers to policy (park) ──\n'
PARK="$TMP/park"; : > "$PARK"
park_rc=0
( flow_reset
  flow_node stuck --enter "do the thing" --done-when "artifact $TMP/never" --on-block policy
  FAKE_SIG="live|idle" FLOW_SESSION=s FLOW_PARK_FILE="$PARK" flow_run stuck ) || park_rc=$?
ok "a parked run returns the needs-human code" 10 "$park_rc"
ok "the park file records the node"             0 "$(grep -q "parked at node 'stuck'" "$PARK"; echo $?)"

# policy `resume` re-polls the same node; when the completion fact then appears, the node completes.
# policy_dispose is overridden to resume and to count how often it was consulted.
printf '\n── block -> policy resume -> done ──\n'
reset_counter
DISPCOUNT="$TMP/dispcount"; printf '0' > "$DISPCOUNT"
policy_dispose() {         # override the default-deny stub: resume, and count the consultations
  local n; n=$(cat "$DISPCOUNT" 2>/dev/null || echo 0); printf '%s' "$((n + 1))" > "$DISPCOUNT"
  printf 'resume'
}
resume_rc=0
( flow_reset
  # done_when turns true on the 2nd check; the agent is idle, so each attempt does one check then
  # stalls, policy resumes, and the 2nd attempt's check completes it.
  flow_node retryish --done-when 'check _probe_after 2' --on-block policy --on-done close
  FAKE_SIG="live|idle" FLOW_SESSION=s flow_run retryish ) || resume_rc=$?
ok "a resumed node can complete"          0 "$resume_rc"
ok "policy was consulted before it did"    0 "$([ "$(cat "$DISPCOUNT")" -ge 1 ]; echo $?)"
# restore the default-deny stub for later cases by re-sourcing (define-only-if-absent won't, so
# unset first).
unset -f policy_dispose
. "$FLOW"

# A resume that never completes must still be bounded: after FLOW_MAX_BLOCKS it parks.
printf '\n── an always-resume that never completes is still bounded ──\n'
policy_dispose() { printf 'resume'; }
bound_rc=0
( flow_reset
  flow_node spin --done-when "artifact $TMP/never" --on-block policy
  FAKE_SIG="live|idle" FLOW_SESSION=s FLOW_MAX_BLOCKS=3 flow_run spin ) || bound_rc=$?
ok "an unresolvable resume loop parks (needs-human)" 10 "$bound_rc"
unset -f policy_dispose
. "$FLOW"

# --- 6. the default-deny policy seam ---------------------------------------------------------
# In a FRESH bash (so the test's own definitions are not inherited): the stub is default-deny, and
# it never shadows a policy the caller sourced first. "$BASH" is this (>= 5) interpreter.
printf '\n── policy seam: default-deny, no shadowing ──\n'
def=$("$BASH" -c '. "$1"; policy_dispose x' _ "$FLOW" 2>/dev/null)
ok "absent a real policy, the stub is default-deny (human)" "human" "$def"
pre=$("$BASH" -c 'policy_dispose(){ printf CALLER; }; . "$1"; policy_dispose x' _ "$FLOW" 2>/dev/null)
ok "a caller's policy sourced first is not shadowed" "CALLER" "$pre"

# --- 7. flow_run guardrails ------------------------------------------------------------------
printf '\n── flow_run guardrails ──\n'
nosess_rc=0; ( flow_reset; flow_node n --done-when 'budget 0'; unset FLOW_SESSION; flow_run n ) 2>/dev/null || nosess_rc=$?
ok "flow_run without a session refuses"       64 "$nosess_rc"
nostart_rc=0; ( flow_reset; FLOW_SESSION=s flow_run "" ) 2>/dev/null || nostart_rc=$?
ok "flow_run without a start node refuses"     66 "$nostart_rc"
unknown_rc=0; ( flow_reset; FLOW_SESSION=s flow_run ghost ) 2>/dev/null || unknown_rc=$?
ok "flow_run on an unknown node refuses"        66 "$unknown_rc"
badact_rc=0; ( flow_reset; flow_node n --done-when 'budget 0' --on-done 'sideways'; FLOW_SESSION=s flow_run n ) 2>/dev/null || badact_rc=$?
ok "a malformed transition action is refused"   67 "$badact_rc"
# A cycle is caught by the node budget rather than looping forever.
cycle_rc=0; ( flow_reset; flow_node loop --done-when 'budget 0' --on-done goto:loop; FLOW_SESSION=s FLOW_MAX_NODES=5 flow_run loop ) 2>/dev/null || cycle_rc=$?
ok "a cycle trips the node budget"              65 "$cycle_rc"

# --- 8. structural: no skill-specific branch in the interpreter -------------------------------
# FLOW-01: the interpreter reads the graph and names no skill. The header comment legitimately
# mentions both skills (it is shared BY them), so scan only the non-comment lines.
printf '\n── structural: no skill name in interpreter code ──\n'
skillrefs=$(grep -vE '^[[:space:]]*#' "$FLOW" | grep -cE 'shipyard|council' || true)
ok "no skill name appears in a code line" 0 "$skillrefs"

# --- done ------------------------------------------------------------------------------------
printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 't-flow: %d checks, all passed\n' "$CHECKS"
  exit 0
fi
printf 't-flow: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"
exit 1
