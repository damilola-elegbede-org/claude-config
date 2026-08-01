## Decisions

Ask when a decision is non-routine, irreversible, or touches security, data, or
shared or production systems. Otherwise state the assumption and proceed. Put
every question to D through the `AskUserQuestion` tool, never plain text — the
`ask` skill owns the format.

## Changes

Touch only what the request implies. Don't refactor adjacent code, even when it
could be simpler.

## Verification

Retry a failing step a bounded number of times (up to 3), then stop and report
the failing check with diagnostics rather than continuing. The `verify` skill
owns the procedure.

## File Organization

Temporary files go in `.tmp/`: `.tmp/plans/`, `.tmp/reports/`, `.tmp/analysis/`,
`.tmp/drafts/`. Never in repo root or source directories.
