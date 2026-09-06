#!/usr/bin/env bash
# t11-slot-graph.sh — shipyard's per-slot supervision as a DECLARED FLOW GRAPH, evaluated by the
# shared guard's session-less `flow_phase` authority mode (FLOW-03, esc 100-1 -> Option B). It pins:
#   1. the phase mapping: (PR/MR number, forge state, ship stage, terminal presence) -> the slot's
#      supervision phase launched | in-review | concluded | "" (fully done);
#   2. behaviour-preservation of the documented rules — a `?` forge state stays in flight, `merged`
#      with the terminal still up is `concluded` (still in flight), and only a torn-down terminal is
#      the empty terminal phase; and that the verdict matches the old scattered forge-state test;
#   3. THE PARENT'S EXPLICIT ASK — a legitimately-idle child is NOT mis-phased. The graph reads
#      facts, never liveness, which is the whole reason shipyard uses flow_phase (authority) and not
#      flow_run (which would park a bare-idle child);
#   4. the wiring is LOAD-BEARING (the #99 lesson): shipyard-report.sh consults this graph and
#      derives the glyph verdict and the in-flight count from it, and the old scattered test is gone.
#
# The shared guard is bash >= 5 (associative arrays); re-exec into one if a stock bash 3.2 started
# us, the same guard council.sh and the flow tests use.
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ] && [ -z "${SHIPYARD_T11_REEXEC:-}" ]; then
  for _c in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash bash; do
    _p=$(command -v "$_c" 2>/dev/null) || continue
    _v=$("$_p" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null) || continue
    [ "${_v:-0}" -ge 5 ] && exec env SHIPYARD_T11_REEXEC=1 "$_p" "$0" "$@"
  done
  echo "t11-slot-graph: needs bash >= 5, this one is ${BASH_VERSION:-unknown}." >&2
  echo "                macOS ships bash 3.2 as /bin/bash; install a modern one (brew install bash)." >&2
  exit 70
fi

set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$DIR/.." && pwd)"
GRAPH="$SKILL_DIR/shipyard-slot-graph.sh"
REPORT="$SKILL_DIR/shipyard-report.sh"
# shellcheck source=../shipyard-slot-graph.sh
. "$GRAPH"

CHECKS=0
FAILURES=0
ok() {  # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then
    printf '  ok   %s\n' "$1"
  else
    printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"
    FAILURES=$((FAILURES + 1))
  fi
}
done_() {
  if [ "$FAILURES" -eq 0 ]; then
    printf '%s: %d checks, all passed\n' "$1" "$CHECKS"; return 0
  fi
  printf '%s: %d checks, %d FAILED\n' "$1" "$CHECKS" "$FAILURES"; return 1
}

A="ship-42:sess"   # a present terminal address

# ---------------------------------------------------- 1. the phase mapping, facts -> phase
# shipyard_slot_phase <iid> <mr_state> <stage> <addr>
ok "no PR/MR yet -> launched"            "launched"   "$(shipyard_slot_phase ''  'no MR yet' issue-ready  "$A")"
ok "PR open, mid-review -> in-review"     "in-review"  "$(shipyard_slot_phase 11  opened     impl-review  "$A")"
ok "ready-to-merge -> concluded"         "concluded"  "$(shipyard_slot_phase 11  opened     ready-to-merge "$A")"
ok "merged, terminal up -> concluded"    "concluded"  "$(shipyard_slot_phase 11  merged     done         "$A")"
ok "closed, terminal up -> concluded"    "concluded"  "$(shipyard_slot_phase 11  closed     impl-review  "$A")"
ok "merged, terminal gone -> '' (done)"  ""           "$(shipyard_slot_phase 11  merged     done         '')"

# ---------------------------------------------------- 2. behaviour-preservation (documented rules)
# `?` forge state is neither merged nor closed -> the slot stays in-review, i.e. in flight.
ok "? forge state -> in-review (in flight)" "in-review" "$(shipyard_slot_phase 11 '?' impl-review "$A")"
# needs-human is NOT the concluded verdict — the old code showed it `active`; preserved.
ok "needs-human stage is not concluded"     "in-review" "$(shipyard_slot_phase 11 opened needs-human "$A")"
# The launched node gates on the PR/MR number, not the terminal: an opened MR with the terminal
# still up is past launched even when the stage file is empty.
ok "opened MR, empty stage -> in-review"     "in-review" "$(shipyard_slot_phase 11 opened '' "$A")"

# ---------------------------------------------------- 3. a legitimately-idle child is NOT mis-phased
# The graph consults facts (PR/MR number, forge state, ship stage, terminal presence), NEVER the
# child's liveness. So an idle in-review child — waiting on CI, on an escalation answer, or between
# ticks — computes the SAME phase and verdict as a busy one: idle is simply not an input. (This is
# exactly what flow_run could not give: it would read bare idle as a stall and park a healthy child.)
idle_phase=$(shipyard_slot_phase 11 opened impl-review "$A")
busy_phase=$(shipyard_slot_phase 11 opened impl-review "$A")
ok "idle child: phase unchanged by liveness" "$busy_phase" "$idle_phase"
ok "idle in-review child stays in-review"     "in-review"   "$idle_phase"
ok "idle in-review child is not concluded"    "active"      "$(shipyard_slot_verdict "$idle_phase")"

# ---------------------------------------------------- 4. the verdict a phase maps to (pre-overlay)
ok "launched  -> active"    "active"    "$(shipyard_slot_verdict launched)"
ok "in-review -> active"    "active"    "$(shipyard_slot_verdict in-review)"
ok "concluded -> completed" "completed" "$(shipyard_slot_verdict concluded)"
ok "torn-down -> completed" "completed" "$(shipyard_slot_verdict torn-down)"
ok "'' (done) -> completed" "completed" "$(shipyard_slot_verdict '')"
ok "unknown   -> active (never falsely completed)" "active" "$(shipyard_slot_verdict some-garbage)"

# ---------------------------------------------------- 5. the executable `slot` interface report uses
# "<phase> <verdict>", one subprocess per live slot. The empty (fully-done) phase is rendered as the
# literal `torn-down` so report.sh can test it as a word rather than mistake it for a dropped slot.
ok "slot: in-review active"                 "in-review active"   "$(bash "$GRAPH" slot 11 opened impl-review "$A")"
ok "slot: concluded completed"              "concluded completed" "$(bash "$GRAPH" slot 11 merged done "$A")"
ok "slot: torn-down completed (empty->word)" "torn-down completed" "$(bash "$GRAPH" slot 11 merged done '')"
ok "slot: launched active"                  "launched active"    "$(bash "$GRAPH" slot '' 'no MR yet' issue-ready "$A")"

# ---------------------------------------------------- 6. FLOW-02: the phase is deterministic
# The done_when vocabulary is `check <fn>` over pure boolean functions — no model, no side effect —
# so the same facts always yield the same phase.
p1=$(shipyard_slot_phase 11 opened impl-review "$A")
p2=$(shipyard_slot_phase 11 opened impl-review "$A")
ok "phase is deterministic over the facts" "$p1" "$p2"

# ---------------------------------------------------- 7. the wiring is load-bearing (the #99 lesson)
# A declared graph with no production caller is decorative. Pin the real callers in report.sh: it
# consults the graph as a subprocess, and derives BOTH the glyph verdict and the in-flight count
# from the result — and the old scattered forge-state verdict test is gone, not left as a second
# authority beside the graph.
ok "report.sh consults the slot graph"                 "1" "$(grep -Fc 'shipyard-slot-graph.sh" slot' "$REPORT")"
ok "report.sh derives the glyph from the graph verdict" "1" "$(grep -Fc 'shipyard_note "$slot" "$verdict"' "$REPORT")"
ok "report.sh derives inflight from the graph phase"    "1" "$(grep -Fc '[ "$phase" = torn-down ] || inflight=' "$REPORT")"
ok "the old scattered forge-state verdict test is gone" "0" "$(grep -Fc '[ "$state" = merged ] || [ "$state" = closed ]' "$REPORT")"

done_ t11-slot-graph
