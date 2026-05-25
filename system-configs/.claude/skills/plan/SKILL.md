---
name: plan
description: Generate PRD and task files for implementation. Use when planning a feature, project, or task.
argument-hint: "[task] [--simple|--no-execute|--file]"
context: fork
metadata:
  category: workflow
---

# /plan

## Usage

```bash
/plan $ARGUMENTS         # Generate PRD and task files
/plan --simple <task>            # Single PR plan (small features)
/plan --no-execute <task>        # Plan only, no file generation
/plan --file <path>              # Read requirements from file
```

## Description

Generate Product Requirements Document (PRD) and task files using architect agent.
Creates structured implementation plans with clear phases and agent assignments.

## Behavior

1. **Analyze**: Deploy architect agent to understand requirements
2. **Design**: Create technical architecture and task breakdown
3. **Generate**: Write PRD and phase files to `.tmp/plans/<repo>/<feature>/`

### Clarification

Never guesses requirements. Asks specific questions when needed before proceeding.

## Expected Output

```text
User: /plan Add user authentication

Analyzing requirements...

Deploying architect agent...

PRD Preview: User Authentication

Executive Summary:
  JWT-based authentication with registration and login flows

Technical Design:
  - Database: users table with bcrypt passwords
  - API: /auth/register, /auth/login, /auth/refresh
  - Frontend: Login/Register components with form validation

Phases:
  Phase 1: Database schema and migrations (2 tasks)
  Phase 2: Auth service and API endpoints (3 tasks)
  Phase 3: Frontend components and integration (4 tasks)

Ready to generate files? (yes/no/modify): yes

Generated in .tmp/plans/my-app/authentication/:
  - prd.md
  - phase_1_pr_1_database.md
  - phase_2_pr_1_auth_service.md
  - phase_3_pr_1_frontend.md
```

### Simple Mode

```text
User: /plan --simple Add logout button

Simple Plan: Logout Button

Tasks (1 PR):
  1. Add logout button to header component
  2. Implement logout API call
  3. Clear auth state on logout
  4. Add confirmation dialog

Generated: .tmp/plans/my-app/logout/phase_1_pr_1_logout.md
```

### No-Execute Mode

```text
User: /plan --no-execute Add caching

[Analysis completes...]

Implementation Plan (preview only)
  Files to modify: 8
  Risk: Low
  Dependencies: redis

No files generated (--no-execute mode)
```

## Notes

- Uses architect agent for technical planning
- Generates structured task files with agent assignments
- Always asks for clarification on ambiguous requirements
- Typical execution: 2-5 minutes
