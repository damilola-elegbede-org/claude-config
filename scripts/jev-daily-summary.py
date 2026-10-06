#!/usr/bin/env python3
"""One compact Markdown report of a day of Jev activity, read from the decision log.

Usage:
  scripts/jev-daily-summary.py [--date YYYY-MM-DD] [--log PATH] [--out DIR] [--stdout]

  --date    the America/Denver calendar day to report (default: yesterday)
  --log     decision log (default: ~/.claude/jev/decisions.jsonl)
  --out     output directory (default: ~/.tmp/reports); the file is jev-daily-<date>.md
  --stdout  print the report instead of writing the file

Reads only the decision log, which never holds prompts, commands or file text (gate rows carry an
`action` string that was already redacted when it was logged). Makes no Jev calls. Standard library only.

Sections: Jev calls (client rows), blocks (deny / hit-enforce) with rule and action, would-deny-shadow
per rule, bypasses (retry-after-deny), and the same counts split by origin (rows without an origin are
"unknown").
"""
import argparse
import collections
import datetime
import json
import math
import os
import re
import sys
from zoneinfo import ZoneInfo

TZ = ZoneInfo("America/Denver")
BLOCK_OUTCOMES = ("deny", "hit-enforce")
ACTION_MAX = 110
AUDIT_MARKER = "## Nightly audit"


def day_bounds(day):
    """(start, end) UTC datetimes of the Denver calendar day."""
    start = datetime.datetime.combine(day, datetime.time.min, tzinfo=TZ)
    end = datetime.datetime.combine(day + datetime.timedelta(days=1), datetime.time.min, tzinfo=TZ)
    utc = datetime.timezone.utc
    return start.astimezone(utc), end.astimezone(utc)


def parse_ts(value):
    if not isinstance(value, str):
        return None
    try:
        dt = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=datetime.timezone.utc)
    return dt


def load_rows(path, day):
    """Decision rows whose timestamp falls on `day` (Denver), each with a parsed `_dt`."""
    start, end = day_bounds(day)
    rows = []
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return rows
    with fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if not isinstance(row, dict):
                continue
            dt = parse_ts(row.get("ts"))
            if dt is None or not (start <= dt < end):
                continue
            row["_dt"] = dt
            rows.append(row)
    return rows


def percentile(values, q):
    if not values:
        return None
    s = sorted(values)
    k = max(0, min(len(s) - 1, math.ceil(q * len(s)) - 1))  # nearest rank
    return s[k]


def num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def origin_of(row):
    o = row.get("origin")
    return o if isinstance(o, str) and o else "unknown"


def readable_action(row):
    a = row.get("action")
    if not isinstance(a, str) or not a:
        a = row.get("target")
    if not isinstance(a, str) or not a:
        sha = row.get("action_sha")
        return "(action not logged%s)" % ((", sha " + sha) if sha else "")
    a = " ".join(a.split())
    if len(a) > ACTION_MAX:
        a = a[: ACTION_MAX - 3] + "..."
    return a


def cell(text):
    return str(text).replace("|", "\\|").replace("`", "'")


def is_client(row):
    return row.get("src") == "client"


def block_events(rows):
    """Deny and hit-enforce rows, one per blocked call. A Jev gate logs a hit-enforce row per matching gate
    and a deny row (gate "G1,G3" when several matched) for the same call. The call is identified without
    the gate id (session, action sha or text, second); the deny row wins, and hit-enforce rows without a
    deny merge into one event that lists every gate. Rows with no identity stay separate."""
    events = [r for r in rows if r.get("outcome") in BLOCK_OUTCOMES]

    def key(r):
        ident = r.get("action_sha") or r.get("target") or r.get("action")
        return (r.get("session_id"), ident, str(r.get("ts"))[:19]) if ident else None

    groups = collections.OrderedDict()
    out = []
    for r in events:
        k = key(r)
        if k is None:
            out.append(r)
        else:
            groups.setdefault(k, []).append(r)
    for g in groups.values():
        denies = [r for r in g if r["outcome"] == "deny"]
        if denies:
            out.append(denies[0])
            continue
        merged = dict(g[0])
        gates = []
        for r in g:
            for part in str(r.get("gate") or "").split(","):
                if part and part not in gates:
                    gates.append(part)
        if gates:
            merged["gate"] = ",".join(gates)
        out.append(merged)
    return out


def stats(rows):
    client = [r for r in rows if is_client(r)]
    unavail = [r for r in client if r.get("outcome") == "unavailable"]
    walls = [num(r.get("wall_ms")) for r in client if num(r.get("wall_ms")) is not None]
    cost = sum(num(r.get("cost_usd")) or 0 for r in client)
    return {
        "calls": len(client),
        "unavailable": len(unavail),
        "walls": walls,
        "cost": cost,
        "blocks": len(block_events(rows)),
        "shadow": sum(1 for r in rows if r.get("outcome") == "would-deny-shadow"),
        "bypass": sum(1 for r in rows if r.get("outcome") == "retry-after-deny"),
    }


def pct(n, d):
    return "%.1f%%" % (100.0 * n / d) if d else "n/a"


def ms(v):
    return "n/a" if v is None else "%d ms" % round(v)


def render(day, rows, log_path):
    s = stats(rows)
    out = []
    out.append("# Jev daily summary %s" % day.isoformat())
    out.append("")
    out.append("Day: %s America/Denver. Source: `%s` (%d rows)." % (day.isoformat(), log_path, len(rows)))
    out.append("")
    out.append("## Jev calls")
    out.append("")
    out.append("| Metric | Value |")
    out.append("| --- | --- |")
    out.append("| Calls (client rows) | %d |" % s["calls"])
    out.append("| Unavailable | %d (%s) |" % (s["unavailable"], pct(s["unavailable"], s["calls"])))
    out.append("| wall_ms p50 / p95 | %s / %s |" % (ms(percentile(s["walls"], 0.5)), ms(percentile(s["walls"], 0.95))))
    out.append("| Total cost | $%.4f |" % s["cost"])
    out.append("")

    blocks = block_events(rows)
    out.append("## Blocks (deny, hit-enforce)")
    out.append("")
    if blocks:
        out.append("| Time (MT) | Rule | Outcome | Origin | Action |")
        out.append("| --- | --- | --- | --- | --- |")
        for r in sorted(blocks, key=lambda r: r["_dt"]):
            out.append(
                "| %s | %s | %s | %s | %s |"
                % (
                    r["_dt"].astimezone(TZ).strftime("%H:%M:%S"),
                    cell(r.get("gate") or "?"),
                    cell(r.get("outcome")),
                    cell(origin_of(r)),
                    cell(readable_action(r)),
                )
            )
    else:
        out.append("None.")
    out.append("")

    shadow = collections.Counter(r.get("gate") or "?" for r in rows if r.get("outcome") == "would-deny-shadow")
    out.append("## Would-deny (shadow) per rule")
    out.append("")
    if shadow:
        out.append("| Rule | Count |")
        out.append("| --- | --- |")
        for rule, n in sorted(shadow.items(), key=lambda kv: (-kv[1], kv[0])):
            out.append("| %s | %d |" % (cell(rule), n))
    else:
        out.append("None.")
    out.append("")

    bypass = [r for r in rows if r.get("outcome") == "retry-after-deny"]
    out.append("## Bypasses (retry-after-deny)")
    out.append("")
    if bypass:
        counts = collections.Counter(r.get("gate") or "?" for r in bypass)
        out.append("%d retries after a deny: %s." % (len(bypass), ", ".join("%s x%d" % (k, v) for k, v in sorted(counts.items()))))
    else:
        out.append("None.")
    out.append("")

    out.append("## By origin")
    out.append("")
    by = collections.defaultdict(list)
    for r in rows:
        by[origin_of(r)].append(r)
    order = [o for o in ("live", "test", "replay") if o in by] + sorted(o for o in by if o not in ("live", "test", "replay"))
    if order:
        out.append("| Origin | Calls | Unavailable | p50 / p95 wall | Cost | Blocks | Shadow | Bypasses |")
        out.append("| --- | --- | --- | --- | --- | --- | --- | --- |")
        for o in order:
            t = stats(by[o])
            out.append(
                "| %s | %d | %d (%s) | %s / %s | $%.4f | %d | %d | %d |"
                % (
                    cell(o),
                    t["calls"],
                    t["unavailable"],
                    pct(t["unavailable"], t["calls"]),
                    ms(percentile(t["walls"], 0.5)),
                    ms(percentile(t["walls"], 0.95)),
                    t["cost"],
                    t["blocks"],
                    t["shadow"],
                    t["bypass"],
                )
            )
    else:
        out.append("No rows.")
    out.append("")
    return "\n".join(out)


def default_day():
    return datetime.datetime.now(TZ).date() - datetime.timedelta(days=1)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Daily Jev summary from the decision log")
    ap.add_argument("--date", help="YYYY-MM-DD (America/Denver); default yesterday")
    ap.add_argument("--log", default=os.path.expanduser("~/.claude/jev/decisions.jsonl"))
    ap.add_argument("--out", default=os.path.expanduser("~/.tmp/reports"))
    ap.add_argument("--stdout", action="store_true", help="print the report instead of writing it")
    args = ap.parse_args(argv)
    if args.date and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", args.date):
        ap.error("--date must be YYYY-MM-DD")
    try:
        day = datetime.date.fromisoformat(args.date) if args.date else default_day()
    except ValueError:
        ap.error("--date is not a calendar date")
    report = render(day, load_rows(args.log, day), args.log)
    if args.stdout:
        sys.stdout.write(report)
        return 0
    os.makedirs(args.out, exist_ok=True)
    path = os.path.join(args.out, "jev-daily-%s.md" % day.isoformat())
    # A re-run keeps the nightly audit section that jev-nightly-audit.py appended to this file.
    audit = ""
    try:
        with open(path, encoding="utf-8") as fh:
            old = fh.read()
        i = old.find(AUDIT_MARKER)
        if i >= 0:
            audit = old[i:]
    except OSError:
        pass
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(report + audit)
    print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
