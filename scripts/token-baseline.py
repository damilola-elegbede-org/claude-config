#!/usr/bin/env python3
"""Token baseline for Claude Code transcripts (Jev integration, Phase 3 baseline).

Reads every ~/.claude/projects/**/*.jsonl, de-duplicates assistant `usage` records by message id
(one API response is written once per content block, with identical usage), and reports per-session
input / cache_read / cache_write / output totals, the share held by the top 10% of sessions, and
medians. It also sizes the tool outputs that the Phase 3 context hooks (A1 Read trim, A2 Grep/Glob
rank, A3 Bash log trim) target, and estimates what replaying them from cache costs.

Definitions
- session   = a top-level <project>/<session-id>.jsonl; its subagent transcripts
              (<session-id>/subagents/*.jsonl) are rolled into it because the session paid for them.
              A "per-file" view (every .jsonl on its own) is also printed because the 2026-08-17
              model-selection report counted that way.
- weighted  = "input-equivalent tokens": input x1, cache_write x1.25, cache_read x0.1, output x5
              (the published ratios of Sonnet/Opus list prices; absolute $ depend on the model, so
              this is a relative signal, not a bill).
- Dedup is global by message id; the oldest file wins, so a resumed session that copies history does
  not double count.

Usage: scripts/token-baseline.py [--projects-dir DIR] [--out FILE] [--date YYYY-MM-DD]
"""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

FIELDS = ("input", "cache_read", "cache_write", "output")
USAGE_KEYS = {
    "input": "input_tokens",
    "cache_read": "cache_read_input_tokens",
    "cache_write": "cache_creation_input_tokens",
    "output": "output_tokens",
}
WEIGHTS = {"input": 1.0, "cache_write": 1.25, "cache_read": 0.1, "output": 5.0}
CHARS_PER_TOKEN = 4  # rough; used only for tool-output sizing


def weighted(t: dict) -> float:
    return sum(t[f] * WEIGHTS[f] for f in FIELDS)


def blank() -> dict:
    return {f: 0 for f in FIELDS} | {"msgs": 0}


def session_key(path: Path, root: Path) -> tuple[str, str]:
    """(project, session id) for a transcript path; subagent files map to their parent session."""
    rel = path.relative_to(root).parts
    project = rel[0]
    if len(rel) >= 3 and rel[2] == "subagents":
        return project, rel[1]
    return project, path.stem


def pct(part: float, whole: float) -> str:
    return f"{(100.0 * part / whole):.1f}%" if whole else "n/a"


def human(n: float) -> str:
    for unit, div in (("B", 1e9), ("M", 1e6), ("k", 1e3)):
        if abs(n) >= div:
            return f"{n / div:,.2f}{unit}"
    return f"{n:,.0f}"


def quantile(sorted_vals: list[float], q: float) -> float:
    if not sorted_vals:
        return 0.0
    idx = min(len(sorted_vals) - 1, max(0, int(round(q * (len(sorted_vals) - 1)))))
    return sorted_vals[idx]


def tool_candidate(result: dict) -> tuple[str, int, int] | None:
    """Classify a toolUseResult as an A1/A2/A3 target. Returns (rule, lines, chars) or None."""
    if not isinstance(result, dict):
        return None
    f = result.get("file")
    if isinstance(f, dict) and isinstance(f.get("content"), str):
        n = f.get("numLines") or f["content"].count("\n") + 1
        # startLine == 1 and a full-length window approximates "no offset/limit given"
        if n > 400 and (f.get("startLine") or 1) == 1:
            return "A1 Read >400 lines, no offset", n, len(f["content"])
        return None
    out = result.get("stdout")
    if isinstance(out, str):
        n = out.count("\n") + 1
        if n > 300:
            return "A3 Bash >300 lines", n, len(out)
        return None
    content = result.get("content")
    if isinstance(content, str) and result.get("mode") == "content":
        n = content.count("\n") + 1
        if n > 100:
            return "A2 Grep/Glob >100 hits", n, len(content)
        return None
    names = result.get("filenames")
    if isinstance(names, list) and len(names) > 100:
        return "A2 Grep/Glob >100 hits", len(names), sum(len(x) + 1 for x in names if isinstance(x, str))
    return None


def scan(root: Path):
    files = sorted(root.rglob("*.jsonl"), key=lambda p: p.stat().st_mtime)
    seen: dict[str, tuple[tuple[str, str], str, dict, str]] = {}  # msg id -> (session, file, usage, model)
    candidates = []  # (rule, tokens, remaining_turns)
    seen_uuid: set[str] = set()
    first_ts = last_ts = None
    bad_lines = 0
    raw_assistant = 0
    for path in files:
        key = session_key(path, root)
        fkey = str(path.relative_to(root))
        asst_in_file = 0
        pending: list[tuple[str, int, int]] = []  # (rule, chars, asst_before)
        try:
            fh = path.open("r", encoding="utf-8", errors="replace")
        except OSError:
            continue
        with fh:
            for line in fh:
                if '"usage"' not in line and '"toolUseResult"' not in line:
                    continue
                try:
                    d = json.loads(line)
                except ValueError:
                    bad_lines += 1
                    continue
                ts = d.get("timestamp")
                if isinstance(ts, str):
                    first_ts = ts if first_ts is None or ts < first_ts else first_ts
                    last_ts = ts if last_ts is None or ts > last_ts else last_ts
                kind = d.get("type")
                if kind == "assistant":
                    msg = d.get("message") or {}
                    usage = msg.get("usage")
                    model = msg.get("model") or "unknown"
                    if not isinstance(usage, dict) or model == "<synthetic>":
                        continue
                    mid = msg.get("id") or d.get("uuid")
                    if not mid:
                        continue
                    raw_assistant += 1
                    if mid not in seen:
                        asst_in_file += 1
                        seen[mid] = (key, fkey, {f: 0 for f in FIELDS}, model)
                    u = seen[mid][2]
                    for f in FIELDS:
                        v = usage.get(USAGE_KEYS[f]) or 0
                        if isinstance(v, int) and v > u[f]:
                            u[f] = v  # a response is written once per content block: keep the max
                elif kind == "user" and "toolUseResult" in d:
                    uid = d.get("uuid")
                    if uid and uid in seen_uuid:
                        continue
                    if uid:
                        seen_uuid.add(uid)
                    cand = tool_candidate(d.get("toolUseResult"))
                    if cand:
                        rule, _lines, chars = cand
                        pending.append((rule, chars, asst_in_file))
        for rule, chars, before in pending:
            candidates.append((rule, chars // CHARS_PER_TOKEN, max(0, asst_in_file - before)))
    return seen, candidates, first_ts, last_ts, len(files), bad_lines, raw_assistant


def build_report(root: Path, date: str) -> tuple[str, list[str]]:
    seen, candidates, first_ts, last_ts, nfiles, bad, raw_assistant = scan(root)
    sessions: dict[tuple[str, str], dict] = defaultdict(blank)
    per_file: dict[str, dict] = defaultdict(blank)
    models: dict[str, dict] = defaultdict(blank)
    for _mid, (key, fkey, u, model) in seen.items():
        for agg in (sessions[key], per_file[fkey], models[model]):
            for f in FIELDS:
                agg[f] += u[f]
            agg["msgs"] += 1

    total = blank()
    for s in sessions.values():
        for f in FIELDS:
            total[f] += s[f]
        total["msgs"] += s["msgs"]
    tot_tokens = sum(total[f] for f in FIELDS)
    tot_w = weighted(total)
    input_side = total["input"] + total["cache_read"] + total["cache_write"]

    def dist(rows: list[dict]) -> dict:
        out = {}
        for name, fn in (
            ("all tokens", lambda r: sum(r[f] for f in FIELDS)),
            ("input", lambda r: r["input"]),
            ("cache_read", lambda r: r["cache_read"]),
            ("cache_write", lambda r: r["cache_write"]),
            ("output", lambda r: r["output"]),
            ("weighted", weighted),
            ("messages", lambda r: r["msgs"]),
        ):
            vals = sorted(fn(r) for r in rows)
            out[name] = (
                statistics.median(vals) if vals else 0,
                quantile(vals, 0.75), quantile(vals, 0.90), quantile(vals, 0.99), vals[-1] if vals else 0,
            )
        return out

    def top_share(rows: list[dict], frac: float, fn) -> tuple[int, float]:
        vals = sorted((fn(r) for r in rows), reverse=True)
        k = max(1, int(round(len(vals) * frac)))
        whole = sum(vals)
        return k, (sum(vals[:k]) / whole if whole else 0.0)

    srows = list(sessions.values())
    frows = list(per_file.values())
    k_tok, sh_tok = top_share(srows, 0.10, lambda r: sum(r[f] for f in FIELDS))
    _, sh_w = top_share(srows, 0.10, weighted)
    _, sh_cr = top_share(srows, 0.10, lambda r: r["cache_read"])
    _, sh_top1 = top_share(srows, 0.01, weighted)
    kf, shf_w = top_share(frows, 0.10, weighted)
    _, shf_cr = top_share(frows, 0.10, lambda r: r["cache_read"])
    d = dist(srows)
    df = dist(frows)

    # tool-output opportunity (upper bound: ignores compaction, which drops old outputs from context)
    by_rule: dict[str, list[int]] = defaultdict(lambda: [0, 0, 0.0])
    for rule, toks, remaining in candidates:
        r = by_rule[rule]
        r[0] += 1
        r[1] += toks
        r[2] += toks * (WEIGHTS["cache_write"] + WEIGHTS["cache_read"] * remaining)
    cand_w = sum(v[2] for v in by_rule.values())

    L: list[str] = []
    L.append(f"# Token baseline ({date})")
    L.append("")
    L.append(
        f"Scope: this laptop's Claude Code transcripts under `~/.claude/projects` — {nfiles} transcript files, "
        f"{len(sessions)} sessions (subagent transcripts rolled into their parent), "
        f"{total['msgs']:,} de-duplicated API responses, {(first_ts or '?')[:10]} to {(last_ts or '?')[:10]}. "
        "Not in scope: the BareClaude fleet, anything not run through these transcripts. "
        f"Generated by `scripts/token-baseline.py` ({bad} unparseable lines skipped)."
    )
    L.append("")
    L.append("## Headline")
    L.append("")
    L.append(f"- **{pct(input_side, tot_tokens)} of all tokens are input-side** "
             f"(cache_read {pct(total['cache_read'], tot_tokens)}, cache_write {pct(total['cache_write'], tot_tokens)}, "
             f"uncached input {pct(total['input'], tot_tokens)}); output is {pct(total['output'], tot_tokens)}.")
    L.append(f"- By relative price (input-equivalent tokens), **cache_read is {pct(total['cache_read'] * WEIGHTS['cache_read'], tot_w)}, "
             f"cache_write {pct(total['cache_write'] * WEIGHTS['cache_write'], tot_w)}, output {pct(total['output'] * WEIGHTS['output'], tot_w)}, "
             f"uncached input {pct(total['input'], tot_w)}** of weighted spend. The bill is context replay.")
    L.append(f"- **Top 10% of sessions ({k_tok} of {len(sessions)}) hold {sh_w * 100:.1f}% of weighted spend, "
             f"{sh_tok * 100:.1f}% of all tokens, {sh_cr * 100:.1f}% of cache_read.** Top 1% hold {sh_top1 * 100:.1f}% of weighted spend.")
    L.append(f"- **Median session: {human(d['all tokens'][0])} tokens** "
             f"(input {human(d['input'][0])}, cache_read {human(d['cache_read'][0])}, cache_write {human(d['cache_write'][0])}, "
             f"output {human(d['output'][0])}; {d['messages'][0]:,.0f} responses). p90 {human(d['all tokens'][2])}, max {human(d['all tokens'][4])}.")
    L.append(f"- Cache replay ratio: {total['cache_read'] / max(1, total['output']):,.0f} cache_read tokens per output token.")
    if cand_w:
        L.append(f"- Upper bound on what Phase 3 A1-A3 can touch: tool outputs above the hook thresholds account for "
                 f"**{pct(cand_w, tot_w)} of weighted spend** (their one-time cache write plus replay on every later turn).")
    L.append("")
    L.append("## Totals")
    L.append("")
    L.append("| Component | Tokens | Share of tokens | Weighted (input-equiv.) | Share of weighted |")
    L.append("| --- | ---: | ---: | ---: | ---: |")
    for f in ("cache_read", "cache_write", "output", "input"):
        L.append(f"| {f} | {human(total[f])} | {pct(total[f], tot_tokens)} | {human(total[f] * WEIGHTS[f])} | {pct(total[f] * WEIGHTS[f], tot_w)} |")
    L.append(f"| **total** | **{human(tot_tokens)}** | | **{human(tot_w)}** | |")
    L.append("")

    def dist_table(title: str, dd: dict, n: int) -> None:
        L.append(f"## {title} (n={n})")
        L.append("")
        L.append("| Metric | median | p75 | p90 | p99 | max |")
        L.append("| --- | ---: | ---: | ---: | ---: | ---: |")
        for name, row in dd.items():
            L.append(f"| {name} | " + " | ".join(human(v) for v in row) + " |")
        L.append("")

    dist_table("Per-session distribution (subagents rolled in)", d, len(srows))
    dist_table("Per-file distribution (every transcript file on its own; comparable to the 2026-08-17 report)", df, len(frows))
    L.append(f"Per-file concentration: top 10% of files ({kf}) hold {shf_w * 100:.1f}% of weighted spend and {shf_cr * 100:.1f}% of cache_read.")
    L.append("")

    top = sorted(sessions.items(), key=lambda kv: weighted(kv[1]), reverse=True)[:10]
    L.append("## Top 10 sessions by weighted spend")
    L.append("")
    L.append("| # | project | session | responses | cache_read | cache_write | output | share of weighted |")
    L.append("| ---: | --- | --- | ---: | ---: | ---: | ---: | ---: |")
    for i, ((proj, sid), r) in enumerate(top, 1):
        L.append(f"| {i} | `{proj[-40:]}` | `{sid[:8]}` | {r['msgs']:,} | {human(r['cache_read'])} | "
                 f"{human(r['cache_write'])} | {human(r['output'])} | {pct(weighted(r), tot_w)} |")
    L.append("")

    L.append("## By model")
    L.append("")
    L.append("| model | responses | cache_read | output | share of weighted |")
    L.append("| --- | ---: | ---: | ---: | ---: |")
    for m, r in sorted(models.items(), key=lambda kv: weighted(kv[1]), reverse=True)[:8]:
        L.append(f"| {m} | {r['msgs']:,} | {human(r['cache_read'])} | {human(r['output'])} | {pct(weighted(r), tot_w)} |")
    L.append("")

    L.append("## Phase 3 target: oversized tool outputs")
    L.append("")
    L.append("Tool outputs that the A1/A2/A3 hooks would consider. Replay cost = one cache write plus a cache read on "
             "every later response in the same transcript (ignores compaction, so this is an **upper bound**; tokens = chars/4).")
    L.append("")
    L.append("| hook target | outputs | tokens | replay-weighted (input-equiv.) | share of all weighted spend |")
    L.append("| --- | ---: | ---: | ---: | ---: |")
    for rule, (n, toks, w) in sorted(by_rule.items()):
        L.append(f"| {rule} | {n:,} | {human(toks)} | {human(w)} | {pct(w, tot_w)} |")
    L.append("")
    L.append("## Method and caveats")
    L.append("")
    L.append("- `usage` is read from assistant records and de-duplicated globally by `message.id` (max per field), oldest file first. "
             f"Here {raw_assistant:,} assistant records collapse to {len(seen):,} unique responses ({raw_assistant / max(1, len(seen)):.1f}x): "
             "any tally that counts assistant lines instead of message ids overstates volume by that factor "
             "(inference: the 2026-08-17 report's turn counts look line-based, so its absolute numbers are not comparable; shares are).")
    L.append("- Weights are list-price ratios (input 1, cache_write 1.25 for 5-minute TTL, cache_read 0.1, output 5). 1-hour cache writes "
             "cost 2x input, so cache_write is slightly understated.")
    L.append("- Tool-output candidates are classified from `toolUseResult` records. A1 uses `startLine == 1` as a proxy for \"no offset\" "
             "(the hook itself checks the real tool input).")
    L.append("- This measures the laptop only. After A1-A8 ship in enforce mode, re-run this script and compare the weighted totals and the tool-output table.")
    L.append("")
    headline = [ln for ln in L[L.index("## Headline") + 2: L.index("## Totals") - 1] if ln.startswith("- ")]
    return "\n".join(L), headline


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--projects-dir", default=str(Path.home() / ".claude" / "projects"))
    ap.add_argument("--date", default=datetime.now().strftime("%Y-%m-%d"))
    ap.add_argument("--out", default=None)
    args = ap.parse_args()
    root = Path(args.projects_dir).expanduser()
    if not root.is_dir():
        print(f"projects dir not found: {root}", file=sys.stderr)
        return 1
    out = Path(args.out).expanduser() if args.out else Path.home() / ".tmp" / "reports" / f"token-baseline-{args.date}.md"
    report, headline = build_report(root, args.date)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(report + "\n", encoding="utf-8")
    print(f"wrote {out}")
    print("\n".join(headline))
    return 0


if __name__ == "__main__":
    sys.exit(main())
