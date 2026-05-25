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

- Remove unnecessary words and phrases
- Structure with bullets or numbered lists for clarity
- Use active voice and action-oriented language
- Ensure every word serves a purpose
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
- Reduced from X to Y words (Z% reduction)
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

**Original (52 words):**

```text
I need you to please help me write a Python function that can validate
email addresses and return true if they're valid or false if they're not.
It should handle various edge cases and be robust.
```

**Optimized (18 words):**

```text
Write Python email validation function.

Requirements:
- Return boolean (True/False)
- Handle RFC 5322 edge cases
- Production-ready robustness
```

**Result**: 65% shorter, enhanced specificity, improved structure

## Behavior

### SCOPE Framework Integration

```yaml
S - Situation: Context (only if essential for clarity)
C - Constraints: Requirements, limitations, technical specifications
O - Objective: Single clear goal (REQUIRED)
P - Persona: Role needed (optional)
E - Examples: Input/output (if ambiguous)
```

### Optimization Rules

1. **Remove unnecessary elements**:
   - Eliminate filler words ("please", "I need you to")
   - Remove redundant phrases
   - Cut verbose explanations

2. **Enhance structure**:
   - Use bullets or numbered lists
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
- **Improvement Metrics** - Quantified enhancements documented
- **Alternative Variations** - Multiple optimized versions provided
- **No Execution** - Command returns optimized text only, no actions taken
- **System Boundary Maintained** - Operation limited to optimization scope

## Implementation Notes

### Optimization Strategy

Direct analysis and enhancement focusing on:

- **Technical Clarity**: Remove ambiguity, improve structure
- **User Experience**: Reduce cognitive load, enhance comprehension
- **Objective Alignment**: Ensure efficiency and clear goals

### Quality Assurance

- Maintain original intent while improving effectiveness
- Generate multiple variations for different contexts
- Provide implementation guidance when helpful
- Ensure copy-ready output

### Notes

- **Direct Execution**: Streamlined optimization without complex orchestration
- **SCOPE Framework**: Systematic structure for effective prompts
- **Copy-Ready Output**: Immediately usable optimized prompts
- **Single Purpose**: Text optimization only, no execution or side effects
