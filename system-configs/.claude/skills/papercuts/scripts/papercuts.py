#!/usr/bin/env python3
"""Deterministic papercut analysis for the /papercuts skill.

Reads the live papercut log plus its monthly archives, keeps the entries inside
a day window, attributes each entry to this repo (with grep evidence), another
repo, or an external tool, groups the whole log into root-cause clusters from
rules.json, and reports what has landed or is open against each cluster's
files. Read-only: it never writes the log.

    papercuts.py report [--days 7] [--today YYYY-MM-DD] [--offline]
"""

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path

SEPARATOR = " · "
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
SKILL_DIR = Path(__file__).resolve().parent.parent


def parse_log(path, label):
    """Return entries from one log file; header and malformed lines are skipped."""
    entries = []
    if not path.is_file():
        return entries
    for lineno, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        parts = line.split(SEPARATOR)
        if len(parts) < 5 or not DATE_RE.match(parts[0]):
            continue
        # The symptom or fix may itself contain the separator; the first two
        # fields and the last field are fixed, so fold any extras into the fix.
        entries.append({
            "id": f"{label}:{lineno}",
            "date": parts[0],
            "source": parts[1],
            "symptom": parts[2],
            "fix": SEPARATOR.join(parts[3:-1]),
            "project": parts[-1],
        })
    return entries


def load_entries(log, archive_dir):
    found = []
    if archive_dir.is_dir():
        for archive in sorted(archive_dir.glob("*.md")):
            found += parse_log(archive, f"archive/{archive.name}")
    found += parse_log(log, log.name)
    # An interrupted archive run leaves the same line in an archive and the
    # live log (archive-papercuts.sh recovers from that); count it once.
    entries, seen = [], set()
    for e in found:
        key = (e["date"], e["source"], e["symptom"], e["fix"], e["project"])
        if key not in seen:
            seen.add(key)
            entries.append(e)
    return entries


def grep_first(root, pattern, paths):
    """First `file:line` under root matching the fixed-string pattern, or None."""
    for rel in paths:
        target = root / rel
        files = sorted(p for p in target.rglob("*") if p.is_file()) if target.is_dir() else [target]
        for f in files:
            if not f.is_file() or "node_modules" in f.parts:
                continue
            try:
                lines = f.read_text(encoding="utf-8").splitlines()
            except (UnicodeDecodeError, OSError):
                continue
            for n, text in enumerate(lines, 1):
                if pattern in text:
                    return f"{f.relative_to(root)}:{n}"
    return None


def attribute(entry, rules, repo, repos_dir):
    """Owner is `ours` only with grep evidence from this repo's shipped config."""
    text = f"{entry['source']} {entry['symptom']}"
    for signal in rules["signals"]:
        for m in re.finditer(signal["match"], text, re.IGNORECASE):
            if signal["kind"] == "gate":
                gate_id = m.group(0)
                hit = grep_first(repo, f'"{gate_id}', signal["paths"]) or grep_first(repo, gate_id, signal["paths"])
                if not hit and "-" in gate_id:
                    base = gate_id.split("-")[0]
                    hit = grep_first(repo, f'"{base}', signal["paths"])
                if hit:
                    return "ours", f"gate {gate_id} → {hit}"
            elif signal["kind"] == "skill":
                name = next(g for g in m.groups() if g)
                skill_md = repo / "system-configs/.claude/skills" / name / "SKILL.md"
                if skill_md.is_file():
                    return "ours", f"skill {name} → {skill_md.relative_to(repo)}:1"
            elif signal["kind"] == "hookfile":
                hooks = repo / "system-configs/.claude/hooks"
                found = sorted(hooks.rglob(f"{m.group(0)}.*")) if hooks.is_dir() else []
                if found:
                    return "ours", f"hook {m.group(0)} → {found[0].relative_to(repo)}:1"
            else:
                hit = grep_first(repo, signal["evidence"], signal["paths"])
                if hit:
                    return "ours", f"{signal['name']} → {hit}"
    if entry["source"] in {p.name for p in (repo / "system-configs/.claude/skills").iterdir()}:
        skill_md = repo / "system-configs/.claude/skills" / entry["source"] / "SKILL.md"
        return "ours", f"skill {entry['source']} → {skill_md.relative_to(repo)}:1"
    first = re.split(r"[/\s]", entry["project"].strip(), maxsplit=1)[0]
    if first in (repo.name, "claude-config"):
        return "ours-unverified", "project path is this repo; no greppable signal"
    if first and (repos_dir / first).is_dir():
        return f"other:{first}", f"{repos_dir / first}"
    return "external", "no repo or shipped-config signal"


def git_lines(repo, args):
    try:
        out = subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return out.stdout.splitlines() if out.returncode == 0 else None


def open_prs(repo):
    try:
        out = subprocess.run(
            # No titles: PR text is untrusted, and this output reaches Claude
            # through a python3 command the untrusted-content gate doesn't
            # recognise. The skill reads titles with `gh pr view` instead.
            ["gh", "pr", "list", "--state", "open", "--limit", "100", "--json", "number,url,files"],
            cwd=repo, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    return json.loads(out.stdout or "[]")


def cluster(entries, rules, repo, offline):
    prs = None if offline else open_prs(repo)
    ref = "origin/main"
    if not offline:
        # A stale origin/main would hide a fix merged since the last fetch,
        # while open_prs() no longer lists it.
        git_lines(repo, ["fetch", "-q", "origin", "main"])
        if git_lines(repo, ["rev-parse", "--verify", "-q", ref]) is None:
            ref = "HEAD"
    clusters = []
    for rule in rules["clusters"]:
        rx = re.compile(rule["match"], re.IGNORECASE)
        scope = rule.get("scope")
        hits = [e for e in entries
                if rx.search(e["symptom"]) and (not scope or e["owner"] in scope)]
        if not hits:
            continue
        first = min(e["date"] for e in hits)
        c = {
            "key": rule["key"],
            "name": rule["name"],
            "owner": rule["owner"],
            "files": rule.get("files", []),
            "entries": [e["id"] for e in hits],
            "in_window": [e["id"] for e in hits if e.get("in_window")],
            "count": len(hits),
            "first": first,
            "last": max(e["date"] for e in hits),
            "commits_since_last": None,
            "open_prs": None,
        }
        if not offline and c["files"]:
            # Commits before the latest occurrence evidently did not fix it.
            c["commits_since_last"] = git_lines(
                repo, ["log", ref, f"--since={c['last']}", "--date=short", "--format=%h %ad %s", "--", *c["files"]])
            if prs is not None:
                c["open_prs"] = [
                    {"number": p["number"], "url": p["url"]}
                    for p in prs
                    if any(f["path"] in c["files"] for f in p.get("files", []))
                ]
        clusters.append(c)
    clusters.sort(key=lambda c: (c["owner"] != "ours", -len(c["in_window"]), -c["count"]))
    return clusters


def main():
    home = Path.home()
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("command", choices=["report"])
    ap.add_argument("--days", type=int, default=7)
    # papercut.sh stamps entries with `date -u`, so the window uses the UTC day.
    ap.add_argument("--today", default=dt.datetime.now(dt.timezone.utc).date().isoformat())
    ap.add_argument("--log", type=Path, default=Path(os.environ.get("PAPERCUT_LOG", home / ".claude/papercuts.md")))
    ap.add_argument("--archive-dir", type=Path,
                    default=Path(os.environ.get("PAPERCUT_ARCHIVE_DIR", home / ".claude/papercuts/archive")))
    ap.add_argument("--repo", type=Path, default=Path(os.environ.get("CLAUDE_CONFIG_REPO", home / "dev/claude-config")))
    ap.add_argument("--repos-dir", type=Path, default=home / "dev")
    ap.add_argument("--rules", type=Path, default=SKILL_DIR / "rules.json")
    ap.add_argument("--offline", action="store_true", help="skip git log and gh lookups")
    a = ap.parse_args()

    if not a.log.is_file():
        json.dump({"error": f"no papercut log at {a.log}; run on the laptop that owns it"}, sys.stdout)
        print()
        return 1
    if not (a.repo / "system-configs").is_dir():
        json.dump({"error": f"{a.repo} is not a claude-config checkout; pass --repo"}, sys.stdout)
        print()
        return 1

    rules = json.loads(a.rules.read_text(encoding="utf-8"))
    today = dt.date.fromisoformat(a.today)
    since = (today - dt.timedelta(days=a.days)).isoformat()
    entries = load_entries(a.log, a.archive_dir)
    for e in entries:
        e["in_window"] = since <= e["date"] <= a.today
        # Every entry gets an owner: cluster scopes filter on it across the whole log.
        e["owner"], e["evidence"] = attribute(e, rules, a.repo, a.repos_dir)

    window = [e for e in entries if e["in_window"]]
    owners = {}
    for e in window:
        owners[e["owner"]] = owners.get(e["owner"], 0) + 1
    clusters = cluster(entries, rules, a.repo, a.offline)
    clustered = {i for c in clusters for i in c["entries"]}

    json.dump({
        "window": {"since": since, "today": a.today, "days": a.days},
        "totals": {"log": len(entries), "window": len(window), "by_owner": owners},
        "entries": window,
        "clusters": [c for c in clusters if c["count"] >= 2],
        "unclustered_in_window": [e["id"] for e in window if e["id"] not in clustered],
    }, sys.stdout, indent=2, ensure_ascii=False)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
