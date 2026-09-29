#!/usr/bin/env bash
# t-turn — the shared turn-state read and the delivery verdict (agent-adapters.sh).
#
# PROVENANCE. Every property here traces to one shipped defect: the parent's directive channel
# decided that a message had landed from a before/after screen DIFF. Typing always changes the
# screen, so the diff was non-empty whether or not the submit took, and a directive left sitting
# UNSENT in the input box reported as delivered — twice in one night on two different slots, each
# time leaving a child that read as healthy and idle. The fix is an ANCHORED state read, sampled.
#
# WHY THE FIXTURES ARE REAL CAPTURES. The anchor is a claim about what real clients render, and
# both ways of getting it wrong are invisible without evidence: too loose restores the false
# confirmation, too tight makes a healthy running turn read as not-running, so the commonest
# healthy path alarms and an operator learns to ignore the signal. So the screens under test are
# live captures of both admitted kinds — see fixtures/panes.notes for how each was taken and which
# are derived rather than verbatim.
#
# The four ADVERSARIAL fixtures are the point of the file. Each one carries the turn marker
# somewhere the anchor must refuse to read it, and each corresponds to a way the old unanchored
# search was fooled:
#   * the marker inside the composer's first line (a typed, unsubmitted directive);
#   * the marker inside a WRAPPED continuation of that line — the case an anchor most easily
#     misjudges, because the continuation carries no glyph of its own;
#   * the marker WELDED out of two fragments by the caller's flatten-to-one-line step, which is
#     how a multi-line directive that merely mentions the two words produces the literal;
#   * the marker as indented transcript content — a child displaying this repo's own source, the
#     case that otherwise poisons a slot permanently.
#
# Everything under test is a pure function over a captured screen, so this needs no terminal, no
# control socket and no repo: it sources the module and calls it.
#
# WHAT IS NOT COVERED, so a green run is never read as more than it is:
#   * NOTHING ANYWHERE ASSERTS WHAT THE CALLERS DO WITH THESE FUNCTIONS. Specifically unguarded:
#     the `unconfirmed` -> exit 6 mapping, the knob validation, the empty-verdict arm, the reply path's closing message, and the three-state mid-turn guard.
#     Stated as the property rather than as a list of script names on purpose — the list version
#     said no test referenced those scripts at all, and went stale twice without anything saying
#     so. The rig it called deferred now exists: the shipyard suite drives whole caller scripts
#     over exported shell functions (a faked backend CLI cannot stay authoritative, because those
#     scripts source a lib that prepends the system PATH). It is used for paths that exit before
#     any turn-state read, so none of the properties above is reached by it.
#   * Whether either kind ever renders its queued hint somewhere OTHER than the place captured
#     here. Both observed placements are covered by a fixture and an assertion; a third placement,
#     if one exists, would read as not-queued and fall to the alarm path.
#   * These are captures of the clients as they render today. Nothing here proves a future build
#     renders the same shapes — that is what pinning them in one place buys.
set -uo pipefail
export LC_ALL=C

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOD="$DIR/../agent-adapters.sh"
FIX="$DIR/fixtures"
[ -f "$MOD" ] || { echo "t-turn: cannot find agent-adapters.sh at $MOD" >&2; exit 1; }
# shellcheck source=../agent-adapters.sh
. "$MOD"

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}

pane() { # <fixture-name> — the fixture's text, or a loud failure if it is missing
  local p="$FIX/pane-$1.txt"
  [ -f "$p" ] || { echo "t-turn: missing fixture $p" >&2; exit 1; }
  cat "$p"
}
state_of() { adp_turn_state "$(pane "$1")"; }

# --- 1. the real states, per kind ------------------------------------------------------------
# One kind carries the marker in its footer, the other in a column-one service line. Neither uses
# the other's home, which is what lets ONE kind-less predicate serve both.
printf '\n── real renders ──\n'
ok "first kind, mid-turn, reads running"      running "$(state_of claude-running)"
ok "first kind, idle at the composer"         idle    "$(state_of claude-idle)"
ok "second kind, mid-turn, reads running"     running "$(state_of codex-running)"
ok "second kind, idle at the composer"        idle    "$(state_of codex-idle)"
# The client says it took the message for the next turn. The two kinds render that in DIFFERENT
# places, which is why the queued arm has two anchors — on the first kind the hint is the composer
# PLACEHOLDER (so it renders only while the box is empty), on the second it is a column-one
# service line. Both were captured; an analogy from one to the other would have been wrong.
ok "first kind, queued mid-turn"              queued  "$(state_of claude-queued)"
ok "second kind, queued mid-turn"             queued  "$(state_of codex-queued)"
# That second fixture is also why `queued` outranks `running`: its service line carries BOTH
# markers at once, so both predicates are true and queued is the more specific answer.
ok "…and its service line carries both markers" yes \
   "$(if adp_turn_running "$(pane codex-queued)"; then printf 'yes'; else printf 'no'; fi)"

# --- 2. the adversarial fixtures — all must read as NOT running ------------------------------
printf '\n── our own text, and file content, are not evidence ──\n'
ok "a typed unsubmitted directive is not a turn"        idle "$(state_of claude-draft)"
ok "…nor is its wrapped continuation"                   idle "$(state_of claude-draft-welded)"
ok "…on the second kind either"                         idle "$(state_of codex-draft-welded)"
ok "the marker as indented transcript content"          idle "$(state_of claude-content)"
# And the predicate agrees with the state read on the same screens.
running_of() { if adp_turn_running "$(pane "$1")"; then printf 'yes'; else printf 'no'; fi; }
ok "predicate: running on the first kind's footer"      yes "$(running_of claude-running)"
ok "predicate: running on the second kind's service line" yes "$(running_of codex-running)"
ok "predicate: not running on a typed draft"            no  "$(running_of claude-draft)"
ok "predicate: not running on transcript content"       no  "$(running_of claude-content)"
ok "predicate: not running on a real idle screen"       no  "$(running_of claude-idle)"
# The service arm reads the client's live-status TAIL, not the marker (#120). Both screens below are
# live captures of the second kind. The first is IDLE with a column-one transcript header that
# carries the marker because the child ran a grep for it — which the bare-substring read called
# running for as long as the line stayed visible. The second is RUNNING with text after the tail,
# which is why the tail is matched anywhere in the line rather than at its end.
ok "a column-one header that greps the marker is not a turn" idle    "$(state_of codex-ran-marker)"
ok "predicate: not running on that header either"            no      "$(running_of codex-ran-marker)"
ok "a status tail with text after it still reads running"    running "$(state_of codex-running-tail)"
ok "the first kind's compaction reads running"               running "$(state_of claude-compacting)"
ok "the second kind's compaction reads running"              running "$(state_of codex-compacting)"
# The predicate ITSELF on an unreadable capture, which is not the same assertion as the state
# read's `unknown` below: `shipyard-compact.sh`'s alt-submit branch calls the PREDICATE, and it
# must treat an unreadable pane as "no turn running" the way the inline grep it replaced did.
ok "predicate: not running on an empty capture"         no \
   "$(if adp_turn_running ""; then printf 'yes'; else printf 'no'; fi)"

# --- 3. unreadable is NOT idle ----------------------------------------------------------------
# An empty capture is what a FAILED read returns as well as what a blank screen returns. Calling
# it idle would let the fold below read a turn that was already running as one our send started.
printf '\n── unreadable vs idle ──\n'
ok "an empty capture reads unknown"           unknown "$(adp_turn_state "")"
ok "a blank but non-empty screen reads idle"  idle    "$(adp_turn_state '   ')"

# --- 4. the verdict fold ----------------------------------------------------------------------
printf '\n── delivery verdict ──\n'
# THE SHIPPED DEFECT: the screens differ (typing put our text in the box) yet no turn started.
ok "the shipped false positive"                    unconfirmed "$(adp_delivery_verdict idle idle)"
ok "and it stays so however long we sample"        unconfirmed "$(adp_delivery_verdict idle idle idle idle)"
ok "no post-send sample at all"                    unconfirmed "$(adp_delivery_verdict idle)"
ok "idle then a turn is delivered"                 delivered   "$(adp_delivery_verdict idle running)"
ok "a turn appearing a few samples in"             delivered   "$(adp_delivery_verdict idle idle running)"
ok "the queued hint mid-turn"                      queued      "$(adp_delivery_verdict running queued)"
# A child already mid-turn cannot yield `delivered` from the turn marker alone: the marker never
# went absent, so nothing distinguishes its own turn from one our submit started.
ok "mid-turn throughout, no hint"                  unconfirmed "$(adp_delivery_verdict running running running)"
ok "a turn ending and a new one starting"          delivered   "$(adp_delivery_verdict running idle running)"
# An unreadable pre-send frame supplies no baseline, so a turn seen afterwards proves nothing.
ok "unknown pre-state cannot confirm"              unconfirmed "$(adp_delivery_verdict unknown running)"
ok "a later idle does supply the baseline"         delivered   "$(adp_delivery_verdict unknown idle running)"
# BOTH positive verdicts need absent-then-present. A queued hint already on screen belongs to an
# earlier send: it persists while its queue is non-empty, so the first post-send sample would
# otherwise re-supply it and decide — which was a live false positive.
ok "a stale queued hint cannot confirm"            unconfirmed "$(adp_delivery_verdict queued queued)"
# The baseline must be WITHHELD by absence, not granted by it. An unreadable pre-send frame is
# what every backend failure looks like, so if it counted as "no hint was there" the first stale
# hint would decide — the same false positive as the screen diff, through a different door.
ok "an unreadable pre-state cannot confirm queued" unconfirmed "$(adp_delivery_verdict unknown queued)"
ok "…nor can a run of them"                        unconfirmed "$(adp_delivery_verdict unknown unknown queued)"
# …but a positive observation that there was no hint does clear it.
ok "a running pre-state clears the queued baseline" queued     "$(adp_delivery_verdict running queued)"
ok "…however many samples it persists for"         unconfirmed "$(adp_delivery_verdict queued queued queued)"
ok "…but a hint that APPEARS after one does"       queued      "$(adp_delivery_verdict queued running queued)"
# Reachable, and pinned because it proves the pre-send slot is read for the baseline only.
ok "a pre-send hint that then clears"              unconfirmed "$(adp_delivery_verdict queued idle)"
ok "the first decisive sample wins"                delivered   "$(adp_delivery_verdict idle running queued)"

# --- 4a. the sampling loop and its census (#163) -----------------------------------------------
# What `shipyard tell` and `council say` each used to carry a copy of. The capture is a function
# that walks a scripted list of states, one per call, and stays on the last one. The list's place
# is kept in a file because the loop reads the capture inside `$( )`.
printf '\n── sampling loop and census ──\n'
TT=$(mktemp -d "${TMPDIR:-/tmp}/t-turn.XXXXXXXX") || exit 1
trap 'rm -rf "$TT"' EXIT
screen_of() { # <state> — a minimal screen that `adp_turn_state` reads as that state
  case "$1" in
    running) printf '  %s\n' "Working (3s • $ADP_TURN_MARKER)" ;;
    unknown) printf '' ;;
    *)       printf 'some transcript line\n' ;;
  esac
}
fake_capture() { # <tag> — prints the next scripted screen, and warns on stderr like a real miss
  local n; n=$(cat "$TT/n"); printf '%s' "$((n + 1))" >"$TT/n"
  echo "fake capture $1 #$n" >&2
  screen_of "$(sed -n "$((n + 1))p" "$TT/seq" | grep . || tail -1 "$TT/seq")"
}
poll_of() { # <secs> <interval> <pre> <post-state>... -> "<verdict>|<census>|<rc>"
  local secs="$1" gap="$2" pre="$3" out rc=0 TAB; shift 3; TAB=$(printf '\t')
  printf '0' >"$TT/n"; printf '%s\n' "$@" >"$TT/seq"
  out=$(adp_delivery_poll "$secs" "$gap" "$pre" fake_capture tag 2>"$TT/err") || rc=$?
  printf '%s|%s|%s' "${out%%"$TAB"*}" "${out#*"$TAB"}" "$rc"
}
ok "census: one state"                         'idle'                "$(adp_delivery_census idle)"
ok "census: runs are counted"                  'idle x3,running'     "$(adp_delivery_census idle idle idle running)"
ok "census: a state that returns is a new run" 'idle,running x2,idle' "$(adp_delivery_census idle running running idle)"
ok "sample: an empty capture reads unknown"    unknown "$(adp_turn_sample printf '')"
ok "sample: a running screen reads running"    running "$(adp_turn_sample screen_of running)"
ok "idle, then a turn -> delivered, and it stops sampling there" \
   'delivered|idle x2,running|0'    "$(poll_of 5 0.01 idle idle running)"
ok "the census starts with the pre-send state" \
   'delivered|running,idle,running|0' "$(poll_of 5 0.01 running idle running)"
ok "a window of 0 still takes one post-send sample" \
   'unconfirmed|idle x2|0'          "$(poll_of 0 0.01 idle idle)"
ok "mid-turn, no hint -> unconfirmed, and the census says so" \
   'unconfirmed|running x2|0'       "$(poll_of 0 0.01 running running running)"
ok "the capture's stderr does not reach the caller" 0 "$(wc -l <"$TT/err" | tr -d ' ')"
# The backstop for a value the callers' knobs should never pass: no verdict, which each caller
# reports as a failure. Never a verdict built on a broken window or interval.
ok "a non-numeric window gives no verdict"     '||2' "$(poll_of x 0.5 idle running)"
ok "a zero interval gives no verdict"          '||2' "$(poll_of 5 0 idle running)"
ok "an unparseable interval gives no verdict"  '||2' "$(poll_of 5 1.2.3 idle running)"
ok "no capture command gives no verdict"       2 "$(adp_delivery_poll 5 0.5 idle >/dev/null; echo $?)"

# --- 4b. has the latest compaction finished? ---------------------------------------------------
# #154. Every screen is a live capture except the one built inline below, which says so. The stale
# pair is the case the old whole-capture search got wrong without any adversary: a compaction from
# EARLIER, still in the viewport, read as done before the new one began. The second kind's line is
# lower-case, so the old search never matched it at all and every compaction there timed out.
printf '\n── compaction finished ──\n'
compacted_of() { if adp_compacted "$(pane "$1")"; then printf 'yes'; else printf 'no'; fi; }
ok "first kind, finished"                          yes "$(compacted_of claude-compacted)"
ok "first kind, still compacting"                  no  "$(compacted_of claude-compacting)"
ok "first kind, an earlier one then another turn"  no  "$(compacted_of claude-compacted-stale)"
ok "second kind, finished"                         yes "$(compacted_of codex-compacted)"
ok "second kind, still compacting"                 no  "$(compacted_of codex-compacting)"
ok "second kind, an earlier one then another turn" no  "$(compacted_of codex-compacted-stale)"
ok "first kind, idle, no compaction on screen"     no  "$(compacted_of claude-idle)"
ok "second kind, idle, no compaction on screen"    no  "$(compacted_of codex-idle)"
ok "an empty capture is never finished"            no  "$(if adp_compacted ""; then printf 'yes'; else printf 'no'; fi)"
# DERIVED, and built here rather than committed so its derivation is visible: the finished capture
# with the echoed command renamed, so the result line sits under an ordinary message — the shape
# a child's own tool output takes when it prints the word. The echo is what makes the line count.
derived=$(pane claude-compacted)
derived=${derived/"$ADP_COMPACT_COMMAND"/grep the compact script}
ok "the result line under any other message is tool output" no \
   "$(if adp_compacted "$derived"; then printf 'yes'; else printf 'no'; fi)"
# DERIVED the same way: the finished capture with the command typed into its empty composer. That
# is the frame shipyard-compact.sh reads right after typing, and it must read not-done however
# stale the screen above it — it is the observation that lets a later "done" be believed.
typed=$(pane claude-compacted | awk -v g="${ADP_BOX_GLYPHS%% *}" -v c="$ADP_COMPACT_COMMAND" '
  { l[NR] = $0; if (index($0, g) == 1) last = NR }
  END { for (i = 1; i <= NR; i++) print (i == last ? g " " c : l[i]) }')
ok "…and the command typed under a finished one is not done" no \
   "$(if adp_compacted "$typed"; then printf 'yes'; else printf 'no'; fi)"

# --- 5. the marker is spelled ONCE ------------------------------------------------------------
# The point of moving this into the shared engine was deduplication: the literal used to be
# spelled four times across two of one skill's scripts. It is spelled once now, in the canonical
# module — plus exactly the vendored copies targets.txt lists, which the drift check holds
# byte-identical. That is the vendoring design, not a second spelling.
printf '\n── one spelling ──\n'
REPO="$(cd "$DIR/../../.." && pwd)"
expected="shared/adapters/agent-adapters.sh"
while IFS= read -r t; do
  case "$t" in ''|\#*) continue ;; esac
  expected="$expected
$t"
done < "$REPO/shared/adapters/targets.txt"
# Scope: PRODUCTION shell only. `*.sh` under any `tests/` directory is exempt because screen
# fixtures have to contain the string — and coupling another suite's fixtures to this constant
# would be worse than the duplication, since it would tie the terminal-backend suite to the
# per-agent-kind module for no gain. Documentation prose is exempt for the same kind of reason: it
# legitimately tells an operator what to look for on a screen.
# LIST THROUGH GIT, never a raw filesystem walk. This repo keeps its own sibling worktrees under a
# gitignored `.claude/worktrees/` — that is where the fleet launcher puts children — and each of
# them contains a full copy of the tree, canonical module and vendored copies included. A `grep -r`
# from the repo root therefore finds them and reds this assertion in the main checkout whenever any
# child is live, which would make the gate unpassable exactly while work is in flight. Every other
# repo-wide scan in the gate goes through `git grep --untracked` or `git ls-files` for this reason.
# `--cached --others --exclude-standard` keeps the reach over brand-new, not-yet-added production
# shell; the trailing /dev/null stops grep reading stdin if the listing is ever empty.
#
# A raw walk was ALSO implementation-dependent, which is worse than either outcome: measured here,
# `grep` resolved to a drop-in replacement whose recursive mode skips hidden directories by
# default, so the walk quietly did not reach the sibling worktrees at all — while GNU and BSD grep
# both descend and would have failed. An assertion whose verdict depends on which grep is
# installed is not an assertion. Listing through git removes the question.
actual=$(cd "$REPO" && git ls-files -z --cached --others --exclude-standard -- '*.sh' \
  | xargs -0 grep -lF -- "$ADP_TURN_MARKER" /dev/null 2>/dev/null \
  | grep -v '/tests/' | sort -u)
ok "the turn marker is spelled only in the canonical module and its vendored copies" \
   "$(printf '%s\n' "$expected" | sort | tr '\n' ' ')" "$(printf '%s\n' "$actual" | tr '\n' ' ')"
# The file SET alone would not notice the literal being hardcoded a second time INSIDE the
# canonical module — an inline grep in some new predicate, right next to the constant that exists
# to prevent it. Counting occurrences is the assertion that actually proves the deduplication this
# whole move was justified by: the literal used to be spelled four times.
# `-o` with `-r` prefixes each match with its file, which is what lets the SAME `/tests/`
# exemption the file-set check uses apply here too — without it this counts other suites' screen
# fixtures and fails for a reason that has nothing to do with duplication.
ok "…and each of them spells it exactly once" \
   "$(printf '%s\n' "$expected" | grep -c .)" \
   "$(cd "$REPO" && git ls-files -z --cached --others --exclude-standard -- '*.sh' \
      | xargs -0 grep -oF -- "$ADP_TURN_MARKER" /dev/null 2>/dev/null \
      | grep -v '/tests/' | grep -c .)"

# The composer glyphs, the same two assertions per glyph (#121). One exemption, and it is a module
# boundary rather than a copy: the terminal backend's own coarse idle read (`drv_signal` in
# shared/driver) spells both glyphs, because that module deliberately does not source this one.
# #156 took its one skill caller off it (autodown's lock 3, which now refuses any live terminal),
# so its capacity half is read only by `flow_run`, which has no production caller. Whether the
# driver keeps reading glyphs goes with whether `flow_run` is kept, which is still open. Exempting
# it here keeps this assertion from settling that by accident. Its vendored copies are exempt too.
glyph_expected="$expected
shared/driver/agent-driver.sh"
while IFS= read -r t; do
  case "$t" in ''|\#*) continue ;; esac
  glyph_expected="$glyph_expected
$t"
done < "$REPO/shared/driver/targets.txt"
glyph_ifs_save=$IFS; IFS=' '
for g in $ADP_BOX_GLYPHS; do
  IFS=$glyph_ifs_save
  actual=$(cd "$REPO" && git ls-files -z --cached --others --exclude-standard -- '*.sh' \
    | xargs -0 grep -lF -- "$g" /dev/null 2>/dev/null \
    | grep -v '/tests/' | sort -u)
  ok "the composer glyph $g is spelled only in the canonical module, its copies and the driver" \
     "$(printf '%s\n' "$glyph_expected" | sort | tr '\n' ' ')" "$(printf '%s\n' "$actual" | tr '\n' ' ')"
  ok "…and the canonical module and its copies spell it exactly once each" \
     "$(printf '%s\n' "$expected" | grep -c .)" \
     "$(cd "$REPO" && git ls-files -z --cached --others --exclude-standard -- '*.sh' \
        | xargs -0 grep -oF -- "$g" /dev/null 2>/dev/null \
        | grep -v '/tests/' | grep -v 'agent-driver\.sh:' | grep -c .)"
done
IFS=$glyph_ifs_save

# The value pin, and the one place this file spells the markers out on purpose: they are observed
# client UI, and a typo silently switches every check above off, because they all build their
# expectations from the fixtures rather than from the constants.
ok "the turn marker is what the clients render"  'esc to interrupt'         "$ADP_TURN_MARKER"
ok "the composer queued hint, common prefix"     'Press up'                 "$ADP_QUEUED_BOX_HINT"
ok "the service-line queued header, common prefix" 'Messages to be submitted' "$ADP_QUEUED_BLOCK_HINT"
ok "the composer glyphs"                         '❯ ›'                      "$ADP_BOX_GLYPHS"
ok "the compaction command"                      '/compact'                 "$ADP_COMPACT_COMMAND"
ok "the first kind's compaction result line"     '  ⎿  Compacted'           "$ADP_COMPACTED_RESULT"
ok "the second kind's compaction service line"   'Context compacted'        "$ADP_COMPACTED_SERVICE"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then
  printf 't-turn: %d checks, all passed\n' "$CHECKS"
  exit 0
fi
printf 't-turn: %d checks, %d FAILED\n' "$CHECKS" "$FAILURES"
exit 1
