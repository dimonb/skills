# Input: the room's canonical messages, slurped. Output: the argument graph.
#
# Rules, all of them mechanical — no model gets to decide whether it "feels resolved":
#   an objection closes on   withdraw|concede by its own author,
#                            amend by anyone that references it AND amends the proposal
#                              it was raised against (the amend's owner, below),
#                            overrule by ANYONE — ungated, see below.
#   a proposal dies on       withdraw by its author, or
#                            concede by its author pointing at one of its objections, or at
#                              the proposal itself
#                            (the proposer yielding IS the proposal dying).
# `concede` therefore always means the same thing — the sender yields — and who sent it
# decides what falls.
#
# Four of those rules are author-gated, and naming them beats counting them: withdraw and
# concede by an OBJECTION's own author, and withdraw and concede by a PROPOSAL's own author.
# `amend` is not — anyone who references an objection closes it, by design. Neither is
# `overrule`.
#
# So `.from` is load-bearing here: it decides who may close an objection and who may kill a
# proposal. It is safe to compare because c_all DERIVES it from the lane the message was read
# at rather than reading the message's own claim about itself (lib.sh, the note above
# C_UNTRUSTED). This file is fed by c_canon, which is fed by c_all, so a caller cannot hand it
# un-derived messages by accident; a NEW caller that assembles messages some other way would
# break that and must not.
#
# `overrule` below is gated on NOTHING — not an author, not a role. Any participant closes any
# objection with it, and there is no chair anywhere in this skill: no roster field, no scenario,
# no check. It was described as the chair's act here and in SKILL.md for a long time, which the
# code never implemented. Deriving `.from` does not touch it, because it never consulted `.from`
# in the first place. Whether a room should have a chair is a governance question nobody has
# decided; this comment describes what the code does, and promises nothing about that.
#
# `$closed` (passed with --argjson) is the snapshot `decide` wrote beside the record, in
# `board/closed-over`: the (from, id) pairs of every message the record was written from. The caller
# passes it only for a room whose record is written, and passes `null` otherwise, and when it
# rewrites the record (#176). With a snapshot, the graph is built from those messages alone, and
# every other message is `late`. A late message arrived after the close, or raced it. It is in the
# log and NOT in the record, so it can close nothing, open nothing, and never be counted OPEN. Doing
# any of that is how the room contradicted its own record for ever.
#
# EVERY MESSAGE IS IN EXACTLY ONE OF THE TWO SETS below, the kept set and `late`. `late` carries
# every late message whose act this graph reads, and `claims` and `status` print them in a section
# of their own. The acts it leaves out are the ones the graph ignores anyway: `msg`, `notice`,
# `clarify`, `support`, `skip`, and `decide`, whose announcement follows the record by
# construction. With `$closed` null, `late` is empty and nothing differs from before.
#
# WHAT THIS HOLDS AGAINST, stated as a scope rather than as "a claim can never vanish", which is not
# true. It holds for the ordinary paths: a claim sent after the close, a send that raced the
# close, an emptied or partly emptied snapshot (below), a copied id, and a ref to an id that first
# appears later. It does NOT hold against a seat that forges room state on purpose, and three
# routes were measured and are left open:
#   * a lane file with a chosen lamport that reuses a kept (from, id) sorts first, takes the kept
#     slot, and can then close an objection the record left open;
#   * a pair appended to board/closed-over moves a post-close closing act into the kept set;
#   * a snapshot that drops a proposal named by an EARLIER objection's forward ref leaves that
#     objection attached to nothing. The same happens with no snapshot at all when an objection
#     names only an id that never becomes a proposal. Since #67 such an objection is listed in
#     `dangling` (below) and printed as an annotation, so it is no longer printed nowhere; it is
#     still not counted OPEN, so the edit can take it out of the count the record gives.
# None of these is new ground. On main, one legal `send --hand --act overrule` after the close
# silenced the same OPEN line, which the refusal and this snapshot now prevent. Each route needs a
# write a human reading the lanes or the snapshot can see. The room is not a trust boundary
# (SKILL.md, "The trust contract").
#
# THE KEPT SET IS CLOSED UNDER ITS REFERENCES, and that is what covers a PARTIAL snapshot and not
# only an empty one. An objection is printed under its proposal and an
# amend under its owner. So a snapshot that kept `b-1` and dropped the `a-1` it objects to used to
# print `b-1` nowhere and count it nowhere: one edit of the file hid an objection the record left
# open. Now a kept message is late too when one of its refs names a message that is NOT kept and
# comes EARLIER in the canonical order (the order this graph is fed in). That is repeated until
# nothing moves, because moving one can orphan the next (an amend of that objection).
#
# The set is worked in POSITIONS, never in ids, because `.id` is the message's own claim and
# nothing makes it unique. Two things follow, each of which an id-keyed version got wrong:
#   * a snapshot pair keeps only its FIRST message in that order, so a message later in that order
#     that reuses a kept (from, id) is late rather than silently part of the record. "Later" is
#     canonical order, which a lamport a seat chooses can invert (the first route above). And a
#     pair duplicated in the log BEFORE the close is rendered twice in the record but kept once
#     here, so the readers then show more than the record, never less;
#   * a ref orphans only through an EARLIER dropped message. A copy of a dropped proposal's id in
#     another lane therefore still orphans the objection. A ref to an id that first appears LATER
#     cannot. That id is a typo or a guess at a seat's next id, and a legal `--hand` send after
#     the close may fill it; every such send stamps a lamport above the whole log, so it sorts
#     after the claim. Without this rule, one such send moved a claim of an unedited record to
#     `late`.
($closed // null) as $co
| # The snapshot's `.from` is flattened the way c_all flattens a lane name (#67), so a snapshot written
# before that change still matches a lane whose name held a byte outside printable ASCII.
def _pair_in_snapshot: . as $x
  | any($co[]; ((.from | tostring) | gsub("[^ -~]"; "?")) == $x.from and .id == $x.id);
. as $all
| ($all | length) as $n
| def _closed_under: . as $kept
    | ( [ range(0; $n) ] - $kept ) as $drop
    | ( $kept | map(select(. as $p
          | all(($all[$p].refs // [])[]; . as $r
                | any($drop[]; . < $p and $all[.].id == $r) | not)))) as $next
    | if ($next | length) == ($kept | length) then $kept else ($next | _closed_under) end;
( if $co == null then [ range(0; $n) ]
  else [ range(0; $n) as $p | $all[$p] as $x
         | select($x | _pair_in_snapshot)
         | select(any(range(0; $p); $all[.].from == $x.from and $all[.].id == $x.id) | not)
         | $p ] | _closed_under end ) as $keep
| [ $keep[] | $all[.] ] as $m
| [ ([ range(0; $n) ] - $keep)[] | $all[.] ] as $late
| [ $m[] | select(.act == "propose") ] as $props
| [ $m[] | select(.act == "object")  ] as $objs
# The first `decide` message, if any. Named for what it IS -- a message somebody sent -- and
# not `decided`, which is what it used to be called and which every reader then took as "the
# room is closed". It is not: `decide` is an act any participant may send, so the message says
# only that somebody ran the verb. What closes a room is its RECORD (c_recorded_status), and
# this graph cannot see that, because it is fed the message log and nothing else.
#
# Read from the WHOLE log ($all), not the snapshot. `decide` sends its announcement AFTER the
# record, so that message is never in the snapshot, and it is a fact about the log, not a claim.
| ( $all | map(select(.act == "decide")) | (.[0].id // null) ) as $decide_msg
# `.turn` is written by another participant and is coerced before it is compared: jq sorts
# strings ABOVE numbers, so one message carrying a string turn would win this `max` and be
# reported as the room's last claim no matter what really happened. lib.sh normalises on
# read (see C_UNTRUSTED); this repeats it because the value decides an ordering here, and a
# graph that is only correct while its caller remembers to sanitise is the wrong shape.
| ( [ $m[] | select(.act == "propose" or .act == "amend" or .act == "object")
      | (if (.turn | type) == "number" then .turn else -1 end) ] | max ) as $last_claim
| ( [ $m[] | select(.hand == false and .turn != null and .valid) ] | length ) as $turns
# An amend belongs to ONE proposal, its OWNER: the first proposal-typed id it references. An amend
# that names NO proposal -- `--refs '["<objection>"]'`, off-protocol but nothing refuses it --
# belongs to the proposal its first objection-typed ref was raised against (that objection's own
# first proposal-typed ref). Without that fallback it carried no proposal, so the room ripened on
# it and the record rendered the UN-amended proposal as the decision while the Objections section
# cited the amendment as the close. The amendment's text appeared only in the transcript.
#
# Counting an amend for every proposal it mentions made a single amendment rewrite two rival
# positions at once, so a room showed two different participants proposing the same words --
# observed live, and it misleads a human before it misleads any code.
| ( [ $m[] | select(.act == "amend")
      | . as $a
      | ( [ ($a.refs // [])[] | select( IN($props[].id) ) ] | first ) as $direct
      | { id: $a.id, from: $a.from,
          owner: ( $direct
                   // ( [ ($a.refs // [])[] as $r | $objs[] | select(.id == $r)
                          | [ (.refs // [])[] | select( IN($props[].id) ) ] | first // empty ]
                        | first ) ) } ] ) as $owners
| [ $props[]
    | . as $p
    | ( [ $objs[] | select(((.refs // []) | index($p.id)) != null) ] ) as $po
    | ( [ $po[]
          | . as $o
          # An amend closes an objection only on the proposal it AMENDS (#176, re-homed from
          # #295). It used to close every objection it referenced, on any proposal, while
          # counting as an amendment of one. An amend with refs `["b-3","b-1"]`, owned by `c-1`
          # through `b-3`, then closed `b-1` on `a-1`: `a-1` became the decision, rendered
          # UN-amended, with its objection reading "closed by an amend" nobody made to it.
          # Now `b-1` stays open and `a-1` is not ripe. A room that used to read ready-to-decide
          # can therefore read deliberating or stuck, which is the honest reading.
          | ( [ $m[] | select( ((.refs // []) | index($o.id)) != null
                    and ( (.act == "withdraw" and .from == $o.from)
                       or (.act == "concede"  and .from == $o.from)
                       or (.act == "amend" and (. as $x | any($owners[];
                                .id == $x.id and .from == $x.from and .owner == $p.id)))
                       or (.act == "overrule") ) ) ] | (.[0] // null) ) as $c
          | { id: $o.id, from: $o.from, text: $o.text, hand: ($o.hand // false),
              closed_by: ($c.id // null), closed_act: ($c.act // null),
              closed_by_who: ($c.from // null) } ] ) as $objd
    # The amendments that carry this proposal: those it OWNS (see $owners above).
    | ( [ $m[] | select(.act == "amend")
          | select(. as $x | any($owners[]; .id == $x.id and .from == $x.from and .owner == $p.id)) ]
      ) as $amends
    | ( [ $m[] | select(.act == "withdraw" and .from == $p.from
                        and ((.refs // []) | index($p.id)) != null) ] ) as $wd
    # `concede` means the sender yields, so from a proposal's own author it kills the
    # proposal — whether it points at an objection ("you are right") or at the proposal
    # itself ("I withdraw my position in favour of yours"). The second form was missing,
    # and a live participant used exactly it: the room recorded the concession and then
    # went on reporting two live proposals, one of which nobody was defending any more.
    | ( [ $m[] | select(.act == "concede" and .from == $p.from)
                | select( [ (.refs // [])[] ] | any( IN($objd[].id) or . == $p.id ) ) ] ) as $yield
    | { id: $p.id, from: $p.from, text: $p.text,
        current_text: ( ($amends | last | .text) // $p.text ),
        # The proposal AS AMENDED, in order: the original, then every amendment that
        # carried it. `current_text` is only the LAST amendment, so a decision rendered
        # from it silently dropped every accepted item the final amendment did not repeat.
        # The messages arrive from c_canon already sorted by (lamport, from), so appending
        # $amends preserves the order they were spoken in.
        revisions: ( [ { id: $p.id, from: $p.from, act: "propose", text: $p.text } ]
                     + [ $amends[] | { id: .id, from: .from, act: "amend", text: .text } ] ),
        amends: ($amends | map(.id)),
        dead: ((($wd | length) + ($yield | length)) > 0),
        dead_by: (($wd + $yield) | (.[0].id // null)),
        objections: $objd } ] as $P
# A kept objection that references NO kept proposal, and a kept amend that owns none, attach to
# nothing above, so without this list they were printed nowhere and counted nowhere (#67): a typo'd
# ref (`send` does not check refs) and a snapshot that dropped a forward referent both made an
# objection vanish from every reader. They are listed here and printed by `claims` and `status` as an
# annotation, and a dangling OBJECTION by the record's Objections section too (an amend is not an
# objection, and the record's transcript carries it). They are NOT `open` and not counted: an objection to nothing blocks no
# proposal, and counting it would let one typo hold every room. Log order, like everything else.
| ( [ $m[]
      | select( (.act == "object" and (((.refs // []) | any(IN($props[].id))) | not))
             # The amend's owner is recomputed from THIS message, the $owners rule applied to it,
             # rather than looked up by (id, from): nothing makes that pair unique, and a lookup
             # listed an attached amend as dangling when another amend reused its id.
             or (.act == "amend"
                 and ([ (.refs // [])[] | select(IN($props[].id)) ] | length) == 0
                 and ([ (.refs // [])[] as $r | $objs[] | select(.id == $r)
                        | (.refs // [])[] | select(IN($props[].id)) ] | length) == 0) )
      | { id, from, act, text, refs: (.refs // []) } ] ) as $dangling
| { turns: $turns, last_claim_turn: ($last_claim // -1), decide_msg: $decide_msg,
    dangling: $dangling,
    late: [ $late[] | select(.act | IN("propose", "amend", "object", "withdraw", "concede", "overrule"))
            | { id, from, act, text } ],
    proposals: $P,
    live: [ $P[] | select(.dead | not) ],
    open: [ $P[] | select(.dead | not) | .objections[] | select(.closed_by == null) ] }
