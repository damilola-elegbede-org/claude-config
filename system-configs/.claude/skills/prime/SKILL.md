---
name: prime
description: Build repository understanding and context. Use when onboarding to a codebase or building context.
argument-hint: "[--lite|--full|component-name]"
context: fork
metadata:
  category: workflow
---

# /prime

## Usage

```bash
/prime                    # Standard analysis (default)
/prime --lite             # Quick essential context
/prime --full             # Deep-dive analysis
/prime authentication     # Focused component analysis
/prime api                # Targeted architecture analysis
```

## Description

Build comprehensive repository understanding using researcher agent. Analyzes structure, technology stack, and development patterns.

## Behavior

1. **Discover**: Scan repository structure and dependencies
2. **Analyze**: Deploy researcher agent for deep analysis
3. **Synthesize**: Generate actionable context summary

### Modes

| Mode | Duration | Depth |
|------|----------|-------|
| `--lite` | ~30s | Essential context only |
| Default | 2-5 min | Technology + architecture |
| `--full` | 5-10 min | Complete deep-dive |
| Focused | 1-3 min | Single component analysis |

## Expected Output

### Standard Mode

```text
User: /prime

Analyzing repository...

Deploying researcher agent...

Repository: my-react-app

Technology Stack:
  - Frontend: React 18 + TypeScript
  - Build: Vite 4.0
  - State: Zustand + React Query
  - Testing: Jest + RTL + Cypress

Architecture:
  - Pattern: Atomic Design components
  - State: Hybrid (local + global + server)
  - API: Custom hooks wrapping React Query

Development:
  npm run dev      # Start with HMR
  npm run test     # Full test suite
  npm run build    # Production build

Key Entry Points:
  - src/main.tsx (bootstrap)
  - src/App.tsx (root + routing)
  - src/hooks/index.ts (hook exports)

Current Context:
  Branch: feature/user-auth
  3 modified files
  PR #42: "Add user authentication"
```

### Lite Mode

```text
User: /prime --lite

Quick Context: ecommerce-api

Branch: fix/payment-gateway (2 files changed)
Node.js/Express API
Ready in 1.2 seconds
```

### Focused Mode

```text
User: /prime authentication

Deep dive: Authentication System

Files: 8 files, 3 integrations
Architecture: JWT with refresh tokens

Security Assessment:
  httpOnly cookies (XSS protection)
  Refresh token rotation
  Missing rate limiting on login

Recommendations:
  1. Add rate limiting middleware
  2. Complete password reset flow
  3. Implement session cleanup
```

## Notes

- Uses researcher agent for analysis
- Results optimized for development productivity
- Auto-runs on Claude Code startup (disable with .claude/noautoprime)
- Typical execution: 1-5 minutes
