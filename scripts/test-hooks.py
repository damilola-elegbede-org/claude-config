#!/usr/bin/env python3
"""Execute the configured PreToolUse hooks against sample payloads and assert
they block what they claim to block — and only that.

Why this exists: hooks fail silently. A hook that reads the wrong input source
matches nothing, exits 0, and looks identical to a hook that ran and approved
the call. Every guard in settings.json was in that state until this test was
added — they read $CLAUDE_TOOL_INPUT / $CLAUDE_FILE_PATHS, which Claude Code
does not populate.

Each case feeds a realistic payload on stdin (which is how Claude Code delivers
it) and checks the exit code: 2 = blocked, 0 = allowed. Blocked cases also
assert WHICH guard fired, so a case cannot pass because some unrelated hook
happened to block it.

Cases run in a temporary working directory, because two guards are
cwd-sensitive: the bare-git guard only fires where infra/scripts/git-agent.sh
exists, and the TDD guard only fires in directories that already use colocated
tests.

Note: the credential fixtures are assembled from fragments at runtime. Spelled
out literally they would match the scanner under test and this file would
become unwritable.
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

SETTINGS = Path(__file__).resolve().parents[1] / "system-configs/.claude/settings.json"

FAKE_AWS_KEY = "AKIA" + "IOSFODNN7" + "EXAMPLE"
FAKE_GH_TOKEN = "ghp" + "_" + ("a" * 36)

DESTRUCTIVE = "Destructive or policy-violating git operation"
BARE_GIT = "bare git for an identity/remote op"
SECRET = "Suspected credential/secret detected"
TDD = "and this directory uses colocated tests"

# (description, tool, tool_input, expected_reason_substring or None, setup)
#   setup: callable(tmpdir) -> None, run before the hooks, or None
def _with_git_agent(tmp):
    wrapper = Path(tmp) / "infra" / "scripts"
    wrapper.mkdir(parents=True, exist_ok=True)
    f = wrapper / "git-agent.sh"
    f.write_text("#!/bin/sh\nexit 0\n")
    f.chmod(0o755)


def _with_colocated_tests(tmp):
    (Path(tmp) / "src").mkdir(parents=True, exist_ok=True)
    (Path(tmp) / "src" / "existing.test.ts").write_text("// marks this dir as colocated-tests\n")


CASES = [
    # destructive git guard — fires everywhere
    ("commit skipping hooks", "Bash", {"command": "git commit --no-verify -m 'x'"}, DESTRUCTIVE, None),
    ("force push", "Bash", {"command": "git push --force origin main"}, DESTRUCTIVE, None),
    ("hard reset", "Bash", {"command": "git reset --hard HEAD~1"}, DESTRUCTIVE, None),
    ("force branch delete", "Bash", {"command": "git branch -D feature/old"}, DESTRUCTIVE, None),

    # bare-git guard — conditional on the wrapper being present
    ("bare git commit, no wrapper", "Bash", {"command": "git commit -m 'msg'"}, None, None),
    ("bare git push, no wrapper", "Bash", {"command": "git push origin main"}, None, None),
    ("bare git commit, wrapper present", "Bash", {"command": "git commit -m 'msg'"}, BARE_GIT, _with_git_agent),
    ("bare git push, wrapper present", "Bash", {"command": "git push origin main"}, BARE_GIT, _with_git_agent),

    # not git operations at all
    ("read-only git status", "Bash", {"command": "git status --short"}, None, None),
    ("ordinary ls", "Bash", {"command": "ls -la"}, None, None),

    # secret scanner
    ("AWS key in source", "Write",
     {"file_path": "app.py", "content": f"KEY = '{FAKE_AWS_KEY}'"}, SECRET, None),
    ("GitHub token in source", "Write",
     {"file_path": "app.py", "content": f"T = '{FAKE_GH_TOKEN}'"}, SECRET, None),
    ("credential-shaped string in markdown", "Write",
     {"file_path": "notes.md", "content": f"example: {FAKE_AWS_KEY}"}, None, None),
    ("clean markdown", "Write", {"file_path": "notes.md", "content": "just prose"}, None, None),

    # TDD guard — only fires where the directory already uses colocated tests
    ("new source file in colocated-test dir", "Write",
     {"file_path": "src/feature.ts", "content": "export const a = 1;"}, TDD, _with_colocated_tests),
    ("new source file, no test convention", "Write",
     {"file_path": "src/feature.ts", "content": "export const a = 1;"}, None, None),
]


def pretooluse_hooks(settings, tool):
    out = []
    for entry in settings.get("hooks", {}).get("PreToolUse", []):
        if tool not in entry.get("matcher", "").split("|"):
            continue
        for hook in entry.get("hooks", []):
            if hook.get("type") == "command" and hook.get("command"):
                out.append(hook["command"])
    return out


def run_case(commands, payload, cwd):
    """Return the stderr of the first hook that blocks, or None if all allow."""
    for cmd in commands:
        proc = subprocess.run(
            ["bash", "-c", cmd], input=payload, capture_output=True, text=True,
            timeout=30, cwd=cwd,
        )
        if proc.returncode == 2:
            return (proc.stderr or "").strip()
        if proc.returncode not in (0, 2):
            return f"__ERROR__ exit {proc.returncode}: {proc.stderr.strip()[:120]}"
    return None


def main():
    settings = json.loads(SETTINGS.read_text())
    failures = []

    for desc, tool, tool_input, expected, setup in CASES:
        commands = pretooluse_hooks(settings, tool)
        if not commands:
            failures.append(f"{desc}: no PreToolUse hook matches tool {tool}")
            print(f"  FAIL  {desc}: no hook matches tool {tool}")
            continue

        with tempfile.TemporaryDirectory() as tmp:
            if setup:
                setup(tmp)
            payload_input = dict(tool_input)
            # Resolve relative file paths inside the sandbox so the cwd-sensitive
            # guards see a realistic tree.
            if "file_path" in payload_input and not os.path.isabs(payload_input["file_path"]):
                payload_input["file_path"] = str(Path(tmp) / payload_input["file_path"])
                Path(payload_input["file_path"]).parent.mkdir(parents=True, exist_ok=True)
            payload = json.dumps({"tool_name": tool, "tool_input": payload_input})
            reason = run_case(commands, payload, tmp)

        if reason and reason.startswith("__ERROR__"):
            failures.append(f"{desc}: {reason}")
            print(f"  FAIL  {desc}: {reason}")
            continue

        if expected is None:
            if reason is None:
                print(f"  ok    {desc} (allowed)")
            else:
                failures.append(f"{desc}: expected allowed, blocked by: {reason[:80]}")
                print(f"  FAIL  {desc}: expected allowed, got blocked")
        else:
            if reason is None:
                failures.append(f"{desc}: expected block on '{expected}', was allowed")
                print(f"  FAIL  {desc}: expected blocked, got allowed")
            elif expected not in reason:
                failures.append(f"{desc}: blocked by the wrong guard — wanted '{expected}', got: {reason[:80]}")
                print(f"  FAIL  {desc}: wrong guard fired")
            else:
                print(f"  ok    {desc} (blocked by the expected guard)")

    print()
    if failures:
        print(f"{len(failures)} hook assertion(s) failed:")
        for f in failures:
            print(f"  - {f}")
        return 1
    print(f"All {len(CASES)} hook assertions passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
