#!/usr/bin/env bash
# t12 — the suite's cleanup guarantees hold after a run, on every exit path a test can take.
# `_helpers.sh` promises that a test leaves nothing behind: its room keepers are stopped, the
# jobs it backgrounded are reaped (a SIGSTOPped one included), and a run root it made itself is
# removed — on a normal exit, on a failed assertion, and on a plain kill while it waits on a
# child. Nothing enforced any of that: the suite printed `all tests passed` over a leaked keeper
# just the same, and the likeliest regression — a `mkroom` moved into a subshell or a pipeline,
# where the keeper list is appended in a child and lost — has no other symptom.
#
# So each case runs a TEST-SHAPED CHILD, a script that sources _helpers.sh exactly as a test does,
# builds two rooms, backgrounds one plain job and one stopped job, and then leaves the way it is
# told to — and checks from outside what survived it. The child under a handed-down root is the
# sharp case: that root is not removed (it is the runner's), so a keeper the trap failed to stop
# would live on with nothing to reap it, and the poll in up.sh cannot satisfy the assertion in the
# trap's place. Mutation-checked, each arm against the regression it names: the keeper loop, the
# job reaping and the root removal taken out of the trap, a TERM trap added to it, and
# `ROOM_KEEPERS+=` moved into a subshell — every one goes red here.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
fail=0
R="$COUNCIL_TEST_ROOT/t12"; rm -rf "$R"; mkdir -p "$R"

# The child. Sourcing the helpers as a test does is the point; `how` is the way it leaves.
CHILD="$R/child.sh"
cat > "$CHILD" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
. "$T12_HELPERS"
report="$1"; how="$2"
R1="$COUNCIL_TEST_ROOT/t12-child-a"; mkroom "$R1" a b
R2="$COUNCIL_TEST_ROOT/t12-child-b"; mkroom "$R2" a b
sleep 300 & j1=$!                      # a listener a test backgrounds and forgets
sleep 300 & j2=$!; kill -STOP "$j2"    # a peer a test wedges on purpose, as t3 does
{ echo "root=$COUNCIL_TEST_ROOT"
  echo "keeper=$(cat "$R1/state/keeper.pid")"; echo "keeper=$(cat "$R2/state/keeper.pid")"
  echo "job=$j1"; echo "job=$j2"; echo ready; } > "$report"
case "$how" in
  fail)  exit 1 ;;      # a failed assertion
  ok)    exit 0 ;;
  block) sleep 300 ;;   # wedged on a child that never returns, until a kill arrives
esac
EOF
export T12_HELPERS="$DIR/_helpers.sh"

# Wait up to <secs> for <pid> to be gone. 0 if it went, 1 if not.
gone() { local i n; n=$(( ${2:-8} * 4 )); for ((i=0; i<n; i++)); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.25; done; return 1; }
# The value of <key>= lines, whole: a root is a path, and a path may hold a space.
field() { sed -n "s/^$1=//p" "$2"; }
# The pid of <key>= lines, first word only: a keeper line carries the pid file's whole record,
# pid then start time, and the date's numeric words are pids of whatever else happens to run.
pid_field() { field "$1" "$2" | awk '{print $1}'; }
# Only ever signal a pid above 1: `kill 0` is the sender's own process group, and 1 is init.
reap9() { case "$1" in ''|*[!0-9]*|0|1) return 0 ;; esac; kill -9 "$1" 2>/dev/null; }
# The direct children of <pid>, from the process table. NOT `pgrep -P`: on macOS, pgrep with no
# pattern ignores -P and lists every process on the machine, and this list is handed to reap9.
children_of() { ps -A -o pid= -o ppid= 2>/dev/null | awk -v p="$1" '$2 == p { print $1 }'; }
# Assert every keeper and job the child reported is gone, within a bound far above the keepers'
# poll period (COUNCIL_KEEPER_POLL_INTERVAL in _helpers.sh) — unambiguous, since in the sharp case
# nothing but the trap ends them.
#
# The child reports exactly two of each, and a line whose pid is missing FAILS rather than being
# skipped: `for p in $(...)` drops an empty word, so a `keeper=` line with nothing after it — a pid
# file that was never written — used to leave nothing to check and pass vacuously (#110's shape).
reaped() { # <report> <label>
  local p key n
  for key in keeper job; do
    n=$(pid_field "$key" "$1" | grep -cE '^[0-9]+$')
    [ "$n" = 2 ] || { echo "FAIL $2: the child reported $n $key pid(s), not 2"; fail=1; }
  done
  for p in $(pid_field keeper "$1"); do
    gone "$p" 8 || { echo "FAIL $2: keeper $p survived the child"; fail=1; reap9 "$p"; }
  done
  for p in $(pid_field job "$1"); do
    gone "$p" 8 || { echo "FAIL $2: background job $p survived the child"; fail=1; reap9 "$p"; }
  done
}
# The root must be exactly what _helpers.sh's mktemp makes: one `run.XXXXXXXX` directly under
# the existing $COUNCIL_TEST_PARENT. The report is line-oriented, so a temp directory whose path
# holds a newline cuts `root=` short at it — and the callers `rm -rf` whatever this returns. A root
# of any other shape is refused, never removed.
own_root_of() { # <report> -> the root the child made for itself, or exit
  local own parent="$COUNCIL_TEST_PARENT"
  own=$(field root "$1")
  [ -n "$own" ] && [ "$own" != "$COUNCIL_TEST_ROOT" ] \
    || { echo "FAIL the child did not make a root of its own ('$own')"; exit 1; }
  { [ -d "$parent" ] && [ "${own%/*}" = "$parent" ] && case "${own##*/}" in run.????????) true ;; *) false ;; esac; } \
    || { echo "FAIL the child's root is not a run.XXXXXXXX directly under $parent ('$own'); refusing it"; exit 1; }
  printf '%s' "$own"
}

echo "1. a failed assertion, in a root handed down: keepers and jobs reaped, the root kept"
rep="$R/report-fail"; mkdir -p "$R/handed"
COUNCIL_TEST_ROOT="$R/handed" bash "$CHILD" "$rep" fail; rc=$?
[ "$rc" = 1 ] || { echo "FAIL the child's exit status was $rc, not the 1 its assertion set"; fail=1; }
grep -qx ready "$rep" 2>/dev/null || { echo "FAIL the child never reported"; exit 1; }
reaped "$rep" "failed assertion"
[ -d "$R/handed/t12-child-a" ] && [ -d "$R/handed/t12-child-b" ] \
  || { echo "FAIL a root the child did not own was removed, rooms and all"; fail=1; }

echo "2. a normal exit, in a root of its own: the root removed, the keepers gone"
rep="$R/report-ok"
env -u COUNCIL_TEST_ROOT bash "$CHILD" "$rep" ok; rc=$?
[ "$rc" = 0 ] || { echo "FAIL the child exited $rc"; fail=1; }
grep -qx ready "$rep" 2>/dev/null || { echo "FAIL the child never reported"; exit 1; }
own=$(own_root_of "$rep") || exit 1
[ ! -e "$own" ] || { echo "FAIL the child's own run root survived it: $own"; fail=1; rm -rf "$own"; }
reaped "$rep" "normal exit"

echo "3. killed while waiting on a child, in a root of its own: dies at once, then as in 2"
rep="$R/report-block"
env -u COUNCIL_TEST_ROOT bash "$CHILD" "$rep" block & cpid=$!
for i in $(seq 1 80); do grep -qx ready "$rep" 2>/dev/null && break; sleep 0.25; done
grep -qx ready "$rep" 2>/dev/null || { echo "FAIL the child never reported"; kill -9 "$cpid" 2>/dev/null; exit 1; }
# The foreground `sleep` the child waits on is not a job of its shell, so its trap does not reap
# it: it is ours to remove afterwards, and its pid is knowable only from outside, while the child
# lives. Two jobs plus that sleep make three children; wait for the third to be forked.
orphans=""
for i in $(seq 1 40); do
  orphans=$(children_of "$cpid" | tr '\n' ' ')
  [ "$(printf '%s' "$orphans" | wc -w)" -ge 3 ] && break
  sleep 0.25
done
# A sanity bound, not a tidy-up: three children are expected, and a list far longer than that means
# the lookup returned something other than this child's children. Signal none of them.
[ "$(printf '%s' "$orphans" | wc -w)" -le 8 ] \
  || { echo "FAIL the child's children lookup returned $(printf '%s' "$orphans" | wc -w) pids; refusing to reap them"; orphans=""; fail=1; }
kill -TERM "$cpid"
# A plain kill of the test's pid, not of its group: the path a trapped TERM would defer until the
# sleep returned, 300 s this test does not wait. Untrapped it dies at once; ten seconds is the bound.
if gone "$cpid" 10; then wait "$cpid" 2>/dev/null; else
  echo "FAIL the child was still running 10 s after a TERM (a deferred trap?)"; fail=1
  kill -9 "$cpid" 2>/dev/null; wait "$cpid" 2>/dev/null
fi
own=$(own_root_of "$rep") || exit 1
[ ! -e "$own" ] || { echo "FAIL the killed child's own run root survived it: $own"; fail=1; rm -rf "$own"; }
reaped "$rep" "killed child"
# The foreground sleep only. The jobs are gone already, and a pid that has exited can be reused by
# an unrelated process, so each one is signalled only while it is still the `sleep 300` it was.
for p in $orphans; do
  [ "$(ps -o command= -p "$p" 2>/dev/null)" = "sleep 300" ] && reap9 "$p"
done

rm -rf "$R/handed"                          # its keepers are dead (asserted); the rooms need not sit here
[ "$fail" = 0 ] && echo "t12 ok"
exit "$fail"
