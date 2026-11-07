# Protocol reference

An experiment is two files, split so the runner can work blind. `score.py --validate` enforces every rule here,
and `lock.sh` runs it before sealing.

## protocol.json: the sealed half

Runners never read this file. It says what would count as true before anything runs.

| Field | Type | Meaning |
| --- | --- | --- |
| `question` | string | What we need to know, in one sentence |
| `hypothesis` | string | The claim under test, stated so it can be false |
| `prediction` | string | What the runs show if the hypothesis is true, in terms of the metric |
| `if_false` | string | What the runs show if it is false |
| `pass_rule` | object | The rule `score.py` applies (forms below) |
| `controls` | list | At least one `{condition, expect: "pass" or "fail"}`; a control must behave on every run |
| `side_effects` | string | `sandbox`, `ask-d` or `refuse` (see `safety.md`) |
| `notes` | string | Optional: anything a later reader needs, such as why this design |

The four text fields cannot be left as `new.sh`'s template text: lock refuses them.

### Pass-rule forms

A run's `value` counts as a pass when it is `true`, a non-zero number, or the string `pass`, `true`, `yes` or
`1`. `rate` is the passing fraction of valid runs; `mean` averages numeric values (`true` counts as 1).

```json
{"type": "rate", "condition": "treatment", "op": ">=", "value": 0.9}
{"type": "mean", "condition": "treatment", "op": "<", "value": 2.5}
{"type": "compare", "stat": "rate", "a": "treatment", "b": "baseline", "op": ">", "margin": 0.2}
```

`op` is one of `>=`, `>`, `<=`, `<`, `==`. For `compare`, the margin widens the gap `a` must clear: with `>`
or `>=`, `a` is compared against `b + margin`; with `<` or `<=`, against `b - margin`.

### How the verdict is decided

In this order, and the first that applies wins:

1. Any condition named by the pass rule or a control has fewer valid runs than `reps`: **INCONCLUSIVE**. A run
   is invalid when it timed out, errored, or has no value yet (an unjudged output).
2. A control did not behave on every run (an `expect: "fail"` condition passed once, or an `expect: "pass"`
   condition failed once): **INCONCLUSIVE**, because the test cannot tell the hypothesis apart.
3. The pass rule holds: **SUPPORTED**. It does not: **REFUTED**.

## plan.json: the runner half

| Field | Type | Meaning |
| --- | --- | --- |
| `reps` | integer 1-1000 | Runs per condition |
| `timeout_s` | number 1-3600 | Per-run time limit; a run past it is killed and counts as invalid |
| `seed` | integer | Seeds the per-rep shuffle of condition order |
| `conditions` | list | Each `{name, cmd, observe, home}` |

- `name`: lowercase letters, digits, hyphens; unique.
- `cmd`: a bash command, run with cwd `work/`.
- `observe`: `null` means the value is "exit code was 0". `"judge"` means a blind judge grades the output. Any
  other string is a command whose stdout is the value (parsed as JSON when it is JSON); it sees `RUN_OUT` and
  `RUN_ERR` (file paths) and `RUN_EXIT`.
- `home`: `real` (default) keeps HOME; `sandbox` sets HOME to the experiment's `home/`.

Every command also sees `EXPERIMENT_DIR`, `EXPERIMENT_WORK`, `EXPERIMENT_HOME`, `EXPERIMENT_CONDITION` and
`EXPERIMENT_REP`.

## Choosing reps

The interval in the table is a 95% Wilson interval on the pass rate. Illustrative widths from the formula:
5/5 passes gives 0.57-1.00, 10/10 gives 0.72-1.00, 20/20 gives 0.84-1.00. A rule like "rate >= 0.9" over 3
runs can hold while its interval is wide; pick reps so the interval is narrow enough for the decision, and say
what n was in the report.
