#!/usr/bin/env bash
# t2b — split the delivery time in two: how long until the sleeping peer WAKES,
# and how long its own parsing then takes. Only the first number is the transport.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
N=${1:-60}
R="$COUNCIL_TEST_ROOT/t2b"; rm -rf "$R"
mkroom "$R" a b
export COUNCIL_ROOM="$R" ROOM="$R"
( export COUNCIL_ME=b
  . "$SKILL/lib/lib.sh"
  c_bell_open
  # A wall-clock DEADLINE, as t1-order.sh has on the identical loop (#109): `c_bell_wait` always
  # returns, so one dropped or mis-stamped message would otherwise pin `seen` below N and hang the
  # run. The count check after the loop turns that into a red. A ceiling, not a budget: only a
  # failing run pays it, so it is sized for a loaded box. The sends are slower than their 0.15s gap
  # suggests — 47 in 12s on an idle machine (measured), so ~15s for the default 60.
  seen=0 deadline=$(( $(date +%s) + 300 ))
  while [ $seen -lt $N ] && [ "$(date +%s)" -lt "$deadline" ]; do
    c_bell_wait 3
    wake=$(c_ms)
    if out=$(c_drain); then
      done_ms=$(c_ms)
      while IFS= read -r m; do
        s=$(jq -r '.sent_ms' <<<"$m")
        echo "$((wake - s)) $((done_ms - wake))" >> "$R/log/split"
        seen=$((seen+1))
      done <<<"$out"
      c_bell_drain
    fi
  done ) & LP=$!
sleep 1
( export COUNCIL_ME=a; . "$SKILL/lib/lib.sh"
  for ((i=1;i<=N;i++)); do c_send --hand --text "p$i" >/dev/null; sleep 0.15; done )
wait $LP
n=$(wc -l 2>/dev/null < "$R/log/split" | tr -d ' '); n=${n:-0}
[ "$n" = "$N" ] || { echo "t2b FAIL (listener saw $n of $N messages before its deadline)"; exit 1; }
awk '{w[NR]=$1; p[NR]=$2} END{
  n=asort(w); m=asort(p);
  printf "wake  (bell -> peer awake): p50=%dms p95=%dms max=%dms\n", w[int(n/2)], w[int(n*0.95)], w[n];
  printf "parse (awake -> message in hand): p50=%dms p95=%dms max=%dms\n", p[int(m/2)], p[int(m*0.95)], p[m];
}' "$R/log/split" 2>/dev/null || {
  sort -n -k1 "$R/log/split" | awk '{a[NR]=$1}END{print "wake  p50="a[int(NR/2)]"ms p95="a[int(NR*0.95)]"ms max="a[NR]"ms"}'
  sort -n -k2 "$R/log/split" | awk '{a[NR]=$2}END{print "parse p50="a[int(NR/2)]"ms p95="a[int(NR*0.95)]"ms max="a[NR]"ms"}'
}
