# Input: the room's canonical messages, slurped. Output: the argument graph.
#
# Rules, all of them mechanical — no model gets to decide whether it "feels resolved":
#   an objection closes on   withdraw|concede by its own author,
#                            amend by anyone that references it,
#                            overrule (the chair).
#   a proposal dies on       withdraw by its author, or
#                            concede by its author pointing at one of its objections
#                            (the proposer yielding IS the proposal dying).
# `concede` therefore always means the same thing — the sender yields — and who sent it
# decides what falls.
. as $m
| [ $m[] | select(.act == "propose") ] as $props
| [ $m[] | select(.act == "object")  ] as $objs
| ( $m | map(select(.act == "decide")) | (.[0].id // null) ) as $decided
| ( [ $m[] | select(.act == "propose" or .act == "amend" or .act == "object")
      | (.turn // -1) ] | max ) as $last_claim
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
    | ( [ $m[] | select(.act == "amend" and ((.refs // []) | index($p.id)) != null) ] ) as $amends
    | ( [ $m[] | select(.act == "withdraw" and .from == $p.from
                        and ((.refs // []) | index($p.id)) != null) ] ) as $wd
    | ( [ $m[] | select(.act == "concede" and .from == $p.from)
                | select( [ (.refs // [])[] ] | any( IN($objd[].id) ) ) ] ) as $yield
    | { id: $p.id, from: $p.from, text: $p.text,
        current_text: ( ($amends | last | .text) // $p.text ),
        amends: ($amends | map(.id)),
        dead: ((($wd | length) + ($yield | length)) > 0),
        dead_by: (($wd + $yield) | (.[0].id // null)),
        objections: $objd } ] as $P
| { turns: $turns, last_claim_turn: ($last_claim // -1), decided: $decided,
    proposals: $P,
    live: [ $P[] | select(.dead | not) ],
    open: [ $P[] | select(.dead | not) | .objections[] | select(.closed_by == null) ] }
