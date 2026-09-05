# STACK — technologies and dependencies

Grounded in a scan of `plugins/shipyard/skills/shipyard/` and `plugins/council/skills/council/`.

## Languages / runtimes

| Tool | council | shipyard | Notes |
|---|---|---|---|
| **bash** | **≥ 5 required, hard gate** (`council.sh:26-38`, re-execs, errors on < 5 for assoc arrays / `read -N` / `EPOCHREALTIME`) | **written for 3.2 compat** (no BASHPID; `sh -c '…$PPID…'` probe, `shipyard-continuity.sh:515-530`) | ⚠️ **baseline mismatch** — see CONCERNS |
| **jq** | pervasive (`lib/term.sh`, `lib/up.sh`, `lib/claims.jq` standalone) | pervasive; agterm backend requires it (`shipyard-backend.sh:81`) | both hard-depend |
| **python3** | scenario front-matter + role parsing (`up.sh:90-118`) | **none** | council-only |
| **agterm / agtermctl** | backend (`lib/term.sh`) | backend (`shipyard-backend.sh`, `shipyard-continuity.sh`) | primary terminal backend |
| **tmux** | alternate backend (`lib/term.sh`) | alternate backend (`shipyard-backend.sh`) | fallback |
| **gh / glab** | **none** (council touches no forge) | `shipyard-report.sh:143` (`gh pr view`), `:150` (`glab mr view`) | forge work delegated to the `/ship` child |

## Takeaway for the shared driver

The shared driver (DRV-*) must decide a **single bash baseline**. council's ≥ 5 and shipyard's
3.2 cannot both be honoured by one module; this is a Phase-2 design decision, not a detail.
jq and the agterm|tmux pair are common ground and safe to share.
