# forge-gitlab — GitLab mechanics for `ship`

Read this file **only** when §2.1 of `SKILL.md` detected a GitLab remote. It holds the CLI
mechanics and the GitLab-specific traps; the pipeline, the review engine and the guardrails
stay in the core. **It deliberately contains no pipeline state names** — the core owns those,
and a second copy of an enum is a copy that rots.

Everything here uses `glab`. Substitute the discovered coordinates for `$HOST` and `$PROJECT`
(the URL-encoded `namespace/path`, or the numeric project id — the numeric id is the more
robust key in API paths) and the merge-request iid for `IID`.

---

## 1. Environment guard — in EVERY shell block

```bash
unset OAUTH_TOKEN; export GITLAB_HOST=<host>
```

**A stray `OAUTH_TOKEN` shadows glab's own auth.** Shell state does not persist between tool
calls, so this goes at the top of every block that touches `glab`. `GITLAB_HOST` must be set
for a self-hosted instance or glab talks to gitlab.com instead.

## 2. Identity and access

```bash
unset OAUTH_TOKEN; export GITLAB_HOST=<host>
git remote get-url origin                       # must match $GITLAB_HOST
ME=$(glab api user | jq -r .username)           # our identity — never hard-code it
echo "ME=$ME"                                   # abort if empty (auth broken)
glab api "projects/$PROJECT" | jq -r '.path_with_namespace, .default_branch, .id'
```

If `$ME` is empty, STOP and report that glab auth is broken. Resolve the numeric project id
once and use it in every later API path.

## 3. glab version quirks — check these before trusting a flag

```bash
glab --version
```

The quirks below were measured on **glab 1.90.0**. They are the kind that fail loudly on a
good day and silently on a bad one, so verify rather than assume:

- **`glab api` has NO `--jq` / `-q` flag.** Pipe raw output to `jq` instead
  (`glab api ... | jq -r '...'`), and use `--paginate --output ndjson` for arrays. The flags
  `glab api` *does* accept: `-F/--field`, `-H/--header`, `-i/--include`, `--input`,
  `-X/--method`, `--output`, `--paginate`, `-f/--raw-field`, `--silent`, `--hostname`.
- **`glab mr create` has NO `--description-file`** — it errors with `Unknown flag`.
  `-d/--description` takes the text itself, so pass `-d "$(cat /tmp/mr-body.md)"`, which
  keeps real newlines and does not re-interpret backticks from the body. Write the body to a
  file first; **never** an escaped `\n` in a quoted argument.
- **`--yes` skips the interactive confirmation** on `mr create` and `mr merge`.

## 4. Pushing

`origin` over SSH is the normal path on GitLab and usually authenticates as the right user.
Push plainly:

```bash
git push -u origin <branch>
```

If the push is rejected for authentication, do not start rewriting `origin` — check
`glab auth status` and the SSH key in use, and report rather than guessing.

## 5. Issues

Not every GitLab project uses issues, and some track one umbrella issue with a checklist per
change (core §7.A covers that convention). Where issues are used:

```bash
unset OAUTH_TOKEN; export GITLAB_HOST=<host>
glab api "projects/$PROJECT/issues/N"
glab issue list --search "<keywords>"
glab issue create --title "<title>" --assignee "$ME" --label "<kind>" \
  -d "$(cat /tmp/issue-body.md)" --yes
glab api --method PUT "projects/$PROJECT/issues/N" -f assignee_ids="<id>"
```

Linked merge requests for an issue — union of the structured query and a description search:

```bash
glab api --paginate "projects/$PROJECT/issues/N/related_merge_requests" | jq -r '.[].iid'
glab api --paginate "projects/$PROJECT/merge_requests?state=opened&search=N&in=description" \
  | jq -r '.[].iid'
```

## 6. Merge requests

```bash
unset OAUTH_TOKEN; export GITLAB_HOST=<host>

# detail — everything the core's §3.3 needs
glab api "projects/$PROJECT/merge_requests/IID" | jq -r '{
  state, draft, source_branch, target_branch, author: .author.username,
  sha, labels, pipeline: .head_pipeline.status,
  merge_status: .detailed_merge_status, web_url }'

# changed paths, for stage detection
glab api --paginate "projects/$PROJECT/merge_requests/IID/changes" \
  | jq -r '.changes[].new_path'

# find one by source branch
glab api "projects/$PROJECT/merge_requests?source_branch=<branch>&state=opened"

# create — -d takes the TEXT (no --description-file on 1.90; §3)
glab mr create --source-branch "<branch>" --target-branch <base> \
  --title "<title>" --assignee "$ME" --label "<label>" \
  -d "$(cat /tmp/mr-body.md)" --yes

# claim the MR we drive (idempotent)
glab mr update IID --assignee "$ME"

# labels (board decoration only — they gate nothing)
glab mr update IID --unlabel "<old>" --label "<new>"

# THE ENFORCED BLOCKER for a stopped run (core §5.9)
glab mr update IID --draft        # -> draft
glab mr update IID --ready        # <- ready, once findings are addressed

# merge (only where policy allows — core §2.6, §10)
glab mr merge IID --yes --remove-source-branch
```

After the MR exists, `.diff_refs.base_sha` should equal the base tip as of branching. If the
base has since moved and the MR shows conflicts, **rebase onto the new base** rather than
merging the base into the branch.

## 7. Notes, discussions and replies

GitLab splits these two ways, and the split matters for the merge gate.

```bash
unset OAUTH_TOKEN; export GITLAB_HOST=<host>

# our own review record (core §5.9) — body through a file
glab api --method POST "projects/$PROJECT/merge_requests/IID/notes" \
  -f "body=$(cat /tmp/review-record.md)"

# every discussion, flattened: who opened it, resolvable, resolved
glab api --paginate "projects/$PROJECT/merge_requests/IID/discussions?per_page=100" \
  | jq -r --arg me "$ME" '
      .[] as $d | $d.notes[]
      | select(.system != true and .author.username != $me)
      | [.created_at, $d.id, .id, .author.username,
         (.resolvable|tostring), (.resolved|tostring),
         (.body|gsub("\n";" ")|.[0:700])] | @tsv'

# reply INTO someone else's discussion (never resolve it)
glab api --method POST \
  "projects/$PROJECT/merge_requests/IID/discussions/DISCUSSION_ID/notes" \
  -f "body=$(cat /tmp/reply.md)"
```

- **Thread ownership is `notes[0].author.username`** — the opener. Reply with the fix or the
  evidence; **never resolve** someone else's thread, not even to unblock a merge.
- **Skip system notes** (`notes[0].system == true`) and paginate discussions fully.
- **Non-resolvable notes are invisible to any thread count** (`individual_note == true` /
  `resolvable == false`), so a human "hold this, I want to look" would slip past the gate
  entirely. The query above deliberately returns notes regardless of resolvability; classify
  each per core §8.

## 8. Pipelines

```bash
unset OAUTH_TOKEN; export GITLAB_HOST=<host>
glab api "projects/$PROJECT/merge_requests/IID" \
  | jq -r '.head_pipeline.status // .pipeline.status'
glab ci status --branch "<branch>"
```

`success` ⇒ green. `running`/`pending` ⇒ wait. `failed` **or `null`** ⇒ do not merge — a
*missing* pipeline is not a pass, and reading `null` as "nothing to wait for" is how an
unverified head gets merged.

## 9. GitLab gotchas that have each cost real time

- **GitLab forbids self-approval, and ship never needs an approval.** `glab mr approve` is
  never called. A clean self-review on the current head is the gate (core §10). If the
  *project* enforces approvals server-side, report it and ask for one — never work around it.
- **`glab api` has no `--jq` on 1.90** (§3). A command that looks right and returns raw JSON
  will quietly break a downstream parse.
- **`glab mr create` has no `--description-file` on 1.90** (§3).
- **A `null` pipeline status is not a pass** (§8).
- **`grep -qv` on a piped path list can misreport** because of a SIGPIPE race — capture the
  non-matching lines and test for emptiness instead (core §3.3 shows the shape).
- **A dead mirror remote is a trap.** Some GitLab projects keep a `github` remote as a
  one-way mirror. If one exists, **never** use it and never run `gh` for any MR operation —
  the only write path is `glab` against the GitLab project. Check `git remote -v` once at
  the start of a run so you know what is there.
- **A stray `OAUTH_TOKEN` shadows glab auth** (§1).
- **`/code-review` and `/security-review` are GitHub-flavoured engines.** Never pass
  `--comment` or `--fix`: they build github.com URLs, post through `gh`, and append an
  attribution footer. If an engine result cites a github.com URL, rewrite it to this
  project's GitLab URL before it goes anywhere (core §5.1).
