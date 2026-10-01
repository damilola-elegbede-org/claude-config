#!/usr/bin/env python3
"""Skill-description overlap test.

For every enabled skill (system-configs/.claude/skills/*/SKILL.md whose name is not
"off" in settings.json skillOverrides) the fixture tests/fixtures/skill-prompts.json
holds a few realistic prompts. Each prompt is put to Jev ONCE as a `choice` question
over all enabled skills (criteria = each skill's description); the prompt's own skill
is the expected answer. Prompts routed to a different skill, or whose probability
mass leaks onto one, mark that PAIR of skills as colliding: their descriptions are
not distinguishable enough. One call per prompt (not per pair): ~60 calls for 20 skills.

Usage:
  python3 scripts/skill-overlap.py [--out FILE] [--max-calls 150] [--dry-run]
  python3 scripts/skill-overlap.py --self-test

Jev client: $JEV_ASK, else ~/.claude/hooks/jev/jev-ask (contract: request JSON on
stdin, response JSON on stdout, exit 3 = unavailable). JEV_MOCK works through the
real client. Tests use a stub via JEV_ASK; CI never reaches the Gateway.
"""
import argparse
import datetime
import itertools
import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SKILLS_DIR = ROOT / "system-configs/.claude/skills"
SETTINGS = ROOT / "system-configs/.claude/settings.json"
FIXTURE = ROOT / "tests/fixtures/skill-prompts.json"
LEAK = 0.2  # mean probability mass on another skill that counts as a collision


def parse_frontmatter(text):
    m = re.match(r"^---\n(.*?)\n---\n", text, re.S)
    if not m:
        return {}
    out, key, buf = {}, None, []
    for line in m.group(1).split("\n"):
        km = re.match(r"^([A-Za-z_-]+):\s*(.*)$", line)
        if km and not line.startswith(" "):
            if key:
                out[key] = " ".join(buf).strip()
            key, val = km.group(1), km.group(2).strip()
            buf = [] if val in (">", ">-", "|", "|-") else [val.strip("\"'")]
        elif key:
            buf.append(line.strip())
    if key:
        out[key] = " ".join(buf).strip()
    return out


def enabled_skills():
    overrides = json.loads(SETTINGS.read_text(encoding="utf-8")).get("skillOverrides", {})
    skills = {}
    for d in sorted(SKILLS_DIR.iterdir()):
        f = d / "SKILL.md"
        if not f.is_file():
            continue
        fm = parse_frontmatter(f.read_text(encoding="utf-8"))
        name = fm.get("name", d.name)
        if overrides.get(name) == "off" or overrides.get(d.name) == "off":
            continue
        skills[name] = fm.get("description", "")
    return skills


def tokens(s):
    return {w for w in re.findall(r"[a-z]{4,}", s.lower())} - {"when", "this", "that", "with", "from", "use", "uses", "using", "into", "your"}


def jaccard(a, b):
    ta, tb = tokens(a), tokens(b)
    return len(ta & tb) / len(ta | tb) if ta | tb else 0.0


def ask_jev(prompt, skills, jev):
    req = {
        "rule": "skill-overlap",
        "state": {"prompt": prompt},
        "questions": {"skill": {
            "type": "choice",
            "instructions": "Which single skill should handle this user request?",
            "criteria": {n: (d[:400] or n) for n, d in skills.items()},
        }},
        "timeout_ms": 5000,
    }
    p = subprocess.run([jev], input=json.dumps(req), capture_output=True, text=True, timeout=30)
    if p.returncode == 3:
        raise RuntimeError("Jev unavailable (exit 3)")
    if p.returncode != 0:
        raise RuntimeError(f"jev-ask exit {p.returncode}: {p.stderr[:200]}")
    ans = json.loads(p.stdout)["answers"]["skill"]
    probs = ans.get("probabilities") or {ans["choice"]: 1.0}
    return ans["choice"], probs


def analyse(rows, skills):
    """rows: [(expected, prompt, choice, probs)] -> (accuracy, pair_stats)."""
    acc = defaultdict(lambda: [0, 0])
    routed = defaultdict(int)  # (expected, chosen) -> n
    mass = defaultdict(list)  # (expected, other) -> [p]
    examples = defaultdict(list)
    for exp, prompt, choice, probs in rows:
        acc[exp][1] += 1
        if choice == exp:
            acc[exp][0] += 1
        else:
            routed[(exp, choice)] += 1
            examples[(exp, choice)].append(prompt)
        for other in skills:
            if other != exp:
                mass[(exp, other)].append(float(probs.get(other, 0.0)))
    pairs = []
    for a, b in itertools.combinations(sorted(skills), 2):
        ab, ba = routed.get((a, b), 0), routed.get((b, a), 0)
        pab = sum(mass[(a, b)]) / max(len(mass[(a, b)]), 1)
        pba = sum(mass[(b, a)]) / max(len(mass[(b, a)]), 1)
        score = ab + ba + pab + pba
        collide = ab or ba or pab >= LEAK or pba >= LEAK
        pairs.append({"a": a, "b": b, "a_to_b": ab, "b_to_a": ba, "p_ab": pab, "p_ba": pba,
                      "desc": jaccard(skills[a], skills[b]), "score": score, "collide": bool(collide),
                      "examples": (examples.get((a, b), []) + examples.get((b, a), []))[:1]})
    pairs.sort(key=lambda p: -p["score"])
    return acc, pairs


def table(header, rows):
    widths = [max(len(header[i]), *(len(r[i]) for r in rows)) if rows else len(header[i]) for i in range(len(header))]
    f = lambda c: "| " + " | ".join(x.ljust(widths[i]) for i, x in enumerate(c)) + " |"
    return "\n".join([f(header), "| " + " | ".join("-" * w for w in widths) + " |"] + [f(r) for r in rows])


def report(rows, skills, calls, source):
    acc, pairs = analyse(rows, skills)
    hit = sum(v[0] for v in acc.values())
    total = sum(v[1] for v in acc.values())
    coll = [p for p in pairs if p["collide"]]
    parts = [
        f"# Skill overlap — {datetime.date.today().isoformat()}",
        "",
        f"Source: {source}. {len(skills)} enabled skills, {total} prompts, {calls} Jev calls "
        f"(one `choice` per prompt over all skills), {len(pairs)} skill pairs.",
        "",
        f"Routing accuracy: **{hit}/{total}** prompts landed on the skill they were written for. "
        f"A pair collides when a prompt of one routes to the other, or the other takes a mean >= {LEAK:.0%} of the probability.",
        "",
        f"## Colliding pairs ({len(coll)} of {len(pairs)})",
        "",
    ]
    if coll:
        parts.append(table(
            ["Skill A", "Skill B", "A→B", "B→A", "mean P(B|A)", "mean P(A|B)", "Description word overlap", "Example misrouted prompt"],
            [[p["a"], p["b"], str(p["a_to_b"]), str(p["b_to_a"]), f"{p['p_ab']:.2f}", f"{p['p_ba']:.2f}",
              f"{p['desc']:.2f}", (p["examples"][0][:70].replace("|", "/") if p["examples"] else "-")] for p in coll]))
    else:
        parts.append("None: every prompt routed to its own skill with leakage below the threshold.")
    parts += ["", f"{len(pairs) - len(coll)} pairs showed no collision signal.", "", "## Per-skill accuracy", ""]
    parts.append(table(["Skill", "Correct", "Prompts"],
                       [[n, str(a[0]), str(a[1])] for n, a in sorted(acc.items(), key=lambda kv: kv[1][0] / max(kv[1][1], 1))]))
    parts += ["", "## How to read this", "",
              "- A→B is how many of A's prompts Jev sent to B. Probability columns catch near-misses the top choice hides.",
              "- Fix a collision by sharpening the `description:` of the weaker skill (trigger phrases that only it owns), then re-run.",
              "- This measures Jev's reading of the descriptions, not Claude's skill selector; use it as a smell test.", ""]
    return "\n".join(parts)


def self_test():
    fm = parse_frontmatter("---\nname: x\ndescription: >-\n  one\n  two\nlicense: y\n---\nbody")
    assert fm == {"name": "x", "description": "one two", "license": "y"}, fm
    fm = parse_frontmatter('---\nname: y\ndescription: "quoted: yes"\n---\n')
    assert fm["description"] == "quoted: yes", fm
    skills = {"a": "alpha commit things", "b": "beta push things", "c": "gamma docs"}
    rows = [("a", "p1", "a", {"a": 0.9, "b": 0.1}), ("a", "p2", "b", {"a": 0.4, "b": 0.6}),
            ("b", "p3", "b", {"b": 0.95, "a": 0.05}), ("c", "p4", "c", {"c": 1.0})]
    acc, pairs = analyse(rows, skills)
    assert acc["a"] == [1, 2] and acc["c"] == [1, 1], acc
    top = pairs[0]
    assert (top["a"], top["b"], top["a_to_b"], top["collide"]) == ("a", "b", 1, True), top
    assert not [p for p in pairs if "c" in (p["a"], p["b"]) and p["collide"]]
    es = enabled_skills()
    assert es and "commit" in es and "audit" not in es, sorted(es)
    fx = json.loads(FIXTURE.read_text(encoding="utf-8"))["prompts"]
    missing = sorted(set(es) - {p["skill"] for p in fx})
    assert not missing, f"enabled skills without fixture prompts: {missing}"
    unknown = sorted({p["skill"] for p in fx} - set(es))
    assert not unknown, f"fixture prompts for skills that are not enabled: {unknown}"
    print("self-test ok: %d enabled skills, %d prompts" % (len(es), len(fx)))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out")
    ap.add_argument("--max-calls", type=int, default=150)
    ap.add_argument("--fixture", default=str(FIXTURE))
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        self_test()
        return 0
    skills = enabled_skills()
    prompts = json.loads(Path(a.fixture).read_text(encoding="utf-8"))["prompts"]
    if len(prompts) > a.max_calls:
        print(f"refusing: {len(prompts)} calls > --max-calls {a.max_calls}", file=sys.stderr)
        return 2
    if a.dry_run:
        print(f"{len(skills)} enabled skills, {len(prompts)} calls planned")
        return 0
    jev = os.environ.get("JEV_ASK") or os.path.expanduser("~/.claude/hooks/jev/jev-ask")
    if not os.access(jev, os.X_OK):
        print(f"Jev client not found or not executable: {jev} (set JEV_ASK)", file=sys.stderr)
        return 3
    rows = []
    for p in prompts:
        try:
            choice, probs = ask_jev(p["prompt"], skills, jev)
        except RuntimeError as e:
            print(f"stopping after {len(rows)} calls: {e}", file=sys.stderr)
            return 3
        rows.append((p["skill"], p["prompt"], choice, probs))
    out = Path(a.out or os.path.expanduser(f"~/.tmp/reports/skill-overlap-{datetime.date.today().isoformat()}.md"))
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(report(rows, skills, len(rows), Path(a.fixture).name), encoding="utf-8")
    print(f"wrote {out} ({len(rows)} calls)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
