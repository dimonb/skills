# forge-github — GitHub mechanics for `ship`

Read this file **only** when §2.1 of `SKILL.md` detected a GitHub remote. It holds the CLI
mechanics and the GitHub-specific traps; the pipeline, the review engine and the guardrails
stay in the core. **It deliberately contains no pipeline state names** — the core owns those,
and a second copy of an enum is a copy that rots.

Everything here uses `gh`. Substitute the discovered coordinates for `$REPO`
(`<owner>/<repo>`), `$OWNER`, `$NAME` and `N`.

---

## 1. Environment guard — in EVERY shell block

```bash
unset GITHUB_TOKEN
```

**A set `GITHUB_TOKEN` overrides the account `gh` is logged in as.** Shell state does not
persist between tool calls, so this goes at the top of every block that touches `gh` or
pushes. Skipping it in one block is how a run half-authenticates as somebody else.

## 2. Identity and access

```bash
unset GITHUB_TOKEN
export REPO=<owner>/<repo>
ME=$(gh api user --jq .login)          # the active gh account — never hard-code it
echo "ME=$ME"
gh repo view "$REPO" >/dev/null 2>&1 || echo "WARN: $ME cannot access $REPO"
```

If `$ME` is empty, or that account cannot access the repo, STOP and ask the user to point
`gh` at an account with access (`gh auth switch`). Whatever account is active becomes `$ME`
for ALL authorship and assignment checks. Always pass `--repo "$REPO"` (or the full
`repos/$REPO/...` path) rather than relying on cwd inference.

## 3. Pushing — the SSH trap

**`origin` may be an SSH URL that authenticates as a GitHub identity *without* access to
this repo.** That is a common multi-account setup, and `git push` over SSH then fails with a
misleading `Repository not found`. Push over **HTTPS with gh's own credential helper**
instead, and **never permanently rewrite `origin`** — override per push:

```bash
unset GITHUB_TOKEN
git -c credential.helper='!gh auth git-credential' \
  push https://github.com/<owner>/<repo>.git <branch>:<branch>
```

`gh pr create` and every `gh api` call already use the active account; only the raw git
transport needs this override.

## 4. Issues

```bash
unset GITHUB_TOKEN; export REPO=<owner>/<repo>

# detail
gh issue view N --repo "$REPO" --json number,state,assignees,title,url

# duplicates, before creating one
gh issue list --repo "$REPO" --search "<keywords>"

# labels — read before inventing one
gh label list --repo "$REPO" --limit 200
gh label create "<name>" --repo "$REPO" --color RRGGBB --description "<what it means>"

# create (body via file — NEVER an escaped \n in a quoted arg; it publishes literally)
gh issue create --repo "$REPO" --title "<title>" --assignee "@me" \
  --label "<kind>" --label "<area>" --body-file /tmp/issue-body.md

gh issue edit N --repo "$REPO" --add-assignee "@me"
gh issue close N --repo "$REPO"
```

### Linked PRs for an issue — take the UNION of two queries

Neither query alone is complete: the structured one misses a plain-text mention, the search
misses a link made through the UI. Union and de-dupe by number.

```bash
gh api graphql -f query='
  query($o:String!,$r:String!,$n:Int!){
    repository(owner:$o,name:$r){
      issue(number:$n){
        closedByPullRequestsReferences(first:30,includeClosedPrs:true){
          nodes{ number state url } } } } }' \
  -F o=<owner> -F r=<repo> -F n=N

gh pr list --repo "$REPO" --state open --search "N in:body" --json number,headRefName,url
```

## 5. Pull requests

```bash
unset GITHUB_TOKEN; export REPO=<owner>/<repo>

# detail — everything the core's §3.3 needs
gh pr view N --repo "$REPO" --json \
  state,isDraft,headRefName,baseRefName,author,headRefOid,labels,reviewDecision,\
mergeable,mergeStateStatus,statusCheckRollup,url

# changed paths, for stage detection
gh pr view N --repo "$REPO" --json files --jq '.files[].path'

# find one by source branch
gh pr list --repo "$REPO" --head "<branch>" --state open --json number,url

# create — body via file, issue reference inside it
gh pr create --repo "$REPO" --base <base> --head "<branch>" \
  --title "<title>" --assignee "@me" \
  --label "<kind>" --label "<area>" --body-file /tmp/pr-body.md

# labels (board decoration only — they gate nothing)
gh pr edit N --repo "$REPO" --remove-label "<old>" --add-label "<new>"

# THE ENFORCED BLOCKER for a stopped run (core §5.9)
gh pr ready N --repo "$REPO" --undo     # -> draft
gh pr ready N --repo "$REPO"            # <- undraft, once findings are addressed

# merge (only where policy allows — core §2.6, §10)
gh pr merge N --repo "$REPO" --squash --delete-branch
```

Pick the merge strategy the repo actually uses — read its merged history
(`git log --oneline origin/<base> | head -20`); a squash-merged repo shows `… (#N)` titles.

Use a **closing keyword** (`Closes #N`) in the PR body from the start where this change really
closes the issue. Where an issue spans several changes, reference it without the keyword so
the merge does not close it early.

## 6. Comments, threads and replies

```bash
unset GITHUB_TOKEN; export REPO=<owner>/<repo>

# our own review record (core §5.9) — body via file
gh pr comment N --repo "$REPO" --body-file /tmp/review-record.md

# every review thread, with the author of its FIRST comment (= its owner)
gh api graphql -f query='
  query($o:String!,$r:String!,$n:Int!){
    repository(owner:$o,name:$r){
      pullRequest(number:$n){
        reviewThreads(first:100){
          nodes{ id isResolved isOutdated
                 comments(first:1){ nodes{ author{ login } body } } } } } } }' \
  -F o=<owner> -F r=<repo> -F n=N

# non-threaded comments — invisible to any thread count (core §8)
gh api --paginate "repos/$REPO/issues/N/comments" \
  --jq '.[] | {user: .user.login, created: .created_at, body: .body[0:700]}'

# reply INTO someone else's thread (never resolve it)
gh api --method POST "repos/$REPO/pulls/N/comments/COMMENT_ID/replies" \
  -f body="$(cat /tmp/reply.md)"

# submitted reviews
gh api "repos/$REPO/pulls/N/reviews" --jq '.[] | {user: .user.login, state}'
```

Paginate fully; skip resolved and outdated threads. Filter out `[bot]` authors when counting
"someone else's" threads — a bot comment is not a person waiting on an answer.

## 7. Checks

```bash
unset GITHUB_TOKEN
gh pr checks N --repo "$REPO"          # exit 0 = all pass
gh pr view N --repo "$REPO" --json statusCheckRollup \
  --jq '.statusCheckRollup[] | {name, status, conclusion}'
```

Poll until nothing is `PENDING`, `QUEUED` or `IN_PROGRESS`.

## 8. GitHub gotchas that have each cost real time

- **The SSH key may authenticate as an identity without repo access.** §3. The error says
  `Repository not found`, which reads like a typo in the URL.
- **A set `GITHUB_TOKEN` silently overrides the logged-in account.** §1.
- **There will never be a formal approval.** GitHub forbids approving your own PR, and any
  review pass ship runs is under the SAME account it pushes from, so an approved state can
  never arrive. **Waiting for `reviewDecision == APPROVED` is an infinite wait.** The gate is
  a completed review pass with its findings addressed (core §10). Read `reviewDecision` only
  to notice a *human* review, never as ship's own gate.
- **Never detect a review by authorship.** Because reviewer and author share one identity,
  any check keyed on `author != <you>` — or a "wait for someone else's comment" heuristic —
  excludes the very reviewer it waits for. Detect our own records by their hidden marker;
  detect a *person's* input by it not carrying that marker.
- **`gh pr merge --auto` is not a gate where no check is configured as *required*.** With no
  required check there is nothing for it to wait on, so it merges **immediately** — it has
  already merged a change whose run was still in progress. Poll the checks yourself, then
  merge (core §10).
- **A green check run belongs to the head it ran on.** After any push, re-read the checks; an
  older run's result says nothing about the new head.
- **`--body-file` or stdin for every multiline body.** An escaped `\n` inside a quoted `--body`
  argument publishes as the literal two characters.
- **`gh pr view --json files` is paginated by the API**; for a very large change confirm you
  saw every path before concluding a diff is spec-only.
- **`/code-review` and `/security-review` must never be passed `--comment` or `--fix` here
  either.** They post to the forge and append an attribution footer, which the repo's law
  forbids (core §5.1).
