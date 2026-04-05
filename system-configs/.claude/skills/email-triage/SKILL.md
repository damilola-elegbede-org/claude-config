---
name: email-triage
description: Monitor and triage D's email accounts. Flag urgent, summarize important, archive noise. Designed to be read by the Email Check cron (7am/1pm/5pm).
user-invocable: false
---

# Email Triage

## When to Use

- Called by the Email Check cron at 7am / 1pm / 5pm MT
- When D explicitly requests an email check
- After D sends an email, to check for immediate replies

## Accounts

- **Primary:** `damilola.elegbede@gmail.com` — D's personal/professional inbox
- **Tool:** `gog gmail search "in:inbox newer_than:8h" --max=15 --account damilola.elegbede@gmail.com --plain`
- **GOG_KEYRING_PASSWORD** is in env

## Step 1 — Fetch & Triage

Fetch new messages since last check. For each message, classify:

### URGENT (Notify D via Telegram immediately)

Criteria — ANY of:

- From an active recruiter/interviewer in `memory/recruiter-log.md` (Visa, Anthropic, Airbnb contacts)
- Interview scheduling, offer, or rejection
- Calendar conflict or meeting change within 24 hours
- Financial alert (fraud, payment failure, large unexpected charge)
- From Ana (<analeju@gmail.com>) marked urgent or time-sensitive
- Contains "urgent", "asap", "time-sensitive", "action required" in subject

Action: Notify D via Telegram (Clara bot) immediately.

Format:

```text
🚨 URGENT EMAIL
From: [Sender]
Subject: [Subject]
Summary: [One line]
Action needed: [What D should do]
```

### IMPORTANT (Queue for brief)

Criteria — ANY of:

- From a known professional contact
- Job opportunity from a reputable company (score 5+ per recruiter-inbox skill)
- Actionable request requiring a response within 1-3 days
- Meeting invite requiring RSVP
- Legal, tax, or financial document
- Travel confirmation or change for upcoming trips

Action: Include in next scheduled brief.

### NOISE (Skip)

Criteria:

- Newsletters, promotional emails, marketing
- Automated notifications (GitHub CI, social media, app updates)
- Subscription receipts (unless unexpected amount)
- Cold outreach spam

Action: Log count, skip.

## Step 2 — Recruiter Detection

For EVERY email in the fetch, check if it's recruiter outreach. If yes, hand off to the
**recruiter-inbox** skill at `~/.openclaw-clara/workspace/skills/recruiter-inbox/SKILL.md`
for scoring and logging.

Quick detection triggers — ANY of:

- Subject contains: opportunity, role, position, hiring, recruiting, interested in you
- Sender domain: greenhouse.io, lever.co, ashbyhq.com, smartrecruiters.com, linkedin.com
- Sender title patterns: "Recruiter", "Talent Acquisition", "People", "TA"
- Body patterns: "I came across your profile", "exciting opportunity", "would you be open to"
- Job board notifications: LinkedIn, Indeed, Wellfound, Greenhouse, Lever

## Step 3 — Telegram Summary

After triage, post summary to D via Telegram (Clara bot) with the time-of-day label:

| Cron time | Label |
|-----------|-------|
| 7am | 📧 Morning Email Check |
| 1pm | 📧 Midday Email Check |
| 5pm | 📧 Afternoon Email Check |

Format:

```text
📧 [Label] — [Day], [Date]

[If urgent items exist, list them first with 🚨]

📌 Action Needed ([N] items):
- [Sender] — [Subject]. [One-line summary + what to do]

ℹ️ FYI:
- [Sender] — [Subject]. [One-line summary]

Noise skipped: [N] emails
```

If inbox is empty or all noise: send a one-liner like "📧 Midday Email Check — Inbox clear, nothing actionable."

## Step 4 — State & Logging

1. Update `memory/email-check.md` with timestamp of this check:
   - **NEVER use the `edit` tool on email-check.md** — fails on exact-match issues
   - **ALWAYS: read full file → update in memory → write complete file back in one shot**
2. Append a timestamped block to `memory/YYYY-MM-DD.md`:
   - NEVER use the `edit` tool on the daily note file
   - Read entire file → append new block → write entire file
   - If file doesn't exist, create it

## Rules

- **NEVER** send email as D without explicit instruction
- **NEVER** mark recruiter emails as read
- **NEVER** reply to any email without D's instruction
- **ALWAYS** Notify D via Telegram immediately for urgent items
- If uncertain whether urgent, err on the side of flagging
- When sending any email to D: FROM `clara.nova.cos@gmail.com` TO `damilola.elegbede@gmail.com` using `--account clara.nova.cos@gmail.com`
- Use HTML formatting for emails per the email-formatting skill
