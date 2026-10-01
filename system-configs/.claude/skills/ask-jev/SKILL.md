---
name: ask-jev
description: Rank candidate files by relevance before reading them. Use when the question is "where is X implemented", "which files handle Y", or "what touches Z" and the answer could be in more than about five files — run this first and read only the top few instead of opening or grepping dozens. Opt-in; skip it for a single known file or an exact symbol lookup that one grep settles.
argument-hint: '"<what you are looking for>" <paths or globs...>'
metadata:
  category: workflow
---

# /ask-jev

## Usage

```bash
~/.claude/skills/ask-jev/scripts/rank-files.sh "<query>" <paths | globs | directories...>
~/.claude/skills/ask-jev/scripts/rank-files.sh --top 8 "where is retry handled" src/ lib/**/*.ts
```

## Description

A cheap relevance pass over many files. Reading files to find out which ones matter is the expensive part
of "where is X / which files handle Y" questions: every file you open stays in context for the rest of the
session. This skill hands the question to Jev (a small, fast model) and gets back a ranked list, so you read
the three best candidates instead of thirty.

Use it when:

- the question is a "where / which files" one and the candidate set is a directory, a glob or a grep that
  returned many files;
- you would otherwise read more than about five files to find the right one.

Skip it when you already know the file, one exact-symbol grep answers the question, or the code is under a
work or Visa checkout (those paths are excluded from Jev by policy and are dropped automatically).

## How it works

1. **Prefilter, no model.** Directories recurse (skipping `.git`, `node_modules`, build output). Binary,
   oversized, secret-named (`.env*`, `*.pem`, `*credential*`, ...) and excluded-path files are dropped. The
   rest are scored by how many query keywords appear in the path and contents, and the best 60 are kept.
2. **Jev relevance.** Batches of at most 20 files go out as path plus first 40 lines, one boolean per file:
   "is this file likely to contain the answer, or be directly relevant?" The Jev client redacts secrets in
   what it sends and refuses an excluded cwd. At most three calls for a default run.
3. **Output**, best first, one line per file: `<probability><TAB><path>` (0.00 to 1.00).

## Expected Output

One line per file, a tab between the probability and the path, best first:

```text
0.94    src/retry/policy.ts
0.81    src/http/client.ts
0.07    docs/changelog.md
```

- Read the top files whose probability is high (roughly 0.5 and up) and ignore the tail. The ranking uses
  each file's first 40 lines, so a low score for a long file whose relevant code sits further down is
  possible: if the top results do not answer the question, widen the paths or fall back to Grep.
- A `-` in the probability column means Jev did not score that file; those files are in prefilter order
  (keyword matches first). This is the fail-open path: Jev unavailable, kill switch (`~/.claude/jev.off`),
  no API key, rule off, or a refused cwd. A one-line note goes to stderr and the exit code stays 0. Treat a
  `-` list as a keyword-ordered shortlist, not a relevance judgement.
- Exit 1 means no readable text file survived the prefilter; exit 2 is a usage error.

## Configuration

Rule `ask-jev-rank` in `~/.claude/hooks/jev/rules.d/skills.json`: `mode` (`off` returns the prefilter order
only; `shadow` and `enforce` both call Jev, because running this skill is itself the opt-in),
`max_files`, `batch_size` (never above 20), `head_lines`, `line_chars`, `max_file_kb`, `timeout_ms`. Every
run appends one line to `~/.claude/jev/decisions.jsonl` (counts only, never the query or file text).
