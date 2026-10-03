#!/usr/bin/env python3
"""Render docs/rules-enforcement.md from docs/rules/registry.json.

The registry lists every rule in system-configs/CLAUDE.md, the Executive output
style, the ask and interview skills, and D's feedback memory entries, with how (and
whether) each is enforced. This script only RENDERS and VALIDATES the registry; it
never reads the memory directory unless one exists (CI has none).

Usage:
  python3 scripts/rules-table.py            # write docs/rules-enforcement.md
  python3 scripts/rules-table.py --check    # validate registry + fail if the doc is stale
  python3 scripts/rules-table.py --slimming # list CLAUDE.md rules whose prose may be deleted
  python3 scripts/rules-table.py --stats    # counts only
"""
import argparse
import json
import os
import sys
import textwrap
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REGISTRY = ROOT / "docs/rules/registry.json"
DOC = ROOT / "docs/rules-enforcement.md"
HOOK_DIRS = [ROOT / "system-configs/.claude/hooks/jev", ROOT / "system-configs/.claude"]
ENFORCEMENT = {"regex", "jev", "none"}
MODES = {"enforce", "advisory", "shadow", "none"}
COVERAGE = {"full", "partial", "none"}


def memory_dir(reg):
    env = os.environ.get("RE_MEMORY_DIR")
    return Path(env) if env else Path(os.path.expanduser(reg.get("memory_dir", "")))


def load():
    try:
        return json.loads(REGISTRY.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as e:
        print(f"cannot load registry {REGISTRY}: {e}", file=sys.stderr)
        return None


def inline_pretooluse_commands():
    """Every PreToolUse hook command in settings.json (the inline guards)."""
    try:
        settings = json.loads((ROOT / "system-configs/.claude/settings.json").read_text())
    except (OSError, json.JSONDecodeError):
        return []
    cmds = []
    for entry in (settings.get("hooks") or {}).get("PreToolUse") or []:
        for h in entry.get("hooks") or []:
            if isinstance(h.get("command"), str):
                cmds.append(h["command"])
    return cmds


def validate(reg):
    errors = []
    seen = set()
    mem = memory_dir(reg)
    for r in reg["rules"]:
        rid = r.get("id", "?")
        if rid in seen:
            errors.append(f"{rid}: duplicate id")
        seen.add(rid)
        for k in ("id", "source", "anchor", "text", "enforcement", "hook", "mode", "coverage"):
            if k not in r:
                errors.append(f"{rid}: missing field {k}")
        if r.get("enforcement") not in ENFORCEMENT:
            errors.append(f"{rid}: enforcement {r.get('enforcement')!r} not in {sorted(ENFORCEMENT)}")
        if r.get("mode") not in MODES:
            errors.append(f"{rid}: mode {r.get('mode')!r} not in {sorted(MODES)}")
        if r.get("coverage") not in COVERAGE:
            errors.append(f"{rid}: coverage {r.get('coverage')!r} not in {sorted(COVERAGE)}")
        if r.get("enforcement") == "none":
            if r.get("hook") is not None or r.get("mode") != "none" or r.get("coverage") != "none":
                errors.append(f"{rid}: enforcement none requires hook null, mode none, coverage none")
        else:
            hook = r.get("hook")
            if not hook:
                errors.append(f"{rid}: enforcement {r.get('enforcement')} requires a hook filename")
            elif not any((d / hook).is_file() for d in HOOK_DIRS):
                errors.append(f"{rid}: hook {hook} not found under hooks/jev or system-configs/.claude")
            elif hook == "settings.json":
                # The file always exists; the guard a rule relies on is INLINE in it, so prove the guard is there.
                marker = r.get("hook_marker")
                if not marker:
                    errors.append(f"{rid}: hook settings.json needs hook_marker (a substring of the inline PreToolUse guard it relies on)")
                elif not any(marker in c for c in inline_pretooluse_commands()):
                    errors.append(f"{rid}: hook_marker {marker!r} is in no PreToolUse command of settings.json (guard removed?)")
            if r.get("enforcement") == "jev" and r.get("mode") not in ("shadow", "enforce"):
                errors.append(f"{rid}: jev rules are shadow or enforce")
        # source:line + anchor must really be there
        src, _, line = r.get("source", ":").rpartition(":")
        if not line.isdigit():
            errors.append(f"{rid}: source {r.get('source')!r} is not file:line")
            continue
        if src.startswith("memory/"):
            path = mem / src[len("memory/"):]
            if not mem.is_dir():
                continue  # no memory dir here (CI): the memory rows cannot be re-checked
        else:
            path = ROOT / src
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError:
            errors.append(f"{rid}: source file {src} not readable")
            continue
        n = int(line)
        if not (1 <= n <= len(lines)) or r.get("anchor", "") not in lines[n - 1]:
            errors.append(f"{rid}: anchor {r.get('anchor')!r} not on {src}:{line}")
    return errors


def cell(s):
    return str(s).replace("|", "\\|").replace("\n", " ")


def table(header, rows):
    widths = [max(len(header[i]), *(len(r[i]) for r in rows)) if rows else len(header[i]) for i in range(len(header))]
    def fmt(cells):
        return "| " + " | ".join(c.ljust(widths[i]) for i, c in enumerate(cells)) + " |"
    out = [fmt(header), "| " + " | ".join("-" * w for w in widths) + " |"]
    out += [fmt(r) for r in rows]
    return "\n".join(out)


def stats(reg):
    c = Counter(r["enforcement"] for r in reg["rules"])
    return len(reg["rules"]), c


def slimming(reg):
    return [r for r in reg["rules"]
            if r["source"].startswith("system-configs/CLAUDE.md:") and r["mode"] == "enforce" and r["coverage"] == "full"]


def render(reg):
    total, c = stats(reg)
    modes = Counter((r["enforcement"], r["mode"]) for r in reg["rules"] if r["enforcement"] != "none")
    parts = [
        "# Rules enforcement",
        "",
        "<!-- GENERATED by scripts/rules-table.py from docs/rules/registry.json. Do not edit by hand. -->",
        "",
        "Every rule in `system-configs/CLAUDE.md`, the Executive output style, the `ask` and `interview` skills, and D's",
        "feedback memory entries, with whether anything enforces it. Edit the registry, then run",
        "`python3 scripts/rules-table.py`; `--check` fails when this file is stale.",
        "",
        "## Summary",
        "",
        table(["Enforcement", "Rules", "Meaning"], [
            ["regex", str(c["regex"]), reg["taxonomy"]["enforcement"]["regex"]],
            ["jev", str(c["jev"]), reg["taxonomy"]["enforcement"]["jev"]],
            ["none", str(c["none"]), reg["taxonomy"]["enforcement"]["none"]],
            ["**total**", f"**{total}**", ""],
        ]),
        "",
        table(["Mode", "Rules", "Meaning"], [
            [m, str(sum(v for (e, mm), v in modes.items() if mm == m)), reg["taxonomy"]["mode"][m]]
            for m in ("enforce", "advisory", "shadow")
        ]),
        "",
        *textwrap.wrap("Slimming rule: " + reg["taxonomy"]["slimming"], 120),
        "",
    ]
    cand = slimming(reg)
    if cand:
        parts += ["CLAUDE.md rules whose prose can be deleted now: " + ", ".join(r["id"] for r in cand) + ".", ""]
    else:
        parts += ["CLAUDE.md rules whose prose can be deleted now: none (no CLAUDE.md rule has an enforce-mode hook with full coverage).", ""]
    groups = [
        ("CLAUDE.md", "system-configs/CLAUDE.md:"),
        ("Executive output style", "system-configs/.claude/output-styles/executive.md:"),
        ("ask skill", "system-configs/.claude/skills/ask/SKILL.md:"),
        ("interview skill", "system-configs/.claude/skills/interview/SKILL.md:"),
        ("Memory (feedback entries)", "memory/"),
    ]
    for title, prefix in groups:
        rs = [r for r in reg["rules"] if r["source"].startswith(prefix)]
        parts += [f"## {title} ({len(rs)})", ""]
        rows = []
        for r in rs:
            src = r["source"]
            rows.append([f"`{r['id']}`", f"`{src}`", cell(r["text"]), r["enforcement"],
                         f"`{r['hook']}`" if r["hook"] else "-", r["mode"] if r["mode"] != "none" else "-",
                         r["coverage"] if r["coverage"] != "none" else "-"])
        parts += [table(["Id", "Source", "Rule", "Enforcement", "Hook", "Mode", "Coverage"], rows), ""]
    return "\n".join(parts).rstrip("\n") + "\n"


def main(argv):
    ap = argparse.ArgumentParser(description="Render and validate docs/rules-enforcement.md from the rules registry.")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true", help="validate registry + fail if the doc is stale")
    mode.add_argument("--slimming", action="store_true", help="list CLAUDE.md rules whose prose may be deleted")
    mode.add_argument("--stats", action="store_true", help="counts only")
    args = ap.parse_args(argv)
    reg = load()
    if reg is None:
        return 1
    errors = validate(reg)
    if errors:  # fail closed before any mode that reads rule fields
        print("registry errors:", file=sys.stderr)
        for e in errors:
            print("  " + e, file=sys.stderr)
        return 1
    if args.stats:
        total, c = stats(reg)
        print(f"rules={total} regex={c['regex']} jev={c['jev']} none={c['none']}")
        return 0
    if args.slimming:
        for r in slimming(reg):
            print(f"{r['id']}\t{r['source']}\t{r['hook']}")
        return 0
    text = render(reg)
    if args.check:
        if not DOC.is_file() or DOC.read_text(encoding="utf-8") != text:
            print("docs/rules-enforcement.md is stale: run python3 scripts/rules-table.py", file=sys.stderr)
            return 1
        total, c = stats(reg)
        print(f"ok: {total} rules (regex {c['regex']}, jev {c['jev']}, none {c['none']})")
        return 0
    DOC.write_text(text, encoding="utf-8")
    print(f"wrote {DOC.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
