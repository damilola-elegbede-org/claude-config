---
name: interview
description: Interview D through rounds of structured AskUserQuestion dialogs until the ask is fully understood — zero guesses, zero silent assumptions — then close with an Understanding Playback that only D's confirmation ends. Use when D says "interview me", "make sure you understand", "no guesses", or hands over a task ambiguous enough that starting would mean guessing.
argument-hint: "[the topic or task to reach full understanding on]"
metadata:
  category: workflow
---

# /interview

## Usage

```bash
/interview <topic or task>
```

Also triggers without the slash: "interview me about…", "make sure you fully understand…", "no guesses on
this one", or when a handed-over task has enough open decisions that starting means guessing.

## Description

The looped form of `/ask`. Instead of one question, run rounds of `/ask`-format questions until nothing about
the ask is a guess, then play the full understanding back for D's confirmation. The point is to surface every
silent assumption while it is still cheap to correct — not to generate ceremony.

## Expected Output

```text
User: interview me about the reporting feature
Claude: (Round 1 — one dialog, 3 related scoping questions:
         audience? cadence? delivery channel? — each with a
         recommendation)
User: (answers)
Claude: (Round 2 — one targeted follow-up opened by the answers)
User: (answers)
Claude: (UNDERSTANDING PLAYBACK dialog — goal, constraints,
         decisions D made, out of scope, remaining assumptions)
        Ask: Did I get all of it?  [Confirmed] [Fix something]
User: Confirmed
Claude: (proceeds with the work — nothing settled gets re-asked)
```

## Behavior

### 1. Map the doubt space first

Before asking anything, list (internally) every guess and silent assumption currently standing between you and
the work. Each becomes a question ONLY if D's answer would change what you'd do — a question whose answer
changes nothing is padding, and convention, the codebase, or the conversation may already answer it. Never ask
what you can verify yourself.

### 2. Cadence: broad, then deep

- **Round 1** batches up to 4 tightly-related scoping questions in one dialog to map the space.
- **Later rounds** go one-at-a-time: each targeted question shaped by the answers before it.
- Unrelated decisions never share a dialog, in any round.

### 3. Every question is an /ask

Each question follows the `/ask` format: context-adaptive scaffold, 2-4 concrete options, exactly one
**"(Recommended)"** with a one-line rationale, previews for artifacts only. Recommendations come from judgment
of the conversation — a recommendation-free menu pushes the thinking back onto D, which is what this skill
exists to prevent. Optionality is real: if every option secretly leads to the same plan, the question is fake.

### 4. Loop criterion

Continue while any unanswered question would change what you'd build or do. Stop when the next question you
can think of wouldn't.

### 5. Exit: Understanding Playback

When zero doubts remain, present the playback as the final dialog:

```text
UNDERSTANDING PLAYBACK — <topic>

Goal: <what D actually wants>
Constraints: <hard lines D set>
Decisions D made: <each ruling from the interview, compressed>
Out of scope: <what D explicitly excluded>
Assumptions I'm still making: <anything unratified — ideally empty>

Ask: Did I get all of it?
```

Options: **"Confirmed" (Recommended)** and **"Fix something"**. Only D's confirmation closes the interview;
a correction spawns another round and a fresh playback.

### 6. Escape hatch

If D says "enough", "just proceed", or similar mid-interview: stop asking, state the remaining assumptions
explicitly in prose, and proceed on them.

### 7. After confirmation

Proceed with the underlying task without re-asking anything the interview settled. The playback is the
contract — decisions ratified there don't get relitigated later in the session.

## Guardrails

- No manufactured questions: every question must trace to a real fork in the work.
- No bundling unrelated decisions into one dialog, ever.
- If D's answer challenges a question's premise, the premise was the doubt — record the correction, don't
  re-ask the original.
- An interview that ends with unstated assumptions has failed its one job; the playback's "Assumptions" line
  exists so that can't happen silently.
