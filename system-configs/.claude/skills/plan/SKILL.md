---
name: plan
description: Shape a task into a complete PRD and task files by walking the decision tree in the open — self-answering with software-engineering best practices and streaming each decision for live override. Use when planning a feature, project, or task.
argument-hint: "[task] [--simple|--no-execute|--file]"
context: fork
metadata:
  category: workflow
---

# /plan

## Usage

```bash
/plan <task>              # Walk the decision tree → PRD + task files
/plan --simple <task>     # Single-PR plan (small features), lighter tree
/plan --no-execute <task> # Stream the tree + PRD preview only, write nothing
/plan --file <path>       # Read the requirement from a file
```

## Description

Turn a rough idea into a complete, buildable plan in one pass. Rather than handing off to an
opaque planning agent, `/plan` walks the decision tree itself, answers each question with
best-practice defaults grounded in the actual codebase, and **streams every decision as
`Q / A / Why`** so you can catch a bad assumption while it is being made. The output is a PRD
plus per-PR task files — each with an `## Acceptance` section — that `/implement` consumes
directly and `/feature-lifecycle` loops until.

## Instructions

### 1. Capture the task

Use `$ARGUMENTS` (or the `--file` contents). If empty, ask once:

> What do you want to build? (one paragraph is fine)

Then proceed without further interactive questions until the write step.

### 2. Ground in the codebase

Before answering anything:

- Read `README.md`, `CLAUDE.md`, and any architecture docs.
- Identify existing modules, conventions, test patterns, and prior art the work should match.
- Verify factual claims in the request against the code — don't trust, check.
- Note the language, framework, test runner, and directory layout.

Greenfield/empty repo: skip to step 3 and record it in the PRD's notes.

### 3. Walk the decision tree

For each branch, generate the questions a thorough engineer would ask, then answer each
one yourself. **Do not skip a branch because it feels obvious — completeness is the point.**

- **Actors & user stories** — who uses this, what they want, what success looks like
- **Happy-path flow** — the primary interaction, step by step
- **Edge cases** — empty/large inputs, concurrency, partial failures, network errors, permission denied, missing data, encoding, time zones
- **Data model & schema** — entities, relationships, indexes, migrations
- **Module boundaries** — deep modules, public interfaces, what stays internal
- **API contracts** — request/response shapes, error codes, idempotency, versioning
- **Testing strategy** — what to test, what to mock (boundaries only), prior art in the repo
- **Security** — authn/authz, input validation, secrets, rate limiting
- **Observability** — what to log, what to surface as metrics
- **Out of scope** — explicit non-goals
- **Dependencies & blockers** — what must exist first

`--simple` walks only: actors, happy-path, edge cases, testing, out-of-scope.

### 4. Best-practice defaults

When self-answering, prefer: boring over clever; deep modules (Ousterhout — wide functionality
behind a simple, stable interface); match the codebase over external standards; TDD-friendly
design (testable through public interfaces, not internals); validate at system boundaries;
YAGNI; parameterized queries; rate-limited auth endpoints; never log secrets or PII; mock only
at system boundaries. **Codebase facts beat generic best practices** — if the project already
does X, the answer is X.

### 5. Stream the decisions

Emit each decision as you make it — do not batch:

```
Q: <the question>
A: <the chosen answer>
Why: <one sentence — cite a codebase reference if relevant>
```

This is the moment to override a bad assumption.

### 6. Write the PRD + task files

Unless `--no-execute`, write to `.tmp/plans/<repo>/<feature>/`:

- `prd.md` — Problem, Solution, User Stories, Implementation Decisions, Testing, Security, and Out of Scope, synthesized from the tree. No file paths or code snippets — they go stale.
- `phase_<n>_pr_<m>_<slug>.md` — one file per PR-sized slice. Each MUST match the format `/implement` consumes:

```markdown
# <Slice Name>

## Tasks
1. [ ] <task>  (depends on: <n>)

## Acceptance
- [ ] <verifiable criterion>
```

`--no-execute`: stream the tree + a PRD preview, write nothing.

### 7. Report

Print the paths written and the next step (`/implement <first phase file>`).

## Notes

- `context: fork` — the tree walk runs in a forked context; only the streamed decisions and final paths surface.
- Every task file carries an `## Acceptance` section — it is the contract `/implement` verifies against and the gate `/feature-lifecycle` loops until.
- Interactive only at two points: capturing the idea (if not given) and any override you inject mid-stream.
- `--simple` produces a single slice; larger plans fan out into multiple `phase_*` files with `depends on:` ordering.
