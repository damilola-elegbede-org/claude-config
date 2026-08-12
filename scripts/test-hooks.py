#!/usr/bin/env python3
"""Execute the configured PreToolUse hooks against sample payloads and assert
they block what they claim to block.

Why this exists: hooks fail silently. A hook that reads the wrong input source
matches nothing, exits 0, and looks identical to a hook that ran and approved
the call. Every guard in settings.json was in that state until this test was
added — they read $CLAUDE_TOOL_INPUT / $CLAUDE_FILE_PATHS, which Claude Code
does not populate, so they had been no-ops for as long as they had existed.

Each case feeds a realistic hook payload on stdin (which is how Claude Code
delivers it) and checks the exit code:
    exit 2 = blocked, exit 0 = allowed.

Note: the credential fixtures below are assembled from fragments at runtime.
Spelled out literally they would match the very scanner under test, and this
file would become unwritable.
"""
import json
import subprocess
import sys
from pathlib import Path

SETTINGS = Path(__file__).resolve().parents[1] / "system-configs/.claude/settings.json"

FAKE_AWS_KEY = "AKIA" + "IOSFODNN7" + "EXAMPLE"          # AKIA + 16 uppercase/digits
FAKE_GH_TOKEN = "ghp" + "_" + ("a" * 36)                  # ghp_ + 36 alphanumerics

# (description, tool, tool_input, expect_blocked)
CASES = [
    ("git commit --no-verify", "Bash", {"command": "git commit --no-verify -m 'x'"}, True),
    ("git push --force", "Bash", {"command": "git push --force origin main"}, True),
    ("git reset --hard", "Bash", {"command": "git reset --hard HEAD~1"}, True),
    ("git branch -D", "Bash", {"command": "git branch -D feature/old"}, True),
    ("bare git commit", "Bash", {"command": "git commit -m 'msg'"}, True),
    ("bare git push", "Bash", {"command": "git push origin main"}, True),
    ("read-only git status", "Bash", {"command": "git status --short"}, False),
    ("ordinary ls", "Bash", {"command": "ls -la"}, False),
    ("AWS key in source file", "Write",
     {"file_path": "/tmp/hooktest_app.py", "content": f"KEY = '{FAKE_AWS_KEY}'"}, True),
    ("GitHub token in source file", "Write",
     {"file_path": "/tmp/hooktest_app.py", "content": f"T = '{FAKE_GH_TOKEN}'"}, True),
    ("credential-shaped string in markdown", "Write",
     {"file_path": "/tmp/hooktest_notes.md", "content": f"example: {FAKE_AWS_KEY}"}, False),
    ("clean source file", "Write",
     {"file_path": "/tmp/hooktest_clean.md", "content": "just some prose"}, False),
]


def pretooluse_hooks(settings, tool):
    """Return PreToolUse commands whose matcher applies to `tool`."""
    out = []
    for entry in settings.get("hooks", {}).get("PreToolUse", []):
        if tool not in entry.get("matcher", "").split("|"):
            continue
        for hook in entry.get("hooks", []):
            if hook.get("type") == "command" and hook.get("command"):
                out.append(hook["command"])
    return out


def main():
    settings = json.loads(SETTINGS.read_text())
    failures = []

    for desc, tool, tool_input, expect_blocked in CASES:
        payload = json.dumps({"tool_name": tool, "tool_input": tool_input})
        commands = pretooluse_hooks(settings, tool)
        if not commands:
            failures.append(f"{desc}: no PreToolUse hook matches tool {tool}")
            print(f"  FAIL  {desc}: no hook matches tool {tool}")
            continue

        blocked_reason = None
        for cmd in commands:
            proc = subprocess.run(
                ["bash", "-c", cmd], input=payload, capture_output=True, text=True, timeout=20
            )
            if proc.returncode == 2:
                lines = (proc.stderr or "").strip().splitlines()
                blocked_reason = lines[0] if lines else "blocked"
                break
            if proc.returncode not in (0, 2):
                failures.append(
                    f"{desc}: hook exited {proc.returncode} (expected 0 or 2): "
                    f"{proc.stderr.strip()[:120]}"
                )

        was_blocked = blocked_reason is not None
        if was_blocked != expect_blocked:
            want = "blocked" if expect_blocked else "allowed"
            got = "blocked" if was_blocked else "allowed"
            failures.append(f"{desc}: expected {want}, got {got}")
            print(f"  FAIL  {desc}: expected {want}, got {got}")
        else:
            note = f" -> {blocked_reason[:58]}" if blocked_reason else ""
            print(f"  ok    {desc} ({'blocked' if was_blocked else 'allowed'}){note}")

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
