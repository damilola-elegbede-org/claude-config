# Git safety

- Never pass `--no-verify`. A failing hook gets fixed, not bypassed.
- Force-push only as a standalone `git push [-u] --force-with-lease <remote> [<src>:]<feature-branch>`; every other force push is blocked.
- Stash with `git stash push -u -m "<unique tag>"`, restore with `git stash apply <sha>`, drop by explicit `stash@{n}`: the stack is shared.
- Stage files by name; never `git add -A` or `git add .`.
- Never commit or push to main or master directly; work on a branch.
