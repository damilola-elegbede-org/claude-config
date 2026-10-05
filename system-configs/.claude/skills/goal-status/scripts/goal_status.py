#!/usr/bin/env python3
"""Read Claude Code /goal state from session transcripts.

/goal writes `goal_status` attachments into ~/.claude/projects/<slug>/<session>.jsonl:
  set:          {met: false, sentinel: true, condition}
  check:        {met: false, condition, reason}
  achieved:     {met: true, condition, reason, iterations, durationMs, tokens}
  impossible:   {met: false, failed: true, condition, reason, iterations, durationMs, tokens}
  cleared:      {met: true, sentinel: true, condition}

Subcommands:
  report [--session ID] [--all]      JSON report of goals (default: current session)
  criteria get --session ID --condition TEXT
  criteria set --session ID --condition TEXT --json '[...]'
  bar DONE TOTAL                     render a progress bar line
"""
import argparse
import glob
import hashlib
import json
import os
import sys
from datetime import datetime, timezone

PROJECTS = os.path.expanduser("~/.claude/projects")
PINS = os.environ.get("GOAL_STATUS_DIR") or os.path.expanduser("~/.claude/goal-status")
PAUSE_PREFIX = "Goal paused"


def die(msg):
    print(json.dumps({"error": msg}))
    sys.exit(1)


def session_file(sid):
    hits = glob.glob(os.path.join(PROJECTS, "*", f"{sid}.jsonl"))
    if not hits:
        die(f"no transcript found for session {sid}")
    return hits[0]


def parse_ts(ts):
    return datetime.fromisoformat(ts.replace("Z", "+00:00")) if ts else None


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(c.get("text", "") for c in content if isinstance(c, dict))
    return ""


def goals_in(path):
    goals, cur, proposed = [], None, set()
    for line in open(path, encoding="utf-8"):
        try:
            o = json.loads(line)
        except ValueError:
            continue
        ts = o.get("timestamp")
        if o.get("type") == "assistant":
            for c in o.get("message", {}).get("content", []) or []:
                if isinstance(c, dict) and c.get("type") == "tool_use" and c.get("name") == "ProposeGoal":
                    cond = (c.get("input") or {}).get("condition")
                    if cond:
                        proposed.add(cond.strip())
            continue
        if o.get("type") == "system" and cur and cur["state"] == "active":
            msg = text_of(o.get("content"))
            if PAUSE_PREFIX in msg:
                cur["paused"] = msg.strip()[:300]
            continue
        a = o.get("attachment") or {}
        if o.get("type") != "attachment" or a.get("type") != "goal_status":
            continue
        cond = a.get("condition", "")
        if a.get("sentinel") and not a.get("met"):
            if cur and cur["state"] == "active":
                cur["state"], cur["ended_at"] = "replaced", ts
            cur = {
                "condition": cond,
                "origin": "proposed by Claude" if cond.strip() in proposed else "typed /goal",
                "set_at": ts,
                "ended_at": None,
                "state": "active",
                "checks": [],
                "paused": None,
                "iterations": None,
                "duration_ms": None,
                "tokens": None,
            }
            goals.append(cur)
            continue
        if cur is None or cond != cur["condition"]:
            continue
        if a.get("sentinel") and a.get("met"):
            cur["state"], cur["ended_at"] = "cleared", ts
            continue
        cur["paused"] = None
        cur["checks"].append({"at": ts, "met": bool(a.get("met")), "reason": a.get("reason", "")})
        if a.get("met") or a.get("failed"):
            cur["state"] = "achieved" if a.get("met") else "impossible"
            cur["ended_at"] = ts
            cur["iterations"] = a.get("iterations")
            cur["duration_ms"] = a.get("durationMs")
            cur["tokens"] = a.get("tokens")
    now = datetime.now(timezone.utc)
    for g in goals:
        start = parse_ts(g["set_at"])
        end = parse_ts(g["ended_at"]) or now
        if g["duration_ms"] is None and start:
            g["duration_ms"] = int((end - start).total_seconds() * 1000)
        g["check_count"] = len(g["checks"])
        g["last_reason"] = g["checks"][-1]["reason"] if g["checks"] else None
        if g["state"] == "active" and g["paused"]:
            g["state"] = "paused"
    return goals


def cmd_report(args):
    sid = args.session or os.environ.get("CLAUDE_CODE_SESSION_ID")
    if not sid:
        die("no session id: pass --session or run inside Claude Code (CLAUDE_CODE_SESSION_ID)")
    path = session_file(sid)
    if not args.all:
        goals = goals_in(path)
        print(json.dumps({"session": sid, "transcript": path, "goals": goals}, indent=2))
        return
    rows = []
    files = sorted(glob.glob(os.path.join(os.path.dirname(path), "*.jsonl")), key=os.path.getmtime, reverse=True)
    for f in files[: args.limit]:
        for g in goals_in(f):
            g.pop("checks")
            rows.append({"session": os.path.basename(f)[:-6], **g})
    rows.sort(key=lambda r: r["set_at"] or "", reverse=True)
    print(json.dumps({"project_dir": os.path.dirname(path), "goals": rows}, indent=2))


def pin_path(sid):
    return os.path.join(PINS, f"{sid}.json")


def cond_key(condition):
    return hashlib.sha256(condition.strip().encode()).hexdigest()[:16]


def cmd_criteria(args):
    p = pin_path(args.session)
    pins = json.load(open(p)) if os.path.exists(p) else {}
    key = cond_key(args.condition)
    if args.action == "get":
        print(json.dumps(pins.get(key)))
        return
    criteria = json.loads(args.json)
    if not isinstance(criteria, list) or not 1 <= len(criteria) <= 7:
        die("criteria must be a JSON list of 1-7 items")
    if key in pins:
        die("criteria already pinned for this goal; they never change while the goal stands")
    os.makedirs(PINS, exist_ok=True)
    pins[key] = {"condition": args.condition, "pinned_at": datetime.now(timezone.utc).isoformat(), "criteria": criteria}
    json.dump(pins, open(p, "w"), indent=2)
    print(json.dumps(pins[key]))


def cmd_bar(args):
    done, total, width = args.done, max(args.total, 1), 24
    filled = round(width * done / total)
    print(f"{'█' * filled}{'░' * (width - filled)}  {done}/{args.total}  {round(100 * done / total)}%")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("report")
    r.add_argument("--session")
    r.add_argument("--all", action="store_true")
    r.add_argument("--limit", type=int, default=30, help="max transcripts scanned with --all")
    c = sub.add_parser("criteria")
    c.add_argument("action", choices=["get", "set"])
    c.add_argument("--session", required=True)
    c.add_argument("--condition", required=True)
    c.add_argument("--json")
    b = sub.add_parser("bar")
    b.add_argument("done", type=int)
    b.add_argument("total", type=int)
    args = ap.parse_args()
    {"report": cmd_report, "criteria": cmd_criteria, "bar": cmd_bar}[args.cmd](args)


if __name__ == "__main__":
    main()
