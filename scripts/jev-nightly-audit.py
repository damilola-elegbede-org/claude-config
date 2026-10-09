#!/usr/bin/env python3
"""Nightly audit: which risky actions of a day did no gate block?

Usage:
  scripts/jev-nightly-audit.py [--date YYYY-MM-DD] [--projects DIR] [--dry-run] [--max-calls N]
                               [--threshold P] [--log PATH] [--out DIR] [--stdout]

  --date       the America/Denver day to audit (default: yesterday)
  --projects   Claude Code transcript root (default: ~/.claude/projects); reads <root>/*/*.jsonl
  --dry-run    make no Jev calls and write nothing; list what would be sent
  --max-calls  cap on Jev calls (default 1200); actions past the cap are listed as not scored
  --threshold  report an action when one of data_loss, irreversible, prod_system, outward_comms or
               spend scores at least this (default 0.8)
  --log        decision log used to find what the gates blocked (default ~/.claude/jev/decisions.jsonl)
  --out        report directory (default ~/.tmp/reports); the section goes into jev-daily-<date>.md
  --stdout     print the section instead of writing it

What is read: transcript events of the day (by event timestamp) and, from assistant tool_use blocks,
ONLY the Bash `command` string and the Write/Edit/MultiEdit `file_path`. Never tool results, file
contents, prompts or any other tool (so no Gmail or Slack content). An action is skipped when its cwd,
its path or a path inside its command falls under `exclude_paths` in jev-config.json. What is sent:
the redacted action text, its tool name and the repo directory name, one choice question (risk_class,
from gate-questions.json choice_questions) per distinct action through jev-ask with JEV_ORIGIN=audit.
The client allows one action per choice call, so there is no batching.

"Not blocked" means no deny or hit-enforce row in the decision log matches the action: by the logged
`action` text when the row has one, else by session and time (within 30 s). Standard library only.
"""
import argparse
import collections
import datetime
import glob
import importlib.util
import json
import os
import re
import shlex
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
RISKY = ("data_loss", "irreversible", "prod_system", "outward_comms", "spend")
SECTION = "## Nightly audit"
COMMAND_MAX = 1500
PATH_ACTION_TOOLS = ("Write", "Edit", "MultiEdit")
JOIN_WINDOW_S = 30
MAX_CONSECUTIVE_UNAVAILABLE = 5
CALL_TIMEOUT_S = 30


def _load_summary():
    spec = importlib.util.spec_from_file_location("jev_daily_summary", os.path.join(HERE, "jev-daily-summary.py"))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


S = _load_summary()

# ---------------------------------------------------------------- redaction
# The same patterns as jev_redact in hooks/jev-gate-lib.sh (perl), in the same order.
_REDACTIONS = [
    (re.compile(r"\b(?:sk|pk|rk)-[A-Za-z0-9_-]{16,}"), "[REDACTED]"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"), "[REDACTED]"),
    (re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}"), "[REDACTED]"),
    (re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"), "[REDACTED]"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "[REDACTED]"),
    (re.compile(r"\bglpat-[A-Za-z0-9_-]{16,}"), "[REDACTED]"),
    (re.compile(r"\b(Bearer|Basic|token)\s+[A-Za-z0-9._~+/=-]{12,}", re.I), r"\1 [REDACTED]"),
    (re.compile(r'(://)[^/\s:@\\"]+:[^/\s@\\"]+@'), r"\1[REDACTED]@"),
    (
        re.compile(
            r"(\b[A-Za-z0-9_]*(?:key|token|secret|passw(?:or)?d|pwd|credential)[A-Za-z0-9_]*\s*[=:]\s*(?:\\\"|\\')?)[^\s\"'\\]+",
            re.I,
        ),
        r"\1[REDACTED]",
    ),
    (re.compile(r"[A-Za-z0-9+_=-]{40,}"), "[REDACTED-LONG]"),
]


def redact(text):
    for rx, rep in _REDACTIONS:
        text = rx.sub(rep, text)
    return text


def trim(text, n=COMMAND_MAX):
    if len(text) <= n:
        return text
    return "%s ... %s" % (text[: n * 7 // 10], text[-(n * 3 // 10):])


# ---------------------------------------------------------------- egress exclusion


def exclude_prefixes(config_path):
    """Lower-cased absolute directory prefixes, same semantics as the client (client.mjs excludedPrefixes)."""
    try:
        with open(config_path, encoding="utf-8") as fh:
            entries = json.load(fh).get("exclude_paths") or []
    except (OSError, ValueError):
        return None
    home = os.path.expanduser("~")
    homes = {home, os.path.realpath(home)}
    out = set()
    for raw in entries:
        if not isinstance(raw, str) or not raw.strip():
            continue
        e = re.sub(r"(?:/\*{0,2})+$", "", raw.strip())
        if not e:
            continue
        if e.startswith("~"):
            rel = re.sub(r"^~/?", "", e)
        elif e.startswith("/"):
            rel = None
        else:
            rel = e
        bases = [e] if rel is None else [os.path.join(h, rel) if rel else h for h in homes]
        for b in bases:
            out.add(b.lower())
            out.add(os.path.realpath(b).lower())
    return out


_HEREDOC = re.compile(r"(?<!<)<<(?!<)-?\s*[\"']?([A-Za-z_][A-Za-z0-9_]*)")
HEREDOC_PLACEHOLDER = "[heredoc body omitted]"


def strip_heredocs(command):
    """Keep the command lines, replace each heredoc body (and its terminator) with a placeholder."""
    out, pending = [], []
    for line in command.split("\n"):
        if pending:
            if re.fullmatch(r"\s*" + re.escape(pending[0]) + r"\s*", line):
                pending.pop(0)
            continue
        out.append(line)
        pending = _HEREDOC.findall(line)
        if pending:
            out.append(HEREDOC_PLACEHOLDER)
    return "\n".join(out)


def under(path, prefixes):
    lc = path.lower()
    return any(lc == p or lc.startswith(p + "/") for p in prefixes)


def excluded(cwd, action_path, command, prefixes):
    for p in (cwd, action_path):
        if p and under(os.path.expanduser(p), prefixes):
            return True
    if command:
        lc = command.lower().replace("$home", os.path.expanduser("~").lower()).replace("~/", os.path.expanduser("~").lower() + "/")
        for p in prefixes:
            if re.search(r"(?<![a-z0-9_.-])" + re.escape(p) + r"(?:/|\b)", lc):
                return True
    if command and cwd:
        for p in command_paths(command, cwd):
            if under(p, prefixes) or under(os.path.realpath(p), prefixes):
                return True
    return False


def command_paths(command, cwd):
    """Every word of the command resolved against cwd (~ expanded); a word may or may not be a path."""
    try:
        lex = shlex.shlex(command, posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        words = list(lex)
    except ValueError:
        words = command.split()
    out = set()
    for w in words:
        if "=" in w:
            w = w.split("=", 1)[1]
        if not w or w.startswith("-") or w[0] in ";&|<>()":
            continue
        w = os.path.expanduser(w)
        out.add(os.path.normpath(w if os.path.isabs(w) else os.path.join(cwd, w)))
    return out


# ---------------------------------------------------------------- transcripts


def scan_transcripts(projects, day):
    """Yield dicts {tool, command|path, cwd, session, dt} for the day's Bash and Write/Edit tool_use blocks."""
    start, end = S.day_bounds(day)
    files = sorted(glob.glob(os.path.join(projects, "*", "*.jsonl")))
    scanned = 0
    out = []
    for f in files:
        try:
            if os.path.getmtime(f) < start.timestamp():
                continue
            fh = open(f, encoding="utf-8", errors="replace")
        except OSError:
            continue
        scanned += 1
        with fh:
            for line in fh:
                if '"tool_use"' not in line:
                    continue
                try:
                    ev = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(ev, dict) or ev.get("type") != "assistant":
                    continue
                dt = S.parse_ts(ev.get("timestamp"))
                if dt is None or not (start <= dt < end):
                    continue
                msg = ev.get("message")
                content = msg.get("content") if isinstance(msg, dict) else None
                if not isinstance(content, list):
                    continue
                cwd = ev.get("cwd") if isinstance(ev.get("cwd"), str) else ""
                session = ev.get("sessionId") or ev.get("session_id") or os.path.basename(f)[:-6]
                for b in content:
                    if not isinstance(b, dict) or b.get("type") != "tool_use":
                        continue
                    name, inp = b.get("name"), b.get("input")
                    if not isinstance(inp, dict):
                        continue
                    if name == "Bash" and isinstance(inp.get("command"), str) and inp["command"].strip():
                        out.append({"tool": "Bash", "command": inp["command"], "cwd": cwd, "session": session, "dt": dt})
                    elif name in PATH_ACTION_TOOLS and isinstance(inp.get("file_path"), str) and inp["file_path"]:
                        out.append({"tool": name, "path": inp["file_path"], "cwd": cwd, "session": session, "dt": dt})
    return out, scanned


def build_actions(raw, prefixes):
    """Apply exclusion, redaction and dedupe. Returns (actions, n_excluded)."""
    actions = collections.OrderedDict()
    n_excl = 0
    for r in sorted(raw, key=lambda r: r["dt"]):
        if r["tool"] == "Bash":
            r = dict(r, command=strip_heredocs(r["command"]))
        text = r.get("command") if r["tool"] == "Bash" else r["path"]
        if excluded(r["cwd"], r.get("path"), r.get("command"), prefixes):
            n_excl += 1
            continue
        red = trim(redact(text))
        # cwd is part of the identity: the same text in two directories is two actions, scored separately.
        key = (r["tool"], red, os.path.normpath(r["cwd"]) if r["cwd"] else "")
        a = actions.get(key)
        if a is None:
            a = actions[key] = {"tool": r["tool"], "text": red, "cwd": r["cwd"], "path": r.get("path"), "seen": []}
        a["seen"].append((r["session"], r["dt"]))
    return list(actions.values()), n_excl


# ---------------------------------------------------------------- Jev


def risk_question(questions_path):
    with open(questions_path, encoding="utf-8") as fh:
        doc = json.load(fh)
    q = (doc.get("audit_questions") or {}).get("risk_class") or doc["choice_questions"]["risk_class"]
    return {"risk_class": {"type": "choice", "instructions": q["instructions"], "criteria": q["criteria"]}}


def find_questions():
    for p in (
        os.environ.get("JEV_QUESTIONS", ""),
        os.path.join(REPO, "system-configs/.claude/hooks/jev/gate-questions.json"),
        os.path.expanduser("~/.claude/hooks/jev/gate-questions.json"),
    ):
        if p and os.path.isfile(p):
            return p
    return None


def find_config():
    for p in (
        os.environ.get("JEV_CONFIG", ""),
        os.path.join(REPO, "system-configs/.claude/hooks/jev/jev-config.json"),
        os.path.expanduser("~/.claude/hooks/jev/jev-config.json"),
    ):
        if p and os.path.isfile(p):
            return p
    return None


def request_for(action, questions):
    state = {"tool": action["tool"], "repo": os.path.basename(action["cwd"].rstrip("/")), "context": "audit"}
    # timeout_ms: without it jev-ask applies default_timeout_ms (1000), too short on a loaded machine
    req = {"rule": "audit/risk-class", "state": state, "questions": questions, "timeout_ms": 5000}
    if action["tool"] == "Bash":
        state["command"] = action["text"]
    else:
        state["path"] = action["text"]
        req["paths"] = [action["text"]]
    if action["cwd"]:
        req["cwd"] = action["cwd"]
    return req


def ask(req, jev_ask):
    """Return (probabilities dict | None, reason). None means unavailable."""
    env = dict(os.environ, JEV_ORIGIN="audit")
    try:
        p = subprocess.run([jev_ask], input=json.dumps(req), capture_output=True, text=True, timeout=CALL_TIMEOUT_S, env=env)
    except (OSError, subprocess.TimeoutExpired):
        return None, "unavailable"
    if p.returncode != 0:
        return None, "unavailable" if p.returncode == 3 else "error"
    try:
        ans = json.loads(p.stdout)["answers"]["risk_class"]
    except (ValueError, KeyError, TypeError):
        return None, "error"
    probs = ans.get("probabilities")
    if not isinstance(probs, dict):
        probs = {ans["choice"]: 1.0} if ans.get("choice") else None
    return probs, "ok"


def best_risk(probs):
    scored = [(float(probs.get(c) or 0), c) for c in RISKY]
    return max(scored)


# ---------------------------------------------------------------- join with the gates


TRUNC_LEN = 199  # the gate cuts `action` to 195 as head(136) + " ... " + tail(58); see jev_trim in jev-gate-lib.sh
TRUNC_HEAD = 136
TRUNC_MARK = " ... "


def _norm(text):
    return " ".join(redact(text).split())


def blocked_by(action, blocks, used=None):
    """True when every occurrence of the action is matched by its own block row: same session when the row
    has one, within JOIN_WINDOW_S, and by logged action text when the row has any (exact, or head and tail
    when the logged text is the gate's truncated form). Each block row satisfies at most one occurrence;
    `used` (a set of row indexes) is shared across actions and only updated when the whole action matched."""
    mine = " ".join(action["text"].split())
    taken = set(used) if used is not None else set()

    def text_matches(blk):
        logged = blk.get("action") if isinstance(blk.get("action"), str) else blk.get("target")
        if not (isinstance(logged, str) and logged):
            return None
        prefix = action["tool"] + " " if action["tool"] in PATH_ACTION_TOOLS else ""
        truncated = len(logged) == TRUNC_LEN and logged[TRUNC_HEAD:TRUNC_HEAD + len(TRUNC_MARK)] == TRUNC_MARK
        parts = (logged[:TRUNC_HEAD], logged[TRUNC_HEAD + len(TRUNC_MARK):]) if truncated else (logged, "")
        head = _norm(parts[0])
        if prefix and head.startswith(prefix):
            head = head[len(prefix):]
        if not truncated:
            return mine == head
        return mine.startswith(head) and mine.endswith(_norm(parts[1]))

    def matches(blk, session, dt):
        sid = blk.get("session_id")
        if sid and sid != session:
            return False
        if abs((blk["_dt"] - dt).total_seconds()) > JOIN_WINDOW_S:
            return False
        t = text_matches(blk)
        return bool(sid) if t is None else t

    for session, dt in sorted(action["seen"], key=lambda x: x[1]):
        cands = [(abs((b["_dt"] - dt).total_seconds()), i) for i, b in enumerate(blocks) if i not in taken and matches(b, session, dt)]
        if not cands:
            return False
        taken.add(min(cands)[1])
    if used is not None:
        used.update(taken)
    return True


# ---------------------------------------------------------------- report


def cell(text, n=110):
    t = " ".join(str(text).split())
    if len(t) > n:
        t = t[: n - 3] + "..."
    return t.replace("|", "\\|").replace("`", "'")


def render(day, st, flagged, blocked_hits):
    out = [SECTION, ""]
    out.append(
        "Transcripts scanned %d; actions extracted %d, skipped for excluded paths %d, distinct %d; "
        "Jev calls %d (unavailable %d, other errors %d), not scored %d."
        % (st["files"], st["extracted"], st["excluded"], st["distinct"], st["calls"], st["unavailable"], st["errors"], st["unscored"])
    )
    if st.get("aborted"):
        out.append("")
        out.append("Stopped early: Jev was unavailable %d calls in a row." % MAX_CONSECUTIVE_UNAVAILABLE)
    out.append("")
    out.append(
        "Reported: score >= %.2f on %s, and no gate block matched. %d risky action(s) were blocked and are not listed."
        % (st["threshold"], ", ".join(RISKY), blocked_hits)
    )
    out.append("")
    if flagged:
        out.append("| Time (MT) | Session | Class | Score | Tool | Action |")
        out.append("| --- | --- | --- | --- | --- | --- |")
        for f in flagged:
            session, dt = f["seen"][0]
            out.append(
                "| %s | %s | %s | %.2f | %s | %s |"
                % (dt.astimezone(S.TZ).strftime("%H:%M:%S"), str(session)[:8], f["cls"], f["score"], f["tool"], cell(f["text"]))
            )
    else:
        out.append("None.")
    out.append("")
    return "\n".join(out)


def write_section(out_dir, day, section):
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "jev-daily-%s.md" % day.isoformat())
    try:
        with open(path, encoding="utf-8") as fh:
            body = fh.read()
    except OSError:
        body = "# Jev daily summary %s\n\n" % day.isoformat()
    i = body.find(SECTION)
    if i >= 0:
        body = body[:i]
    if body and not body.endswith("\n\n"):
        body = body.rstrip("\n") + "\n\n"
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(body + section)
    return path


def write_notice(out_dir, day, flagged, blocked_hits, st, report):
    """jev-audit-latest.json: what the SessionStart hook audit-digest.sh flashes to D. Best effort."""
    top = [
        {"time": f["seen"][0][1].astimezone(S.TZ).strftime("%H:%M"), "cls": f["cls"], "score": round(f["score"], 2),
         "action": cell(f["text"], 70)}
        for f in flagged[:3]
    ]
    doc = {"date": day.isoformat(), "flagged": len(flagged), "blocked": blocked_hits, "aborted": bool(st.get("aborted")),
           "report": report, "top": top}
    try:
        with open(os.path.join(out_dir, "jev-audit-latest.json"), "w", encoding="utf-8") as fh:
            json.dump(doc, fh)
    except OSError:
        pass


def main(argv=None):
    ap = argparse.ArgumentParser(description="Nightly audit of unblocked risky actions")
    ap.add_argument("--date")
    ap.add_argument("--projects", default=os.path.expanduser("~/.claude/projects"))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--max-calls", type=int, default=1200)
    ap.add_argument("--threshold", type=float, default=0.8)
    ap.add_argument("--log", default=os.path.expanduser("~/.claude/jev/decisions.jsonl"))
    ap.add_argument("--out", default=os.path.expanduser("~/.tmp/reports"))
    ap.add_argument("--stdout", action="store_true")
    args = ap.parse_args(argv)
    if args.date and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", args.date):
        ap.error("--date must be YYYY-MM-DD")
    try:
        day = datetime.date.fromisoformat(args.date) if args.date else S.default_day()
    except ValueError:
        ap.error("--date is not a calendar date")
    if args.max_calls < 0:
        ap.error("--max-calls must be >= 0")

    cfg = find_config()
    prefixes = exclude_prefixes(cfg) if cfg else None
    if prefixes is None:
        print("jev-nightly-audit: jev-config.json unreadable; refusing to scan (the exclusion list is unknown)", file=sys.stderr)
        return 1
    qpath = find_questions()
    if not qpath:
        print("jev-nightly-audit: gate-questions.json not found", file=sys.stderr)
        return 1
    questions = risk_question(qpath)

    raw, nfiles = scan_transcripts(args.projects, day)
    actions, n_excl = build_actions(raw, prefixes)
    to_send, unscored = actions[: args.max_calls], max(0, len(actions) - args.max_calls)

    if args.dry_run:
        print("Dry run for %s: no Jev calls, nothing written." % day.isoformat())
        print(
            "transcripts scanned %d; actions extracted %d; skipped (excluded paths) %d; distinct %d; would send %d; over the cap %d"
            % (nfiles, len(raw), n_excl, len(actions), len(to_send), unscored)
        )
        print("rule audit/risk-class, question risk_class, origin audit. Redacted text that would be sent:")
        for a in to_send:
            print("%s\t%s" % (a["tool"], " ".join(a["text"].split())[:200]))
        return 0

    jev_ask = os.environ.get("JEV_ASK") or os.path.expanduser("~/.claude/hooks/jev/jev-ask")
    st = {
        "files": nfiles, "extracted": len(raw), "excluded": n_excl, "distinct": len(actions), "calls": 0,
        "unavailable": 0, "errors": 0, "unscored": unscored, "threshold": args.threshold, "aborted": False,
    }
    scored, streak = [], 0
    for i, a in enumerate(to_send):
        probs, reason = ask(request_for(a, questions), jev_ask)
        st["calls"] += 1
        if probs is None:
            st["unavailable" if reason == "unavailable" else "errors"] += 1
            streak += 1
            if streak >= MAX_CONSECUTIVE_UNAVAILABLE:
                st["aborted"] = True
                st["unscored"] += len(to_send) - i - 1
                break
            continue
        streak = 0
        score, cls = best_risk(probs)
        scored.append(dict(a, score=score, cls=cls))

    day_rows = S.load_rows(args.log, day)
    blocks = S.block_events(day_rows)
    flagged, blocked_hits, used_blocks = [], 0, set()
    for a in scored:
        if a["score"] < args.threshold:
            continue
        if blocked_by(a, blocks, used_blocks):
            blocked_hits += 1
        else:
            flagged.append(a)
    flagged.sort(key=lambda a: (-a["score"], a["seen"][0][1]))

    section = render(day, st, flagged, blocked_hits)
    if args.stdout:
        sys.stdout.write(section)
    else:
        path = write_section(args.out, day, section)
        write_notice(args.out, day, flagged, blocked_hits, st, path)
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
