# Input: the room's canonical messages, slurped. Output: the argument graph.
#
# Rules, all of them mechanical — no model gets to decide whether it "feels resolved":
#   an objection closes on   withdraw|concede by its own author,
#                            amend by anyone that references it,
#                            overrule by ANYONE — ungated, see below.
#   a proposal dies on       withdraw by its author, or
#                            concede by its author pointing at one of its objections
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
. as $m
| [ $m[] | select(.act == "propose") ] as $props
| [ $m[] | select(.act == "object")  ] as $objs
# The first `decide` message, if any. Named for what it IS -- a message somebody sent -- and
# not `decided`, which is what it used to be called and which every reader then took as "the
# room is closed". It is not: `decide` is an act any participant may send, so the message says
# only that somebody ran the verb. What closes a room is its RECORD (c_recorded_status), and
# this graph cannot see that, because it is fed the message log and nothing else.
| ( $m | map(select(.act == "decide")) | (.[0].id // null) ) as $decide_msg
# `.turn` is written by another participant and is coerced before it is compared: jq sorts
# strings ABOVE numbers, so one message carrying a string turn would win this `max` and be
# reported as the room's last claim no matter what really happened. lib.sh normalises on
# read (see C_UNTRUSTED); this repeats it because the value decides an ordering here, and a
# graph that is only correct while its caller remembers to sanitise is the wrong shape.
| ( [ $m[] | select(.act == "propose" or .act == "amend" or .act == "object")
      | (if (.turn | type) == "number" then .turn else -1 end) ] | max ) as $last_claim
| ( [ $m[] | select(.hand == false and .turn != null and .valid) ] | length ) as $turns
| [ $props[]
    | . as $p
    | ( [ $objs[] | select(((.refs // []) | index($p.id)) != null) ] ) as $po
    | ( [ $po[]
          | . as $o
          | ( [ $m[] | select( ((.refs // []) | index($o.id)) != null
                    and ( (.act == "withdraw" and .from == $o.from)
                       or (.act == "concede"  and .from == $o.from)
                       or (.act == "amend")
                       or (.act == "overrule") ) ) ] | (.[0] // null) ) as $c
          | { id: $o.id, from: $o.from, text: $o.text, hand: ($o.hand // false),
              closed_by: ($c.id // null), closed_act: ($c.act // null),
              closed_by_who: ($c.from // null) } ] ) as $objd
    # An amend belongs to ONE proposal: the first proposal-typed id it references. Its other
    # refs are the objections it closes. Counting it for every proposal it mentions made a
    # single amendment rewrite two rival positions at once, so a room showed two different
    # participants proposing the same words — observed live, and it misleads a human before
    # it misleads any code.
    | ( [ $m[] | select(.act == "amend")
          | select( [ (.refs // [])[] | select( IN($props[].id) ) ] | first == $p.id ) ] ) as $amends
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
| { turns: $turns, last_claim_turn: ($last_claim // -1), decide_msg: $decide_msg,
    proposals: $P,
    live: [ $P[] | select(.dead | not) ],
    open: [ $P[] | select(.dead | not) | .objections[] | select(.closed_by == null) ] }
