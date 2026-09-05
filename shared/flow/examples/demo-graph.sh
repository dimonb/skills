# demo-graph.sh — a tiny, skill-agnostic example flow graph.
#
# Not vendored and not called by any skill: it is a REFERENCE that shows how a graph is declared
# as data against the interpreter (shared/flow/flow.sh), and it is what the flow test suite drives
# end to end against a faked driver. Deliberately generic — it names no skill and encodes nothing
# specific to shipyard or council; those graphs (one node, and a turn cycle) are separate later
# changes (FLOW-03/04).
#
# The graph, two nodes:
#   collect  — tell the agent to produce a report; DONE when the report file exists (an artifact
#              predicate); then go to `confirm`.
#   confirm  — tell the agent to confirm; DONE when it goes idle (a signal predicate); emit a
#              completion marker, then close. If it stalls without confirming, defer to policy.
#
# Every `done_when` is mechanical (a file exists, a signal token arrived) — no node consults a
# model. Source this file, then call `flow_demo_graph` to register the nodes, set FLOW_SESSION,
# and `flow_run collect`. The two paths are read from the environment so the caller owns locations:
#   FLOW_DEMO_REPORT   the report artifact the `collect` node waits for.
#   FLOW_DEMO_DONE     the completion marker the `confirm` node emits.
flow_demo_graph() {
  flow_reset
  flow_node collect \
    --enter "Produce the report and write it to the report path, then stop." \
    --done-when "artifact ${FLOW_DEMO_REPORT:-}" \
    --on-done goto:confirm
  flow_node confirm \
    --enter "Confirm the report is complete." \
    --done-when "signal idle" \
    --emit "${FLOW_DEMO_DONE:-}" \
    --on-done close \
    --on-block policy
}
