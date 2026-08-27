#!/usr/bin/env bash
# t4-band.sh — ctx_band's thresholds and its four values.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_helpers.sh
. "$DIR/_helpers.sh"

# --- the edges, exactly ---------------------------------------------------------------------
ok "0 is ok"    "ok"   "$(ctx_band 0)"
ok "64 is ok"   "ok"   "$(ctx_band 64)"
ok "65 warns"   "warn" "$(ctx_band 65)"
ok "79 warns"   "warn" "$(ctx_band 79)"
ok "80 is crit" "crit" "$(ctx_band 80)"
ok "100 is crit" "crit" "$(ctx_band 100)"

# --- the two sentinels ----------------------------------------------------------------------
ok "em-dash sentinel is ok"   "ok"      "$(ctx_band -)"
ok "empty is ok"              "ok"      "$(ctx_band '')"
ok "out-of-range is unknown"  "unknown" "$(ctx_band '?')"

# --- unknown is NOT ok. This is the whole point of it existing. -----------------------------
ok "unknown is distinct from ok" "different" \
   "$([ "$(ctx_band '?')" = "$(ctx_band -)" ] && echo same || echo different)"
# ...and it is not crit either: a permanent alarm for a whole model generation is the glyph
# nobody reads, which is why this is a third value rather than a louder second one.
ok "unknown is distinct from crit" "different" \
   "$([ "$(ctx_band '?')" = "$(ctx_band 90)" ] && echo same || echo different)"

done_ t4-band
