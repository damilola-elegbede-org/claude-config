# Orchestration Skill Template

Template for complex multi-step skills that use Claude Code's advanced features.

## Directory Structure

```text
skills/<name>/
  SKILL.md          # Required: skill definition
  templates/        # Optional: supporting template files
  examples/         # Optional: reference examples
```

## Frontmatter Reference

```yaml
---
name: skill-name              # Required: lowercase-hyphenated, matches directory
description: Brief description # Required: shown in autocomplete
metadata:
  category: orchestration     # Required: orchestration for complex workflows

# Claude Code Skill Features (all optional)
context: fork                 # Run in isolated subagent context
agent: code-reviewer          # Route to specific agent type
user-invocable: true          # Can user invoke directly (default: true)
disable-model-invocation: true # Prevent model from invoking
allowed-tools: Read, Grep     # Restrict available tools
---
```

## Frontmatter Fields Explained

### context: fork

Runs the skill in an isolated subagent context. Use when:

- Skill produces intermediate output that shouldn't pollute main conversation
- Investigation/analysis should be contained
- Workflow has many steps that could confuse main context

### agent: type

Routes to a specific Claude Code built-in agent type:

| Agent Type | Use For |
|------------|---------|
| general-purpose | Multi-step tasks requiring all tools |
| Explore | Fast codebase search |
| Plan | Design implementation approaches |
| debugger | Bug/performance investigation |
| architect | System design decisions |
| code-reviewer | Code quality review |
| test-engineer | Writing tests |
| security-auditor | Vulnerability detection |
| researcher | Technology analysis |
| frontend-engineer | UI/component work |
| backend-engineer | Server/API work |
| devops | CI/CD, K8s, IaC |
| data-engineer | Pipelines, ETL |
| tech-writer | Documentation |

### allowed-tools

Restricts which tools the skill can use. Common sets:

- Read-only: `Read, Grep, Glob`
- Code changes: `Read, Write, Edit, Grep, Glob`
- With Bash: `Read, Write, Edit, Grep, Glob, Bash`
- Orchestration: `Skill, Task, TaskCreate, TaskUpdate, TaskList, TaskOutput`

## Task System Integration

Use TaskCreate/TaskUpdate for progress tracking:

```text
### Step 1: Create Task Plan

TaskCreate: "Phase 1 description" (no blockers)
  activeForm: "Running phase 1"
TaskCreate: "Phase 2 description" (blockedBy: phase1)
  activeForm: "Running phase 2"

### Step 2: Execute with Tracking

TaskUpdate: task1 -> in_progress
[do work]
TaskUpdate: task1 -> completed

TaskUpdate: task2 -> in_progress
[do work]
TaskUpdate: task2 -> completed
```

## Parallel Execution Pattern

Use `run_in_background: true` for parallel agent execution:

```yaml
# Launch multiple agents in parallel
Task tool:
  subagent_type: "agent-type-1"
  run_in_background: true
  prompt: "First task..."

Task tool:
  subagent_type: "agent-type-2"
  run_in_background: true
  prompt: "Second task..."

# Collect results
TaskOutput: task_id=<id1>, block=true
TaskOutput: task_id=<id2>, block=true
```

## Complete Example

### Example Frontmatter

```yaml
---
name: example-orchestrator
description: Example multi-phase orchestration skill
context: fork
allowed-tools: Skill, Task, TaskCreate, TaskUpdate, TaskList, TaskOutput
metadata:
  category: orchestration
---
```

### Example Usage Section

```text
## Usage

/example-orchestrator           # Run full workflow
/example-orchestrator --quick   # Skip optional phases
```

### Example Task Plan

```text
TaskCreate: "Analysis phase" (no blockers)
  activeForm: "Analyzing codebase"
TaskCreate: "Processing phase" (blockedBy: analysis)
  activeForm: "Processing results"
TaskCreate: "Finalization phase" (blockedBy: processing)
  activeForm: "Finalizing output"
```

### Example Parallel Execution

```text
TaskUpdate: "Analysis phase" -> in_progress

# Launch parallel analysis agents
Task 1 (background):
  subagent_type: "Explore"
  run_in_background: true
  prompt: "Analyze aspect 1..."

Task 2 (background):
  subagent_type: "Explore"
  run_in_background: true
  prompt: "Analyze aspect 2..."

# Collect results
TaskOutput: task_id=task1, block=true
TaskOutput: task_id=task2, block=true

TaskUpdate: "Analysis phase" -> completed
```

### Example Expected Output

```text
Analysis phase...
  Analyzing codebase (2 parallel agents)
  Analysis complete

Processing phase...
  Processing results
  Processing complete

Finalization phase...
  Creating final output
  Complete

All phases complete (3/3)
```

## When to Use Orchestration Skills vs Commands

| Criterion | Use Command | Use Orchestration Skill |
|-----------|-------------|-------------------------|
| Context isolation needed? | No | Yes (context: fork) |
| Routes to specific agent? | No | Yes (agent: type) |
| Complex multi-phase workflow? | No | Yes |
| Needs supporting files? | No | Yes (templates/) |
| Parallel agent execution? | Sometimes | Yes |
| Task progress tracking? | Optional | Recommended |

## Validation

Run before syncing:

```bash
./scripts/validate-skills.py
```

Validates:

- SKILL.md exists in directory
- Frontmatter has valid fields
- name matches directory name
- category is valid
- agent type is valid (if specified)
- context value is valid (if specified)
