# Package ecosystems

Auto-detect by manifest file presence: npm/yarn (`package.json`), pip (`requirements.txt`,
`pyproject.toml`), go (`go.mod`), cargo (`Cargo.toml`), maven/gradle (`pom.xml`, `build.gradle`),
bundler (`Gemfile`), composer (`composer.json`).

## Tools per ecosystem

| Ecosystem | Audit          | Outdated                  | Unused / tree      |
| --------- | -------------- | ------------------------- | ------------------ |
| npm       | `npm audit`    | `npm outdated`            | `depcheck`         |
| pip       | `pip-audit`    | `pip list --outdated`     | `pipdeptree`       |
| go        | `govulncheck`, `nancy sleuth` | `go list -u -m all` | `go mod graph` |
| cargo     | `cargo audit`  | `cargo outdated`          | `cargo tree`       |
| maven     | —              | `versions:display-dependency-updates` | `dependency:analyze` |

Scan ecosystems in parallel — one `security-auditor` per detected ecosystem, capped at 5 concurrent.
Aggregate into one report rather than emitting per-ecosystem output separately.

## Update workflows

```bash
# npm
npm audit --audit-level high
npm audit fix
npm audit fix --force --dry-run    # inspect breaking changes before committing to them
npm outdated && npm update
```

- **Python**: `pip-audit`, then targeted upgrades; `pip-autoremove` for unused.
- **Go**: `nancy sleuth`, `go get -u`, `go mod tidy`.
- **Rust**: `cargo audit`, `cargo update`.

## Deep mode delegation

For `/deps audit` and `/deps update`, fan out rather than scanning serially:

- `security-auditor`, one per ecosystem — vulnerability scan against CVE data.
- `security-auditor`, additional instances for the cross-cutting dimensions that don't map to a single
  ecosystem: critical-CVE identification (CVSS 9.0+), supply-chain/package reputation, license
  compliance, maintenance status.
- `devops` — dependency conflict and breaking-change assessment for proposed updates.
- `devops` — CI/CD pipeline impact and rollback strategy.

Between scanning and applying, do the classification yourself: aggregate the findings, sort by
severity, and split updates into safe-to-apply vs. needs-human-review. Apply the safe set with a
rollback point, run the test suite, and leave the rest flagged with the specific breaking change
(e.g. "react@17→18: component API updates", "django@3→4: URL routing changes").
