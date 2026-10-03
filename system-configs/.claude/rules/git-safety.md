# Git safety

- Never pass `--no-verify`. A failing hook gets fixed, not bypassed.
- Never force-push; a PreToolUse guard blocks `git push --force` and `-f`. After a rewrite, ask D via `AskUserQuestion` and give D the command.
- Stash with `git stash push -u -m "<unique tag>"`, restore with `git stash apply <sha>`, drop by explicit `stash@{n}`: the stack is shared.
- Stage files by name; never `git add -A` or `git add .`.
- Never commit or push to main or master directly; work on a branch.
