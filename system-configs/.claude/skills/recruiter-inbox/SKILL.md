---
name: recruiter-inbox
description: Score and log recruiter outreach emails. Detect recruiter messages, score fit against D's job search criteria, log to recruiter-log.md, and route alerts based on score.
---

# Recruiter Inbox

## When to Use

- Called by the email-triage skill when a recruiter email is detected
- When D asks to evaluate a recruiter message
- During morning brief compilation (to surface scored recruiter activity)

## Job Search Context

Load current parameters from `MEMORY.md` — key fields:
- **Target roles:** EM, Senior EM, Director of Engineering
- **NO IC roles** (no VP, no Head of Eng, no CTO/CIO)
- **Base salary floor:** $230K | **Total comp floor:** $350K
- **Primary locations:** Colorado (Boulder preferred), remote
- **Will relocate for:** Anthropic (anywhere), Seattle, San Diego
- **Companies to avoid:** Verily (former employer)
- **Active interviews:** Check `MEMORY.md` → Active Interviews section

## Scoring System (1–10)

### Role Fit (0–3 points, weighted heavily)

| Signal | Points |
|--------|--------|
| EM / Senior EM / Director of Engineering | +3 |
| VP Engineering / Head of Engineering | +2 |
| Staff/Principal Engineer (IC) | +1 |
| IC-only, junior, non-engineering, CTO/CIO | 0 |

### Company Quality (0–3 points)

| Signal | Points |
|--------|--------|
| Series B+ startup or established tech company | +1 |
| AI/ML company or AI-forward org | +1 |
| Remote-friendly or Colorado/Boulder/Denver | +1 |
| Seattle or San Diego (relocation-worthy) | +1 |
| Anthropic (any location) | +3 (auto) |
| Early-stage (<20 people) or non-tech | 0 |

### Outreach Quality (0–2 points)

| Signal | Points |
|--------|--------|
| Named role + comp range | +1 |
| Personalized (references D's background specifically) | +1 |
| Generic template blast | 0 |
| Agency recruiter with no company named | -1 |

### Disqualifiers (override score to 1–2)

- Base salary below $200K (if stated)
- Role is clearly IC-only with no management path
- Company is on the avoid list (Verily)
- Same recruiter/role already scored in `memory/recruiter-log.md`

## Score-Based Actions

| Score | Action |
|-------|--------|
| **8–10** | 🔥 Notify D via Telegram immediately + log. Format: "📨 RECRUITER — Score [N]/10 — [Company]: [Role]. [One-line why it's hot]" |
| **5–7** | 👀 Include in next brief + log |
| **3–4** | 📋 Log only to `memory/recruiter-log.md` |
| **1–2** | 🗑️ Log with note, skip notification |

## Logging

Append every scored recruiter email to `memory/recruiter-log.md` in this format:

```markdown
## YYYY-MM-DD

| Date | Sender | Subject | Score | Thread ID | Notes |
|------|--------|---------|-------|-----------|-------|
| YYYY-MM-DD (time) | Name <email> (Company) | "Subject" | N/10 | thread_id | Scoring rationale. Key details. |
```

### Deduplication

Before scoring, check `memory/recruiter-log.md` for:
- Same sender + same role → skip (already scored)
- Same sender, different role → score as new
- Same company, different recruiter → score as new

## Telegram Format (Score 5+)

```
📨 Recruiter: [Sender Name] ([Company]) — Score: [N]/10
Role: [Title]
Location: [Location or Remote]
Comp: [If mentioned, otherwise "Not stated"]
Key detail: [One line — why interesting or red flag]
Thread: [Gmail thread ID for quick lookup]
```

## Rules

- **NEVER** draft or send responses to recruiters
- **NEVER** reply on D's behalf
- **NEVER** mark recruiter emails as read
- **ALWAYS** include Gmail thread ID for D to find the email
- **ALWAYS** check dedup before logging
- If a recruiter is connected to an active interview (check MEMORY.md), auto-elevate to URGENT regardless of score
