---
name: process-bareclaude
description: Walk D through the BareClaude Linear triage one decision at a time, driven by Clara's saved workspace views — Needs Unblocking and Needs Your Sign-off — each ticket with full context, recommended options, and clickable ticket links. Use when D wants to clear the Linear decision/approval queue.
argument-hint: "[--view signoff|unblock|deadlines|ungroomed|all] [--team ENG|OPS|all]"
metadata:
  category: workflow
---

# /process-bareclaude

## Usage

```bash
/process-bareclaude                  # Decision views: Needs Unblocking, then Needs Your Sign-off
/process-bareclaude --view signoff   # Only "Needs Your Sign-off"
/process-bareclaude --view unblock   # Only "Needs Unblocking"
/process-bareclaude --view deadlines # Risk pass over "Upcoming Deadlines"
/process-bareclaude --view ungroomed # Grooming pass over "Ungroomed Backlog"
/process-bareclaude --view all       # All four views in order
/process-bareclaude --team OPS       # Restrict to Operations
```

## Description

Interactive triage of D's Linear workspace (`bareclaude`), driven by **Clara's saved workspace views**. Surfaces
the queues that gate the fleet and walks the decision ones ticket by ticket. For each ticket, Claude gathers full
context (description + comments + relations), then asks D exactly one `AskUserQuestion` with 2–4 concrete options,
**always including a recommendation**, and **always** presenting the ticket as a clickable hyperlink. D's answer is
recorded back to Linear as a structured decision comment + a state change before moving to the next ticket.

The fleet's agents (Clara/ops, Dara/eng, TARS) create and work these tickets and delegate decisions back to D. This
skill is the mechanism for clearing that decision backlog fast — without losing decision quality.

## Expected Output

```text
User: /process-bareclaude
Claude: Loading BareClaude triage views…
  🚫 Needs Unblocking (Blocked, OPS+ENG) ...... 7 tickets
  ⏳ Needs Your Sign-off (In Review) .......... 12 tickets

Proposed order (most-unblocking first):
  1. ENG-42  (blocks 4)  https://linear.app/bareclaude/issue/ENG-42/...
  2. OPS-17  (blocks 2)  https://linear.app/bareclaude/issue/OPS-17/...
  ...
[dry-run question] Proceed / reorder / drop some?

User: proceed
Claude: [ENG-42] Blocked on a policy decision — <2-line context>.
        (options via AskUserQuestion; one tagged "(Recommended)")
User: <picks an option>
Claude: ✓ Recorded [triage-decision] comment on ENG-42, set state → Todo
        ✓ Noted the unblock on 4 dependents
        Next → OPS-17 …

Recap:
  Decided: 6 · Deferred: 1 · Skipped (state drift): 1
  Comments posted: 11 · States changed: 6
```

## Behavior

### 1. Resolve the views (mirror Clara's saved views by filter)

The Linear MCP cannot fetch a saved view object directly, so this skill reproduces each of Clara's views by its
filter. Keep the names identical to the workspace views so they stay conceptually linked:

| Skill view | Clara's saved view | Filter (`list_issues`) | Mode |
| --- | --- | --- | --- |
| `unblock` | **Needs Unblocking** | `state: Blocked` (OPS + ENG) | Interactive decision |
| `signoff` | **Needs Your Sign-off** | `state: In Review` (+ `needs-d` label if adopted) | Interactive decision |
| `deadlines` | **Upcoming Deadlines** | issues with a `dueDate`, order by dueDate asc | Risk pass |
| `ungroomed` | **Ungroomed Backlog** | `state: Backlog` where description lacks `## Acceptance` | Grooming pass |

Default (`--view all` off) processes the two **decision** views only: **Needs Unblocking**, then **Needs Your
Sign-off**. Apply `--team` to scope. If the MCP later exposes saved views directly, switch to fetching the view by
name instead of re-deriving the filter.

### 2. Prefetch everything, in parallel

For every queued ticket, fetch description, comments, and relations (`blocks` / `blockedBy`) in one parallel batch.
Speed comes from prefetch — not from bundling decisions.

### 3. Order by leverage

Process **Needs Unblocking** fully before **Needs Your Sign-off**. Within each, sort by: outgoing `blocks` count
(most dependents first) → priority → age. For **Upcoming Deadlines**, sort by soonest dueDate. No transitive
(depth > 1) dependency analysis.

### 4. Dry-run summary first (one question)

Present a single hyperlinked list of the queue with proposed order and, per ticket, a one-line "why it's here" +
dependent count. Ask D once: **proceed / reorder / drop some**. This is the ONLY batching in the skill.

### 5. Just-in-time re-fetch before each ask

Immediately before asking about a ticket, re-fetch its current state. If it changed since prefetch, or a prior
`[triage-decision]` marker comment already exists, **skip it with a note** (idempotency + race safety).

### 6. Ask exactly one question

- Put the **full linear.app URL** in prose — use the `url` the MCP returns; never string-build it.
- 2–4 concrete options; tag exactly one **"(Recommended)"** with a one-line rationale.
- If any option's real substance lives outside Linear (vault / Notion / #briefs), say so and mark the recommendation
  **tentative** — never present a confident rec built on a doc you did not read; offer to pull it.
- In prose, state that D can also type **"skip"**, **"defer"**, or **"show me the brief"** at any time — do not spend
  option slots on these.
- **One decision per question. Never bundle unrelated decisions.**

### 7. Record atomically

On D's answer, post a decision comment using the template below, THEN set the ticket state. Verify both writes
succeeded; retry up to 3×. If a write cannot be confirmed, **halt and report** — never advance the queue on an
unverified write. A lost decision is worse than a stall.

### 8. Cascade lightly

Comment on **direct** dependents to note the unblock (e.g. "blocker ENG-42 resolved: `<decision>`"). Do NOT
auto-transition downstream tickets — the agents own those. Auto-transitioning shared state is an irreversibility
trap and is out of scope.

### 9. Per-view special handling

- **Upcoming Deadlines** (risk pass): surface at-risk items (near/overdue dueDate, especially if also Blocked) and
  only ask D when an actual decision is needed (reprioritize, extend, drop). Don't force a question per ticket.
- **Ungroomed Backlog** (grooming pass): these need a `## Acceptance` section — that is **agent grooming, not a D
  decision**. Flag them and offer to route the batch to Clara; do not ask D to write acceptance criteria.

### 10. Deferred / skipped / mislabeled + recap

Deferred tickets go to the end and are re-offered once, then left for next session. "This ticket is mislabeled" is a
first-class answer: fix state, comment why, record no decision. End with a recap: decisions made (hyperlinked),
comments posted, states changed, deferred/skipped list.

## Decision comment template

Post every decision in this exact shape so the agents can parse D's rulings reliably:

```text
[triage-decision]
Decision: <what D chose>
Rationale: <one line — D's reasoning if given>
Decided-by: D via /process-bareclaude triage
Date: <YYYY-MM-DD>
```

## Guardrails (non-negotiable)

1. **Race with agents** → just-in-time re-fetch (step 5); skip-and-note on state drift.
2. **Deciding on unread source** → detect external links; flag + downgrade rec to tentative; offer to read first.
3. **Silent write failure** → verify-after-write, ≤3 retries, halt-and-report before advancing.
4. **Re-run duplication** → `[triage-decision]` marker checked in step 5; never double-decide a ticket.
5. **Mislabeled state** → treat "this isn't really blocked/ready" as a valid answer; fix state, no fake decision.

All writes stay on the decided ticket, and dependents get comments only. Nothing auto-transitions downstream.

## Hyperlink rule

Every ticket reference shown to D is a clickable markdown link built from the MCP-returned `url`, e.g.
`[OPS-274](https://linear.app/bareclaude/issue/OPS-274/...)`. Never show a bare ID alone. `AskUserQuestion` chips may
not render links, so the links live in the prose around each question.

## Prerequisites

- Linear MCP connected. The connection lives in `~/.claude.json` (OAuth, runtime) — it is not versioned, so it does
  not travel with `/sync`.
- Read-only Linear calls run prompt-free under the workspace's `bypassPermissions` mode; no allowlist needed.

## Notes

- Speed comes from parallel prefetch + tight question prose, NOT from bundling.
- Views mirror Clara's saved workspace views (`Needs Unblocking`, `Needs Your Sign-off`, `Upcoming Deadlines`,
  `Ungroomed Backlog`); keep names in sync if she renames them.
- Recommended follow-up: adopt a `needs-d` label as the escalation contract so "Needs Your Sign-off" is a clean
  filter instead of comment archaeology.
- Workspace convention: in `bareclaude`, `In Review` ≈ D's decision queue, not "ready to ship."
