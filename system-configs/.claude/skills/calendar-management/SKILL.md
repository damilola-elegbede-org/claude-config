---
name: calendar-management
description: Monitor Google Calendar, create/modify events, detect conflicts, and
  generate meeting prep notes. Always check with D before accepting/declining.
user-invocable: false
---

# Calendar Management

## When to Use

- During morning brief (7am) to preview today's schedule
- During midday check (12pm) to flag afternoon conflicts
- During EOD wrap (6pm) to preview tomorrow
- When D requests calendar changes (create, move, cancel)
- When detecting scheduling conflicts
- When generating prep notes for important meetings

## Workflow Steps

1. **FETCH:** Read Google Calendar events
   - Primary calendar: D's main calendar
   - Time window: Today + next 7 days (for preview)
   - Include: confirmed events, tentative, invites pending response
2. **DETECT CONFLICTS:** Flag scheduling issues
   - Double-bookings (overlapping events)
   - Back-to-back meetings without break (less than 15min buffer)
   - Events during D's focus time blocks (if configured)
   - Missing prep time before important meetings
3. **GENERATE PREP NOTES:** For important meetings (flagged or >1 hour)
   - Extract: attendees, agenda, related docs
   - Context: previous meetings with same attendees, related projects
   - Talking points: outstanding items, decisions needed
4. **CREATE/MODIFY:** When instructed by D
   - Create event: verify no conflicts, add to calendar, confirm
   - Move event: check new slot for conflicts, update, notify attendees if needed
   - Cancel event: remove from calendar, notify attendees
5. **ACCEPT/DECLINE:** Never without explicit D approval
   - **ALWAYS CHECK WITH D FIRST** before accepting or declining any invite
   - Standing instructions in calendar-rules.json are reference hints only — they do NOT grant autonomous RSVP authority
   - After D explicitly confirms, execute acceptance/decline and notify sender
6. **FLAG URGENT:** If conflicts detected or time-sensitive invite
   - Notify D via Telegram immediately with conflict summary and suggested resolution

## Output Format

### For Morning Brief:

```text
📅 TODAY'S CALENDAR

**9:00-10:00 AM** — [Meeting Title]
  With: [Attendees]
  Prep: [Key talking points or context]

**11:00-12:00 PM** — [Meeting Title]
  With: [Attendees]

⚠️ CONFLICTS:
- [Time]: [Event A] overlaps with [Event B]
  Suggestion: [Proposed resolution]

**FOCUS TIME:** [Available blocks for deep work]
```

### For Conflict Alert (Signal):

```text
🚨 CALENDAR CONFLICT

[Time]: [Event A] conflicts with [Event B]

Options:
1. Decline [Event B] and keep [Event A]
2. Move [Event A] to [suggested time]
3. Decline both and propose [alternative]

Which should I do?
```

### For Invite Requiring Response:

```text
📅 CALENDAR INVITE

[Event Title]
When: [Date/Time]
With: [Organizer + Attendees]
Context: [Why this meeting, background]

Accept or decline?
```

## Important

- NEVER accept or decline invitations without D's explicit approval
- ALWAYS Notify D via Telegram for conflicts or time-sensitive invites
- Include prep notes for important meetings in morning brief
- Respect D's focus time blocks (configured in calendar-config.json)
- When creating events, default to 25min or 50min (not 30min/60min) to allow buffer
- If event details are unclear, ask D before creating
- Maintain calendar history log (calendar-log.json) for context
- Standing instructions for auto-accept/decline can be configured in calendar-rules.json
