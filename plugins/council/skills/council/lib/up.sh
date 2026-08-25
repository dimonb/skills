#!/usr/bin/env bash
# up.sh — creating, listing, driving and tearing down a room.

# --- create ---------------------------------------------------------------------
# The keeper holds every bell open read-write for the life of the room. Without it a bell
# rung at a participant that is not currently in `recv` either blocks its sender or is
# lost; with it, it is buffered and delivered the instant that participant listens.
#
# Idempotent, and called from `relaunch` as well as from room creation on purpose: `down`
# kills the keeper, so a seat started back up in a torn-down room would otherwise look
# perfectly healthy while every bell rung at it went nowhere.
_keeper_ensure() { # <room-dir> <peer>...
  local room="$1"; shift
  local keep="$room/state/keeper.pid" p
  [ -s "$keep" ] && kill -0 "$(cat "$keep")" 2>/dev/null && return 0
  # Detach it from the caller's stdio COMPLETELY. A background process that keeps the
  # caller's stdout open holds any pipe reading it open too: `council.sh ... | tail`
  # then never sees EOF and hangs forever, with nothing wrong upstream. Cost one
  # mystifying "the suite hangs" during development.
  ( exec >/dev/null 2>&1 <&-
    for p in "$@"; do exec {fd}<> "$room/bell/$p.fifo"; done
    while [ -d "$room" ]; do sleep 5; done ) &
  echo $! > "$keep"
}

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
  _keeper_ensure "$room" "$@"
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
  # Resolve it here, once. The value is recorded in the roster and later baked into a
  # regenerated launcher's `cd` line by `relaunch`, so a RELATIVE one would be re-resolved
  # against whatever directory the supervisor happened to be standing in — `--cwd .` passes
  # every check and silently puts the participant somewhere else entirely.
  #
  # `CDPATH=` and `--` are both load-bearing. With CDPATH exported, `cd sub` searches it and
  # then ECHOES the directory it found, so the substitution captures two lines naming the
  # wrong directory; the launcher gets a `cd $'a\nb'` that dies on launch with nothing
  # logged, which is the failure this file spends the most words warning about. `--` stops a
  # directory named like an option: `--cwd -` otherwise resolves to $OLDPWD and echoes that.
  local cwd_in="${cwd:-$(pwd -P)}"
  cwd=$(CDPATH= cd -- "$cwd_in" 2>/dev/null && pwd -P) \
    || { echo "council up: no such directory: $cwd_in" >&2; return 2; }

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
  # `cwd` is recorded because `relaunch` bakes it into the `cd` line of the launcher it
  # regenerates, so it decides where a restarted participant RUNS. Re-deriving it then, from
  # wherever the supervisor happened to be standing, would silently move that seat to another
  # directory — and a supervisor is very often standing in a different worktree of the same
  # repo, which resolves to the same room.
  jq -n --argjson order "$(printf '%s\n' "${peers[@]}" | jq -R . | jq -s .)" \
        --argjson peers "$peers_json" --arg mode "$SC_MODE" --arg dec "$SC_DECIDE" \
        --argjson turns "$SC_TURNS" --arg sc "$scenario" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --argjson rdl "$SC_RDEADLINE" --arg cwd "$cwd" \
    '{order:$order, peers:$peers, scenario:$sc, mode:$mode, decide_by:$dec,
      order_rotate:true, turn_deadline_ms:180000, turns_budget:$turns,
      round_deadline_ms:$rdl, cwd:$cwd, created_at:$at}' \
    > "$room/roster.json"
  printf '%s\n' "${agenda:-(no agenda given)}" > "$room/agenda.md"

  # Every participant gets a protocol, including the seat the human took with --me. Only the
  # ones that get a TERMINAL get a launcher, which is what makes the launcher's existence the
  # record of that, and what `relaunch` reads it as.
  for i in "${!peers[@]}"; do
    _write_protocol "$room" "${peers[$i]}" "${roles[$i]}" "$sf" "${peers[@]}"
  done

  . "$SKILL/lib/term.sh"
  local started=0
  for i in "${!peers[@]}"; do
    # Separate statements on purpose: a `local a=… b=$a` reads $a before it is assigned
    # under `set -u`, which fails with an unbound-variable error naming a variable you can
    # see being set on the same line.
    local p kind
    p="${peers[$i]}"; kind="${kinds[$i]}"
    if [ "$p" = "$me" ]; then continue; fi
    _write_launcher "$room" "$p" "$kind" "$cwd" \
      || { echo "council up: could not write the launcher for $p" >&2; continue; }
    if ct_launch "$p" "$cwd" "$room/state/launch-$p.sh"; then started=$((started+1))
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

# The two files a participant is launched with. Both are generated from the roster and the
# skill, and NOTHING is read back out of the room — which is what lets `relaunch` regenerate
# them instead of trusting what is on disk. `up` calls them too, so there is one generator
# per file rather than a copy in each verb that would drift.
#
# The LAUNCHER exports the room, never the participant. A participant that has to set up its
# own environment gets it wrong in the order it happens to read things — observed, in the
# probe that produced this design, on the very first command.
_write_launcher() { # <room> <peer> <kind> <cwd>
  local room="$1" peer="$2" kind="$3" cwd="$4"
  # `rm -f` first, and not for tidiness: `>` FOLLOWS a symlink and writes through it, and the
  # `chmod +x` below then marks the target executable. A participant that replaces this path
  # with a link to a file outside the room gets that file overwritten with a runnable script
  # the next time the seat is relaunched. Unlinking makes the redirect create a fresh file.
  rm -f "$room/state/launch-$peer.sh"
  ( . "$SKILL/adapters/$kind.sh"
    { printf '#!/usr/bin/env bash\n'
      printf 'export COUNCIL_ROOM=%q COUNCIL_ME=%q\n' "$room" "$peer"
      printf 'cd %q || exit 1\n' "$cwd"
      adapter_cmd "$room" "$room/protocol-$peer.md" "$SKILL"
    } > "$room/state/launch-$peer.sh" ) || return 1
  chmod +x "$room/state/launch-$peer.sh"
}

# The channel rules are one file for everyone; the scenario adds only the role.
_write_protocol() { # <room> <peer> <role> <scenario-file> <peer>...
  local room="$1" peer="$2" role="$3" sf="$4"; shift 4
  # Same reason as the launcher, and worse here: this path had no existence check at all, so a
  # symlink pointing at a file that does not exist yet gets that file CREATED.
  rm -f "$room/protocol-$peer.md"
  local chan; chan=$(cat "$SKILL/protocol/_channel.md")
  { printf '%s\n' "$chan"; printf '\n## Your role: %s\n\n' "$role"; _role_block "$sf" "$role"; } \
    | sed -e "s#__ROOM__#$room#g" -e "s#__ME__#$peer#g" -e "s#__SKILL__#$SKILL#g" \
          -e "s#__PEERS__#$(printf '%s\n' "$@" | paste -sd, - | sed 's/,/, /g')#g" \
    > "$room/protocol-$peer.md"
}

# Put one seat back up.
#
# What survives a restart and what does not, because the difference matters and the docs now
# say it out loud: the floor, the lanes and every objection's open-or-closed state are
# derived from the log, so the ROOM is untouched. That seat's own knowledge is not — a fresh
# process has never read a word of the argument, and its cursors are files that outlived it,
# so `recv` hands it nothing. `protocol/_channel.md` therefore tells every participant to
# read the transcript when it starts into a room that is already running.
#
# Two things this does that a hand-rolled launch does not.
#
# Handing the launcher straight to the terminal backend — `agtermctl session new --command
# <room>/state/launch-<peer>.sh` — runs it with no login shell, so the agent CLI is not on
# the resulting PATH, `exec` fails with 127, and the session closes within a second with
# nothing logged anywhere the caller can see. It reads as the backend silently refusing.
# ct_launch wraps it the same way the first launch did.
#
# And the launcher and protocol are REGENERATED rather than re-run. Every participant is
# handed the room as a writable root (`--add-dir <room>`, all three adapters), so those two
# files are writable by the other agents in the room — and a scenario deliberately makes
# them adversarial. Re-executing a stored launcher would run whatever a participant put
# there, in a login shell, unsandboxed, in the human's own process tree. Regenerating also
# picks up adapter changes made since the room opened, which is what "killed to pick up new
# permissions" actually asks for. The cost, which is documented where the verb is: a
# hand-edited launcher or protocol is DISCARDED.
council_relaunch() {
  local peer="" cwd=""
  while [ $# -gt 0 ]; do
    case "$1" in
      # `[ $# -ge 2 ]`, not `${2:-}`: defaulting the value dodges the unbound-variable error
      # and then `shift 2` fails silently with one argument left, so `$#` never falls and the
      # loop spins at 100% CPU forever, printing nothing. A supervisor that ran
      # `relaunch <peer> --cwd $dir` with $dir empty would hang until something killed it.
      --cwd) [ $# -ge 2 ] || { echo "council relaunch: --cwd needs a directory" >&2; return 2; }
             cwd="$2"; shift 2 ;;
      -*)    echo "council relaunch: unknown option $1" >&2; return 2 ;;
      *)     [ -n "$peer" ] && { echo "council relaunch: one participant at a time" >&2; return 2; }
             peer="$1"; shift ;;
    esac
  done
  local names; names=$(jq -r '.order | join(", ")' "$ROOM/roster.json")
  [ -n "$peer" ] || { echo "council relaunch: which participant? (roster: $names)" >&2; return 2; }
  jq -e --arg p "$peer" '.order | index($p)' "$ROOM/roster.json" >/dev/null 2>&1 \
    || { echo "council relaunch: '$peer' is not in this room (roster: $names)" >&2; return 2; }

  # The launcher's CONTENT is untrusted and about to be overwritten, but its EXISTENCE is
  # still the only record of which seats were given a terminal: `up` writes one for every
  # participant except the one the human took with --me.
  [ -f "$ROOM/state/launch-$peer.sh" ] || {
    echo "council relaunch: no launcher for '$peer' — that seat was never given a terminal." >&2
    echo "                  it is the seat you took yourself with --me, so there is nothing to restart." >&2
    return 3; }

  # Everything below comes out of roster.json, which lives IN the room — so every participant
  # can write it, and these values choose a file to source, a file to render, and a directory
  # to run in. Validate the shape before use, never after.
  #
  # Be clear about what this buys, because the measured answer is smaller than it looks: it
  # removes the easiest path, not the participant's ability to reach you. A participant is an
  # agent running as you with approval prompts turned off by construction — see the trust
  # note in SKILL.md. This is blast-radius reduction, not containment.
  _plain() { case "$1" in ''|*[!A-Za-z0-9_-]*) return 1 ;; *) return 0 ;; esac; }

  local -a roster=(); local q
  while IFS= read -r q; do [ -n "$q" ] && roster+=("$q"); done < <(jq -r '.order[]' "$ROOM/roster.json")
  local kind role scenario
  kind=$(jq -r --arg p "$peer" '.peers[]? | select(.name==$p) | .kind' "$ROOM/roster.json" | head -1)
  role=$(jq -r --arg p "$peer" '.peers[]? | select(.name==$p) | .role' "$ROOM/roster.json" | head -1)
  scenario=$(jq -r '.scenario // empty' "$ROOM/roster.json")
  [ -n "$kind" ] && [ -n "$scenario" ] \
    || { echo "council relaunch: this room does not record which agent plays '$peer' — it cannot be regenerated" >&2; return 2; }
  # A bare name only. `..` in either of these reaches out of the skill and picks a file the
  # participant planted; both are then sourced or rendered by the supervisor.
  _plain "$kind" \
    || { echo "council relaunch: roster names an implausible agent kind for '$peer' — refusing to source it" >&2; return 2; }
  _plain "$scenario" \
    || { echo "council relaunch: roster names an implausible scenario — refusing to render from it" >&2; return 2; }
  [ -n "$role" ] && [ "$role" != null ] || role=any
  _plain "$role" \
    || { echo "council relaunch: roster names an implausible role for '$peer'" >&2; return 2; }
  [ -f "$SKILL/adapters/$kind.sh" ] \
    || { echo "council relaunch: this skill has no adapter for '$kind' any more" >&2; return 2; }
  local sf="$SKILL/scenarios/$scenario.md"
  [ -f "$sf" ] \
    || { echo "council relaunch: this skill has no scenario '$scenario' any more — the protocol cannot be regenerated" >&2; return 2; }
  # Peer names are interpolated into a `#`-delimited sed program when the protocol is
  # rendered, so a name carrying `#` breaks out of the s-command into arbitrary sed script.
  for q in "${roster[@]}"; do
    _plain "$q" \
      || { echo "council relaunch: roster holds an implausible participant name ('$q') — refusing to render a protocol from it" >&2; return 2; }
  done

  # The cwd is BAKED INTO the regenerated launcher's `cd` line, so it decides where the
  # participant runs — not merely where its terminal opens. That is why it is recorded in the
  # roster at `up` rather than re-derived from wherever the supervisor happens to be standing,
  # and why it is resolved to an absolute path before anyone stores or uses it.
  [ -n "$cwd" ] || cwd=$(jq -r '.cwd // empty' "$ROOM/roster.json")
  [ -n "$cwd" ] || { echo "council relaunch: this room predates the recorded cwd — pass --cwd <dir>" >&2; return 2; }
  local cwd_in="$cwd"
  cwd=$(CDPATH= cd -- "$cwd_in" 2>/dev/null && pwd -P) \
    || { echo "council relaunch: no such directory: $cwd_in" >&2; return 2; }

  . "$SKILL/lib/term.sh"
  # A seat can be relaunched after `down`, which killed the keeper along with the terminals.
  # Without it every bell rung at this participant is lost while the room looks healthy.
  _keeper_ensure "$ROOM" "${roster[@]}"
  # Close whatever still answers to this peer BEFORE regenerating and starting the
  # replacement. A terminal is addressed by name, and ct_launch does not check whether that
  # name is taken: launching over a live one leaves two sessions called the same thing, of
  # which ct_target keeps the first — quite possibly the one that is already dead. Closing
  # first also means the old process cannot write back over the inputs between the
  # regeneration and the launch.
  #
  # What you see here differs by backend, and both are normal. On agterm a crashed
  # participant leaves its session LISTED (`--wait`, so the crash stays readable), so this
  # finds it and prints `terminal closed`. On tmux the window died with the process, so
  # ct_kill simply reports no live terminal and prints nothing. Neither blocks the launch.
  ct_kill "$peer" 2>/dev/null && echo "terminal closed: $peer"
  _write_launcher "$ROOM" "$peer" "$kind" "$cwd" \
    || { echo "council relaunch: could not write the launcher for '$peer'" >&2; return 1; }
  _write_protocol "$ROOM" "$peer" "$role" "$sf" "${roster[@]}" \
    || { echo "council relaunch: could not write the protocol for '$peer'" >&2; return 1; }
  ct_launch "$peer" "$cwd" "$ROOM/state/launch-$peer.sh" \
    || { echo "council relaunch: could not start a terminal for '$peer'" >&2; return 1; }
  printf 'relaunched: %s (%s/%s) in container %s, cwd %s\n' "$peer" "$kind" "$role" "$(ct_container)" "$cwd"
  printf 'launcher and protocol regenerated; it reads the transcript and rejoins where the log stands.\n'
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
