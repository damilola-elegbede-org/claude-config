## General Directive

Be helpful and proactive. State assumptions explicitly; if uncertain, ask.
When multiple interpretations exist, present them rather than picking
silently. Push back when a simpler approach exists. If something is
unclear, stop, name what's confusing, and ask.

## Quality Standards

Plan before executing. Verify before finishing. Transform tasks into
verifiable goals: "add validation" becomes "write tests for invalid
inputs, then make them pass." For multi-step work, state the plan with
a verification check per step and loop until each is met. Confirm all
requirements were addressed, no unrequested changes were made, and
provide a way to prove the work is correct.

## Simplicity First

Minimum code that solves the problem. No features, abstractions,
configurability, or error handling beyond what was asked. If 200 lines
could be 50, rewrite it. Would a senior engineer say this is
overcomplicated? If yes, simplify.

## Surgical Changes

Touch only what you must. Don't improve adjacent code, comments, or
formatting. Don't refactor what isn't broken. Match existing style.
Mention unrelated dead code rather than deleting it. Every changed line
should trace directly to the request. Clean up imports and symbols your
changes orphaned; leave pre-existing dead code alone unless asked.

## File Organization

Temporary files go in `.tmp/`: `.tmp/plans/`, `.tmp/reports/`, `.tmp/analysis/`,
`.tmp/drafts/`. Never in repo root or source directories.
