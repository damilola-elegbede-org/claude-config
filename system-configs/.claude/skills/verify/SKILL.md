---
name: verify
description: Verify command execution met requirements. Use when confirming a command or skill completed correctly.
argument-hint: "[--last|--command|--report-only]"
metadata:
  category: workflow
---

# /verify

## Usage

```bash
/verify                       # Verify last command
/verify --command "/test"     # Verify specific command
/verify --report-only         # Report without recommendations
```

## Description

Evaluates how well a previous command execution met its requirements. Produces an alignment score with actionable recommendations.

## Behavior

1. **Extract**: Identify requirements from the original command
2. **Analyze**: Compare execution against requirements
3. **Score**: Calculate alignment percentage
4. **Recommend**: Suggest improvements if needed

## Expected Output

```text
User: /verify

Verifying: /test --create

Analyzing execution...

Verification Results:

Overall Alignment: 85%

Category Breakdown:
  Requirement Completeness: 88%
     - 6/7 explicit requirements met
     - Missing: error boundary handling

  Implementation Quality: 92%
     - Code follows best practices
     - Proper error handling

  Output Accuracy: 75%
     - Format deviation: JSON instead of YAML
     - Missing summary statistics

Key Findings:
  1. Missing error boundary for async operations
  2. Output format should be YAML

Recommendations:
  1. HIGH: Add error boundary handling
  2. MEDIUM: Convert output to YAML format

With fixes applied: projected 94%
```

### Report-Only Mode

```text
User: /verify --report-only

[Analysis runs...]

Alignment: 85%
  - 2 issues identified
  - See above for details

(Recommendations omitted in report-only mode)
```

## Scoring Categories

| Category | Weight | Measures |
|----------|--------|----------|
| Requirement Completeness | 30% | Explicit + implicit requirements |
| Implementation Quality | 25% | Code standards, practices |
| Output Accuracy | 20% | Format, data correctness |
| Performance | 15% | Execution time, efficiency |
| Extras/Deviations | 10% | Scope creep, additions |

## Notes

- Works with any previously executed command
- Provides actionable fix commands
- Typical execution: 1-2 minutes
