# STATE — session memory

## ▶ RUNNING (2026-09-11) — TWO lanes, and the posture is "working, not ideal"

**Posture change from the owner, and it governs everything below:** working beats ideal, and
pragmatic compromises are explicitly wanted. Both children were told the four consequences, all
of which loosen rather than tighten: decide design questions yourself and escalate only what is
unsafe, irreversible, or would change what the PR is FOR; ONE scoped review round after the fix
pass; optional findings become follow-up ISSUES by default rather than in-PR fixes, unless a fix
is one or two lines in a file already in the diff. This deliberately reverses decision 51-3's
bias, which had told slot 51 to take most of its optionals.

**Two lanes, not one, because the queue's serialisation is by FILE and #54 is disjoint.** #112,
#22 and #61 all wait on #116 — it holds `tell.sh`, `compact.sh`, `report.sh` and
`shared/adapters/` at once — but #54 lives in `down.sh` and collides with nothing, so it runs
beside #116 instead of behind it. Slot cap stays 2; it guards memory, and a third lane would buy
nothing here since #22 changes the very printed protocol #116 is re-scoping.

### #116 SHIPPED (`c204c06`) — the fleet's main blocker is closed

Two rounds, 14 axes, 5 skeptics; 2 of round 1's blocking candidates were refuted by their own
skeptics and correctly not treated as blockers. `tell` now concludes delivery from the child's
**turn state**, anchored per line, with a non-zero exit for `unconfirmed`. The read lives in
`shared/adapters/`, kind-less, with eleven live-captured fixtures and the notes on how each was
taken.

**The captures earned their cost.** The condition I attached to decision 51-4 — capture the second
kind rather than extend the first kind's shape by analogy — turned out to be load-bearing: the two
kinds render the queued hint in **different places**, so that arm needed two anchors. Analogy
would have alarmed on every mid-turn send on one kind, i.e. on the commonest healthy path, which
is the failure that teaches an operator to ignore the signal.

Two findings worth keeping:

* **A committed rule-zero leak the gate structurally cannot see.** A home path in its
  separator-encoded form; `check.sh:356` wants a literal `/Users/` or `/home/` prefix, so the
  encoded form passes while disclosing the same thing. `make check` was green over it and a
  reading agent caught it, not the gate. Verified by hand, filed as **#122** — a *publishing*
  risk rather than a usability one, and the likeliest remaining shape to be committed by accident,
  because nobody types it: it arrives by pasting tool output.
* A one-spelling assertion of the child's own that would have reddened `make check` in the main
  checkout whenever any child worktree was live.

Its teardown then became the **third live reproduction of #54**, in exactly the form slot 54 had
diagnosed: a slot's branch has the *base* branch as its upstream, never its own remote branch, so
the ancestry question is unanswerable after a squash. Containment was proven the way #118 does it
— `merge-tree --write-tree` produced `main`'s own tree exactly — and only then `--force`.

### #118 SHIPPED (`419f53f`) — and it proved itself on its own author

The teardown gate asks **content**, not ancestry. Its first use in anger was the teardown of the
very slot that built it: `ship-54: content is already in origin/main — nothing to lose`, no
`--force`. The three teardowns before it had each required switching the guard off.

It also closed the defect in the **opposite** direction, which was in neither the issue nor my
reproduction: a branch with no upstream made `@{upstream}` fatal, stderr was discarded, and `wc -l`
counted the empty stdout as zero — so a worktree holding never-pushed work passed the gate and was
removed. Review then found three more, **two of them introduced by the fix round itself** and both
wrong-ALLOWs: an unreadable index made `git status` answer empty and a staged file verdicted safe;
and a self-upstream guard that was a string test defeatable by a renamed push. A fourth: `git`
discovers upward, so a stray directory under the worktree root got a confident answer about the
parent repo.

Four outcomes are now distinguished where two used to be merged — `unprovable` (a conflicting test
merge) and `no-proof-tool` (git older than 2.38) gave the same "just `--force`" advice, which on
Ubuntu 22.04 meant every unmerged slot.

### #125 SHIPPED (`b4524d4`) — the leak gate sees the encoded form

One arm plus three probes, and the **bounds were derived from the encoding rather than chosen**:
flattening turns an absolute path's leading `/` into a leading `-`, so the encoded root always
begins a token, which means the preceding character can be neither alphanumeric nor a hyphen. That
one requirement excludes hyphenated English (`per-users-quota`) and long flags (`--users-file`)
without losing a real shape. Deliberately not anchored on a trailing separator: an encoded home
directory with nothing after it discloses the username just the same. Zero blocking findings; two
optionals were one defect (the bounds comment overclaimed) and were fixed as comment text only,
leaving the pattern byte-identical. Follow-ups **#126** and **#127** filed rather than folded in.

### #123 SHIPPED (`57f418b`) — and its own review round proved the bug twice

The watchdog now asks **why** a child is not moving before consulting the clock. Both triggers were
measured rather than argued, and the second one fired *during this PR's review*: after the four-day
pause, the block accused two healthy children of a 5420-minute stall, and then both hit a real
session limit mid-review and it fired again.

Round 1 returned blocking findings on five of six axes, and **four were one mistake** — reasoning
about what a client renders instead of reading the captures. So the fix *removes* surface: the
service-bullet arm is gone rather than narrowed (it accepted one kind's own prose and tool-call
headers, so a child that merely greps the phrase bought a permanent stall exemption), the
"resets left" line is gone (it is that kind's chrome, and the positive test built on it pinned a
line proving nothing), and the transport-fault arm is gone (no capture shows its glyph). **Two
evidenced states instead of five that guess.**

The property that keeps it honest: a banner must be **live**, not merely present. A child that hit
a limit, resumed, worked, and *then* wedged still has the banner in the capture — excusing it would
recreate the 8.5-hour silent stall with a reassurance attached. The clearing rule is **mirrored**
from the existing capacity-state read rather than shared, and the PR names the seam instead of
hiding it: that function is fused to an episode counter with a different contract and a
single-kind vocabulary.

Two findings about tests that were not testing:

* the change's own new test extracted a glyph byte-wise under `LC_ALL=C`, got a literal space, and
  so asserted *indentation* — and both of its vacuity guards passed on it. A guard built from the
  same expression it guards.
* the report's plumbing was pinned only by `grep`: **six of seven** semantic mutations shipped
  green, including inverting the supervision-gap comparison. The suite now drives the real script
  over a faked container and every one of them reds.

### ✅ #130 SHIPPED (`b0ff815`) — THE FINISH LINE IS MET

Exit 0 is the monitor's stop signal, so it is the loudest claim the report makes, and it was
reachable from an **absence**. The mechanism is sharper than the issue's "socket blip":
`SHIPYARD_BACKEND=auto` re-resolves per tick, so when the agterm socket failed one probe that tick
fell back to tmux, where a session named after the repo holds no ship windows — and the report
truthfully announced that everything had shipped while two children sat mid-review with open PRs.
**It was not wrong about what it saw. It was wrong about what seeing nothing means.**

Emptiness must now be corroborated by two facts before it may end the watch: the container answered
at all, and the backend asked was the one the fleet was launched on. "I do not know" now shares an
exit code with "yes, work is open", because the loop's only decision is whether to keep watching.

Neither fact was new knowledge here — `shipyard-down.sh` already refused to drop the pin unless
enumeration *proved* the fleet empty, so the report was the last place still reading a failed
enumeration as a drained fleet.

**It closes an instance, not the class, and says so in its own body:** the same defect lives in the
admission gate (#131, an unreachable backend counted as zero live slots, bypassing the concurrency
cap) and in `tell`/`compact` (#134, a child reported gone when its terminal is merely absent on the
backend that tick resolved).

Eleven blocking findings fixed across three rounds, **ten of them introduced by the change's own
earlier rounds** — including a guard added in round 1 that was wrong twice and ended up fully
reverted to the rule already there. Third time today a change improved by *removing* what its
author added rather than by adding another guard.

## ▶ COUNCIL — the next goal, and its finish line

`ship` and `shipyard` are validated by ten changes driven through them; `council` by nothing. It
ships in the same marketplace and carries 18 of the repo's open issues. The goal now is the same
test applied to it: **what blocks USING it**, not what would make it ideal.

Triaged against the tree rather than by reading the issue list back, because an issue's age says
nothing about whether it is still true:

| # | what | evidence |
|---|---|---|
| **#28** | a dangling `--room`/`--me` spins forever | **reproduced**: both documented forms, zero output, rc 124 under a 5s timeout, 100% CPU |
| **#117** | `say` reports success for a message left unsubmitted in the seat's box | the twin of shipyard's #51; `up.sh:526` confirms only that keystrokes were injected |
| **#36** | participants are never told `skip` exists | **grepped**: absent from `protocol/_channel.md` and every scenario — the only documents a participant receives |
| **#17** | a blocked participant is indistinguishable from a thinking one | the README says the trust prompt "looks, from the room, exactly like a wedged session", and the two need opposite fixes |
| **#24** | `decide`'s announcement can be refused and the room never learns it closed | **read**: `verbs.sh:664` sends with `>/dev/null` and never reads the status |

The shape of the list is worth noting: three of the five are the same defect family the fleet just
spent two days on — **a verb that reports success without establishing it** (#117, #24), and **a
state nobody can distinguish from its opposite** (#17). #117 in particular is not a blank page:
the fix lives in `shared/adapters` *because* council was identified as the second consumer while
#116 was in review, so adopting it is the work, not writing it.

**Deliberately below the line, and why:** #66's remainder — `overrule` is gated on nothing, so any
non-author can close an objection — is a *correctness* hole in the thesis that "the outcome is
computed", not a usability one, and its obvious fix was tried and reverted once already. #48
(a decided room leaves its terminals running), #21 (no monitor protocol), #67, #29, #30, #34, #39,
#40 and the test issues stay below it too.

## 🚢 RELEASED (2026-09-12) — `ship` 0.2.0 · `shipyard` 0.5.0 · `council` 0.3.0

Issue **#144** → PR **#145** → `add5b83`. Both manifests per plugin moved together; nothing gates
that yet, which is #20.

**Why it was needed, stated narrowly because I first stated it too broadly.** I claimed that
anyone who had installed the plugin was running August code. That is wrong for a **fresh** install:
`marketplace add` clones the default branch, so a new user already received current content under
the stale number — verified by installing from the public repo and finding a merge from that same
afternoon inside a copy declaring `0.4.0`. The frozen case is only an **existing** install, whose
cache is keyed by the declared version, so `update` compares a number that had not moved, does
nothing, and reports success.

**Not `1.0.0`, deliberately.** The Codex runtime path has never been driven end to end, and
`council` carries 18 of the repo's open issues, one labelled security. A minor bump claims what was
earned; `1.0.0` would claim what was not.

### Installation — verified by running it, in both CLIs, for the first time

The README has promised these commands since August and nobody had executed them. Both marketplaces
add from the public repo, all plugins install, the skills land in the cache, and teardown is clean.
`shipyard` installs and reports **0.5.0**, and the cached copy carries every fleet fix — checked by
symbol, not by trust: the anchored turn read (#116), the teardown gate script (#118), the wait
classifier (#123), the absence classifier and its `tell`/`compact` wrapper with exit 7 (#137), and
the forge iid fallback (#138).

Two things the run established that no amount of reading would have:

* **Claude Code resolves the declared dependency.** Installing `shipyard` alone pulled `ship` with
  it (`+ 1 dependency: ship`), and uninstalling offered to prune it again. The manifest field works.
* **Codex does not, exactly as documented.** `codex plugin add shipyard@dimonb-skills` succeeded
  and left `ship` as `not installed`. This is not a defect to file — `plugins/shipyard/README.md`
  says precisely this, and the README's install block lists all three plugins explicitly, so a
  reader who follows it is fine. Observed behaviour matched documented behaviour, which is the
  outcome worth recording.

**One correction to my own method, worth keeping.** My first content check reported a fix ABSENT
from `shipyard-tell.sh`. The probe was wrong, not the code: `tell` and `compact` do not call the
classifier directly, they call `shipyard_absence_report`, which classifies and prints the
operator's next move, and they exit **7** for "could not resolve" rather than the corroborated
"gone" of 3. Grepping for the symbol I expected rather than the one the code uses would have been
a false alarm reported as a finding.

### Still unexercised, and it is the honest boundary of this release

Installation on Codex is verified; **running** a change through Codex is not. No Codex child has
been driven end to end, so every claim about that path remains prose. `council` is likewise
installed-and-untouched: I have validated `ship` and `shipyard` by driving ten changes through
them across two days, and `council` by nothing at all.

## ✅ THE FLEET IS USABLE — the four blockers are closed

| PR | merge | what it fixes |
|---|---|---|
| **#116** | `c204c06` | `tell` confirms delivery from turn state, not a screen diff (#51) |
| **#118** | `419f53f` | teardown asks content, not ancestry (#54) |
| **#123** | `57f418b` | the watchdog asks *why* before consulting the clock (#22) |
| **#130** | `b0ff815` | the report earns its stop signal instead of assuming it (#61) |

Plus two that were not on the line: **#115** (`67972b5`, the policy suite finally runs; check 12)
and **#125** (`b4524d4`, the leak gate sees an encoded home path).

**Verified on the merged head, by running it rather than by inference:** `make check` rc=0 with all
four fast suites executing, `make check-test` **101 assertions proven / 0 not proven**, `make test`
rc=0 with all six suites, working tree clean.

### Deliberately left undone, so nobody has to re-derive the reasoning

* **#112** (`tell` types over an unsubmitted draft) — demoted twice and left. #116 turned it from
  silent corruption into corruption that reports itself, and its fix is *undecidable from a
  capture*: a live frame showed the client rendering suggestion text nobody typed, so a draft and
  an empty box are the same bytes. Spending a lane on the undecidable while decidable fixes waited
  was the wrong trade. Recorded on the issue so the next reader does not start from the approach
  its body implies.
* **#131 / #134** — the remaining instances of #130's class. Neither *silently ends supervision*,
  which is what made #61 a blocker: a false "child is gone" is visible and repeatable, and the cap
  bypass needs an unreachable backend and a launch at once. #134 is the closest call if there is
  another pass.
* **#117** (council `say`, the same defect as #51) — cheap now that the predicate is shared, but it
  is council's bug, not the fleet's.
* **#124** (`ship` writes its state file late, so the status table is blind for most of a run) —
  found by supervising, and the reason I read panes and queried the forge by hand all day.
* **#126, #127, #128, #132, #133, #135, #114** — filed by the children's own rounds, all below the
  line.

### One thing I did to myself, worth remembering

`make check-test` left `docs/_probe.md` behind when I killed it with a two-minute timeout, and the
next run refused to start with `BASELINE DIRTY`. Its EXIT trap does not cover a hard kill — exactly
the incidental finding slot 111 reported and I said I would triage. Reproduced first-hand, filed,
and below the line. Give that target a real budget: it takes minutes, not seconds.

### Two findings filed from supervision, not from a diff

* **#124 — `ship` writes its state file late and unevenly, so the status table is blind for most
  of a run.** `ship` §4 specifies `.pipeline-state/<KEY>.json` and §2 says to write it "ONCE per
  run, before anything else". **I first filed this as "never written" and had to correct it**: one
  child wrote the file, but only once its PR already existed, while another still had none with an
  open PR and two completed review rounds behind it. The claim was built partly on the report's own
  column rather than on looking, which is inference dressed as observation — the correction is on
  the issue. The cost is unchanged — `shipyard-report.sh` reads the PR number from there and correctly refuses to
  assume a numeric slot is a PR (on GitHub the slot is an *issue* number; the old assumption once
  made the monitor declare a run finished a minute after it started), so with no state file the
  column reads `no MR yet` over an open, reviewed, mergeable PR, and the stage column reads `—`.
  Supervising then means reading panes and querying the forge by hand — exactly what the table
  exists to replace. **#64 is the narrower problem and this is its precondition:** that issue
  reports rounds not reaching the file and quotes the file to prove it.
* **#122 — the leak gate cannot see a home path in its separator-encoded form.** Filed from a
  committed instance `make check` was green over. A publishing risk, not a usability one, and now
  in flight because the lane was free.

### A rule that earned its way into AGENTS.md

Three changes in a row hit the same failure, always in the harmful direction: **any predicate that
reads a child's screen is forgeable by a child whose work IS that predicate.** #116's read counted
its own typed directive and the plugin's own source as evidence; #123's first anchor accepted one
kind's prose and tool-call headers, and its positive test pinned a line that proves nothing.

Written up in `AGENTS.md` as a standing rule — anchor on client **chrome** the child's output
cannot produce, derive the anchor from a committed capture, and remember that too tight is not safe
either, because an alarm on the commonest healthy path is one the operator learns to ignore. When
no anchorable shape exists, drop the arm: an exemption you cannot evidence is worth less than not
having it.

### Remainder re-prioritised, because #116 changed the picture

| # | was | now | why |
|---|---|---|---|
| **#22** | third | **in flight** | the watchdog discards live context — active harm |
| **#61** | fourth | next, same file as #22 | a socket blip silences the monitor permanently |
| **#112** | second | **last, and questionable** | see below |

**#112 dropped for two independent reasons.** #116 turned it from *silent* corruption into
corruption you are told about: `tell` no longer claims `delivered`, it returns `unconfirmed` with
a non-zero exit. And its fix is an open design question rather than a settled one — "is the box
empty" is **not decidable from a capture**, now proven by a live frame in which the client rendered
suggestion text nobody had typed. Spending a lane on the undecidable while two decidable fixes
wait is the wrong trade. Recorded on the issue so the next reader does not start from the approach
its body implies.

**A collision neither slot knew about, caught by reading both diffs:** both edit the shipyard
suite's single-line `tests=()` registration array, and both independently claimed the number
`t12`. The number works out — 51 deletes its `t12-turn-delivery.sh` (its table moves to
`shared/adapters/tests/`) and 54 adds `t12-down-gate.sh` — but whoever merges second hits a
one-line conflict there. Both were warned, and told to re-read the whole array rather than resolve
it wholesale, because the gate's own comment notes that a resolution silently dropping a name
looks exactly like a clean one.

### #118 found the defect in the OPPOSITE direction, which neither the issue nor I had

The issue, and my own reproduction, only ever described the **false refusal**. The child measured a
**silent pass** as well: a branch with **no upstream configured** makes `@{upstream}` a fatal
error, stderr was discarded, and `wc -l` counted the empty stdout as **zero** — so a worktree
holding work that had never been pushed anywhere passed the gate and was removed. The guard that
exists to protect unpushed work was blind to the one case where nothing else would have caught it.

It also explains the false refusal more precisely than the issue did: a slot's branch is created
with `git switch -c <branch> origin/<base>`, so its upstream is `origin/<base>` — never its own
remote branch — and a push by refspec never updates it. `@{upstream}..HEAD` is therefore the
branch's own commits, which after a squash are ancestors of nothing.

Both dissolve once the question is content. The gate now proves containment two ways — tree
equality, then merge emptiness via `git merge-tree --write-tree`, the second being the one that
survives the base branch moving ahead, which in a fleet it always does. Every unanswerable
question returns a refusal rather than a clean bill of health, and the residual is written down:
if the base later edits the same region of the same file, the test merge conflicts and a
fully-merged slot is still refused — the conservative direction.

## The lane's history (2026-09-11) — one lane at the start, `ship-51`

Resumed after a four-day pause. Both terminals survived it, so neither child needed rebuilding.
`ship-111` is torn down (its change merged on the 7th), so the single lane is now `ship-51`
working PR #116, started from `.git/ship-escalations/decision-51-3.md` and rebasing onto a `main`
that moved under it.

### Two findings the pause itself produced, both already on their issues

* **#54's trigger is the dangling upstream, not the squash.** `ship-111` was torn down with
  `shipyard-down.sh` and it **succeeded, rc=0, no `--force`** — because #115 was merged with
  `--delete-branch=false`, so `@{upstream}` still resolved. Not one of the branch's commits was an
  ancestor of `main`, which is nominally what the guard measures, and it passed anyway. A guard
  that says *safe* here and *unsafe* for the identical situation with the ref deleted is not
  measuring what it claims in either case. Practical workaround until the fix lands: merge with
  `--delete-branch=false`, tear down, then delete the remote branch.
* **#22 has a second trigger with the same wrong prescription: a slot paused on purpose.** The
  resume printed `🛑 STALLED — motionless for 5420 min`, whose stated justification is *"a child
  does not idle this long on its own"* — the one assumption that is false here, since it idled that
  long *because* it was told to. Ninety hours, and the block's third step is compaction, i.e.
  discarding 446k tokens of live context to cure nobody having asked it anything. Same defect as
  the rate-limit case: the watchdog measures motionlessness and concludes death, when what it needs
  to separate is *cannot move* and *was not asked* from *stuck*. The pause case is the cheap one to
  fix, because the parent knows it happened and need not infer it from the pane.

**A containment proof that stopped being one.** With `main` ahead of a merged branch,
`git diff origin/main..<head>` shows main's own later commits and looks alarming while nothing is
missing. What actually proves containment: the files still differing between the branch head and
`main` (for #115, only the two files `main` had edited independently), or comparing the squash
commit's diff against the branch's three-dot diff — which matched exactly, 19 files, 485
insertions, 151 deletions on both sides.

### The instruction this lane runs under, and it still stands

Two narrowings, both from the owner: **one slot at a time**, and the objective is only **what
actually blocks using the fleet** — not the backlog.

**One lane is also the budget, not only a preference.** The resumed slot's own banner read *79% of
the weekly limit, resets Sep 11*. Two slots burn that twice as fast for no gain here, because the
queue below is serialised by the file each change touches anyway.

### Shipped this lane

**#115 → PR #115 merged (`67972b5`).** `shared/policy/tests` had run in no automated invocation
since the day it landed; it now runs under `make check` (1.1s, pure) and `make test`, and the
*class* is closed rather than the instance — check 10's suite list became `$GATED_SUITES`, read by
both consumers, and a new **check 12** asserts the reverse direction against disk: every runner
under `plugins/` or `shared/` must be named by a Makefile recipe AND declared in that list.
Verified before merging: `make test` rc=0 in 438s on macOS with all six suites executing,
`make check-test` 98 proven / 0 not proven, CI green on all three targets.

One thing worth knowing because both sides touched one file: the branch predated the AGENTS.md
"shared engine" section, and the squash **kept both** — main's `AGENTS.md` carries the section and
the new check-12 text, and `check.sh` carries `$GATED_SUITES`. Checked after merging, not assumed.

### The finish line — what is left, in order

Everything after #61 is explicitly NOT part of it:

| # | what | why it blocks USE | where |
|---|---|---|---|
| ~~#115~~ | ~~policy suite gated + check 12~~ | — | **merged `67972b5`** |
| **#116** | `tell` confirms from turn state, not a screen diff | a directive reports `delivered` while it sits unsent | `ship-51`, idle, PR open |
| **#112** | `tell` types over an unsubmitted draft | same channel, corrupts the directive | after #116, same file |
| **#54** | `down` refuses a squash-merged slot | every teardown needs `--force` by hand | then |
| **#22** | the stall watchdog prescribes compaction to a rate-limited child | actively destroys live context to cure waiting | then |
| **#61** | `report` exits 0 on an unreachable backend | a socket blip stops the monitor for good | last, same file as #22 |

**#117** (council `say`, the same defect as #51) rides the shared predicate #116 introduces, so it
is cheap afterwards — but it is council's bug, not the fleet's, and it sits below the line.

### The lane, verified rather than assumed

| slot | branch | head at resume | PR | worktree | state |
|---|---|---|---|---|---|
| ~~`ship-111`~~ | ~~`fix/gate-policy-tests-registration`~~ | `30609b5` | **#115 MERGED** `67972b5` | **torn down** | done; remote branch deleted after the teardown |
| `ship-51` | `fix/shipyard-tell-delivery-confirmation` | `08ad8f8` | **#116** open, MERGEABLE/CLEAN | clean, 0 ahead of origin | **running** — one pass over amended 51-1 + the confirmed fixes |

Neither child was sent a pause directive on the way down: 111 had already handed off and 51 had
never started, so a `tell` would have been noise — and on this very code a `tell` carries a small
risk of its own until #116 lands.

### What `ship-51` is doing, and what it was given

Its round-1 review is COMPLETE (9 axes + 5 skeptics); the full ledger survived the pause in
`.git/ship-escalations/pause-51-round1-findings.md`. The one thing that blocked it — an open
design question about B1's fix shape — is answered in `.git/ship-escalations/decision-51-3.md`,
which also dispositions every finding of the round and fences the scope to this change only.

**Decision 51-3: anchor the match by line shape; do NOT thread the typed line in as a parameter.**
Both fixes were proposed by confirmed sources and the choice had API consequences, since amended
51-1 puts the function in the shared module. Anchoring wins on three counts: the parameter is the
plumbing the upheld objection was against; anchoring closes a strict superset of the triggers,
including the one that permanently poisons a slot (a child displaying this plugin's own source);
and the technique, with its discipline, is already in the tree at `shipyard-continuity.sh:28-36`.
The condition attached is not optional — **derive the anchor from real captured panes committed as
fixtures.** A too-loose anchor restores the false `delivered`; a too-tight one alarms on the
commonest healthy path, which is the failure that teaches an operator to ignore the signal and so
defeats the change's own premise.

Also folded into the same pass: B3's surviving optional (OR over both real queued shapes, now that
the code sits behind the `adp_*` seam), B2's verified fix, B5's corrected form, B6 handled honestly
rather than justified into coverage, and F1–F6. B3 and B4 were **refuted** as blockers by their
skeptics and must not be treated as such.

Standing rules: `shipyard-down.sh` only after a merge or a close (it removes the worktree);
monitors carry `SHIPYARD_CTX_WINDOW=1000000` or the ctx column lies about a 1M-window session.

**A drafting rule this lane adopted and the next one should keep:** never write the client's footer
marker or its queued hint literally into a directive, an escalation or a comment. A child working
on shipyard displays what you send it, and the displayed literal then satisfies the very predicate
#116 is fixing — sweep-siblings' third trigger, which poisons the slot until the text scrolls off.
Name such a string by role and put it in a file the reader opens. `decision-51-3.md` is written
that way on purpose.


- **Mode:** brownfield onboarding (GSD Core methodology, applied by hand — no GSD CLI installed).
- **Project:** shared agent-harness core for shipyard and council (`PROJECT.md`).
- **Where we are:** setup artifacts drafted — `PROJECT.md`, `REQUIREMENTS.md`, `ROADMAP.md`.
  Codebase map in `.planning/codebase/` grounded from a repo scan of both skills.
- **Requirements:** 22 mapped across 4 phases; all P0 covered (`ROADMAP.md`).
- **Spike done (branch `spike/shared-driver`, local, uncommitted):** MIG-02 / C1 is answered.
  One canonical `shared/driver/agent-driver.sh` is vendored into both plugins by
  `scripts/sync-driver.sh`; `check.sh` gained **check 11**, which reds on drift, a missing copy,
  a missing canonical, or an empty target list. All four arms verified manually; `make check`
  green. Two probes added to `check-test.sh` (runs once the spike is committed — its clean-tree
  guard blocks on untracked files). **Conclusion: the sharing mechanism works — Phases 2–4 are
  unblocked.**
- **02-01 SHIPPED TO PROD:** PR **#77 merged** to `main` (squash `6685ecd`) via shipyard/Opus.
  ship's impl-review found + fixed 2 real blockers (a rule-zero `.planning` leak in the driver
  comment; under-probed check 11 arms). Model default switched off Fable (it was over-thinking and
  stalling) to Opus; now `opus[1m]` (Opus 5, 1M). CORRECTION to an earlier note here: the switch did
  NOT cost the 1M window, and the recurring "ctx 92-99%" alarms were shipyard's ctx column inferring
  a 200k window for a young 1M session — the 92%->20% jumps were that inference resolving past 200k,
  not autocompact. `SHIPYARD_CTX_WINDOW=1000000` makes the column read true from the first turn.
- **02-02 SHIPPED:** PR **#79 merged** (squash `911d3db`) — real drv_* body (superset of both
  backends) + `shared/driver/tests/`. 0 blockers on review. On the #78 decision I confirmed the
  API myself (delegated): the child caught a spec error — both backends append `-ai` identically
  (not council-only); differences (repo-key `:`→`_`, pin location, override env) go to caller vars.
- **02-03 SHIPPED:** PR **#81 merged** (squash `6fd1c08`) — council `term.sh` delegates to drv_*,
  behaviour-preserving; council suite 21/21 + new t15 mapping test green on merged main. Review
  caught a stale SKILL.md doc, fixed.
- **02-04 SHIPPED:** PR **#83 merged** (squash `05cf692`) — shipyard backend delegates to drv_*;
  shipyard suite green incl. new t8-backend-adapter (24 checks); monitors verified working on the
  migrated backend. **Driver de-duplication COMPLETE — both skills run on one shared driver.**
- **GSD position — Phase 2 extraction DONE (in prod):** #77 mechanism, #79 body, #81 council,
  #83 shipyard. Four squash-merges to main, each ship-reviewed (Opus) + independently re-verified.
- **02-05 SHIPPED:** PR **#85 merged** (`c984d97`) — make check runs the driver suite + a
  registration check generalized to all 3 suites, stays fast (~3.7s); new `make test`;
  check-test 79/0. **PHASE 2 COMPLETE (all 5 tasks in prod: #77/#79/#81/#83/#85).**
  **STALE FIGURE — annotated at #104, not rewritten.** The ~3.7s above was true when written: the
  gate then ran ONE suite. The flow suite landed after it (2.4s) and check.sh itself grew to ~3.5s,
  so `make check` measures **~6.0-6.5s idle** (three warm runs on the main worktree) and 7.6-8.7s
  on a loaded machine. I keyed a speed rule for #104 to the 3.7s number and the child caught it by
  measuring instead of trusting it. **Lesson: a wall-clock figure in a prose log is a fact with an
  expiry date nothing enforces — never key a rule off a remembered one.** The rule is: measure
  before and after, report both WITH the load conditions, justify the delta.
- **LOAD SHIPPED:** PR **#87 merged** (`dd996eb`) — `shipyard-admission.sh` gate before launch:
  refuses when live slots at cap (`SHIPYARD_MAX_SLOTS`, default 2) or under macOS memory pressure
  (floor 10%), before any worktree/terminal. t9-admission (42 checks). Verified live: dry launch
  at 0/2 slots + 46% free = admitted. **The desktop-recycle crash is fixed.** Fleet safe to run 2.
- **LIFE SHIPPED / task 01-02:** PR **#89 merged** (`413193b`) — `council up --hold` + fifo canary;
  keeper reaps participant terminals on owner-EOF; no `$PPID`. Review caught 2 real blockers
  (tmux fd inheritance = the predicted footgun; canary-bootstrap fd-exhaustion hang), both fixed +
  regression-tested. t16 (26 checks) incl. the with/without-guard fd proof. **Phase 1 is
  council-complete (LOAD ✅ + LIFE ✅).** Note: the 5/6-axis "stall" was a session rate-limit
  (disguised), unblocked by a nudge after the reset.
- **PHASE 1 CLOSED / task 01-03:** PR **#93 merged** (`ea6ed4c`) — shipyard watcher opt-in canary +
  process group on the detached path, `$PPID`-free reaping (t10, 21 checks). Decision 90-1 (mine):
  shipyard has no long-lived owner, so the canary is opt-in; agterm-session path stays the
  production owner-death guarantee (honest docs). **Phase 1 done: LOAD #87 + LIFE council #89 +
  LIFE shipyard #93.**
- **CI SHIPPED:** PR **#92 merged** (`090ab52`) — `.github/workflows/ci.yml` runs the whole gate on
  push/PR. **CORRECTION (made at #111): this entry said "Linux + macOS" and that was never true** —
  `ci.yml` has a single `runs-on: ubuntu-latest` job and `git log -p --all` over that file contains
  zero occurrences of `macos`. I wrote the claim without deriving it. It is load-bearing in the
  worst way: a reader would reasonably conclude that the BSD-vs-GNU portability these suites care
  about is covered by CI, and it is not — the only macOS coverage is a human running `make test`
  locally. Whether to ADD a macOS job is a separate and real question given this repo's `stat -f`
  and `timeout(1)` history. Caught + fixed 2 latent portability bugs (`ctx_mtime` `stat -f`,
  `t3-token` wall-clock race → turn-count). Decision 91-3 (mine): Option A, bounded — worked.
- **GSD adopted + tracked:** `.planning/` is now committed (`3853950`); AGENTS.md rewritten to
  reconcile GSD with the no-per-change-spec rule (plan-phase output = the issue) and `.planning/`
  added to the docs-only-to-main allowlist.
- **Phase 3 + Phase 4 core SHIPPED (ran parallel, 2-slot cap):**
  - Phase 3 ESC policy — #94 → PR **#96** → `f47f15a`. One shared `policy_dispose` table
    (default-deny, rate-limit-from-usage, council mailbox). Decision 94-1 coordination: no bespoke
    drift check, rely on #97's generalized gate.
  - Phase 4 FLOW guard core — #95 → PR **#97** → `4ba98ba`. Interpreter over a declared step-graph,
    fixed mechanical `done_when` vocabulary. Decision 95-1 (mine): A1+B1+C1 — incl. **generalize
    the shared-module drift gate** to iterate every `shared/<mod>/` (now covers driver+flow+policy).
    Also made t10 robust under load.
  - Merge order #97 → #96 (verified by a local trial-merge: 0 conflicts, generalized gate covers
    policy). Both children hit a shared account **rate-limit** mid-run (2 parallel Opus) — nudged
    back after reset; lesson: the cap guards memory, not API quota.
- **FLOW-04 SHIPPED (council on the guard):** #98 → PR **#99** → `3e333ea`. Decision 98-1 (mine):
  Option C — a session-less `flow_phase` AUTHORITY mode added to the shared guard; council's turn
  cycle is a declared graph, the barrier stays a pure log function consulted as one authority,
  the #74 race retired (t18: a wedged seat and a caught-up seat agree). The guard now serves both
  modes — `flow_run` (drive one agent) and `flow_phase` (authority). **The guard is now USED.**
- **FLOW-03 SHIPPED (shipyard on the guard):** #100 → PR **#101** → `e05b410`. Decision 100-1 (mine):
  Option B — `flow_phase` authority, not `flow_run` (rejected: parks idle children, blocks a
  non-blocking snapshot, wrong completion axis). report derives phase+glyph+terminal from the
  declared graph; dogfood check passed (the live monitors still work on the migrated shipyard).

## PROJECT COMPLETE

All four phases in prod, and with #106 **all 22 requirements are delivered**. Both skills run on the
shared **driver + adapters + policy + guard**; one generalized drift gate covers all four shared
modules; CI runs the whole gate on every push/PR; the crash and the orphaned-supervisor class are
fixed. 16 feature PRs, each ship-reviewed and independently re-verified before merge.

### DRV-02 — the last requirement

- **DRV-02 SHIPPED — PR #106 merged (squash `40f4320`). THE LAST OPEN REQUIREMENT: all 22 are now
  met and the GSD plan is fully delivered.** One shared `shared/adapters/agent-adapters.sh`, both
  callers on it, no gate edit needed (check 11 already iterated every `shared/<mod>/`). 3 review
  rounds + a scoped confirming round, 15 axes.
  - **Merged with a body supplied at merge time, not by rewriting history.** `cec678e`'s message
    described a fail-open as fail-closed, and with `squash_merge_commit_message=COMMIT_MESSAGES`
    that would have landed on `main` verbatim. The reword was blocked by the permission classifier
    in the child AND in the parent, so decision 104-8 used the option neither of us had listed:
    `gh pr merge --squash --body-file`, which overrides the setting. Verified after merge that the
    false clause is absent from `40f4320`'s body. This deliberately reverses the 102-5 instruction
    ("do not rely on the merger supplying a body by hand") — that was about fragility when the
    merger might forget, which does not hold when the merger is in the loop with the text in hand.
  - **The finding worth keeping, and the child found it itself:** three of the four post-round-1
    blockers were ONE defect — enumerable, completeness-shaped claims written into comments ("the
    two other places that branch on a kind"), where each correction bred the next. A count in a
    comment is wrong the moment anyone adds to the thing it counts. The last commit removes the
    SHAPE (an explicitly open list that says not to trust a count in a comment, including itself)
    instead of correcting another instance. Related: after round 1, **no round found a defect in
    the shipped module's behaviour** — the code settled first and the prose took three more rounds.
  - Decision 104-9: handed off without a further round, on a stated distinction rather than a
    waiver — the earlier delta contained a fix to a probe that could not fail (an assertion that
    might not assert is what an author cannot verify by reading), while the final delta only
    REMOVES claims, which has no completeness to be short of. I read both hunks myself.
  - Emergent, filed not folded: **#113** (latent fail-open — `shipyard_env_preamble`'s rc is
    swallowed by its caller, so a kind with no env-pass arm launches a child with nothing
    propagated and nothing scrubbed; latent only because both admitted kinds have arms, and this
    very change makes adding a kind easy) and **#114** (two pre-existing load-only test flakes).
  Decisions taken under delegation: 104-1 one canonical `shared/adapters/agent-adapters.sh` with
  per-kind `case` branches and `ADP_*` knobs (Options 2 and 3 rejected — the gate and
  `sync-driver.sh` both require EXACTLY ONE `*.sh` per module, so a file-per-kind module is
  impossible by contract, not by taste); the protocol mode is DERIVED per kind and exposed as a
  read-only query, never an input knob; `ADP_APPROVAL=sandboxed|full` with council pinned
  `sandboxed` and shipyard `full`, because this is the one place a behaviour-preserving refactor
  could silently move a security posture. 104-2 (the child's correction, accepted): "byte-identical
  rendering" was MY over-specification and is unsatisfiable once one module owns one quoting
  function — the real criterion is SAME ARGV, proven against fixtures captured from `main` BEFORE
  the renderers changed (a test that regenerates both sides proves nothing). Retiring the dynamic
  `source adapters/$kind.sh` also closes the plant-a-plausibly-named-file hole council had
  documented as measured-and-left-standing.
## After the plan: the fleet-ergonomics track

The GSD plan is delivered, so the work now is a different thing and is tracked as such: **what makes
the fleet painful to RUN.** It is not a new phase of the plan — no requirement IDs — it is the
backlog, prioritised by first-hand evidence from supervising this project's own slots. Everything on
it below I hit myself while shipping #105/#106, which is why it is this list and not the other 25
open issues.

Order is set by which FILE each touches, so two slots never collide the way #97/#96 once did and
#106/#115 just would have (measured: five conflicting files):

| order | issue | file | status |
|---|---|---|---|
| 1 | **#51** | `shipyard-tell.sh` | IN FLIGHT, slot `ship-51` |
| 2 | **#112** | `shipyard-tell.sh` | sequential after #51, same slot |
| 3 | **#54** | `shipyard-down.sh` | queued |
| 4 | **#22** | `shipyard-report.sh` | queued (sequential with #61 — same file) |
| 5 | **#61** | `shipyard-report.sh` | queued |

**CORRECTED at 51-2, by the child.** This table first had #51 and #112 as ONE PR, justified as
"two PRs would collide in one file". That is an argument against running them in PARALLEL, not
against sequencing them — and rows 4 and 5 of this very table sequence two PRs on one file, so I
was applying two different rules inside one table. **Sequencing is the rule; same-file work is
serialised, not merged.** The substantive reason is stronger anyway: they are DIFFERENT reads.
#51 reads turn STATE (is a turn running); #112 needs prompt CONTENT (is the box empty), whose only
proven method is a mutating probe — an open design question that would have parked a settled fix
behind an unsettled argument.

- **#51 / #112** — `tell` decides `delivered` from a before/after screen DIFF, which typing always
  changes, so an unsubmitted directive reports as delivered (#51); and it types with no emptiness
  check, so a directive concatenates onto a pending draft (#112). Decisions 51-1/51-2: the
  turn-state read does NOT belong in the shared **driver** — a client's footer string
  (`esc to interrupt`) is not backend knowledge, and the driver abstracts agterm-vs-tmux; and it
  must REDUCE the marker's spellings, or the change has made things worse.

  **Two claims in the two lines above were wrong, and the child caught both** (same class as
  `3e97e22`). (a) The read was recorded as living in `shipyard-lib.sh`; it lived in a new
  `shipyard-turn.sh` that the lib sources — the lib is its *caller*, not its home, and naming the
  wrong file is how a later reader "fixes" the wrong one. (b) The marker's inline greps were
  recorded as **two** in `shipyard-compact.sh`; there are **three** there, and a fourth in
  `shipyard-report.sh`. I counted from memory of the diff instead of grepping the tree.

  **AMENDED at 51-1 (authoritative).** The predicate moves into `shared/adapters/` after all,
  because the premise of the original decision was false: I justified keeping it skill-local as
  "both consumers are shipyard's", and council is a real third one — `council_say`
  (`up.sh:526`) confirms only that `ct_type` injected keystrokes, never that a turn started, which
  is #51 verbatim. Filed as **#117**. What the objection actually landed on was kind-THREADING
  plumbing, not the shared home, so the function goes in kind-less and the seam where a per-kind
  marker would arrive is documented instead of parameterised. `unconfirmed` gets a non-zero exit, because a verdict that exits 0
  is exactly a note nobody has to notice — the same defect class as the false `delivered`. **Hit while
  diagnosing a real stall**, where a captured pane showed placeholder ghost text that is
  indistinguishable from a draft — a bare Return did nothing (correctly: the box was empty) and it
  read as a wedged terminal. A single probe character proved the box empty.
- **#54** — `down` refuses a fully merged slot because it asks about ANCESTRY, not content: the
  squash-merge deletes the remote branch, `@{upstream}` dangles, and every commit reads as unpushed.
  **Hit twice today**, on both #105 and #106; both times `--force` was the only way through, which
  means the gate guarding genuinely unpushed work had to be switched off to tear down a slot whose
  work was already in `main`. Fresh reproduction added to the issue.
- **#22** — the stall watchdog fires on a rate-limited session and prescribes COMPACTION, i.e.
  discarding live context to cure something that only needed waiting. **Hit on both slots at once**
  (a session limit at 17:01 with an 20:10 reset), and again when the machine SLEPT mid-turn. The
  banner in the pane names when the window ran out, not the current state, so it reads as live.
- **#61** — `report` exits 0 (the monitor's "all finished, stop watching" signal) when it cannot
  reach the backend, so a socket blip permanently stops the monitor. Not hit this run, but it is the
  same class as the sleep: an environment hiccup read as a terminal state.

**Not on the list, deliberately:** ~25 other open issues, mostly council's robustness against
malformed values and its test hygiene. None blocks running the fleet. The structural one is **#40**
(a participant is not confined, so the room cannot be a trust boundary), which is a threat-model
conversation rather than a bug fix.

## Open follow-ups from the plan

- `flow_run` has no production caller — both skills turned out monitor/authority, not driven. Remove
  it (YAGNI) or justify it as a general primitive.
- **#111 IN FLIGHT (slot `ship-111`, PR #115)** — `shared/policy/tests` runs in NO automated invocation:
  absent from check 10's list, from both Makefile targets and from CI (verified independently; it
  still passes by hand at 92 checks). #97's generalization landed by halves — check 11 (drift) does
  iterate every `shared/<mod>/`, check 10 (run + registration) kept a hand-maintained list. Found
  by the #104 child while reviewing its own change. Decision 111-1: **A + C** — patch the list AND
  add a new check that every test runner on disk is invoked by a Makefile target. C is the missing
  assertion, because check 10 gates whether a TEST is registered inside a runner while nothing gated
  whether the RUNNER is ever run. Deriving the list from disk (B) was rejected: it replaces a
  declaration with disk, so a suite deleted or renamed wholesale stops being noticed — the same
  silent-coverage shape. Scoped to `plugins/` and `shared/` so an untracked local skill under the
  project skill dirs cannot red the gate (AGENTS.md's carve-out).
- **#113 / #114** — filed out of #106's review, above.

**Stale-worktree cleanup — DONE, with a salvage.** `ship-3` was empty (its branch `feat/ci-gate`
long since superseded by the merged CI work) and was removed. `ship-41` was NOT dead: it held an
unpushed commit plus five files of uncommitted work. That WIP was committed verbatim and the branch
pushed to `origin/fix/council-suite-cleanup-enforced` before the worktree was removed, so nothing was
lost. Only `main` remains as a worktree. Two independent valuable pieces were identified there,
both verified still absent from `main`, and each filed as its own issue rather than cherry-picked
(the tree has moved under them — #89 rewrote the keeper loop):
- **#102 SHIPPED:** PR **#105** merged (squash `b02ba4f`). 3 review rounds + a verification pass,
  0 blocking findings open; `t19` at 43 checks with every mutation row measured against the merged
  tree. Three message-only history rewrites, each one an application of the rule set at 102-5
  (review branch, sole author, tree byte-identical, `--force-with-lease`), never a fresh decision.
  Two lessons worth keeping: a claim repeated in three places is ONE claim with three copies, and
  the first amend fixing only the flagged copy is what let the stale figures survive two rounds;
  and mutation testing via `git checkout origin/main -- <file>` leaves the pre-fix file STAGED, so
  an `--amend` there silently commits a revert of the fix (caught, not suffered). Four pre-existing
  defects found by its siblings sweep went to #107/#108/#109/#110, none folded into the diff.
- **#102 (as filed)** — a keeper whose room was rebuilt at the same path never
  steps down: it watches only `[ -d "$room" ]`, so the old keeper survives a `down`+`up` cycle as a
  leaked process holding open fifos. Fix: watch the pid file and step down only when it names
  ANOTHER positive pid — missing/empty/malformed is deliberately NOT a stop reason (t9g writes `0`).
- **#103 CLOSED as a duplicate of #41.** I filed it from the salvaged branch without checking the
  backlog, and #41 predates it, is richer, and even reserves the same `t12-*` number. What the
  salvage adds is now recorded on #41: the work is already IMPLEMENTED on that branch (a working
  `t12-cleanup.sh`, so this is porting, not writing), and #41's deferred-signal figure of "60s vs
  0s" is really **20s vs 0s** — the delay is the length of the foreground command, not a constant.
  **Process lesson: search the backlog before filing.** Two of the three issues I opened from the
  salvage duplicated existing ones (#103→#41), and a third had a pre-existing twin (#112 beside
  #51). A fleet supervisor filing from a child's findings sees the finding, not the backlog.

- **Repo law reminder:** every change keeps `make check` green; issue → branch → PR → human merges.
  `.planning/` is TRACKED (since `3853950`) and is the project-planning record, never a per-change
  spec gate — AGENTS.md "Planning with GSD, and no per-change spec artifact".
