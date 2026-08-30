#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$DIR/.." && pwd)"
TMP=$(mktemp -d /tmp/shipyard-codex-ctx-test.XXXXXXXX) || exit 1
trap 'rm -rf "$TMP"' EXIT

failures=0
check() {
  local want="$1" got="$2" label="$3"
  if [ "$want" = "$got" ]; then
    printf 'ok - %s\n' "$label"
  else
    printf 'not ok - %s (want %q, got %q)\n' "$label" "$want" "$got"
    failures=$((failures+1))
  fi
}

git init -q "$TMP/repo"
cd "$TMP/repo" || exit 1
ROOT=$(pwd -P)
mkdir -p "$ROOT/.claude/worktrees/ship-7" "$ROOT/.git/ship-escalations"
printf '{"agent":"codex"}\n' >"$ROOT/.git/ship-escalations/launch-7.json"

CODEX_HOME="$TMP/codex"
export CODEX_HOME
mkdir -p "$CODEX_HOME/sessions/2026/08/30"
rollout="$CODEX_HOME/sessions/2026/08/30/rollout-test.jsonl"
printf '{"type":"session_meta","payload":{"cwd":"%s"}}\n' "$ROOT/.claude/worktrees/ship-7" >"$rollout"
printf '%s\n' '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":184225},"model_context_window":258400}}}' >>"$rollout"

. "$SKILL_DIR/shipyard-lib.sh"
. "$SKILL_DIR/shipyard-ctx.sh"

check codex "$(ctx_agent 7)" "launch metadata selects Codex"
check "$rollout" "$(ctx_codex_transcript 7)" "Codex transcript matches worktree cwd"
check "184225 258400" "$(ctx_codex_totals "$rollout")" "Codex token event exposes current and window"
check "71 71% · 184k" "$(ctx_probe 7 "")" "Codex context uses its explicit window"

exit "$failures"
