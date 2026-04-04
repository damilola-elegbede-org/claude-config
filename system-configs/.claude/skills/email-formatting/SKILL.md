---
name: email-formatting
description: Format outbound emails for D, Ana, and other stakeholders with clear subject lines, BLUF-first structure, clickable links, explicit recipient/CC checks, and polished HTML when useful. Use when drafting or sending email via gog/Gmail, especially for travel options, recommendations, status updates, summaries, follow-ups, or any message that should feel executive-ready instead of raw plain text.
---

# Email Formatting

Format outbound email so it is easy to scan, hard to mis-send, and ready for action.

## Workflow

1. **Verify recipients before writing**
   - Confirm `to`, `cc`, and `bcc` from the current request.
   - Do not add `cc` recipients by default.
   - Only CC someone when D explicitly instructs it, or when replying within an already-established thread where keeping the same recipients is clearly intended.

2. **Choose the body format intentionally**
   - **Do not send plain-text emails.**
   - Send in **HTML** by default.
   - Markdown is acceptable only if it will render correctly end-to-end in the actual sending path; if there is any doubt, use HTML.
   - Use HTML whenever the message benefits from clickable links, section headers, bullets, or emphasis.

3. **Lead with BLUF**
   - First paragraph should answer: what matters, what changed, and what you recommend.
   - Keep it to 1-3 short sentences.

4. **Structure for fast scanning**
   - Prefer this order:
     1. BLUF
     2. Key links
     3. Options / findings
     4. Recommendation
     5. Risks / caveats
     6. Next step

5. **Make links clickable**
   - If referencing flights, docs, bookings, forms, or source material, include clickable hyperlinks.
   - Prefer descriptive anchor text over raw URLs.
   - If exact deep links are unstable, provide search links and label them clearly.

6. **End with a concrete recommendation**
   - State the action you recommend now.
   - If there are ranked options, number them.

## Required Quality Bar

Every outbound email should pass this checklist:

- Clear subject line
- Correct `to` and `cc`
- HTML by default; no plain-text send
- BLUF in opening
- Clickable links when links matter
- Bullets or numbered options when comparing choices
- Explicit recommendation
- No wall-of-text paragraphs
- No exposed internal process, tooling, or agent mechanics

## Subject Line Patterns

Use short, decision-friendly subjects.

- **Travel options:** `Portugal trip outbound flight options (DEN → Lisbon, Jun 2/3)`
- **Recommendation:** `Recommendation: [topic]`
- **Update:** `[Topic] — update`
- **Follow-up:** `[Topic] — follow-up`
- **Decision required:** `Decision needed: [topic]`

When resending a corrected version, append a meaningful suffix such as:

- `— with links`
- `— updated options`
- `— revised recommendation`

## HTML Formatting Rules

When sending HTML email:

- Use short paragraphs inside `<p>` tags.
- Use `<ul>` / `<ol>` for options and action items.
- Use `<strong>` sparingly for labels, prices, dates, and recommendations.
- Use `<a href="...">descriptive text</a>` for links.
- Keep nesting shallow.
- Do not over-style; simple semantic HTML is enough.

For a reusable skeleton, see `references/patterns.md` and `assets/html-shell.html`.

## Common Patterns

### Option-comparison email

Use when comparing flights, vendors, products, or plans.

- BLUF
- Quick links
- Date-by-date or option-by-option breakdown
- Best overall
- Best premium / convenience option (if relevant)
- Avoid / warning notes
- Recommendation

### Executive update email

Use when reporting status or summarizing work.

- BLUF
- What changed
- Risks / blockers
- Decision needed
- Next step

### Coordination email

Use when multiple recipients need shared context.

- State why everyone is included
- Call out owner and next action clearly
- Avoid ambiguity about who should respond

## Travel-Specific Guardrails

For itinerary research or booking emails:

- Include at least one clickable source/search link near the top.
- Show total price and passenger count.
- Separate approximate pricing from confirmed booking details.
- Warn on self-transfers, airport changes, very tight layovers, or 2-stop routings.
- Do not add CC recipients unless D explicitly asks.

## Final Send Check

Before sending, pause and verify:

1. Did I include everyone who should see this?
2. If the reader clicks nothing else, is the recommendation still obvious?
3. If the reader clicks links, do they land somewhere useful?
4. Is the email polished enough to forward as-is?

If any answer is no, revise before sending.
