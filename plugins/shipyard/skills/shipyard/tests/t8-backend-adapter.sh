#!/usr/bin/env bash
# t8 — the shipyard terminal-backend ADAPTER (shipyard-backend.sh) over the shared drv_* driver.
#
# shipyard-backend.sh no longer carries the backend mechanics; it maps shipyard's knobs onto the
# shared driver (agent-driver.sh) and delegates each shared op to the matching drv_*. The driver's
# own mechanics are covered by shared/driver/tests/t-driver.sh; THIS file asserts only the
# SHIPYARD-specific glue the migration introduced, which none of t1..t7 exercises: the
# SHIPYARD_BACKEND -> DRV_BACKEND mapping (including the refusal a bad value yields, still naming
# SHIPYARD_BACKEND), the container name with shipyard's own repo-key ':' -> '_' transform and the
# '-ai' suffix, the SHIPYARD_WORKSPACE / SHIPYARD_SESSION override (backend-specific), the pin file
# living in the shipyard mailbox keyed by backend, and that shipyard_target/slots build their query
# from the 'ship-<slot>' template.
#
# Everything is a PURE read over environment variables and three faked CLIs (git, agtermctl, tmux)
# on PATH — NO live terminal, no real repo, no network. shipyard-backend.sh resolves DRV_REPO_KEY
# and the override at SOURCE time, so each case sources it afresh inside its own subshell with the
# environment it is asserting; sourcing it never prepends PATH (only shipyard-lib.sh does), so the
# fakes stay authoritative.
#
# The adapter sources the driver, whose baseline interpreter is bash >= 5, so re-exec into one if a
# stock bash 3.2 started us (the guard council.sh and t-driver.sh use), or a bash-5-only construct
# in the driver would surface here as a confusing syntax error rather than a clear version message.
if [ "${BASH_VERSINFO[0]:-0}" -lt 5 ] && [ -z "${T8_BASH_REEXEC:-}" ]; then
  for _c in /opt/homebrew/bin/bash /usr/local/bin/bash /usr/bin/bash bash; do
    _p=$(command -v "$_c" 2>/dev/null) || continue
    _v=$("$_p" -c 'echo ${BASH_VERSINFO[0]}' 2>/dev/null) || continue
    [ "${_v:-0}" -ge 5 ] && exec env T8_BASH_REEXEC=1 "$_p" "$0" "$@"
  done
  echo "t8: needs bash >= 5, this one is ${BASH_VERSION:-unknown}." >&2
  exit 70
fi

set -uo pipefail
export LC_ALL=C
# A live agterm workspace would make container derivation query a socket; unset it so every case
# takes the deterministic repo-stem fallback, exactly as t-driver and the probe do.
unset AGTERM_WORKSPACE_ID AGTERM_WINDOW_ID

SKILL="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BACKEND="$SKILL/shipyard-backend.sh"
LIB="$SKILL/shipyard-lib.sh"
[ -f "$BACKEND" ] || { echo "t8: cannot find shipyard-backend.sh at $BACKEND" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/shipyard-t8.XXXXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

CHECKS=0; FAILURES=0
ok() { # <label> <expected> <actual>
  CHECKS=$((CHECKS + 1))
  if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
  else printf '  FAIL %s\n         expected: [%s]\n         actual:   [%s]\n' "$1" "$2" "$3"; FAILURES=$((FAILURES + 1)); fi
}

# --- faked CLIs, driven entirely by environment variables, FIRST on PATH ---------------------
FAKEBIN="$TMP/bin"; mkdir -p "$FAKEBIN"
cat >"$FAKEBIN/git" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "rev-parse --show-toplevel")  [ -n "${FAKE_TOPLEVEL:-}" ] && { printf '%s\n' "$FAKE_TOPLEVEL"; exit 0; }; exit 128 ;;
  "rev-parse --git-common-dir") [ -n "${FAKE_GITDIR:-}" ]   && { printf '%s\n' "$FAKE_GITDIR";   exit 0; }; exit 128 ;;
  *) exit 0 ;;
esac
EOF
cat >"$FAKEBIN/agtermctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  version) exit "${FAKE_AT_VERSION_RC:-0}" ;;
  tree)    cat "${FAKE_AT_TREE:-/dev/null}"; exit 0 ;;
  *)       exit 0 ;;
esac
EOF
cat >"$FAKEBIN/tmux" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list-windows) cat "${FAKE_TMUX_WINDOWS:-/dev/null}"; exit 0 ;;
  *)            exit 0 ;;
esac
EOF
chmod +x "$FAKEBIN/git" "$FAKEBIN/agtermctl" "$FAKEBIN/tmux"
export PATH="$FAKEBIN:$PATH"
# The repo the fake git reports: a COLON in the stem, so the ':' -> '_' transform is exercised for
# real. FAKE_TOPLEVEL/FAKE_GITDIR are exported so every subshell and the faked git see them.
export FAKE_TOPLEVEL="$TMP/proj:x"
export FAKE_GITDIR="$TMP/gd"; mkdir -p "$FAKE_GITDIR/ship-escalations"

# --- 1. SHIPYARD_BACKEND -> DRV_BACKEND mapping ----------------------------------------------
printf '\n── backend mapping ──\n'
ok "SHIPYARD_BACKEND=tmux maps through"   tmux    "$( export SHIPYARD_BACKEND=tmux;   . "$BACKEND"; shipyard_backend )"
ok "SHIPYARD_BACKEND=agterm maps through" agterm  "$( export SHIPYARD_BACKEND=agterm; . "$BACKEND"; shipyard_backend )"
ok "a bad SHIPYARD_BACKEND is invalid"    invalid "$( export SHIPYARD_BACKEND=nonsense; . "$BACKEND"; shipyard_backend )"
# The refusal must still name SHIPYARD_BACKEND (the knob the operator set), not the driver's own.
inv_rc=0
( export SHIPYARD_BACKEND=nonsense; . "$BACKEND"; shipyard_backend_check ) >/dev/null 2>&1 || inv_rc=$?
ok "a bad backend refuses (exit 1)" 1 "$inv_rc"
inv_msg=$( export SHIPYARD_BACKEND=nonsense; . "$BACKEND"; shipyard_backend_check 2>&1 >/dev/null | head -1 )
case "$inv_msg" in *SHIPYARD_BACKEND*) ok "the refusal names SHIPYARD_BACKEND" yes yes ;;
                   *) ok "the refusal names SHIPYARD_BACKEND" yes "no: [$inv_msg]" ;; esac

# --- 2. container name: shipyard's ':' -> '_' transform and the '-ai' suffix ------------------
printf '\n── container naming ──\n'
ok "shipyard_repo_key sanitises ':' -> '_'" proj_x "$( . "$BACKEND"; shipyard_repo_key )"
ok "tmux container: sanitised stem, no suffix" proj_x \
  "$( export SHIPYARD_BACKEND=tmux; . "$BACKEND"; shipyard_container )"
ok "agterm container: sanitised stem + '-ai'"  proj_x-ai \
  "$( export SHIPYARD_BACKEND=agterm; . "$BACKEND"; shipyard_container )"
ok "container kind is 'session' on tmux"   session   "$( export SHIPYARD_BACKEND=tmux;   . "$BACKEND"; shipyard_container_kind )"
ok "container kind is 'workspace' on agterm" workspace "$( export SHIPYARD_BACKEND=agterm; . "$BACKEND"; shipyard_container_kind )"

# --- 3. the SHIPYARD_WORKSPACE / SHIPYARD_SESSION override (backend-specific) -----------------
printf '\n── container override ──\n'
ok "SHIPYARD_WORKSPACE overrides on agterm" my-ws \
  "$( export SHIPYARD_BACKEND=agterm SHIPYARD_WORKSPACE=my-ws; . "$BACKEND"; shipyard_container )"
ok "SHIPYARD_SESSION overrides on tmux" my-sess \
  "$( export SHIPYARD_BACKEND=tmux SHIPYARD_SESSION=my-sess; . "$BACKEND"; shipyard_container )"
# Each override applies only to its own backend: the other backend ignores it and derives.
ok "SHIPYARD_SESSION is ignored on agterm" proj_x-ai \
  "$( export SHIPYARD_BACKEND=agterm SHIPYARD_SESSION=my-sess; . "$BACKEND"; shipyard_container )"
ok "SHIPYARD_WORKSPACE is ignored on tmux" proj_x \
  "$( export SHIPYARD_BACKEND=tmux SHIPYARD_WORKSPACE=my-ws; . "$BACKEND"; shipyard_container )"

# --- 4. the pin file lives in the shipyard mailbox, keyed by backend -------------------------
printf '\n── container pinning ──\n'
# shipyard-lib.sh points DRV_CONTAINER_PIN_DIR at the mailbox; set it here as the lib would, and
# assert drv_container_pin (via shipyard_container_pin) writes/reads there, keyed by backend.
MB="$TMP/mailbox"; mkdir -p "$MB"
pin_v=$( export SHIPYARD_BACKEND=tmux DRV_CONTAINER_PIN_DIR="$MB"; . "$BACKEND"; shipyard_container_pin )
ok "shipyard_container_pin returns the derived name" proj_x "$pin_v"
ok "the pin file is written under the mailbox, keyed by backend" proj_x "$(cat "$MB/container-tmux" 2>/dev/null)"
ok "a later shipyard_container reads that pin" proj_x \
  "$( export SHIPYARD_BACKEND=tmux DRV_CONTAINER_PIN_DIR="$MB"; . "$BACKEND"; FAKE_TOPLEVEL="$TMP/changed" shipyard_container )"
# unpin forgets it, so the next derive is fresh.
( export SHIPYARD_BACKEND=tmux DRV_CONTAINER_PIN_DIR="$MB"; . "$BACKEND"; shipyard_container_unpin )
ok "shipyard_container_unpin removes the mailbox pin file" "" "$(cat "$MB/container-tmux" 2>/dev/null)"

# shipyard-lib.sh really does point the pin dir at the mailbox: source the full lib with a git
# FUNCTION (which survives lib's PATH prepend, unlike a PATH stub) and read the resolved var.
mb_expect="$(cd "$FAKE_GITDIR" && pwd -P)/ship-escalations"
pindir=$(
  git() { case "$1 $2" in
            "rev-parse --show-toplevel")  printf '%s\n' "$FAKE_TOPLEVEL" ;;
            "rev-parse --git-common-dir") printf '%s\n' "$FAKE_GITDIR" ;;
            *) return 0 ;; esac; }
  export SHIPYARD_BACKEND=tmux
  . "$LIB" >/dev/null 2>&1
  printf '%s' "${DRV_CONTAINER_PIN_DIR:-}"
)
ok "shipyard-lib points the driver pin dir at the mailbox" "$mb_expect" "$pindir"

# --- 5. drv_target query construction from the 'ship-<slot>' template ------------------------
printf '\n── target query construction ──\n'
# agterm: the container is 'proj_x-ai' (derived), so the fixture tree names that workspace and puts
# a 'ship-5' session in it. shipyard_target 5 must resolve that session's UUID.
cat >"$TMP/tree.json" <<'EOF'
{"ok":true,"result":{"tree":{"workspaces":[{"id":"w1","name":"proj_x-ai","sessions":[{"id":"u5","name":"ship-5"},{"id":"u9","name":"ship-9"}]}]}}}
EOF
ok "agterm shipyard_target builds a ship-<slot> query -> UUID" u5 \
  "$( export SHIPYARD_BACKEND=agterm FAKE_AT_TREE="$TMP/tree.json"; . "$BACKEND"; shipyard_target 5 )"
miss_rc=0
( export SHIPYARD_BACKEND=agterm FAKE_AT_TREE="$TMP/tree.json"; . "$BACKEND"; shipyard_target 7 ) >/dev/null 2>&1 || miss_rc=$?
ok "agterm shipyard_target exits 1 for an absent slot" 1 "$miss_rc"
# agterm slot enumeration strips the 'ship-' prefix back to the slot ids.
ok "shipyard_slots lists the agterm slots" "5 9" \
  "$( export SHIPYARD_BACKEND=agterm FAKE_AT_TREE="$TMP/tree.json"; . "$BACKEND"; shipyard_slots | tr '\n' ' ' | sed 's/ $//' )"
# tmux: container 'proj_x'; windows carry the 'ship-<slot>' names; the handle is '<container>:<idx>'.
printf '%s\n' '0 other' '1 ship-5' >"$TMP/windows.txt"
ok "tmux shipyard_target builds a ship-<slot> query -> container:index" proj_x:1 \
  "$( export SHIPYARD_BACKEND=tmux FAKE_TMUX_WINDOWS="$TMP/windows.txt"; . "$BACKEND"; shipyard_target 5 )"
tmiss_rc=0
( export SHIPYARD_BACKEND=tmux FAKE_TMUX_WINDOWS="$TMP/windows.txt"; . "$BACKEND"; shipyard_target 7 ) >/dev/null 2>&1 || tmiss_rc=$?
ok "tmux shipyard_target exits 1 for an absent slot" 1 "$tmiss_rc"

printf '\n'
if [ "$FAILURES" -eq 0 ]; then echo "t8 PASS ($CHECKS checks)"; else echo "t8 FAIL ($FAILURES/$CHECKS)"; exit 1; fi
