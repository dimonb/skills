#!/usr/bin/env bash
# t1 — concurrency, loss, corruption, causality, delivery order.
# Three peers blast messages at each other with no turn discipline at all (every message is
# a raised hand, which is exempt from it): the worst case the transport will ever see, and
# the point is that it survives without a single lock.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
N=${1:-170}                       # messages per peer
R="$COUNCIL_TEST_ROOT/t1"; rm -rf "$R"
mkroom "$R" a b c
export COUNCIL_ROOM="$R" ROOM="$R"

peer() {
  local me="$1"
  export COUNCIL_ME="$me"
  . "$SKILL/lib/lib.sh"
  c_bell_open
  local i
  for ((i=1;i<=N;i++)); do
    # --hand: out-of-turn by definition, so the turn discipline does not throttle what this
    # test is actually stressing — the transport under three concurrent writers.
    c_send --act msg --hand --text "$me#$i" >/dev/null
    if out=$(c_drain); then printf '%s\n' "$out" | jq -r '.id' >> "$R/log/$me.got"; fi
  done
  # Settle on COMPLETENESS, not on quiet. "Six empty drains in a row" is a timer in
  # disguise: a peer that finishes its own sends early hits a lull while the others are
  # still writing, declares the room quiet, and stops two messages short — which then reads
  # as the transport losing them.
  local want=$(( N * 2 )) got=0 deadline=$(( $(date +%s) + 90 ))
  while [ "$got" -lt "$want" ] && [ "$(date +%s)" -lt "$deadline" ]; do
    if out=$(c_drain); then printf '%s\n' "$out" | jq -r '.id' >> "$R/log/$me.got"; fi
    got=$(wc -l < "$R/log/$me.got" 2>/dev/null || echo 0)
    [ "$got" -lt "$want" ] && c_bell_wait 0.25
  done
}
t0=$(date +%s)
for p in a b c; do peer "$p" & done
wait
t1=$(date +%s)
echo "sent $((N*3)) messages in $((t1-t0))s"

fail=0
# 1. nothing lost, nothing duplicated, nothing half-written
total=$(ls "$R"/lane/*/[0-9]*.json | wc -l | tr -d ' ')
[ "$total" = "$((N*3))" ] || { echo "FAIL files: $total != $((N*3))"; fail=1; }
bad=$(for f in "$R"/lane/*/[0-9]*.json; do jq -e . "$f" >/dev/null 2>&1 || echo "$f"; done | wc -l | tr -d ' ')
[ "$bad" = 0 ] || { echo "FAIL unparsable files: $bad"; fail=1; }
for p in a b c; do
  last=$(ls "$R/lane/$p" | sed 's/\.json//' | sort -n | tail -1)
  cnt=$(ls "$R/lane/$p" | wc -l | tr -d ' ')
  [ "$((10#$last))" = "$cnt" ] || { echo "FAIL seq gap in lane $p: last=$last count=$cnt"; fail=1; }
done
# 2. every peer received every message from the other two, exactly once
for p in a b c; do
  got=$(sort "$R/log/$p.got" | wc -l | tr -d ' ')
  uniq=$(sort -u "$R/log/$p.got" | wc -l | tr -d ' ')
  [ "$got" = "$uniq" ] || { echo "FAIL $p got duplicates: $got vs $uniq"; fail=1; }
  [ "$uniq" = "$((N*2))" ] || { echo "FAIL $p received $uniq, expected $((N*2))"; fail=1; }
done
# 3. total order is a pure function of the log — identical no matter who asks
bash "$CLI" order --ids > "$R/log/order.a"
COUNCIL_ME=b bash "$CLI" order --ids > "$R/log/order.b"
COUNCIL_ME=c bash "$CLI" order --ids > "$R/log/order.c"
cmp -s "$R/log/order.a" "$R/log/order.b" && cmp -s "$R/log/order.a" "$R/log/order.c" \
  || { echo "FAIL total order differs between peers"; fail=1; }
# 4. causality: a message is strictly later than everything it says it had seen
bash "$CLI" order | jq -s '
  (INDEX(.id)) as $byid
  | [ .[] | . as $m | (.deps|to_entries[]) | select(.value>0)
      | ($byid[(.key + "-" + (.value|tostring))]) as $d
      | select($d != null and $d.lamport >= $m.lamport)
      | {msg:$m.id, dep:$d.id, l:$m.lamport, dl:$d.lamport} ] | length' > "$R/log/causal"
viol=$(cat "$R/log/causal")
[ "$viol" = 0 ] || { echo "FAIL causality violations: $viol"; fail=1; }
# 5. HOW OFTEN incremental delivery contradicts the final total order (stragglers).
#    Not a failure — a number the protocol has to live with. In token mode only one
#    peer speaks at a time, so it should be ~0; here, with three peers blasting, it
#    is the honest worst case.
inv=$(for p in a b c; do
  awk 'NR==FNR{pos[$1]=NR;next}{print pos[$1]}' "$R/log/order.a" "$R/log/$p.got" \
   | awk '{if($1<prev)n++; prev=$1}END{print n+0}'
done | paste -sd, -)
echo "delivery inversions vs total order (a,b,c): $inv"
[ "$fail" = 0 ] && echo "t1 PASS" || echo "t1 FAIL"
exit $fail
