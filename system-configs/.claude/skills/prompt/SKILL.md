---
name: prompt
description: Optimize prompts using direct execution with SCOPE framework. Use when refining or improving prompts.
argument-hint: "[text|--file|--f]"
metadata:
  category: workflow
---

# /prompt

## Usage

```bash
/prompt $ARGUMENTS           # Optimize text directly
/prompt --file <path>    # Optimize from file
/prompt -f <path>        # Optimize from file (short form)
/prompt                  # Interactive mode
```

## Description

Optimize prompts using direct execution with the SCOPE framework. This command analyzes clarity,
structure, specificity, and efficiency to create clean, effective prompts ready for immediate use.

**SYSTEM BOUNDARY**: This command ONLY optimizes prompts and returns the optimized text.
It does NOT execute prompts or perform actions based on prompt content.

## Direct Optimization Process

### Analysis Phase

Claude directly analyzes the input prompt across three dimensions:

- **Clarity & Structure**: Remove fluff, improve readability, enhance technical communication
- **User Experience**: Reduce cognitive load, improve comprehension factors
- **Objective Alignment**: Check alignment with goals, maximize efficiency and business value

### Enhancement Phase

Apply optimization improvements:

- Remove filler and restated defaults; keep context, constraints, and their reasons
- Use lists for reference data (requirements, inputs); use prose for behavioral guidance so each rule keeps its reason
- Use active voice and action-oriented language
- Ensure every sentence earns its place — context the model can't infer always does
- Apply SCOPE framework structure

### Validation Phase

Verify improvements maintain original intent while enhancing effectiveness:

- Compare optimized version against original objectives
- Ensure clarity improvements don't sacrifice meaning
- Validate enhanced specificity maintains scope
- Generate alternative variations for different use cases

## Expected Output

### Output Format

```text
OPTIMIZED PROMPT:
[Clean optimized text following SCOPE framework]

OPTIMIZATION IMPROVEMENTS:
- What changed and why (each edit tied to a reason: ambiguity removed, missing context added, dated emphasis dialed down)
- Applied SCOPE structure
- Enhanced clarity and readability
- Improved specificity and precision
- Optimized for comprehension

ALTERNATIVE VARIATIONS:
1. [Variation focusing on brevity]
2. [Variation emphasizing specificity]
3. [Variation optimizing for clarity]
```

### Before/After Example

Illustrative.

**Original:**

```text
I need you to please help me write a Python function that can validate
email addresses and return true if they're valid or false if they're not.
It should handle various edge cases and be robust.
```

**Optimized:**

```text
Write a Python function that validates an email address and returns True or
False. It will be used to check sign-up form input, so favor rejecting
obviously malformed addresses over full RFC compliance. Include tests for
empty strings, missing @, and multiple @.
```

**Result**: Goal, use context, and success criteria made explicit; no requirements invented.

## Behavior

### SCOPE Framework Integration

```yaml
S - Situation: Audience, purpose, environment, and the reasons behind constraints (REQUIRED — the model can't infer what only the author knows)
C - Constraints: Requirements, limitations, technical specifications
O - Objective: Single clear goal (REQUIRED)
P - Persona: Role needed (optional)
E - Examples: Input/output (if ambiguous)
```

### Optimization Rules

1. **Remove unnecessary elements**:
   - Eliminate filler words ("please", "I need you to")
   - Remove redundant phrases
   - Remove filler and restated defaults; keep context, constraints, and their reasons

2. **Enhance structure**:
   - Lists for reference data, prose for behavior
   - Group related requirements
   - Apply logical flow

3. **Improve specificity**:
   - Replace vague terms with precise language
   - Add technical specifications when needed
   - Define clear success criteria

4. **Optimize for comprehension**:
   - Use active voice
   - Choose concrete over abstract terms
   - Ensure single, clear objective

5. **Calibrate emphasis**: rewrite CAPS/CRITICAL/MUST and stacked NEVERs to plain statements with their reason; drop
   'think step by step' and scratchpad-tag instructions (current models reason natively); keep emphasis only on one
   demonstrably underweighted instruction.

### Interactive Mode

For `/prompt` without arguments:

1. **Input Collection**: Prompt user for text to optimize
2. **Direct Analysis**: Analyze clarity, structure, and effectiveness
3. **Optimization**: Apply SCOPE framework improvements
4. **Validation**: Verify improvements maintain intent
5. **Output**: Provide optimized version with alternatives
6. **Optional Refinement**: Single refinement cycle if requested
   - To request: reply with `refine: <specific aspect to improve>`

File input: Supports .md, .txt, .yaml, .json with full analysis

### Success Criteria

The command succeeds when direct execution delivers:

- **Comprehensive Analysis** - Clarity, structure, and objective alignment evaluated
- **SCOPE Applied** - Framework structure implemented effectively
- **Clean Output** - Optimized prompt ready for immediate use
- **Change rationale** - Each edit has a stated reason
- **Alternative Variations** - Multiple optimized versions provided
- **No Execution** - Command returns optimized text only, no actions taken
- **System Boundary Maintained** - Operation limited to optimization scope
