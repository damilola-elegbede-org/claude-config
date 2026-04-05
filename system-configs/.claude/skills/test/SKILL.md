---
name: test
description: Auto-discover and run tests for any project. Use when running or creating tests.
argument-hint: "[--create|--framework|--coverage]"
category: workflow
---

# /test

## Usage

```bash
/test                           # Auto-discover and run tests
/test --create                  # Generate test suite if missing
/test --framework <name>        # Use specific framework (jest, pytest, etc.)
/test --coverage                # Run with coverage reporting
```

## Description

Universal test runner that discovers and runs tests for any repository, and creates test
suites on demand. Uses smart detection across README files, package managers, and framework
conventions to find the right test command, and supports test creation via `--create` when
no suite exists.

## Behavior

### Default Mode - Auto-Discovery and Execution

**What it does:** Finds test command and runs it

1. **Discover Test Command** (in order of priority)

   a. Check README.md for test commands:

   ```bash
   # Look for sections like "Testing", "Running Tests", "Development"
   # Extract commands from code blocks
   ```

   b. Check package managers:

   ```yaml
   JavaScript/TypeScript:
     - package.json: npm test, npm run test:unit, yarn test

   Python:
     - pyproject.toml: pytest, python -m pytest
     - setup.py: python -m pytest
     - tox.ini: tox

   Go:
     - go.mod: go test ./...

   Rust:
     - Cargo.toml: cargo test

   Ruby:
     - Gemfile: bundle exec rspec, rake test

   Java:
     - pom.xml: mvn test
     - build.gradle: gradle test, ./gradlew test

   .NET:
     - *.csproj: dotnet test
   ```

   c. Check for test framework files:

   ```bash
   # Common test config files
   - pytest.ini, .pytest.ini → pytest
   - jest.config.js → npm test
   - vitest.config.js → npm test
   - .rspec → rspec
   ```

   d. Look for test directories/files:

   ```bash
   # If test files found but no command
   - tests/, __tests__/, test/ directories
   - *_test.*, *.test.*, test_*.* files
   # Infer framework from file patterns
   ```

2. **Execute Test Command**

   ```bash
   # Run discovered command with appropriate environment
   NODE_ENV=test npm test
   # or
   pytest -v
   # or
   go test ./...
   ```

3. **Report Results**
   - Show test output in real-time
   - Highlight failures and errors
   - Display coverage if available
   - Report test count and duration

### Create Mode (--create)

**What it does:** Generates basic test suite when none exists

**Triggers:**

- No test command found after discovery
- User explicitly requests with --create flag
- No test files found in repository

**Process with Task Tracking:**

Uses the Task system to track multi-step generation:

```yaml
Task Phases:
  1. "Detect project type"
     - Analyze files to determine language
     - Identify framework preferences
     - Status: pending → in_progress → completed

  2. "Select test framework"
     - Choose appropriate framework (Jest, pytest, etc.)
     - Consider project conventions
     - Status: pending → in_progress → completed

  3. "Generate test structure"
     - Deploy test-engineer agent
     - Create test files and configuration
     - Status: pending → in_progress → completed

  4. "Install dependencies"
     - Add test framework dependencies
     - Update package manager configs
     - Status: pending → in_progress → completed

  5. "Verify tests run"
     - Execute generated tests
     - Report initial coverage
     - Status: pending → in_progress → completed
```

**Implementation:**

1. **Detect Project Type**
   - Language (based on files present)
   - Framework preferences (if config exists)

2. **Deploy test-engineer Agent**
   - Single agent to generate test structure
   - Creates appropriate test files for project type
   - Adds test configuration
   - Updates package.json/pyproject.toml with test script

3. **Verify Generated Tests**
   - Run generated tests to ensure they work
   - Report initial test coverage

### Framework Mode (--framework)

**What it does:** Uses specific test framework

```bash
/test --framework jest    # Use Jest explicitly
/test --framework pytest  # Use pytest explicitly
/test --framework go      # Use Go test explicitly
```

Overrides auto-discovery and runs specified framework.

### Coverage Mode (--coverage)

**What it does:** Runs tests with coverage reporting

Automatically adds coverage flags:

- Jest/Vitest: `--coverage`
- pytest: `--cov=src`
- Go: `-cover`
- Rust: `--coverage` (if llvm-cov installed)

## Expected Output

### Successful Test Run

```text
User: /test
Claude: 🔍 Discovering test command...

✅ Found: npm test (from package.json scripts)

🧪 Running tests...

> my-project@1.0.0 test
> jest --passWithNoTests

 PASS  src/auth/__tests__/login.test.ts
 PASS  src/api/__tests__/endpoints.test.ts
 PASS  src/utils/__tests__/helpers.test.ts

Test Suites: 3 passed, 3 total
Tests:       45 passed, 45 total
Snapshots:   0 total
Time:        8.234 s

✅ All tests passed (45/45)
```

### Test Failures

```text
User: /test
Claude: 🔍 Discovering test command...

✅ Found: pytest -v (from pytest.ini)

🧪 Running tests...

======================== test session starts ========================
tests/test_auth.py::test_login PASSED                         [ 20%]
tests/test_auth.py::test_logout FAILED                        [ 40%]
tests/test_api.py::test_get_user PASSED                       [ 60%]
tests/test_api.py::test_create_user FAILED                    [ 80%]
tests/test_utils.py::test_helpers PASSED                      [100%]

============================= FAILURES ==============================
______________________ test_logout _________________________________

    def test_logout():
>       assert logout_user() == True
E       AssertionError: assert False == True

tests/test_auth.py:12: AssertionError

______________________ test_create_user ____________________________

    def test_create_user():
>       response = api.create_user({"name": "test"})
E       KeyError: 'email'

tests/test_api.py:25: KeyError

==================== short test summary info =======================
FAILED tests/test_auth.py::test_logout - AssertionError
FAILED tests/test_api.py::test_create_user - KeyError: 'email'
==================== 2 failed, 3 passed in 2.34s ===================

❌ 2 of 5 tests failed

Failed tests:
  1. test_logout (tests/test_auth.py:12)
     AssertionError: assert False == True

  2. test_create_user (tests/test_api.py:25)
     KeyError: 'email'

💡 Tip: Review the failed tests and fix the issues
💡 Run `/review` to check for code quality issues
```

### Coverage Report

```text
User: /test --coverage
Claude: 🔍 Discovering test command...

✅ Found: npm test (from package.json scripts)

🧪 Running tests with coverage...

> my-project@1.0.0 test
> jest --coverage

 PASS  src/auth/__tests__/login.test.ts
 PASS  src/api/__tests__/endpoints.test.ts
 PASS  src/utils/__tests__/helpers.test.ts

Test Suites: 3 passed, 3 total
Tests:       45 passed, 45 total

--------------------|---------|----------|---------|---------|
File                | % Stmts | % Branch | % Funcs | % Lines |
--------------------|---------|----------|---------|---------|
All files           |   87.34 |    82.15 |   91.23 |   86.92 |
 src/auth           |   92.45 |    88.32 |   95.12 |   91.87 |
  login.ts          |   94.23 |    90.12 |   96.43 |   93.78 |
  logout.ts         |   89.56 |    85.34 |   92.86 |   88.92 |
 src/api            |   85.67 |    79.45 |   89.34 |   84.56 |
  endpoints.ts      |   88.34 |    82.12 |   91.23 |   87.45 |
  validators.ts     |   81.23 |    75.67 |   86.54 |   80.34 |
 src/utils          |   83.45 |    78.92 |   88.67 |   82.78 |
  helpers.ts        |   85.67 |    81.23 |   90.12 |   84.89 |
--------------------|---------|----------|---------|---------|

✅ All tests passed (45/45)
📊 Coverage: 87.34% statements, 82.15% branches
```

### No Tests Found - Generate Prompt

```text
User: /test
Claude: 🔍 Discovering test command...

⚠️  No tests found

Searched:
  ✗ README.md: No test commands
  ✗ package.json: No test script
  ✗ Test files: None found
  ✗ Test config: No pytest.ini, jest.config.js, etc.

💡 Options:
  1. Generate test suite: /test --create
  2. Manually add tests and configure test script

Project detected: JavaScript (Node.js)
Recommended: Jest or Vitest
```

### Generate Tests (--create)

```text
User: /test --create
Claude: 🔍 No tests found, generating test suite...

📦 Project type: JavaScript (Node.js)
🧪 Framework: Jest (recommended)

🤖 Deploying test-engineer to create test structure...

✅ Generated test suite:

Created files:
  ├── __tests__/
  │   ├── auth.test.js
  │   ├── api.test.js
  │   └── utils.test.js
  ├── jest.config.js
  └── package.json (updated with test script)

Added to package.json:
  "scripts": {
    "test": "jest"
  },
  "devDependencies": {
    "jest": "^29.7.0"
  }

📝 Installing dependencies...
✅ Dependencies installed

🧪 Running generated tests...

 PASS  __tests__/auth.test.js
 PASS  __tests__/api.test.js
 PASS  __tests__/utils.test.js

Test Suites: 3 passed, 3 total
Tests:       12 passed, 12 total

✅ Test suite generated and verified (12/12 tests passing)
📊 Initial coverage: 45.2% (baseline tests only)

💡 Next steps:
  - Add more test cases for edge cases
  - Improve coverage by testing error paths
  - Add integration and E2E tests
```

### Multiple Test Commands Found

```text
User: /test
Claude: 🔍 Discovering test command...

✅ Found multiple test commands:

1. npm run test:unit      (unit tests)
2. npm run test:integration (integration tests)
3. npm run test:e2e       (end-to-end tests)
4. npm test               (all tests)

Which would you like to run? [1-4, or 'all']: 4

🧪 Running: npm test

[... test output ...]
```

## Test Discovery Process

### Priority Order

1. **README.md** - Look for test sections and extract commands
2. **Package manager configs** - Check for test scripts
3. **Framework configs** - Detect from config files
4. **File patterns** - Infer from test file names
5. **Fallback to common patterns** - Try standard commands

### Language-Specific Detection

```yaml
JavaScript/TypeScript:
  configs: [package.json, jest.config.js, vitest.config.ts]
  commands: [npm test, yarn test, pnpm test]
  patterns: [*.test.js, *.spec.js, __tests__/]

Python:
  configs: [pytest.ini, pyproject.toml, setup.py, tox.ini]
  commands: [pytest, python -m pytest, tox]
  patterns: [test_*.py, *_test.py, tests/]

Go:
  configs: [go.mod]
  commands: [go test ./...]
  patterns: [*_test.go]

Rust:
  configs: [Cargo.toml]
  commands: [cargo test]
  patterns: [tests/]

Ruby:
  configs: [Gemfile, .rspec]
  commands: [bundle exec rspec, rake test]
  patterns: [*_spec.rb, spec/]

Java:
  configs: [pom.xml, build.gradle]
  commands: [mvn test, gradle test]
  patterns: [*Test.java, src/test/]
```

## Error Handling

### Missing Dependencies

```text
❌ Test framework not found

Error: Cannot find module 'jest'

💡 Install dependencies first:
  npm install
  # or
  yarn install
```

### Database/Environment Issues

```text
❌ Tests failed to start

Error: Database connection refused

💡 Check your test environment:
  - Ensure test database is running
  - Check environment variables
  - Verify test configuration
```

### No Test Command

```text
⚠️  Cannot determine how to run tests

Suggestions:
  1. Add test script to package.json
  2. Create pytest.ini or jest.config.js
  3. Run `/test --create` to generate tests
  4. Specify framework: /test --framework jest
```

## Implementation Strategy

### Direct Execution

Claude handles test discovery and execution directly:

- Reads configuration files
- Parses test commands
- Runs tests with appropriate environment
- Reports results clearly

### Single Agent Usage

Deploy test-engineer agent only when:

- No tests exist and --create flag used
- Generating comprehensive test structure
- Need to create framework configuration

**Decision criteria:** Use agent only for test generation, not for execution or fixing.

## Notes

- Streamlined design focuses on test execution, not orchestration
- No wave-based auto-remediation (tests should be fixed by developers)
- Fast execution: typically 10-30 seconds (depends on test suite)
- Trusts existing test frameworks and tooling
- Clear error reporting without auto-fix complexity
- Single test-engineer agent only for --create mode
- Reports failures for developer review and fixing
- Works with any language/framework through smart detection
- Coverage reporting integrated when requested
