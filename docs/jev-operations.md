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

A rule that no layer registers is OFF. `exempt_agents` (default `dara`, `clara`) is read from the same
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

```
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

```
# what did the gates decide today?
jq -r 'select(.gate | startswith("G")) | [.ts, .gate, .mode, .outcome] | @tsv' ~/.claude/jev/decisions.jsonl
```
