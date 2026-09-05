#!/usr/bin/env bash
# room-graph.sh — council's turn cycle as a DECLARED FLOW GRAPH, and the single authority for
# which phase the room is in. Source only; sourced at the END of lib/verbs.sh, so the verdict
# reader it leans on (v_verdict) is already defined.
#
# FLOW-04. The room's protocol is a graph the shared flow guard (lib/flow.sh, the vendored
# shared/flow/flow.sh) EVALUATES as an authority — `flow_phase`, the session-less mode — so
# "which phase is the room in / does the opening round still hold" is decided in ONE declared
# place instead of each reader re-deriving the barrier (the #74 "hold the opening barrier in every
# reader" race class). It changes WHO decides a round/turn advances, not the messaging beneath it:
# the barrier and the floor stay PURE FUNCTIONS OF THE LOG (c_barrier, c_floor_at), and this file
# only gathers the phase rules into one graph and reads them the same way everywhere.
#
# The graph, three nodes, every `done_when` a MECHANICAL predicate over the log (FLOW-02 — no
# node consults a model):
#   opening   the opening barrier round (roundtable's first lap). Complete once the round is
#             closed — the transport's own c_round_complete (a `token` room is closed from the
#             start, so it begins already past `opening`, exactly as today). -> exchange
#   exchange  turn-taking deliberation; whose turn is c_floor_at, gated as it always was.
#             Complete once the room has concluded — ready to decide (claims.jq's closure rule,
#             behind a `check`), or a record already written. -> closing
#   closing   ready, awaiting the record. Complete once the decision record is on disk. -> close
# The floor (whose turn it is WITHIN `exchange`) stays c_floor_at consulted centrally by the
# transport; the graph gates the PHASE, the floor gates the turn — together they are the "turn
# admission decided in one place" the migration asks for.
. "$(dirname "${BASH_SOURCE[0]}")/flow.sh"

# The two closure predicates the exchange/closing nodes gate on (the opening node's predicate,
# c_round_complete, lives in lib.sh beside the barrier it reads). Each is a deterministic command
# over the log — no agent is asked anything (FLOW-02) — and each wraps an EXISTING reader so the
# graph and the verbs share one rule rather than a second copy of it.
#
# c_room_decided: the room's durable output exists. The one reader that decides a room is closed
# (c_recorded_status) already carries the whole account of why it is the record and not a `decide`
# message; this is a boolean over it.
c_room_decided() { [ -n "$(c_recorded_status)" ]; }
# c_room_ready: deliberation has CONCLUDED — the room is ready to decide (claims.jq's rule, read
# through v_verdict so the closure logic is not duplicated), OR a record is already written. The
# second half is what keeps the phase MONOTONIC: `ready-to-decide` is a live verdict that flips to
# `decided` the moment the record lands, so without it a decided room would read as `ready-to-
# decide == false` and its phase would fall back to `exchange` instead of closing out. `|| true`
# guards the one reader here that can fail (v_verdict returns 1 with no output on an unreadable
# roster); an empty word is simply not `ready-to-decide`, and c_room_decided still answers from the
# record, which passes through neither the log nor the roster.
c_room_ready() {
  local v
  v=$(v_verdict --json 2>/dev/null | jq -r '.verdict // empty' 2>/dev/null || true)
  [ "$v" = ready-to-decide ] || c_room_decided
}

# The graph, declared as data. flow_reset first because verbs.sh is sourced once per verb, so this
# runs again on each invocation and must rebuild cleanly rather than append. council owns the one
# flow graph in its process, so resetting it here is safe.
council_room_graph() {
  flow_reset
  flow_node opening  --done-when 'check c_round_complete' --on-done goto:exchange
  flow_node exchange --done-when 'check c_room_ready'     --on-done goto:closing
  flow_node closing  --done-when 'check c_room_decided'   --on-done close
}
council_room_graph

# c_phase — the room's phase, read from the declared graph by the shared guard:
#   opening | exchange | closing | ""(empty = decided/closed).
# This is the single authority: it is a PURE FUNCTION OF THE LOG (every predicate reads the log,
# never the caller's cursor or timing), so a wedged or slow reader computes the SAME phase as an
# up-to-date one — which is what makes "a reader cannot desync the round" structural rather than
# careful. The transport's hot paths do NOT walk the whole graph on every read: they ask only the
# opening gate through the cheap c_round_open / c_round_closed accessors (lib.sh), which are the
# `opening` node's own predicate. c_phase is the full read, for a supervisor's "where is this
# room" and for the tests that pin the graph end to end.
c_phase() { flow_phase opening; }
