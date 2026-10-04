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

A rule that no layer registers is OFF. `exempt_agents` (default `clara`) is read from the same
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
{ts, gate, mode, answers, confidence, model, latencyMs, outcome, src, ...extra}
```

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

`scripts/jev-replay.py` replays the 87 labelled examples in `tests/fixtures/jev-replay-labels.jsonl`
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
