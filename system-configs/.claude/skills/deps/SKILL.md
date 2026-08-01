---
name: deps
description: Manage dependencies with security scanning and safe updates. Use when auditing or updating dependencies.
argument-hint: "[audit|update|clean|--quick]"
context: fork
metadata:
  category: orchestration
---

# /deps

## Usage

```bash
/deps            # Quick audit of all detected ecosystems (default)
/deps audit      # Deep parallel security scan with auto-remediation
/deps update     # Safe dependency updates with a rollback point
/deps clean      # Remove unused dependencies
/deps --quick    # Fast check, no deep analysis
```

## Description

Dependency health across polyglot repositories: vulnerability scanning, safe updates, and cleanup.
Auto-detects every package manager present rather than assuming one.

**Quick mode** (default) runs the ecosystems' own tooling directly — no delegation. Reports critical
CVEs, outdated packages, and unused dependencies, with the one-line fix command for each.

**Deep mode** (`audit`, `update`) fans out across ecosystems and security dimensions in parallel, then
classifies findings before touching anything. → `references/ecosystems.md`

Severity bands, supply-chain risk indicators, and the pre-completion checklist:
→ `references/risk-matrix.md`

## What matters most

- **Safe fixes apply automatically; breaking changes get flagged, never auto-applied.** The split
  between the two is the judgement call this skill exists to make — name the specific breaking change
  when flagging one.
- **Create a rollback point before applying updates**, and roll back on test failure rather than
  leaving a half-updated tree.
- **Run the test suite after updating.** An update that compiles is not an update that works.
- **Commit lock files with manifests.** A manifest bump without its lock file doesn't reproduce.
- Report real timings and real counts. Don't narrate progress percentages or speedup multiples.

## Expected Output

```text
User: /deps

🔍 Scanning dependencies...
📦 Detected: npm, pip (2 package managers)

⚠️ Issues Found:
🔴 Critical: lodash@4.17.15 (prototype pollution CVE-2020-8203)
🟡 Medium: axios@0.21.0 (SSRF vulnerability)
📊 Outdated: 12 packages have newer versions
🗑️ Unused: 3 packages not imported

💡 Quick Fixes:
npm audit fix
pip install --upgrade-strategy eager
```

For `/deps audit`, add the classification result: what was auto-remediated, what is flagged for
review with the reason, and which packages are on the supply-chain watchlist.
