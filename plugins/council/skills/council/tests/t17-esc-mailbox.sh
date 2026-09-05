#!/usr/bin/env bash
# t17 — ESC-04: council routes a needs-human signal to the shared escalation mailbox.
#
# When a room closes UNRESOLVED (the room could not converge), v_decide now drops a fire-and-forget
# `notice` into the mailbox policy.sh resolves — the one shipyard's reporter reads — so a council
# escalation surfaces alongside ship's. _helpers.sh points POLICY_MAILBOX_DIR at the run root, so
# this test inspects that temp mailbox and never touches a developer's real .git/ship-escalations.
#
# Two halves, because the property is "unresolved AND ONLY unresolved":
#   A  an unresolved close writes one well-formed notice (the shipyard entry shape);
#   B  a room that DECIDES writes nothing — else every converged room would spam the mailbox.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"

command -v jq >/dev/null 2>&1 || { echo "t17: jq is required" >&2; exit 1; }
MB="${POLICY_MAILBOX_DIR:?_helpers.sh must set POLICY_MAILBOX_DIR}"
fail=0
v() { bash "$CLI" verdict | cut -d' ' -f1; }

# --- A. an unresolved close routes a notice --------------------------------------------------
RU="$COUNCIL_TEST_ROOT/t17u"; rm -rf "$RU"
mkroom "$RU" a b c
export COUNCIL_ROOM="$RU" ROOM="$RU"
jq '.turns_budget = 9' "$RU/roster.json" > "$RU/roster.tmp" && mv "$RU/roster.tmp" "$RU/roster.json"
echo "Should we take on one more schedule mode?" > "$RU/agenda.md"
prop=$(say_floor propose '[]' "Add a swarm mode right away, alongside token.")
say_floor object '["'"$prop"'-1"]' "Swarm needs a stability rule first. Separate work." >/dev/null
say_floor msg '[]' "I see both sides." >/dev/null
say_floor msg '[]' "Yes, it is hard." >/dev/null
say_floor msg '[]' "Agreed, it is hard." >/dev/null
for _t in "Right." "Uh-huh." "Mm." "Still thinking."; do say_floor msg '[]' "$_t" >/dev/null; done
[ "$(v)" = unresolved ] || { echo "FAIL setup: expected unresolved, got $(v)"; fail=1; }
COUNCIL_ME=a bash "$CLI" decide --force >/dev/null || { echo "FAIL --force did not close the room"; fail=1; }

ENTRY="$MB/council-t17u-1.json"
if [ -f "$ENTRY" ]; then
  echo "unresolved close wrote: $ENTRY"
  [ "$(jq -r '.kind'   "$ENTRY")" = notice        ] || { echo "FAIL entry kind is not notice";        fail=1; }
  [ "$(jq -r '.status' "$ENTRY")" = pending       ] || { echo "FAIL entry status is not pending";      fail=1; }
  [ "$(jq -r '.slot'   "$ENTRY")" = council-t17u  ] || { echo "FAIL entry slot is not council-t17u";   fail=1; }
  [ "$(jq -r '.id'     "$ENTRY")" = council-t17u-1 ] || { echo "FAIL entry id is not council-t17u-1";  fail=1; }
  jq -e '.text | test("unresolved")' "$ENTRY" >/dev/null || { echo "FAIL entry text does not mention unresolved"; fail=1; }
  # The shipyard reporter reads these exact keys — assert the whole set so a council entry stays
  # consumable by shipyard-escalations.sh / shipyard-answer.sh unchanged.
  keys=$(jq -r '[keys[]] | join(" ")' "$ENTRY")
  want="answer answered_at context created_at id kind notified slot status text worktree"
  [ "$keys" = "$want" ] || { echo "FAIL entry keys differ from shipyard's shape"; echo "  want: $want"; echo "  got:  $keys"; fail=1; }
else
  echo "FAIL an unresolved close wrote no mailbox entry (looked for $ENTRY)"; ls -la "$MB" 2>&1 || true; fail=1
fi

# --- B. a decided room routes nothing --------------------------------------------------------
RD="$COUNCIL_TEST_ROOT/t17d"; rm -rf "$RD"
mkroom "$RD" a b c
export COUNCIL_ROOM="$RD" ROOM="$RD"
echo "Where should the room keep its history?" > "$RD/agenda.md"
prop=$(say_floor propose '[]' "Keep the history as one lane per author, ordered by Lamport clock.")
obj=$(say_floor  object  '["'"$prop"'-1"]' "Then a reader scans N directories on every poll.")
say_floor support '[]' "A lane per author removes the locks, which matters more." >/dev/null
say_floor amend '["'"$prop"'-1","'"$obj"'-1"]' "One lane per author; a reader probes upward from its cursor, no scans." >/dev/null
say_floor msg '[]' "I agree with the amendment." >/dev/null
say_floor msg '[]' "No objections." >/dev/null
say_floor msg '[]' "Then let us record it." >/dev/null
[ "$(v)" = ready-to-decide ] || { echo "FAIL setup: expected ready-to-decide, got $(v)"; fail=1; }
COUNCIL_ME=a bash "$CLI" decide >/dev/null || { echo "FAIL decide refused a ripe room"; fail=1; }
[ "$(v)" = decided ] || { echo "FAIL the room did not close as decided"; fail=1; }
if ls "$MB"/council-t17d-*.json >/dev/null 2>&1; then
  echo "FAIL a decided room wrote a mailbox entry (it must not):"; ls -la "$MB"/council-t17d-*.json; fail=1
else
  echo "decided room wrote no mailbox entry (correct)"
fi

[ "$fail" = 0 ] && echo "t17 PASS" || echo "t17 FAIL"
exit $fail
