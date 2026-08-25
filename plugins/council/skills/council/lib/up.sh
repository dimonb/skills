#!/usr/bin/env bash
# up.sh — creating, listing, driving and tearing down a room.

# --- create ---------------------------------------------------------------------
_mkroom() { # <room-dir> <peer>...
  local room="$1"; shift
  mkdir -p "$room"/{bell,state,board,log,lane,cursor} || return 1
  local p q
  for p in "$@"; do
    mkdir -p "$room/lane/$p" "$room/cursor/$p"
    [ -p "$room/bell/$p.fifo" ] || mkfifo "$room/bell/$p.fifo"
    for q in "$@"; do [ "$q" = "$p" ] || printf 0 > "$room/cursor/$p/$q"; done
    printf 0 > "$room/state/$p.seq"; printf 0 > "$room/state/$p.lamport"
  done
  # The keeper holds every bell open read-write for the life of the room. Without it a
  # bell rung at a participant that is not currently in `recv` either blocks its sender or
  # is lost; with it, it is buffered and delivered the instant that participant listens.
  local keep="$room/state/keeper.pid"
  if [ ! -s "$keep" ] || ! kill -0 "$(cat "$keep")" 2>/dev/null; then
    # Detach it from the caller's stdio COMPLETELY. A background process that keeps the
    # caller's stdout open holds any pipe reading it open too: `council.sh ... | tail`
    # then never sees EOF and hangs forever, with nothing wrong upstream. Cost one
    # mystifying "the suite hangs" during development.
    ( exec >/dev/null 2>&1 <&-
      for p in "$@"; do exec {fd}<> "$room/bell/$p.fifo"; done
      while [ -d "$room" ]; do sleep 5; done ) &
    echo $! > "$keep"
  fi
}

_scenario_meta() { # <file> -> shell assignments
  python3 - "$1" <<'PY'
import sys, re
src = open(sys.argv[1]).read()
m = re.match(r"^---\n(.*?)\n---\n", src, re.S)
fm = m.group(1) if m else ""
def get(k, d=""):
    mm = re.search(r"^%s:\s*(.*)$" % k, fm, re.M)
    return mm.group(1).strip() if mm else d
roles = get("roles", "[]").strip("[]")
roles = [r.strip().strip("'\"") for r in roles.split(",") if r.strip()]
print("SC_MODE=%s" % (get("mode", "token") or "token"))
print("SC_DECIDE=%s" % (get("decide_by", "unanimous") or "unanimous"))
print("SC_TURNS=%s" % (get("turns", "30") or "30"))
print("SC_ROLES='%s'" % " ".join(roles))
print("SC_RDEADLINE=%s" % (get("round_deadline_ms", "600000") or "600000"))
print("SC_TITLE='%s'" % get("title", "").replace("'", ""))
PY
}
_role_block() { # <scenario-file> <role>
  python3 - "$1" "$2" <<'PY'
import sys, re
src, role = open(sys.argv[1]).read(), sys.argv[2]
blocks = re.split(r"^## role:\s*", src, flags=re.M)[1:]
for b in blocks:
    name, _, body = b.partition("\n")
    if name.strip() == role:
        print(body.strip()); break
PY
}

council_up() {
  local scenario="" agents="" turns="" cwd="" agenda="" me="${COUNCIL_ME:-}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --scenario) scenario="$2"; shift 2 ;;
      --agents)   agents="$2"; shift 2 ;;
      --turns)    turns="$2"; shift 2 ;;
      --cwd)      cwd="$2"; shift 2 ;;
      @*)         agenda=$(cat "${1#@}") || return 1; shift ;;
      *)          agenda="$1"; shift ;;
    esac
  done
  [ -n "$scenario" ] || { echo "council up: needs --scenario (available: $(ls "$SKILL/scenarios" | sed 's/\.md$//' | paste -sd, -))" >&2; return 2; }
  [ -n "$agents" ]   || { echo "council up: needs --agents, for example claude,codex,agy" >&2; return 2; }
  local sf="$SKILL/scenarios/$scenario.md"
  [ -f "$sf" ] || { echo "council up: no such scenario '$scenario'" >&2; return 2; }
  eval "$(_scenario_meta "$sf")"
  [ -n "$turns" ] && SC_TURNS="$turns"
  cwd="${cwd:-$(pwd -P)}"

  local base; base=$(room_base) || return 1
  local rname="${ROOM_NAME:-$scenario}" room="$base/${ROOM_NAME:-$scenario}" n=2
  while [ -d "$room" ]; do room="$base/$rname-$n"; n=$((n+1)); done
  rname=$(basename "$room")

  # roster: peer names and the agent kind behind each
  local -a peers=() kinds=() roles=()
  local spec name kind i=0
  IFS=',' read -ra SPECS <<<"$agents"
  for spec in "${SPECS[@]}"; do
    spec="${spec// /}"; [ -n "$spec" ] || continue
    case "$spec" in *=*) name="${spec%%=*}"; kind="${spec#*=}" ;; *) name="$spec"; kind="$spec" ;; esac
    local u="$name" k=2
    while printf '%s\n' ${peers+"${peers[@]}"} | grep -qx "$u"; do u="$name-$k"; k=$((k+1)); done
    [ -f "$SKILL/adapters/$kind.sh" ] || { echo "council up: no adapter for '$kind' (available: $(ls "$SKILL/adapters" | sed 's/\.sh$//' | paste -sd, -))" >&2; return 2; }
    peers+=("$u"); kinds+=("$kind")
    roles+=("$(printf '%s\n' $SC_ROLES | sed -n "$((i+1))p")"); [ -n "${roles[$i]}" ] || roles[$i]=any
    i=$((i+1))
  done
  [ "${#peers[@]}" -ge 2 ] || { echo "council up: a room with one participant is a monologue" >&2; return 2; }

  _mkroom "$room" "${peers[@]}" || return 1
  ROOM="$room"   # term.sh pins the container inside the room
  local peers_json; peers_json=$(for i in "${!peers[@]}"; do
      jq -n --arg n "${peers[$i]}" --arg k "${kinds[$i]}" --arg r "${roles[$i]}" '{name:$n,kind:$k,role:$r}'
    done | jq -s .)
  jq -n --argjson order "$(printf '%s\n' "${peers[@]}" | jq -R . | jq -s .)" \
        --argjson peers "$peers_json" --arg mode "$SC_MODE" --arg dec "$SC_DECIDE" \
        --argjson turns "$SC_TURNS" --arg sc "$scenario" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson rdl "$SC_RDEADLINE" \
    '{order:$order, peers:$peers, scenario:$sc, mode:$mode, decide_by:$dec,
      order_rotate:true, turn_deadline_ms:180000, turns_budget:$turns,
      round_deadline_ms:$rdl, created_at:$at}' \
    > "$room/roster.json"
  printf '%s\n' "${agenda:-(no agenda given)}" > "$room/agenda.md"

  # protocols: the channel rules are one file for everyone, the scenario adds only the role
  local chan; chan=$(cat "$SKILL/protocol/_channel.md")
  for i in "${!peers[@]}"; do
    { printf '%s\n' "$chan"; printf '\n## Your role: %s\n\n' "${roles[$i]}"; _role_block "$sf" "${roles[$i]}"; } \
      | sed -e "s#__ROOM__#$room#g" -e "s#__ME__#${peers[$i]}#g" -e "s#__SKILL__#$SKILL#g" \
            -e "s#__PEERS__#$(printf '%s\n' "${peers[@]}" | paste -sd, - | sed 's/,/, /g')#g" \
      > "$room/protocol-${peers[$i]}.md"
  done

  # launchers: the LAUNCHER exports the room, never the participant. A participant that has
  # to set up its own environment gets it wrong in the order it happens to read things —
  # observed, in the probe that produced this design, on the very first command.
  . "$SKILL/lib/term.sh"
  local started=0
  for i in "${!peers[@]}"; do
    # Separate statements on purpose: a `local a=… b=$a` reads $a before it is assigned
    # under `set -u`, which fails with an unbound-variable error naming a variable you can
    # see being set on the same line.
    local p kind launcher
    p="${peers[$i]}"; kind="${kinds[$i]}"; launcher="$room/state/launch-$p.sh"
    if [ "$p" = "$me" ]; then continue; fi
    ( . "$SKILL/adapters/$kind.sh"
      { printf '#!/usr/bin/env bash\n'
        printf 'export COUNCIL_ROOM=%q COUNCIL_ME=%q\n' "$room" "$p"
        printf 'cd %q || exit 1\n' "$cwd"
        adapter_cmd "$room" "$room/protocol-$p.md" "$SKILL"
      } > "$launcher" )
    chmod +x "$launcher"
    if ct_launch "$p" "$cwd" "$launcher"; then started=$((started+1))
    else echo "council up: could not launch participant $p" >&2; fi
  done

  printf 'ROOM: %s\n' "$room"
  printf 'scenario %s · mode %s · rule %s · budget %s turns\n' "$scenario" "$SC_MODE" "$SC_DECIDE" "$SC_TURNS"
  [ "$SC_MODE" = roundtable ] && printf 'the first lap runs as a barrier: positions are written at once and nobody sees anyone else until the round completes\n'
  true
  printf 'participants: '; for i in "${!peers[@]}"; do printf '%s(%s/%s) ' "${peers[$i]}" "${kinds[$i]}" "${roles[$i]}"; done; printf '\n'
  printf 'terminals started: %s in container %s\n' "$started" "$(ct_container)"
  [ -n "$me" ] && printf 'you take part yourself as: %s\n' "$me"
  # De-duplicate by adapter KIND, never with `sort -u` over the lines. These notes are
  # multi-line, and sorting them lifts every continuation line above the line it continues:
  # under LC_ALL=C an indented line sorts before the sentence it belongs to, so the one
  # instruction the human has to act on came out shuffled and unreadable.
  local shown=""
  for i in "${!kinds[@]}"; do
    case " $shown " in *" ${kinds[$i]} "*) continue ;; esac
    shown="$shown ${kinds[$i]}"
    ( . "$SKILL/adapters/${kinds[$i]}.sh"; adapter_notes "${peers[$i]}" )
  done
  printf '\nwatch:  council.sh status --room %s\nspeak:  council.sh say <peer> "..." --room %s\n' "$rname" "$rname"
}

council_rooms() {
  local base; base=$(room_base) || return 1
  [ -d "$base" ] || { echo "no rooms"; return 0; }
  local d
  for d in "$base"/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"
    printf '%-24s %s\n' "$(basename "$d")" \
      "$(COUNCIL_ROOM="$d" bash "$SKILL/council.sh" verdict 2>/dev/null || true)"
  done
}

# The out-of-band channel: the room reaches a participant that is IN recv; this reaches one
# that is busy working. Flattened to one line — a literal newline submits early.
council_say() {
  local peer="${1:?council say: to whom}"; shift
  local text; case "${1:-}" in @*) text=$(cat "${1#@}") ;; *) text="$*" ;; esac
  [ -n "$text" ] || { echo "council say: empty message" >&2; return 2; }
  . "$SKILL/lib/term.sh"
  local one; one=$(printf '[supervisor] %s' "$text" | tr '\n' ' ')
  # Confirm by counting our own marker in the pane, not by diffing its last lines: an agent
  # that is mid-turn shows the queued message ABOVE the prompt, so a tail diff reports
  # "unconfirmed" for a message that plainly arrived. The marker can still scroll out of a
  # busy pane, so this says "sent" rather than pretending to certainty.
  local nb na full
  nb=$(ct_capture "$peer" 2>/dev/null | grep -c '\[supervisor\]')
  ct_type "$peer" "$one" || { echo "council say: participant '$peer' has no live terminal" >&2; return 3; }
  sleep 0.3; ct_submit "$peer"; sleep 1.5
  full=$(ct_capture "$peer" 2>/dev/null); na=$(printf '%s' "$full" | grep -c '\[supervisor\]')
  if [ "$na" -gt "$nb" ]; then
    printf '%s\n' "$full" | grep -q 'to be submitted after' && echo "queued (the participant is busy; it lands on the next turn boundary)" || echo "delivered"
  else
    echo "sent, but the pane shows no confirmation — look at the terminal of that participant"
  fi
}

council_down() {
  local purge=0; [ "${1:-}" = "--purge" ] && purge=1
  . "$SKILL/lib/term.sh"
  local p
  for p in $(jq -r '.order[]' "$ROOM/roster.json"); do
    ct_kill "$p" 2>/dev/null && echo "terminal closed: $p"
  done
  local keep="$ROOM/state/keeper.pid"
  [ -s "$keep" ] && kill "$(cat "$keep")" 2>/dev/null
  if [ "$purge" = 1 ]; then
    # The room IS the record — the ADR and the transcript live in it. Deleting it throws
    # away the only durable output the room produced, so it takes an explicit flag.
    rm -rf "$ROOM"; echo "room deleted: $ROOM"
  else
    echo "room kept: $ROOM  (decision: $ROOM/board/decision.md)"
  fi
}
