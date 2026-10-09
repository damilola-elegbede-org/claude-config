#!/usr/bin/env python3
"""Skill catalog for the Jev skill routers (A8 prompt-time, A9 action-time).

Lists every skill a session can invoke, from the same four sources Claude Code loads:
  user       ~/.claude/skills/<name>/SKILL.md
  project    <repo root>/.claude/skills/<name>/SKILL.md
  directory  <repo>/<dir>/.claude/skills/<name>/SKILL.md, applying only under <dir>
  plugin     skills/<name>/SKILL.md inside each enabled plugin's install path

Usage: skill-catalog.py <cwd> <out.json>
       skill-catalog.py --match <hook-input.json> <out.json>
Writes a JSON list of {name, base, desc, source, scope_dir, cmd, path, invokes}:
  name       what the Skill tool takes (directory skills: "<dir relative to cwd>:<base>",
             plugin skills: "<plugin>:<base>", the form Claude Code lists them under)
  cmd/path   triggers the skill declares in its frontmatter, under metadata.triggers:
               metadata:
                 triggers:
                   - "cmd:<regex matched against a Bash command>"
                   - "path:<glob matched against a Write/Edit target>"
  invokes    base names of trigger-bearing skills this skill's body runs as /<name>
             (an orchestrator such as /ship-it runs /commit, so loading it covers /commit)

--match (A9, PreToolUse): which skills declare a trigger for this tool call and are not already
running. Writes {"candidates": [...], "route": [...], "turn": "<id>"}: candidates match the call and
apply to its target; route drops those loaded (Skill tool, or a typed /command) since the last real
user message, including skills an orchestrator loaded then runs (its `invokes`).

Skips skills turned off in skillOverrides or marked disable-model-invocation: true.
Fails open: any error writes [] and exits 0. Results are cached for CACHE_TTL seconds per
(cwd, repo root) so a hook on every tool call does not re-walk the repository.
"""
import fnmatch
import hashlib
import json
import os
import re
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
CLAUDE = os.path.join(HOME, ".claude")
CACHE_DIR = os.path.join(CLAUDE, "jev-cache", "state")
CACHE_TTL = 300
PRUNE = {".git", "node_modules", "worktrees", ".venv", "venv", "dist", "build", ".tmp", ".next",
         "__pycache__", "vendor", "target"}
MAX_DEPTH = 6


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def load_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def frontmatter(text):
    """Return (fields, body). fields: top-level scalars plus metadata.triggers as a list."""
    if not text.startswith("---"):
        return {}, text
    end = text.find("\n---", 3)
    if end < 0:
        return {}, text
    head, body = text[3:end], text[end + 4:]
    fields, triggers = {}, []
    cur, block, in_meta, in_trig = None, [], False, False
    for line in head.splitlines():
        if not line.strip():
            continue
        indent = len(line) - len(line.lstrip())
        if indent == 0:
            if cur and block:
                fields[cur] = " ".join(block).strip()
            cur, block, in_trig = None, [], False
            key, _, val = line.partition(":")
            key, val = key.strip(), val.strip()
            in_meta = key == "metadata"
            if val in (">", ">-", "|", "|-", ">+", "|+"):
                cur = key
            else:
                fields[key] = val.strip("\"'")
        elif cur:
            block.append(line.strip())
        elif in_meta:
            s = line.strip()
            if indent <= 2 and s.startswith("triggers:"):
                in_trig = True
            elif in_trig and s.startswith("- "):
                triggers.append(s[2:].strip().strip("\"'"))
            elif indent <= 2:
                in_trig = False
    if cur and block:
        fields[cur] = " ".join(block).strip()
    fields["triggers"] = triggers
    return fields, body


def entry(skill_md, base_default, source, scope_dir, name):
    fields, body = frontmatter(read(skill_md))
    if str(fields.get("disable-model-invocation", "")).lower() == "true":
        return None
    base = fields.get("name") or base_default
    cmd = [t[4:] for t in fields.get("triggers", []) if t.startswith("cmd:")]
    path = [t[5:] for t in fields.get("triggers", []) if t.startswith("path:")]
    return {"name": name.replace("{base}", base), "base": base,
            "desc": (fields.get("description") or "")[:200], "source": source,
            "scope_dir": scope_dir, "cmd": cmd, "path": path, "_body": body}


def skill_dirs(root):
    try:
        names = sorted(os.listdir(root))
    except OSError:
        return []
    return [(n, os.path.join(root, n, "SKILL.md")) for n in names
            if os.path.isfile(os.path.join(root, n, "SKILL.md"))]


def repo_root(cwd):
    try:
        out = subprocess.run(["git", "-C", cwd, "rev-parse", "--show-toplevel"],
                             capture_output=True, text=True, timeout=3)
        return out.stdout.strip() if out.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def nested_skill_roots(top):
    """Every <dir>/.claude/skills under top (excluding top itself), pruned and depth-bounded."""
    found = []
    top_depth = top.rstrip(os.sep).count(os.sep)
    for dirpath, dirnames, _ in os.walk(top):
        depth = dirpath.count(os.sep) - top_depth
        dirnames[:] = [d for d in dirnames if d not in PRUNE and (d == ".claude" or not d.startswith(".") or d == ".github")]
        if depth >= MAX_DEPTH:
            dirnames[:] = []
        if os.path.basename(dirpath) == ".claude" and dirpath != os.path.join(top, ".claude"):
            sk = os.path.join(dirpath, "skills")
            if os.path.isdir(sk):
                found.append((os.path.dirname(dirpath), sk))
    return found


def enabled_plugins(top):
    enabled = {}
    for settings in (os.path.join(CLAUDE, "settings.json"),
                     os.path.join(top, ".claude", "settings.json") if top else "",
                     os.path.join(top, ".claude", "settings.local.json") if top else ""):
        if settings:
            enabled.update(load_json(settings).get("enabledPlugins") or {})
    installed = load_json(os.path.join(CLAUDE, "plugins", "installed_plugins.json"))
    installed = installed.get("plugins", installed) if isinstance(installed, dict) else {}
    out = []
    for key, on in enabled.items():
        if on is not True:
            continue
        recs = installed.get(key) or []
        recs = recs if isinstance(recs, list) else [recs]
        for rec in recs[:1]:
            path = isinstance(rec, dict) and rec.get("installPath")
            if path and os.path.isdir(os.path.join(path, "skills")):
                out.append((key.split("@", 1)[0], os.path.join(path, "skills")))
    return out


def build(cwd):
    top = repo_root(cwd)
    # The /skills menu writes skillOverrides to <repo>/.claude/settings.local.json; the narrower file wins.
    overrides = {}
    for path in [os.path.join(CLAUDE, "settings.json")] + (
            [os.path.join(top, ".claude", "settings.json"), os.path.join(top, ".claude", "settings.local.json")] if top else []):
        o = load_json(path).get("skillOverrides")
        overrides.update(o if isinstance(o, dict) else {})
    skills = []
    for base, md in skill_dirs(os.path.join(CLAUDE, "skills")):
        skills.append(entry(md, base, "user", "", "{base}"))
    if top:
        for base, md in skill_dirs(os.path.join(top, ".claude", "skills")):
            skills.append(entry(md, base, "project", top, "{base}"))
        for scope, root in nested_skill_roots(top):
            rel = os.path.relpath(scope, cwd)
            # Claude Code lists skills of the cwd or an ancestor under their plain name and qualifies
            # only those of a directory below the cwd, as "<dir relative to cwd>:<name>".
            name = "{base}" if rel == "." or rel.startswith("..") else rel + ":{base}"
            for base, md in skill_dirs(root):
                skills.append(entry(md, base, "directory", scope, name))
    for plugin, root in enabled_plugins(top):
        for base, md in skill_dirs(root):
            skills.append(entry(md, base, "plugin", "", plugin + ":{base}"))
    skills = [s for s in skills if s and overrides.get(s["name"]) != "off" and overrides.get(s["base"]) != "off"]
    routed = {s["base"] for s in skills if s["cmd"] or s["path"]}
    for s in skills:
        body = s.pop("_body")
        s["invokes"] = sorted(b for b in routed if b != s["base"] and re.search(r"(?<![\w/])/" + re.escape(b) + r"\b", body))
    return skills


_QUOTED = r"\"(?:[^\"\\]|\\.)*\"|'[^']*'"
# A quoted string, or a shell's -c script (bash -lc '...'), whose quoted body is a command that runs.
_QUOTED_OR_SHELL_C = re.compile(
    r"(?P<sh>(?<![\w./-])(?:[\w./~-]*/)?(?:ba|z|da|k)?sh\s+(?:-[A-Za-z]+\s+)*-[A-Za-z]*c[A-Za-z]*\s+)(?P<arg>"
    + _QUOTED + ")|" + _QUOTED, re.S)


def strip_quoted(cmd, depth=0):
    """Remove heredoc bodies, quoted strings and shell comments, so a commit message, PR body or
    comment that merely mentions a command is not mistaken for running it. A shell's -c script is
    kept (itself stripped), because that quoted body is what runs."""
    cmd = re.sub(r"<<-?\s*([\"']?)(\w+)\1.*?\n\s*\2\s*(\n|$)", " ", cmd, flags=re.S)

    def keep_script(m):
        if not m.group("sh") or depth >= 3:
            return '""'
        body = m.group("arg")[1:-1]
        if m.group("arg")[0] == '"':
            body = re.sub(r"\\(.)", r"\1", body)
        return m.group("sh") + strip_quoted(body, depth + 1) + " ;"

    # One left-to-right pass, so a "bash -c" that only appears inside a quoted string stays quoted.
    cmd = _QUOTED_OR_SHELL_C.sub(keep_script, cmd)
    # A comment starts at a # that begins a word (quotes are gone, so none hides inside a string).
    return re.sub(r"(^|[\s;&|()])#[^\n]*", r"\1", cmd)


def turn_state(transcript):
    """(turn id, loaded base names) since the last real user message in the transcript."""
    rows = []
    try:
        with open(transcript, "rb") as fh:
            fh.seek(0, 2)
            fh.seek(max(0, fh.tell() - 3000000))
            for raw in fh.read().decode("utf-8", "replace").splitlines():
                try:
                    rows.append(json.loads(raw))
                except ValueError:
                    pass
    except (OSError, TypeError):
        return "", set()
    start, turn = 0, ""
    for i, r in enumerate(rows):
        if r.get("type") != "user" or r.get("isMeta") or r.get("isCompactSummary"):
            continue
        c = (r.get("message") or {}).get("content")
        if isinstance(c, list):
            if any(isinstance(x, dict) and x.get("type") == "tool_result" for x in c):
                continue
            c = " ".join(x.get("text", "") for x in c if isinstance(x, dict))
        if isinstance(c, str) and c.strip() and not re.match(r"\s*<(local-command|bash-|task-notification)", c):
            start, turn = i, r.get("uuid") or str(i)
    loaded = set()
    for r in rows[start:]:
        c = (r.get("message") or {}).get("content")
        if isinstance(c, str):
            loaded.update(m.split(":")[-1] for m in re.findall(r"<command-name>/?([^<\s]+)</command-name>", c))
        elif isinstance(c, list):
            for x in c:
                if isinstance(x, dict) and x.get("type") == "tool_use" and x.get("name") == "Skill":
                    loaded.add(str((x.get("input") or {}).get("skill", "")).split(":")[-1].lstrip("/"))
                elif isinstance(x, dict) and x.get("type") == "text":
                    loaded.update(m.split(":")[-1] for m in re.findall(r"<command-name>/?([^<\s]+)</command-name>", x.get("text", "")))
    return turn, loaded


def under(path, scope):
    return not scope or (path + "/").startswith(scope.rstrip("/") + "/")


def match(hook_input, out):
    inp = load_json(hook_input)
    tool, ti = inp.get("tool_name", ""), inp.get("tool_input") or {}
    # Real paths throughout: git reports the resolved repo root, so a symlinked cwd (/var vs
    # /private/var on macOS) would otherwise fall outside every project and directory scope.
    cwd = os.path.realpath(inp.get("cwd") or os.getcwd())
    skills = load_catalog(cwd)
    top = repo_root(cwd)
    cands = []
    if tool == "Bash":
        cmd = strip_quoted(str(ti.get("command", "")))
        target = cwd
        for s in skills:
            if any(_search(rx, cmd) for rx in s["cmd"]):
                cands.append(s)
    else:
        target = str(ti.get("file_path") or ti.get("notebook_path") or "")
        if target and not os.path.isabs(target):
            target = os.path.join(cwd, target)
        target = os.path.realpath(target) if target else target
        rel = os.path.relpath(target, top) if top and target.startswith(top) else target
        for s in skills:
            if any(fnmatch.fnmatch(target, g) or fnmatch.fnmatch(rel, g) for g in s["path"]):
                cands.append(s)
    cands = [s for s in cands if under(target, s["scope_dir"])]
    # One per invocable name. Claude Code resolves a shared plain name personal over project, and a
    # plugin skill is invoked as <plugin>:<name>, so it never competes with a plain one.
    rank = lambda s: (s["source"] == "user", len(s["scope_dir"]))
    best = {}
    for s in cands:
        key = s["name"] if s["source"] == "plugin" else s["base"]
        cur = best.get(key)
        if cur is None or rank(s) > rank(cur):
            best[key] = s
    turn, loaded = turn_state(inp.get("transcript_path"))
    by_base = {s["base"]: s for s in skills}
    covered = set(loaded)
    for b in loaded:
        covered.update((by_base.get(b) or {}).get("invokes", []))
    route = [s for s in best.values() if s["base"] not in covered]
    slim = lambda s: {"name": s["name"], "base": s["base"], "source": s["source"], "desc": s["desc"][:160]}
    with open(out, "w", encoding="utf-8") as fh:
        json.dump({"candidates": [slim(s) for s in best.values()], "route": [slim(s) for s in route],
                   "loaded": sorted(covered), "turn": turn}, fh)


def _search(rx, text):
    try:
        return re.search(rx, text) is not None
    except re.error:
        return False


def signature(cwd):
    """Cheap change detector for the cache key: mtimes of the skill roots and settings files.
    Nested directory skill roots are not walked here (that is the cost the cache saves), so a new
    or edited directory-scoped skill shows up when the cache expires (CACHE_TTL)."""
    top = repo_root(cwd)
    parts = [cwd]
    for p in (os.path.join(CLAUDE, "skills"), os.path.join(CLAUDE, "settings.json"),
              os.path.join(CLAUDE, "plugins", "installed_plugins.json"),
              os.path.join(top, ".claude", "skills") if top else "",
              os.path.join(top, ".claude", "settings.json") if top else "",
              os.path.join(top, ".claude", "settings.local.json") if top else ""):
        try:
            parts.append("%s=%d" % (p, os.stat(p).st_mtime_ns))
        except OSError:
            parts.append(p + "=-")
    return "|".join(parts)


def load_catalog(cwd):
    key = hashlib.sha256(signature(cwd).encode()).hexdigest()[:16]
    cache = os.path.join(CACHE_DIR, "skills-" + key + ".json")
    if os.path.isfile(cache) and time.time() - os.path.getmtime(cache) < CACHE_TTL:
        cached = load_json(cache)
        if isinstance(cached, list) and cached:
            return cached
    result = build(cwd)
    os.makedirs(CACHE_DIR, mode=0o700, exist_ok=True)
    tmp = cache + ".%d" % os.getpid()
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(result, fh)
    os.replace(tmp, cache)
    # Each cwd or settings change keys a new file; drop the ones that expired a day ago.
    for name in os.listdir(CACHE_DIR):
        old = os.path.join(CACHE_DIR, name)
        try:
            if name.startswith("skills-") and time.time() - os.path.getmtime(old) > CACHE_TTL + 86400:
                os.remove(old)
        except OSError:
            pass
    return result


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "--match":
        try:
            match(sys.argv[2], sys.argv[3])
        except Exception:  # fail open: no route file means no routing
            pass
        return
    if len(sys.argv) != 3:
        return
    cwd, out = os.path.realpath(sys.argv[1]), sys.argv[2]
    try:
        result = load_catalog(cwd)
    except Exception:  # fail open: a broken catalog must never break a hook
        result = []
    try:
        with open(out, "w", encoding="utf-8") as fh:
            json.dump(result, fh)
    except OSError:
        pass


if __name__ == "__main__":
    main()
