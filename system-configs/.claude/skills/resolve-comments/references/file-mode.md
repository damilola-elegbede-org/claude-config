# File mode — triage `/review` output from `.tmp/`

Active when `--local` is passed. Reads the file `/review` writes (`.tmp/review-local.json`).

## STEP 1: Load issues

`CURRENT_SCHEMA_VERSION = "1.0"`.

```text
issues = []

IF: --local flag
  READ: .tmp/review-local.json
  IF: not found → skip to the empty check below
  VALIDATE: schema_version exists AND == CURRENT_SCHEMA_VERSION
    IF: missing or mismatched
      COPY: file → .tmp/review-local.backup-{timestamp}.json
      DELETE: .tmp/review-local.json
      OUTPUT: "⚠️ Schema version mismatch in review-local.json (found: {v}, expected: {CURRENT}).
               Backed up to {backup_path}. Re-run /review to regenerate."
  APPEND: issues with source="code-reviewer"
  OUTPUT: "Loaded {count} AI reviewer issues"

IF: issues empty
  OUTPUT: "No issues to triage. Run /review first to generate issue files."
  END
```

## STEP 2-3: Triage and apply

See `triage.md`.

## STEP 4: Finalize

File mode commits but never pushes or comments — there may be no PR yet.

```text
IF: fixes applied AND fix_count > 0
  ASK (AskUserQuestion, header "Commit?"): "Commit {fix_count} fixes to the repository?"
    - "Commit fixes"     → stage + local commit (no push)
    - "Keep uncommitted" → leave as working-tree changes for the caller to commit
    Freeform "Other" → default to keep uncommitted

  IF: "Commit fixes"
    RECONCILE: modified_files against git diff --name-only
    RUN: git add {modified_files}      # never git add -A
    RUN: git commit -m "fix: resolve review feedback ({fix_count} issues)"
    OUTPUT: "Committed {fix_count} fixes"
  ELSE
    OUTPUT: "Changes preserved but not committed"

IF: skipped_issues not empty
  WRITE: .tmp/coderabbit-ignored.json (schema_version "1.0" — see schemas.md)
  OUTPUT: "Saved {count} skipped issues (posted to the PR by /pr or /ship-it)"

OUTPUT: "Fixed {fix_count} issues, skipped {skip_count}"
```
