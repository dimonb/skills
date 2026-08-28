#!/usr/bin/env bash
# t1-totals.sh — ctx_totals: what counts as a measurement, and current vs peak.
#
# The assertion that earns this file: a client-written all-zero usage record must NOT be taken
# as the current total. It shipped once, and it made a child frozen at its session limit read
# `0% · 0` with no glyph — the most reassuring display the report can produce, on the one child
# that is certainly dead. 18 of 290 transcripts on the machine that found it ended on such a
# record.
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_helpers.sh
. "$DIR/_helpers.sh"

# --- a transcript with no usage record at all is NOT zero, it is nothing -------------------
f=$(transcript empty)
ok "empty file -> nothing" "" "$(ctx_totals "$f")"

f=$(transcript no-usage)
printf '%s\n' '{"type":"system","subtype":"init"}' >> "$f"
printf '%s\n' '{"type":"user","message":{"role":"user"}}' >> "$f"
ok "records but no usage -> nothing" "" "$(ctx_totals "$f")"

f=$(transcript garbage)
printf '%s\n' 'not json at all' >> "$f"
printf '%s\n' '{"unterminated' >> "$f"
ok "unparseable lines -> nothing" "" "$(ctx_totals "$f")"

# --- a real turn is measured ---------------------------------------------------------------
f=$(transcript one-turn)
usage_record 10 300 702000 0 >> "$f"
ok "one real turn -> current and peak both set" "702310 702310" "$(ctx_totals "$f")"

# --- THE REGRESSION: a synthetic all-zero record must not become the current total ----------
f=$(transcript frozen)
usage_record 10 300 702000 0 >> "$f"
synthetic_record >> "$f"
ok "synthetic tail must not zero the reading" "702310 702310" "$(ctx_totals "$f")"

f=$(transcript frozen-many)
usage_record 10 300 702000 0 >> "$f"
synthetic_record >> "$f"
synthetic_record >> "$f"
synthetic_record >> "$f"
ok "a run of synthetic tails is still ignored" "702310 702310" "$(ctx_totals "$f")"

# A transcript of nothing BUT synthetic records has measured nothing — it must not read as 0,
# and its peak must not come back empty either (which used to happen: awk's max was never
# assigned, so `peak` was "" and ctx_window fell through its whole list).
f=$(transcript synthetic-only)
synthetic_record >> "$f"
synthetic_record >> "$f"
ok "synthetic-only -> nothing, not 0" "" "$(ctx_totals "$f")"

# --- current vs peak: autocompact drops the current figure, the peak must not follow --------
f=$(transcript compacted)
usage_record 10 300 461204 0 >> "$f"      # 461514 peak
usage_record 5 100 160212 0 >> "$f"       # 160317 after an autocompact
ok "peak survives an autocompact" "160317 461514" "$(ctx_totals "$f")"

f=$(transcript compacted-then-synthetic)
usage_record 10 300 461204 0 >> "$f"
usage_record 5 100 160212 0 >> "$f"
synthetic_record >> "$f"
ok "peak and current both survive a synthetic tail" "160317 461514" "$(ctx_totals "$f")"

done_ t1-totals
