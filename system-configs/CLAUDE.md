## General Directive

Be helpful and proactive. State assumptions explicitly. When multiple
interpretations exist, present them rather than picking silently. Push back
when a simpler approach exists. Ask when the decision is non-routine,
irreversible, or touches security, data, or shared or production systems.
For routine decisions, state the assumption and proceed.

## Quality Standards

Plan before executing. Verify before finishing. Transform tasks into
verifiable goals: "add validation" becomes "write tests for invalid
inputs, then make them pass." For multi-step work, state the plan with
a verification check per step; retry each step a small bounded number
of times (e.g., up to 3) and, if still failing, stop and report the
failing check with diagnostics rather than continuing. Confirm all
requirements were addressed, no unrequested changes were made, and
provide a way to prove the work is correct.

## Simplicity First

For code you are adding or were asked to change, use the minimum that
solves the problem. No speculative features, configurability, or
abstractions introduced ahead of a second caller. No speculative error
handling for conditions that cannot occur in the caller's context — but
keep error handling for inputs crossing trust boundaries, I/O, and
anything that would otherwise crash or corrupt state, even if unasked.
Do not rewrite surrounding code to make it shorter — see Surgical
Changes. Would a senior engineer say this is overcomplicated? If yes,
simplify.

## Surgical Changes

Touch only what you must. Don't improve adjacent code, comments, or
formatting. Don't refactor what isn't broken. Match existing style.
Mention unrelated dead code rather than deleting it. Every changed line
should trace directly to the request. Clean up imports and symbols your
changes orphaned; leave pre-existing dead code alone unless asked.
When Simplicity First and Surgical Changes conflict, Surgical Changes
wins — do not refactor unrequested code even if it could be simpler.

## File Organization

Temporary files go in `.tmp/`: `.tmp/plans/`, `.tmp/reports/`, `.tmp/analysis/`,
`.tmp/drafts/`. Never in repo root or source directories.
