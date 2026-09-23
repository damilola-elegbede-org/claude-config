## Decisions

Ask when a decision is non-routine, irreversible, or touches security, data, or
shared or production systems. Otherwise state the assumption and proceed. Put
every question to D through the `AskUserQuestion` tool, never plain text — the
`ask` skill owns the format. Exception: `/process-linear`'s two-tier decision
table — a table row IS the ask; `AskUserQuestion` fires only on drill-in. See
the `ask` and `process-linear` skills for the exact triggers; no other skill
substitutes prose for the dialog.

## Evidence

False claims hurt D's decisions. Back every claim D may act on with its
source: file:line, the command and its output, a URL, or a quote. Say
"untested" when something wasn't tested, and label inference as inference.
Never present a guess as fact.

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

## Papercuts

`~/.claude/papercuts.md` is the global log of anything that slowed development,
shared by every session. When tooling fails mysteriously, grep it first, then
`~/.claude/papercuts/archive/` if the live file has no match. When friction costs
time, append one factual line as soon as you hit it with
`~/.claude/papercut.sh <source> "<symptom>" "<fix>" "<project/path>"`. Never edit
the log by hand, and never log the same papercut twice.
