---
name: ask
description: Pose a decision to D through the AskUserQuestion dialog instead of plain text. Use whenever D says "ask me", "get my input", "check with me", "which should we", or any time a decision needs D's answer before work continues — even if D doesn't say "ask" explicitly. One clear question, 2-4 options, exactly one recommendation.
argument-hint: "[the decision to put to D]"
metadata:
  category: workflow
---

# /ask

## Usage

```bash
/ask <decision to put to D>
```

Also triggers without the slash: "ask me…", "get my input on…", "check with me before…", or any moment a
decision is D's to make and plain-text questions would go unanswered.

## Description

The question primitive. D answers decisions through the `AskUserQuestion` dialog, not prose — the dialog takes
focus immediately, so anything load-bearing that sits in prose above it goes unread. This skill defines the one
question format every D-facing ask uses; `/interview` and `/process-linear` both build on it.

## Expected Output

```text
User: ask me which auth approach to use
Claude: (AskUserQuestion dialog)
        Ask: Which auth approach for the API?
        [JWT (Recommended) — matches the existing session model]
        [OAuth2] [API keys]
User: (picks JWT)
Claude: Going with JWT — wiring it into the middleware now.
```

## Behavior

### One decision per question

Ask exactly one thing. A dialog may carry up to 4 questions only when they are tightly-related facets of the
same decision — unrelated decisions never share a dialog. Use `multiSelect` when the choices are not mutually
exclusive.

### Question format (D's ratified ask format, 2026-07-17)

All decision-relevant context lives inside the dialog. The scaffold is **context-adaptive**:

- **Warm** (the subject is already live in this conversation): just the ask.

  ```text
  Ask: Which naming scheme for the new module?
  ```

- **Cold** (the subject arrives fresh — a ticket, an alert, a new topic): full scaffold, each part 1-2 short
  lines, never a run-on paragraph of inlined figures and IDs:

  ```text
  <headline — what this is about, verbatim title if it has one>

  Context: <what this is, in plain words — no digging required>
  Latest: <the most recent material update, dated>
  Why it matters: <consequence of this decision>

  Ask: <exactly ONE clear question>
  ```

### Options

- 2-4 concrete options; tag exactly one **"(Recommended)"** with a one-line rationale in its description.
  The recommendation comes from judgment of the conversation — never present a bare menu with no lean.
- Option `preview` panes carry **artifacts only** — exact message copy, a diff summary, the dollar math a choice
  would enact. A preview that re-narrates context D already has is noise.
- Don't spend option slots on "skip"/"other" — the dialog always lets D type a custom answer.

### After the answer

Act on it. If the answer changes something recorded elsewhere (a ticket, a doc), write the decision where it
belongs before moving on.

## Notes

- `/interview` is the looped form of this skill — rounds of `/ask`-format questions until zero doubts remain.
- If D's answer challenges the premise of the question, treat that as the real answer — don't re-ask.
