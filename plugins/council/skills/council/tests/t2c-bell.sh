#!/usr/bin/env bash
# t2c — the doorbell alone: byte written -> sleeping reader awake. No json, no jq.
set -uo pipefail
export LC_ALL=C
D=$(mktemp -d); F="$D/b.fifo"; mkfifo "$F"
# This test builds no room, so it sits outside $COUNCIL_TEST_ROOT and the suite's root removal
# cannot reach it. It needs its own EXIT trap: run-all.sh now caps each test with a timeout, so
# being killed part-way through is a routine event rather than a theoretical one, and the final
# `rm` below is never reached when it happens. EXIT alone on purpose — see _helpers.sh on why
# trapping TERM would defer the kill instead of hastening the cleanup.
trap 'rm -rf "$D"' EXIT
ms() { local t=${EPOCHREALTIME/./}; echo $(( 10#$t / 1000 )); }
us() { local t=${EPOCHREALTIME/./}; echo $(( 10#$t )); }
( exec 3<> "$F"
  for i in $(seq 1 50); do
    read -r -t 5 -N 1 -u 3 _ && us >> "$D/wake"
  done ) & RP=$!
sleep 0.5
exec 4> "$F"
for i in $(seq 1 50); do us >> "$D/sent"; printf '.' >&4; sleep 0.05; done
wait $RP
paste "$D/sent" "$D/wake" | awk '{d=$2-$1; a[NR]=d; s+=d} END{n=asorti(a); print ""}' 2>/dev/null
paste "$D/sent" "$D/wake" | awk '{print $2-$1}' | sort -n > "$D/d"
n=$(wc -l < "$D/d" | tr -d ' ')
printf 'pure bell wake over %s rings: min=%sus p50=%sus p95=%sus max=%sus\n' \
  "$n" "$(head -1 "$D/d")" "$(sed -n "$((n/2))p" "$D/d")" "$(sed -n "$((n*95/100))p" "$D/d")" "$(tail -1 "$D/d")"
