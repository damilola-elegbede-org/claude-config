# Repo location

- Every git repo lives at `~/dev/<name>`, one copy each. Never `~/repos`, `~/Documents/Projects`, or the home root.
- Clone with an explicit destination: `git clone <url> ~/dev/<name>` or `gh repo clone <owner/name> ~/dev/<name>`.
  The `MG-repo-location` gate denies a clone without one. Scratch clones under `$TMPDIR` or `/tmp` are fine.
- Before cloning, check whether `~/dev/<name>` exists; if it does, use it.
  Don't create a second copy to work on a branch: use a worktree.
- Worktrees live inside the repo at `.claude/worktrees/<name>`, never beside it in `~/dev`.
- VS Code opens `~/dev` by default (bare `code` in the dotfiles zshrc).
