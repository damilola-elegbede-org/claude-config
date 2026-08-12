#!/usr/bin/env python3
"""Enforce the file-organization rule from CLAUDE.md.

  "Temporary files go in .tmp/: .tmp/plans/, .tmp/reports/, .tmp/analysis/,
   .tmp/drafts/. Never in repo root or source directories."

That rule was documented but never checked, so it was enforced by hand — every
time, forever, by whoever noticed. This is the check.

Only tracked files are examined: .tmp/ is gitignored, and untracked scratch is
the developer's business until they try to commit it.

Usage:
  python3 scripts/validate-file-org.py          # report violations, exit 1 if any
  python3 scripts/validate-file-org.py --list   # show what would be checked
"""
import re
import subprocess
import sys
from pathlib import Path

# Artefact-shaped names. Deliberately narrow: this should catch "I dropped a
# report in the repo root", not argue about whether a doc is permanent.
TEMP_PATTERNS = [
    re.compile(r".*[-_](report|analysis|audit|summary|findings)\.(md|json|txt)$", re.I),
    re.compile(r".*[-_]plan\.(md|json|txt)$", re.I),
    re.compile(r"^(scratch|draft|temp|tmp|notes|wip)[-_.].*", re.I),
    re.compile(r"^(scratch|scratchpad|todo|notes)\.(md|txt|json)$", re.I),
    # Separator is [-_.] on purpose: "foo.sh.wave8-backup" is as much a stray
    # backup as "foo.sh.backup", and requiring a dot missed it.
    re.compile(r".*[-_.](bak|backup|orig|old|save)$", re.I),
    re.compile(r".*\.(tmp|swp|swo)$", re.I),
]

# Directories whose contents are published artefacts, not working files.
EXEMPT_DIRS = (".tmp/", "docs/", "tests/fixtures/", "examples/", "node_modules/", ".git/")

# Files that look temporary but are load-bearing.
EXEMPT_FILES = set()


def tracked_files():
    out = subprocess.run(
        ["git", "ls-files"], capture_output=True, text=True, check=True
    ).stdout
    return [line for line in out.splitlines() if line.strip()]


def is_exempt(path: str) -> bool:
    if path in EXEMPT_FILES:
        return True
    return any(path.startswith(d) for d in EXEMPT_DIRS)


def violations(paths):
    found = []
    for path in paths:
        if is_exempt(path):
            continue
        name = Path(path).name
        for pattern in TEMP_PATTERNS:
            if pattern.match(name):
                found.append(path)
                break
    return found


def main():
    listing = "--list" in sys.argv[1:]
    paths = tracked_files()

    if listing:
        print(f"{len(paths)} tracked files; {sum(1 for p in paths if not is_exempt(p))} in scope")
        print(f"Exempt directories: {', '.join(EXEMPT_DIRS)}")
        return 0

    found = violations(paths)
    if not found:
        print(f"File organization OK — no temporary artefacts tracked outside .tmp/ ({len(paths)} files checked)")
        return 0

    print(f"{len(found)} temporary artefact(s) tracked outside .tmp/:")
    for path in found:
        print(f"  {path}")
    print()
    print("Per CLAUDE.md, these belong in .tmp/plans, .tmp/reports, .tmp/analysis, or .tmp/drafts.")
    print("Move them there, or delete them if they have served their purpose.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
