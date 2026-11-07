---
name: experiment
description: Settle a hypothesis with a small, pre-registered experiment run by subagents in a sandbox, graded by a script, and reported as SUPPORTED, REFUTED or INCONCLUSIVE with n. Use proactively whenever a claim, plan or answer rests on something nobody has checked and a quick safe test could check it, and when D says "prove it", "are you sure", "verify that", "test the hypothesis", "I'm not sure", "we're guessing", or a claim would otherwise be marked untested or inference. Not for running a project's own checks (/verify) or test suite (/test), or for vetting an argument (/colorwheel).
argument-hint: "<hypothesis or question to settle> [--reps N]"
allowed-tools: [Read, Write, Edit, Bash, Grep, Glob, Agent, AskUserQuestion]
metadata:
  category: workflow
---

# /experiment

## Usage

```bash
/experiment "the gate releases a Drive trash call after one coded yes"
/experiment "is the cache hit rate higher with the new key?" --reps 10
/experiment                     # settle the open doubt in the current conversation
```

## Description

Turns a doubt into evidence. A claim D might act on should be checked, not argued: this skill writes down what
would prove the claim wrong before anything runs, runs the trial out of the main context in a sandbox, and lets
a script, not the model that formed the hypothesis, apply the rule. The result is a verdict with its sample
size and interval, kept on disk under `.tmp/experiments/<id>/` so anyone can re-read or re-run it.

Three things make the evidence trustworthy, and the scripts enforce each one:

- **Pre-registration.** The hypothesis, prediction, pass rule and controls are written into `protocol.json` and
  sealed by `scripts/lock.sh` before any run. `run.sh` and `score.py` refuse a protocol edited after the lock,
  so the goalposts cannot move to fit the data.
- **Blind runners.** The `experiment-runner` agent works from `plan.json` only and never sees the hypothesis or
  the expected answer, because a runner that knows the expected result tends to find it.
- **Mechanical grading.** `scripts/score.py` applies the locked rule to `runs.jsonl`. A control that misbehaves
  makes the result INCONCLUSIVE, because a test that cannot fail proves nothing.

## Expected Output

Illustrative; the experiment, numbers and paths are examples.

```text
User: /experiment "a retry inside 30 minutes keeps D's approval valid"

Pre-registered .tmp/experiments/20261107-101500-retry-keeps-approval/
  prediction: treatment releases on 5/5 retries; the expired-deny control releases on 0/5
  side effects: sandbox (fake HOME, scratch repo, local bare remote)
Locked (sha256 3f9c1a...). Runner dispatched; 15 runs recorded, 0 refused, 0 timed out.

Verdict: SUPPORTED — holds: rate(treatment) = 1 >= 1

| condition        | n | invalid | passes | rate | 95% interval | mean |
| ---------------- | - | ------- | ------ | ---- | ------------ | ---- |
| treatment        | 5 | 0       | 5      | 1.00 | 0.57-1.00    | 1    |
| baseline         | 5 | 0       | 0      | 0.00 | 0.00-0.43    | 0    |
| expired-control  | 5 | 0       | 0      | 0.00 | 0.00-0.43    | 0    |

Evidence: .tmp/experiments/20261107-101500-retry-keeps-approval/verdict.json
```

## Behavior

### When to run it

Run it without being asked when all three hold: a conclusion D may act on rests on a claim nobody checked, a
test could settle that claim in minutes, and the test can run in a sandbox. Typical moments:

- About to write "untested", "inference", "should work" or "probably" next to a claim D will act on
- Two explanations for a behavior compete and the next step depends on which one is true
- About to ask D to check something a command or a headless run could check instead
- Changing a hook, gate, threshold or prompt whose effect on real runs is unknown
- D asks for proof, or questions a claim

Skip it, and say why, when reading the code or docs answers the question outright, when the project's own
checks answer it (`/verify`, `/test`), or when the only possible test touches production, spends money or
reaches other people. Those are D's call through AskUserQuestion, not an experiment's.

### The loop

Order matters: each step depends on the one before it.

1. **Frame.** Turn the doubt into one falsifiable hypothesis and the metric that would show it. If the claim
   cannot fail under any observation, say so and stop: there is nothing to test.
2. **Pre-register.** `scripts/new.sh <slug>` scaffolds the directory. Fill in `protocol.json` (question,
   hypothesis, prediction, if_false, pass_rule, controls, side_effects) and `plan.json` (conditions, reps,
   timeout_s, seed). `references/protocol.md` has the schema and the pass-rule forms; `references/designs.md`
   has the designs: baseline comparison, negative control, A/B, headless `claude -p` trials, live probes.
   Every experiment needs a negative control, a condition that must fail, so the test shows it can fail.
3. **Screen side effects.** Classify every command with `references/safety.md` before anything is handed off:
   sandbox (runs here), ask-d (D approves through AskUserQuestion, then you run the one gated step in the main
   session and record it), or refuse. Subagents cannot answer a gate, so this judgment belongs to the main
   session, before delegation.
4. **Lock.** `scripts/lock.sh <dir>` validates and seals both files. It rejects template text, unknown
   conditions, a missing control and `side_effects: refuse`.
5. **Run out of context.** Hand the directory to the `experiment-runner` agent through the Agent tool, with a
   prompt that names only the directory and says to run `~/.claude/skills/experiment/scripts/run.sh <dir>` and
   report. Never put the hypothesis or the expected result in that prompt. Independent experiments get one
   runner each, sent in one message so they run in parallel; one experiment gets one runner, because two runners
   on one directory would interleave its `runs.jsonl`. `run.sh` refuses unlocked or edited experiments,
   anything not marked sandbox, and any command the regex gate (`~/.claude/hooks/gate.sh`) would stop, because
   commands it runs are subprocesses the tool-call gates never see.
6. **Judge, only if the metric needs judgment.** Conditions with `"observe": "judge"` produce outputs a person
   or model must grade. `score.py --export-blind <dir>` writes them without condition names; a fresh
   `experiment-runner` grades them with `references/judge.md` and the rubric, and `score.py` maps the grades
   back. Prefer an `observe` command that prints a value: a script cannot be talked into a result.
7. **Score.** `python3 ~/.claude/skills/experiment/scripts/score.py <dir>` prints the verdict and table and
   writes `verdict.json`. Read the runner's anomaly lines too: an INCONCLUSIVE verdict says what to fix.
8. **Report and keep.** Lead with the verdict, then the hypothesis, the table and the directory. If the result
   changes how future work should go, save it as a memory; if it settles a claim in a PR or ticket, cite the
   `verdict.json` path or paste the table there.

### Rules

- **Never call a hypothesis proved.** SUPPORTED means the locked rule held on these n runs; report the
  interval. Small n gives wide intervals, and the table shows it.
- **Never change the protocol after a run.** A better design is a new experiment (`new.sh`), and the old
  verdict stays on disk.
- **Never weaken a refusal.** If `run.sh` or `lock.sh` refuses, fix the design or take the step to D. Never
  run a refused command by hand to get around it.
- **INCONCLUSIVE is a result.** Report it with its reason and the fix; do not round it up to SUPPORTED.
- **Spend is D's call.** Estimate the cost before running anything that calls a paid API, such as headless
  `claude -p` runs. Anything beyond a trivial amount goes to D through AskUserQuestion first.
- **Keep the main context clean.** The main session writes the protocol and reads the verdict; raw run output
  stays under `runs/` and in the runner's context.

### Boundaries with other skills

| Need | Skill |
| --- | --- |
| Run the project's tests, linters, build; fix what fails | `/verify` |
| Run the test suite and report | `/test` |
| Stress-test an idea or plan by argument | `/colorwheel` |
| Produce new evidence for or against a specific claim | `/experiment` |

## Notes

- Layout: `protocol.json` (sealed half), `plan.json` (runner half), `lock.json`, `runs.jsonl` (one row per
  run), `runs/<cond>-<rep>.out|.err`, `work/` (cwd of every run), `home/` (fake HOME a condition opts into with
  `"home": "sandbox"`), `verdict.json`.
- `run.sh` resumes: re-running skips condition/rep pairs already recorded.
- `scripts/supervise.py` runs each `cmd` and `observe` in its own process group and kills the whole group when
  it exits or times out, so a background child cannot outlive its run and touch the next one.
- Conditions run in an order shuffled per rep with `plan.seed`, so no condition always runs first.
- `score.py` exit codes: 0 SUPPORTED, 1 REFUTED, 2 INCONCLUSIVE, 3 bad or unlocked experiment.
- The Jev Stop check `experiment-candidate` surfaces this skill: when a reply rests on something not yet
  sure, new evidence would change the next step or D's decision, and a quick sandboxed experiment could get it,
  Jev holds the reply once per session and asks for `/experiment` first. Its log lines
  (`verdict: p=...` and `block`) are the measure of its precision.
