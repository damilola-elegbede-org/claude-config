---
name: security-ops
description: Operational security audit procedures — weekly repo audits, secret scanning, dependency vulnerability checks, file permission verification. Use when running security audits, scanning for secrets, or checking dependency vulnerabilities.
argument-hint: "[--weekly|--secrets|--deps|--permissions]"
category: operations
user-invocable: false
---

# Security Ops

Operational playbook for recurring security audits across all tracked repositories.

## Audit Repo Paths

| Repo | Local Path |
|------|-----------|
| `damilola-elegbede-org/cortex` | `~/dev/cortex` |
| `damilola-elegbede-org/damilola.tech` | `~/dev/damilola.tech` |
| `damilola-elegbede-org/alocubano.boulderfest` | `~/dev/alocubano.boulderfest` |
| `damilola-elegbede-org/scf-social-media` | `~/dev/scf-social-media` |
| `damilola-elegbede-org/tidal-mcp` | `~/dev/tidal-mcp` |
| `damilola-elegbede-org/resume-toolkit` | `~/dev/resume-toolkit` |
| `damilola-elegbede-org/career-data` | `~/dev/career-data` |

## Usage

```bash
/security-ops              # Full weekly audit (all checks)
/security-ops --secrets    # Secret exposure scan only
/security-ops --deps       # Dependency vulnerability scan only
/security-ops --permissions # File permission check only
```

## Pre-flight

Ensure all audit repos are cloned and up-to-date:

```bash
for repo in cortex damilola.tech alocubano.boulderfest scf-social-media tidal-mcp resume-toolkit career-data; do
  if [ -d "$HOME/dev/$repo" ]; then
    git -C "$HOME/dev/$repo" pull origin main 2>/dev/null || true
  else
    gh repo clone "damilola-elegbede-org/$repo" "$HOME/dev/$repo" 2>/dev/null || echo "WARN: Failed to clone $repo"
  fi
done
```

## Audit Steps

### a. Secret Exposure Scan

For each repo in `~/dev/`:

```bash
cd ~/dev/<repo>
rg -n 'AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|BEGIN.*PRIVATE KEY' \
  --glob '!node_modules/**' --glob '!.git/**' --glob '!*.md' 2>/dev/null || true
```

### b. Dependency Vulnerability Scan

```bash
cd ~/dev/<repo>
# Node.js repos:
[ -f package-lock.json ] && npm audit --audit-level=moderate 2>&1 || true
# Python repos:
[ -f requirements.txt ] && pip-audit -r requirements.txt 2>&1 || true
```

### c. .gitignore Coverage Check

```bash
cd ~/dev/<repo>
for pattern in '.env' 'node_modules' '*.key' '*.pem'; do
  grep -q "$pattern" .gitignore 2>/dev/null && echo "OK $pattern" || echo "MISSING $pattern"
done
```

### d. File Permission Check

```bash
# Critical paths
stat -f "%Sp %N" ~/.cortex/credentials/ ~/.cortex/secret ~/.claude/settings.json 2>/dev/null
# Env files across repos
find ~/dev/ -name "*.env*" -not -path "*/node_modules/*" -not -path "*/.git/*" \
  -exec stat -f '%Lp %N' {} \; 2>/dev/null || true
```

### e. Claude Config Security Check

```bash
# Verify no plaintext secrets in Claude Code settings
rg -n 'xoxb-|xapp-|sk-|ghp_|AKIA|BEGIN.*PRIVATE KEY' \
  ~/.claude/settings.json ~/.claude/mcp-servers/*.py 2>/dev/null || echo "OK: No plaintext secrets found"
```

## Coverage Gap Handling

If a repo is missing from `~/dev/` and cloning fails:

1. Log as `COVERAGE_GAP` with repo name and reason
2. Do NOT skip silently — always report it

## Severity Classification

| Level | Criteria |
|-------|---------|
| CRITICAL | Secret exposure in git history or live file; auth bypass |
| HIGH | Unpatched CVE severity>=high; plaintext credential in config |
| MEDIUM | Moderate CVE; stale dependency; missing .gitignore patterns |
| LOW | Outdated deps with no known CVE; cosmetic misconfigs |
| INFO | Coverage gap; advisory-only findings |

## Reporting

Post the full report to Slack #alerts:

```bash
/Users/daelegbe/.openclaw-dara/workspace/scripts/slack-post.sh post alerts "<report>" dara
```

For HIGH+ findings, also tag D in the alert.

Write heartbeat:

```bash
echo '{"task":"security-ops","agent":"dara","lastRun":"'$(date -u +%Y-%m-%dT%H:%M:%SZ)'","status":"ok"}' > ~/.cortex/heartbeats/dara-security-ops.json
```

## Rules

- **NEVER** log actual secret values — only file paths and pattern types
- CRITICAL findings require immediate notification via Telegram (when available)
- One consolidated report per run — no finding-by-finding posting
