---
name: clara-briefing
description: Clara Nova's daily briefing compiler. Modeled after the President's Daily Brief — concise, actionable intelligence for D.
---

# Clara Briefing — President's Daily Brief Format

## When to Use

- **Morning Brief (7am)** — full daily intelligence → Email + Slack #briefs summary
- **Midday Check (12pm)** — urgent items + afternoon prep → Slack #briefs only
- **EOD Wrap (8pm)** — day summary + tomorrow setup → Slack #briefs only

---

## Golden Reference

**Wednesday March 18, 2026** is the canonical golden EDB. Every morning brief must match that email's visual design exactly: Gmail message ID `19d010d1515b718d`. When in doubt, reproduce that structure.

---

## Data Sources

All data gathered via existing tools. Skip any source that errors — never fabricate.

| Source              | Tool                                                                                            | What to Pull                                                                                                                                                                        |
| ------------------- | ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Email               | `gog gmail search "in:inbox is:unread" --account damilola.elegbede@gmail.com --plain --max 10` | Unread/important since last brief                                                                                                                                                   |
| Calendar            | `gog calendar events --all --today --json --account damilola.elegbede@gmail.com`                | **ALWAYS `--json`. Parse JSON. Never dump raw text.** Extract `summary`, `start.dateTime`, `end.dateTime`. Format times 12-hr MT.                                                  |
| Google Tasks        | `gog tasks list MDY2NjI3NzQ3NDQzMDI5MTAxODU6MDow --account damilola.elegbede@gmail.com --json` | Due/overdue native tasks. **FILTER OUT any task where notes/description contains "Notion Task: "** — those are Notion mirrors tracked by Cadence.                                   |
| Notion / GTD        | `~/.openclaw-clara/workspace-cadence/state/gtd_pulse_edb.json`                                 | Cadence's pre-computed overdue/blocked/horizon tasks. Fall back to `gtd_pulse_section.txt`. **Never query Notion directly — Cadence owns it.**                                     |
| Trident — jobs      | `memory/job-search-latest.md`                                                                   | Latest matches from 5-target pipeline (Anthropic, Netflix, Nvidia, Airbnb, Vercel)                                                                                                  |
| Trident — recruiter | `memory/recruiter-log.md`                                                                       | Scored recruiter outreach (last 7 days only)                                                                                                                                        |
| Trident — Oriki     | `plans/operation-trident.md` + recent memory files                                              | Oriki Labs status: entity, venture selection, product dev, consulting pipeline                                                                                                       |
| Overnight results   | Nexus Slack `#status`, `#alerts`, `#coordination` since last brief                              | Agent activity, cron results, system changes                                                                                                                                        |
| Weather             | Open-Meteo API (Boulder, °F)                                                                     | High/low temps, humidity %, precipitation % for header line                                                                                                                         |

---

## Morning Brief — Step-by-Step Assembly Procedure

**Follow every step in order. Do not skip, reorder, or improvise the HTML structure.**

### Step 1 — Collect All Data First

Run ALL of the following before writing any HTML:

```bash
# Weather (Open-Meteo: high, low, humidity, precip %)
curl -s "https://api.open-meteo.com/v1/forecast?latitude=40.015&longitude=-105.2705&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max&current=relative_humidity_2m,weather_code&temperature_unit=fahrenheit&timezone=America/Denver&forecast_days=1"
# Parse JSON: daily.temperature_2m_max[0], daily.temperature_2m_min[0], current.relative_humidity_2m, daily.precipitation_probability_max[0]
# Map weather_code to emoji: 0-1=☀️, 2=⛅, 3=☁️, 45-48=🌫️, 51-67=🌧️, 71-77=🌨️, 80-82=🌦️, 85-86=🌨️, 95-99=⛈️

# Calendar — ALWAYS --json
gog calendar events --all --today --json --account damilola.elegbede@gmail.com

# Google Tasks
gog tasks list MDY2NjI3NzQ3NDQzMDI5MTAxODU6MDow --account damilola.elegbede@gmail.com --json

# Email
gog gmail search "in:inbox is:unread" --account damilola.elegbede@gmail.com --plain --max 10
```

Also read:
- `~/.openclaw-clara/workspace-cadence/state/gtd_pulse_edb.json` — Cadence's Notion GTD data. **Never query Notion directly.**
- `memory/job-search-latest.md`
- `memory/recruiter-log.md`
- Nexus Slack `#status`, `#alerts`, `#coordination` for overnight Cortex updates

### Step 2 — Write the HTML to `/tmp/edb-morning.html`

Use the **exact HTML structure below**. Colors, fonts, and layout are fixed. Only the content inside each section changes. This structure exactly matches the Wednesday March 18 golden reference.

```html
<div style="font-family:'Helvetica Neue',Helvetica,Arial,sans-serif;max-width:680px;margin:0 auto;color:#2d2d2d;line-height:1.6">
  <h1 style="font-size:22px;font-weight:700;margin:0 0 2px 0;letter-spacing:-0.3px;color:#002b5c">
    ☀️ Executive Daily Brief
  </h1>
  <p style="color:#6b7280;font-size:13px;margin:4px 0 16px 0">
    [Day], [Month] [DD] · [weather emoji] [Hi]°/[Lo]°F · 💧 [Humidity]% · 🌧 [Precip]%
  </p>

  <hr style="border:none;border-top:1px solid #d6d2c4;margin:16px 0">

  <!-- ⚡ TOP LINE -->
  <h2 style="color:#c0392b;font-size:16px;font-weight:700;margin:0 0 8px 0">⚡ TOP LINE</h2>
  <p style="font-size:15px">
    [One paragraph. Most critical item requiring D's attention. Direct, no hedging.
    Hyperlink relevant items: <a href="[URL]" style="color:#006d75;text-decoration:none">anchor text</a>]
  </p>

  <hr style="border:none;border-top:1px solid #d6d2c4;margin:16px 0">

  <!-- 📅 SCHEDULE -->
  <h2 style="color:#002b5c;font-size:16px;font-weight:700;margin:0 0 8px 0">📅 SCHEDULE</h2>
  <table style="width:100%;border-collapse:collapse;font-size:14px">
    <!-- For each event from --json output, one <tr>. Alternate background:#f7f6f3 on even rows. -->
    <!-- Skip all-day holiday entries from secondary calendars unless relevant. -->
    <!-- Link event name to Google Calendar event URL when available. -->
    <tr style="border-bottom:1px solid #d6d2c4">
      <td style="padding:8px 0;width:120px;color:#6b7280;vertical-align:top">[H:MM AM/PM]</td>
      <td style="padding:8px 0"><a href="[calendar event URL]" style="color:#006d75;text-decoration:none"><strong>[Event Summary]</strong></a> — [one-line prep note if important meeting]</td>
    </tr>
    <tr style="border-bottom:1px solid #d6d2c4;background:#f7f6f3">
      <td style="padding:8px 0;width:120px;color:#6b7280;vertical-align:top">[H:MM AM/PM]</td>
      <td style="padding:8px 0"><a href="[calendar event URL]" style="color:#006d75;text-decoration:none"><strong>[Event Summary]</strong></a></td>
    </tr>
    <!-- ...repeat for each event... -->
  </table>
  <!-- If zero timed events: replace table with: -->
  <!-- <p style="color:#6b7280;font-size:14px;margin:0">No meetings today — deep work day.</p> -->

  <hr style="border:none;border-top:1px solid #d6d2c4;margin:16px 0">

  <!-- ✅ TASKS DUE -->
  <h2 style="color:#002b5c;font-size:16px;font-weight:700;margin:0 0 8px 0">✅ TASKS DUE</h2>
  <table style="width:100%;border-collapse:collapse;font-size:14px">
    <!-- Parse --json tasks. Skip any task where notes contains "Notion Task: ". -->
    <!-- Show due-today (green) and overdue (red) tasks only. Link task name to Google Tasks URL. -->
    <tr style="border-bottom:1px solid #d6d2c4">
      <td style="padding:8px 0"><strong><a href="[tasks URL]" style="color:#2d2d2d;text-decoration:none">[Task name]</a></strong></td>
      <td style="text-align:right;color:#1e7a3a">Due today</td>
    </tr>
    <tr style="border-bottom:1px solid #d6d2c4;background:#f7f6f3">
      <td style="padding:8px 0"><strong><a href="[tasks URL]" style="color:#2d2d2d;text-decoration:none">[Task name]</a></strong></td>
      <td style="text-align:right;color:#c0392b">[N] days overdue</td>
    </tr>
    <!-- ...repeat... -->
  </table>
  <p style="color:#6b7280;font-size:13px">Notion-synced tasks filtered (tracked by Cadence).</p>
  <!-- If no tasks: <p style="color:#6b7280;font-size:13px">No tasks due today.</p> -->

  <hr style="border:none;border-top:1px solid #d6d2c4;margin:16px 0">

  <!-- 📧 EMAIL INTELLIGENCE -->
  <h2 style="color:#002b5c;font-size:16px;font-weight:700;margin:0 0 8px 0">📧 INTELLIGENCE — EMAIL</h2>
  <ul style="padding-left:20px">
    <!-- Max 5 items. Each: sender bold, subject, why-it-matters in gray, Gmail link. -->
    <li style="margin-bottom:8px">
      <strong>[Sender]</strong> — [Subject] · <span style="color:#6b7280">[Why it matters]</span>
      <a href="https://mail.google.com/mail/u/0/#inbox/[messageId]" style="color:#006d75;text-decoration:none">View →</a>
    </li>
    <!-- ...repeat up to 5... -->
  </ul>
  <p style="color:#6b7280;font-size:13px">Noise filtered: [N] emails archived/skipped</p>

  <hr style="border:none;border-top:1px solid #d6d2c4;margin:16px 0">

  <!-- 📋 OVERDUE & BLOCKED — NOTION -->
  <h2 style="color:#002b5c;font-size:16px;font-weight:700;margin:0 0 8px 0">📋 OVERDUE &amp; BLOCKED — NOTION</h2>
  <table style="width:100%;border-collapse:collapse;font-size:14px">
    <!-- Read from ~/.openclaw-clara/workspace-cadence/state/gtd_pulse_edb.json -->
    <!-- Link task name to Notion page URL when available. -->
    <tr style="border-bottom:1px solid #d6d2c4">
      <td style="padding:8px 0"><strong style="color:#c0392b"><a href="[Notion URL]" style="color:#c0392b;text-decoration:none">[Task name]</a></strong></td>
      <td style="text-align:right;color:#6b7280">[Due date] · <span style="color:#c0392b">[N] days overdue</span></td>
    </tr>
    <tr style="border-bottom:1px solid #d6d2c4;background:#f7f6f3">
      <td style="padding:8px 0"><strong style="color:#c0392b"><a href="[Notion URL]" style="color:#c0392b;text-decoration:none">[Task name]</a></strong></td>
      <td style="text-align:right;color:#6b7280">[Due date] · <span style="color:#c0392b">[N] days overdue</span></td>
    </tr>
    <!-- ...repeat... -->
  </table>
  <!-- If none: <p style="color:#6b7280;font-size:13px">All Notion tasks current. ✓</p> -->

  <hr style="border:none;border-top:1px solid #d6d2c4;margin:16px 0">

  <!-- 🎯 RECRUITER WATCH — omit entirely if no entries in last 7 days -->
  <h2 style="color:#002b5c;font-size:16px;font-weight:700;margin:0 0 8px 0">🎯 RECRUITER WATCH</h2>
  <ul style="padding-left:20px">
    <!-- Score, role, company, why it fits, link to email thread. -->
    <li style="margin-bottom:8px">
      <strong>[Score]/10</strong> — [Role] at <strong>[Company]</strong> · <span style="color:#6b7280">[One-line fit note]</span>
      <a href="https://mail.google.com/mail/u/0/#inbox/[messageId]" style="color:#006d75;text-decoration:none">Action →</a>
    </li>
  </ul>

  <hr style="border:none;border-top:1px solid #d6d2c4;margin:16px 0">

  <!-- 🔱 OPERATION TRIDENT -->
  <h2 style="color:#002b5c;font-size:16px;font-weight:700;margin:0 0 8px 0">🔱 OPERATION TRIDENT</h2>
  <ul style="padding-left:20px">
    <!-- Two sub-sections: Job Search Pipeline + Oriki Labs status -->
    <!-- JOB SEARCH: Tier 1 (85+): score in green #1e7a3a. Tier 2 (80-84): score in amber #d4920b. -->
    <!-- Link role name to job posting URL. -->
    <!-- ORIKI LABS: Status of venture selection, entity formation, product development if active -->
    <li style="margin-bottom:8px">
      <strong>🎯 Job Pipeline:</strong> [Summary — new roles at 5 targets, active interviews, recruiter contacts]
    </li>
    <li style="margin-bottom:8px">
      <strong>🏗️ Oriki Labs:</strong> [Status — venture selection, entity formation, product dev, consulting pipeline]
    </li>
    <!-- If no updates: <p style="color:#6b7280;font-size:13px">No new Trident activity since last brief.</p> -->

  <hr style="border:none;border-top:1px solid #d6d2c4;margin:16px 0">

  <!-- 🔥 PRIORITIES TODAY -->
  <h2 style="color:#002b5c;font-size:16px;font-weight:700;margin:0 0 8px 0">🔥 PRIORITIES TODAY</h2>
  <ol style="padding-left:20px">
    <li style="margin-bottom:8px">
      <strong>[Priority 1]</strong> — [Why now, what specifically to do.]
      <a href="[link]" style="color:#006d75;text-decoration:none">Action →</a>
    </li>
    <li style="margin-bottom:8px">
      <strong>[Priority 2]</strong> — [Why now, what specifically to do.]
    </li>
    <li style="margin-bottom:8px">
      <strong>[Priority 3]</strong> — [Why now, what specifically to do.]
    </li>
  </ol>

  <hr style="border:none;border-top:1px solid #d6d2c4;margin:16px 0">

  <!-- 🌙 OVERNIGHT / CORTEX UPDATES -->
  <h2 style="color:#002b5c;font-size:16px;font-weight:700;margin:0 0 8px 0">🌙 OVERNIGHT / CORTEX UPDATES</h2>
  <ul style="padding-left:20px">
    <!-- Pull from Nexus #status, #alerts, #coordination since last brief. -->
    <!-- All agents: Dara, Nyx, Vesper, Cadence, Portia, Atlas, Frontend, Infra, etc. -->
    <li style="margin-bottom:8px">
      <strong>[Agent/System]</strong> — [What happened or was completed.]
      <a href="[nexus link if available]" style="color:#006d75;text-decoration:none;font-size:13px">Details →</a>
    </li>
    <!-- ...repeat... -->
  </ul>
  <!-- If nothing: omit section entirely -->

  <hr style="border:none;border-top:1px solid #d6d2c4;margin:16px 0">

  <!-- 💡 EXECUTIVE INSIGHT — This is D's daily executive coaching session. Make it count. -->
  <h2 style="color:#002b5c;font-size:16px;font-weight:700;margin:0 0 8px 0">💡 Executive Insight</h2>
  <!-- 
    INSTRUCTIONS (do not render these — they guide the assembler):
    
    1. SEARCH THE WEB for a fresh, compelling insight from credible executive leadership sources:
       Harvard Business Review, McKinsey, MIT Sloan Management Review, Drucker Institute,
       First Round Review, a16z, Reforge, Lenny's Newsletter, The Economist, Stanford GSB,
       Wharton@Work, or similar tier-1 publications.
    
    2. TOPIC FOCUS: Strategic thinking, org design, stakeholder management, executive presence,
       decision-making, team scaling, culture, innovation leadership, talent strategy, 
       organizational psychology, power dynamics, negotiation, change management.
    
    3. FORMAT: Exactly 2-3 paragraphs. No more. No less. Each paragraph should hit hard.
       - Para 1: The counterintuitive insight or uncomfortable truth. Hook with specificity.
       - Para 2: The mechanism — why this works, with evidence or a concrete example.
       - Para 3: The executive move — what D should do with this, connected to his actual context
         (Visa start Apr 14, org building, Trident targets, leadership transition).
    
    4. TONE: Like a $50K/year executive coach in a private 1:1. Direct, sharp, occasionally 
       provocative. Not a newsletter. Not motivation. Actionable wisdom.
    
    5. NO-REPEAT RULE (370-DAY LOCKOUT — NON-NEGOTIABLE):
       Before composing, READ `memory/edb-insights-log.md` for ALL prior topics.
       - No topic/angle may repeat within 370 days.
       - No same author cited more than 2x in any 30-day window.
       - No same publication more than 2x in any 5-day window.
       - Thematic clustering rules from MEMORY.md still apply (Identity/Transition locked).
       - Rotate across 8+ categories: Strategy, Org Design, Talent, Decision-Making,
         Executive Presence, Culture, Innovation, Power/Influence.
       If in doubt about overlap, pick a different topic.
    
    6. AFTER SENDING: Log the insight to `memory/edb-insights-log.md` with date, topic, 
       category, author, publication, and URL. This feeds the Weekly Coaching Digest (Sunday 6pm).
  -->
  <p style="font-size:15px;line-height:1.7;margin:0 0 12px 0">
    <strong>[Insight Title — Bold, Specific, Provocative]</strong>
  </p>
  <p style="font-size:15px;line-height:1.7;margin:0 0 12px 0">
    [Paragraph 1 — The counterintuitive insight or uncomfortable truth.]
  </p>
  <p style="font-size:15px;line-height:1.7;margin:0 0 12px 0">
    [Paragraph 2 — The mechanism: why this works, with evidence or example.]
  </p>
  <p style="font-size:15px;line-height:1.7;margin:0 0 12px 0">
    [Paragraph 3 — The executive move: what D should do with this, tied to his context.]
  </p>
  <p style="font-size:13px;color:#6b7280;margin:4px 0 0 0">
    <em>Source: [Publication], [Date]</em><br>
    <a href="[article URL]" style="color:#006d75;text-decoration:none">[article URL]</a>
  </p>

  <hr style="border:none;border-top:1px solid #d6d2c4;margin:16px 0">

  <p style="color:#9ca3af;font-size:13px;text-align:center">— 💫 Clara Nova · Chief of Staff</p>
</div>
```

### Step 3 — Send the Email

```bash
gog gmail send \
  --account clara.nova.cos@gmail.com \
  --client openclaw \
  --to damilola.elegbede@gmail.com \
  --subject "☀️ EDB — [Day], [Date] | [top priority one-liner]" \
  --body-html "$(cat /tmp/edb-morning.html)"
```

### Step 4 — Send the Telegram Summary

After the email is confirmed sent:

```
[weather emoji] EDB — [Day], [Date] · [Hi]°/[Lo]°F · 💧[Humidity]% · 🌧[Precip]%

⚡ [Top line — one sentence]

📅 [N] events today · Next: [first event name + time]
✅ [N] tasks due · [N] overdue
📧 [N] important emails · Top: [most urgent one-liner]
📋 [N] overdue Notion tasks
🔥 Top priority: [#1 priority]

Full brief in your inbox →
```

Keep under 100 words. Send via Telegram (Clara bot).

---

## Midday Check (12pm) — Telegram Only

```
🕛 MIDDAY — [Date]

⚡ [Top line if anything urgent, or "All clear"]

📅 AFTERNOON
[Remaining events with times — from ALL calendars]

✅ TASKS
[Any incomplete tasks from morning — native Google Tasks only, skip Notion-mirrored]

📨 SINCE MORNING
[Max 3 notable emails — one line each]

📋 ACTION ITEMS
[Open items from morning brief — status update]
```

---

## EOD Wrap (8pm) — Telegram Only

```
🌆 EOD — [Date]

✅ TODAY
[What happened — meetings, decisions, completions. 3-5 bullets.]

📅 TOMORROW
[Calendar preview with times — from ALL calendars]

📋 OPEN ITEMS
[Unresolved from today — carry forward]

🌙 OVERNIGHT QUEUE
[Suggested tasks for overnight processing]

🤖 CORTEX STATUS
[One-line status from each active agent.]
```

---

## Delivery Rules

| Brief   | Email | Telegram     | Format                           |
| ------- | ----- | ------------ | -------------------------------- |
| Morning | ✅    | ✅ (summary) | Full EDB email + compact Telegram |
| Midday  | ❌    | ✅           | Telegram only                      |
| EOD     | ❌    | ✅           | Telegram only                      |

- **Email:** Always FROM `clara.nova.cos@gmail.com` TO `damilola.elegbede@gmail.com`
- **Telegram:** Send via Clara bot to D (Clara bot)
- **Hyperlinks:** Everywhere actionable — Gmail links (`https://mail.google.com/mail/u/0/#inbox/[id]`), Google Calendar event links, job URLs, Notion page links, article URLs

---

## Hard Rules (Non-Negotiable)

1. **Never fabricate data** — if a source fails, say "unavailable" and move on
2. **Calendar MUST use `--json` flag** — parse JSON, render as HTML `<tr>` rows, never dump raw text
3. **Never query Notion directly** — read `~/.openclaw-clara/workspace-cadence/state/gtd_pulse_edb.json`; Cadence owns Notion
4. **Google Tasks: filter "Notion Task: "** — skip any task where `notes` contains that string
5. **Use the exact HTML structure from Step 2** — do not invent your own layout, colors, or fonts
6. **Write to `/tmp/edb-morning.html` first** — send with `$(cat /tmp/edb-morning.html)`, never pipe to `--body-html`
7. **Use direct UTF-8 characters** — no double-escaped sequences (use `→` not `\u2192`, use `&amp;` in HTML attributes)
8. **Recruiter Watch: conditional** — omit entirely if no entries in `memory/recruiter-log.md` from last 7 days
9. **Schedule: never skip** — if calendar is empty, output "No meetings today — deep work day."
10. **Overnight/Cortex updates are mandatory** — always check Nexus #status, #alerts, #coordination
