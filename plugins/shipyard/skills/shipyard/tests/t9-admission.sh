#!/usr/bin/env bash
# t9 — the pre-launch admission gate (shipyard-admission.sh): concurrency cap + macOS
# memory-pressure. This is the test the desktop-recycle issue asked for: it covers the CAP
# decision and the MEMORY-GATE decision with the detector faked (no real pressure needed),
# analogous to t8's faked backend.
#
# WHAT IS NOT COVERED, so a green run is never read as more than it is: no test DRIVES
# shipyard-launch.sh, so the gate's runtime effect in the launcher (that it really exits 4/5 on a
# refusal, that SHIPYARD_DRY really prints the decision and still exits 0) is not exercised end to
# end. Section 7 guards the WIRE statically instead — the report is evaluated, the enforcing exit
# exists, and it precedes worktree/terminal creation — mirroring how t7 guards its own wire in the
# same file. That catches the silent-removal mutation; it does not replace an integration test.
#
# Everything is a PURE read over environment variables and three faked CLIs (git, agtermctl,
# memory_pressure) FIRST on PATH — NO live terminal, no real repo, no network, and crucially no
# dependence on the machine's real memory state. The gate counts slots through the backend's own
# shipyard_slots, so each case sources shipyard-backend.sh (for that enumeration) and then
# shipyard-admission.sh in its own subshell with the environment it is asserting. Neither file
# prepends PATH (only shipyard-lib.sh does), so the fakes stay authoritative.
#
# shipyard-backend.sh sources the shared driver, whose baseline interpreter is bash >= 5, so
# re-exec into one if a stock bash 3.2 started us — the same guard t8 uses — or a bash-5-only
# construct in the driver would surface here as a confusing syntax error.
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ] && [ -z "${T9_BASH_REEXEC:-}" ]; then
  for _c in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash bash; do
    _p=$(command -v "$_c" 2>/dev/null) || continue
    _v=$("$_p" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null) || continue
    [ "${_v:-0}" -ge 5 ] && exec env T9_BASH_REEXEC=1 "$_p" "$0" "$@"
  done
  echo "t9: needs bash >= 5, this one is ${BASH_VERSION:-unknown}." >&2
  exit 70
fi

set -uo pipefail
export LC_ALL=C
# A live agterm workspace would make container derivation query a socket; unset it so every case
# takes the deterministic repo-stem fallback, exactly as t8 does.
unset AGTERM_WORKSPACE_ID AGTERM_WINDOW_ID
# The gate reads these; a value inherited from the surrounding shell would skew the defaults it is
# asserting. Per-case exports set them where a case needs them.
unset SHIPYARD_MAX_SLOTS SHIPYARD_MEM_MIN_FREE_PCT

SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BACKEND="$SKILL/shipyard-backend.sh"
ADMISSION="$SKILL/shipyard-admission.sh"
[ -f "$BACKEND" ]   || { echo "t9: cannot find shipyard-backend.sh at $BACKEND" >&2; exit 1; }
[ -f "$ADMISSION" ] || { echo "t9: cannot find shipyard-admission.sh at $ADMISSION" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/shipyard-t9.XXXXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}
# names <label> <needle> <haystack> — assert the haystack contains the needle.
names() {
  CHECKS=$((CHECKS + 1))
  case "$3" in *"$2"*) printf '  ok   %s\n' "$1" ;;
    *) printf '  FAIL %s\n         wanted substring: [%s]\n         in:               [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)) ;; esac
}

# --- faked CLIs, driven entirely by environment variables, FIRST on PATH ---------------------
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/git" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "rev-parse --show-toplevel")  [ -n "${FAKE_TOPLEVEL:-}" ] && { printf '%s\n' "$FAKE_TOPLEVEL"; exit 0; }; exit 128 ;;
  "rev-parse --git-common-dir") [ -n "${FAKE_GITDIR:-}" ]   && { printf '%s\n' "$FAKE_GITDIR";   exit 0; }; exit 128 ;;
  *) exit 0 ;;
esac
EOF
cat >"$FAKEBIN/agtermctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  version) exit "${FAKE_AT_VERSION_RC:-0}" ;;
  tree)    cat "${FAKE_AT_TREE:-/dev/null}"; exit 0 ;;
  *)       exit 0 ;;
esac
EOF
# The faked memory detector: FAKE_MEM_PCT prints the real tool's summary line with that percent;
# FAKE_MEM_RAW prints arbitrary text (to assert the unparseable path); neither prints nothing (to
# assert the no-reading path). It NEVER simulates real pressure — it just echoes a fixture.
cat >"$FAKEBIN/memory_pressure" <<'EOF'
#!/usr/bin/env bash
if [ -n "${FAKE_MEM_RAW:-}" ]; then printf '%s\n' "$FAKE_MEM_RAW"; exit 0; fi
if [ -n "${FAKE_MEM_PCT:-}" ]; then
  printf 'The system has 17179869184 (4194304 pages with a page size of 4096).\n\n'
  printf 'System-wide memory free percentage: %s%%\n' "$FAKE_MEM_PCT"
  exit 0
fi
exit 0
EOF
chmod +x "$FAKEBIN/git" "$FAKEBIN/agtermctl" "$FAKEBIN/memory_pressure"
export PATH="$FAKEBIN:$PATH"
# The repo the fake git reports; container derives to 'proj_x-ai' on agterm (t8 asserts that
# transform), so the tree fixtures below name that workspace.
export FAKE_TOPLEVEL="$TMP/proj:x"
export FAKE_GITDIR="$TMP/gd"; mkdir -p "$FAKE_GITDIR/ship-escalations"

# --- tree fixtures: N ship-* sessions in the derived workspace, plus a non-ship one -----------
tree_of() { # <file> <session-name...>  — write a valid agterm tree naming these sessions
  local f="$1"; shift
  local sess="" i=0 n
  for n in "$@"; do sess="$sess${sess:+,}{\"id\":\"u$i\",\"name\":\"$n\"}"; i=$((i+1)); done
  printf '{"ok":true,"result":{"tree":{"workspaces":[{"id":"w1","name":"proj_x-ai","sessions":[%s]}]}}}\n' "$sess" >"$f"
}
TREE0="$TMP/t0.json"; tree_of "$TREE0" human
TREE1="$TMP/t1.json"; tree_of "$TREE1" human ship-5
TREE2="$TMP/t2.json"; tree_of "$TREE2" ship-5 ship-9
TREE3="$TMP/t3.json"; tree_of "$TREE3" human ship-5 ship-9 ship-12

# --- 1. defaults and overrides ---------------------------------------------------------------
printf '\n── defaults and overrides ──\n'
ok "cap default is 2"                2  "$( . "$ADMISSION"; shipyard_admission_cap )"
ok "cap honours SHIPYARD_MAX_SLOTS"  5  "$( export SHIPYARD_MAX_SLOTS=5; . "$ADMISSION"; shipyard_admission_cap )"
ok "free floor default is 10"        10 "$( . "$ADMISSION"; shipyard_admission_min_free_pct )"
ok "free floor honours override"     25 "$( export SHIPYARD_MEM_MIN_FREE_PCT=25; . "$ADMISSION"; shipyard_admission_min_free_pct )"
# A mistyped knob must NOT silently disable the gate: a non-integer falls back to the default so
# the integer test never errors and never fails open.
ok "a non-integer cap falls back to the default" 2 \
  "$( export SHIPYARD_MAX_SLOTS=two; . "$ADMISSION"; shipyard_admission_cap )"
ok "a cap with a stray trailing space falls back" 2 \
  "$( export SHIPYARD_MAX_SLOTS='2 '; . "$ADMISSION"; shipyard_admission_cap )"
ok "a non-integer floor falls back to the default" 10 \
  "$( export SHIPYARD_MEM_MIN_FREE_PCT=lots; . "$ADMISSION"; shipyard_admission_min_free_pct )"
# An all-digit value long enough to overflow the [ ] integer test would itself error and fail
# open, so it must fall back too — an unusable knob never disables the gate, digits or not.
ok "an over-long all-digit floor falls back to the default" 10 \
  "$( export SHIPYARD_MEM_MIN_FREE_PCT=999999999999999999999; . "$ADMISSION"; shipyard_admission_min_free_pct )"

# --- 2. slot count reuses the backend's enumeration ------------------------------------------
printf '\n── slot count ──\n'
ok "no ship slots -> 0" 0 \
  "$( export SHIPYARD_BACKEND=agterm FAKE_AT_TREE="$TREE0"; . "$BACKEND"; . "$ADMISSION"; shipyard_admission_slot_count )"
ok "one ship slot -> 1 (non-ship ignored)" 1 \
  "$( export SHIPYARD_BACKEND=agterm FAKE_AT_TREE="$TREE1"; . "$BACKEND"; . "$ADMISSION"; shipyard_admission_slot_count )"
ok "two ship slots -> 2" 2 \
  "$( export SHIPYARD_BACKEND=agterm FAKE_AT_TREE="$TREE2"; . "$BACKEND"; . "$ADMISSION"; shipyard_admission_slot_count )"

# --- 3. memory reading parses the detector, fails cleanly when it cannot ----------------------
printf '\n── memory reading ──\n'
ok "parses the free-percentage line" 44 \
  "$( export FAKE_MEM_PCT=44; . "$ADMISSION"; shipyard_admission_mem_free_pct )"
mem_rc=0
( export FAKE_MEM_RAW="no percentage here at all"; . "$ADMISSION"; shipyard_admission_mem_free_pct ) >/dev/null 2>&1 || mem_rc=$?
ok "unparseable output -> exit 1 (unavailable)" 1 "$mem_rc"
noout_rc=0
( . "$ADMISSION"; shipyard_admission_mem_free_pct ) >/dev/null 2>&1 || noout_rc=$?
ok "no reading -> exit 1 (unavailable)" 1 "$noout_rc"

# --- 4. the concurrency-cap decision ---------------------------------------------------------
printf '\n── concurrency cap ──\n'
# Below the cap, with the memory detector giving no reading, admits (rc 0).
out=$( export SHIPYARD_BACKEND=agterm SHIPYARD_MAX_SLOTS=2 FAKE_AT_TREE="$TREE1"; . "$BACKEND"; . "$ADMISSION"; shipyard_admission_report ); rc=$?
ok "1 slot, cap 2 -> admit (rc 0)" 0 "$rc"
names "admit report says OK" "admission: OK" "$out"
# At the cap, refuses with the distinct code 4.
out=$( export SHIPYARD_BACKEND=agterm SHIPYARD_MAX_SLOTS=2 FAKE_AT_TREE="$TREE2"; . "$BACKEND"; . "$ADMISSION"; shipyard_admission_report ); rc=$?
ok "2 slots, cap 2 -> refuse (rc 4)" 4 "$rc"
names "cap refusal names the gate"      "concurrency cap"        "$out"
names "cap refusal gives current count" "2 live ship-* slot(s)"  "$out"
names "cap refusal names the override"  "SHIPYARD_MAX_SLOTS"     "$out"
# Above the cap too (a forced or suffixed launch): still refused.
rc=0; ( export SHIPYARD_BACKEND=agterm SHIPYARD_MAX_SLOTS=2 FAKE_AT_TREE="$TREE3"; . "$BACKEND"; . "$ADMISSION"; shipyard_admission_report ) >/dev/null 2>&1 || rc=$?
ok "3 slots, cap 2 -> refuse (rc 4)" 4 "$rc"
# The acceptance boundary, stated directly: exactly-at refuses, one-below admits.
rc=0; ( export SHIPYARD_BACKEND=agterm SHIPYARD_MAX_SLOTS=1 FAKE_AT_TREE="$TREE1"; . "$BACKEND"; . "$ADMISSION"; shipyard_admission_report ) >/dev/null 2>&1 || rc=$?
ok "boundary: 1 slot, cap 1 -> refuse" 4 "$rc"
rc=0; ( export SHIPYARD_BACKEND=agterm SHIPYARD_MAX_SLOTS=3 FAKE_AT_TREE="$TREE2"; . "$BACKEND"; . "$ADMISSION"; shipyard_admission_report ) >/dev/null 2>&1 || rc=$?
ok "boundary: 2 slots, cap 3 -> admit" 0 "$rc"
# A mistyped cap must fall back to the default (2) and STILL enforce — never fail open — and must
# not leak a raw `integer expected` to stderr.
rc=0; ( export SHIPYARD_BACKEND=agterm SHIPYARD_MAX_SLOTS=two FAKE_AT_TREE="$TREE2"; . "$BACKEND"; . "$ADMISSION"; shipyard_admission_report ) >/dev/null 2>&1 || rc=$?
ok "mistyped cap falls back to default and still enforces (rc 4)" 4 "$rc"
err=$( export SHIPYARD_BACKEND=agterm SHIPYARD_MAX_SLOTS=two FAKE_AT_TREE="$TREE0"; . "$BACKEND" >/dev/null 2>&1; . "$ADMISSION"; shipyard_admission_report 2>&1 >/dev/null )
case "$err" in *'integer expected'*) ok "no raw bash error leaks on a mistyped knob" clean "leaked: [$err]" ;;
               *) ok "no raw bash error leaks on a mistyped knob" clean clean ;; esac

# --- 5. the memory-pressure decision (below the cap, so the memory gate is the one in play) ----
printf '\n── memory pressure ──\n'
out=$( export SHIPYARD_BACKEND=agterm SHIPYARD_MAX_SLOTS=10 FAKE_AT_TREE="$TREE1" FAKE_MEM_PCT=44; . "$BACKEND"; . "$ADMISSION"; shipyard_admission_report ); rc=$?
ok "44% free, floor 10 -> admit (rc 0)" 0 "$rc"
names "admit report shows the reading" "memory 44% free" "$out"
out=$( export SHIPYARD_BACKEND=agterm SHIPYARD_MAX_SLOTS=10 FAKE_AT_TREE="$TREE1" FAKE_MEM_PCT=6; . "$BACKEND"; . "$ADMISSION"; shipyard_admission_report ); rc=$?
ok "6% free, floor 10 -> refuse (rc 5)" 5 "$rc"
names "memory refusal names the gate"     "memory pressure"          "$out"
names "memory refusal gives current pct"  "6% memory free"           "$out"
names "memory refusal names the override" "SHIPYARD_MEM_MIN_FREE_PCT" "$out"
# Boundary: exactly at the floor admits, one below refuses.
rc=0; ( export SHIPYARD_BACKEND=agterm SHIPYARD_MAX_SLOTS=10 FAKE_AT_TREE="$TREE1" FAKE_MEM_PCT=10; . "$BACKEND"; . "$ADMISSION"; shipyard_admission_report ) >/dev/null 2>&1 || rc=$?
ok "boundary: 10% free, floor 10 -> admit" 0 "$rc"
rc=0; ( export SHIPYARD_BACKEND=agterm SHIPYARD_MAX_SLOTS=10 SHIPYARD_MEM_MIN_FREE_PCT=10 FAKE_AT_TREE="$TREE1" FAKE_MEM_PCT=9; . "$BACKEND"; . "$ADMISSION"; shipyard_admission_report ) >/dev/null 2>&1 || rc=$?
ok "boundary: 9% free, floor 10 -> refuse" 5 "$rc"
# A custom floor is honoured end to end.
rc=0; ( export SHIPYARD_BACKEND=agterm SHIPYARD_MAX_SLOTS=10 SHIPYARD_MEM_MIN_FREE_PCT=50 FAKE_AT_TREE="$TREE1" FAKE_MEM_PCT=44; . "$BACKEND"; . "$ADMISSION"; shipyard_admission_report ) >/dev/null 2>&1 || rc=$?
ok "custom floor 50, 44% free -> refuse" 5 "$rc"
# An over-long floor (would overflow the [ ] test) falls back to the default (10), so at 5% free
# the memory gate still ENFORCES (rc 5) instead of erroring and failing open.
rc=0; ( export SHIPYARD_BACKEND=agterm SHIPYARD_MAX_SLOTS=10 SHIPYARD_MEM_MIN_FREE_PCT=999999999999999999999 FAKE_AT_TREE="$TREE1" FAKE_MEM_PCT=5; . "$BACKEND"; . "$ADMISSION"; shipyard_admission_report ) >/dev/null 2>&1 || rc=$?
ok "over-long floor falls back and still enforces (rc 5)" 5 "$rc"

# --- 6. degrade + precedence -----------------------------------------------------------------
printf '\n── degrade and precedence ──\n'
# No detector reading: the memory gate is a no-op, the launch is admitted, and the report says so.
out=$( export SHIPYARD_BACKEND=agterm SHIPYARD_MAX_SLOTS=10 FAKE_AT_TREE="$TREE1"; . "$BACKEND"; . "$ADMISSION"; shipyard_admission_report ); rc=$?
ok "no memory reading -> admit (rc 0)" 0 "$rc"
names "unavailable is stated, not silent" "memory gate unavailable" "$out"
# The cap is checked first: at the cap AND under memory pressure, the code is 4 (cap), not 5.
out=$( export SHIPYARD_BACKEND=agterm SHIPYARD_MAX_SLOTS=2 FAKE_AT_TREE="$TREE2" FAKE_MEM_PCT=1; . "$BACKEND"; . "$ADMISSION"; shipyard_admission_report ); rc=$?
ok "cap takes precedence over memory (rc 4)" 4 "$rc"
names "precedence: the cap gate is the one reported" "concurrency cap" "$out"

# --- 7. the launch-script wiring (static, mirroring t7's continuity-wire assertions) ----------
# t9 sources the gate functions but never drives shipyard-launch.sh, so the WIRE that makes the
# gate matter — evaluate the report, and exit on a refusal BEFORE any worktree or terminal is
# created — is asserted statically here, exactly the way t7 guards shipyard_continuity_start
# against silent removal. Without this, moving the admission block below the creation calls, or
# deleting the enforcing exit, defeats the change's core property ("no worktree or terminal on
# refusal") with every suite still green.
printf '\n── launch wiring ──\n'
LAUNCH="$SKILL/shipyard-launch.sh"
ok "launch evaluates the admission report" 1 "$(grep -Fc 'shipyard_admission_report' "$LAUNCH")"
ok "launch enforces the refusal with its exit code" 1 "$(grep -Fc 'exit "$ADMISSION_RC"' "$LAUNCH")"
enforce_line=$(grep -n 'exit "$ADMISSION_RC"' "$LAUNCH" | head -1 | cut -d: -f1)
create_line=$(grep -n 'shipyard_agent_prepare_worktree' "$LAUNCH" | head -1 | cut -d: -f1)
if [ -n "$enforce_line" ] && [ -n "$create_line" ] && [ "$enforce_line" -lt "$create_line" ]; then
  ok "the refusal exit precedes worktree/terminal creation" yes yes
else
  ok "the refusal exit precedes worktree/terminal creation" yes "no: exit@${enforce_line:-?} create@${create_line:-?}"
fi

printf '\n'
if [ "$FAILURES" -eq 0 ]; then echo "t9 PASS ($CHECKS checks)"; else echo "t9 FAIL ($FAILURES/$CHECKS)"; exit 1; fi
