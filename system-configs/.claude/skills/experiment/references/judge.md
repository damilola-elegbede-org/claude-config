# Blind judge

Use a judge only when no `observe` command can measure the outcome, for example "is this reply a correct
answer" or "did the model follow the instruction". A script beats a judge whenever both can measure it.

## Setup (main session)

1. Write the rubric into `protocol.json` `notes` before locking: what earns `true` (or each score) and what
   does not, with one example of each. A rubric written after seeing outputs drifts toward them.
2. After the runs: `python3 ~/.claude/skills/experiment/scripts/score.py --export-blind <dir>`. It writes
   `blind/items.jsonl` (`{id, output}`, shuffled, no condition names) and `blind/key.json` (the mapping, never
   shown to the judge).
3. Dispatch a fresh `experiment-runner` through the Agent tool with this prompt, filling in the two values:

```text
You are a blind judge. Read <dir>/blind/items.jsonl. For each item, apply the rubric below to its output alone
and append one line to <dir>/blind/judgments.jsonl: {"id": "<the item's id>", "value": <true or false, or a
number if the rubric scores>, "reason": "<one sentence>"}. Do not open any other file in <dir>. Grade every
item; if one cannot be graded, give value null and say why.

Rubric:
<the rubric from protocol.json notes>
```

Then `python3 ~/.claude/skills/experiment/scripts/score.py <dir>` maps the grades back to their conditions and
scores as usual. An item graded `null` counts as an invalid run.

## Judge quality

- One judge pass is one opinion. For a decision that matters, run three independent judges (three items files
  are not needed: dispatch three fresh runners, each writing its own judgments file, then merge by majority
  into `blind/judgments.jsonl` before scoring).
- Spot-check a few judgments against the outputs yourself; report any disagreement with the judge.
