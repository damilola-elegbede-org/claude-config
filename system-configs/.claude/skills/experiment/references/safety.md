# Side-effect screen

The main session classifies every command in `plan.json` before locking, because a runner subagent cannot ask
D and cannot answer a gate. `run.sh` adds a mechanical second check: it screens each `cmd` and `observe` command
through the regex gate and refuses anything the gate would stop. That check catches known patterns only; this
screen is the judgment.

## Classes

| Class | What it covers | How it runs |
| --- | --- | --- |
| `sandbox` | Reads anywhere; writes only under the experiment directory; scratch repos with local bare remotes; a fake HOME; local processes; read-only network requests | `run.sh`, dispatched to the runner |
| `ask-d` | One step that touches something outside the sandbox, such as a real repo's remote, a message, a paid call beyond a trivial amount, or a live write | D approves the exact step through AskUserQuestion; the main session runs it, where the gates see it, then records the result with `run.sh <dir> --record` |
| `refuse` | Production data, deletes outside the sandbox, money, anything irreversible, or anything that reaches other people | Not run. `lock.sh` refuses it; report why and what a safe stand-in would be |

## Checks for every command

- Every path it writes is under `$EXPERIMENT_DIR`. A command that writes elsewhere is not sandbox.
- No push, PR, issue, comment, message or email to anything real. Use a local bare remote.
- No credentials in the plan, and no command that prints a secret into `runs/`.
- Live `~/.claude` stays untouched: hooks or configs under test are copied under `$EXPERIMENT_HOME`, and a
  condition that needs them sets `"home": "sandbox"` or passes the fake HOME to only the hook it tests.
- Cost: commands that call paid APIs are counted and estimated before locking.

When a design cannot stay in the sandbox, look for a stand-in first: a local bare remote instead of GitHub, a
copy of the file instead of the file, a read-only probe instead of a write.
