#!/usr/bin/env bash
# t2 — how fast does a peer sitting in recv notice a message?
# This is the whole reason the bell exists: sh's mailbox polls every 5s.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
N=${1:-100}
R="${TMPDIR:-/tmp}/council-test/t2"; rm -rf "$R"
mkroom "$R" a b
export COUNCIL_ROOM="$R" ROOM="$R"

listener() {
  export COUNCIL_ME=b
  . "$SKILL/lib/lib.sh"
  c_bell_open
  local seen=0
  while [ $seen -lt $N ]; do
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
  for ((i=1;i<=N;i++)); do c_send --text "ping $i" >/dev/null; sleep 0.05; done )
wait $LPID
sort -n "$R/log/lat" > "$R/log/lat.s"
n=$(wc -l < "$R/log/lat.s" | tr -d ' ')
p50=$(sed -n "$(( n/2 ))p" "$R/log/lat.s"); p95=$(sed -n "$(( n*95/100 ))p" "$R/log/lat.s")
echo "bell latency over $n messages: min=$(head -1 "$R/log/lat.s")ms p50=${p50}ms p95=${p95}ms max=$(tail -1 "$R/log/lat.s")ms"
# The bar: a human-visible reaction, and far under sh's 0-5s poll.
[ "$p95" -lt 250 ] && { echo "t2 PASS"; exit 0; } || { echo "t2 FAIL (p95 >= 250ms)"; exit 1; }
