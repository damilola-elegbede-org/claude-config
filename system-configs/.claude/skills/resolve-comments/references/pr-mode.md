# PR mode — fetch, resolve, verify

Default mode: no `--code-rabbit` / `--local` flag.

## STEP 1: Determine PR number

```text
IF: pr-number argument provided
  USE: provided number
ELSE:
  RUN: gh pr view --json number -q '.number'
  IF: fails
    OUTPUT: "No PR found for current branch. Create one with: gh pr create"
    END

VALIDATE: pr-number is a positive numeric integer <= 2147483647
  IF: not → OUTPUT "Invalid PR number" and END
```

## STEP 2: Fetch unresolved CodeRabbit comments (paginated)

```text
INITIALIZE: all_issues = [], threads_cursor = null, has_more_threads = true, modified_files = []

VALIDATE: owner/repo from gh repo view --json owner,name
  These values are interpolated into shell/API arguments — treat as a trust boundary.
  SANITIZE: owner matches ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ (no leading/trailing/consecutive hyphens),
            length <= 39
  SANITIZE: repo matches ^[a-zA-Z0-9_.-]+$, length <= 100, not "." , no ".git" suffix
  REJECT: any slashes or ".." path-traversal sequences in either value
  IF: any check fails → OUTPUT "Invalid repository name: contains disallowed characters" and END
  IF: gh repo view fails
    OUTPUT: "Failed to get repository info. Ensure gh is authenticated and run from within a git repository."
    END

WHILE: has_more_threads
  RUN: gh api graphql -f query='
    query($owner: String!, $repo: String!, $pr: Int!, $after: String) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $pr) {
          reviewThreads(first: 100, after: $after) {
            pageInfo { endCursor hasNextPage }
            nodes {
              id
              isResolved
              comments(first: 100) {
                pageInfo { endCursor hasNextPage }
                nodes { id path line body author { login } }
              }
            }
          }
        }
      }
    }' -F owner="{owner}" -F repo="{repo}" -F pr="{pr}" -F after="{threads_cursor}"

  ON_ERROR:
    rate limit / 403 → OUTPUT "GitHub API rate limited. Wait 60s or check: gh auth status"; END
    Bad credentials / 401 → OUTPUT "GitHub authentication failed. Run: gh auth login"; END
    malformed or unresolvable → RETRY once after 2s; if retry fails, OUTPUT and END

  FOR_EACH: thread in reviewThreads.nodes
    IF: thread.isResolved == true → SKIP
    STORE: thread_id = thread.id
    WHILE: thread.comments.pageInfo.hasNextPage
      RUN: fetch additional comments with comments_cursor; APPEND to thread.comments.nodes
    FOR_EACH: comment in thread.comments.nodes
      IF: comment.author.login (lowercased) contains "coderabbit"
        APPEND: {...comment fields, thread_id} to all_issues

  SET: threads_cursor = reviewThreads.pageInfo.endCursor
  SET: has_more_threads = reviewThreads.pageInfo.hasNextPage
```

Outer loop paginates threads (>100); inner loop paginates comments within a thread (>100). The
comment-level author filter is what keeps non-CodeRabbit reviewers out.

### Parse each comment body

```text
SEVERITY/TYPE HEADER: emoji + type + "|" + emoji + severity
  "🔧 Nitpick | 🔵 Trivial"        → type=nitpick,  severity=LOW
  "⚠️ Potential issue | 🟡 Major"  → type=issue,    severity=MEDIUM
  "🚨 Critical | 🔴 Critical"      → type=critical, severity=HIGH

  Type (lowercase, strip emoji/punctuation): Nitpick→nitpick, Potential issue→issue,
    Issue→issue, Critical→critical, Unknown→other
  Severity: Trivial→LOW, Minor→LOW, Major→MEDIUM, Critical→HIGH

AI PROMPT EXTRACTION:
  Find section starting "🤖 Prompt for AI Agents" or "🤖 Fix all issues with AI agents"
  Extract the following text block → issue.ai_prompt; SET issue.requires_analysis = false

FALLBACK: no ai_prompt → issue.ai_prompt = null, issue.requires_analysis = true
```

OUTPUT: `"Fetched {count} unresolved CodeRabbit comments from PR #{pr}"`

## STEP 3-4: Triage and apply

See `triage.md`.

## STEP 5: Finalize

```text
IF: skipped_issues not empty
  WRITE: .tmp/coderabbit-ignored.json (schema_version "1.0" at top level — see schemas.md)
  OUTPUT: "Saved {count} skipped issues for /ship-it acknowledgment"

IF: fixes applied
  ASK (AskUserQuestion, header "Commit+push"):
    "Commit, push, and post resolution to PR #{pr}? ({fix_count} fixes on {current_branch})"
      - "Commit, push, post" → full flow below
      - "Local only" → keep working-tree changes; no commit/push/comment
    Freeform "Other" → treat as "Local only" unless it clearly authorizes commit+push.

  IF: "Commit, push, post"
    IF: fix_count == 0 → OUTPUT "No fixes to commit. Skipping git operations."; SKIP git steps
    RECONCILE: modified_files against git diff --name-only
      VALIDATE each file: relative path, no "..", resolves inside $(git rev-parse --show-toplevel)
        IF: any fails → OUTPUT "Error: Invalid file path detected - aborting for security"; END
      IF: unexpected files detected
        ASK (header "Extra files"): "Detected changes to files not in the fix list."
          - "Exclude extras (Recommended)" → git add only the reconciled list
          - "Include all" → expand to full git diff --name-only
          Freeform → default to exclude extras
    RUN: git add {modified_files}      # never git add -A
    RUN: git commit -m "fix: resolve CodeRabbit feedback ({fix_count} issues)"
    RUN: git push
```

### Post thread resolutions (do not skip)

CodeRabbit only marks a thread resolved when that thread receives a direct reply. This is separate
from the PR-level comment. Skipped issues get an acknowledgment reply too, so threads don't sit open
forever.

```text
SET: all_issues = fixed_issues + skipped_issues   (default each to [] if undefined)
IF: all_issues empty → OUTPUT "No issues to post resolutions for"; SKIP this block
INITIALIZE: resolution_results = [], success_count = 0, failure_count = 0

FOR_EACH: issue in all_issues          # every thread needs its own mutation — never batch
  IF: issue.thread_id missing/empty
    APPEND {location, status:"skipped", error:"missing thread_id"}; INCREMENT failure_count
    OUTPUT "Warning: Skipped {issue.location} - missing thread_id"; CONTINUE

  IF: issue in fixed_issues
    body_prefix = "Fixed"; body_detail = summary of fix from issue.description
      (if description missing/empty → "Issue resolved")
  ELSE
    body_prefix = "Acknowledged"; body_detail = issue.reason
      (if missing/empty → "Reviewed and acknowledged")

  SANITIZE: body_detail BEFORE truncating (so escapes aren't cut mid-sequence)
    - escape " → \", ` → \`, and $ → \$ (the $ escape specifically blocks $() command
      substitution — escaping quotes and backticks alone does not stop it)
    - control chars (newline, tab) → space
    - protect @coderabbitai as {{CODERABBIT}}, neutralize all other @mentions (@user → `@`user),
      then restore {{CODERABBIT}} → @coderabbitai
    - truncate to 100 chars AFTER sanitization
    IF: empty after sanitization → "Issue resolved"

  NOTE: thread_id is opaque per GitHub docs — never decode or pattern-validate node IDs.

  SAFETY: body_detail crosses a trust boundary — it's derived from a CodeRabbit PR comment, not
    typed by the user. Never build the mutation by splicing it into a shell string that then gets
    re-parsed; escaping is defense in depth, not the primary control. Write the composed message to
    a file and pass it with gh's `@file` syntax, which reads the value as literal bytes with no
    shell re-interpretation of its contents:

  TRY:
    WRITE: "@coderabbitai resolve - {body_prefix}: {body_detail}" to .tmp/thread-reply-{issue.id}.txt
    RUN: gh api graphql -f query='
      mutation($threadId: ID!, $body: String!) {
        addPullRequestReviewThreadReply(input: {
          pullRequestReviewThreadId: $threadId, body: $body
        }) { comment { id } }
      }' -F threadId="{issue.thread_id}" -F body=@.tmp/thread-reply-{issue.id}.txt
    DELETE: .tmp/thread-reply-{issue.id}.txt
    INCREMENT success_count; OUTPUT "Resolved thread ({body_prefix}): {issue.location}"
  ON_ERROR:
    CAPTURE error; INCREMENT failure_count
    OUTPUT "Warning: Failed to resolve {issue.location}: {error_message}"

OUTPUT: "Thread resolution complete: {success_count} succeeded, {failure_count} failed"
IF: failure_count > 0 → OUTPUT the failed locations
IF: success_count == 0 AND failure_count > 0 → OUTPUT "⚠️ WARNING: All thread resolutions failed."
IF: success_count > 0 AND failure_count > 0 → OUTPUT "⚠️ Partial success: {success}/{failure}"
```

### Post-resolution verification (exit 1 on failure)

Posting `@coderabbitai resolve` is not the same as the threads actually flipping to resolved.
CodeRabbit has to observe the reply and set `isResolved` server-side. If that fails silently, a later
run or an automated gate still sees unresolved threads while the PR may already be marked ready.

```text
SLEEP: 30 seconds     # CodeRabbit needs time to process the replies

INIT: all_thread_nodes = [], cursor = null
LOOP:
  RUN: gh api graphql -F owner="{owner}" -F repo="{repo}" -F pr="{pr_number}" -F cursor="{cursor}" -f query='
    query($owner: String!, $repo: String!, $pr: Int!, $cursor: String) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $pr) {
          reviewThreads(first: 100, after: $cursor) {
            nodes { id isResolved comments(first: 1) { nodes { path line } } }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    }'
  APPEND: nodes to all_thread_nodes
  IF: not hasNextPage → BREAK
  SET: cursor = endCursor

PARSE: unresolved = nodes where isResolved == false
IF: unresolved non-empty
  STDERR: "ERROR: {n} thread(s) remain unresolved after @coderabbitai resolve replies:"
  STDERR: "  - {thread.id} @ {path}:{line}" for each
  EXIT: 1

OUTPUT: "✅ Verified: all {success_count} threads now isResolved=true"
```

### PR summary comment

```text
COMPUTE: total, fix_count, skip_count
GENERATE: markdown summary from all_issues
  Categories: security→Security, error→Error Handling, performance→Performance,
              docs→Documentation, test→Testing, quality/other→Code Quality
    - unknown/missing type → Code Quality; multi-category → primary by severity
  Structure:
    "## CodeRabbit Feedback Resolution"
    "**Resolved {total} review comments: {fix_count} fixed, {skip_count} acknowledged**"
    category breakdown for fixed issues (omit empty categories)
    file-by-file changes, <=100 chars per description (consolidate duplicate paths)
    IF skipped_issues non-empty: "### Acknowledged (not fixed)" + table | Location | Reason |
  Edge cases: no file association → "General"; all skipped → omit category breakdown
  Sanitize descriptions: strip HTML/script tags, escape backticks, escape @mentions except
    @coderabbitai, remove control characters
  Limit to 2000 chars with structure-aware truncation (keep category counts, cut file detail)
  IF generation fails → fallback body:
    "@coderabbitai resolve - Resolved {total} review comments ({fix_count} fixed,
     {skip_count} acknowledged). See commit for details."
WRITE: summary to .tmp/pr-comment.md
VALIDATE: .tmp/pr-comment.md exists and size > 0, else use the fallback body directly
RUN: gh pr comment {pr} --body-file .tmp/pr-comment.md
OUTPUT: "Posted @coderabbitai resolve with change summary to PR #{pr}"

ELSE (Local only): OUTPUT "Skipped commit/push/comment. Local changes preserved."

OUTPUT: "Resolved {total} comments: {fix_count} fixed, {skip_count} acknowledged"
```
