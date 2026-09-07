#!/usr/bin/env bash
# t-adapters — the shared per-agent-kind adapter module (shared/adapters/agent-adapters.sh) on
# its own. The two CALLERS' launches are proven separately, against frozen baseline fixtures, in
# t-callers.sh; this file covers the module's API and its rendering.
#
# Everything here is a pure string read plus, for the argv assertions, three faked CLIs on PATH.
# No live agent, no terminal, no network.
#
# THE MODULE'S floor is bash 3.2, lower than this FILE's. They are different constraints and the
# distinction matters: the module is sourced in-process into shipyard-report.sh, which re-execs
# into nothing, so a bash-4+ construct in it breaks status reporting on a stock macOS shell. This
# test file is its own program and uses bash-5 conveniences freely, so it re-execs into a modern
# bash the way its sibling suites do. Section 9 is what actually holds the module's floor: it runs
# the module under /bin/bash rather than under this shell.
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ] && [ -z "${TADP_BASH_REEXEC:-}" ]; then
  for _c in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash bash; do
    _p=$(command -v "$_c" 2>/dev/null) || continue
    _v=$("$_p" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null) || continue
    [ "${_v:-0}" -ge 5 ] && exec env TADP_BASH_REEXEC=1 "$_p" "$0" "$@"
  done
  echo "t-adapters: needs bash >= 5, this one is ${BASH_VERSION:-unknown}." >&2
  exit 70
fi

set -uo pipefail
export LC_ALL=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
MOD="$DIR/../agent-adapters.sh"
FIX="$DIR/fixtures"
[ -f "$MOD" ] || { echo "t-adapters: cannot find the module at $MOD" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/adp-t.XXXXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}

# shellcheck source=../agent-adapters.sh
. "$MOD"

# --- 1. the kind set ---------------------------------------------------------------------
printf '\n── kinds ──\n'
ok "adp_kinds lists the kinds, one per line, sorted" "agy claude codex" "$(adp_kinds | tr '\n' ' ' | sed 's/ $//')"
ok "council's message form joins them" "agy,claude,codex" "$(adp_kinds | paste -sd, -)"
for k in $(adp_kinds); do
  ok "adp_known accepts '$k'" 0 "$(adp_known "$k"; echo $?)"
done
# An unknown kind is refused by every entry point, and NEVER by falling through to a default
# that would launch something. This is the check that replaced sourcing `adapters/<kind>.sh`.
ok "adp_known refuses an unknown kind"      1 "$(adp_known nonesuch; echo $?)"
ok "adp_known refuses an empty kind"        1 "$(adp_known ''; echo $?)"
ok "adp_known refuses a path-shaped kind"   1 "$(adp_known ../../pwn; echo $?)"
ok "adp_cmd refuses an unknown kind"        1 "$(ADP_PROMPT=x adp_cmd nonesuch >/dev/null 2>&1; echo $?)"
ok "adp_cmd prints nothing for an unknown kind" "" "$(ADP_PROMPT=x adp_cmd nonesuch 2>/dev/null)"
# adp_cmd's own `*)` arm, reachable only if the kind sets DRIFT — the failure mode the module's
# "add a case label in each function" instruction invites. Teach adp_known a kind adp_cmd does not
# handle and require a refusal, not an empty render at rc 0: a caller would otherwise write a
# launcher with no exec line, chmod it, start it, and report a successful launch.
drift=$( adp_known() { case "${1:-}" in halfadded) return 0 ;; *) return 1 ;; esac; }
         ADP_PROMPT=x adp_cmd halfadded; printf 'rc=%s' "$?" )
ok "adp_cmd refuses a kind adp_known accepts but it does not handle" "rc=1" "$drift"
ok "adp_protocol_mode refuses an unknown kind" 1 "$(adp_protocol_mode nonesuch >/dev/null 2>&1; echo $?)"
ok "adp_notes refuses an unknown kind"      1 "$(adp_notes nonesuch peer >/dev/null 2>&1; echo $?)"

# --- 2. protocol mode is a per-kind property, and total over the kind set -----------------
printf '\n── protocol mode ──\n'
ok "claude takes a real system prompt" system-prompt "$(adp_protocol_mode claude)"
ok "agy fuses the protocol into the goal" inline "$(adp_protocol_mode agy)"
ok "codex is told the protocol's path" reference "$(adp_protocol_mode codex)"
missing=""
for k in $(adp_kinds); do adp_protocol_mode "$k" >/dev/null 2>&1 || missing="$missing $k"; done
ok "every known kind has a mode" "" "$missing"

# --- 3. quoting --------------------------------------------------------------------------
# _adp_shq is the module's private data quoter. It must round-trip every byte through a shell,
# including the newline that `$( … | sed … )` would have eaten and that the agy fusion needs.
printf '\n── quoting ──\n'
for s in "/tmp/ro om" "sk'ill" 'a"b$c`d' 'back\slash' '-leading-dash' '' 'semi;colon&amp'; do
  q=$(_adp_shq "$s"); r=$(eval "printf '%s' $q")
  ok "shq round-trips [$s]" "$s" "$r"
done
# `'` + a + LF + LF + `'` = 5 bytes. A `$( … | sed … )` quoter returns 3 — it eats them — and the
# agy fusion below is built on keeping them, so this is the assertion that would catch a rewrite.
nl_len=$(_adp_shq "$(printf 'a')"$'\n\n' | wc -c | tr -d ' ')
ok "shq keeps trailing newlines (byte length of 'a\\n\\n' quoted)" 5 "$nl_len"

# --- 4. approval: the one thing this unification must not flatten -------------------------
# council runs `sandboxed`, shipyard runs `full`. They differ for a reason (council writes into
# a room outside its cwd; shipyard -C's into its worktree), so both spellings are pinned here.
printf '\n── approval ──\n'
codex_flags() { ( ADP_APPROVAL="$1" ADP_PROMPT=goal; adp_cmd codex ) | head -1; }
ok "codex sandboxed keeps the sandbox on" \
  'exec codex -s workspace-write -a never \' "$(codex_flags sandboxed)"
ok "codex full turns approvals off" \
  'exec codex --approve-for-me \' "$(codex_flags full)"
ok "an omitted approval defaults to the CONFINED value" \
  'exec codex -s workspace-write -a never \' "$( ( ADP_PROMPT=goal; adp_cmd codex ) | head -1 )"
ok "an unrecognised approval defaults to the confined value" \
  'exec codex -s workspace-write -a never \' "$(codex_flags nonsense)"
# claude has one unattended mode and agy one flag; both approval levels map onto them. Pinned
# against LITERALS, not against each other: comparing the two renders would agree just as happily
# if both produced nothing.
for lvl in sandboxed full; do
  ok "claude at '$lvl' renders its one unattended mode" \
    'exec claude --permission-mode auto \' "$( ( ADP_APPROVAL=$lvl ADP_PROMPT=g; adp_cmd claude ) | head -1 )"
  ok "agy at '$lvl' renders its one unattended flag" \
    'exec agy --dangerously-skip-permissions \' "$( ( ADP_APPROVAL=$lvl ADP_PROMPT=g; adp_cmd agy ) | head -1 )"
done

# --- 5. emit-iff-set: a knob only one caller uses imposes nothing on the other -------------
printf '\n── emit-iff-set ──\n'
bare=$( ADP_PROMPT=goal; adp_cmd claude )
case "$bare" in *--add-dir*) ok "no ADP_DIRS -> no --add-dir" yes "no: [$bare]" ;;
                *)           ok "no ADP_DIRS -> no --add-dir" yes yes ;; esac
case "$bare" in *-w\ *|*--remote-control*) ok "no ADP_NAME -> no session flags" yes "no: [$bare]" ;;
                *)                         ok "no ADP_NAME -> no session flags" yes yes ;; esac
case "$bare" in *--effort*) ok "no ADP_EFFORT -> no --effort" yes "no: [$bare]" ;;
                *)          ok "no ADP_EFFORT -> no --effort" yes yes ;; esac
case "$bare" in *--append-system-prompt*) ok "no ADP_PROTOCOL -> no system prompt" yes "no: [$bare]" ;;
                *)                        ok "no ADP_PROTOCOL -> no system prompt" yes yes ;; esac
nocwd=$( ADP_PROMPT=goal; adp_cmd codex )
case "$nocwd" in *' -C '*) ok "no ADP_CWD -> no -C" yes "no: [$nocwd]" ;;
                 *)        ok "no ADP_CWD -> no -C" yes yes ;; esac
# Several dirs, in order, one --add-dir each.
dirs=$( ADP_PROMPT=goal ADP_DIRS=$'/one\n/two\n/three'; adp_cmd claude | head -1 )
ok "each ADP_DIRS line gets its own --add-dir, in order" \
  "exec claude --permission-mode auto --add-dir '/one' --add-dir '/two' --add-dir '/three' \\" "$dirs"
# A blank line in the list is skipped rather than becoming an empty --add-dir.
blank=$( ADP_PROMPT=goal ADP_DIRS=$'/one\n\n/two'; adp_cmd claude | head -1 )
ok "a blank ADP_DIRS line is skipped" \
  "exec claude --permission-mode auto --add-dir '/one' --add-dir '/two' \\" "$blank"

# --- 6. the rendered text, against checked-in goldens -------------------------------------
# The goldens exist so a change to the RENDERING is visible in a diff rather than silent. They
# are not the behaviour proof — t-callers.sh is, against argv captured from the pre-change code.
printf '\n── rendered text (goldens) ──\n'
FX="$TMP/fx"; mkdir -p "$FX/ro om" "$FX/sk'ill" "$FX/work tree"
PROTO="$FX/pro to.md"
cat >"$PROTO" <<'EOP'
PROTOCOL LINE ONE $notavar `notacmd`
PROTOCOL LINE TWO
EOP
DIRS=$(printf '%s\n%s' "$FX/ro om" "$FX/sk'ill")

render() { # <pair> — the exact knobs the named caller sets for that kind
  case "$1" in
    council-claude)  ( ADP_APPROVAL=sandboxed ADP_DIRS=$DIRS ADP_PROTOCOL=$PROTO \
                       ADP_PROMPT="You are a participant in a council room. Read the agenda and join the loop."
                       adp_cmd claude ) ;;
    council-codex)   ( ADP_APPROVAL=sandboxed ADP_DIRS=$DIRS \
                       ADP_PROMPT="Read $PROTO and follow it literally. Begin."
                       adp_cmd codex ) ;;
    council-agy)     ( ADP_APPROVAL=sandboxed ADP_DIRS=$DIRS ADP_PROTOCOL=$PROTO \
                       ADP_PROMPT="Follow this protocol literally. Begin."
                       adp_cmd agy ) ;;
    shipyard-claude) ( ADP_APPROVAL=full ADP_NAME=ship-42 ADP_EFFORT=max ADP_PROTOCOL=$PROTO \
                       ADP_PROMPT='/ship #42'
                       adp_cmd claude ) ;;
    shipyard-codex)  ( ADP_APPROVAL=full ADP_CWD="$FX/work tree" \
                       ADP_PROMPT="Read and follow the supervisor protocol at $PROTO. Then invoke \$ship #42 and stay inside that workflow until its stopping condition."
                       adp_cmd codex ) ;;
  esac
}

for pair in council-claude council-codex council-agy shipyard-claude shipyard-codex; do
  got=$(render "$pair" | sed "s#$FX#@FX@#g")
  want=$(cat "$FIX/$pair.text")
  ok "rendered text matches the golden: $pair" "$want" "$got"
done

# --- 7. the shell constructs survive as SYNTAX, not as data -------------------------------
# The one silent, total failure this module can cause: single-quoting a whole argument that
# holds a command substitution. The child then launches with the literal text `$(cat …)` as its
# protocol and every seat comes up with none, while the launch still looks healthy.
printf '\n── protocol delivery ──\n'
BIN="$TMP/bin"; mkdir -p "$BIN"
for b in claude codex agy; do
  cat >"$BIN/$b" <<'EOF'
#!/usr/bin/env bash
printf '<<CMD>>\n%s\n<<END>>\n' "$(basename "$0")"
for a in "$@"; do printf '<<ARG>>\n%s\n<<END>>\n' "$a"; done
EOF
  chmod +x "$BIN/$b"
done
run() { local frag="$TMP/frag.sh"; cat >"$frag"; ( PATH="$BIN:$PATH" bash "$frag" ); }
# The argument FOLLOWING <flag> in an argv dump, by block rather than by line offset — the
# arguments here are multi-line, so counting lines would be wrong the moment one changed.
arg_after() { # <flag>; dump on stdin
  awk -v flag="$1" '
    /^<<ARG>>$/ { inblk=1; buf=""; first=1; next }
    /^<<END>>$/ { if (inblk) { if (want) { printf "%s", buf; exit }
                               if (buf == flag) want=1 }; inblk=0; next }
    inblk { if (first) { buf=$0; first=0 } else { buf=buf "\n" $0 } }'
}

sysprompt=$(render council-claude | run | arg_after --append-system-prompt)
ok "claude receives the protocol's CONTENT, not the literal \$(cat …)" \
  "PROTOCOL LINE ONE \$notavar \`notacmd\`
PROTOCOL LINE TWO" "$sysprompt"
inline=$(render council-agy | run | arg_after -i)
ok "agy fuses goal + blank line + protocol CONTENT into one argument" \
  "Follow this protocol literally. Begin.

PROTOCOL LINE ONE \$notavar \`notacmd\`
PROTOCOL LINE TWO" "$inline"
# codex has neither flag: the module must not invent one, and must not render ADP_PROTOCOL.
codex_ref=$( ADP_PROMPT=goal ADP_PROTOCOL=$PROTO; adp_cmd codex )
case "$codex_ref" in *"$PROTO"*) ok "codex does not render ADP_PROTOCOL itself" yes "no: [$codex_ref]" ;;
                     *)          ok "codex does not render ADP_PROTOCOL itself" yes yes ;; esac

# --- 8. notes, skill refs, parent detection ----------------------------------------------
printf '\n── identity and notes ──\n'
# claude's and codex's notes are byte-identical to what council printed before this module
# existed. agy's are the ONE piece of user-visible text this change rewords: the note said
# "council-launched sessions" and "The room", and a shared module may not name one of its
# callers. The substance is asserted separately below, because a golden alone would not notice
# the reword dropping the thing the note exists to say.
for k in agy claude codex; do
  ok "adp_notes for '$k' matches its golden" "$(cat "$FIX/council-$k.notes")" "$(adp_notes "$k" alice)"
done
agy_note=$(adp_notes agy alice)
for phrase in "--dangerously-skip-permissions" "file-access prompt" "always" "asks you to trust"; do
  case "$agy_note" in *"$phrase"*) ok "the agy note still says [$phrase]" yes yes ;;
                      *)           ok "the agy note still says [$phrase]" yes no ;; esac
done
case "$agy_note" in *council*) ok "the agy note names no caller (rule zero)" yes no ;;
                    *)         ok "the agy note names no caller (rule zero)" yes yes ;; esac
ok "claude invokes a skill with a slash" '/ship'     "$(adp_skill_ref claude ship)"
ok "codex invokes a skill with a dollar" '$ship'     "$(adp_skill_ref codex ship)"
ok "claude, the other skill"             '/shipyard' "$(adp_skill_ref claude shipyard)"
ok "codex, the other skill"              '$shipyard' "$(adp_skill_ref codex shipyard)"
# agy's syntax is not established here: rc 1 and no output beats a plausible guess, which would
# produce a child that starts fine and then does nothing anyone asked for.
ok "agy has no skill-reference syntax (rc)"  1  "$(adp_skill_ref agy ship >/dev/null 2>&1; echo $?)"
ok "agy has no skill-reference syntax (out)" "" "$(adp_skill_ref agy ship 2>/dev/null)"

env_kind() { ( unset CODEX_SESSION_ID CODEX_THREAD_ID CLAUDECODE CLAUDE_CODE_SESSION_ID
               [ -n "${1:-}" ] && export "$1=set"
               PATH="$TMP/empty"; adp_parent_kind ); }
mkdir -p "$TMP/empty"
ok "CODEX_SESSION_ID names a codex parent"      codex  "$(env_kind CODEX_SESSION_ID)"
ok "CODEX_THREAD_ID names a codex parent"       codex  "$(env_kind CODEX_THREAD_ID)"
ok "CLAUDECODE names a claude parent"           claude "$(env_kind CLAUDECODE)"
ok "CLAUDE_CODE_SESSION_ID names a claude parent" claude "$(env_kind CLAUDE_CODE_SESSION_ID)"
ok "no marker and nothing installed -> none"    none   "$(env_kind '')"
# A codex marker wins over a claude one: it is checked first, and that order is what shipyard
# relied on before this moved here.
both=$( unset CLAUDECODE CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID
        CODEX_SESSION_ID=x CLAUDECODE=1; PATH="$TMP/empty"; adp_parent_kind )
ok "a codex marker wins over a claude one" codex "$both"
# With no marker, what is installed decides.
mkdir -p "$TMP/onlyclaude"; printf '#!/bin/sh\n' >"$TMP/onlyclaude/claude"; chmod +x "$TMP/onlyclaude/claude"
mkdir -p "$TMP/onlycodex";  printf '#!/bin/sh\n' >"$TMP/onlycodex/codex";  chmod +x "$TMP/onlycodex/codex"
noenv() { ( unset CODEX_SESSION_ID CODEX_THREAD_ID CLAUDECODE CLAUDE_CODE_SESSION_ID
            PATH="$1"; adp_parent_kind ); }
ok "no marker, only claude installed -> claude" claude "$(noenv "$TMP/onlyclaude")"
ok "no marker, only codex installed -> codex"   codex  "$(noenv "$TMP/onlycodex")"

# --- 9. the module's declared interpreter floor, held by running rather than by assertion ------
# The module says its floor is bash 3.2 because shipyard-report.sh sources it in-process and
# re-execs into nothing. A floor stated in a comment and checked by no test is a floor that stops
# holding the moment someone reaches for an associative array, so this runs the module under
# /bin/bash — which on macOS, the platform the constraint exists for, IS 3.2 — and renders every
# kind. On a Linux runner /bin/bash is modern and this degrades to a smoke test; it says so rather
# than reporting a coverage it does not have.
printf '\n── interpreter floor (/bin/bash: %s) ──\n' \
  "$(/bin/bash -c 'echo ${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}' 2>/dev/null || echo absent)"
if [ -x /bin/bash ]; then
  floor_probe="$TMP/floor.sh"
  cat >"$floor_probe" <<PROBE
set -u
. "$MOD"
for k in \$(adp_kinds); do
  ADP_PROMPT=goal ADP_PROTOCOL=/p ADP_DIRS=/d ADP_NAME=n ADP_EFFORT=max ADP_CWD=/c \\
    adp_cmd "\$k" >/dev/null || { echo "adp_cmd \$k failed"; exit 1; }
  adp_protocol_mode "\$k" >/dev/null || { echo "adp_protocol_mode \$k failed"; exit 1; }
done
adp_known claude && adp_skill_ref claude ship >/dev/null && adp_parent_kind >/dev/null || exit 1
adp_notes codex peer >/dev/null || exit 1
echo FLOOR-OK
PROBE
  # The WHOLE combined output, not `| tail -1`. `echo FLOOR-OK` always prints last, so tailing
  # threw away every 3.2 diagnostic above it, and a bash-4 construct that is not a function's last
  # command left rc 0 — so this printed `ok`. Measured on `mapfile` and `${var^^}`, two of the
  # three constructs the module's header names: the render silently lost every --add-dir and the
  # probe passed. Comparing the whole output reds both.
  #
  # WHAT THIS STILL DOES NOT HOLD, said here so a green line is not read as more than it is: the
  # renders themselves are dropped (`adp_cmd … >/dev/null`), so the floor is held by DIAGNOSTIC
  # only. A construct that is silent on stderr and merely renders differently under 3.2 — a
  # `{1..6..2}` sequence, a `$'\uXXXX'` escape — passes here, and the goldens above cannot catch
  # it either, because they are taken under this bash-5 shell. And on a Linux runner `/bin/bash`
  # IS bash 5, so there this section proves only that the module loads and runs cleanly under a
  # modern shell; the version it prints in the heading is what tells you which of the two you got.
  ok "the module sources and renders under /bin/bash" FLOOR-OK \
    "$(/bin/bash "$floor_probe" 2>&1)"
else
  ok "/bin/bash exists to probe the floor with" yes no
fi

printf '\n'
if [ "$FAILURES" -eq 0 ]; then echo "t-adapters PASS ($CHECKS checks)"; else echo "t-adapters FAIL ($FAILURES/$CHECKS)"; exit 1; fi
