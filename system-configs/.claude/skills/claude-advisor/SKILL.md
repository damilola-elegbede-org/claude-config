---
name: advisor
description: Pair Sonnet executor with Opus advisor for complex tasks
argument-hint: "<task description>"
category: orchestration
context: fork
---

# /advisor

## Usage

```bash
/advisor refactor the auth module
/advisor design the caching strategy for the API
/advisor fix the flaky payments test
```

## Description

Implements the advisor strategy: a Sonnet executor handles the task end-to-end, consulting
the `claude-advisor` Opus agent on-demand when it hits decisions too complex or high-stakes
to resolve independently. Routine steps run at Sonnet speed and cost; elevated reasoning
is reserved for decision gates that actually need it.

## Execution Script

```text
STEP 1: Intake
  PARSE: $ARGUMENTS for task description
  IF: no task description provided
    ASK user for task description via AskUserQuestion
  IDENTIFY: up front, which aspects of this task have complex decision points
    (architectural choices, irreversible actions, ambiguous tradeoffs, security implications)
  OUTPUT: "advisor strategy: [task summary]"
  OUTPUT: "decision gates identified: [list or 'none detected — will escalate dynamically']"

STEP 2: Executor loop
  FOR each step in the task:
    EVALUATE: is this step routine or a decision gate?

    IF routine:
      EXECUTE directly using available tools
      CONTINUE to next step

    IF decision gate:
      ESCALATE to claude-advisor agent (see Step 3)
      APPLY returned guidance
      CONTINUE with advised approach

STEP 3: Advisor escalation (when triggered in Step 2)
  INVOKE: claude-advisor agent via Agent tool
  PASS: full current context + the specific decision requiring guidance
  RECEIVE: focused strategic advice from Opus
  IF: advice signals user escalation (decision requires user input, not strategic judgment)
    ASK user via AskUserQuestion with the advisor's framing of the decision
    APPLY user's response as the direction for this step
  LOG: "advisor consulted: [decision summary] → [advice summary]"
  RETURN to Step 2 executor loop

STEP 4: Completion
  COMPLETE the task
  SUMMARIZE:
    - What was accomplished
    - How many times the advisor was consulted and on which decisions
    - Any open questions or follow-up recommendations from the advisor
```

## Decision Gate Criteria

Escalate to the advisor when any of these apply:

- Multiple valid approaches exist with non-obvious tradeoffs
- Action is irreversible (deletes data, drops schema, force-pushes)
- Security or auth implications detected
- Architectural choice that constrains future options
- Executor confidence is low and the stakes are meaningful

Handle directly when:

- Mechanical implementation with a clear correct answer
- Formatting, naming, or style decisions
- Steps already resolved by prior context or user instruction

## Expected Output

```text
advisor strategy: refactor the auth module
decision gates identified: session storage approach, middleware ordering

[executor handles file reads and initial analysis directly]

advisor consulted: session storage approach → use Redis with TTL, avoid JWT for server-side sessions given compliance context
advisor consulted: middleware ordering → auth before rate-limit to avoid leaking rate-limit headers to unauthenticated requests

[executor implements with advised approaches]

Done. Auth module refactored.
Advisor consulted 2 times: session storage strategy, middleware ordering.
```
