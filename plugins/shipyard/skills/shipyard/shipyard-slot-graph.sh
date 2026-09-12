#!/usr/bin/env bash
# shipyard-slot-graph.sh — a shipyard SLOT's supervision lifecycle as a DECLARED FLOW GRAPH, and
# the single authority for which phase a slot is in. shipyard-report.sh derives a slot's sidebar
# verdict and its in-flight count from this graph (FLOW-03).
#
# WHY flow_phase (authority) AND NOT flow_run (drive). shipyard launches an AUTONOMOUS child
# (`/ship #N`) and then MONITORS it — it does not step-drive it. Its per-slot supervision is a
# periodic, non-blocking snapshot that reads facts (a PR/MR number, the forge state, the ship
# stage, whether the terminal is still up) and decides "which phase is this slot in / is it
# terminal". That is an AUTHORITY READ, exactly council's situation (#98/#99) — so this graph is
# evaluated by the shared guard's session-less `flow_phase` mode, not driven by `flow_run`. Using
# `flow_run` here would be mechanically wrong three ways (esc 100-1, decided Option B): it treats a
# legitimately-idle child (waiting on CI, on an escalation, between ticks) as a stall to park; it
# BLOCKS a shell inside what must be a non-blocking all-slots snapshot; and it keys completion on
# `drv_signal`, while shipyard's terminal signal is the forge state plus the absence of a terminal.
# So: an authority graph, read by flow_phase — never a drive loop, never a puppet.
#
# LOAD-BEARING, not decorative (the #99 lesson: wire a real production caller, not a tested-but-dead
# path). shipyard-report.sh consults this graph for a slot's GLYPH verdict and its INFLIGHT count —
# the same two decisions it used to make with a scattered `if/elif` over the raw forge state and
# ship stage. The mapping from facts to phase, and the ordering (a slot cannot be `concluded`
# before a PR/MR opens), now live in ONE declared place here.
#
# The graph, three nodes, every `done_when` a MECHANICAL predicate (FLOW-02 — no node consults a
# model; each is a deterministic test over the resolved per-slot facts below):
#   launched   the child is up, no PR/MR opened yet. Complete once a PR/MR number is known. -> in-review
#   in-review  the PR/MR is open and ship is running its battery. Complete once ship has concluded
#              — the forge says merged/closed, or the ship stage is ready-to-merge. -> concluded
#   concluded  ship reached a terminal outcome; the slot awaits teardown. Complete once the slot's
#              terminal is gone. -> close  (flow_phase then reports the empty phase = fully done)
#
# BEHAVIOUR-PRESERVING by construction (shipyard's observable behaviour must be identical):
#   * `_syg_concluded` reproduces shipyard-report.sh's old `completed` verdict EXACTLY —
#     forge state merged|closed OR ship stage == ready-to-merge — so the glyph does not change.
#   * a `?` (unresolvable) forge state is neither merged nor closed, so the slot stays `in-review`,
#     i.e. in flight — the documented "`?` counts as in flight, never finished" rule.
#   * `merged` while the terminal is still up lands the slot at `concluded`, which is still a
#     non-terminal phase (not the empty "torn down") — the documented "merged != the child is done;
#     the absence of a terminal is the honest end signal; teardown is the supervisor's act" rule.
#
# THE PER-SLOT FACTS. flow_phase evaluates the predicates below against four facts the caller
# resolves ONCE (shipyard-report.sh already reads each for its table, so this adds no forge call)
# and passes to `shipyard_slot_phase`. They are read from `SYG_*` variables, which are function-
# local in `shipyard_slot_phase` and reach the predicates through bash's dynamic scope (the same
# way council's predicates read the ambient room):
#   SYG_IID       the slot's PR/MR number, or empty before one is opened.
#   SYG_MR_STATE  the forge state: opened | merged | closed | ? | "no MR yet".
#   SYG_STAGE     ship's pipeline stage from its state file (impl-review / ready-to-merge / ...).
#   SYG_ADDR      the slot's terminal address, or empty once the terminal is gone.
#
# TWO WAYS THIS FILE IS USED, because report.sh must stay bash-3.2-compatible while the shared
# guard needs bash >= 5 (associative arrays):
#   * SOURCED by the tests (which re-exec into bash >= 5 first) — defines the predicates, the
#     graph, `shipyard_slot_phase` and `shipyard_slot_verdict` and returns.
#   * EXECUTED as a subprocess by shipyard-report.sh — `shipyard-slot-graph.sh slot <iid>
#     <mr_state> <stage> <addr>` prints "<phase> <verdict>". report.sh runs on stock macOS bash
#     3.2 (t7 pins that), so it never sources the guard; it spawns this, which re-execs itself into
#     a modern bash below. The subprocess is spawned only for a LIVE slot, never on the empty-report
#     path report.sh takes when there are no terminals.
#
# Source of truth for the interpreter it leans on is shared/flow/flow.sh, vendored beside this file
# as flow.sh (check 11 keeps the copy identical). This file is shipyard-local skill DATA, like
# council's lib/room-graph.sh; only the interpreter is shared.

# Re-exec into a modern bash ONLY when EXECUTED as a subprocess under an old one — never when
# sourced, where `exec` would replace the caller's (already bash >= 5) process. The shared guard
# needs associative arrays; stock macOS /bin/bash is 3.2. Same guard council.sh and the flow tests
# use, keyed on this file's own env var so a re-exec is not mistaken for a caller's.
if [ "${BASH_SOURCE[0]}" = "${0}" ] \
   && [ "${BASH_VERSINFO[0]:-0}" -lt 5 ] && [ -z "${SHIPYARD_SLOT_GRAPH_REEXEC:-}" ]; then
  for _c in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash bash; do
    _p=$(command -v "$_c" 2>/dev/null) || continue
    _v=$("$_p" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null) || continue
    [ "${_v:-0}" -ge 5 ] && exec env SHIPYARD_SLOT_GRAPH_REEXEC=1 "$_p" "$0" "$@"
  done
  echo "shipyard-slot-graph: needs bash >= 5, this one is ${BASH_VERSION:-unknown}." >&2
  echo "                     macOS ships bash 3.2 as /bin/bash; install a modern one (brew install bash)." >&2
  exit 70
fi

# shellcheck source=flow.sh
. "$(dirname "${BASH_SOURCE[0]}")/flow.sh"

# --- the mechanical predicates (FLOW-02: deterministic, model-free) -------------------------------
# Each is a boolean over the resolved per-slot facts in SYG_* — no forge call, no agent, no model.
_syg_pr_known() { [ -n "${SYG_IID:-}" ]; }

# This predicate matches shipyard-report.sh's historical `completed` condition exactly: the forge
# says merged/closed, or ship has reached its hand-off stage. `needs-human` and `done` are
# deliberately NOT here — the old code treated them as `active` (a needs-human slot still wants
# attention, and its escalation overlay shows that), and behaviour is preserved.
#
# One deliberate refinement of the FULL glyph path (not this predicate alone): `concluded` sits
# behind the `launched` node, so the `completed` verdict now also requires a known PR/MR number.
#
# THAT PRECONDITION WAS ARGUED UNREACHABLE, AND IT WAS NOT (#124). The argument ran: ship records
# the PR number when it opens the PR, well before `stage=ready-to-merge`, and slot_stage and
# slot_iid read the same state file — so a `ready-to-merge` slot always has a known iid. Both
# halves are true and the conclusion still failed, because the premise under them is that the
# state file EXISTS. Where a child never wrote one, both facts are missing together: the slot sits
# at `launched` from launch to merge, and the `completed` glyph never fires at all. The cost was
# glyph-only, as predicted (the in-flight count reads a live terminal, not this phase) — but it was
# reached, so do not read this node's ordering as free. slot_iid()'s forge fallback is what makes
# the iid arrive without the child's cooperation; the stage has no such second source.
_syg_concluded() {
  case "${SYG_MR_STATE:-}" in merged|closed) return 0 ;; esac
  [ "${SYG_STAGE:-}" = ready-to-merge ]
}

_syg_torn_down() { [ -z "${SYG_ADDR:-}" ]; }

# --- the graph, declared as data ----------------------------------------------------------------
# flow_reset first because this file may be sourced more than once in a process (a test does); the
# registry must rebuild cleanly rather than append. shipyard owns the one flow graph in its process.
shipyard_slot_graph() {
  flow_reset
  flow_node launched  --done-when 'check _syg_pr_known'  --on-done goto:in-review
  flow_node in-review --done-when 'check _syg_concluded' --on-done goto:concluded
  flow_node concluded --done-when 'check _syg_torn_down' --on-done close
}
shipyard_slot_graph

# shipyard_slot_phase <iid> <mr_state> <stage> <addr> — the slot's phase, read from the declared
# graph by the shared guard (this is where shipyard USES flow_phase): launched | in-review |
# concluded | "" (empty = torn down = fully done). The facts are function-local; bash's dynamic
# scope carries them into the predicates flow_phase evaluates (and into their `check` subshells).
shipyard_slot_phase() {
  local SYG_IID="${1:-}" SYG_MR_STATE="${2:-}" SYG_STAGE="${3:-}" SYG_ADDR="${4:-}"
  flow_phase launched
}

# shipyard_slot_verdict <phase> — the sidebar glyph verdict a phase maps to, BEFORE report.sh's
# escalation/stall overlays (those still win over this). `concluded` and the empty/`torn-down`
# terminal phase read as `completed`; every earlier phase (and any unrecognised value) as `active`,
# so an unreadable phase is never shown as falsely completed.
shipyard_slot_verdict() {
  case "${1:-}" in
    concluded|torn-down|"") printf 'completed' ;;
    *)                      printf 'active' ;;
  esac
}

# --- executed as a subprocess: the interface shipyard-report.sh calls ----------------------------
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  case "${1:-}" in
    slot)
      # <iid> <mr_state> <stage> <addr> -> "<phase> <verdict>". flow_phase's empty (fully done)
      # phase is rendered as the literal `torn-down` so report.sh can test it as a word.
      #
      # Guard that the interpreter actually loaded first: the empty -> `torn-down` mapping below
      # assumes flow_phase RAN and reported a complete graph. If flow.sh failed to source (a
      # corrupted or partial install — check 11 gates this in-repo, but a shipped copy could still be
      # incomplete), flow_phase is undefined, shipyard_slot_phase yields empty, and we would
      # otherwise emit a MISLEADING `torn-down` for a slot the interpreter never evaluated — which
      # report.sh would read as a dropped, completed slot (the catastrophic early-termination class
      # this supervision code exists to prevent). Fail loudly with EMPTY stdout instead, so
      # report.sh's fail-safe (verdict=active, still counted in flight) applies. The realistic
      # no-bash-5 failure already exits at the re-exec guard above with empty stdout; this covers
      # loaded-bash-5-but-no-flow.sh.
      command -v flow_phase >/dev/null 2>&1 || {
        echo "shipyard-slot-graph: flow.sh did not load (flow_phase undefined)" >&2
        exit 70
      }
      p=$(shipyard_slot_phase "${2:-}" "${3:-}" "${4:-}" "${5:-}")
      [ -n "$p" ] || p=torn-down
      printf '%s %s\n' "$p" "$(shipyard_slot_verdict "$p")"
      ;;
    *)
      echo "usage: shipyard-slot-graph.sh slot <iid> <mr_state> <stage> <addr>" >&2
      exit 2
      ;;
  esac
fi
