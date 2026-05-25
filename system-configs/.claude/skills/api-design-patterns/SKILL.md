---
name: api-design-patterns
description: REST and GraphQL API design conventions including versioning, error handling, and response formats.
user-invocable: false
metadata:
  category: framework
---

# API Design Patterns Reference

## REST Conventions

### Resource Naming

- Use **plural nouns** for collections: `/users`, `/orders`, `/products`
- Use **kebab-case** for multi-word resources: `/order-items`, `/user-profiles`
- Nest for relationships: `/users/{id}/orders`
- Limit nesting to 2 levels: `/users/{id}/orders` (not `/users/{id}/orders/{id}/items/{id}/details`)

### HTTP Methods

| Method | Purpose | Idempotent | Example |
|--------|---------|------------|---------|
| `GET` | Retrieve resource(s) | Yes | `GET /users/123` |
| `POST` | Create resource | No | `POST /users` |
| `PUT` | Full replacement | Yes | `PUT /users/123` |
| `PATCH` | Partial update | No | `PATCH /users/123` |
| `DELETE` | Remove resource | Yes | `DELETE /users/123` |

### Status Codes

| Code | Meaning | Use When |
|------|---------|----------|
| `200` | OK | Successful GET, PUT, PATCH, DELETE |
| `201` | Created | Successful POST creating a resource |
| `204` | No Content | Successful DELETE with no body |
| `400` | Bad Request | Invalid request body or parameters |
| `401` | Unauthorized | Missing or invalid authentication |
| `403` | Forbidden | Authenticated but insufficient permissions |
| `404` | Not Found | Resource does not exist |
| `409` | Conflict | Resource state conflict (duplicate, version) |
| `422` | Unprocessable Entity | Valid syntax but semantic errors |
| `429` | Too Many Requests | Rate limit exceeded |
| `500` | Internal Server Error | Unexpected server failure |

### Pagination

```json
GET /users?page=2&per_page=25

{
  "data": [...],
  "pagination": {
    "page": 2,
    "per_page": 25,
    "total": 150,
    "total_pages": 6
  }
}
```

Cursor-based pagination for large datasets:

```json
GET /events?cursor=abc123&limit=50

{
  "data": [...],
  "pagination": {
    "next_cursor": "def456",
    "has_more": true
  }
}
```

### Filtering and Sorting

```text
GET /users?status=active&role=admin          # Filtering
GET /users?sort=created_at&order=desc        # Sorting
GET /users?fields=id,name,email              # Field selection
GET /users?search=john                       # Search
```

## Error Response Format

### Standard Error Structure

```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "Request validation failed",
    "details": [
      {
        "field": "email",
        "message": "Must be a valid email address",
        "value": "not-an-email"
      },
      {
        "field": "age",
        "message": "Must be at least 18",
        "value": 15
      }
    ]
  }
}
```

### Error Code Convention

```text
AUTH_REQUIRED          - 401: Authentication needed
AUTH_INVALID           - 401: Invalid credentials
FORBIDDEN              - 403: Insufficient permissions
NOT_FOUND              - 404: Resource not found
VALIDATION_ERROR       - 422: Input validation failed
RATE_LIMITED           - 429: Too many requests
CONFLICT               - 409: State conflict
INTERNAL_ERROR         - 500: Unexpected server error
```

## Versioning Strategies

### URL Path Versioning (Recommended)

```text
GET /v1/users
GET /v2/users
```

- Clear and explicit
- Easy to route at load balancer level
- Simplest to document and consume

### Header-Based Versioning

```text
GET /users
Accept: application/vnd.myapi.v2+json
```

- Cleaner URLs
- More complex to implement and test
- Use when URL versioning is not feasible

### Versioning Rules

- Never break existing versions without deprecation notice
- Support at least N-1 versions concurrently
- Use sunset headers for deprecation: `Sunset: Sat, 01 Jan 2028 00:00:00 GMT`
- Document breaking changes in changelogs

## GraphQL Conventions

### Query Naming

```text
# Queries: noun-based, camelCase
query GetUser($id: ID!) {
  user(id: $id) {
    id
    name
    email
  }
}

query ListUsers($filter: UserFilter, $pagination: PaginationInput) {
  users(filter: $filter, pagination: $pagination) {
    nodes {
      id
      name
    }
    pageInfo {
      hasNextPage
      endCursor
    }
  }
}
```

### Mutation Naming

```text
# Mutations: verb + noun, camelCase
mutation CreateUser($input: CreateUserInput!) {
  createUser(input: $input) {
    user {
      id
      name
    }
    errors {
      field
      message
    }
  }
}

mutation UpdateUserProfile($id: ID!, $input: UpdateProfileInput!) {
  updateUserProfile(id: $id, input: $input) {
    user { id name }
    errors { field message }
  }
}
```

### Input Types

```text
input CreateUserInput {
  name: String!
  email: String!
  role: UserRole = USER
}

input UserFilter {
  status: UserStatus
  role: UserRole
  search: String
}

input PaginationInput {
  first: Int
  after: String
}
```

### Error Handling

```json
{
  "data": {
    "createUser": {
      "user": null,
      "errors": [
        { "field": "email", "message": "Email already registered" }
      ]
    }
  }
}
```

Return errors in the response payload for expected failures; use GraphQL errors array for unexpected failures.

## Authentication Patterns

### Bearer Token (JWT)

```text
Authorization: Bearer eyJhbGciOiJIUzI1NiIs...
```

- Short-lived access tokens (15-60 minutes)
- Refresh tokens for renewal (7-30 days)
- Include minimal claims (user ID, role)

### API Keys

```text
X-API-Key: sk_live_EXAMPLE_KEY_REPLACE_ME
```

- Prefix with environment: `sk_live_`, `sk_test_`
- Hash before storage, never log full key
- Support key rotation with grace period

### OAuth2 Flows

| Flow | Use Case |
|------|----------|
| Authorization Code | Server-side web apps |
| Authorization Code + PKCE | SPAs, mobile apps |
| Client Credentials | Service-to-service |
| Device Code | CLI tools, smart devices |

## Rate Limiting Headers

```text
X-RateLimit-Limit: 100          # Requests allowed per window
X-RateLimit-Remaining: 45       # Requests remaining
X-RateLimit-Reset: 1672531200   # Unix timestamp when window resets
Retry-After: 30                 # Seconds to wait (on 429 response)
```

### Rate Limit Strategy

- Per-endpoint limits for write operations
- Global limits for read operations
- Higher limits for authenticated requests
- Exponential backoff guidance in documentation
