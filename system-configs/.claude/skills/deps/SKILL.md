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
/deps                           # Quick audit of all dependencies (30 seconds)
/deps audit                     # Deep multi-instance security scan (20-30 seconds)
/deps update                    # Safe dependency updates with rollback
/deps clean                     # Remove unused dependencies
/deps --quick                   # Fast check without deep analysis (10-15 seconds)
```

## Description

Manages dependencies across all package managers with security scanning and safe updates.
Provides quick audit, update, and cleanup operations for polyglot codebases.

## Expected Output

### Quick Mode (default, 30 seconds)

```text
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

⏱️ Completed in 28 seconds
```

### Deep Mode (/deps audit, 30-45 seconds)

```text
## Wave-Based Dependency Security Audit

### Wave 1: Comprehensive Scanning (18s)
🔍 Deploying security-auditor instances across 3 ecosystems...
📊 Parallel vulnerability assessment (4 security dimensions)...

### Wave 1 Results:
🔴 **Critical Vulnerabilities**: 2 found
- lodash@4.17.15: Prototype pollution (CVE-2020-8203) [AUTO-FIXABLE]
- pillow@8.2.0: Buffer overflow (CVE-2021-34552) [AUTO-FIXABLE]

🟡 **Medium Risk**: 3 vulnerabilities [MANUAL REVIEW]
🟢 **Low Risk**: 7 vulnerabilities [SCHEDULED UPDATE]

### Claude Analysis: Classification Complete
✅ Safe auto-fixes identified: 2 critical vulnerabilities
⚠️ Manual review required: 3 medium-risk updates with breaking changes
📋 Remediation priority matrix generated

### Wave 2: Remediation Planning (12s)
🎯 Deploying specialized security-auditor instances for critical vulnerabilities...
🔧 devops analyzing dependency conflicts...
🚀 devops assessing CI/CD pipeline impact...

### Wave 2 Results:
✅ **Auto-Fix Safe**: 2 critical, 5 low-risk updates
⚠️ **Manual Review**: 3 medium-risk (potential breaking changes)
🔒 **Rollback Strategy**: Automated for all safe updates

### Wave 3: Auto-Fix Implementation (8s)
🔄 Executing safe dependency updates across ecosystems...
📦 npm: Updated lodash@4.17.15 → 4.17.21 ✅
🐍 pip: Updated pillow@8.2.0 → 8.3.2 ✅
🧪 Running compatibility tests... ✅ All tests passing

### Supply Chain Assessment
✅ **Package Authenticity**: All packages verified
⚠️ **Maintainer Risk**: 2 packages flagged for monitoring
🔍 **Suspicious Activity**: None detected

### License Compliance
✅ **Compatible Licenses**: 94% (47/50 packages)
⚠️ **Manual Review**: 2 GPL dependencies flagged

### Auto-Remediation Summary
✅ **Applied Automatically**: 7 safe updates (2 critical, 5 low-risk)
⚠️ **Requires Review**: 3 updates with breaking change potential
📋 **Monitoring**: 2 packages with maintainer risk flagged

### Next Steps
1. ✅ Critical vulnerabilities patched automatically
2. 📋 Review flagged medium-risk updates in security backlog
3. 🔍 Monitor single-maintainer packages for changes
4. 📝 GPL license review scheduled for compliance team

⚡ Completed in 38 seconds (4.2x faster with auto-remediation)
```

### Safe Update Process (/deps update)

```text
## Wave-Based Auto-Remediation Process

### Wave 1: Vulnerability Assessment (15s)
🔍 Comprehensive security scanning across all ecosystems...
📊 Vulnerability categorization and risk analysis...
✅ Safe auto-fix classification complete

### Claude Analysis: Update Strategy
✅ **Auto-Fix Safe**: 8 updates (3 critical, 5 low-risk)
⚠️ **Manual Review**: 2 updates (breaking change potential)
🔒 **Rollback Points**: Automated for all ecosystems

### Wave 2: Remediation Planning (10s)
🎯 Critical vulnerability remediation strategies...
🔧 Dependency conflict resolution...
🚀 CI/CD pipeline compatibility verification...

### Wave 3: Auto-Fix Implementation (8s)
💾 Creating automated rollback snapshots...
🔄 Applying safe updates in parallel:
  📦 npm: 3 security patches applied ✅
  🐍 pip: 2 critical vulnerabilities fixed ✅
  🦀 cargo: 3 dependency updates applied ✅
🧪 Running comprehensive test suite... ✅
🔍 Verifying application functionality... ✅

### Auto-Remediation Results
✅ **Successfully Applied**: 8/10 updates (80% automation rate)
⚠️ **Flagged for Review**: 2 updates require manual assessment
🔒 **Zero Failures**: All auto-fixes verified and stable
⚡ **Performance**: 33 seconds (5x faster than manual process)

### Manual Review Required
⚠️ react@17.x → 18.x: Major version change, component API updates
⚠️ django@3.x → 4.x: Breaking changes in URL routing system

Next: Review flagged updates in development environment
```

## Behavior

### Wave-Based Orchestration System

Three-wave parallel execution system for comprehensive dependency management:

```yaml
# WAVE 1: Comprehensive Scanning (15-20 seconds)
security-auditor (instance pool):
  deployment: One instance per package manager detected
  calculation: min(5, number_of_package_managers)
  distribution:
    - instance_1: npm/yarn dependencies (package.json, lock files)
    - instance_2: Python pip dependencies (requirements.txt, pyproject.toml)
    - instance_3: Go modules (go.mod, go.sum)
    - instance_4: Rust cargo dependencies (Cargo.toml, Cargo.lock)
    - instance_5: Java/Maven dependencies (pom.xml, build.gradle)
  parallel_execution: All package managers scanned simultaneously
  role: Ecosystem-specific vulnerability scanning
  output: Per-ecosystem dependency reports with CVE data

security-auditor (vulnerability analysis):
  deployment: 3-4 instances for parallel vulnerability assessment
  distribution:
    - instance_1: Critical vulnerability (CVSS 9.0+) identification
    - instance_2: Supply chain risk assessment and package reputation
    - instance_3: License compliance and legal compatibility
    - instance_4: Dependency freshness and maintenance status
  parallel_with: [package manager scanners]
  role: Multi-dimensional security analysis
  output: Categorized vulnerability reports

# CLAUDE ANALYSIS PHASE: Pattern Recognition & Categorization
# - Aggregate vulnerability data from all Wave 1 instances
# - Categorize by severity: Critical, High, Medium, Low
# - Identify vulnerability patterns and attack vectors
# - Classify updates: Safe auto-fix vs. requires manual review
# - Generate remediation priority matrix

# WAVE 2: Remediation Planning (10-15 seconds)
security-auditor (critical vulnerability focus):
  deployment: One instance per critical vulnerability category
  calculation: min(6, number_of_critical_vulnerabilities)
  distribution:
    - instance_1: RCE and privilege escalation vulnerabilities
    - instance_2: Authentication bypass and access control
    - instance_3: Data injection vulnerabilities (SQL, XSS, etc.)
    - instance_4: Cryptographic and hash vulnerabilities
    - instance_5: Deserialization and remote exploitation
    - instance_6: Path traversal and file system access
  role: Deep analysis of critical vulnerabilities
  output: Detailed remediation plans with risk assessment

devops:
  role: Dependency conflict analysis and compatibility assessment
  parallel_with: [security-auditor critical instances]
  input: Proposed updates from vulnerability analysis
  output: Breaking change assessment, compatibility matrix

devops:
  role: CI/CD pipeline impact assessment
  parallel_with: [security-auditor, devops]
  input: Proposed dependency changes
  output: Deployment risk analysis, rollback strategies

# CLAUDE DECISION PHASE: Safe Update Classification
# - Analyze breaking change potential for each update
# - Classify updates: Auto-fix safe vs. manual review required
# - Generate update execution plan with rollback points
# - Prioritize updates by security impact vs. stability risk

# WAVE 3: Auto-Fix Implementation (5-10 seconds)
security-auditor (safe update implementation):
  deployment: One instance per package manager with safe updates
  calculation: number_of_ecosystems_with_safe_updates
  distribution:
    - instance_per_ecosystem: Execute safe dependency updates
  role: Apply pre-approved safe dependency updates
  output: Update execution results, compatibility verification

devops (verification):
  role: Post-update verification and rollback readiness
  parallel_with: [update implementation instances]
  input: Update results from security instances
  output: System stability verification, test suite results

# Performance Impact:
#   Traditional sequential: 3-5 minutes across all phases
#   Wave-based parallel: 30-45 seconds total (4-6x faster)
#   Auto-remediation: Immediate safe fixes, flagged risky updates
```

### Multi-Instance Scanning Strategy

```yaml
Multi-Package Manager Support:
  instance_deployment:
    - Auto-detect all package managers in repository
    - Deploy one security-auditor instance per ecosystem
    - Each instance runs ecosystem-specific tools
    - Maximum 5 concurrent instances

  parallel_tools_per_instance:
    - npm: npm audit, npm outdated, depcheck
    - pip: pip-audit, pip list --outdated, pipdeptree
    - go: nancy, govulncheck, go list -u, go mod graph
    - cargo: cargo audit, cargo outdated, cargo tree
    - maven: dependency:analyze, versions:display

  result_aggregation:
    - Real-time streaming from all instances
    - Unified vulnerability report
    - Cross-ecosystem dependency analysis
    - Consolidated risk assessment

Time Optimization:
  - Sequential: 2+ minutes
  - Multi-instance parallel: 20-30 seconds (4-6x faster)
  - Full CPU utilization: Each instance on separate core
```

### Two-Mode Operation

#### Quick Mode (default) - 30 Second Analysis

**What it does**: Essential dependency health check

```yaml
Analysis Scope:
  - Detect package managers automatically
  - Check for known critical vulnerabilities
  - Identify outdated packages
  - Flag unused dependencies

Agent Usage: None (direct tooling)
Output: Summary with actionable items only
```

#### Deep Mode (audit) - Wave-Based Analysis (30-45 seconds)

**What it does**: Comprehensive three-wave dependency analysis with auto-remediation

```yaml
Wave 1 - Comprehensive Scanning (15-20 seconds):
  - Parallel CVE vulnerability scanning across all ecosystems
  - Multi-dimensional security analysis (4 specialized instances)
  - Supply chain risk assessment and package reputation
  - License compliance and legal compatibility checking

Claude Analysis Phase:
  - Pattern recognition and vulnerability categorization
  - Security impact vs. stability risk classification
  - Safe auto-fix vs. manual review determination
  - Remediation priority matrix generation

Wave 2 - Remediation Planning (10-15 seconds):
  - Critical vulnerability deep analysis (up to 6 instances)
  - Dependency conflict and compatibility assessment
  - CI/CD pipeline impact analysis
  - Breaking change risk evaluation

Claude Decision Phase:
  - Safe update classification and approval
  - Update execution plan with rollback points
  - Risk-based update prioritization

Wave 3 - Auto-Fix Implementation (5-10 seconds):
  - Parallel safe dependency updates per ecosystem
  - Real-time compatibility verification
  - Automated rollback on failure detection

Agent Usage:
  - security-auditor instances: 5-15 per wave (dynamic scaling)
  - devops: Compatibility analysis
  - devops: CI/CD impact and verification
  - Coordinated multi-wave deployment

Output:
  - Detailed vulnerability analysis with auto-remediation
  - Immediate safe fixes applied automatically
  - Risky updates flagged for manual review
  - Comprehensive security posture improvement

Performance:
  - Traditional sequential: 3-5 minutes
  - Wave-based parallel: 30-45 seconds (4-6x faster)
  - Auto-remediation: Zero-touch safe updates
```

### Package Manager Support

Auto-detects: npm, pip, go, cargo, maven, gradle, bundler, composer
Based on presence of manifest files (package.json, requirements.txt, etc.)
Uses ecosystem-specific tools: npm audit, pip-audit, cargo audit, nancy (Go)

### Language-Specific Patterns

#### Node.js/npm Workflow

```bash
npm_workflow() {
  # Quick vulnerability check and automated fixes
  npm audit --audit-level high
  npm audit fix

  # Manual review for breaking changes
  npm audit fix --force --dry-run

  # Update outdated packages
  npm outdated && npm update
}
```

#### Other Ecosystems

- Python: pip-audit, pip upgrade, pip-autoremove
- Go: nancy sleuth, go get -u, go mod tidy
- Rust: cargo audit, cargo update

### Agent Coordination

#### Quick Mode (No Agents)

```yaml
Direct Tooling:
  - npm audit, pip-audit, cargo audit
  - Built-in package manager commands
  - Simple vulnerability databases

Speed: 30 seconds average
Accuracy: High for known CVEs
Coverage: Basic security + outdated packages
Auto-remediation: Basic safe fixes only
```

#### Deep Mode (Wave-Based Deployment)

```yaml
Wave 1: Comprehensive Scanning (15-20 seconds)
  security-auditor (ecosystem pool):
    instances: "One per package manager detected (npm, pip, go, cargo, maven)"
    role: "Parallel ecosystem-specific vulnerability scanning"
    tools: "Ecosystem-specific scanners, CVE databases"
    output: "Per-ecosystem vulnerability reports"

  security-auditor (analysis pool):
    instances: "4 specialized vulnerability analysis instances"
    distribution:
      - instance_1: "Critical vulnerability identification (CVSS 9.0+)"
      - instance_2: "Supply chain risk assessment"
      - instance_3: "License compliance analysis"
      - instance_4: "Dependency maintenance status"
    tools: "CVE databases, package reputation analysis, legal compatibility"
    output: "Multi-dimensional security assessment"

Claude Analysis Phase:
  - Aggregate vulnerability data from all Wave 1 instances
  - Categorize by severity and remediation complexity
  - Classify safe auto-fixes vs. manual review requirements
  - Generate remediation priority matrix

Wave 2: Remediation Planning (10-15 seconds)
  security-auditor (critical focus pool):
    instances: "One per critical vulnerability category (max 6)"
    distribution:
      - instance_1: "RCE and privilege escalation"
      - instance_2: "Authentication bypass vulnerabilities"
      - instance_3: "Data injection attacks (SQL, XSS)"
      - instance_4: "Cryptographic vulnerabilities"
      - instance_5: "Deserialization exploits"
      - instance_6: "Path traversal and file access"
    role: "Deep analysis of critical vulnerabilities"
    output: "Detailed remediation plans with risk assessment"

  devops:
    role: "Dependency conflict analysis and compatibility assessment"
    input: "Proposed updates from vulnerability analysis"
    output: "Breaking change assessment, compatibility matrix"

  devops:
    role: "CI/CD pipeline impact assessment"
    input: "Proposed dependency changes"
    output: "Deployment risk analysis, rollback strategies"

Claude Decision Phase:
  - Analyze breaking change potential for each update
  - Classify updates: auto-fix safe vs. manual review required
  - Generate update execution plan with rollback points
  - Prioritize by security impact vs. stability risk

Wave 3: Auto-Fix Implementation (5-10 seconds)
  security-auditor (implementation pool):
    instances: "One per package manager with safe updates"
    role: "Execute pre-approved safe dependency updates"
    tools: "Package manager update commands, compatibility verification"
    output: "Update execution results, verification status"

  devops (verification):
    role: "Post-update verification and rollback readiness"
    input: "Update results from security instances"
    output: "System stability verification, test suite results"

Wave Coordination Strategy:
  - Wave 1: Maximum parallelization for data collection
  - Claude Analysis: Intelligent pattern recognition and classification
  - Wave 2: Targeted analysis of identified issues
  - Claude Decision: Safe vs. risky update determination
  - Wave 3: Parallel auto-remediation with verification

Instance Scaling:
  - Wave 1: 5-9 total instances (ecosystem + analysis)
  - Wave 2: 3-8 instances (critical focus + platform analysis)
  - Wave 3: 2-5 instances (implementation + verification)
  - Total deployment: 10-22 instances across all waves
  - Performance multiplier: 4-6x faster than sequential execution

Auto-Remediation Capabilities:
  - Immediate application of safe security patches
  - Automated rollback on compatibility failure
  - Zero-touch updates for non-breaking changes
  - Intelligent flagging of risky updates for manual review
```

### Risk Assessment Matrix

#### Vulnerability Severity

```yaml
Critical (CVSS 9.0-10.0):
  - Remote code execution, privilege escalation, data exfiltration
  Action: Immediate update required

High (CVSS 7.0-8.9):
  - Authentication bypass, SQL injection, XSS vulnerabilities
  Action: Update within 48 hours

Medium (CVSS 4.0-6.9):
  - Information disclosure, DoS potential, input validation issues
  Action: Schedule update within 1 week

Low (CVSS 0.1-3.9):
  - Minor information leaks, edge case vulnerabilities
  Action: Update during next maintenance
```

#### Supply Chain Risk Factors

```yaml
High Risk Indicators:
  - Single maintainer packages, recent maintainer changes
  - Unusual download patterns, missing metadata
  - Packages with embedded malware history

Medium Risk Indicators:
  - Infrequent updates (>1 year), small user base (<1000 downloads/week)
  - Typosquatting potential, complex dependency chains

Low Risk Indicators:
  - Well-established packages, active maintenance
  - Large user base, corporate sponsorship
```

### Execution Verification

Claude validates dependency management progress and results:

- **Package managers detected** - All present ecosystems identified
- **Vulnerabilities scanned** - Security databases queried successfully
- **Updates applied safely** - No breaking changes introduced
- **Dependencies functional** - Applications still work after changes
- **Lock files updated** - Dependency versions properly recorded
- **Tests passing** - Quality gates maintained during updates

### Examples

#### Quick Dependency Check

```text
User: /deps
Claude: 🔍 Scanning dependencies across 3 package managers...
⚠️ Found 2 critical vulnerabilities in npm packages
📊 12 packages have updates available
🗑️ 3 unused dependencies detected
💡 Run 'npm audit fix' for immediate security fixes
⏱️ Scan completed in 31 seconds
```

#### Security-Focused Audit with Wave-Based Orchestration

```text
User: /deps audit
Claude: 🚀 Initiating wave-based dependency security audit...

### Wave 1: Comprehensive Scanning (18s)
📊 Instance Pool Status:
  - security-auditor[ecosystem-1]: npm (127 packages) ✅
  - security-auditor[ecosystem-2]: pip (85 packages) ✅
  - security-auditor[ecosystem-3]: go modules (35 packages) ✅
  - security-auditor[analysis-1]: Critical vulnerability detection ✅
  - security-auditor[analysis-2]: Supply chain assessment ✅
  - security-auditor[analysis-3]: License compliance ✅
  - security-auditor[analysis-4]: Maintenance status ✅

🧠 Claude Analysis: Categorizing 247 dependencies...
✅ Safe auto-fixes: 3 critical vulnerabilities identified
⚠️ Manual review: 2 updates with breaking change potential

### Wave 2: Remediation Planning (12s)
🎯 Deploying specialized remediation instances:
  - security-auditor[critical-1]: RCE vulnerability (express@4.16.1)
  - security-auditor[critical-2]: Auth bypass (jsonwebtoken@8.5.0)
  - devops: Dependency conflict analysis
  - devops: CI/CD impact assessment

🧠 Claude Decision: Update execution plan ready
✅ Auto-approved: 3 critical + 4 low-risk updates
⚠️ Flagged: 2 medium-risk updates for manual review

### Wave 3: Auto-Fix Implementation (8s)
🔄 Parallel safe update execution:
  - security-auditor[npm]: express@4.16.1 → 4.18.2 ✅
  - security-auditor[npm]: jsonwebtoken@8.5.0 → 9.0.0 ✅
  - security-auditor[go]: gorilla/mux security patch ✅
  - devops[verify]: Test suite validation ✅

⚡ Wave-Based Results (38 seconds total):
✅ Auto-remediated: 7/9 vulnerabilities (78% automation)
⚠️ Manual review: 2 updates flagged (django@3→4, react@17→18)
🔒 Zero failures: All auto-fixes verified and stable
📈 Performance: 4.2x faster with intelligent auto-remediation
```

### Notes

- **Wave-Based Orchestration**: Three-phase approach with intelligent analysis between waves
- **Auto-Remediation**: Immediate application of safe security patches with verification
- **Dynamic Scaling**: 10-22 instances deployed across waves based on project complexity
- **Performance Target**: 30-45 seconds for full audit with auto-fixes (was 3-5 minutes)
- **Smart Classification**: AI-driven safe vs. risky update determination between waves
- Quick mode for daily workflow (30 seconds), deep mode for security reviews with auto-fixes (30-45 seconds)
- Automatically detects all package managers in polyglot repositories
- Prioritizes critical security fixes with immediate auto-remediation
- Zero-touch updates for safe patches, intelligent flagging for breaking changes
- Automated rollback capability for failed updates
- Comprehensive test suite validation post-update
