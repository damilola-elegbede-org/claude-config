# Experiment designs

Pick the smallest design that can tell the hypothesis apart from its alternative. Every design has a negative
control: a condition built so it must fail. Without one, a broken test that always passes reads as SUPPORTED.

## Baseline comparison

The change against the way things are now, under identical conditions.

- `treatment`: the new code, setting or prompt
- `baseline`: the current one (for a repo change, check the base branch's version out into `work/`)
- `negative-control`: an input the behavior must reject
- Rule: `compare` on `rate` or `mean`, `treatment` vs `baseline`, with a margin that matters for the decision

## Single claim

"X always does Y." One treatment condition, a high bar, and a control.

- Rule: `{"type": "rate", "condition": "treatment", "op": ">=", "value": 1}`
- Reps: enough that the interval supports the decision (`protocol.md`, Choosing reps)

## A/B of two candidates

Two candidate fixes or prompts, same inputs. Treat one as `a`, the other as `b`, and pre-register which way
the decision goes before running: a rule written after the data favors whichever happened to win.

## Headless Claude trial

For questions about what a model or a hook does in a real session. Each condition is one `claude -p` run.

```bash
# illustrative cmd for one condition; the settings file wires the hooks under test to a fake HOME
claude -p "<the task, identical in every condition>" --model sonnet \
  --setting-sources project,local --settings "$EXPERIMENT_DIR/settings-treatment.json" \
  --max-turns 6 --output-format stream-json --verbose --include-hook-events >"$EXPERIMENT_WORK/run.jsonl"
```

- Give only the hook commands a fake HOME (`env HOME=$EXPERIMENT_HOME JEV_ZSHRC=$HOME/.zshrc <hook>` inside the
  settings file, with `$HOME` expanded to the real home when the file is written), with the version under test
  copied there. That keeps the live `~/.claude` untouched while the CLI still signs in.
- The Jev client reads its API key from `$HOME/.zshrc`, so under a fake HOME pass `JEV_ZSHRC` pointing at the
  real file. Without it every Jev call fails open, the hook's model checks never fire, and the trial reads as
  "the hook did nothing": a false negative. Never copy the key file into the experiment directory.
- `--setting-sources project,local` drops the live user hooks and also the user skills: copy any skill the
  trial needs into the scratch repo's `.claude/skills/`.
- Unset `CLAUDE_JOB_DIR` in the command so the session counts as interactive, unless the question is about
  background jobs.
- Point the session at a scratch repo in `work/` with a local bare remote (`git init --bare`), so a push or a
  delete stays inside the experiment.
- Observe from the run's own output or the hooks' logs under `$EXPERIMENT_HOME/.claude/`. Hook verdicts live in
  `jev-gates.jsonl` and `gate-log.jsonl` there; read the right file before concluding a hook did nothing.
- Check the premise in a dry run first: a scenario the model refuses for an unrelated reason tests nothing.
- These runs call a paid API. Estimate the cost before locking, and take anything beyond a trivial amount to D.

## Live probe

For claims about an external API or service: one real, read-only request per condition, observed by status
code or a field in the response. Stub tests can pass while the live endpoint rejects the client. A probe that
writes, sends or spends is ask-d, not sandbox (`safety.md`).

## Replay over real inputs

For threshold or classifier questions: run the candidate over real past inputs (for example, transcripts under
`~/.claude/projects/`) copied into `work/`, at least 3 reps per item, and grade with a blind judge or a labelled
set. Report the rate with its interval per threshold.
