---
name: testing-patterns
description: TDD/BDD patterns, fixture strategies, and coverage requirements for consistent test engineering.
user-invocable: false
metadata:
  category: workflow
---

# Testing Patterns Reference

## Test Pyramid

```text
        /  E2E  \         ~10% - Critical user journeys
       /----------\
      / Integration \     ~20% - Service boundaries, API contracts
     /----------------\
    /    Unit Tests     \  ~70% - Business logic, utilities, pure functions
   /--------------------\
```

### Coverage Targets

| Level | Target | Focus |
|-------|--------|-------|
| Unit | 80%+ line coverage | Pure functions, business logic, edge cases |
| Integration | Key paths covered | API contracts, database queries, external services |
| E2E | Critical journeys | Login, checkout, core workflows |
| Branch | 70%+ | Conditional logic, error paths |

## Naming Conventions

### Jest/Vitest (describe/it blocks)

```javascript
describe('AuthService', () => {
  describe('login', () => {
    it('should return a token for valid credentials', () => {});
    it('should throw UnauthorizedError for invalid password', () => {});
    it('should lock account after 5 failed attempts', () => {});
  });

  describe('refreshToken', () => {
    it('should issue new token when refresh token is valid', () => {});
    it('should reject expired refresh tokens', () => {});
  });
});
```

**Pattern:** `describe('[Unit]')` > `describe('[method/scenario]')` > `it('should [expected behavior] when [condition]')`

### Pytest

```python
class TestAuthService:
    def test_login_returns_token_for_valid_credentials(self):
        pass

    def test_login_raises_unauthorized_for_invalid_password(self):
        pass

    def test_login_locks_account_after_five_failed_attempts(self):
        pass

    def test_refresh_token_issues_new_token_when_valid(self):
        pass
```

**Pattern:** `test_[method]_[expected]_[condition]` using snake_case

### Go testing

```go
func TestAuthService_Login_ReturnsTokenForValidCredentials(t *testing.T) {}
func TestAuthService_Login_ReturnsErrorForInvalidPassword(t *testing.T) {}
func TestAuthService_RefreshToken_IssuesNewTokenWhenValid(t *testing.T) {}
```

**Pattern:** `Test[Unit]_[Method]_[Expected][Condition]` using PascalCase

## Fixture Patterns

### Factory Functions

```javascript
// Preferred: Factory functions with sensible defaults
function createUser(overrides = {}) {
  return {
    id: faker.string.uuid(),
    name: faker.person.fullName(),
    email: faker.internet.email(),
    role: 'user',
    createdAt: new Date(),
    ...overrides,
  };
}

// Usage
const admin = createUser({ role: 'admin' });
const user = createUser({ name: 'Test User' });
```

### Builder Pattern

```python
class UserBuilder:
    def __init__(self):
        self._data = {
            'name': 'Default User',
            'email': 'default@test.com',
            'role': 'user',
        }

    def with_role(self, role):
        self._data['role'] = role
        return self

    def with_email(self, email):
        self._data['email'] = email
        return self

    def build(self):
        return User(**self._data)

# Usage
admin = UserBuilder().with_role('admin').build()
```

### Test Data Management

```text
Principles:
- Each test creates its own data (no shared mutable state)
- Use factories over raw literals for maintainability
- Clean up after tests (database transactions, temp files)
- Avoid loading from external files when possible
- Use realistic but deterministic data (seeded faker)
```

## Framework-Specific Patterns

### Jest/Vitest

```javascript
// Setup and teardown
beforeAll(async () => { /* DB connection */ });
afterAll(async () => { /* DB disconnect */ });
beforeEach(() => { /* Reset mocks */ });
afterEach(() => { jest.restoreAllMocks(); });

// Mocking
jest.mock('./database');
const mockFn = jest.fn().mockResolvedValue({ id: 1 });

// Async testing
it('should fetch user', async () => {
  const user = await service.getUser(1);
  expect(user).toMatchObject({ id: 1, name: expect.any(String) });
});

// Snapshot testing (use sparingly)
it('should render component', () => {
  const { container } = render(<Component />);
  expect(container).toMatchSnapshot();
});
```

### Pytest

```python
# Fixtures with scope
@pytest.fixture(scope='session')
def db_connection():
    conn = create_connection()
    yield conn
    conn.close()

@pytest.fixture
def user(db_connection):
    user = create_user(db_connection)
    yield user
    delete_user(db_connection, user.id)

# Parametrize for multiple cases
@pytest.mark.parametrize('input,expected', [
    ('valid@email.com', True),
    ('invalid', False),
    ('', False),
])
def test_validate_email(input, expected):
    assert validate_email(input) == expected

# Mocking
def test_send_email(mocker):
    mock_smtp = mocker.patch('smtplib.SMTP')
    send_notification('user@test.com')
    mock_smtp.return_value.send_message.assert_called_once()
```

### Go testing

```go
// Table-driven tests
func TestValidateEmail(t *testing.T) {
    tests := []struct {
        name    string
        input   string
        want    bool
    }{
        {"valid email", "user@example.com", true},
        {"missing domain", "user@", false},
        {"empty string", "", false},
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            got := ValidateEmail(tt.input)
            if got != tt.want {
                t.Errorf("ValidateEmail(%q) = %v, want %v", tt.input, got, tt.want)
            }
        })
    }
}

// Test helpers
func setupTestDB(t *testing.T) *sql.DB {
    t.Helper()
    db, err := sql.Open("sqlite3", ":memory:")
    if err != nil {
        t.Fatal(err)
    }
    t.Cleanup(func() { db.Close() })
    return db
}
```

## Anti-Patterns to Avoid

### Testing Implementation Details

```javascript
// BAD: Testing internal state
it('should set _isLoading to true', () => {
  service.fetchData();
  expect(service._isLoading).toBe(true);
});

// GOOD: Testing observable behavior
it('should show loading indicator while fetching', () => {
  service.fetchData();
  expect(screen.getByRole('progressbar')).toBeVisible();
});
```

### Flaky Tests

```text
Common causes and fixes:
- Time-dependent: Use fixed timestamps or clock mocking
- Race conditions: Await async operations properly, avoid arbitrary sleeps
- Shared state: Isolate test data, reset between tests
- External dependencies: Mock external services
- Order-dependent: Each test must be independently runnable
```

### Over-Mocking

```javascript
// BAD: Mocking everything, testing nothing
it('should process order', () => {
  jest.mock('./database');
  jest.mock('./payment');
  jest.mock('./inventory');
  jest.mock('./notification');
  // At this point you're testing mock wiring, not logic
});

// GOOD: Mock boundaries, test logic
it('should calculate order total with discount', () => {
  const order = createOrder({ items: [item1, item2], discount: 0.1 });
  expect(calculateTotal(order)).toBe(90);
});
```

### Brittle Assertions

```python
# BAD: Asserting on exact output
assert response.json() == {"id": 1, "name": "Test", "created": "2025-01-01T00:00:00Z", ...}

# GOOD: Assert on what matters
assert response.status_code == 200
assert response.json()['name'] == 'Test'
assert 'id' in response.json()
```

## Test Organization

```text
project/
  src/
    auth/
      login.ts
  tests/
    unit/
      auth/
        login.test.ts        # Unit tests mirror src structure
    integration/
      auth/
        login.integration.ts  # Integration tests for auth flows
    e2e/
      login.e2e.ts            # End-to-end login journey
    fixtures/
      users.ts                # Shared factory functions
    helpers/
      setup.ts                # Test utilities and helpers
```
