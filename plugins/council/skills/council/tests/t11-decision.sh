#!/usr/bin/env bash
# t11 — the decision record must be readable on its own.
#   * "## The decision" carries the ORIGINAL proposal and every amendment, under headings
#     that say which is which. It used to render `current_text` — the last amendment only —
#     so accepted items that the final amendment did not restate appeared nowhere, and the
#     decision had to be reconstructed from the transcript;
#   * the provenance line names the amendment ids, so the transcript can be indexed back
#     from the decision;
#   * a long agenda is summarised with a link and quoted in full at the END, instead of
#     opening the record with two screens of prompt. A one-line agenda stays inline.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/_helpers.sh"
# A private root per run. `COUNCIL_TEST_ROOT` is an optional override, and otherwise we make
# our own. Never a path built from this test's own name: two concurrent runs then delete each
# other's rooms, which is what made a red t3 mean nothing for most of a day.
_own_root=""
if [ -z "${COUNCIL_TEST_ROOT:-}" ]; then
  COUNCIL_TEST_ROOT=$(mktemp -d) || { echo "t11 FAIL: no temp dir"; exit 1; }
  _own_root="$COUNCIL_TEST_ROOT"
fi
R="$COUNCIL_TEST_ROOT/t11"; rm -rf "$R"
mkroom "$R" a b
export COUNCIL_ROOM="$R" ROOM="$R"
fail=0

# The id of the message just sent. A peer's Nth message is `<peer>-N`, so a test that
# hard-codes `-1` silently points at the wrong message once a peer speaks twice.
sid() { # <act> <refs-json> <text>
  say_floor "$1" "$2" "$3" >/dev/null || return $?
  bash "$CLI" order --ids | tail -1
}

printf 'Which storage layout?\n' > "$R/agenda.md"
p=$(sid  propose '[]'            "ITEM-ONE one lane per author. ITEM-TWO no locks. ITEM-FIVE a janitor sweeps orphaned tokens.")
o1=$(sid object  "[\"$p\"]"      "A reader would scan N directories on every poll.")
a1=$(sid amend   "[\"$p\",\"$o1\"]" "AMEND-THREE a reader probes upward from its cursor instead.")
o2=$(sid object  "[\"$p\"]"      "The janitor has no deadline.")
a2=$(sid amend   "[\"$p\",\"$o2\"]" "AMEND-FOUR the janitor finishes within 24 h.")
for i in 1 2 3 4; do sid msg '[]' "Nothing further from me ($i)." >/dev/null; done

[ "$(bash "$CLI" verdict | cut -d' ' -f1)" = ready-to-decide ] || {
  echo "FAIL expected ready-to-decide"; bash "$CLI" claims; exit 1; }

# The graph carries the whole revision chain, in order — and `current_text` keeps its old
# meaning, because claims/status and t8 are written against it.
g=$(bash "$CLI" claims --raw)
# `// []` on the array: without it, a graph that has no `revisions` at all makes jq abort
# with "cannot iterate over null" and the assertion below reports an empty string through a
# screen of jq noise, instead of saying plainly what was missing.
q() { printf '%s' "$g" | jq -r ".proposals[] | select(.id==\"$p\") | $1"; }
revs=$(q '[(.revisions // [])[].id] | join(",")')
[ "$revs" = "$p,$a1,$a2" ] || { echo "FAIL revisions are not original-then-amendments-in-order: '$revs'"; fail=1; }
acts=$(q '[(.revisions // [])[].act] | join(",")')
[ "$acts" = "propose,amend,amend" ] || { echo "FAIL revision acts: '$acts'"; fail=1; }
[ "$(q '(.revisions // [])[0].text')" = "$(q '.text')" ] || { echo "FAIL the first revision is not the original proposal"; fail=1; }
[ "$(q '.current_text')" = "AMEND-FOUR the janitor finishes within 24 h." ] || {
  echo "FAIL current_text changed meaning: '$(q '.current_text')'"; fail=1; }
echo "the graph carries the revision chain in order, and current_text is unchanged"

# Decide as whoever holds the floor. Deciding as a fixed peer leaves v_decide's own trailing
# `decide` message refused, which prints "the floor is no longer yours" into the middle of a
# PASSING test and leaves the room readable as ready-to-decide although the record is written.
decider() { bash "$CLI" floor | sed -n 's/.*floor=\([^ ]*\).*/\1/p'; }
OUT=$(COUNCIL_ME=$(decider) bash "$CLI" decide) || { echo "FAIL decide refused"; exit 1; }
[ "$(bash "$CLI" verdict | cut -d' ' -f1)" = decided ] || {
  echo "FAIL the room does not read back as decided"; fail=1; }
dec=$(sed -n '/^## The decision/,/^## Objections/p' "$OUT")

# Quotable on its own: every accepted item is in the decision section, not only in the
# transcript. This is the assertion the old renderer failed.
for want in ITEM-ONE ITEM-TWO ITEM-FIVE AMEND-THREE AMEND-FOUR; do
  printf '%s\n' "$dec" | grep -q "$want" || { echo "FAIL the decision section is missing $want"; fail=1; }
done
printf '%s\n' "$dec" | grep -q '^### As proposed' || { echo "FAIL no 'As proposed' heading"; fail=1; }
printf '%s\n' "$dec" | grep -q "^### Amendment .$a1" || { echo "FAIL no heading naming amendment $a1"; fail=1; }
printf '%s\n' "$dec" | grep -q "^### Amendment .$a2" || { echo "FAIL no heading naming amendment $a2"; fail=1; }
echo "the decision records the proposal as amended, under headings that say which is which"

printf '%s\n' "$dec" | grep -q "as amended by .$a1., .$a2." || {
  echo "FAIL the provenance line does not name the amendment ids"; fail=1; }
echo "the provenance line names the amendments that carried the proposal"

# A one-line agenda is its own gist: inline, and never quoted a second time.
grep -q 'Which storage layout?' "$OUT" || { echo "FAIL the one-line agenda is missing"; fail=1; }
grep -q '^## The agenda in full' "$OUT" && { echo "FAIL a one-line agenda was quoted twice"; fail=1; }
echo "a one-line agenda stays inline"

# A long agenda: the gist plus a link at the top, the full text at the end.
# mkroom's EXIT trap only remembers the LAST room, so retire this keeper by hand before
# opening the second room, or it outlives the run.
kill "$(cat "$R/state/keeper.pid" 2>/dev/null)" 2>/dev/null
R2="$COUNCIL_TEST_ROOT/t11-long"; rm -rf "$R2"
mkroom "$R2" a b
export COUNCIL_ROOM="$R2" ROOM="$R2"
# The question is the OPENING LINE and a heading comes later, which is the shape that broke:
# scanning the file for its first heading recorded "Background" as the question. A
# heading-first agenda cannot see that difference — both readings return the same string — so
# a fixture shaped that way leaves the whole record-level assertion blind, and the bug could
# come back at the call site with the suite still green.
cat > "$R2/agenda.md" <<'AGENDA'
Where should the room keep its history?

## Background

Background a reader does not need before the decision itself.

* one constraint
* another constraint
AGENDA
sid propose '[]' "One lane per author, total order by Lamport clock." >/dev/null
for i in 1 2 3; do sid msg '[]' "Agreed ($i)." >/dev/null; done
OUT2=$(COUNCIL_ME=$(decider) bash "$CLI" decide) || { echo "FAIL decide refused in the long-agenda room"; exit 1; }

# This room's proposal carried with NO amendment — the most common successful outcome, and a
# different branch of the renderer from the amended one above. Without these two assertions
# the branch is executed but never checked: emptying it writes a blank decision section while
# board/status still says `decided`, and the whole suite stays green.
dec2=$(sed -n '/^## The decision/,/^## Objections/p' "$OUT2")
printf '%s\n' "$dec2" | grep -q 'One lane per author' || {
  echo "FAIL an unamended proposal is missing from the decision section"; fail=1; }
printf '%s\n' "$dec2" | grep -q 'as amended by' && {
  echo "FAIL an unamended proposal claims amendments"; fail=1; }
printf '%s\n' "$dec2" | grep -q '^### ' && {
  echo "FAIL an unamended proposal was given revision headings"; fail=1; }
echo "an unamended proposal is recorded as plain text, with no headings and no amendment claim"

head=$(sed -n '/^## The question/,/^## The decision/p' "$OUT2")
printf '%s\n' "$head" | grep -q 'Where should the room keep its history?' || {
  echo "FAIL the record does not open with the agenda's opening line"; fail=1; }
printf '%s\n' "$head" | grep -q 'Background' && {
  echo "FAIL the record opens with a later section heading, not the question"; fail=1; }
printf '%s\n' "$head" | grep -q 'agenda.md' || { echo "FAIL no link to the agenda"; fail=1; }
printf '%s\n' "$head" | grep -q 'another constraint' && {
  echo "FAIL the whole agenda is still embedded at the top"; fail=1; }
grep -q '^## The agenda in full' "$OUT2" || { echo "FAIL the agenda is not quoted in full at the end"; fail=1; }
printf '%s\n' "$(sed -n '/^## The agenda in full/,$p' "$OUT2")" | grep -q 'another constraint' || {
  echo "FAIL the full agenda section lost the agenda's body"; fail=1; }
echo "a long agenda opens as a heading plus a link, and is quoted in full at the end"

# The gist directly, over the shapes a room record actually gets. The end-to-end fixture
# above opens with a heading, so heading-first and opening-line semantics coincide there and
# it cannot see the difference: picking "the file's first heading" instead of the opening
# line recorded a later section as the question, and every assertion above still passed.
. "$SKILL/lib/verbs.sh"
G="$COUNCIL_TEST_ROOT/t11-gist"; rm -rf "$G"; mkdir -p "$G"
gist_is() { # <name> <want> <agenda-text>
  printf '%s' "$3" > "$G/a.md"
  local got; got=$(_agenda_gist "$G/a.md")
  [ "$got" = "$2" ] || { echo "FAIL gist of $1: want '$2', got '$got'"; fail=1; }
}
gist_is "a question above a later section" "Should we adopt X or Y?" \
  "Should we adopt X or Y?

## Background

lots of stuff"
gist_is "a heading-first agenda" "Where should the room keep its history?" \
  "# Where should the room keep its history?

Background."
gist_is "a comment at column zero in a fenced block" "How often should the janitor run?" \
  "How often should the janitor run?

\`\`\`sh
# poll every 500ms
sleep 0.5
\`\`\`"
gist_is "leading blank lines and an indented question" "Should we adopt X or Y?" \
  "

    Should we adopt X or Y?

More."
# Written with ANSI-C quoting so the trailing blanks sit MID-LINE in this source file: typed
# at the end of a line they are silently eaten by any editor that trims whitespace, and the
# assertion then passes whether or not the trim it is guarding still exists.
gist_is "trailing whitespace on the opening line" "Should we adopt X or Y?" \
  $'Should we adopt X or Y? \t \n\nMore.'
# A heading is hashes followed by SPACE. Without that requirement the strip both mangles
# lines that are not headings and manufactures one: six-hash-max stripping turned eight
# hashes into `## ...`, a section marker of this very record, above the real sections.
gist_is "eight hashes are not a heading" "######## Objections, and how they were closed" \
  "######## Objections, and how they were closed

More."
gist_is "a shebang is not a heading" "#!/usr/bin/env bash" \
  "#!/usr/bin/env bash

More."
gist_is "a hash number is not a heading" "#12 should we adopt X?" \
  "#12 should we adopt X?

More."
echo "the gist is the agenda's opening line, not the first heading found anywhere in it"

# Only reap the root if we made it: one handed down by a runner is that runner's to remove,
# and taking it here would delete the other tests' rooms with it. Retire the second room's
# keeper first, so it is not left polling a directory that is about to go.
kill_keeper "$R2/state/keeper.pid"
[ -n "$_own_root" ] && rm -rf "$_own_root"

[ "$fail" = 0 ] && echo "t11 PASS" || echo "t11 FAIL"
exit $fail
