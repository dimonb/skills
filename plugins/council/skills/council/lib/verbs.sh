#!/usr/bin/env bash
# verbs.sh — the reading and speaking verbs. Sourced by council.sh with the room and the
# transport already in scope.

# --- the room's own files, read through the entrypoint --------------------------
# A participant should not have to open a file in the room by path. What governs the prompt
# is not the directory: it is whether the agent was TOLD the path or DERIVED it. A path named
# in a launch prompt is read without asking; one the participant works out for itself — the
# agenda, the board — raises "allow access to this file?" every time, with no "always" in the
# menu and no grant that persists (measured in dimonb/skills#7 and #18). While it is up the
# participant holds the floor, and from inside the room that is indistinguishable from one
# that is thinking.
#
# So the room's own readable files get verbs. A verb is a command, and commands DO have a
# persisted grant — which is the whole reason this skill has one entrypoint.

v_protocol() {
  # The one file a participant cannot be handed by a launcher: the peer sitting in the room
  # as `--me` has no launcher at all (`up` skips it), so without this verb its own protocol
  # is reachable only by the path the rest of this file tells it not to use.
  need_me
  [ -f "$ROOM/protocol-$ME.md" ] || {
    printf 'council: no protocol for %s in this room\n' "$ME" >&2
    return 2
  }
  cat "$ROOM/protocol-$ME.md"
}

v_agenda() {
  # A missing agenda is not an error: `up` writes this same placeholder when it is given
  # no agenda, and a room built by hand for a test has no file at all. A participant that
  # reads a non-zero exit as breakage stops instead of speaking.
  if [ -f "$ROOM/agenda.md" ]; then cat "$ROOM/agenda.md"; else printf '(no agenda given)\n'; fi
}

v_decision() {
  # Exit 1 while the room is still open — a STATUS, the same way `verdict` reports a live
  # room, not a failure.
  #
  # `-s`, matching c_recorded_status, and the two readers of this file must not drift apart:
  # v_decide opens the record with `> "$out"`, which creates it at zero bytes the instant the
  # redirect opens, so a decide that dies part-way leaves an empty file behind. With `-f` this
  # verb printed nothing and exited 0 — and `protocol/_channel.md` now makes exactly that exit
  # the single signal every participant stops on, so every seat would leave an open room with
  # no record and no alarm. A non-empty but half-written record still prints and exits 0, which
  # is deliberate: it is the copy a human needs in order to see what went wrong.
  [ -s "$ROOM/board/decision.md" ] || {
    printf 'council: no decision yet — the room is still open (council.sh verdict)\n'
    return 1
  }
  cat "$ROOM/board/decision.md"
}

v_send() { # --act A [--refs J] [--hand] "<text>"
  local -a a=(); local text=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --act|--refs|--to) a+=("$1" "$2"); shift 2 ;;
      --hand) a+=(--hand); shift ;;
      @*) text=$(cat "${1#@}") || return 1; shift ;;
      *) text="$1"; shift ;;
    esac
  done
  [ -n "$text" ] || { echo "council send: empty message" >&2; return 2; }
  c_send ${a+"${a[@]}"} --text "$text"
}

v_recv() { # [--timeout N] [--peek] [--until-floor]
  local timeout=540 peek=0 until_floor=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) timeout="$2"; shift 2 ;;
      --peek) peek=1; shift ;;
      --until-floor) until_floor=1; shift ;;
      *) echo "council recv: unknown argument $1" >&2; return 2 ;;
    esac
  done
  if [ "$peek" = 1 ]; then c_drain && return 0; return 4; fi
  # During an open barrier round there IS no floor holder: everyone owes a position and
  # nobody is waiting for a turn. A participant that has not posted yet must be released
  # immediately, or it sits in --until-floor waiting for a turn that cannot arrive — which
  # is exactly what a live Codex participant did the first time a roundtable room ran.
  # Advancement here is the guard's opening decision (c_round_open), not a barrier re-derived
  # inline — the guard owns "does the opening round still hold" (FLOW-04).
  if [ "$until_floor" = 1 ] && c_round_open && [ -z "$(c_posted_round0)" ]; then
    c_drain || true
    return 0
  fi
  c_bell_open
  local deadline out got
  deadline=$(( $(c_ms) + timeout * 1000 ))
  while :; do
    got=0
    if out=$(c_drain); then printf '%s\n' "$out"; got=1; c_bell_drain; fi
    if [ "$until_floor" = 1 ]; then
      # A CLOSED ROOM RELEASES THIS WAIT, because otherwise nothing does. `--until-floor` returns
      # only when the floor becomes mine, and a closed room hands out no more turns — so a seat
      # that is not the holder when the room closes waits out its whole `--timeout` (540 s by
      # default) and every other seat does the same. protocol/_channel.md prescribes exactly this
      # loop ("recv --until-floor -> one message -> wait again"), so that was the ordinary path,
      # not a corner: a decided room held every participant idle for up to nine minutes apiece
      # while its record sat finished on disk.
      #
      # `c_recorded_status` and NOTHING ELSE decides this. It is the one reader #66 hardened as the
      # authority on a closed room, shared with `verdict`, `claims` and the room graph, so this
      # introduces no second notion of closed — which is the defect this whole family is about. In
      # particular it does NOT key on seeing an `act: decide` message: that says only that somebody
      # ran the verb, and `_channel.md` tells participants the same thing.
      #
      # THE PROPERTY THAT MAKES THIS SAFE: it can only ever return EARLIER than before, never
      # later, and only in a state where the previous behaviour was to wait for a turn that can no
      # longer arrive. So the risk is releasing too EAGERLY, and that is what the test pins — t23
      # asserts an open room still waits, which is the direction a mistake here would break.
      # Placed after the drain above, so a seat released by a close still receives whatever was
      # waiting for it, the announcement included.
      if [ -n "$(c_recorded_status)" ]; then return 0; fi
      # Posted already, round still open: keep waiting — not for a turn, but for the round
      # to complete, which is what releases everyone else's positions. The round/turn advance
      # is the guard's call: the opening round is over (`! c_round_open`) and the floor is mine.
      if ! c_round_open && [ "$(c_floor)" = "$ME" ]; then return 0; fi
    elif [ "$got" = 1 ]; then return 0; fi
    [ "$(c_ms)" -ge "$deadline" ] && break
    c_bell_wait 0.5
  done
  return 4
}

# `deadline_ms` is here because protocol/_channel.md tells a participant to compare it against
# `held_ms` before writing a `skip`, and that participant is told to reach the room through the
# command and never by path — so a rule it can only check by opening roster.json is a rule it
# cannot check at all.
#
# The fallback is a second copy of the number `up` writes, kept in step by nothing — the same
# shape as c_barrier's `round_deadline_ms 600000` and v_verdict's `turns_budget 30`, and filed as
# a rule rather than three pairs of lines. It is reached by any roster `up` did not write as
# written: one assembled by hand, one whose field a peer has since overwritten with something
# that is not an integer, and one that cannot be read at all (a state `floor` still answers in,
# at exit 0 — SKILL.md says so).
#
# The barrier branch prints no deadline on purpose: an open round has no floor holder to be
# overdue, and `skip` has nothing to consume there.
#
# roster.json is writable by every participant, so this number is peer-written like `created_ms`
# and `turns_budget`. Printing it grants no reach that was not already there: c_send exempts
# `skip` from the floor check outright, so a seat that wanted to skip out of turn never needed
# the field — the restriction is protocol rather than a check (see c_send). What the field does
# is let an HONEST seat apply the rule.
#
# c_int_field keeps a crafted value out of the arithmetic. It does NOT keep every crafted value
# off this line: an all-digit integer at or above 2^63 passes the digit gate and wraps through
# `$((10#$v))`, so a peer can still make this field print a negative number and read as "already
# overdue" to an honest seat. That is c_int_field's to fix, for all of its callers at once, and
# it is filed rather than patched here.
v_floor() {
  local t f age
  if c_round_open; then
    printf 'round=0 (barrier) posted=%s/%s waiting=%s conflicts=%s\n' \
      "$(c_round0 | wc -l | tr -d ' ')" "$(c_npeers)" \
      "$(comm -23 <(c_peers | sort) <(c_round0 | jq -r .from | sort) | paste -sd, -)" \
      "$(c_conflicts)"
    return 0
  fi
  t=$(c_turns); f=$(c_floor_at "$t"); age=$(c_floor_held_ms)
  printf 'turns=%s floor=%s next=%s held_ms=%s deadline_ms=%s conflicts=%s\n' \
    "$t" "$f" "$(c_floor_at $((t+1)))" "$age" "$(c_int_field turn_deadline_ms 180000)" \
    "$(c_conflicts)"
}

# The four verbs a PARTICIPANT reads the room with all go through c_visible, so an open
# barrier round withholds from them NO LESS than it withholds from `recv` -- a lane holding a
# foreign opening position is withheld whole. It is deliberately one-sided rather than an
# equality; c_visible's header says why, and reading it as an equality is what produces the
# lamport-ordered prefix cut that was reverted as a hole. `--ids` is filtered too: an id is not
# content, but a list of them says who has posted, and a reader that withholds the messages
# and not their ids is the same divergence in miniature.
v_order() { if [ "${1:-}" = "--ids" ]; then c_visible | jq -r '.id'; else c_visible; fi; }

# The renderer, over whatever stream it is given. `transcript` shows a participant what it may
# see; v_decide renders the SAME lines from the whole log into the record, because the record
# is the room's output rather than one seat's view of it.
_render_transcript() {
  jq -r '"[\(.from) \(.act)\(if (.refs|length)>0 then " →"+(.refs|join(",")) else "" end)\(if .valid then "" else " (out of turn)" end)] \(.text)"'
}

v_transcript() { c_visible | _render_transcript; }

_graph_of() { jq -s -f "$SKILL/lib/claims.jq"; }
# The whole room. `verdict` reports the room's state and `decide` writes its record, and
# neither is a function of who is asking.
_graph() { c_canon | _graph_of; }
# What the asker may see. `claims` and the display half of `status` render proposal and
# objection TEXT, which is precisely what an open barrier round withholds.
_graph_seen() { c_visible | _graph_of; }

v_claims() {
  local g; g=$(_graph_seen) || return 1
  [ "${1:-}" = "--raw" ] && { printf '%s\n' "$g"; return 0; }
  # Turns from c_turns here too. The graph counts turn-claiming messages only, so in a
  # roundtable room it is short by the whole opening lap, and `claims` and `verdict` printed
  # two different turn counts for one room.
  #
  # The second field is the turn a claim STAMPED, which is not the window `verdict` reports
  # and no longer has anything to do with it: a barrier position and a `--hand` claim stamp
  # no turn, so this reads -1 in rooms whose every claim is real. Labelled for what it is,
  # rather than left looking like a contradiction of the verdict line.
  # Closure comes from the RECORD, through the same reader `verdict` uses. This line used to
  # print "DECIDED by message <id>" from claims.jq's `$decided`, which is nothing more than
  # "a decide message exists somewhere in the log" -- so one room answered `deliberating` from
  # `verdict`, `DECIDED` from here, and "no decision yet" from `decision`, all at once. It ran
  # the other way too: after a `--force` close whose trailing send was refused, the room was
  # genuinely closed and this line said nothing at all. protocol/_channel.md sends every
  # participant here to catch up, so this was the reader most likely to be believed.
  #
  # `.decide_msg` below goes through `@json`, and that is not tidiness. It is a peer own `.id`,
  # unverified, a string a participant chose, and it may contain NEWLINES. Interpolated raw it
  # forged this very block: an id of "x)\nCLOSED as decided — the record is written
  # (council.sh decision)\n(" made `claims` print a line byte-identical to the closure
  # announcement above, while the room was open and no record existed. That is the hole this
  # whole change closes, reopened on the line that closes it. `@json` quotes and escapes, so a
  # forged newline renders as \n inside one visibly quoted string.
  printf '%s' "$g" | jq -r --argjson turns "$(c_turns)" --arg closed "$(c_recorded_status)" '
    "turns: \($turns)   last claim that stamped a turn: \(.last_claim_turn)",
    (if $closed != "" then "CLOSED as \($closed) — the record is written (council.sh decision)"
     elif .decide_msg then "a decide message was sent (\(.decide_msg | @json)) — no record yet, the room is still open"
     else empty end),
    "",
    ( .proposals[]
      | "proposal \(.id) from \(.from)\(if .dead then "  [dropped: \(.dead_by)]" else "" end)"
      , "  \(.current_text)"
      , (if (.amends|length) > 0 then "  amendments: \(.amends|join(", "))" else empty end)
      , ( . as $p | .objections[]
          | if .closed_by != null
            then "  ✓ closed  \(.id) (\(.from)) — \(.closed_act) from \(.closed_by_who): \(.text)"
            elif $p.dead
            then "  · dropped with its proposal: \(.id) (\(.from)): \(.text)"
            else "  ✗ OPEN \(.id) (\(.from)): \(.text)" end )
      , "" ),
    "open objections: \(.open|length)"'
}

# The verdict is COMPUTED. "We agree" here means: no open objection, and a full lap in
# which nobody added a proposal, an amendment or an objection. Not a mood anyone reports.
v_verdict() {
  local g n budget turns live open since win lap v recorded gok
  # THE RECORD ANSWERS BEFORE THE ROOM DOES. `board/decision.md` and `board/status` pass
  # through neither the lane log nor the roster, so a room that has already closed must keep
  # saying so even when neither can be read -- `status` exits 0 ("the room is finished"), which
  # is the contract a supervising session polls on, and `decide` returns 3.
  #
  # This is read FIRST because reading it last has now produced the same inversion twice, from
  # two different directions: once when an unreadable LOG made `_graph` fail (reverted -- see
  # c_all's header), and once when an unreadable ROSTER made the peer-count precondition below
  # return. Both left a closed room answering nothing at all, and both were invisible until a
  # room was actually closed and then damaged. `origin/main` answers `decided` in both states.
  #
  # A room whose record is written is not going to change its mind, so nothing computed below
  # can alter this answer -- which is why short-circuiting here is safe as well as correct.
  # THE RECORD IS A FALLBACK, NOT A SUBSTITUTE. It answers only when the room cannot be read,
  # so a room that can be read is reported from the room -- and the computed path below already
  # gives the record the last word on the VERDICT (`if [ -n "$recorded" ]; then v=$recorded`),
  # which is the part that must not be recomputed. Writing this as a parallel block that emits
  # its own JSON instead cost two rounds: the first version omitted `turns`, `budget`,
  # `since_last_claim` and `lap`, so every closed room rendered `turns 5/null` and wrote
  # `* turns: null of null` into its durable record; the second invented `live`, `open`,
  # `open_ids` and `decide_msg` as 0/0/[]/null, so `verdict --json` reported no open objection
  # on a room recorded `unresolved` -- which is precisely a room that closed with objections
  # standing -- while `status`, `claims` and the record all still said otherwise. A block that
  # has to be kept in step with the one below by hand will fall out of step; falling through
  # keeps them the same code.
  recorded=$(c_recorded_status)
  # Held to digits, not `// 30` and not jq's `type == "number"`: a string is truthy in jq so
  # the alternative never fires, and a JSON number is not a bash integer -- `2.5` and `1e400`
  # are numbers, and both make the `[ -ge ]` below error, which silently disables the room's
  # only stop condition and puts the same value into `--argjson`. roster.json is peer-writable.
  n=$(c_npeers); budget=$(c_int_field turns_budget 30)
  # `gok` rather than `[ -z "$g" ]`: an empty room's graph is a perfectly good JSON object, and
  # testing the text would read an empty room as a broken one.
  gok=1; g=$(_graph) && gok=0
  # A room with no readable participant list has no lap to measure convergence against, and
  # `lap` is exactly what both thresholds below compare against. At n=0, `[ "$since" -ge 0 ]` is
  # UNCONDITIONALLY true, so such a room reported ready-to-decide on its very first proposal and
  # `decide` -- without --force -- wrote a permanent `decided` record at rc 0, carrying a blank
  # participant list, for a room in which nobody could take the floor. No hostile peer is needed:
  # a truncated, absent or half-written roster.json does it, and roster.json is written with a
  # plain `>`.
  if [ "$gok" != 0 ] || [ "$n" -le 0 ]; then
    # Neither door opens. If the room has already produced its output, say so from the record --
    # `board/decision.md` and `board/status` pass through neither the log nor the roster, and a
    # room whose record is written is not going to change its mind. Reading the record LAST
    # produced the same inversion twice, from both doors: a closed room answering nothing at all,
    # `status` rc 1 where a supervisor waits on rc 0, and `decide` rc 1 where SKILL.md promises 3.
    #
    # With no record either, return 1 having printed nothing -- the same contract `_graph`'s own
    # failure already used, so the two agree: a room this verb cannot read yields no verdict.
    # v_status then raises its "state could not be computed" alarm and v_decide refuses to write
    # a record. c_floor_at and c_barrier carry the same precondition.
    [ -n "$recorded" ] || return 1
    # The counts are the honest ones for a room nothing can be read from; every other field comes
    # from a reader that is TOTAL -- it falls back to a default rather than failing, so an
    # unreadable roster costs accuracy, not an answer. They are not roster-INDEPENDENT: `c_turns`
    # (through `c_mode` and `c_barrier`), `c_npeers` and `c_int_field` all read roster.json, and
    # removing it moves `lap` to 0 and, in a roundtable room, `turns` down by a lap. Only
    # `c_turns_since_last_claim` is independent of it, and it answers -1 rather than failing.
    local rturns rwin rsince
    rturns=$(c_turns); rwin=$(c_turns_since_last_claim)
    rsince=$(( rwin < 0 ? rturns : rwin ))
    if [ "${1:-}" = "--json" ]; then
      printf '{"verdict":"%s","turns":%s,"budget":%s,"since_last_claim":%s,"lap":%s,"live":0,"open":0,"open_ids":[],"decide_msg":null,"recorded":true}\n' \
        "$recorded" "$rturns" "$budget" "$rsince" "$n"
    else
      printf '%s  turns %s/%s  nothing new for %s turns (lap %s)  (recorded; the room is closed)\n' \
        "$recorded" "$rturns" "$budget" "$rsince" "$n"
    fi
    return 0
  fi
  # Two counts, and deliberately NOT the decide message's id alongside them. `@tsv` does not
  # escape spaces and `read` splits on them as well as on tabs, so a peer-chosen `.id` of
  # `b 9` used to shift every following field: live took the id's tail and open took
  # `1<TAB>1`, which then reached `[ "$open" -gt 0 ]` as `integer expected`. That was harmless
  # only while the branch below short-circuited on the id being present -- which is exactly
  # what this change removed, so carrying the field here would have turned a latent trap into
  # a live one: the room could no longer report stuck, ready-to-decide or no-proposal, and
  # `status` lost the STUCK alarm entirely. A non-scalar `.id` empties all three the same way.
  read -r live open <<<"$(printf '%s' "$g" | jq -r '[(.live|length), (.open|length)] | @tsv')"
  # Turns come from c_turns, never from the graph: the graph counts turn-claiming messages
  # and knows nothing about a completed barrier round, which consumes a whole lap without
  # any of its positions claiming a turn. Mixing the two produced a room "minus one turn
  # with nothing new said" — a negative age that no branch below reads correctly. The JSON
  # further down kept emitting the graph's count long after this was written, which is how
  # a roundtable room's decision record came to report its turns short by a whole lap.
  turns=$(c_turns)
  lap=$n
  # The window is a count of turns minus a count of turns, both taken from one reading of
  # the log (see c_turns_since_last_claim). `win` is -1 only when the room holds no claim
  # at all, which is also what gates the two thresholds below: a claim that stamped no turn
  # -- a barrier position, or an objection raised with `--hand` -- is still a claim, and
  # keying the gate on a stamped turn left a roundtable room unable to converge at all.
  win=$(c_turns_since_last_claim)
  since=$(( win < 0 ? turns : win ))
  # A room is closed when its RECORD says so, never because a `decide` message exists --
  # c_recorded_status is the one reader that decides this, shared with v_claims so the two
  # verbs cannot drift apart, and it carries the full account of why. That is issue #66's
  # third reproduction: a bare `{"act":"decide"}` in any lane used to make the room report
  # itself decided with rc 0 while holding a live proposal and having written no record. It is
  # NOT an author-identity bug -- it reproduces identically with an honest `.from`.
  recorded=$(c_recorded_status)
  if   [ -n "$recorded" ]; then v=$recorded
  elif [ "$turns" -ge "$budget" ]; then v=unresolved
  elif [ "$live" = 0 ]; then v=no-proposal
  elif [ "$open" -gt 0 ] && [ "$win" -ge 0 ] && [ "$since" -ge "$lap" ]; then v=stuck
  elif [ "$open" = 0 ] && [ "$live" = 1 ] && [ "$win" -ge 0 ] && [ "$since" -ge "$lap" ]; then v=ready-to-decide
  else v=deliberating
  fi
  if [ "${1:-}" = "--json" ]; then
    printf '%s' "$g" | jq -c --arg v "$v" --argjson turns "$turns" --argjson since "$since" \
      --argjson lap "$lap" --argjson budget "$budget" \
      '{verdict:$v, turns:$turns, budget:$budget, since_last_claim:$since, lap:$lap,
        live:(.live|length), open:(.open|length), open_ids:[.open[].id],
        decide_msg:.decide_msg}'
  else
    printf '%s  turns %s/%s  nothing new for %s turns (lap %s)  live proposals %s  open objections %s\n' \
      "$v" "$turns" "$budget" "$since" "$lap" "$live" "$open"
  fi
  case "$v" in decided|unresolved) return 0 ;; stuck) return 2 ;; *) return 1 ;; esac
}

# --- WHY a seat that holds the floor is not moving ----------------------------------------------
# THE DEFECT THESE HELPERS CLOSE. `status` could say "the floor has been held for 626s"; it could
# not say why, so it guessed — "it may be sitting on a permission prompt" — and a supervisor had to
# go and capture the terminal by hand to find out. The guess mattered because the two commonest
# causes need OPPOSITE remedies: a seat parked on a capacity limit resumes on its own, while a seat
# on a first-launch trust prompt needs that prompt answered IN PLACE. `council.sh relaunch` is the
# remedy for neither, and it throws away the seat's reading of the whole argument.
#
# THE RULE THAT SHAPES ALL OF IT, and the one to keep if everything else here is rewritten:
#
#   UNTRUSTED EVIDENCE MAY ANNOTATE AN OPERATOR-FACING SIGNAL, NEVER SUPPRESS ONE.
#
# A peer-writable value that changes how a signal READS is fine; one that decides whether the
# signal APPEARS is not. That is the difference between informing a supervisor and being trusted by
# one, and a signal a participant can silence is strictly worse than none, because the supervisor
# stops looking.
#
# IT SAYS *SIGNAL*, NOT *ALARM*, AND THAT WORD COST A ROUND. Written as "never suppress an alarm",
# it was applied to the alarm line that happened to be in front of the author — and the mailbox
# PUSH, the second operator-facing output of the same event, stayed gated on peer-writable state
# for another round. So the test is per OUTPUT, not per feature: for each thing a supervisor reads,
# ask what decides whether it appears. The enumeration further down does that for this verb.
#
# THE PRECEDENT IS IN THIS FILE ALREADY: the `created_ms` paragraph in v_status says the same thing
# for the clock-wrong wording — the alarm fires on the condition it always did, and the untrusted
# value can only change how it reads. This is that rule applied to a second untrusted input.
#
# WHERE SUPPRESSION CANNOT BE PREVENTED, MAKE IT SELF-REVEALING. That is the stronger form, and it
# is what `_stall_escalate` does below: nothing confines a participant (SKILL.md, "The room is not
# a trust boundary", measured for all three kinds), so no file a supervisor writes is out of a
# seat's reach. Rather than pretend otherwise, the push de-duplicates against the MAILBOX ITSELF,
# so suppressing a notice THROUGH THE DE-DUPLICATION CHECK costs a visible artefact in the
# directory the supervisor reads. Read that as a property of the check, not of the push: the other
# ways out are enumerated below and `_stall_escalate` names its own. Self-revealing is the property
# to prefer to an unreachable-file argument whenever you have the choice — it survives an adversary
# you cannot lock out, which is the case here.
#
# WHAT THIS DOES NOT MAKE TRUE, stated because the rule above reads stronger than the room is.
# EVERY operator-facing output of this verb is ultimately a function of room state a participant
# can write, and that is #40's fact rather than this change's defect:
#   * the status block's fields — roster.json and the lanes, wholesale;
#   * the STUCK / ready-to-decide / unresolved alarms — the claim graph, i.e. the lanes;
#   * `status`'s exit code and `rooms`' listing — `board/status` + `board/decision.md`;
#   * the STALL alarm — `c_floor_held_ms`, hence the last turn's peer-written `sent_ms` and
#     `created_ms`. A seat that stamps a message in the FUTURE clamps the held time to 0 and
#     removes the alarm and the push together; measured, and filed as #165. That is a live
#     counterexample to the rule above, it predates this change, and it is named here rather than
#     left for a reader to find, because a rule stated absolutely and contradicted by the same file
#     is worse than a rule stated with its hole;
#   * the mailbox push — everything the alarm is gated on, PLUS the closed-room early return
#     (`board/status` + `board/decision.md`, forgeable, #66) and the mailbox's own contents, which
#     are not room state. It carries strictly more gates than the alarm, so "same condition as the
#     alarm" is the wrong summary; `_stall_escalate`'s header lists them.
# What this change CAN keep true is narrower and worth having: the TERMINAL READ — the one input
# here that is not room state — is annotation-only, so it adds no new way to go dark.
#
# WHY IT HAD TO BE THIS WAY ROUND, stated as what was actually checked rather than as a claim about
# every possible design. An earlier draft let a recognised capacity banner REPLACE the alarm. Every
# fact that draft keyed on turns out to sit inside the room directory, which is the participant's
# own writable root (#40): the roster's `.peers[].kind`, the container pin under `state/`, the
# launcher script, and the pane itself, whose selection follows the pin. A record written outside
# the room at launch would not be peer-writable, but that is `up.sh`'s to write. NOT CHECKED:
# whether either terminal backend can attest a session's identity in a way a participant cannot
# forge — so this is not a claim that no unforgeable anchor exists, only that none of the four this
# code can reach today is one. The annotation needs no such anchor, which is why it is the
# annotation that shipped.
#
# NOTHING HERE IS COUNCIL'S OWN KNOWLEDGE. Three modules already answer the three parts, and
# shipyard's stall watchdog asks the same question through the same two of them
# (`shipyard_wait_state`):
#   * shared/adapters (`adp_wait_class`) owns what a client RENDERS, and returns a class from the
#     driver's AgentSignal vocabulary; `adp_wait_anchored` owns whether that read is evidenced for
#     the kind in question, which matters here and not in shipyard because council admits a wider
#     set of kinds than the two whose panes have been captured;
#   * shared/policy (`policy_dispose`) owns what to DO with such a class — `park` is a self-healing
#     wait — and `policy_park_advice` owns the sentence a person is shown about one.
# Nothing here re-derives any of that, and in particular nothing here reads a time out of a banner:
# ESC-03 in the policy module records why that number is always in the past.
#
# WHAT THE GATES ARE FOR, now that none of them can clear an alarm: they keep `status` from
# PRINTING a claim it has no standing to make. An unanchored kind gets no sentence rather than a
# sentence about a client whose chrome nobody has captured. The screen read itself is anchored on
# client chrome (see agent-adapters.sh, and AGENTS.md for why a substring over a capture is
# forgeable by an agent whose work IS that predicate — a council seat arguing about this very
# feature is exactly such an agent).

# _floor_screen <peer> — the seat's visible screen, or nothing and rc 1.
_floor_screen() {
  local peer="${1:-}" f pinned=0
  [ -n "$peer" ] || return 1
  # A TEST SEAM: it replaces the CAPTURE, never the classification or the disposition below, so a
  # test still exercises the real anchor and the real policy table. It is read from the environment
  # of whichever process runs `status` — usually the supervisor's, but `status` takes no `need_me`
  # and participants are told they may read the room with it, so a seat running `status` controls
  # this for ITS OWN invocation. That buys nothing worth having: the result can only ANNOTATE an
  # alarm, and a seat can already put whatever it likes on its own pane.
  if [ -n "${COUNCIL_WAIT_SCREEN_FILE:-}" ] && [ -f "$COUNCIL_WAIT_SCREEN_FILE" ]; then
    cat "$COUNCIL_WAIT_SCREEN_FILE"; return 0
  fi
  # A room with no pinned container was never LAUNCHED by this skill, so it has no terminals to
  # read and there is nothing to ask. What the guard saves is the pane CAPTURE — the backend's
  # tree/list call and its read — for the rooms that have none: the test rooms, and a room built by
  # hand. It does not save the backend RESOLUTION, which happens once when term.sh is sourced; the
  # source is therefore deferred to here, after the guard, so a room with no pin costs neither.
  for f in "$ROOM"/state/container-*; do [ -f "$f" ] && pinned=1; done
  [ "$pinned" = 1 ] || return 1
  # Sourced on demand, PER INVOCATION — not once, whatever the `command -v` looks like it buys.
  # This function's only call site is `screen=$(_floor_screen "$peer")`, i.e. a command
  # substitution, so everything it defines dies with that subshell and the next call re-sources.
  # That is fine while there is one call per `status`, and it is the reason this guard cannot be
  # read as a cache: a future caller that loops the read would pay the backend resolution every
  # time, and should hoist the source into v_status, outside the substitution, where the guard
  # would actually bite. A caller with no $SKILL, or a term.sh that will not load, gets no capture
  # rather than an error — the same way v_decide treats policy.sh.
  if ! command -v ct_capture >/dev/null 2>&1; then
    [ -n "${SKILL:-}" ] && [ -f "$SKILL/lib/term.sh" ] || return 1
    . "$SKILL/lib/term.sh" || return 1
    command -v ct_capture >/dev/null 2>&1 || return 1
  fi
  ct_capture "$peer" 2>/dev/null
}

# _floor_wait_state <peer> — "<class><TAB><the line that said so>" and rc 0 when this seat's own
# client announces a wait that heals itself; nothing and rc 1 for every other answer, including
# every answer we are not entitled to give.
#
# ITS RESULT IS EVIDENCE, NOT A VERDICT. Every input it reads is peer-writable (the header above
# enumerates them), so the caller may quote it and must not act on it: it adds a sentence to the
# STALL alarm and decides nothing about whether that alarm, or its push, happens. Keep it that way
# round — the moment a caller branches the alarm on this, a seat can silence the supervisor's alarm
# about itself, which is worse than the blindness this whole block exists to fix.
_floor_wait_state() {
  local peer="${1:-}" kind screen ev cls
  [ -n "$peer" ] || return 1
  # Both shared modules are sourced by council.sh for this verb. Absent either, give up quietly:
  # the STALL alarm is unchanged by that, and a supervisor is never told a pass ran that did not.
  command -v adp_wait_class >/dev/null 2>&1 || return 1
  command -v adp_wait_anchored >/dev/null 2>&1 || return 1
  command -v policy_dispose >/dev/null 2>&1 || return 1
  # The kind comes from the roster, which is where `relaunch` already reads it. `.peers` is absent
  # in a room built without it (the test helper's rooms, and any room made before `up` wrote the
  # field), and an unknown kind is unanchored by definition — both end the read here.
  kind=$(jq -r --arg p "$peer" '.peers[]? | select(.name==$p) | .kind // empty' \
           "$ROOM/roster.json" 2>/dev/null | head -1)
  [ -n "$kind" ] || return 1
  adp_wait_anchored "$kind" || return 1
  screen=$(_floor_screen "$peer") || return 1
  [ -n "$screen" ] || return 1
  ev=$(adp_wait_class "$screen" 2>/dev/null)   # "<class><TAB><the line that said so>", or empty
  cls=${ev%%	*}
  ev=${ev#*	}
  # The emptiness test IS the check: adp_wait_class printing nothing is how it says "no class",
  # and its own exit status is lost to the command substitution.
  [ -n "$cls" ] || return 1
  # Routed through policy rather than tested as a class here, so a class added to the adapter
  # later arrives with the shared disposition already attached and lands on the STALL path unless
  # someone deliberately writes an arm for it. `park` is the only self-healing disposition there
  # is; `compact` and every `escalate` are a person's move and belong in the alarm, not out of it.
  case "$(policy_dispose "$cls" 2>/dev/null)" in
    park*) printf '%s\t%s' "$cls" "$ev"; return 0 ;;
  esac
  return 1
}

# _stall_escalate <peer> <turns> <held-seconds> [annotation] — push one notice into the shared
# mailbox for a stalled room. Best-effort: it can never fail the status block that called it.
#
# WHAT IT ADDS THAT THE PRINTED ALARM CANNOT. `status` writes to a console someone has to be
# reading. This is the same fire-and-forget channel `decide` already uses for a room that closed
# unresolved (ESC-04), so a council stall lands in the one directory a shipyard parent's escalation
# monitor already polls, alongside ship's — which means the person who sees it need not be the one
# who ran `status`. It does NOT make the room self-reporting: something still has to invoke
# `council.sh status`, and nothing in this repo does so unattended (#21 is that gap). SKILL.md
# documents a watch loop for an operator who wants one; until #21 has an answer, that loop is the
# trigger.
#
# IT FIRES WHENEVER THE ALARM DOES, in either of its wordings and explained or not. Two earlier
# drafts got this wrong in the same way and it is the mistake worth naming: the first pushed only
# for an UNEXPLAINED stall, so the screen read decided whether a person was woken; the second still
# skipped the clock-wrong arm, so a peer writing `created_ms` did. Both times the alarm had been
# fixed and the push — the same event's second operator-facing output — had not, because the alarm
# was the one being looked at. What the classification changes is this notice's WORDING, never its
# existence.
#
# DE-DUPLICATED AGAINST THE MAILBOX ITSELF, within ONE room, so polling `status` does not accrue N
# notices for one stall while a room that moves and stalls again notifies afresh. Two halves, and
# an agent relocating this scan needs both: the ROOM is matched on the entry's `.slot` field with
# `==`, and within that, the key `[stall:<peer>:<turns>]` carried in the notice's `.text` separates
# one stall from the next. Dropping the first half reinstates a collision between sibling rooms
# that the body below records in full.
#
# THAT IS THE POINT OF IT, and it is why there is no latch file. Nothing confines a participant —
# SKILL.md's "The room is not a trust boundary" records all three kinds writing outside the repo
# entirely — so a latch anywhere, in the room or in the mailbox, is a file the seat the notice is
# about can pre-write, and pre-writing it is silence. De-duplicating against the mailbox makes
# suppression through THIS CHECK self-revealing instead: to stop the notice here you must put an
# entry carrying its key into the directory the supervisor reads. Weaker than preventing
# suppression, stronger than pretending to.
#
# THE CHECK IS NOT THE ONLY WAY OUT, and the list matters more than the property. Three others,
# each named here rather than left to be found — an earlier draft of this very comment claimed the
# check was the only route while listing two of them eight lines below:
#   * a CLOSED room returns early, and a closure is two files inside the room (`board/status`,
#     `board/decision.md`), so a seat can forge one and stop the push. A forged closure also makes
#     every other reader report the room decided, which is the larger pre-existing lie (#66) rather
#     than something this gate adds;
#   * a mailbox that cannot be resolved or written pushes nothing at all;
#   * upstream of this function entirely, a held time clamped to 0 removes the alarm and the push
#     together (#165).
_stall_escalate() {
  local peer="${1:-}" turns="${2:-}" held="${3:-}" note="${4:-}" key room who where mb
  command -v policy_escalate >/dev/null 2>&1 || return 0
  command -v policy_mailbox_dir >/dev/null 2>&1 || return 0
  # A closed room's floor is nobody's problem, and `decide` has already escalated the one closure
  # that needs a person. Only a LIVE room can be stalled.
  [ -z "$(c_recorded_status)" ] || return 0
  mb=$(policy_mailbox_dir) || return 0
  room=$(basename "$ROOM")
  # THE ROOM IS MATCHED AS AN EXACT FIELD, never as a filename prefix, and the distinction is the
  # whole defect. A first version globbed `council-$room-*.json`; `council.sh up` names a repeated
  # scenario `<name>-2`, so `design` and `design-2` are the ordinary pair rather than a contrived
  # one — and `council-design-*.json` matches `council-design-2-1.json`. With the same `--agents`
  # spec both rooms have the same seat names, so both wedging at turn 0 produced the same key and
  # whichever polled second pushed NOTHING, permanently.
  #
  # THE SHAPE IS AN UNANCHORED PREFIX MATCH over a scarce namespace — the same shape as the
  # test-number collisions in #149 — and what closes it is any comparison whose room segment cannot
  # bleed into the next one. THREE WERE CHECKED, and the first is the one that fails:
  #   * a tighter GLOB, `council-design-[0-9]*.json`: still matches `council-design-2-1.json`;
  #   * an ANCHORED pattern, `+([0-9]).json` under extglob or `^council-<room>-[0-9]+\.json$` as a
  #     regex: correct — it excludes the sibling, and it is what this file's own test helper uses;
  #   * an exact FIELD comparison on `.slot`: correct.
  # (An earlier draft of this comment claimed no tighter pattern could work. That was an untested
  # claim about a solution space, false, and contradicted by the anchored helper in the same commit.)
  #
  # THE EXACT FIELD IS PREFERRED over the anchored pattern for two reasons, neither of which is that
  # the other cannot work. First, an anchor over the FILENAME re-derives the room's identity from a
  # path that `policy_escalate` composed, while `.slot` is that identity as the writer recorded it —
  # one fewer place for the two to disagree. Second, `--room` is validated nowhere (council.sh
  # interpolates `$ROOM_NAME` straight into a path), so a delimiter-based key would encode a value
  # that may contain its own delimiter, and an anchored filename pattern would have to be built from
  # the same unvalidated string.
  #
  # THE ROOM IDENTITY IS `basename "$ROOM"`, so `--room a/b` and `--room b` share a slot. Contrived,
  # and it predates this scan, but it is why this says "the room as `policy_escalate` recorded it"
  # rather than "whatever the room is called".
  #
  # MATCHING `.text` AND NOT THE WHOLE ENTRY also matters: the annotation is a quote from a seat's
  # own pane and lands in `.context`, so a seat that appends a key-shaped string to its banner would
  # otherwise suppress the NEXT stall's notice. Keying on `.text`, which this code composes, leaves
  # that route closed.
  key="[stall:$peer:$turns]"
  # Fails OPEN by construction, which is the right way round for a de-duplication check: an empty
  # glob, an unreadable mailbox, a malformed entry or a missing jq all make this print nothing, and
  # a check that cannot read its own history must repeat a notice rather than skip one.
  local seen
  seen=$(jq -s --arg s "council-$room" --arg k "$key" \
           '[.[] | select(.slot == $s) | select((.text // "") | contains($k))] | length' \
           "$mb"/council-*.json 2>/dev/null) || seen=""
  case "$seen" in ''|*[!0-9]*) seen=0 ;; esac
  [ "$seen" -gt 0 ] && return 0
  # During an open barrier round the caller's `$floor` is a LABEL, not a seat — nobody holds the
  # floor and the room is waiting on everyone — so the notice must not name it as a participant.
  # A real seat is named; anything else degrades to the room, and the terminal to look at becomes
  # every terminal. The label is still a fine de-duplication key: it is stable while the round is.
  #
  # Captured and matched rather than piped into `grep -q`, for the reason ship's own guidance gives
  # about this exact shape: `-q` exits on the first hit, the writer takes a SIGPIPE, and under
  # `pipefail` the pipeline's status is then the writer's — so a present peer intermittently reads
  # as absent. Here that would only downgrade the wording, which is precisely the kind of rare,
  # harmless-looking misreport nobody ever tracks down.
  local roster; roster=$(c_peers)
  case $'\n'"$roster"$'\n' in
    *$'\n'"$peer"$'\n'*) who="$peer"; where="$peer's terminal" ;;
    *)                   who="the room's floor"; where="every participant's terminal" ;;
  esac
  # `[ -n "$peer" ]` first: with no floor holder AND an unreadable roster both sides of the `case`
  # subject are empty, which MATCHES the member pattern and named an empty seat in the notice
  # ("  has been held for 7200s"). An unnamed floor is exactly the input the fallback is for.
  [ -n "$peer" ] || { who="the room's floor"; where="every participant's terminal"; }
  mkdir -p "$mb" 2>/dev/null || true
  # The annotation goes LAST, after council's own remedies, and the quote is delimited. Spliced
  # mid-sentence it ran straight into this skill's instructions with nothing marking where the
  # participant-authored half ended — and the whole reason it is quoted at all is that a seat
  # chooses its text. On the console the evidence is last for the same reason.
  #
  # Built OUTSIDE the argument, not with a `${note:+…}` inside it: an apostrophe in the alternate
  # text ends the surrounding double-quoted word as far as bash's parser is concerned, and the
  # whole file then fails to parse. It cost a round here; the plain `if` cannot do that.
  local ctx="turn $turns; go and look at $where. A permission or first-launch trust prompt is answered IN PLACE; council.sh relaunch is only for a seat that is genuinely dead, and it discards everything that seat has read."
  if [ -n "$note" ]; then
    ctx="$ctx Quoted from the pane, not a verdict: <<$note>>"
  fi
  policy_escalate notice "council-$room" \
    "council room '$room': $who has been held for ${held}s — the room has stopped $key" \
    "$ctx" \
    >/dev/null 2>&1 || return 0
}

v_status() {
  local j verd g t floor held conf room_age alarms="" phase wait_ev="" wait_note=""
  j=$(v_verdict --json); verd=$(printf '%s' "$j" | jq -r '.verdict // empty' 2>/dev/null)
  # Which phase of the turn cycle the room is in, from the declared flow graph via the shared
  # guard (c_phase -> flow_phase over lib/room-graph.sh). This is the supervisor's "where is this
  # room" read, and the one place the guard's session-less evaluation is surfaced to a person; the
  # transport's hot paths gate on the cheap c_round_open/c_round_closed accessors, not this walk.
  # Empty means the graph has closed out — the room is decided.
  phase=$(c_phase); phase=${phase:-decided}
  # The verdict line above is the room's, the lines below are the reader's. During an open
  # barrier round those differ on purpose: `verdict` counts the whole log, and counts and ids
  # are not content -- `OPEN ROUND: posted k/N` discloses the same existence three lines down
  # -- while `on the table:` and the objection list print TEXT and so must respect the barrier.
  g=$(_graph_seen)
  # This block is what a supervisor reads instead of the room, so it has to say when it cannot
  # read the room either. Both reads above degrade to EMPTY, not to an error, and every printf
  # above then renders a blank where a number belongs: `turns 3/`, `verdict: `, no proposals,
  # `alarms: —`. That is a broken room reported as a quiet one, on the one display a supervisor
  # is told to watch — so the emptiness gets an alarm of its own rather than a blank field.
  [ -n "$verd" ] && [ -n "$g" ] \
    || alarms="$alarms 🛑 this room's state could not be computed — the lines above are incomplete (the error above says what could not be read)"
  t=$(c_turns); floor=$(c_floor_at "$t")
  held=$(( $(c_floor_held_ms) / 1000 ))
  conf=$(c_conflicts)
  printf '=== council %s ===\n' "$(basename "$ROOM")"
  c_round_open && floor="— (barrier)"
  printf 'mode %s · participants %s · turns %s/%s · floor: %s (held %ss) · turn conflicts: %s\n' \
    "$(jq -r .mode "$ROOM/roster.json")" "$(c_peers | paste -sd, -)" "$t" \
    "$(printf '%s' "$j" | jq -r .budget)" "$floor" "$held" "$conf"
  printf 'verdict: %s (nothing new for %s turns, lap %s)\n' "$verd" \
    "$(printf '%s' "$j" | jq -r .since_last_claim)" "$(printf '%s' "$j" | jq -r .lap)"
  printf 'phase: %s\n' "$phase"
  if c_round_open; then
    printf 'OPEN ROUND: posted %s/%s, waiting for %s — nobody sees their positions yet\n' \
      "$(c_round0 | wc -l | tr -d ' ')" "$(c_npeers)" \
      "$(comm -23 <(c_peers | sort) <(c_round0 | jq -r .from | sort) | paste -sd, -)"
  fi
  printf '%s' "$g" | jq -r '
    if (.live|length) == 0 then "on the table: nothing" else (.live[] | "on the table: \(.id) from \(.from) — \(.current_text[0:90])") end,
    (if (.open|length) > 0 then (.open[] | "  ✗ OPEN \(.id) (\(.from)): \(.text[0:90])") else "  no open objections" end)'
  case "$verd" in
    stuck) alarms="$alarms 🛑 STUCK: a whole lap and nothing new was said, while objections are open" ;;
    ready-to-decide) alarms="$alarms ✅ ready to decide: council.sh decide" ;;
    # `unresolved` reaches here two ways, and they need opposite things from a supervisor: the
    # budget ran out and a record is still owed, or a record already says `unresolved` and the
    # room is finished. Telling a supervisor to "write an honest unresolved" for a room that
    # has already written one invites it to run `decide --force` again and rewrite the record
    # — while the same status block exits 0 saying the room is closed.
    unresolved) if [ -n "$(c_recorded_status)" ]
                then alarms="$alarms ✅ closed as unresolved — the record is written (council.sh decision)"
                else alarms="$alarms 🛑 the turn budget is spent — write an honest unresolved"; fi ;;
  esac
  [ "$conf" -gt 0 ] && alarms="$alarms ⚠️ $conf messages lost a turn conflict (their authors must take the floor again)"
  # The held time comes from the last turn-consuming message's `sent_ms`, so it is only as good
  # as the clock of whichever seat wrote that message — and a held time longer than the ROOM has
  # existed cannot be true. It is not reported as a smaller number: clamping it would let an
  # impossible value slip under the threshold and silence a real stall.
  #
  # THE THRESHOLD IS TESTED FIRST, AND THE IMPOSSIBLE-VALUE CASE ONLY CHOOSES THE WORDING. That
  # ordering is the whole point and it must not be inverted back. `created_ms` lives in
  # roster.json, which every participant can write, so when the impossible case was an `elif`
  # ABOVE the threshold a seat could set `created_ms` to now, make `room_age` 0, and every held
  # time then exceeded it — which silently replaced a real STALL with "the clock is wrong",
  # permanently. Measured on a room genuinely stalled for two hours. A peer-writable field must
  # never be able to REMOVE an alarm; here the alarm fires on exactly the same condition it
  # always did, and the untrusted value can only change how it reads.
  #
  # The wording does not name a seat, because the one it could name would be the wrong one: the
  # value comes from the last turn-consuming message, whose author is the previous speaker,
  # while `$floor` is the seat that is waiting. `$floor` is correct for STALL, which is about
  # who holds the floor now, and it is used only there.
  #
  # A room that records no creation time (one made before `created_ms` existed) answers nothing
  # and keeps the plain threshold, which is exactly its behaviour before this branch was here.
  #
  # THE INVARIANT ABOVE IS ABOUT THE ALARMS THAT EXISTED WHEN IT WAS WRITTEN, and one alarm now
  # falls outside it. Since c_floor_held_ms learned to time a token room's first holder from
  # `created_ms`, a room that has never moved raises STALL where it used to raise nothing — and
  # for THAT case the alarm's condition is the peer-written field itself, not just its wording, so
  # a seat can switch it off by writing `created_ms` forward or by rewriting `mode` to roundtable.
  # Nothing that fired before became suppressible; this one arrives that way, which is still
  # better than the silence it replaced but is not what the paragraphs above promise. Closing it
  # means a never-moved-room alarm that does not read the floor's age at all; that is filed.
  room_age=$(c_room_age_s) || room_age=""
  if [ "$held" -gt "${COUNCIL_STALL_SECS:-900}" ]; then
    if [ -n "$room_age" ] && [ "$held" -gt "$room_age" ]; then
      alarms="$alarms 🛑 STALL: the floor has been held for ${held}s, which is longer than this room has existed (${room_age}s) — one seat's clock is wrong, so check every terminal rather than trusting the figure"
      # No terminal read on this arm: `held` is not a trustworthy number here, so nothing about a
      # seat should be concluded from it, and the threshold-first ordering the paragraph above
      # insists on stays exactly as it was. The PUSH still happens — see below.
    else
      # ONE alarm, on exactly the condition it always fired on, and then — where the seat's own
      # client announced something this check recognises — one more sentence QUOTING that. The
      # annotation never gates the alarm or the push (the header of _floor_wait_state says why),
      # so a seat cannot talk its way out of being noticed; the most it can do is change what the
      # supervisor reads before going to look, which is what `created_ms` can already do to the
      # clock wording below.
      #
      # The alarm no longer GUESSES a cause. The guess it used to make ("it may be sitting on a
      # permission prompt") was right often enough to be believed and wrong often enough to cost a
      # seat, because the two likeliest causes need opposite remedies and only one of them is
      # `relaunch`. It now names both remedies and says which case each belongs to.
      #
      # The recognition clause is CONDITIONAL, and that is not tidiness. Printed unconditionally it
      # said "nothing this check recognises explains it" in the same line as the annotation this
      # very check had just produced — the alarm denying and asserting the same fact, on the one
      # path the feature exists for. It is worded this way rather than "nothing on its terminal"
      # because the only shape recognised is an announced capacity wait, so on the commonest wedge
      # the terminal says exactly why and this code cannot read it.
      wait_ev=$(_floor_wait_state "$floor") || wait_ev=""
      alarms="$alarms 🛑 STALL: $floor has held the floor for ${held}s — the room has stopped; go and look at it. A seat sitting on a permission or first-launch trust prompt needs that prompt ANSWERED IN PLACE; council.sh relaunch is only for a seat that is genuinely dead, and it discards everything that seat has read."
      if [ -n "$wait_ev" ]; then
        wait_note="⏳ its pane carries a live ${wait_ev%%	*} banner: $(policy_park_advice) If that banner is current the seat resumes by itself, so check the terminal before relaunching — this is a quote from a pane, not a verdict. Evidence: ${wait_ev#*	}"
        alarms="$alarms $wait_note"
      else
        alarms="$alarms Nothing this check recognises explains it; only an announced capacity wait is recognised today."
      fi
    fi
    # OUTSIDE the wording branches, deliberately. Both of them are the same alarm — this room has
    # stopped — and the push is that alarm's second operator-facing output, for the supervisor who
    # is not at the console. Nesting it under one wording is how a peer-written `created_ms`, which
    # only chooses between the two, came to decide whether anyone was woken.
    _stall_escalate "$floor" "$t" "$held" "$wait_note"
  fi
  printf 'alarms:%s\n' "${alarms:- —}"
  printf 'last messages:\n'
  v_transcript | tail -3 | sed 's/^/  /'
  case "$verd" in decided|unresolved) return 0 ;; *) return 1 ;; esac
}

# The agenda's gist: its opening (first non-blank) line, with a heading marker stripped from
# that line. A detailed agenda used to be embedded whole at the top, so the record opened
# with two screens of prompt before the decision; a long one is summarised here and quoted in
# full at the end. A one-line agenda is its own gist and stays inline, unquoted twice.
#
# Take the opening line, never "the file's first heading" — that picks up a later section.
# An agenda stating the question on line 1 and continuing `## Background` recorded
# "Background" as the question, with the real one appearing only at the very bottom of the
# record, below the transcript; a `#` comment at column zero inside a fenced code block was
# mistaken for the heading the same way.
#
# The marker strip demands whitespace after the hashes, because that is what makes a heading
# a heading. Accepting none of it both mangled lines that are not headings (`#!/usr/bin/env
# bash`, `#12 ...`) and MANUFACTURED one: `#\{1,6\}` stops at six, so eight hashes came out as
# `## ...`, an exact section marker of this record, sitting above the real sections.
_agenda_gist() { # <file>
  sed -e '/^[[:space:]]*$/d' -e 'q' "$1" \
    | sed -e 's/^[[:space:]]*//' -e 's/^#\{1,6\}[[:space:]]\{1,\}//' -e 's/[[:space:]]*$//'
}
_agenda_is_long() { # <file> — more than one non-blank line
  [ "$(grep -c -v '^[[:space:]]*$' "$1")" -gt 1 ]
}

# The ADR is the room's OUTPUT. A room that did not converge writes an `unresolved` record
# listing what is still open — a valid outcome, never something to paper over.
v_decide() {
  local force=0; [ "${1:-}" = "--force" ] && force=1
  local j verd g out status
  j=$(v_verdict --json); verd=$(printf '%s' "$j" | jq -r '.verdict // empty' 2>/dev/null)
  # A record is never written from a ROSTER or a GRAPH this verb could not read. That is
  # narrower than it once said here, and the narrowing is the point: an unreadable LANE FILE
  # reaches this guard as a perfectly computable empty room, so `--force` does write a record
  # over it, saying there were no objections. Three attempts to close that door are recorded at
  # `c_all` in lib.sh, two of them reverted; do not re-derive them from this comment. Both reads
  # below can come
  # back empty rather than wrong -- `_graph` is a jq program over peer-written messages, and one
  # message of the wrong shape aborts it mid-stream -- and every renderer further down treats
  # empty input as "nothing to say" rather than as a failure. `--force` then walked straight
  # through: `verd` was empty so it did not match `ready-to-decide`, `status` came out
  # `unresolved`, and the room's one durable output was written at rc 0 with a blank verdict,
  # blank turn counts and "(there were no objections)" over a transcript showing an objection.
  #
  # A refusal is the honest outcome, and it is not a wedge: `verdict` and `claims` fail the same
  # way, loudly, and jq has already said on stderr which file it choked on. Writing a false
  # record cannot be undone by re-running anything -- a reader who believed it is not a state
  # this room can get back to.
  #
  # `verd` is checked rather than `j`'s exit status because v_verdict returns 1 for an ordinary
  # live room: its rc is a STATUS, not a success flag, and reading it as one would refuse every
  # `--force` on a room that had not converged, which is precisely the case --force exists for.
  [ -n "$verd" ] || {
    echo "council decide: this room's state could not be computed — refusing to write a record. The error above says what could not be read." >&2
    return 1
  }
  case "$verd" in
    ready-to-decide) ;;
    decided) echo "council: this room is already decided" >&2; return 3 ;;
    *) [ "$force" = 1 ] || { echo "council: verdict '$verd', the decision is not ripe. --force writes an honest unresolved." >&2; return 2; } ;;
  esac
  # A SEAT THAT OWES A POSITION MAY NOT CLOSE THE ROUND IT OWES IT TO. Closing a room writes
  # the record from the WHOLE log -- deliberately, because one holding only the writer's own
  # position would be worse than none -- and `decision` then hands that record to anyone. So
  # without this gate, `decide --force` followed by `decision` was a two-command bypass of the
  # opening barrier, available to every participant and to NO supervisor, since `decide` takes
  # `need_me`. A seat that has stated its position keeps the escape hatch; a seat that has said
  # nothing cannot buy the log with it.
  #
  # AFTER the verdict dispatch above, not before it, and that placement is load-bearing. Ahead
  # of it this gate preempted the answers v_verdict exists to give: a room whose RECORD is on
  # disk answered 2 instead of the documented 3 as soon as one lane file stopped parsing, which
  # is the same inversion v_verdict's own header records as having been introduced and reverted
  # twice. Here it guards only the record WRITE, which is all it was ever about -- an
  # already-decided room needs no gate anyway, since `decision` hands that record to anyone.
  #
  # IT REFUSES EXACTLY WHEN THE RECORD WOULD DISCLOSE A POSITION THE CALLER MAY NOT READ, which
  # is why the third test is here rather than only the first two. Without it the gate fired on a
  # round nobody had posted in at all: `c_barrier` returns `open` from its `[ "$first" = 0 ]`
  # short-circuit before it ever consults the deadline, so that round never closes on its own,
  # every seat is refused for ever, and no supervisor can run `decide` -- measured, with
  # `round_deadline_ms=1`, and the pre-gate tree wrote an honest `unresolved` record there. It
  # protected nothing while doing it: with no position in the log, `c_visible` withholds nothing
  # (measured: a seat that had posted nothing read byte-identically to the supervisor).
  #
  # So the rule is about DISCLOSURE, not about manners. When `c_round0` yields no foreign
  # position the record cannot carry one, whatever the reason -- an empty round, or a log this
  # reader cannot parse. The second of those leaves `--force` able to write a record over a log
  # it could not read, which is a REMAINDER THIS GATE DELIBERATELY DOES NOT TAKE ON: it is
  # recorded at `c_all` and in SKILL.md, three attempts at it are recorded there, and two were
  # reverted. Do not quietly make this gate the fourth.
  #
  # The first two tests fail closed. `! c_round_closed` (round not verifiably closed), never
  # `c_round_open`: a c_barrier that dies mid-function prints NEITHER word (its own header carries
  # that failure), so `c_round_open` (true only for the literal `open`) would read false and let
  # the close through exactly when the room could not be read, while `! c_round_closed` (true for
  # `open` AND for nothing) refuses it. That is reasoned, not measured -- no reachable input on
  # this tree makes c_barrier print nothing, so no test pins it. `c_posted_round0` that fails
  # prints nothing, so `-z` refuses; it is the
  # same reader `c_send` uses to refuse a second position, so the two cannot disagree about
  # whether I have spoken.
  #
  # NO ROSTER READ HERE. With roster.json emptied -- and in the other shapes that leave c_mode
  # blank -- `decide --force` already returns 1 and writes nothing, in a `token` room and a
  # `roundtable` one alike, because v_verdict cannot compute a state. Measured. It is NOT true
  # of every unusable roster: over `{...}\n{}` c_barrier answers `closed`, this gate passes, and
  # a record is written from a roster c_visible refuses to trust. That shape is left alone
  # because `recv` releases the round on it too, so a check here would close no leak.
  #
  # AND NOT ONCE A RECORD EXISTS, for the same disclosure reason: `decision` hands that record
  # to anyone, so the positions are already out and refusing the rewrite protects nothing while
  # costing the documented exit codes. Two reachable states need it. A room recorded `decided`
  # must still answer 3, which the placement above already secures. A room recorded
  # `unresolved` falls through `*)` under `--force`, and there this gate would otherwise wedge a
  # room that is already closed: a seat states a real opening position and force-closes mid-round,
  # leaving a record on disk, a FOREIGN `round: 0` position in the log and the barrier still open,
  # so every seat that has posted nothing is refused for ever on a round it can no longer join --
  # while `decision` hands that same record to any of them anyway. That is the state t7's `t7e`
  # fixture builds, and deleting this term reds it.
  #
  # It reached that state a SECOND way until the announcement became `--hand`, and the note is kept
  # because the mechanism is gone and a reader who greps for it will not find it: closing an EMPTY
  # round used to stamp the closer's own trailing `decide` message `round: 0` -- c_send did that
  # whenever the barrier was open and the sender had not posted -- so the announcement itself read
  # as a foreign opening position and gated every other seat out of ever re-closing. Measured, then.
  # `--hand` stamps `turn: null, round: null`, so a close can no longer manufacture that position;
  # t7e now has to state one for real. The term is still load-bearing for the first state above.
  #
  # The message is the ONE authoritative statement of the rule: SKILL.md describes the behaviour
  # and its cost without restating it, and t7 asserts a substring rather than a copy.
  # The last test asks for SOMEBODY ELSE'S position, and the `.from != $me` is not redundant
  # with the test before it, though it looks it. `c_posted_round0` and `c_round0` read the same
  # documents, but not the same way: the former pipes them through `jq -r … | .id | head -1`, so
  # a round-0 message in MY OWN lane carrying an empty `.id` -- which `c_send` never mints, but a
  # hand-written or harness-written lane file does -- comes back as an empty line that `$( )`
  # strips, and the second test then reads "I have not posted" about a position I did post.
  # Without this filter the gate refuses the ONE seat that had posted, telling it another seat
  # has spoken and it has not, while withholding nothing from it. Measured.
  #
  # It prints the WHOLE MESSAGE compactly rather than any field of it, and that is the third
  # attempt at this line. Each earlier one was defeated by a value whose FIRST LINE can be empty
  # while the message is not, which is all `head -1` reads:
  #
  #   The first printed no field at all -- `c_round0 | head -1`, no filter -- and leaned on
  #   `c_posted_round0` to have established that no position was mine. That reader goes through
  #   `.id`, a string the message chose, so an empty one in MY OWN lane made it report that I had
  #   not posted and the gate refused the one seat that had, while withholding nothing from it.
  #   The lesson of that one is the `.from != $me` filter, not the field.
  #
  #   The second added the filter and printed `.from`, which looked immune: it is c_all's
  #   derivation from the LANE DIRECTORY, so it is a real directory name. But `head -1` reads its
  #   FIRST LINE, and a directory name may contain a newline. A lane called $'\nz' holding a
  #   `round: 0` message made this test read empty, the
  #   gate stand down, and a seat that had posted nothing close the round and take the record
  #   with every position in it. Measured, end to end. That name cannot come from `c_send`
  #   (`c_atomic` does not mkdir), which is exactly the premise the `.id` case above rests on
  #   too, so it is the same threat and not a smaller one.
  #
  # `jq -c` emits one line per document with every control byte escaped, so the value is
  # non-empty whenever a document matched and there is no field left to be empty. c_all's own
  # header records the same class -- a peer-chosen lane name reaching a reader raw -- for its
  # error path.
  if ! c_round_closed && [ -z "$(c_posted_round0)" ] && [ -z "$(c_recorded_status)" ] \
     && [ -n "$(c_round0 | jq -c --arg me "$ME" 'select(.from != $me)' | head -1)" ]; then
    echo "council decide: another seat has stated an opening position and you have not — refusing to close a round you have not taken part in, because the record would hand you every position in it. Post your position first; the round also closes on its own once its deadline passes." >&2
    return 2
  fi
  g=$(_graph) && [ -n "$g" ] || {
    echo "council decide: this room's argument graph could not be computed — refusing to write a record. The error above says what could not be read." >&2
    return 1
  }
  out="$ROOM/board/decision.md"
  status=$([ "$verd" = ready-to-decide ] && echo decided || echo unresolved)
  {
    printf '# Decision of room `%s`\n\n' "$(basename "$ROOM")"
    printf '* status: **%s** (verdict when written: `%s`)\n' "$status" "$verd"
    printf '* participants: %s\n' "$(c_peers | paste -sd, - | sed 's/,/, /g')"
    printf '* mode: %s, rule: %s\n' "$(jq -r .mode "$ROOM/roster.json")" "$(jq -r .decide_by "$ROOM/roster.json")"
    printf '* turns: %s of %s\n' "$(printf '%s' "$j" | jq -r .turns)" "$(printf '%s' "$j" | jq -r .budget)"
    printf '* written by: %s, %s\n\n' "$ME" "$(c_now)"
    if [ -f "$ROOM/agenda.md" ]; then
      printf '## The question\n\n'
      if _agenda_is_long "$ROOM/agenda.md"; then
        printf '%s\n\n' "$(_agenda_gist "$ROOM/agenda.md")"
        printf 'The agenda is [`agenda.md`](../agenda.md), quoted in full at the end of this record.\n\n'
      else
        cat "$ROOM/agenda.md"; printf '\n'
      fi
    fi
    printf '## The decision\n\n'
    if [ "$status" = decided ]; then
      # The decision is the proposal AS AMENDED, under headings that say which part is
      # which. Rendering `current_text` here recorded only the final amendment, in the
      # amendment's own voice, so accepted items the amendment did not restate appeared
      # nowhere and the decision could only be reconstructed from the transcript.
      printf '%s\n\n' "$(printf '%s' "$g" | jq -r '.live[0]
        | if (.amends|length) == 0 then .text
          else ( [ .revisions[]
                   | if .act == "propose"
                     then "### As proposed (`\(.id)`, from \(.from))\n\n\(.text)"
                     else "### Amendment `\(.id)`, from \(.from)\n\n\(.text)" end ]
                 | join("\n\n") )
          end')"
      # Name the amendments as well as the proposal: the ids are what lets a reader index
      # this decision back into the transcript, and the amendments are usually where the
      # decision actually got its final shape.
      printf '%s\n\n' "$(printf '%s' "$g" | jq -r '.live[0]
        | "_(proposal `\(.id)` from \(.from)"
          + (if (.amends|length) > 0
             then ", as amended by " + ([.amends[] | "`\(.)`"] | join(", "))
             else "" end)
          + ")_"')"
    else
      printf 'Not accepted: the room did not converge.\n\n'
    fi
    printf '## Objections, and how they were closed\n\n'
    printf '%s' "$g" | jq -r '
      if ([.proposals[].objections[]] | length) == 0 then "* (there were no objections)" else
      (.proposals[] | . as $p | .objections[]
       | if .closed_by != null
         then "* ✓ **\(.from)** on `\(.id)`: \(.text)\n  * closed by `\(.closed_by)` — \(.closed_act) from \(.closed_by_who)"
         elif $p.dead then "* · **\(.from)** on `\(.id)`: \(.text)\n  * fell with proposal `\($p.id)`"
         else "* ✗ **\(.from)** on `\(.id)`: \(.text)\n  * **left open**" end) end'
    printf '\n'
    if [ "$status" != decided ]; then
      printf '## Left open\n\n'
      printf '%s' "$g" | jq -r 'if (.open|length) == 0 then "* (no open objections — the room ran out of turns)" else (.open[] | "* `\(.id)` from \(.from): \(.text)") end'
      printf '\n'
    fi
    printf '## Transcript\n\n'
    # c_canon, NOT v_transcript: the record is the room's durable output and must hold the
    # whole log, while `transcript` is what the seat running this may see. They differ while an
    # opening barrier round is open -- a room `--force`-closed mid-round -- AND for the room's
    # whole life whenever `roster.json` is not one JSON object, because c_visible withholds on
    # that too (its header says why). Do not narrow this to the open round: with the roster
    # damaged after the round has closed, the seat's view is its own lane and the record
    # rendered from it would be missing every other position, written at rc 0 and impossible to
    # tell from a complete one afterwards.
    c_canon | _render_transcript | sed 's/^/* /'
    if [ -f "$ROOM/agenda.md" ] && _agenda_is_long "$ROOM/agenda.md"; then
      printf '\n## The agenda in full\n\n'
      cat "$ROOM/agenda.md"
    fi
  } > "$out"
  # THE RECORD IS THE CLOSE, so nothing downstream may assume it landed. This block used to be a
  # bare `> "$out"` followed by a bare `> board/status`, and a redirect that cannot open reports
  # nothing to the shell: with `board/` unwritable, `decide` printed the record's path for a file
  # that does not exist, announced "decision written: decided" to the room, and exited 0 -- while
  # `verdict` still said `ready-to-decide` and `decision` still answered 1, because
  # `c_recorded_status` had nothing to read. Measured. That is this verb's own headline defect
  # (a verb reporting a close it did not perform) sitting one step ABOVE the announcement, and it
  # is strictly worse than the announcement case: there the room's output exists and only the wake
  # is lost, whereas here the room is told a decision was written that is not there.
  #
  # `-s` and not `-f`: the redirect creates the file at zero bytes the instant it opens, so a
  # truncated-then-failed write (a full disk, which `>` reaches after truncating an EXISTING
  # record) leaves an empty file behind that `-f` would accept. `v_decision`'s own reader uses `-s`
  # for the same reason and its header says so; keep the two in step.
  #
  # This refuses with 1 and prints NO path, which is the honest report and a DIFFERENT one from the
  # exit 4 below. 1 already means "refusing to write a record" for the two readers above it; a
  # record that could not be written belongs with them, because in every one of those cases the
  # room is not closed and stdout must not carry a path to a record a caller would then try to read.
  [ -s "$out" ] || {
    echo "council decide: the decision record could not be written to $out — the room is NOT closed and nothing has been announced. The error above says why; fix it and run decide again." >&2
    return 1
  }
  # Read the PRIOR status before overwriting it, so the escalation below can fire ONCE. `decide
  # --force` on an already-unresolved room rewrites the record idempotently; the escalation must
  # be idempotent too, or N re-forces would accrue N notices in the mailbox.
  local prev_status; prev_status=$(cat "$ROOM/board/status" 2>/dev/null || true)
  # And board/status is what every OTHER verb reads to know the room closed (c_recorded_status), so
  # a record with no status is a room that reads open to `verdict`, `status`, `claims` and the
  # room graph while its record sits on disk -- the same disagreement, one file over.
  printf '%s' "$status" > "$ROOM/board/status" || {
    echo "council decide: the record was written to $out but board/status could not be — every other verb reads that file, so the room will keep reporting itself open. The error above says why; fix it and run decide again to complete the close." >&2
    return 1
  }
  # ESC-04: an unresolved close is council's needs-human signal — the room could not converge, so
  # a person has to look. Route it to the shared escalation mailbox (the one shipyard's reporter
  # already reads) as a fire-and-forget notice, so a council escalation surfaces alongside ship's
  # from any worktree. This is the ONLY push channel council has ever had; the decision record and
  # board/status remain exactly as before, so a supervisor that polls the room still works.
  # Fire only on the FIRST close that lands unresolved (prev_status != unresolved), so re-forcing
  # an already-unresolved room does not re-notify. Best-effort by design: a mailbox that cannot be
  # resolved (not in a git repo) must never turn a written decision into a failure, and
  # policy_escalate is present only because council.sh sourced lib/policy.sh for this verb — so a
  # caller that did not is silently skipped rather than errored.
  if [ "$status" = unresolved ] && [ "$prev_status" != unresolved ] \
     && command -v policy_escalate >/dev/null 2>&1; then
    local esc_room esc_ctx
    esc_room=$(basename "$ROOM")
    esc_ctx=$(printf '%s' "$j" | jq -r '"verdict \(.verdict); turns \(.turns)/\(.budget); open objections \(.open)"' 2>/dev/null)
    policy_escalate notice "council-$esc_room" \
      "council room '$esc_room' closed unresolved — the room did not converge; a human should look" \
      "${esc_ctx:-unresolved}; record: $out" >/dev/null 2>&1 || true
  fi
  # THE ANNOUNCEMENT IS A WAKE, NOT A CLAIM ON A TURN, and it is `--hand` for that reason.
  # `decide` is a chair action taken out of band: the caller is `--me`-gated to some seat, but it
  # is acting for the room rather than taking its turn, so the rotation has nothing to say about
  # it. The record on disk is what closes the room: `c_recorded_status` is the reader every verb
  # consults for that VERDICT (v_verdict, v_claims, v_status, c_room_decided), while v_decision
  # reads `board/decision.md` directly to print it and v_decide reads `board/status` with `cat`
  # just above for its escalation's prior value -- three readers of the record, kept deliberately
  # in step rather than one. Either way this message carries no authority at all. All
  # it does is ring the peers (c_send's trailing `c_ring` loop), which is what turns each seat's
  # next `decision` poll from "after this recv times out" into "now".
  #
  # It used to be a plain send, and c_send refuses one from a peer that does not hold the floor
  # (exit 6). The exit status was discarded by `>/dev/null` on the call and never read, so the
  # commonest close there is -- a supervisor closing a room whose rotation has moved on -- rang
  # nobody and reported success. `--hand` takes the branch that precedes both the floor check and
  # the barrier check, stamping `turn: null` and `round: null`, so the refusal that was being
  # discarded can no longer happen.
  #
  # Not the `skip` exemption the issue proposed, and the difference is the turn. `skip` is exempt
  # from the floor check while still stamping `turn=$(c_turns)`, because consuming the absent
  # holder's turn is precisely what `skip` is for. This message must consume nothing: the room is
  # closed and a turn spent here is a turn stamped on top of whoever legitimately holds it, for
  # c_canon to settle against a real contribution. `--hand` is the existing mechanism for exactly
  # that shape -- out of turn, consumes no turn, does not move the floor -- so this reuses it
  # rather than widening c_send's exemption list.
  #
  # WHAT IS LEFT CAN STILL FAIL, and it must not read as a clean close. c_atomic can fail on a
  # full or read-only disk and jq can die, and `--hand` does not make a write succeed. So the
  # status is read now, and the two facts are reported apart: the record IS written (it is on
  # stdout either way, because it is the room's output and `decision` is the protocol's stop
  # signal), and the room was NOT told. This is `say`'s exit 6 in another verb -- report what was
  # established, never the claim you wanted to make -- and it is deliberately NOT a failure of the
  # close: the room is genuinely closed, and a re-run says so rather than re-closing it — 3 on a
  # `decided` record, 2 ("not ripe") on an `unresolved` one, because v_verdict answers from the
  # record and v_decide's `*)` arm catches `unresolved`. Neither re-opens the room. Do not write
  # the bare "answers 3" here: `--force` on a stuck room is the commonest way to reach exit 4, it
  # records `unresolved`, and 2 is the one status this skill tells a supervisor it MAY retry — so
  # that shorthand sent a supervisor to `--force`, which rewrites the record and posts a second
  # announcement. Measured, in the round that introduced this message.
  if ! c_send --act decide --hand --text "decision written: $status (council.sh decision)" >/dev/null; then
    printf '%s\n' "$out"
    echo "council decide: the record is written ($status) but the room was not told — the announcement could not be sent, so no seat was rung. The close stands and 'council.sh decision' serves the record. Do not re-run decide to check: it answers 3 on a decided room and 2 ('not ripe') on an unresolved one, and --force would rewrite the record and announce a second time. Wake a seat with 'council.sh say' if the room should stop sooner." >&2
    return 4
  fi
  printf '%s\n' "$out"
}

# The room's turn cycle as a declared flow graph, and c_phase / the closure predicates it needs.
# Sourced last, so c_room_ready can lean on v_verdict (defined above); the opening-gate accessors
# it shares with the transport live in lib.sh, already in scope. See lib/room-graph.sh.
. "$(dirname "${BASH_SOURCE[0]}")/room-graph.sh"
