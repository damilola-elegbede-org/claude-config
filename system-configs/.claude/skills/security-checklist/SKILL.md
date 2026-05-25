---
name: security-checklist
description: OWASP Top 10 quick reference and common vulnerability patterns for security-focused code review and auditing.
user-invocable: false
metadata:
  category: workflow
---

# Security Checklist Reference

## OWASP Top 10 Quick Reference

### A01: Broken Access Control

**What to look for:** Missing authorization checks, IDOR, path traversal, CORS misconfig.

```javascript
// BAD: No authorization check
app.get('/api/users/:id', (req, res) => {
  return db.getUser(req.params.id);
});

// GOOD: Verify ownership
app.get('/api/users/:id', authorize, (req, res) => {
  if (req.user.id !== req.params.id && !req.user.isAdmin) {
    return res.status(403).json({ error: 'Forbidden' });
  }
  return db.getUser(req.params.id);
});
```

```python
# BAD: Direct object reference without check
@app.route('/documents/<doc_id>')
def get_document(doc_id):
    return Document.query.get(doc_id)

# GOOD: Verify access
@app.route('/documents/<doc_id>')
@login_required
def get_document(doc_id):
    doc = Document.query.get_or_404(doc_id)
    if doc.owner_id != current_user.id:
        abort(403)
    return doc
```

**Grep patterns:**

```text
# Missing auth middleware
app\.(get|post|put|delete)\([^)]+\)\s*=>
router\.(get|post|put|delete)\([^)]+,\s*(req|async)

# Path traversal risk
\.\.\/|\.\.\\|path\.join.*req\.(params|query|body)
```

### A02: Cryptographic Failures

**What to look for:** Hardcoded secrets, weak hashing, plaintext sensitive data, insecure TLS.

```python
# BAD: Hardcoded secret
SECRET_KEY = "my-secret-key-123"
password_hash = hashlib.md5(password.encode()).hexdigest()

# GOOD: Environment variable, strong hashing
SECRET_KEY = os.environ['SECRET_KEY']
password_hash = bcrypt.hashpw(password.encode(), bcrypt.gensalt())
```

**Grep patterns:**

```text
# Hardcoded secrets
(password|secret|key|token|api_key)\s*=\s*["'][^"']+["']
# Weak hashing
(md5|sha1)\(
# Insecure protocol
http:\/\/(?!localhost|127\.0\.0\.1)
```

### A03: Injection

**What to look for:** SQL injection, command injection, LDAP injection, template injection.

```javascript
// BAD: SQL injection
const query = `SELECT * FROM users WHERE id = ${req.params.id}`;

// GOOD: Parameterized query
const query = 'SELECT * FROM users WHERE id = $1';
const result = await db.query(query, [req.params.id]);
```

```python
# BAD: Command injection
os.system(f"ping {user_input}")

# GOOD: Use subprocess with list args
subprocess.run(["ping", "-c", "4", validated_host], check=True)
```

```go
// BAD: SQL injection
query := fmt.Sprintf("SELECT * FROM users WHERE name = '%s'", name)

// GOOD: Parameterized
row := db.QueryRow("SELECT * FROM users WHERE name = $1", name)
```

**Grep patterns:**

```text
# String interpolation in queries
(SELECT|INSERT|UPDATE|DELETE).*(\$\{|%s|\.format|f")
# Command injection
os\.system|subprocess\.call.*shell=True|exec\(.*\+
```

### A04: Insecure Design

**What to look for:** Missing rate limiting, no abuse prevention, lack of input validation at design level.

```javascript
// BAD: No rate limiting on auth endpoint
app.post('/login', handleLogin);

// GOOD: Rate limited
app.post('/login', rateLimiter({ max: 5, window: '15m' }), handleLogin);
```

**Grep patterns:**

```text
# Auth endpoints without rate limiting
\/(login|auth|register|reset-password|forgot).*(?!rateLimit)
```

### A05: Security Misconfiguration

**What to look for:** Default credentials, verbose errors in production, unnecessary features enabled.

```javascript
// BAD: Verbose errors in production
app.use((err, req, res, next) => {
  res.status(500).json({ error: err.stack });
});

// GOOD: Generic error in production
app.use((err, req, res, next) => {
  logger.error(err);
  res.status(500).json({ error: { code: 'INTERNAL_ERROR', message: 'An error occurred' } });
});
```

**Grep patterns:**

```text
# Debug mode in production
DEBUG\s*=\s*[Tt]rue|debug:\s*true
# Verbose error exposure
err\.stack|error\.stack|traceback
# Missing security headers
(?!helmet|csp|x-frame|x-content-type)
```

### A06: Vulnerable and Outdated Components

**What to look for:** Known CVEs in dependencies, unpinned versions, abandoned packages.

**Grep patterns:**

```text
# Unpinned dependencies
"[^"]+"\s*:\s*"\*"|"latest"|">=
# Known vulnerable packages (check against advisories)
# Run: npm audit, pip-audit, govulncheck
```

### A07: Identification and Authentication Failures

**What to look for:** Weak passwords allowed, missing MFA, session fixation, credential stuffing.

```python
# BAD: No password strength check
def register(username, password):
    create_user(username, hash_password(password))

# GOOD: Validate password strength
def register(username, password):
    if len(password) < 12 or not has_complexity(password):
        raise ValueError("Password does not meet requirements")
    create_user(username, hash_password(password))
```

**Grep patterns:**

```text
# Weak session config
session.*secure\s*[:=]\s*false|httpOnly\s*[:=]\s*false
# Missing password validation
password.*len.*<\s*[0-8]\b
```

### A08: Software and Data Integrity Failures

**What to look for:** Deserialization of untrusted data, missing integrity checks, insecure CI/CD.

```python
# BAD: Deserializing untrusted data
data = pickle.loads(user_input)
data = yaml.load(user_input)

# GOOD: Safe deserialization
data = json.loads(user_input)
data = yaml.safe_load(user_input)
```

**Grep patterns:**

```text
# Unsafe deserialization
pickle\.loads|yaml\.load\((?!.*safe)|eval\(|unserialize\(
# Missing integrity verification
curl.*\|\s*(bash|sh)|wget.*\|\s*(bash|sh)
```

### A09: Security Logging and Monitoring Failures

**What to look for:** Missing auth event logging, no alerting, sensitive data in logs.

```javascript
// BAD: Logging sensitive data
logger.info(`User login: ${username}, password: ${password}`);

// GOOD: Log events without sensitive data
logger.info(`Login attempt`, { username, ip: req.ip, success: true });
```

**Grep patterns:**

```text
# Sensitive data in logs
log.*(password|token|secret|key|credit.?card|ssn)
# Missing audit logging on sensitive operations
(delete|update|admin).*(?!log|audit)
```

### A10: Server-Side Request Forgery (SSRF)

**What to look for:** Unvalidated URLs from user input, internal network access, cloud metadata access.

```python
# BAD: SSRF via user-controlled URL
response = requests.get(user_provided_url)

# GOOD: Validate URL against allowlist
parsed = urlparse(user_provided_url)
if parsed.hostname not in ALLOWED_HOSTS:
    raise ValueError("URL not in allowlist")
if ipaddress.ip_address(socket.gethostbyname(parsed.hostname)).is_private:
    raise ValueError("Internal addresses not allowed")
response = requests.get(user_provided_url)
```

**Grep patterns:**

```text
# User-controlled URLs in requests
requests\.get\(.*req\.|fetch\(.*req\.|http\.Get\(.*req\.
# Cloud metadata access
169\.254\.169\.254|metadata\.google|metadata\.aws
```

## Quick Audit Checklist

- [ ] All endpoints have appropriate authorization checks
- [ ] No hardcoded secrets or credentials in source code
- [ ] All database queries use parameterized statements
- [ ] User input is validated and sanitized at system boundaries
- [ ] Error messages do not leak internal details in production
- [ ] Dependencies are up-to-date and free of known CVEs
- [ ] Authentication enforces strong password policies
- [ ] Deserialization only uses safe methods
- [ ] Security events are logged without sensitive data
- [ ] External URL requests validate against allowlists
