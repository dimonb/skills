#!/usr/bin/env bash
# shipyard-admission.sh — the pre-launch admission gate. Source only, never execute.
#
# WHY THIS EXISTS. A parallel shipyard run with no cap once drove a 16 GB machine to a load
# in the 30s with under 2% free RAM; macOS recycled WindowServer and tore down the whole GUI
# login session (every terminal, every app), and the supervisor then relaunched the fleet and
# fed the loop. The root cause was structural: shipyard-launch.sh started one terminal + one
# git worktree per invocation with NO admission check — nothing ever asked whether the machine
# could take another agent. This file is that check.
#
# WHAT IT IS, AND IS NOT. It is a synchronous gate in the existing launch path — two cheap
# reads and a decision, evaluated once per launch, BEFORE any worktree or terminal is created.
# It is deliberately NOT a scheduler, a queue, or a state store: there is no daemon, nothing
# persisted, and no coordination between concurrent launches beyond each counting the slots
# that already exist. It is the pragmatic "stop the bleeding" fix, not the larger coordinator.
#
# TWO GATES, each with its own exit code so the caller (and the operator) can tell them apart:
#   * concurrency cap    — SHIPYARD_MAX_SLOTS live ship-* slots already running -> refuse (4)
#   * memory-pressure    — free memory below SHIPYARD_MEM_MIN_FREE_PCT percent  -> refuse (5)
# and the cap's own failure — the live slots could not be counted at all          -> refuse (6)
# Both defaults are conservative and DOCUMENTED, and both are env-overridable (rule zero: a
# knob, never a hardcoded machine-specific value). The cap defaults small because that is what
# a ~16 GB machine safely sustains; raise it on a bigger box.
#
# WHERE IT READS PATH. Unlike shipyard-lib.sh, this file does NOT prepend the standard PATH —
# it only defines functions. That is what lets the test suite (t9) fake `memory_pressure` and
# the terminal backend on PATH and have those fakes stay authoritative, exactly as t8 does for
# the backend adapter. The real launch reaches this through shipyard-lib.sh, which has already
# prepended the system locations, so the real `memory_pressure` resolves there.
#
# NON-macOS. The memory gate has no portable equivalent, so where `memory_pressure` is not
# present (or produces no reading) it DEGRADES TO A NO-OP — the launch is admitted, never hard
# -failed on a platform where the detector cannot run. The concurrency cap is platform-neutral
# and always applies.

# _shipyard_admission_uint <value> <default> — the value when it is a short run of digits, else
# the default. The knobs feed integer `[ -ge ]`/`[ -lt ]` tests, which ERROR on a non-integer
# operand; an `if` reads that error as false, so an unvalidated bad knob would make the gate FAIL
# OPEN — the one outcome a crash-prevention gate must never have — and leak a raw `integer
# expected` to stderr. So an unusable override ALWAYS falls back to the documented default rather
# than silently disabling the gate. "Unusable" is empty, any non-digit (a typo, a stray space,
# `two`, a negative), AND an absurdly long digit run: a value that overflows the `[ ]` test
# (>= ~19 digits) would itself error and fail open, and no legitimate cap or percentage is
# anywhere near 10 digits — so 10+ digits is capped back to the default too.
_shipyard_admission_uint() {
  case "$1" in
    ''|*[!0-9]*) printf '%s' "$2"; return ;;
  esac
  if [ "${#1}" -le 9 ]; then printf '%s' "$1"; else printf '%s' "$2"; fi
}

# shipyard_admission_cap — the effective concurrency cap (live ship-* slots allowed).
# Small by default, sized for ~16 GB; override with SHIPYARD_MAX_SLOTS.
shipyard_admission_cap() { _shipyard_admission_uint "${SHIPYARD_MAX_SLOTS:-}" 2; }

# shipyard_admission_min_free_pct — the effective free-memory floor, as a whole percent.
# A launch is refused when the system has less than this fraction of memory free.
shipyard_admission_min_free_pct() { _shipyard_admission_uint "${SHIPYARD_MEM_MIN_FREE_PCT:-}" 10; }

# shipyard_admission_slot_count — how many ship-* slots currently have a live terminal.
# Reuses the backend's own enumeration (shipyard_slots), so the count means exactly what the
# report and the dedup mean by a slot. Prints a non-negative integer and exits 0 when the count
# can be believed.
#
# WHEN IT CANNOT, it prints `shipyard_signal_class`'s "<class><TAB><why>" instead and exits 1: the
# backend did not answer the enumeration (`unreachable`), or it answered about a different backend
# from the one this fleet was launched on (`elsewhere`). Either way an empty list is not an empty
# fleet, and reading it as zero is how the cap used to be bypassed at the moment the machine was
# least healthy (#131). The status of the enumeration is captured BEFORE counting — a pipe into
# `wc -l` reports `wc`'s status, which is 0 whatever happened upstream — and the list classified is
# the list counted, never a second enumeration that could disagree with it.
shipyard_admission_slot_count() {
  local out rc=0 sig
  out=$(shipyard_slots 2>/dev/null) || rc=$?
  sig=$(shipyard_signal_class "$rc") || { printf '%s' "$sig"; return 1; }
  printf '%s\n' "$out" | sed '/^[[:space:]]*$/d' | wc -l | tr -d '[:space:]'
}

# shipyard_admission_mem_free_pct — the system-wide free-memory percentage as a whole number,
# read from macOS `memory_pressure`. This is NOT raw free pages: `memory_pressure` reports the
# reclaimable free fraction, which is the figure that actually tracks pressure on macOS. Exits
# non-zero (printing nothing) when the detector is absent or its output cannot be parsed — the
# caller reads that as "gate unavailable", never as "0% free".
#
# `memory_pressure` is invoked with NO options: bare, it prints statistics and is read-only.
# The options that would SIMULATE pressure (-l/-p/-P/-s) are never passed.
shipyard_admission_mem_free_pct() {
  command -v memory_pressure >/dev/null 2>&1 || return 1
  local out pct
  out=$(memory_pressure 2>/dev/null) || return 1
  pct=$(printf '%s\n' "$out" \
    | sed -n 's/.*free percentage: *\([0-9][0-9]*\).*/\1/p' | head -1)
  [ -n "$pct" ] || return 1
  printf '%s' "$pct"
}

# shipyard_admission_report — evaluate both gates, print a one-decision human-readable report
# to stdout, and return the verdict:
#   0  admit
#   4  refuse: concurrency cap reached
#   5  refuse: memory pressure
#   6  refuse: the live slots could not be counted, so the concurrency cap cannot be applied
# The report is what the caller shows in a dry run and, on a real refusal, prints to stderr. A
# refusal is ACTIONABLE by contract: it names which gate blocked, the current value versus the
# limit, and how to override the gate or what to wait for.
#
# Exit 6 is a refusal and not a degradation, unlike the memory gate's missing detector: that one is
# a platform that has no reading at all, while this is a backend that exists and did not answer.
# SHIPYARD_MAX_SLOTS does not override it, because there is no count to compare the cap with.
shipyard_admission_report() {
  local cap count floor pct TAB
  TAB=$(printf '\t')
  cap=$(shipyard_admission_cap)
  floor=$(shipyard_admission_min_free_pct)

  if ! count=$(shipyard_admission_slot_count); then
    printf 'admission: REFUSED (slot count unavailable) — %s.\n' "${count#*"$TAB"}"
    case "${count%%"$TAB"*}" in
      elsewhere)
        printf '  SHIPYARD_BACKEND=auto decides per process; pin the fleet'"'"'s backend for this launch: SHIPYARD_BACKEND=%s.\n' \
          "$(shipyard_backend_pinned_elsewhere)" ;;
      *)
        printf '  Start the terminal backend (agterm: `agtermctl version` answers; tmux: `tmux ls`) and re-run.\n' ;;
    esac
    return 6
  fi

  if [ "${count:-0}" -ge "${cap:-0}" ]; then
    printf 'admission: REFUSED (concurrency cap) — %s live ship-* slot(s), cap SHIPYARD_MAX_SLOTS=%s.\n' "$count" "$cap"
    printf '  Wait for a slot to finish, or raise the cap for this launch: SHIPYARD_MAX_SLOTS=<n>.\n'
    return 4
  fi

  if pct=$(shipyard_admission_mem_free_pct); then
    if [ "$pct" -lt "$floor" ]; then
      printf 'admission: REFUSED (memory pressure) — %s%% memory free, below SHIPYARD_MEM_MIN_FREE_PCT=%s%%.\n' "$pct" "$floor"
      printf '  Free memory (close apps, or let running agents finish), or lower the floor: SHIPYARD_MEM_MIN_FREE_PCT=<pct>.\n'
      return 5
    fi
    printf 'admission: OK — slots %s/%s, memory %s%% free (floor %s%%).\n' "$count" "$cap" "$pct" "$floor"
    return 0
  fi

  printf 'admission: OK — slots %s/%s, memory gate unavailable (no memory_pressure reading; skipped).\n' "$count" "$cap"
  return 0
}
