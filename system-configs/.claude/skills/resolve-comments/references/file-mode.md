# File mode — triage `/review` output from `.tmp/`

Active when `--code-rabbit` and/or `--local` is passed. `--local` reads the file `/review` writes.

## STEP 1: Load issues

Both sources follow the same shape. `CURRENT_SCHEMA_VERSION = "1.0"`.

```text
issues = []

IF: --code-rabbit flag
  READ: .tmp/review-coderabbit.json
  IF: not found
    OUTPUT: "Warning: No CodeRabbit issues file found (.tmp/review-coderabbit.json)"
    CONTINUE            # check the other source; do not END
  VALIDATE: schema_version exists AND == CURRENT_SCHEMA_VERSION
    IF: missing or mismatched
      COPY: file → .tmp/review-coderabbit.backup-{timestamp}.json
      DELETE: .tmp/review-coderabbit.json
      OUTPUT: "⚠️ Schema version mismatch in review-coderabbit.json (found: {v}, expected: {CURRENT}).
               Backed up to {backup_path}. Re-run /review --code-rabbit to regenerate."
      CONTINUE          # skip this source, do not END
  APPEND: issues with source="coderabbit"
  OUTPUT: "Loaded {count} CodeRabbit issues"

IF: --local flag
  Same flow against .tmp/review-local.json, source="code-reviewer",
  regeneration hint "Re-run /review to regenerate."
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
  OUTPUT: "Saved {count} skipped issues (will be posted to PR via /ship-it)"

OUTPUT: "Fixed {fix_count} issues, skipped {skip_count}"
```
