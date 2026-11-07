#!/usr/bin/env python3
"""Grade an experiment against its locked, pre-registered pass rule.

  score.py <dir>                 verdict: prints a table, writes <dir>/verdict.json
  score.py <dir> --json          verdict as one JSON object
  score.py --validate <dir>      check protocol.json + plan.json (lock.sh runs this)
  score.py --hash <dir>          sha256 of the canonical protocol + plan (lock.sh / run.sh)
  score.py --check-lock <dir>    exit 0 only when lock.json matches the files
  score.py --export-blind <dir>  write blind/items.jsonl for a blind judge (conditions with observe "judge")

Exit codes for a verdict: 0 SUPPORTED, 1 REFUTED, 2 INCONCLUSIVE, 3 error (bad or unlocked experiment).

The verdict is mechanical: the pass rule and controls were written and locked before any run, and this script
applies them to runs.jsonl as written. It never says "proved": SUPPORTED means the locked rule held on these n
runs, with the interval shown.
"""

import hashlib
import json
import math
import random
import re
import sys
from pathlib import Path

VERDICT_EXIT = {"SUPPORTED": 0, "REFUTED": 1, "INCONCLUSIVE": 2}
TEMPLATE_TEXT = {
    "What do we need to know? One sentence.",
    "The claim being tested, stated so it can be false.",
    "What the runs will show if the hypothesis is true, in terms of the metric.",
    "What the runs will show if it is false.",
}
OPS = {">=", ">", "<=", "<", "=="}
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")


class ExpError(Exception):
    pass


def load_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise ExpError(f"missing {path}")
    except json.JSONDecodeError as e:
        raise ExpError(f"{path} is not valid JSON: {e}")


def canonical_hash(d):
    proto = load_json(d / "protocol.json")
    plan = load_json(d / "plan.json")
    blob = json.dumps(proto, sort_keys=True, separators=(",", ":")) + "\n" + json.dumps(
        plan, sort_keys=True, separators=(",", ":")
    )
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


def validate(d):
    """Return a list of problems; empty means the experiment is well-formed."""
    errs = []
    try:
        proto = load_json(d / "protocol.json")
        plan = load_json(d / "plan.json")
    except ExpError as e:
        return [str(e)]
    for k in ("question", "hypothesis", "prediction", "if_false"):
        v = proto.get(k)
        if not isinstance(v, str) or not v.strip():
            errs.append(f"protocol.{k} must be a non-empty string")
        elif v.strip() in TEMPLATE_TEXT:
            errs.append(f"protocol.{k} is still the template text; write the real one before locking")
    if proto.get("side_effects") not in ("sandbox", "ask-d", "refuse"):
        errs.append("protocol.side_effects must be sandbox, ask-d or refuse")

    reps = plan.get("reps")
    if not isinstance(reps, int) or isinstance(reps, bool) or not 1 <= reps <= 1000:
        errs.append("plan.reps must be an integer from 1 to 1000")
    t = plan.get("timeout_s", 120)
    if not isinstance(t, (int, float)) or isinstance(t, bool) or not 1 <= t <= 3600:
        errs.append("plan.timeout_s must be a number from 1 to 3600")
    seed = plan.get("seed", 1)
    if not isinstance(seed, int) or isinstance(seed, bool):
        errs.append("plan.seed must be an integer")
    conds = plan.get("conditions")
    names = []
    if not isinstance(conds, list) or not conds:
        errs.append("plan.conditions must be a non-empty list")
        conds = []
    for i, c in enumerate(conds):
        if not isinstance(c, dict):
            errs.append(f"plan.conditions[{i}] must be an object")
            continue
        n = c.get("name")
        if not isinstance(n, str) or not NAME_RE.match(n):
            errs.append(f"plan.conditions[{i}].name must match {NAME_RE.pattern}")
        elif n in names:
            errs.append(f"plan.conditions: duplicate name {n}")
        else:
            names.append(n)
        if not isinstance(c.get("cmd"), str) or not c["cmd"].strip():
            errs.append(f"plan.conditions[{i}].cmd must be a non-empty string")
        obs = c.get("observe")
        if obs is not None and (not isinstance(obs, str) or not obs.strip()):
            errs.append(f"plan.conditions[{i}].observe must be null, \"judge\" or a command")
        if c.get("home", "real") not in ("real", "sandbox"):
            errs.append(f"plan.conditions[{i}].home must be real or sandbox")

    rule = proto.get("pass_rule")
    if not isinstance(rule, dict):
        errs.append("protocol.pass_rule must be an object")
    else:
        kind = rule.get("type")
        if rule.get("op") not in OPS:
            errs.append(f"protocol.pass_rule.op must be one of {sorted(OPS)}")
        if kind in ("rate", "mean"):
            if rule.get("condition") not in names:
                errs.append(f"protocol.pass_rule.condition must name a plan condition ({names})")
            v = rule.get("value")
            if not isinstance(v, (int, float)) or isinstance(v, bool):
                errs.append("protocol.pass_rule.value must be a number")
            elif kind == "rate" and not 0 <= v <= 1:
                errs.append("protocol.pass_rule.value is a rate: 0 to 1")
        elif kind == "compare":
            for side in ("a", "b"):
                if rule.get(side) not in names:
                    errs.append(f"protocol.pass_rule.{side} must name a plan condition ({names})")
            if rule.get("a") == rule.get("b"):
                errs.append("protocol.pass_rule: a and b must be different conditions")
            if rule.get("stat") not in ("rate", "mean"):
                errs.append("protocol.pass_rule.stat must be rate or mean")
            m = rule.get("margin", 0)
            if not isinstance(m, (int, float)) or isinstance(m, bool) or m < 0:
                errs.append("protocol.pass_rule.margin must be a number >= 0")
        else:
            errs.append("protocol.pass_rule.type must be rate, mean or compare")

    controls = proto.get("controls", [])
    if not isinstance(controls, list):
        errs.append("protocol.controls must be a list")
        controls = []
    for i, c in enumerate(controls):
        if not isinstance(c, dict) or c.get("condition") not in names:
            errs.append(f"protocol.controls[{i}].condition must name a plan condition")
        elif c.get("expect") not in ("pass", "fail"):
            errs.append(f"protocol.controls[{i}].expect must be pass or fail")
    if not controls:
        errs.append("protocol.controls is empty: add a negative control (a condition that must fail) so the "
                    "test can show it is able to fail")
    elif not any(isinstance(c, dict) and c.get("expect") == "fail" for c in controls):
        errs.append("protocol.controls has no negative control: add one with expect \"fail\", because positive "
                    "controls alone cannot show that a broken test which always passes would be caught")
    return errs


def planned(plan, rows):
    """The rows the plan asked for: reps 1..plan.reps, the first row per (condition, rep).

    run.sh never writes a pair twice and --record refuses reps outside the plan, but runs.jsonl is a plain file;
    a row added by hand must not be able to change the verdict."""
    reps = plan["reps"]
    seen, out = set(), []
    for r in rows:
        rep = r.get("rep")
        if not isinstance(rep, int) or isinstance(rep, bool) or not 1 <= rep <= reps:
            continue
        pair = (r.get("condition"), rep)
        if pair in seen:
            continue
        seen.add(pair)
        out.append(r)
    return out


def check_lock(d):
    lock = d / "lock.json"
    if not lock.exists():
        raise ExpError(f"{d} is not locked: run lock.sh first (pre-register before any run)")
    want = load_json(lock).get("sha256")
    if want != canonical_hash(d):
        raise ExpError(f"{d}: protocol.json or plan.json changed after lock.sh; a changed protocol is a new "
                       "experiment (new.sh)")


def truthy(v):
    if isinstance(v, bool):
        return v
    if isinstance(v, (int, float)):
        return v != 0
    if isinstance(v, str):
        return v.strip().lower() in ("pass", "true", "yes", "1")
    return False


def numeric(v):
    if isinstance(v, bool):
        return 1.0 if v else 0.0
    if isinstance(v, (int, float)) and math.isfinite(v):
        return float(v)
    if isinstance(v, str):
        try:
            f = float(v)
            return f if math.isfinite(f) else None
        except ValueError:
            return None
    return None


def wilson(k, n, z=1.96):
    if n == 0:
        return (0.0, 1.0)
    p = k / n
    den = 1 + z * z / n
    mid = (p + z * z / (2 * n)) / den
    half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / den
    return (max(0.0, mid - half), min(1.0, mid + half))


def compare(x, op, y):
    return {">=": x >= y, ">": x > y, "<=": x <= y, "<": x < y, "==": abs(x - y) < 1e-12}[op]


def read_rows(d):
    rows = []
    p = d / "runs.jsonl"
    if p.exists():
        for i, line in enumerate(p.read_text(encoding="utf-8").splitlines(), 1):
            if not line.strip():
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                raise ExpError(f"runs.jsonl line {i} is not valid JSON")
    key_p, jud_p = d / "blind" / "key.json", d / "blind" / "judgments.jsonl"
    if key_p.exists() and jud_p.exists():
        key = load_json(key_p)
        verdicts = {}
        for line in jud_p.read_text(encoding="utf-8").splitlines():
            if line.strip():
                j = json.loads(line)
                verdicts[j.get("id")] = j.get("value")
        for r in rows:
            for bid, ref in key.items():
                if ref == [r.get("condition"), r.get("rep")] and r.get("value") is None and bid in verdicts:
                    r["value"] = verdicts[bid]
                    r["judged"] = True
    return rows


def stats(plan, rows):
    rows = planned(plan, rows)
    out = {}
    for c in plan["conditions"]:
        name = c["name"]
        mine = [r for r in rows if r.get("condition") == name]
        valid = [r for r in mine if not r.get("error") and not r.get("timed_out") and r.get("value") is not None]
        k = sum(1 for r in valid if truthy(r["value"]))
        nums = [x for x in (numeric(r["value"]) for r in valid) if x is not None]
        n = len(valid)
        lo, hi = wilson(k, n)
        out[name] = {
            "n": n,
            "recorded": len(mine),
            "invalid": len(mine) - n,
            "passes": k,
            "rate": (k / n) if n else None,
            "rate_ci95": [round(lo, 3), round(hi, 3)] if n else None,
            "mean": (sum(nums) / len(nums)) if nums else None,
        }
    return out


def decide(proto, plan, st):
    reps = plan["reps"]
    rule = proto["pass_rule"]
    used = {rule.get("condition"), rule.get("a"), rule.get("b")} | {c["condition"] for c in proto.get("controls", [])}
    used.discard(None)
    short = [f"{c} has {st[c]['n']}/{reps} valid runs" for c in sorted(used) if st[c]["n"] < reps]
    if short:
        return "INCONCLUSIVE", "not enough valid runs: " + "; ".join(short)
    for c in proto.get("controls", []):
        s = st[c["condition"]]
        want = 0.0 if c["expect"] == "fail" else 1.0
        if s["rate"] != want:
            return "INCONCLUSIVE", (
                f"control {c['condition']} was expected to {c['expect']} on every run but passed "
                f"{s['passes']}/{s['n']}: the test cannot tell the hypothesis apart, fix the design"
            )
    kind, op = rule["type"], rule["op"]
    if kind in ("rate", "mean"):
        x = st[rule["condition"]][kind]
        if x is None:
            return "INCONCLUSIVE", f"{rule['condition']} has no numeric values for {kind}"
        ok = compare(x, op, rule["value"])
        why = f"{kind}({rule['condition']}) = {x:.4g} {op} {rule['value']}"
    else:
        a, b = st[rule["a"]][rule["stat"]], st[rule["b"]][rule["stat"]]
        if a is None or b is None:
            return "INCONCLUSIVE", f"no {rule['stat']} for {rule['a']} or {rule['b']}"
        m = rule.get("margin", 0)
        target = b + m if op in (">", ">=") else b - m if op in ("<", "<=") else b
        ok = compare(a, op, target)
        why = f"{rule['stat']}({rule['a']}) = {a:.4g} {op} {rule['stat']}({rule['b']}) = {b:.4g}" + (
            f" with margin {m}" if m else ""
        )
    return ("SUPPORTED" if ok else "REFUTED"), ("holds: " if ok else "fails: ") + why


def table(proto, st, verdict, why):
    lines = [
        f"Verdict: {verdict} — {why}",
        f"Hypothesis: {proto['hypothesis']}",
        f"Prediction: {proto['prediction']}",
        "",
        "| condition | n | invalid | passes | rate | 95% interval | mean |",
        "| --- | --- | --- | --- | --- | --- | --- |",
    ]
    for name, s in st.items():
        rate = "-" if s["rate"] is None else f"{s['rate']:.2f}"
        ci = "-" if s["rate_ci95"] is None else f"{s['rate_ci95'][0]:.2f}-{s['rate_ci95'][1]:.2f}"
        mean = "-" if s["mean"] is None else f"{s['mean']:.4g}"
        lines.append(f"| {name} | {s['n']} | {s['invalid']} | {s['passes']} | {rate} | {ci} | {mean} |")
    return "\n".join(lines)


def export_blind(d):
    check_lock(d)
    plan = load_json(d / "plan.json")
    judged = {c["name"] for c in plan["conditions"] if c.get("observe") == "judge"}
    if not judged:
        raise ExpError("no condition has observe \"judge\"; nothing to export")
    rows = [r for r in planned(plan, read_rows(d))
            if r.get("condition") in judged and not r.get("error") and not r.get("timed_out")]
    rng = random.Random()
    rng.shuffle(rows)
    (d / "blind").mkdir(exist_ok=True)
    key, items = {}, []
    for r in rows:
        bid = "%08x" % rng.getrandbits(32)
        while bid in key:
            bid = "%08x" % rng.getrandbits(32)
        key[bid] = [r["condition"], r["rep"]]
        out = d / "runs" / f"{r['condition']}-{r['rep']}.out"
        # The whole output: a cut would hide whatever the grade depends on past the cut.
        text = out.read_text(encoding="utf-8", errors="replace") if out.exists() else ""
        items.append({"id": bid, "output": text})
    (d / "blind" / "key.json").write_text(json.dumps(key, indent=1) + "\n", encoding="utf-8")
    with open(d / "blind" / "items.jsonl", "w", encoding="utf-8") as f:
        for it in items:
            f.write(json.dumps(it) + "\n")
    print(f"{len(items)} items in {d / 'blind' / 'items.jsonl'}; the judge writes {d / 'blind' / 'judgments.jsonl'}")


def main(argv):
    if len(argv) == 3 and argv[1] in ("--validate", "--hash", "--check-lock", "--export-blind"):
        d = Path(argv[2])
        if argv[1] == "--validate":
            errs = validate(d)
            for e in errs:
                print("invalid: " + e, file=sys.stderr)
            return 3 if errs else 0
        if argv[1] == "--hash":
            print(canonical_hash(d))
            return 0
        if argv[1] == "--check-lock":
            check_lock(d)
            return 0
        export_blind(d)
        return 0
    if len(argv) not in (2, 3) or (len(argv) == 3 and argv[2] != "--json"):
        print(__doc__.strip(), file=sys.stderr)
        return 3
    d = Path(argv[1])
    errs = validate(d)
    if errs:
        raise ExpError("; ".join(errs))
    check_lock(d)
    proto, plan = load_json(d / "protocol.json"), load_json(d / "plan.json")
    st = stats(plan, read_rows(d))
    verdict, why = decide(proto, plan, st)
    result = {"id": proto.get("id", d.name), "verdict": verdict, "why": why, "hypothesis": proto["hypothesis"],
              "prediction": proto["prediction"], "pass_rule": proto["pass_rule"], "stats": st, "dir": str(d)}
    (d / "verdict.json").write_text(json.dumps(result, indent=1) + "\n", encoding="utf-8")
    print(json.dumps(result) if len(argv) == 3 else table(proto, st, verdict, why))
    return VERDICT_EXIT[verdict]


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except ExpError as e:
        print("error: " + str(e), file=sys.stderr)
        sys.exit(3)
