#!/usr/bin/env bash
# roster-defaults.sh — the default of each number `up` writes into roster.json. Source only.
#
# Each of these is read on two sides: `council_up` (lib/up.sh) writes it into a new room's roster
# unless the scenario's frontmatter (or `up --turns`) gives a value — `turn_deadline_ms` is never
# given one, so it is always this — and a reader in lib/lib.sh or lib/verbs.sh falls back to it
# when the roster does not carry the field as a usable integer: a room assembled by hand, one made
# by an older `up`, or one a peer has overwritten (c_int_field). Both sides used to spell the
# number themselves, with nothing keeping a pair in step (#151).
#
# A new roster number with a default goes here, and both its writer and its reader name the
# variable. tests/t13-relaunch.sh builds a room with `up` from a scenario that sets none of these
# and checks the roster carries them, that `floor` and `verdict` fall back to what `up` wrote,
# and that no c_int_field call in lib/ spells one of these three defaults as a literal.
#
# Council's own, not shared/: nothing in shipyard has a roster. It is not lib.sh because `up`
# runs before a room exists and lib.sh refuses to load without one.
C_DEF_TURNS_BUDGET=30             # turns_budget: turns a room may take before verdict says so
C_DEF_TURN_DEADLINE_MS=180000     # turn_deadline_ms: a floor holder past this may be skipped
C_DEF_ROUND_DEADLINE_MS=600000    # round_deadline_ms: the opening barrier's quorum deadline
