# Schemas and caller compatibility

## Ignored issues — `.tmp/coderabbit-ignored.json`

<!-- SCHEMA VERSION: "1.0" — Any breaking schema changes MUST increment schema_version. -->
<!-- Readers (e.g. pr/SKILL.md) validate this field on load and reject stale files. -->

```json
{
  "schema_version": "1.0",
  "branch": "feature/my-feature",
  "created_at": "2025-01-10T12:00:00Z",
  "ignored_issues": [
    {
      "id": 1,
      "source": "coderabbit|code-reviewer",
      "location": "file.ts:45",
      "description": "Issue description",
      "severity": "LOW",
      "category": "nitpick|low-priority|user-skipped",
      "reason": "Auto-generated reason from evaluation"
    }
  ]
}
```

`/ship-it` reads this file to acknowledge what was consciously not fixed.

## Context compatibility

This skill needs `AskUserQuestion` and so MUST NOT run with `context: fork` — a forked context can't
show the dialog to the user. A caller that runs it forked must pass `--auto` to bypass the prompts.

| Caller              | Flag required | Reason                          |
| ------------------- | ------------- | ------------------------------- |
| Direct user         | none          | Interactive triage available    |
| `/review`           | `--auto`      | Runs in `context: fork`         |
| `/feature-lifecycle`| `--auto`      | Autonomous orchestrator         |

## Worked examples

### PR mode

```text
User: /resolve-comments

Fetched 3 unresolved CodeRabbit comments from PR #42

Review Issues:

| # | Src | Description | Action |
|---|-----|-------------|--------|
| 1 | CR | auth.ts:45 - Missing error handling | FIX |
| 2 | CR | api.ts:12 - Add input validation | FIX |
| 3 | CR | utils.ts:8 - Use const vs let | SKIP |

Summary: 2 to fix, 1 to skip

[User selects "Approve all fixes (2 issues)"]

Fixed (using CodeRabbit AI prompt): Missing error handling
Fixed (using CodeRabbit AI prompt): Add input validation

Committed: fix: resolve CodeRabbit feedback (2 issues)
Pushed to origin
Resolved thread (Fixed): auth.ts:45
Resolved thread (Fixed): api.ts:12
Resolved thread (Acknowledged): utils.ts:8
Thread resolution complete: 3 succeeded, 0 failed
Posted @coderabbitai resolve with change summary to PR #42

Resolved 3 comments: 2 fixed, 1 acknowledged
```

### File mode

```text
User: /resolve-comments --code-rabbit --local

Loaded 3 CodeRabbit issues
Loaded 2 AI reviewer issues

Review Issues:

| # | Src | Description | Action |
|---|-----|-------------|--------|
| 1 | CR | auth.ts:45 - Missing error handling | FIX |
| 2 | CR | api.ts:12 - Add input validation | FIX |
| 3 | Agent | db.ts:78 - SQL injection risk | FIX |
| 4 | Agent | perf.ts:23 - N+1 query detected | FIX |
| 5 | CR | utils.ts:8 - Use const vs let | SKIP |

Summary: 4 to fix, 1 to skip

[Interactive triage continues...]
```
