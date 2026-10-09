Review focus. Report correctness problems; formatting and lint are enforced elsewhere. The classes
below account for most review findings in these repositories, largest first, so look for them
before anything else. Keep the usual P0-P3 priorities: this list says where to look, not how
severe a finding is.

1. Edge cases in parsing, matching and selection: quoted or prefixed arguments, option operands,
   empty or malformed input, and which records a filter keeps or drops.
2. Fail-open paths: a check that passes when its input is missing, malformed or unavailable; an
   error swallowed by `|| true`, an errexit interaction, or a handler that returns success; a gate
   that should fail closed.
3. State across repeated or concurrent runs: retries, idempotency, deduplication keys, partial
   writes, temporary files left behind, stale caches, races, and reused process IDs.
4. Wiring the change needs outside the diff: a new test, job, agent or skill that must also be
   registered in a workflow list, manifest, registry, inventory, count or canonical source.
5. Security and identity: credentials, sender authentication, writes that bypass a required
   identity wrapper, and untrusted input that reaches a shell, a path or a prompt.
6. Environment: relative or PATH-dependent binaries in cron or launchd jobs, and assumptions about
   the working directory, repository root, worktree, operating system or shell.
7. Bounds: unpaginated API reads, missing timeouts, and unbounded buffers, files or arguments.
8. Test evidence: a new or changed test that would still pass if the behavior it guards broke.
9. Documentation, prompts and instructions that the change makes stale or contradicts.

End every finding body with one line, `Files the fix must change: <repo-relative paths>`, naming
every file the fix touches, including registries and docs outside the diff. The fix is applied
automatically and may only edit the files a finding names.
