#!/usr/bin/env bash
# verbs.sh — the reading and speaking verbs. Sourced by council.sh with the room and the
# transport already in scope.

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
  printf '%s' "$g" | jq -r '
    "turns: \(.turns)   last substantive claim at turn: \(.last_claim_turn)",
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
  local g n budget turns last decided live open since lap v
  g=$(_graph) || return 1
  n=$(c_npeers); budget=$(jq -r '.turns_budget // 30' "$ROOM/roster.json")
  read -r _gt last decided live open <<<"$(printf '%s' "$g" | jq -r '[.turns, .last_claim_turn, (.decided // "-"), (.live|length), (.open|length)] | @tsv')"
  # Turns come from c_turns, not from the graph: the graph counts turn-claiming messages
  # and knows nothing about a completed barrier round, which consumes a whole lap without
  # any of its positions claiming a turn. Mixing the two produced a room "minus one turn
  # with nothing new said" — a negative age that no branch below reads correctly.
  turns=$(c_turns)
  since=$(( turns - (last < 0 ? 0 : last) )); lap=$n
  if   [ "$decided" != "-" ]; then v=$(c_slurp "$ROOM/board/status"); [ "$v" = 0 ] && v=decided
  elif [ "$turns" -ge "$budget" ]; then v=unresolved
  elif [ "$live" = 0 ]; then v=no-proposal
  elif [ "$open" -gt 0 ] && [ "$last" -ge 0 ] && [ "$since" -ge "$lap" ]; then v=stuck
  elif [ "$open" = 0 ] && [ "$live" = 1 ] && [ "$last" -ge 0 ] && [ "$since" -ge "$lap" ]; then v=ready-to-decide
  else v=deliberating
  fi
  if [ "${1:-}" = "--json" ]; then
    printf '%s' "$g" | jq -c --arg v "$v" --argjson since "$since" --argjson lap "$lap" --argjson budget "$budget" \
      '{verdict:$v, turns:.turns, budget:$budget, since_last_claim:$since, lap:$lap,
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
    [ -f "$ROOM/agenda.md" ] && { printf '## The question\n\n'; cat "$ROOM/agenda.md"; printf '\n'; }
    printf '## The decision\n\n'
    if [ "$status" = decided ]; then
      printf '%s\n\n' "$(printf '%s' "$g" | jq -r '.live[0].current_text')"
      printf '_(proposal `%s` from %s)_\n\n' "$(printf '%s' "$g" | jq -r '.live[0].id')" "$(printf '%s' "$g" | jq -r '.live[0].from')"
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
  } > "$out"
  printf '%s' "$status" > "$ROOM/board/status"
  c_send --act decide --text "decision written: $status (board/decision.md)" >/dev/null
  printf '%s\n' "$out"
}
