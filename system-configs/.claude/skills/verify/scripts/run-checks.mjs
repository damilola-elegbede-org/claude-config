#!/usr/bin/env node
/**
 * Discover and run a project's verification gates, then exit non-zero if any fail.
 *
 * This is the deterministic half of /verify. It makes no judgement about quality —
 * it runs the checks the project already defines and reports what the tools said.
 * Interpreting failures and fixing them is the agent's job; deciding whether the
 * work is "85% aligned" is nobody's.
 *
 * Usage:
 *   node run-checks.mjs [--list] [--json] [--only <id>] [--skip <id>] [--dir <path>]
 *
 *   --list   Print detected checks and exit 0 without running anything.
 *   --json   Emit machine-readable results (used by the skill to drive its loop).
 *   --only   Run a single check by id. Repeatable.
 *   --skip   Skip a check by id. Repeatable.
 *
 * Exit codes:
 *   0  every detected check passed (or none were detected — see --list)
 *   1  at least one check failed
 *   2  bad usage
 */

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

function parseArgs(argv) {
  const opts = { list: false, json: false, only: [], skip: [], dir: process.cwd() };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--list") opts.list = true;
    else if (a === "--json") opts.json = true;
    else if (a === "--only" || a === "--skip" || a === "--dir") {
      const value = argv[++i];
      if (value === undefined) {
        console.error(`${a} requires a value`);
        process.exit(2);
      }
      if (a === "--only") opts.only.push(value);
      else if (a === "--skip") opts.skip.push(value);
      else opts.dir = value;
    } else {
      console.error(`Unknown argument: ${a}`);
      process.exit(2);
    }
  }
  return opts;
}

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, "utf8"));
  } catch {
    return null;
  }
}

/** Shallow scan for a collectable pytest file. Returns the first match, or null. */
function findPythonTests(dir, depth = 0) {
  if (depth > 2) return null;
  let entries;
  try {
    entries = readdirSync(dir, { withFileTypes: true });
  } catch {
    return null;
  }
  for (const e of entries) {
    if (e.isFile() && /^test_.*\.py$|.*_test\.py$/.test(e.name)) return join(dir, e.name);
  }
  for (const e of entries) {
    if (!e.isDirectory()) continue;
    if (["node_modules", ".git", ".venv", "venv", "__pycache__", ".tmp"].includes(e.name)) continue;
    const found = findPythonTests(join(dir, e.name), depth + 1);
    if (found) return found;
  }
  return null;
}

/**
 * Detect the gates this project actually defines.
 *
 * Order matters: cheap and specific checks run before slow ones, so a lint error
 * surfaces in seconds rather than after a full test suite.
 */
function detectChecks(dir) {
  const checks = [];
  const has = (p) => existsSync(join(dir, p));
  const pkg = readJson(join(dir, "package.json"));
  const scripts = pkg?.scripts ?? {};

  // Node — only claim a script that is actually defined.
  const npmRunner = has("pnpm-lock.yaml") ? "pnpm" : has("yarn.lock") ? "yarn" : "npm";
  for (const [id, script] of [
    ["lint", "lint"],
    ["typecheck", "typecheck"],
    ["build", "build"],
    ["test", "test"],
  ]) {
    if (scripts[script]) {
      checks.push({ id, cmd: npmRunner, args: ["run", script], why: `package.json scripts.${script}` });
    }
  }

  // Python
  if (has("pyproject.toml") || has("setup.cfg") || has("requirements.txt")) {
    if (has("pyproject.toml") && readFileSync(join(dir, "pyproject.toml"), "utf8").includes("ruff")) {
      checks.push({ id: "ruff", cmd: "ruff", args: ["check", "."], why: "ruff configured in pyproject.toml" });
    }
    // A tests/ directory is not evidence of pytest — this repo's tests/ holds shell
    // scripts, and pytest would exit 5 ("no tests ran"), which reads as a failure.
    // Require an actual collectable test file.
    const pyTests = findPythonTests(dir);
    if (pyTests) {
      checks.push({ id: "pytest", cmd: "pytest", args: ["-q"], why: `python tests found (${pyTests})` });
    }
  }

  // Go
  if (has("go.mod")) {
    checks.push({ id: "go-vet", cmd: "go", args: ["vet", "./..."], why: "go.mod present" });
    checks.push({ id: "go-test", cmd: "go", args: ["test", "./..."], why: "go.mod present" });
  }

  // Rust
  if (has("Cargo.toml")) {
    checks.push({ id: "cargo-test", cmd: "cargo", args: ["test"], why: "Cargo.toml present" });
  }

  // Markdown — config-driven, so only when the project opted in.
  for (const cfg of [".markdownlint-cli2.jsonc", ".markdownlint-cli2.yaml", ".markdownlint.json"]) {
    if (has(cfg)) {
      checks.push({
        id: "markdownlint",
        cmd: "npx",
        args: ["-y", "markdownlint-cli2", "**/*.md"],
        why: cfg,
      });
      break;
    }
  }

  // Repo-local test entrypoint that isn't wired into package.json.
  if (!scripts.test && has("tests/test.sh")) {
    checks.push({ id: "test-sh", cmd: "./tests/test.sh", args: [], why: "tests/test.sh present" });
  }

  return checks;
}

// 0 would disable spawnSync's timeout entirely and negative/NaN values make it
// throw RangeError, so anything but a finite positive number falls back.
const DEFAULT_GATE_TIMEOUT_MS = 10 * 60 * 1000;
const envTimeout = Number(process.env.VERIFY_GATE_TIMEOUT_MS);
const GATE_TIMEOUT_MS =
  Number.isFinite(envTimeout) && envTimeout > 0 ? envTimeout : DEFAULT_GATE_TIMEOUT_MS;

function runCheck(check, dir) {
  const started = Date.now();
  const res = spawnSync(check.cmd, check.args, {
    cwd: dir,
    encoding: "utf8",
    maxBuffer: 32 * 1024 * 1024,
    timeout: GATE_TIMEOUT_MS,
    killSignal: "SIGKILL",
  });

  // A gate that hangs must fail, not wedge the caller. Without this, /verify —
  // and therefore ship-it's pre-commit gate — waits forever on a stuck suite.
  if (res.error?.code === "ETIMEDOUT" || res.signal === "SIGKILL") {
    return {
      ...check,
      status: "fail",
      exitCode: null,
      output: `Gate exceeded ${GATE_TIMEOUT_MS}ms and was killed.`,
      ms: Date.now() - started,
    };
  }

  // Truncated output means we cannot tell pass from fail. Treat as failure:
  // silently downgrading to "unavailable" would exit 0 on a failing suite.
  if (res.error?.code === "ENOBUFS") {
    return {
      ...check,
      status: "fail",
      exitCode: null,
      output: "Gate produced more output than the 32MB buffer; result indeterminate.",
      ms: Date.now() - started,
    };
  }

  // A missing binary is not a failing check — it means the gate cannot run here,
  // which the caller must distinguish from "the gate ran and found problems".
  if (res.error?.code === "ENOENT") {
    return { ...check, status: "unavailable", detail: `${check.cmd} not found on PATH`, ms: Date.now() - started };
  }
  if (res.error) {
    return { ...check, status: "unavailable", detail: res.error.message, ms: Date.now() - started };
  }

  const output = `${res.stdout ?? ""}${res.stderr ?? ""}`.trim();

  // pytest exits 5 when it collected nothing. That is "this gate had nothing to
  // check", not "the code is broken" — reporting it as a failure trains everyone
  // to ignore the runner.
  if (check.id === "pytest" && res.status === 5) {
    return { ...check, status: "unavailable", detail: "no tests collected", ms: Date.now() - started };
  }

  return {
    ...check,
    status: res.status === 0 ? "pass" : "fail",
    exitCode: res.status,
    output,
    ms: Date.now() - started,
  };
}

function main() {
  const opts = parseArgs(process.argv.slice(2));
  let checks = detectChecks(opts.dir);

  // A typo'd --only would otherwise filter to zero checks and exit 0, which
  // reads as "everything passed".
  const knownIds = new Set(checks.map((c) => c.id));
  const unknownIds = [...new Set([...opts.only, ...opts.skip])].filter((id) => !knownIds.has(id));
  if (unknownIds.length) {
    console.error(`Unknown gate id(s): ${unknownIds.join(", ")}`);
    console.error(`Known gate ids: ${[...knownIds].join(", ") || "(none detected)"}`);
    process.exit(2);
  }

  if (opts.only.length) checks = checks.filter((c) => opts.only.includes(c.id));
  if (opts.skip.length) checks = checks.filter((c) => !opts.skip.includes(c.id));

  if (opts.list) {
    if (opts.json) {
      console.log(JSON.stringify({ checks: checks.map(({ id, cmd, args, why }) => ({ id, cmd, args, why })) }, null, 2));
    } else if (!checks.length) {
      console.log("No verification gates detected.");
    } else {
      for (const c of checks) console.log(`${c.id.padEnd(14)} ${c.cmd} ${c.args.join(" ")}   (${c.why})`);
    }
    process.exit(0);
  }

  if (!checks.length) {
    const msg = "No verification gates detected. This is not a pass — nothing was checked.";
    if (opts.json) console.log(JSON.stringify({ checks: [], failed: 0, verdict: "no-gates" }, null, 2));
    else console.log(msg);
    process.exit(0);
  }

  const results = checks.map((c) => runCheck(c, opts.dir));
  const failed = results.filter((r) => r.status === "fail");
  const unavailable = results.filter((r) => r.status === "unavailable");

  // Verdict is three-valued on purpose. "pass" means every detected gate ran
  // and passed. Any unavailable gate makes the result "incomplete", and
  // incomplete is not green: a project that declares a typecheck gate has not
  // been verified on a machine where the typechecker cannot run.
  const verdict = failed.length ? "fail" : unavailable.length ? "incomplete" : "pass";

  if (opts.json) {
    console.log(JSON.stringify({
      checks: results,
      failed: failed.length,
      unavailable: unavailable.length,
      verdict,
    }, null, 2));
  } else {
    for (const r of results) {
      const mark = r.status === "pass" ? "PASS" : r.status === "fail" ? "FAIL" : "SKIP";
      console.log(`${mark}  ${r.id.padEnd(14)} ${(r.ms / 1000).toFixed(1)}s  ${r.status === "unavailable" ? r.detail : ""}`);
    }
    for (const r of failed) {
      console.log(`\n--- ${r.id} (exit ${r.exitCode}) ---\n${r.output}`);
    }
    console.log(
      `\n${verdict.toUpperCase()}: ${results.length - failed.length - unavailable.length}/${results.length} gates passed` +
        (unavailable.length ? `, ${unavailable.length} unavailable (an unavailable gate is not a pass)` : ""),
    );
  }

  process.exit(verdict === "pass" ? 0 : 1);
}

main();
