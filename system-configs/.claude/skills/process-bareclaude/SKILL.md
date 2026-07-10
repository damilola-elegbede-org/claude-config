---
name: process-bareclaude
description: Walk D through the BareClaude Linear triage one decision at a time, driven by Clara's saved workspace views — Needs Unblocking and Needs Your Sign-off. Classifies the queue FIRST (typically only ~1 in 5 tickets truly needs D), walks only the genuine decisions with full context, recommended options, and clickable ticket links, and bulk-handles the rest. Use when D wants to clear the Linear decision/approval queue.
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
the queues that gate the fleet, then does the thing that matters most: **classifies the queue before walking it.**
In practice most tickets in the Blocked / In Review states are NOT decisions for D — they are agent-executable work
mis-parked, tickets blocked on other tickets, shelved projects, or completed deliverables awaiting a rubber-stamp.
The skill walks only the genuine D-decisions one at a time (full context, recommended options, clickable links),
and bulk-handles everything else — while emitting a **suppression report** so the filtering itself stays auditable.

The fleet's agents (Clara/ops, Dara/eng, TARS) create and work these tickets and delegate decisions back to D. This
skill is the mechanism for clearing that decision backlog fast — without losing decision quality, and without letting
the fleet's own labels decide what deserves D's attention.

## Expected Output

```text
User: /process-bareclaude
Claude: Loading BareClaude triage views…
  🚫 Needs Unblocking (Blocked, OPS+ENG) ...... 24 tickets
  ⏳ Needs Your Sign-off (In Review) .......... 25 tickets

Classified (only the genuine decisions get walked):
  A · needs D            9   → walk one at a time
  B · bounce to agent   14   → back to Dara/Clara (Todo)
  C · blocked upstream   5   → left; not D's
  D · bulk-ack / shelved 21  → accept-close or cancel in bulk

[dry-run question] Walk the 9 A-tickets? (B/C/D handled as above — see suppression report)

User: proceed
Claude: [ENG-1190](https://linear.app/bareclaude/issue/ENG-1190/...) — keystone: blocks 3 secret-cleanup tickets — <2-line context>.
        (options via AskUserQuestion; one tagged "(Recommended)")
User: <picks an option>
Claude: ✓ Recorded [triage-decision] on [ENG-1190](...), set state → Todo
        ✓ Keystone resolved 3 downstream tickets — dropped from the walk
        Next → [OPS-299](https://linear.app/bareclaude/issue/OPS-299/...) …

Recap:
  Decided: 9 · Bulk-accepted: 19 · Bounced: 14 · Cancelled: 2
  Comments posted: 40 · States changed: 34

D-action checklist (produced by the decisions):
  1. Run 3 gh secret commands (ENG-517 / ENG-1022 / ENG-1132)
  2. Uninstall 16 retired GitHub Apps (org settings)  ✅ done this run

Suppression report (classified NOT-for-D — reopen anything I got wrong):
  B · bounced: ENG-1070, ENG-373, OPS-292 …
  D · bulk-accepted: OPS-224, OPS-264 …
```

## Behavior

### 1. Resolve the views (mirror Clara's saved views by filter)

The Linear MCP cannot fetch a saved view object directly, so this skill reproduces each of Clara's views by its
filter. Keep the names identical to the workspace views so they stay conceptually linked:

| Skill view | Clara's saved view | Filter (`list_issues`) | Mode |
| --- | --- | --- | --- |
| `unblock` | **Needs Unblocking** | `state: Blocked` (OPS + ENG) | Interactive decision |
| `signoff` | **Needs Your Sign-off** | `state: In Review` (OPS + ENG) | Interactive decision |
| `deadlines` | **Upcoming Deadlines** | issues with a `dueDate`, order by dueDate asc | Risk pass |
| `ungroomed` | **Ungroomed Backlog** | `state: Backlog` where description lacks `## Acceptance` | Grooming pass |

Default (`--view all` off) processes the two **decision** views only: **Needs Unblocking**, then **Needs Your
Sign-off**. Apply `--team` to scope. If the MCP later exposes saved views directly, switch to fetching the view by
name instead of re-deriving the filter.

### 2. Prefetch everything, in parallel

For every queued ticket, fetch description, comments, and relations (`blocks` / `blockedBy`) in one parallel batch.
Speed comes from prefetch — not from bundling decisions.

### 3. Classify BEFORE you walk (the highest-leverage step)

Do NOT assume every Blocked / In-Review ticket is a decision for D — typically only ~1 in 5 is. Using the prefetched
context, sort every ticket into exactly one bucket:

| Bucket | Meaning | Disposition |
| --- | --- | --- |
| **A — needs D** | A real decision only D can make (policy, irreversible, security, spend, ambiguous product call) | Walk one at a time (steps 6-11) |
| **B — bounce to agent** | Agent-executable work (bug fix, investigation, implementation) mis-parked as if it were a D-decision | Comment "not a D-decision, execute or re-block with a specific non-D blocker" → set Todo |
| **C — blocked upstream** | Correctly blocked on ANOTHER ticket / external gate, not on D | Leave as-is; note in the suppression report |
| **D — bulk-ack / shelved** | Completed deliverable awaiting acknowledgment, OR a cancelled/superseded/dead project | Bulk accept-and-close, or cancel, per D's one bulk instruction |

Two classification cautions, because this skill filters D's attention using labels the fleet itself wrote:

- **Don't trust the state.** Mislabeling is common, not rare: In-Review tickets with no PR, "ready" comments that are
  days stale, Blocked tickets whose blocker already resolved. Verify (step 8) before trusting a status.
- **Flag cron-generated busywork.** Many tickets are auto-created by a Plan cron to fill "project has zero active
  issues" gaps, then worked into a deliverable and parked for D. Name these in the suppression report — a mattering
  ticket must never be rubber-stamped just because the fleet manufactured it.

### 4. Order by leverage + group keystones

Process **Needs Unblocking** fully before **Needs Your Sign-off**. Within bucket A, sort by: outgoing `blocks` count
(most dependents first) → priority → age. For **Upcoming Deadlines**, sort by soonest dueDate. No transitive
(depth > 1) analysis. **Identify keystones:** where one decision would resolve several queued tickets (shared root
cause, or a policy that answers N tickets at once), group them so you ask ONCE, not per dependent (see step 7, 11).

### 5. Dry-run summary first (one question) + suppression preview

Present the classification counts (A/B/C/D) and the ordered, hyperlinked list of the **A** tickets with a one-line
"why it's here" + dependent count each. State how B/C/D will be handled. Ask D once: **proceed / reorder / drop /
reclassify**. This is the sanctioned batching point for scoping. D may pull a ticket up from B/C/D into A, or push
one down.

### 6. Just-in-time re-fetch before each ask

Immediately before asking about a ticket, re-fetch its current state. If it changed since prefetch, or a prior
`[triage-decision]` marker comment already exists, or a keystone already resolved it, **skip it with a note**
(idempotency + race safety).

### 7. Ask one question per DECISION (not per ticket)

- One question per **decision**. A decision may span N homogeneous tickets (a keystone that unblocks several; a
  bulk-accept of completed briefs) — ask once and record on each affected ticket. Keep it per-ticket only when the
  stakes genuinely diverge. **Never bundle unrelated decisions into one question.**
- Put the **full linear.app URL** in prose — use the `url` the MCP returns; never string-build it.
- 2-4 concrete options; tag exactly one **"(Recommended)"** with a one-line rationale. Use option `preview` text to
  mock the concrete outcome of each choice — it reads far better than labels alone.
- If any option's real substance lives outside Linear (a diff, a vault doc, org state), verify it (step 8) or mark
  the recommendation **tentative** and offer to pull it — never a confident rec built on a source you did not read.
- In prose, state that D can also type **"skip"**, **"defer"**, or **"show me the source"** at any time — do not
  spend option slots on these.

### 8. Verify against the source system (mandatory at high-stakes gates)

This skill is NOT Linear-only. Linear comments are the fleet's self-report; for anything that matters, check the
source of truth before deciding or recommending. **Mandatory** verification before you record a decision when the
ticket involves any of:

- **Money / payments** — read the actual PR diff; confirm what a change truly touches (e.g. a "disable checkout"
  change may also disable donations if they share an endpoint). Green CI and an agent's own "SAFE TO SHIP" self-review
  are NOT sufficient for payment/customer-facing code.
- **Secrets / identity / access** — query the live system (`gh api`, provider dashboards) rather than trusting a
  ticket's list (e.g. confirm which app is a live identity before a bulk uninstall).
- **Irreversible actions** — deletes, sends, deploys, org-level changes: confirm current real-world state first.
- **Agent self-reported "ready/mergeable/green"** — re-check with `gh pr view` (mergeability + checks); "ready"
  comments go stale within days.

For everything else, source verification is optional but encouraged. When a check contradicts the ticket, treat that
as the finding.

### 9. Escalate to the fable-advisor at the sharp gates

Consult the `fable-advisor` (Fable tier) **before finalizing** the recommendation when a decision is
**financial, secrets/access-scoped, bulk-destructive, or architecturally constraining** — the gates where a plausible
wrong call is expensive. Pass it the verified facts (step 8), not the ticket text alone. Its guidance sharpens the
options you present; D still decides. Elsewhere the consult is optional — don't manufacture it for routine calls.

### 10. Record atomically (re-check, then idempotent write)

On D's answer, **FIRST re-fetch** the ticket's state and scan for an existing `[triage-decision]` marker — D may
have taken minutes to answer, and an agent may have moved the ticket meanwhile. If the state drifted or a marker
already exists, abort and re-surface the ticket rather than writing stale.

Then post the decision comment using the template below, THEN set the ticket state. Make both writes **idempotent**:
before retrying either, re-scan for the exact marker/state and treat an existing match as success — retry only the
missing operation. Verify both writes; retry up to 3×. On unrecoverable partial failure, report exactly what landed
and **halt** — never advance the queue on an unverified write. A lost or duplicated decision is worse than a stall.

### 11. Cascade lightly + collapse keystones

Comment on **direct** dependents to note the unblock (e.g. "blocker ENG-42 resolved: `<decision>`"). When the ticket
was a **keystone**, also drop its now-resolved dependents out of the remaining walk (re-derive the A-queue) so you
never ask a question a prior answer already settled. Do NOT auto-transition downstream tickets — the agents own those;
auto-transitioning shared state is an irreversibility trap and is out of scope. These dependent comments are
**best-effort**: verify and retry once, but on failure log the miss in the recap rather than halting — a failed
courtesy-comment must never block D's decisions.

### 12. Per-view special handling

- **Upcoming Deadlines** (risk pass): surface at-risk items (near/overdue dueDate, especially if also Blocked) and
  only ask D when an actual decision is needed (reprioritize, extend, drop). Don't force a question per ticket.
- **Ungroomed Backlog** (grooming pass): these need a `## Acceptance` section — that is **agent grooming, not a D
  decision**. Flag them and offer to route the batch to Clara; do not ask D to write acceptance criteria.

### 13. Capture standing policies

When a decision is a **standing rule** rather than a one-off (e.g. "job-application tickets close on Clara's email
delivery, not on D's submission"), don't bury it in a single ticket comment. Write it to persistent memory AND flag
the owning agent's skill so the rule propagates, then apply it to every matching ticket in the current queue.

### 14. Deferred / skipped / mislabeled, recap, D-action checklist, suppression report

Every decision path has an explicit outcome — target state and whether a comment is written:

| Path | Target state | Comment |
| --- | --- | --- |
| Normal decision | per D's choice | `[triage-decision]` |
| Skip | unchanged | none |
| Defer | unchanged (re-queued once, then left for next session) | brief "deferred by D" note |
| "Show me the source" | unchanged (re-asked after D reads) | none |
| Mislabeled | corrected state | note explaining the correction; no `[triage-decision]` |
| Bounce (bucket B) | Todo | "not a D-decision; execute or re-block" note |
| Bulk-ack (bucket D) | Done / Canceled | `[triage-decision]` (acceptance or cancellation) |

End with a recap that carries three things:

1. **Counts** — decided / bulk-accepted / bounced / cancelled; comments posted; states changed; deferred/skipped.
2. **D-action checklist** — a first-class list of the concrete actions the decisions handed to D (shell commands,
   portal submits, GitHub-UI clicks), each hyperlinked, with anything already done marked ✅.
3. **Suppression report** — what was classified B/C/D and therefore NOT asked, so D can catch a misclassification.

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

1. **Rubber-stamp risk** → the fleet creates the load this skill filters; classify independently (step 3), never
   trust a state blindly, and always emit the suppression report (step 14) so the filtering is auditable.
2. **Race with agents** → just-in-time re-fetch (step 6); skip-and-note on state drift.
3. **Deciding on unread/self-reported source** → verify against the source system (step 8) at money/secrets/
   irreversible/PR gates; flag + downgrade rec to tentative otherwise; offer to read first.
4. **Silent write failure** → verify-after-write, ≤3 retries, halt-and-report before advancing.
5. **Re-run duplication** → `[triage-decision]` marker checked in step 6; keystone collapse (step 11); never
   double-decide a ticket.
6. **Mislabeled state** → treat "this isn't really blocked/ready" as a valid answer; fix state, no fake decision.

All writes stay on the decided ticket, and dependents get comments only. Nothing auto-transitions downstream.

## Hyperlink rule

Every ticket reference shown to D is a clickable markdown link built from the MCP-returned `url`, e.g.
`[OPS-274](https://linear.app/bareclaude/issue/OPS-274/...)`. Never show a bare ID alone. `AskUserQuestion` chips may
not render links, so the links live in the prose around each question.

## Prerequisites

- Linear MCP connected. The connection lives in `~/.claude.json` (OAuth, runtime) — it is not versioned, so it does
  not travel with `/sync`.
- `gh` CLI authenticated with org access — required for the source-system verification in step 8 (PR state, org app
  installations, diffs).
- Read-only Linear and `gh` calls run prompt-free under the workspace's `bypassPermissions` mode; no allowlist needed.

## Notes

- Speed comes from parallel prefetch + tight question prose, NOT from bundling.
- The classification pass (step 3) is the whole game: it turns a 50-ticket wall into the ~10 that actually need D.
- Views mirror Clara's saved workspace views (`Needs Unblocking`, `Needs Your Sign-off`, `Upcoming Deadlines`,
  `Ungroomed Backlog`); keep names in sync if she renames them.
- Workspace convention: in `bareclaude`, `In Review` ≈ D's decision queue, not "ready to ship." But it is heavily
  overloaded (real decisions + completed briefs + code PRs) — the classification pass is what separates them.
