# Jev operations

How the Jev (typesafe-ai/jev) layer is wired, switched off, read and measured. Source of truth for the
code is `system-configs/.claude/hooks/jev/` (client, registry, context and rules hooks) and
`system-configs/.claude/hooks/jev-gate*.sh` (the decision gates).

## One registry, one reader

Every hook asks the same question ("what mode, threshold and scope does rule X have?") of one merged
registry. Layers, later wins (objects deep-merge key by key, arrays and scalars are replaced):

1. `hooks/jev/gate-questions.json` - the questions: per-gate label, instructions, criteria, expected
   risk classes and scopes, the shared choice questions, the approval-detector and MCP-classifier prompts
2. `hooks/jev/rules.d/*.json` - modes, thresholds, scopes, tuning knobs (lexical file order)
3. `hooks/jev/jev-rules.json` - your overrides, always last

A rule that no layer registers is OFF. A rule's `mode` is a string (`off`, `shadow`, `enforce`) or an
object keyed by session type, for example `{"interactive": "enforce", "bgjob": "shadow"}`. The reader
resolves an object to the current session's string (`fleet` when a fleet agent slug is set, `bgjob` when
`CLAUDE_JOB_DIR` is set, else `interactive`; a missing key falls back to `default`, then `off`), so hooks
always see a plain mode. `JEV_REG_CTX` overrides the session type (tests). `scope` still decides whether
a rule runs at all in a session type. `exempt_agents` (default `clara`) is read from the same
registry by every hook. `JEV_RULES_FILE` (alias `JEV_RULES`) replaces all layers with one file (tests).

The reader exists twice because the hooks are bash and the client is node: `hooks/jev/registry.sh`
(`jev_reg_json`, `jev_reg_value`, `jev_reg_rule`, `jev_reg_exempt`) and `rulesRegistry()` in
`hooks/jev/client.mjs`. `tests/hooks/test_jev_registry.sh` runs both on the same fixtures and fails if
they disagree. `node hooks/jev/client.mjs --registry` prints the merged registry.

Regex rules stay where they were: `hooks/gate-rules.json` (patterns, lanes, messages) is data that
`gate.sh` evaluates; a registry entry with the same rule id overrides its mode (`off`, `shadow`,
`enforce`), and a registry `exempt_agents` list replaces the one shipped in `gate-rules.json`.

## Kill switches

Two files in `~/.claude`. Only a regular file counts: a directory or a symlink with that name does
nothing, so an agent cannot disable the gates with `mkdir`.

| File       | Effect                                                                                                                                                         |
| ---------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gate.off` | Master switch. Every decision gate stands down: the regex gate (`gate.sh`) and the Jev gates (`jev-gate.sh`, `jev-ask-channel.sh`).                            |
| `jev.off`  | Jev stops answering: the client exits 3 for every caller. Safety gates fall back to their regex verdict (`gate.sh` keeps enforcing); quality hooks do nothing. |

Precedence: independent files, and `gate.off` wins for gates (a gate behind `gate.off` never runs
whatever `jev.off` says). Both present means no decision gate runs and no Jev call is made. To stop only
the Jev spend, `touch ~/.claude/jev.off`. To stop all blocking, `touch ~/.claude/gate.off`. `G10-tamper` and `G10-file` gate
creating or editing either file from a tool call.

## One decision log

`~/.claude/jev/decisions.jsonl` (mode 0600, rotated monthly by the client), one line per decision:

```text
{ts, gate, mode, answers, confidence, model, latencyMs, outcome, src, origin, session_id, entrypoint, ...extra}
```

`origin` is `live` unless `JEV_ORIGIN` says otherwise: the test suites set `test`, the replay sets
`replay`, the nightly audit sets `audit`. `session_id` and `entrypoint` come from the
`CLAUDE_CODE_SESSION_ID` and `CLAUDE_CODE_ENTRYPOINT` variables Claude Code exports to hooks (null when
absent). Gate rows also carry `action`: the redacted display string of the command or path, at most about
200 characters, never file contents.

`gate` is the rule id, `mode` is `off|shadow|enforce` (`regex` for `gate.sh`), `answers` the Jev answers
(never the prompt, command or file text), `confidence` the probability of the first answer, `outcome`
what the hook did, `src` the writer (`client`, `hook:gate.sh`, `hook:jev-gate`, `hook:ctx`,
`hook:rules-events`). The client writes one line per Jev call and each hook one line per verdict, so one
tool call can produce a client line and a hook line; join on `ts` and `gate` or filter on `src`.

The older logs are still written for one release as aliases and will be removed after that:
`~/.claude/jev-shadow.jsonl`, `~/.claude/jev-gates.jsonl`, `~/.claude/jev/rules-events.jsonl`,
`~/.claude/gate-log.jsonl`. Read `decisions.jsonl` instead.

```text
# what did the gates decide today?
jq -r 'select(.gate | startswith("G")) | [.ts, .gate, .mode, .outcome] | @tsv' ~/.claude/jev/decisions.jsonl
```

## Replay and the regression guard

`scripts/jev-replay.py` replays the 169 labelled examples in `tests/fixtures/jev-replay-labels.jsonl`
through the same request builder the gates use and reports per-rule precision and recall. The recorded
answers, thresholds and accepted block rates live in `tests/fixtures/jev-replay-results.json`.

| Command                                                                       | Calls       | What it does                                                                                                                                                                                                                                                                                    |
| ----------------------------------------------------------------------------- | ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `python3 scripts/jev-replay.py --check`                                       | none        | CI guard. Fails when the questions or labels changed without a fresh live run, when `rules.d/gates.json` thresholds differ from the recorded ones, or when re-scoring the recorded answers at the current thresholds moves any rule's block rate more than 5 points from the accepted baseline. |
| `python3 scripts/jev-replay.py --rescore`                                     | none        | Re-scores the recorded answers at the current thresholds and rewrites the results file. The accepted baseline is kept, so cumulative drift stays visible.                                                                                                                                       |
| `python3 scripts/jev-replay.py --backend inline --no-history --write-results` | at most 200 | Live run; records answers and accepts the current thresholds as the new baseline. Key from the `export VERCEL_AI_GATEWAY_TOKEN=` line in `~/.zshrc`. Run it after a question change, and whenever `--check` says the baseline needs confirming.                                                 |

`tests/hooks/test_jev_replay_check.sh` (part of `tests/test.sh`) proves the guard on temp copies: a
threshold or question edit without an updated results file fails, `--rescore` fixes a small threshold
change, and a change that moves a block rate more than 5 points fails.

### Suggested monthly live replay (NOT installed)

Model or gateway behaviour can drift without any change in this repo. A monthly live replay catches that.
This is a suggestion only; nothing in this repo installs it. It deliberately omits `--write-results`: it
produces a report to read, and a human decides whether to accept a new baseline.

```text
# crontab -e   (monthly, 06:17 on the 1st; about 100 Jev calls)
17 6 1 * * cd "$HOME/repos/claude-config" && python3 scripts/jev-replay.py --backend inline --no-history --max-calls 200 --ai-dir "$HOME/.claude/hooks/jev" --cache "$HOME/.tmp/jev-replay-cache.jsonl" --out "$HOME/.tmp/reports/jev-replay-$(date +\%F).md" >> "$HOME/.tmp/reports/jev-replay-cron.log" 2>&1
```

Untested as a cron entry: the inline backend reads the key from `~/.zshrc` itself, but this was not run
under cron. Compare the new report's per-rule precision and recall with the committed results file; if a
rule degraded, re-run with `--write-results` only after reviewing it.

## Blocks, approvals and the deny trail

What a block tells the session depends on where it runs:

| Session | On a block | Approval |
| --- | --- | --- |
| interactive | ask D via AskUserQuestion, then retry once if D approves exactly this action | yes |
| bgjob (`CLAUDE_JOB_DIR` set, no fleet slug, not a subagent) | same as interactive; if D does not answer, end the report with `needs input:` naming the action | yes |
| fleet agent or subagent (`agent_id` in the hook input) | end the report with `needs input:` | none |

A job-session approval of a regex checkpoint follows the interactive path (`gate.sh approve <hash>`,
bound to the checkpoint code in an answered AskUserQuestion). A job-session approval of a Jev gate needs
three things: the last deny in that session was for this exact action, D's last turn is an AskUserQuestion
answer stamped at or after that deny, and the approval detector says yes. Every approval is one-shot.

Every enforced deny from either gate writes `~/.claude/jev-state/last-deny/<session_id>.json`
(`{ts, epoch, src, tool, rule, norm}`, mode 0600; `norm` is the whitespace-collapsed, redacted action,
at most 500 characters). On each later Bash, Write or Edit call, `jev-gate.sh` compares the action with
it: a different action of the same tool within 600 seconds with token similarity of 0.5 or more logs a
`retry-after-deny` row (gate `bypass-detector`), and the shadow rule `retry-classifier` asks Jev whether it
is the same action, a safer variant or unrelated (`retry_kind`). These rows never deny.

## Gate behaviour worth knowing

- `G1-rm` resolves standalone `NAME=literal` assignments earlier in the same command and a leading
  `cd <scratch dir> &&` before matching, so deletes inside the job temp folder or `.tmp/` pass when reached
  through a variable or a `cd`. Anything else (command substitution, `eval`, loop or `read` variables, a
  non-scratch `cd`) is matched as written.
- Command-position regex rules treat the body of a heredoc fed to an interpreter (python, node, ...) as
  data. Heredocs fed to a shell are still code, and `G1-interp` and the SQL rules still read interpreter
  bodies.
- `G1-irreversible-local` gets `deleted_paths`, `created_in_command` and `script_calls` in its state, so
  deleting files the same command created is not scored as irreversible loss.
- `G15-untrusted-origin` is the `origin` choice question (`user_directed`, `tool_suggested`, `injected`)
  and fires on P(injected). It is asked only when untrusted content arrived after D's last turn.

## Context and rules hooks in job sessions

- `A3-bash-trim` leaves the output whole when no chunk reaches its threshold (`best_fallback: false`,
  logged as `keep-full` with why `no-relevant-chunk`). `A1` and `A2` still keep their best chunk.
- `A7-memory-inject` and `A8-skill-picker` run in job sessions in shadow, for the first user prompt only
  (marker `~/.claude/jev-cache/state/<session_id>.first`).
- `A6-agent-router` adds a hint pointing at the `/ask-jev` ranking script when a delegation is a file
  search (`Explore`, or a prompt about locating files).
- In job sessions the `executive-lint` regex checks enforce: meta line (`executive-lint-meta`), bare Linear IDs
  (`executive-lint-bare-id`) and the length cap block once per Stop; the tag check blocks only replies longer than
  `bgjob_tag_min_chars` (500). Shorter untagged replies log `executive-lint-tagshort` / `shadow-would-block`
  (set `bgjob_tag_min_chars` to 0 to enforce the tag on every reply). Every block also prints a `Jev:` systemMessage
  to D. The Jev model checks (`executive-tag-correctness`, `-unsourced-claims`, `-scope-creep`) stay shadow in jobs.
- The `workflow-*` helpers (commit and branch type, mixed commit, review depth, CI and verify failure
  class, Linear presort, click target) run in job sessions in shadow; the skills always run their helper
  and act on the answer only when the mode is `enforce`.
- At session start, `session-check.sh` prints one line when deployed hook files differ from the
  claude-config clone's `origin/main` (it never fetches, so it is only as fresh as the last fetch there).
  `JEV_DRIFT_REPO` and `JEV_DRIFT_HOOKS` override the paths.

## The opt-in /ask-jev skill

`skills/ask-jev/scripts/rank-files.sh "<query>" <paths or globs...>` ranks candidate files for "where is X /
which files handle Y" questions so the model reads the top few instead of dozens. A keyword prefilter
(no model) keeps at most 60 files, then Jev scores them in batches of at most 20 (path plus first 40
lines, one boolean per file; the client redacts and refuses an excluded cwd). Output is one
`<probability><TAB><path>` line per file, best first. It fails open: with Jev unavailable it prints the
prefilter order with `-` as the probability and exits 0. Rule `ask-jev-rank` lives in
`hooks/jev/rules.d/skills.json`; it ships `enforce` because invoking the skill is itself the opt-in and the
output is advisory. Tests: `tests/hooks/test_ask_jev.sh`.

## Hook `if` prefilters

Claude Code's handler-level `if` field is supported (probe `scripts/jev-hook-probes.sh e`, run live on
CLI 2.1.286). It takes one permission rule per handler (`Bash(git *)`, `Write(**/memory/*.md)`) and only
applies to tool events. What the probe showed:

- A handler with a non-matching `if` is not spawned at all.
- `Bash(git *)` matches `git ...` anywhere in a compound command (after `&&`, `;` and `|`) and after
  environment assignments (`FOO=1 git ...`). Commands the CLI cannot parse safely, such as `(git ...)` and
  `echo $(git ...)`, ran every `if` handler, so an unparseable command fails open (the hook runs).
- Redirections are invisible to the glob: `Bash(*>*)` did not match `echo y > file`.
- Two handlers with the same command and different `if` rules both run (no cross-handler dedupe).
- Path rules for Edit and Write work (`Edit(**/package.json)`, `Write(**/memory/*.md)`).

Applied only where the script ignores everything the rule filters out, so no hook is skipped for a call it
would have acted on:

| Handler                                                | `if`                    |
| ------------------------------------------------------ | ----------------------- |
| `pr-draft-guard.sh`                                    | `Bash(gh *pr create*)`  |
| `memory-dup-guard.sh`                                  | `Write(**/memory/*.md)` |
| bare-git identity guard (`infra/scripts/git-agent.sh`) | `Bash(git *)`           |

Deliberately left without one: `gate.sh` and `jev-gate.sh` (their rules match on redirects and on
payload content, which a glob cannot see), the destructive-git guard (its `--no-verify` arm is not
git-prefixed and an `if` takes one rule), the file-extension guards (several extensions, one rule), and the
Jev context hooks (`a1`..`a8`, `retry-counter`: they act on every call of their matcher, so there is
nothing for a prefilter to skip). Every handler now has an explicit `timeout`.

## Daily summary

`python3 scripts/jev-daily-summary.py [--date YYYY-MM-DD] [--log PATH] [--out DIR] [--stdout]` writes one
compact Markdown report for a day of `decisions.jsonl`. The day is an America/Denver calendar day
(default: yesterday); the file is `~/.tmp/reports/jev-daily-<date>.md`. It reads only the decision log and
makes no Jev calls.

| Section             | Content                                                                                                             |
| ------------------- | ------------------------------------------------------------------------------------------------------------------- |
| Jev calls           | Client rows (`src: client`): count, unavailable count and percent, p50 and p95 `wall_ms` (nearest rank), total cost |
| Blocks              | `deny` and `hit-enforce` rows with time, rule, origin and a readable action (`action`, else `target`, else the sha) |
| Would-deny (shadow) | `would-deny-shadow` rows per rule                                                                                   |
| Bypasses            | `retry-after-deny` rows per rule                                                                                    |
| By origin           | The same counts split by `origin` (`live`, `test`, `replay`); rows without an `origin` count as `unknown`           |

A Jev gate logs a `hit-enforce` row and a `deny` row for one blocked call; the report counts that call
once. A re-run keeps the nightly audit section already in the file.

## Nightly audit

`python3 scripts/jev-nightly-audit.py [--date YYYY-MM-DD] [--projects DIR] [--dry-run] [--max-calls N]
[--threshold P] [--log PATH] [--out DIR] [--stdout]` looks for risky actions that no gate blocked.

1. Scans `~/.claude/projects/*/*.jsonl` for assistant events whose own timestamp falls on the day.
2. Keeps only the Bash `command` string and the Write, Edit and MultiEdit `file_path` of `tool_use`
   blocks. Nothing else is read.
3. Skips an action whose cwd, path or a path named inside its command falls under `exclude_paths` in
   `jev-config.json` (same prefix rules as the client). If the config cannot be read the audit refuses to
   run, because the exclusion list is unknown.
4. Redacts secrets with the patterns of `jev_redact` in `hooks/jev-gate-lib.sh`, trims long commands
   (head and tail), and drops duplicates.
5. Asks Jev the shared `risk_class` choice question (`choice_questions` in `gate-questions.json`) once
   per distinct action through `~/.claude/hooks/jev/jev-ask`, rule `audit/risk-class`, with
   `JEV_ORIGIN=audit` so the decision log tells these calls apart. A choice call takes one action, so
   there is no batching; `--max-calls` (default 300) bounds the spend and the rest is listed as not
   scored. Five unavailable calls in a row stop the run.
6. Reports actions that score at least `--threshold` (default 0.8) on `data_loss`, `irreversible`,
   `prod_system`, `outward_comms` or `spend` and that no gate blocked. An action counts as blocked when a
   `deny` or `hit-enforce` row of the day carries the same action text, or, for rows without one, the same
   `session_id` within 30 seconds.
7. Replaces the `## Nightly audit` section of `jev-daily-<date>.md` (creating the file if needed).

What is sent to Jev: the redacted action text, the tool name, the repo directory name, `context: audit`,
and the `risk_class` question. The client adds its own redaction and refuses an excluded cwd or path
(the audit passes `cwd` and, for Write and Edit, the path). What is never sent: tool results, file
contents, assistant or user prose, any tool other than Bash, Write, Edit and MultiEdit (so no Gmail or
Slack content), anything under `exclude_paths`, unredacted secrets.

`--dry-run` makes no Jev calls and writes nothing; it prints the counts and the redacted text that would
be sent, one line per action:

```text
python3 scripts/jev-nightly-audit.py --dry-run --date 2026-10-04
```

The audit's decisions land in `decisions.jsonl` with `origin: audit`, so the daily summary lists them in
their own origin row. Tests: `tests/scripts/test_jev_daily.sh` (stub client and the real client in
`JEV_MOCK` mode; no real calls).

## Daily schedule

`com.damilola.jev-daily-report` runs the summary and then the audit every day at 06:30 local time. The
scripts run from the repo checkout, not from `~/.claude`, so `scripts/sync.sh` deploys nothing for them
(the client they call, `~/.claude/hooks/jev/jev-ask`, is deployed as usual). The template is
`system-configs/.claude/launchagents/com.damilola.jev-daily-report.plist.template`; `__HOME__` and
`__REPO__` are substituted at install time because a plist cannot expand variables.

```text
scripts/install-jev-daily-agent.sh            # prints what it would do, changes nothing
scripts/install-jev-daily-agent.sh --write    # renders ~/Library/LaunchAgents/com.damilola.jev-daily-report.plist
launchctl load ~/Library/LaunchAgents/com.damilola.jev-daily-report.plist    # separate, explicit step
```

The installer never loads the agent: the audit makes Jev calls, so starting it is a decision. Run it from
the main checkout (it warns inside a worktree) or set `JEV_REPO_DIR`. Output goes to
`~/.tmp/reports/jev-daily-<date>.md`; launchd's own log is `~/.claude/logs/jev_daily_report.launchd.log`.
To stop it: `launchctl unload` the same plist.
