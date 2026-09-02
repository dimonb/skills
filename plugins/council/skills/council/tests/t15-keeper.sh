#!/usr/bin/env bash
# t15 — a keeper does not outlive its room.
#   * a room rebuilt at the SAME path (rm -rf, then _mkroom again — what every throwaway probe
#     script does) gets a fresh keeper, and the previous one steps down within one poll period;
#   * a room removed for good takes its keeper with it within one poll period.
# Before the pid-file check in _keeper_ensure, the first case left one extra forever-process
# per rebuild: `[ -d "$room" ]` was true again before the old keeper ever looked.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
fail=0

# Wait up to ~8 s (one poll period plus slack) for <pid> to be gone. 0 if it went, 1 if not.
gone() { local i; for i in $(seq 1 16); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.5; done; return 1; }

R="$COUNCIL_TEST_ROOT/t15"
mkroom "$R" a b
old=$(cat "$R/state/keeper.pid")
kill -0 "$old" 2>/dev/null || { echo "FAIL keeper $old is not running after mkroom"; exit 1; }

echo "rebuild at the same path: the old keeper steps down, the new one stays"
mkroom "$R" a b
new=$(cat "$R/state/keeper.pid")
[ "$new" != "$old" ] || { echo "FAIL rebuild did not start a new keeper (still $old)"; fail=1; }
gone "$old" || { echo "FAIL old keeper $old survived the rebuild"; fail=1; }
kill -0 "$new" 2>/dev/null || { echo "FAIL new keeper $new died"; fail=1; }

echo "removal: the keeper goes with the room"
rm -rf "$R"
gone "$new" || { echo "FAIL keeper $new survived the room's removal"; fail=1; }

[ "$fail" = 0 ] && echo "t15 ok"
exit "$fail"
