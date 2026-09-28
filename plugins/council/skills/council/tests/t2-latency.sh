#!/usr/bin/env bash
# t2 — how fast does a peer sitting in recv notice a message?
# This is the whole reason the bell exists: sh's mailbox polls every 5s.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
N=${1:-100}
R="$COUNCIL_TEST_ROOT/t2"; rm -rf "$R"
mkroom "$R" a b
export COUNCIL_ROOM="$R" ROOM="$R"

listener() {
  export COUNCIL_ME=b
  . "$SKILL/lib/lib.sh"
  c_bell_open
  # A wall-clock DEADLINE, as t1-order.sh has on the identical loop (#109). `c_bell_wait` always
  # returns, so a transport that drops or mis-stamps even one message pins `seen` below N and the
  # loop never ends: the run hangs instead of failing. The deadline turns that into the count check
  # below. A ceiling, not a budget: only a failing run pays it, so it is sized for a loaded box. The
  # sends are far slower than their 0.05s gap suggests — 49 in 8s on an idle machine (measured), so
  # ~16s for the default 100 — which is why this is not t1's 90.
  local seen=0 deadline=$(( $(date +%s) + 300 ))
  while [ $seen -lt $N ] && [ "$(date +%s)" -lt "$deadline" ]; do
    if out=$(c_drain); then
      local now; now=$(c_ms)
      while IFS= read -r m; do
        printf '%s\n' "$(( now - $(jq -r '.sent_ms' <<<"$m") ))" >> "$R/log/lat"
        seen=$((seen+1))
      done <<<"$out"
      c_bell_drain
    else
      c_bell_wait 2
    fi
  done
}
listener & LPID=$!
sleep 1
( export COUNCIL_ME=a; . "$SKILL/lib/lib.sh"
  for ((i=1;i<=N;i++)); do c_send --hand --text "ping $i" >/dev/null; sleep 0.05; done )
wait $LPID
sort -n "$R/log/lat" > "$R/log/lat.s" 2>/dev/null || : > "$R/log/lat.s"
n=$(wc -l < "$R/log/lat.s" | tr -d ' ')
# A short count is the transport losing messages, and it reds with the number rather than being
# read as a latency figure over fewer samples.
[ "$n" = "$N" ] || { echo "t2 FAIL (listener saw $n of $N messages before its deadline)"; exit 1; }
p50=$(sed -n "$(( n/2 ))p" "$R/log/lat.s"); p95=$(sed -n "$(( n*95/100 ))p" "$R/log/lat.s")
echo "bell latency over $n messages: min=$(head -1 "$R/log/lat.s")ms p50=${p50}ms p95=${p95}ms max=$(tail -1 "$R/log/lat.s")ms"
# The bar: a human-visible reaction, and far under sh's 0-5s poll.
[ "$p95" -lt 250 ] && { echo "t2 PASS"; exit 0; } || { echo "t2 FAIL (p95 >= 250ms)"; exit 1; }
