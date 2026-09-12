#!/usr/bin/env bash
# shipyard-backend.sh — terminal-backend abstraction for the `shipyard` skill. Source only.
#
# A child ship session lives in a terminal the parent watcher can read from and type
# into. Two backends provide that surface:
#
#   agterm (DEFAULT) — a native macOS terminal driven over a control socket by
#                      `agtermctl`. Children are SESSIONS named `ship-<slot>` inside a
#                      WORKSPACE named `<repo>-ai`.
#   tmux             — the original backend. Children are WINDOWS named `ship-<slot>`
#                      inside a session named `<repo>`.
#
# Pick one with SHIPYARD_BACKEND=agterm|tmux|auto. The default is `auto`: agterm whenever an
# agterm app is answering its control socket, else tmux, and a hard error when NEITHER
# is available — `shipyard` has no third way to reach a child. Every other script in this skill
# talks only to the shipyard_* functions below and never to agtermctl/tmux directly, so a slot
# behaves identically on both.
#
# THE BACKEND MECHANICS NO LONGER LIVE HERE. They are the one shared agent-console driver
# (shared/driver/agent-driver.sh, vendored beside this file as agent-driver.sh and kept
# byte-identical to its source by scripts/sync-driver.sh + the repo gate, check 11). What was a
# second hand-synced copy of that backend code is now a thin shipyard ADAPTER over it: this file
# maps shipyard's own knobs onto the driver's caller-set variables, keeps shipyard's `ship-<slot>`
# session-name template, and lets the shared ops (backend, container, target, launch, read, type,
# submit, kill, focus) delegate to the matching drv_* one. If a backend needs fixing, fix it in the
# shared driver; there is no longer a second copy here to keep in step.
#
# The container name is the ONE place the two backends differ, and the ONE place shipyard differs
# from council — so it is expressed entirely through the driver's caller-set vars (mapped below):
#   agterm: workspace `<parent's workspace>-ai`, falling back to `<repo>-ai`
#           (the `-ai` suffix keeps agent sessions in their own workspace, away from the
#            human's own tabs)
#   tmux:   session   `<repo>`      (unchanged, so ship windows coexist with your own)
# The agterm name is derived ONCE and then PINNED in the shipyard mailbox, because it depends on
# where the caller was sitting. Re-deriving it per call would mean a report run from a different
# workspace resolves a different container and truthfully reports that there are no children — the
# worst possible lie for a monitor.
#
# What STAYS in shipyard, because the shared driver has no twin for it: the backend precheck
# (shipyard_backend_check), the Escape key (shipyard_esc), the sidebar note / desktop notify /
# empty-workspace prune, the container kind/unpin, and the report-facing shipyard_slot_addr /
# shipyard_where / shipyard_peek_hint. Only the shared backend ops move.
#
# `shipyard_slots` was on that list until #141 gave council the same question. Its backend
# mechanics are now `drv_sessions`, and what stays here is shipyard's `ship-<slot>` template —
# the same split every other op already has, and the reason its two private helpers are gone.

# --- map shipyard's knobs onto the driver's, then source it --------------------------------
# The driver resolves and caches the backend ONCE, at source time, so DRV_BACKEND must already
# carry shipyard's choice or the cache would answer for `auto` whatever SHIPYARD_BACKEND said.
# SHIPYARD_BACKEND is process-stable, so this single mapping reproduces shipyard_backend's old
# resolve-and-cache-on-first-call exactly, including the `invalid` a bad value used to yield.
#   DRV_BACKEND          <- SHIPYARD_BACKEND (default auto).
#   DRV_CONTAINER_SUFFIX  "-ai": shipyard keeps its agent sessions in a `<workspace>-ai` container.
# DRV_REPO_KEY, DRV_CONTAINER_OVERRIDE are set just below (they need the sourced driver's resolved
# backend and shipyard's own repo-key rule); DRV_CONTAINER_PIN_DIR is set at the end of
# shipyard-lib.sh, once shipyard_mailbox is defined. None of these are exported: the old code put
# nothing of the kind into a launched child's or the tmux server's environment, and neither does
# this.
DRV_BACKEND="${SHIPYARD_BACKEND:-auto}"
DRV_CONTAINER_SUFFIX="-ai"
# shellcheck source=agent-driver.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/agent-driver.sh"

# --- naming: the repo-key rule that is shipyard's, not the driver's -------------------------
# shipyard sanitises ':' -> '_' in the stem and derives its container from a git repo — DISTINCT
# from council, which takes the driver's forgiving default (basename of the git top-level, or of
# $PWD outside a repo). shipyard injects its own DRV_REPO_KEY, which the driver reads only on the
# repo-stem fallback path (no live agterm workspace), so the ':' -> '_' transform holds wherever a
# container is actually derived (t8 asserts it). One edge is NOT reproduced exactly: outside a git
# repo the old code failed (empty + exit 1), whereas an empty DRV_REPO_KEY here lets the driver
# fall back to the pwd basename. shipyard is a per-repo tool (worktrees + a .git mailbox), so this
# surfaces only if a report is run outside every repo — cosmetically naming a pwd-based container in
# its "no live terminals" line; a same-named terminal container would then read as ship slots.
# Reproducing the failure exactly would mean re-duplicating the driver's override/pin/derive
# precedence in this adapter — the very duplication this migration removes — so it is left as is.
shipyard_repo_key() {
  local root
  root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "error: not inside a git repository — shipyard derives its container name from the repo" >&2
    return 1; }
  basename "$root" | tr ':' '_'
}
DRV_REPO_KEY=$(shipyard_repo_key 2>/dev/null) || DRV_REPO_KEY=""

# shipyard's explicit container override is backend-specific: SHIPYARD_WORKSPACE names the agterm
# workspace, SHIPYARD_SESSION the tmux session. The driver takes a single DRV_CONTAINER_OVERRIDE, so
# resolve shipyard's pair against the now-cached backend and hand the driver the one that applies.
# Both are process-stable env vars, exactly as the old shipyard_container read them.
case "$(drv_backend)" in
  agterm) DRV_CONTAINER_OVERRIDE="${SHIPYARD_WORKSPACE:-}" ;;
  tmux)   DRV_CONTAINER_OVERRIDE="${SHIPYARD_SESSION:-}" ;;
esac

# --- backend + container: thin delegations to the shared driver -----------------------------
shipyard_backend() { drv_backend; }
shipyard_shq()     { drv_shq "$1"; }

# The container keeps shipyard's cross-process cache: _SHIPYARD_CONTAINER is resolved once in the
# main shell (end of shipyard-lib.sh, after the mailbox is defined) and every $(shipyard_container)
# fork inherits it, so a hot report loop neither re-reads the pin file nor re-queries agterm. With
# no cache the delegation is the driver's own resolve (override -> pin -> derive), in that order.
shipyard_container() {
  [ -n "${_SHIPYARD_CONTAINER:-}" ] && { printf '%s' "$_SHIPYARD_CONTAINER"; return 0; }
  drv_container
}
shipyard_container_pin() { drv_container_pin; }

# The refusal shipyard's own surface shares (the delegating ops get the driver's equivalent). Its
# message names SHIPYARD_BACKEND and the agterm/tmux install steps, so an unusable backend can never
# read as a no-op. Re-resolve rather than reading $_DRV_BE: every dispatch reaches us from inside a
# `case "$(shipyard_backend)"`, i.e. a SUBSHELL, so an assignment there never reached this shell.
_shipyard_no_backend() {
  if [ "$(shipyard_backend)" = invalid ]; then
    echo "error: SHIPYARD_BACKEND must be agterm, tmux or auto (got: ${SHIPYARD_BACKEND:-})" >&2
  else
    echo "error: no terminal backend available — shipyard cannot reach a child session." >&2
    echo "       agterm: install agtermctl (agterm ▸ Help ▸ Install Command Line Tool…) and start the app;" >&2
    echo "       tmux:   brew install tmux, then run with SHIPYARD_BACKEND=tmux." >&2
  fi
  return 1
}

# Fail early and loudly rather than at the first weird empty capture. No driver twin: the driver has
# no precheck of its own, so this stays shipyard's, with shipyard's own remediation text and jq need.
shipyard_backend_check() {
  case "$(shipyard_backend)" in
    agterm)
      command -v agtermctl >/dev/null 2>&1 || {
        echo "error: agtermctl is not on PATH (agterm ▸ Help ▸ Install Command Line Tool…)" >&2
        echo "       or run with SHIPYARD_BACKEND=tmux" >&2; return 1; }
      agtermctl version >/dev/null 2>&1 || {
        echo "error: no agterm is answering the control socket (${AGTERM_SOCKET:-default})" >&2
        echo "       start agterm, or run with SHIPYARD_BACKEND=tmux" >&2; return 1; }
      command -v jq >/dev/null 2>&1 || { echo "error: the agterm backend needs jq" >&2; return 1; } ;;
    tmux)
      command -v tmux >/dev/null 2>&1 || { echo "error: tmux is not on PATH" >&2; return 1; } ;;
    *) _shipyard_no_backend; return 1 ;;
  esac
}

# shipyard_container_unpin — forget the pinned name, so the next launch derives a fresh one. Only
# correct once nothing is left in the old container, which is why shipyard-down.sh calls it solely
# after `shipyard_continuity_cleanup_last_slot` has PROVEN the fleet empty.
#
# IT CLEARS ONLY THE RESOLVED BACKEND'S PIN, which is the rule that was already here, and the
# reuse of `_drv_pin_file` that goes with it: unpin removes exactly what `drv_container_pin` wrote.
#
# That is worth a note because this change spent two review rounds getting back to it. Reading the
# pin's NAME as evidence (shipyard_backend_pinned_elsewhere, below) made a leftover pin look like
# litter worth sweeping, so unpin was widened to clear every backend's. It was wrong twice, in the
# same direction both times:
#   * resolved tmux, pinned agterm — the extra removal deletes the evidence the report reads, so
#     the next blip exits 0 over live children. #61, reintroduced by its own fix.
#   * resolved tmux, BOTH pinned — patched with an early return when the pins disagree, which does
#     not fire here (tmux IS pinned). The justification written for it was circular: the agterm pin
#     is invisible to the disagreement check only BECAUSE the tmux pin sits beside it, and this very
#     call is about to delete that one. Afterwards the leftover is exactly what the check reads.
#
# The rule that covers all three configurations without a guard is the original one: the caller
# proved that the backend it RESOLVED holds no slots and learned nothing about the other, so clear
# that one and leave the other alone. A pin whose fleet ended some other way does outlive it — and
# that is fail-CLOSED (a refusal that names itself and says what to run), which is the direction to
# be wrong in.
shipyard_container_unpin() {
  local f; f=$(_drv_pin_file 2>/dev/null) && rm -f "$f" 2>/dev/null
  return 0
}

# What kind of thing that container is, for messages. No driver twin.
shipyard_container_kind() {
  case "$(shipyard_backend)" in
    agterm) printf 'workspace' ;;
    tmux)   printf 'session' ;;
    *) _shipyard_no_backend; return 1 ;;
  esac
}

# --- the API every other script uses -------------------------------------------
# The shared ops delegate; the session-name template `ship-<slot>` is resolved here and handed to
# the driver, which re-derives the opaque backend handle from it on every call.

# shipyard_target <slot> — opaque handle for the backend; exit 1 when the slot has no live
# terminal. agterm: the session UUID. tmux: `<session>:<index>`.
shipyard_target()  { drv_target "ship-$1"; }

# shipyard_capture <slot> — the child's visible screen as plain text.
shipyard_capture() { drv_read "ship-$1"; }

# shipyard_type <slot> <text> — inject text as keystrokes WITHOUT submitting.
shipyard_type()    { drv_tell "ship-$1" "$2"; }

# shipyard_submit <slot> [alt] — press Return. `alt` asks for the keypad Return, which some
# Claude Code builds want instead; agterm delivers a real newline either way.
shipyard_submit()  { drv_submit "ship-$1" "${2:-}"; }

# shipyard_launch <slot> <cwd> <launcher-script> — start a child terminal running the launcher.
# drv_launch echoes the session name on success; shipyard_launch never wrote to stdout and its
# caller runs it uncaptured, so swallow that echo while preserving the exit status it branches on.
shipyard_launch()  { drv_launch "ship-$1" "$2" "$3" >/dev/null; }

# shipyard_kill <slot> — tear the child's terminal down (teardown after a merge).
shipyard_kill()    { drv_kill "ship-$1"; }

# shipyard_focus <slot> — put the human on that child.
shipyard_focus()   { drv_focus "ship-$1"; }

# shipyard_slot_addr <slot> — the SHORT column value for the report ("win" on tmux, the
# session-id prefix on agterm). Empty + exit 1 when the slot has no terminal ON THE BACKEND THIS
# RUN RESOLVED, which is not the same fact as the child being gone — `shipyard_absence_report`
# tells the two apart, and `shipyard-tell.sh` and `shipyard-compact.sh` ask it before they say
# anything to a human.
#
# THEY ARE NOT THE ONLY CALLERS THAT SPEAK. `shipyard-down.sh` renders this failure as `gone` in
# its `--list` TERMINAL column, and on the teardown path skips the kill and removes the worktree
# anyway; it asks nothing. That is the remaining instance in this skill, out of scope here and
# filed on its own — named for the same reason the admission-gate caller is named below, so a
# later reader does not take this paragraph as a claim that the sweep is finished. No driver twin.
shipyard_slot_addr() {
  local t; t=$(shipyard_target "$1") || return 1
  case "$(shipyard_backend)" in
    agterm) printf '%s' "$(printf '%s' "$t" | cut -c1-8 | tr '[:upper:]' '[:lower:]')" ;;
    tmux)   printf '%s' "${t##*:}" ;;
    *) _shipyard_no_backend; return 1 ;;
  esac
}

# shipyard_where <slot> — human-readable location, for log lines and errors. No driver twin.
shipyard_where() {
  local t
  if ! t=$(shipyard_target "$1"); then printf '%s/ship-%s (no live terminal)' "$(shipyard_container)" "$1"; return 1; fi
  case "$(shipyard_backend)" in
    agterm) printf '%s/ship-%s' "$(shipyard_container)" "$1" ;;
    tmux)   printf '%s' "$t" ;;
    *) _shipyard_no_backend; return 1 ;;
  esac
}

# shipyard_peek_hint <slot> — a command the human can paste to look inside the child. No driver twin.
shipyard_peek_hint() {
  local t; t=$(shipyard_target "$1") || { printf 'no live terminal for ship-%s' "$1"; return 1; }
  case "$(shipyard_backend)" in
    agterm) printf "agtermctl session text --target %s --lines 20" "$t" ;;
    tmux)   printf "tmux capture-pane -t '%s' -p | tail -20" "$t" ;;
    *) _shipyard_no_backend; return 1 ;;
  esac
}

# shipyard_slots — every slot that currently has a terminal. The enumeration itself is the
# driver's `drv_sessions`; what is shipyard's, and what stays here, is the `ship-<slot>` template
# it filters by.
#
# THE EXIT STATUS IS PART OF THE CONTRACT, and it carries the one distinction this change is about:
# rc 0 means the container ANSWERED (its slot list follows, possibly empty), non-zero means it did
# not answer at all. `shipyard-down.sh` consults it today — it refuses to drop the container pin on
# anything but a proven-empty fleet — and `shipyard-report.sh` now does too. ("Today", not "always":
# the original down.sh unpinned on `[ -z "$(shipyard_slots)" ]`, i.e. read a failed enumeration as
# empty, and the proof-of-empty gate arrived later with shipyard_continuity_cleanup_last_slot.)
#
# THE THIRD CALLER STILL DISCARDS IT. `shipyard_admission_slot_count` pipes this function into
# `wc -l`, so a socket that answers `version` and fails `tree` reads as zero live slots and the
# SHIPYARD_MAX_SLOTS cap is silently bypassed — the same defect one gate over. That is out of this
# change's scope and filed separately; it is named here so the next reader does not infer from the
# paragraph above that every caller now branches on the status.
#
# The agterm arm used to be a bare pipeline, so its status was `sed`'s, which is 0 whether or not
# anything upstream survived. It happened to work because both callers that CONSULT the status set
# `pipefail`: an ambient option in the caller decided whether a failed enumeration was
# distinguishable from an empty container. Capture it explicitly instead, so no later caller
# inherits the wrong answer by forgetting an option it never knew it needed.
#
# THE BACKEND MECHANICS ARE NO LONGER HERE. Both arms moved into `drv_sessions` in shared/driver
# when `council say` became a second caller that had to tell an empty container from an
# unanswered one (#141); what stays is shipyard's own `ship-<slot>` template, which is the half
# the driver deliberately does not know. The status contract above is `drv_sessions`' now and is
# passed through unchanged.
shipyard_slots() {
  local raw rc=0
  # The unusable-backend arm is answered HERE rather than let through to the driver's, purely so
  # the operator keeps reading about `SHIPYARD_BACKEND` and shipyard's own install hints. The
  # driver would refuse just as correctly, in the driver's words.
  case "$(shipyard_backend)" in
    agterm|tmux) ;;
    *) _shipyard_no_backend; return 1 ;;
  esac
  # THE CONTAINER IS PASSED, NOT LEFT TO THE DRIVER. `drv_sessions` would resolve it through
  # `drv_container`, which knows nothing of shipyard's `_SHIPYARD_CONTAINER` memo — so the
  # enumeration would ask about a name that every other shipyard verb, including the diagnostic
  # that reports its result, resolves differently. The deleted arms both asked
  # `$(shipyard_container)`; this keeps that exactly. It also keeps the memo's whole point: without
  # it the report's poll loop re-reads the pin file every tick, and on an unpinned agterm fleet
  # re-queries `agtermctl tree` — where a single blipped workspace lookup makes the derivation fall
  # back to the repo stem, and the backend then answers rc 0 about a workspace that is not the
  # fleet's. That answer is corroborated by construction, so no classifier can catch it.
  raw=$(drv_sessions "$(shipyard_container)") || rc=$?
  [ "$rc" = 0 ] || return 1
  printf '%s\n' "$raw" | sed -n -E 's/^ship-(.+)$/\1/p'
}

# shipyard_backend_pinned_elsewhere — echoes the backend(s) this fleet was actually launched on,
# and returns 0 ONLY when a pin exists and NONE of them is the backend this process resolved.
#
# There is no separate backend pin file to maintain. The driver's container pin is already named
# `container-<backend>`, so the set of pin files present IS the record of which backends this
# mailbox has launched a fleet on. Reading that name keeps one fact in one place.
#
# THE SEAM THIS USED TO NAME IS NOW CLOSED. This function spelled `container-<b>` itself, which
# duplicated a template the driver owns — so a rename there would have made it read nothing and
# fail OPEN, silently, back to the incident. It named `drv_pins_present` in shared/driver as the
# right home and deferred on the explicit grounds that council had no empty-answer conclusion to
# protect, with the trigger "Move it the moment that stops being true". #141 is that moment:
# `council say` refuses a peer with a confident negative drawn from the same unanswerable
# question. The implementation is `drv_pins_elsewhere` in shared/driver, vendored into both
# plugins; this stays as shipyard's NAME for it, because a released surface with four call sites
# is worth a one-line seam and because the answer it gives is unchanged.
#
# WHY IT MATTERS. `SHIPYARD_BACKEND=auto` decides per PROCESS by probing the agterm control socket,
# so a socket that blips for one tick resolves tmux for that tick — and a tmux session named after
# the repo holds no ship windows, correctly and uselessly. Nothing is wrong with either answer;
# what was wrong was reading "I looked somewhere else and found nothing" as "there is nothing".
shipyard_backend_pinned_elsewhere() { drv_pins_elsewhere; }

# shipyard_signal_class [<enum-rc> [<enum-output> <slot-session-name>]] — MAY AN ABSENCE BE
# BELIEVED?
#
# Echoes "<class><TAB><why>" and returns 1 when it may not: the question was not answered, so any
# negative drawn from it would be a guess. Echoes nothing and returns 0 when it may.
#
#   unreachable  the backend did not answer when asked which terminals exist.
#   elsewhere    it answered, but this fleet was launched on a DIFFERENT backend (the pin says so).
#   listed       it answered AND still lists this very slot, so it is the per-slot lookup that
#                failed, not the child that ended. Needs the last two arguments; a caller that
#                passes only a status can never get this class.
#
# THE LAST TWO ARGUMENTS SHARE A NAMESPACE AND NOTHING CHECKS IT. `<enum-output>` and
# `<slot-session-name>` are compared for exact equality, so they must be spelled the same way.
# `shipyard_absence_report` passes FULL session names on both sides (`drv_sessions`' output and
# `ship-<slot>`); a caller holding bare slots from `shipyard_slots` must pass a bare slot as the
# name. Mixing the two matches nothing and turns the arm off silently, which is the failure mode
# this paragraph exists to prevent — there is no assertion that would catch it.
#
# The verdict itself is `drv_absence_class` in shared/driver, and this is shipyard's name for it.
# What stays HERE is the one thing the driver must not do: supply the enumeration. Both facts it
# rests on are the driver's own — `drv_sessions`' exit status and the container pin's name — but
# WHICH enumeration a caller's answer came from is the caller's knowledge, so the probe below is
# shipyard's and the driver never re-probes. `council say` is the second caller; two answers to
# one question is the defect AGENTS.md says the shared engine exists to remove.
#
# WHY THE STATUS IS A PARAMETER. A caller that has already enumerated must classify the status of
# the list it ACTED ON, not of a second enumeration that could disagree with it, so it captures
# the rc once and passes it in. Who actually does what, rather than an absolute: `shipyard-report.sh`
# passes a status alone (it classifies the list it PRINTED); `shipyard_absence_report` passes all
# three (it needs the list for the `listed` arm anyway). `shipyard-tell.sh` and
# `shipyard-compact.sh` reach this only THROUGH `shipyard_absence_report`, so they pass three too.
#
# So NO caller uses the argument-less mode today. It is kept as a fail-closed default, not for a
# caller: the driver treats an EMPTY status as `unreachable`, so a status-less call there would
# refuse everything, and probing here is the honest answer for a caller that genuinely holds no
# list. Stated plainly because an earlier version of this paragraph named tell and compact as its
# users, which would have invited a later agent to add a bare call in exactly the two scripts that
# already hold a list — reintroducing the disagreement the parameter exists to prevent.
#
# THE DUPLICATION, RESTATED AGAINST THE TREE AS IT IS. `shipyard-report.sh` used to carry its own
# `fleet_signal`; #137 deleted it, and both of that file's call sites now come here (its own line
# 156 records the deletion). What survives there is narrower: an open-coded per-slot "still listed"
# contradiction check, which is exactly this function's `listed` arm spelled a second time — and it
# labels that verdict `unreachable`, so the operator is sent to check a socket that demonstrably
# answered. Folding it in is not a one-line swap, because that loop matches BARE slots and this
# function's callers here pass full session names (see the namespace note above), so it is filed
# rather than done here.
#
# NOT USED AS EVIDENCE: the slot's worktree. A worktree outlives its terminal by design — that is
# the state of every child whose terminal was killed but not torn down — so reading its presence as
# "the child may still be alive" would raise the alarm on the commonest healthy case, which
# AGENTS.md names as costing more than the bug it guards. The per-slot launch record that WOULD
# carry that evidence belongs with the pin-staleness work, filed separately.
#
# AND WHY IT RE-SPELLS TWO OF THE SENTENCES. The CLASS is decided once, in the driver; the WHY is
# operator-facing prose in this skill's own vocabulary — a fleet, a slot, a child — which the
# driver cannot speak without being told, and council must not inherit. `shipyard-report.sh`
# renders this `why` verbatim inside its `🛑 NO SIGNAL` block, so the wording is a released
# surface with a test on it, not an internal detail. Overriding it here keeps the decision in one
# place and the words where they belong; the `unreachable` sentence needs no override because it
# names only the backend, which both skills say the same way.
shipyard_signal_class() {
  local rc="${1:-}" list="${2:-}" name="${3:-}" sig crc=0 TAB
  TAB=$(printf '\t')
  if [ -z "$rc" ]; then rc=0; shipyard_slots >/dev/null 2>&1 || rc=$?; fi
  sig=$(drv_absence_class "$rc" "$list" "$name") || crc=$?
  case "${sig%%"$TAB"*}" in
    # Re-asked rather than parsed back out of the driver's sentence, for the reason the
    # `elsewhere` remedy in `shipyard_absence_report` already gives: reading two file names again
    # costs nothing, and recovering a value from prose couples this to that sentence's wording.
    elsewhere) sig="elsewhere${TAB}this run resolved $(shipyard_backend), but this fleet was launched on $(shipyard_backend_pinned_elsewhere)" ;;
    listed)    sig="listed${TAB}the $(shipyard_backend) backend answered and still lists $name, so it is the per-slot lookup that failed, not the child that ended" ;;
  esac
  printf '%s' "$sig"
  return "$crc"
}

# shipyard_absence_report <slot> — say, on stderr, why that slot has no terminal.
#
# Returns 0 when the absence is CORROBORATED (the backend answered and does not have it — the
# child really is gone) and 1 when it is UNRESOLVED. Callers map that onto their own exit codes;
# it is one function rather than a paragraph in each script so the two cannot drift apart.
#
# THE DEFECT IT CLOSES. `shipyard_target` resolves against whatever backend THIS process picked,
# and `SHIPYARD_BACKEND=auto` picks per process by probing the agterm control socket. During a blip
# the honest answer is "no terminal on the backend I resolved", not "the child is gone" — and the
# supervising agent acts on what it is told, so the reasonable next moves after "gone" are to tear
# the slot down or relaunch it, against a child that is mid-review and alive in the other backend.
# An unanswerable question must never produce a confident negative.
shipyard_absence_report() {
  local slot="$1" list sig class why pin rc=0 erc=0 TAB
  TAB=$(printf '\t')
  # ONE enumeration, and KEEP ITS ANSWER — not just its status. The status alone cannot see the
  # narrowest blip, and that blip is the one that ends in a teardown: `drv_target` makes its OWN
  # backend call (tmux asks for `#{window_index} #{window_name}`, `drv_sessions` for
  # `#{window_name}`; agterm reads the tree twice), and it swallows stderr and status, so a
  # transient failure there is indistinguishable from "not found". If THAT call blips while the
  # enumeration answers, both facts below agree and a slot the backend has just listed is called
  # gone. `shipyard-report.sh` guards the same contradiction one level up — "the only honest
  # reading of 'still enumerated, but I rendered it gone' is that the lookup failed" — and its
  # `blip` fixture exists because that shape happened. This is the per-slot form of it, and it is
  # the classifier's `listed` arm rather than a loop here, so the two cannot drift.
  #
  # Enumerated through `drv_sessions` and not `shipyard_slots` because the comparison wants the
  # FULL session name: `shipyard_slots` strips the `ship-` prefix, and the diagnostic names the
  # terminal the operator would go and look at. The container is passed for the reason
  # `shipyard_slots` gives — the message below names `$(shipyard_container)`, so the enumeration
  # must have asked about that same container or the two sentences are about different places.
  list=$(drv_sessions "$(shipyard_container)" 2>/dev/null) || erc=$?
  sig=$(shipyard_signal_class "$erc" "$list" "ship-$slot") || rc=$?
  if [ "$rc" = 0 ]; then
    echo "error: no live terminal \`ship-$slot\` in $(shipyard_container_kind) \`$(shipyard_container)\`." >&2
    echo "       the $(shipyard_backend) backend answered and does not have it, so the child is gone." >&2
    return 0
  fi
  class=${sig%%$TAB*}; why=${sig#*$TAB}
  echo "error: cannot tell whether \`ship-$slot\` is alive, so nothing was sent." >&2
  echo "       $why." >&2
  echo "       Not finding its terminal is therefore not the same as finding it is gone: do NOT tear" >&2
  echo "       this slot down or relaunch it on this answer. The report's \`🛑 NO SIGNAL\` block" >&2
  echo "       refuses the same inference one level up, and means the same thing here." >&2
  case "$class" in
    unreachable)
      echo "       If the backend is simply down, start it and re-run; nothing was lost." >&2
      echo "         agterm: check the app is running and answering \`agtermctl version\`." >&2
      echo "         tmux:   check \`tmux ls\`." >&2 ;;
    elsewhere)
      # Asked a second time rather than parsed back out of the message above: re-reading two file names costs
      # nothing, and recovering a value from prose couples this arm to that sentence's wording.
      pin=$(shipyard_backend_pinned_elsewhere) || pin=""
      echo "       \`SHIPYARD_BACKEND=auto\` decides per PROCESS, so one failed socket probe sends this" >&2
      echo "       run to the other backend, where this repo's container is empty for entirely" >&2
      echo "       correct reasons." >&2
      [ -n "$pin" ] && echo "       Pin it for this shell and re-run: SHIPYARD_BACKEND=$pin" >&2 ;;
    listed)
      # No peek hint here: shipyard_peek_hint resolves through the very lookup that just failed, so
      # it would print its own "no live terminal" refusal instead of a command to paste.
      echo "       A transient lookup failure is the likeliest cause, so re-run — it usually goes" >&2
      echo "       through. If it keeps failing, open the terminal by hand before concluding" >&2
      echo "       anything: the backend says the slot is there." >&2 ;;
  esac
  return 1
}

# shipyard_esc <slot> — Escape, i.e. CLEAR the input box. Never send this mid-turn: Escape
# is INTERRUPT while Claude Code is working. No driver twin.
shipyard_esc() {
  local t; t=$(shipyard_target "$1") || return 1
  case "$(shipyard_backend)" in
    agterm) printf '\033' | agtermctl session type --stdin --target "$t" >/dev/null 2>&1 ;;
    tmux)   tmux send-keys -t "$t" Escape 2>/dev/null ;;
    *) _shipyard_no_backend; return 1 ;;
  esac
}

# shipyard_note <slot> <idle|active|completed|blocked> [--blink] — paint the child's state on
# the sidebar so the board is readable without the report. agterm only; a no-op on tmux,
# which has nowhere to put it. No driver twin.
shipyard_note() {
  [ "$(shipyard_backend)" = agterm ] || return 0
  local t; t=$(shipyard_target "$1") || return 1
  shift
  agtermctl session status "$@" --target "$t" >/dev/null 2>&1 || true
}

# shipyard_container_prune — drop the container once it holds no ship terminals, so a repo
# that has finished all its work stops showing an empty `<repo>-ai` workspace. Only
# ever removes an EMPTY one, so a human tab parked in there keeps it alive. No driver twin.
shipyard_container_prune() {
  case "$(shipyard_backend)" in
    agterm)
      local n ws
      n=$(agtermctl tree --json 2>/dev/null | jq -r --arg ws "$(shipyard_container)" \
            '[.result.tree.workspaces[]? | select(.name==$ws) | .sessions[]?] | length' 2>/dev/null)
      [ "${n:-1}" = 0 ] || return 0
      ws=$(agtermctl tree --json 2>/dev/null | jq -r --arg ws "$(shipyard_container)" \
            '.result.tree.workspaces[]? | select(.name==$ws) | .id' 2>/dev/null | head -1)
      [ -n "$ws" ] || return 0
      agtermctl workspace delete --target "$ws" >/dev/null 2>&1 || true ;;
    tmux)
      # A tmux session is shared with the human's own windows, so it is never
      # pruned from here — tmux kills an empty session by itself anyway.
      return 0 ;;
    *) _shipyard_no_backend; return 1 ;;
  esac
}

# shipyard_notify <slot> <body> [title] — desktop notification attributed to the child. No driver
# twin.
shipyard_notify() {
  [ "$(shipyard_backend)" = agterm ] || return 0
  local t; t=$(shipyard_target "$1") || return 1
  agtermctl notify "$2" --title "${3:-ship}" --target "$t" >/dev/null 2>&1 || true
}
