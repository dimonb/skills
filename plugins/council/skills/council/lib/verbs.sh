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
  [ -f "$ROOM/board/decision.md" ] || {
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
  if [ "$until_floor" = 1 ] && [ "$(c_barrier)" = open ] && [ -z "$(c_posted_round0)" ]; then
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
      # Posted already, round still open: keep waiting — not for a turn, but for the round
      # to complete, which is what releases everyone else's positions.
      if [ "$(c_barrier)" != open ] && [ "$(c_floor)" = "$ME" ]; then return 0; fi
    elif [ "$got" = 1 ]; then return 0; fi
    [ "$(c_ms)" -ge "$deadline" ] && break
    c_bell_wait 0.5
  done
  return 4
}

v_floor() {
  local t f last age
  if [ "$(c_barrier)" = open ]; then
    printf 'round=0 (barrier) posted=%s/%s waiting=%s conflicts=%s\n' \
      "$(c_round0 | wc -l | tr -d ' ')" "$(c_npeers)" \
      "$(comm -23 <(c_peers | sort) <(c_round0 | jq -r .from | sort) | paste -sd, -)" \
      "$(c_conflicts)"
    return 0
  fi
  t=$(c_turns); f=$(c_floor_at "$t"); last=$(c_last_turn_ms)
  age=$(( $(c_ms) - last )); [ "$last" = 0 ] && age=0
  printf 'turns=%s floor=%s next=%s held_ms=%s conflicts=%s\n' \
    "$t" "$f" "$(c_floor_at $((t+1)))" "$age" "$(c_conflicts)"
}

v_order() { if [ "${1:-}" = "--ids" ]; then c_canon | jq -r '.id'; else c_canon; fi; }

v_transcript() {
  c_canon | jq -r '"[\(.from) \(.act)\(if (.refs|length)>0 then " →"+(.refs|join(",")) else "" end)\(if .valid then "" else " (out of turn)" end)] \(.text)"'
}

_graph() { c_canon | jq -s -f "$SKILL/lib/claims.jq"; }

v_claims() {
  local g; g=$(_graph) || return 1
  [ "${1:-}" = "--raw" ] && { printf '%s\n' "$g"; return 0; }
  # Turns from c_turns here too. The graph counts turn-claiming messages only, so in a
  # roundtable room it is short by the whole opening lap, and `claims` and `verdict` printed
  # two different turn counts for one room.
  #
  # The second field is the turn a claim STAMPED, which is not the window `verdict` reports
  # and no longer has anything to do with it: a barrier position and a `--hand` claim stamp
  # no turn, so this reads -1 in rooms whose every claim is real. Labelled for what it is,
  # rather than left looking like a contradiction of the verdict line.
  printf '%s' "$g" | jq -r --argjson turns "$(c_turns)" '
    "turns: \($turns)   last claim that stamped a turn: \(.last_claim_turn)",
    (if .decided then "DECIDED by message \(.decided)" else empty end),
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
  local g n budget turns live open since win lap v recorded
  g=$(_graph) || return 1
  # Held to digits, not `// 30` and not jq's `type == "number"`: a string is truthy in jq so
  # the alternative never fires, and a JSON number is not a bash integer -- `2.5` and `1e400`
  # are numbers, and both make the `[ -ge ]` below error, which silently disables the room's
  # only stop condition and puts the same value into `--argjson`. roster.json is peer-writable.
  n=$(c_npeers); budget=$(c_int_field turns_budget 30)
  read -r decided live open <<<"$(printf '%s' "$g" | jq -r '[(.decided // "-"), (.live|length), (.open|length)] | @tsv')"
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
  # A room is closed when its RECORD says so, never because a `decide` message exists.
  # `board/status` is the whole condition, and the decide message is not part of it.
  #
  # It is tempting to require BOTH, as a belt-and-braces reading of "the record was written
  # AND somebody ran decide". That is wrong, and measurably so: v_decide writes the record
  # and board/status FIRST and sends the message last, and that send can legitimately fail --
  # c_send refuses a sender that does not hold the floor (rc 6), which is the ordinary case
  # for `decide --force` on a stuck room, and v_decide does not check it. Requiring the
  # message leaves a room that has genuinely closed as `unresolved`, record on disk,
  # reporting `deliberating` for ever.
  #
  # That is not hypothetical and it is not new: it is what the code did BEFORE this change,
  # which required the message via `$decided`. A `--force` close by anyone not holding the
  # floor -- the ordinary way a stuck room gets closed -- read back as a live room. So the
  # same reader broke the rule twice, in opposite directions: closed when it was not, and
  # open when it was. t9f's fourth case pins this half.
  #
  # `c_slurp_raw` returns `0` for a MISSING file -- it has to, it is a reader with nothing to
  # report -- and the old `[ "$v" = 0 ] && v=decided` mapped exactly that onto `decided`. So a
  # bare `{"act":"decide"}` written into any lane made the room report itself closed and
  # decided, rc 0, while holding a live proposal and having written no decision record at all.
  # rc 0 is documented as "the room is closed" and is what a supervising session branches on,
  # so nothing anywhere said otherwise. That is issue #66's third reproduction; it is NOT an
  # author-identity bug -- it reproduces identically with an honest `.from` -- and it directly
  # contradicted this file's own documented rule, that the recorded status is written to
  # `board/status` and not re-derived from the presence of a `decide` message.
  #
  # Absent, unreadable or holding anything else, `board/status` therefore means NOT CLOSED and
  # the room falls through to its real verdict. Only the two words `v_decide` writes are
  # believed -- `board/status` is in the room like every other file, so an unexpected value is
  # treated as absent, the same rule applied to every other untrusted room input.
  #
  # This is the only caller of c_slurp_raw. If a second one ever appears, it inherits the
  # missing-file-reads-as-0 trap and needs its own decision about what absence means.
  recorded=$(c_slurp_raw "$ROOM/board/status")
  case "$recorded" in decided|unresolved) ;; *) recorded="" ;; esac
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
        live:(.live|length), open:(.open|length), open_ids:[.open[].id], decided:.decided}'
  else
    printf '%s  turns %s/%s  nothing new for %s turns (lap %s)  live proposals %s  open objections %s\n' \
      "$v" "$turns" "$budget" "$since" "$lap" "$live" "$open"
  fi
  case "$v" in decided|unresolved) return 0 ;; stuck) return 2 ;; *) return 1 ;; esac
}

v_status() {
  local j verd g t floor last held conf alarms=""
  j=$(v_verdict --json); verd=$(printf '%s' "$j" | jq -r .verdict)
  g=$(_graph)
  t=$(c_turns); floor=$(c_floor_at "$t"); last=$(c_last_turn_ms)
  held=$([ "$last" = 0 ] && echo 0 || echo $(( ($(c_ms) - last) / 1000 )))
  conf=$(c_conflicts)
  printf '=== council %s ===\n' "$(basename "$ROOM")"
  [ "$(c_barrier)" = open ] && floor="— (barrier)"
  printf 'mode %s · participants %s · turns %s/%s · floor: %s (held %ss) · turn conflicts: %s\n' \
    "$(jq -r .mode "$ROOM/roster.json")" "$(c_peers | paste -sd, -)" "$t" \
    "$(printf '%s' "$j" | jq -r .budget)" "$floor" "$held" "$conf"
  printf 'verdict: %s (nothing new for %s turns, lap %s)\n' "$verd" \
    "$(printf '%s' "$j" | jq -r .since_last_claim)" "$(printf '%s' "$j" | jq -r .lap)"
  if [ "$(c_barrier)" = open ]; then
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
    unresolved) alarms="$alarms 🛑 the turn budget is spent — write an honest unresolved" ;;
  esac
  [ "$conf" -gt 0 ] && alarms="$alarms ⚠️ $conf messages lost a turn conflict (their authors must take the floor again)"
  [ "$held" -gt "${COUNCIL_STALL_SECS:-900}" ] && alarms="$alarms 🛑 STALL: $floor has held the floor for ${held}s — check its terminal, it may be sitting on a permission prompt"
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
  j=$(v_verdict --json); verd=$(printf '%s' "$j" | jq -r .verdict)
  case "$verd" in
    ready-to-decide) ;;
    decided) echo "council: this room is already decided" >&2; return 3 ;;
    *) [ "$force" = 1 ] || { echo "council: verdict '$verd', the decision is not ripe. --force writes an honest unresolved." >&2; return 2; } ;;
  esac
  g=$(_graph); out="$ROOM/board/decision.md"
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
    v_transcript | sed 's/^/* /'
    if [ -f "$ROOM/agenda.md" ] && _agenda_is_long "$ROOM/agenda.md"; then
      printf '\n## The agenda in full\n\n'
      cat "$ROOM/agenda.md"
    fi
  } > "$out"
  printf '%s' "$status" > "$ROOM/board/status"
  c_send --act decide --text "decision written: $status (council.sh decision)" >/dev/null
  printf '%s\n' "$out"
}
