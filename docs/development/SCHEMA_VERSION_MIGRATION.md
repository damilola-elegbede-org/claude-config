# Schema Version Migration Strategy

## Overview

The `.tmp/` directory holds ephemeral JSON state files shared between skills
(e.g. `/review` → `/resolve-comments` → `/ship-it`). These files carry a
`schema_version` field so consumers can detect and handle breaking schema
changes safely.

This document defines the contract for schema versioning, the migration policy,
and the required validation behaviour for every skill that reads a `.tmp/` JSON
file.

---

## Scope — `.tmp/` JSON State Files

| File | Written by | Read by |
| --- | --- | --- |
| `.tmp/review-local.json` | `review/SKILL.md` | `resolve-comments/SKILL.md` |
| `.tmp/review-coderabbit.json` | `review/SKILL.md` | `resolve-comments/SKILL.md` |
| `.tmp/review-code.json` | `review/SKILL.md` | `review/SKILL.md` (merge step) |
| `.tmp/review-security.json` | `review/SKILL.md` | `review/SKILL.md` (merge step) |
| `.tmp/review-accessibility.json` | `review/SKILL.md` | `review/SKILL.md` (merge step) |
| `.tmp/coderabbit-ignored.json` | `resolve-comments/SKILL.md` | `pr/SKILL.md` |

All of these files **must** include `schema_version` at the top level.

---

## Schema Version Contract

### Current versions (all at `"1.0"`)

```text
review-local.json          → schema_version: "1.0"
review-coderabbit.json     → schema_version: "1.0"
review-code.json           → schema_version: "1.0"
review-security.json       → schema_version: "1.0"
review-accessibility.json  → schema_version: "1.0"
coderabbit-ignored.json    → schema_version: "1.0"
```

### Versioning Rules

- Versions use `"MAJOR.MINOR"` format (e.g. `"1.0"`, `"2.0"`).
- Any version change (major or minor) requires updating all readers in the same PR.
- Readers **must** use exact string equality (`schema_version != CURRENT_SCHEMA_VERSION`) — no semver parsing.

---

## Read-Time Validation — Required Pattern

Every skill that reads a `.tmp/` JSON state file **must** apply the following
validation logic immediately after reading:

```text
READ: .tmp/<file>.json
IF: file exists
  VALIDATE: schema_version field exists in JSON
  SET: CURRENT_SCHEMA_VERSION = "<expected version>"
  IF: schema_version is missing OR schema_version != CURRENT_SCHEMA_VERSION
    SET: backup_path = .tmp/<file>.backup-{timestamp}.json
    COPY: .tmp/<file>.json TO backup_path
    DELETE: .tmp/<file>.json
    OUTPUT: "⚠️ Schema version mismatch in <file>.json
             (found: {schema_version}, expected: {CURRENT_SCHEMA_VERSION}).
             Backed up to {backup_path} — starting fresh."
    TREAT AS: file missing (proceed as if no prior state)
```

**Key properties:**

- `schema_version` missing → treated as mismatch.
- Version mismatch uses exact string equality — no semver parsing.
- Mismatch → backup-and-skip; no data loss, no silent corruption.
- Backup files are never deleted automatically; humans clean them up.

---

## Migration Policy

### When MAJOR version changes are needed

1. Update the writer (the skill that writes the file) to emit the new version.
1. Update the reader (the skill that reads the file) to bump `CURRENT_SCHEMA_VERSION`.
1. Both changes **must land in the same PR**. Split PRs are not allowed — a
   reader without a matching writer would immediately create mismatches in
   existing environments.
1. Add a changelog entry to this document (see below).
1. No data migration scripts are needed — the backup-and-reinit pattern handles
   stale files gracefully.

### Why not migrate data forward?

These files are ephemeral: they are created per-branch, consumed once during a
review/ship cycle, and deleted after use. The cost of re-running `/review` is
low. Data migration would add complexity with no meaningful benefit.

---

## Current Implementation Status

### ✅ Covered by PR #175

- `coderabbit-ignored.json` — validation added to `pr/SKILL.md` (STEP 4,
  post-review acknowledgment path).

### ✅ Covered by PR #176

The following files now have `schema_version` validation on read, added in PR #176:

| File | Read location | Validation |
| --- | --- | --- |
| `.tmp/review-local.json` | `resolve-comments/SKILL.md` STEP 3 | Exact match check |
| `.tmp/review-coderabbit.json` | `resolve-comments/SKILL.md` STEP 2 | Exact match check |
| `.tmp/review-code.json` | `review/SKILL.md` merge step | Exact match check |
| `.tmp/review-security.json` | `review/SKILL.md` merge step | Exact match check |
| `.tmp/review-accessibility.json` | `review/SKILL.md` merge step | Exact match check |

All `.tmp/` JSON state files now have read-time `schema_version` validation.

---

## Recommendations

### Immediate — ✅ Done in PR #176

1. **✅ Validation added to `resolve-comments/SKILL.md`** when reading:
   - `.tmp/review-local.json` (STEP 3 / STEP 2 fetch path)
   - `.tmp/review-coderabbit.json` (STEP 2 fetch path)

2. **✅ Validation added to `review/SKILL.md`** when merging:
   - `.tmp/review-code.json`
   - `.tmp/review-security.json`
   - `.tmp/review-accessibility.json`
   Uses backup-and-skip pattern. On mismatch, the sub-file is skipped and
   a warning is emitted; the entire review is not aborted.

3. **No changes to `openclaw.json`** — that file is operator-owned and managed
   by the Cortex/OpenClaw boundary established in PR #147 (cortex repo). Schema
   versioning for `openclaw.json` is out of scope for this issue.

### Short-term (within next sprint)

1. Add a CI check (`scripts/validate-schema-versions.sh`) that:
   - Asserts every `.tmp/` file definition in a SKILL.md includes `schema_version`
   - Asserts every READ of a `.tmp/` file in a SKILL.md has a corresponding
     `VALIDATE: schema_version` step
   - Includes **test discovery**: the script should auto-discover all `.tmp/` file
     references in SKILL.md files without a hardcoded list
   - Includes **test creation** guidance: new `.tmp/` file writers must include a
     corresponding test assertion in the CI check
   This prevents future regressions without requiring manual review of all skill files.

---

## Backwards Compatibility Guarantee

The current `"1.0"` schema is stable. No MAJOR version bump is planned. All
`.tmp/` files written by the current skill set will continue to be accepted by
all current readers, including after PR #175 merges.

Existing `.tmp/` files that **pre-date** the `schema_version` field (written
before PR #175) will trigger the mismatch path and be backed up. This is the
correct safe behaviour — it prevents silent corruption.

---

## Changelog

| Date       | Version | Change                                     | PR        |
| ---------- | ------- | ------------------------------------------ | --------- |
| 2026-03-05 | `1.0`   | Initial schema for all `.tmp/` state files | #175      |
| 2026-03-07 | `1.0`   | Document added; per-file schema_version validations implemented for all .tmp/ reads | #176 |

---

## References

- Issue: [#147 — Missing schema version migration strategy](https://github.com/damilola-elegbede-org/claude-config/issues/147)
- PR: [#175 — fix(resolve-comments): add schema_version validation](https://github.com/damilola-elegbede-org/claude-config/pull/175)
- `system-configs/.claude/skills/resolve-comments/SKILL.md` — Ignored Issues Schema section
- `system-configs/.claude/skills/review/SKILL.md` — review output schemas
- `system-configs/.claude/skills/pr/SKILL.md` — coderabbit-ignored.json consumer
