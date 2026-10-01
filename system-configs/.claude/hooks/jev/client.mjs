#!/usr/bin/env node
// Jev client: one CLI (`jev-ask`) plus a long-lived daemon behind a unix socket.
//
// Contract (all phases code against this):
//   stdin  {"rule","state","questions","untrusted"?,"untrusted_source"?,"cwd"?,"timeout_ms"?}
//   stdout {"answers":{...},"model","latency_ms","cost_usd"}   exit 0
//   exit 3 = unavailable (no key, timeout, gateway error, kill switch, egress
//            excluded, rule off). The CALLER applies its fail mode. Never blocks.
//   exit 2 = bad input (message on stderr).
//
// What the client guarantees so callers need not: key resolution (never logged),
// zeroDataRetention always on, redaction of secrets in state, egress exclusion
// for work repos and Gmail/Slack bodies, truncation under 32k tokens, a shadow
// log with NO state, a daemon (cold fallback = direct call).
//
// Test hooks (documented here because tests and parallel branches rely on them):
//   JEV_MOCK=<fixture.json>  return the file as stdout, exit 0, no network, no
//                            daemon. JEV_MOCK=unavailable -> exit 3. Validation,
//                            kill switch, redaction and the shadow log still run.
//                            Egress exclusion is skipped in mock mode unless
//                            JEV_MOCK_CHECK_EGRESS=1 (so a fixture run from a checkout
//                            that happens to sit under an excluded dir still answers).
//   JEV_RECORD=<path>        write the post-redaction, post-truncation payload.
//   JEV_STATE_DIR            dir for shadow log, kill switch, daemon log
//                            (default ~/.claude).
//   JEV_CONFIG / JEV_RULES   alternate jev-config.json / jev-rules.json (JEV_RULES = that one
//                            file only, no rules.d merge).
//   JEV_SOCK                 alternate socket path. JEV_IDLE_MS: daemon idle exit.
//   JEV_NO_DAEMON=1          direct call only.
//   JEV_BACKEND_FIXTURE      daemon/direct backends answer from this file instead
//                            of the gateway (lifecycle tests without network).
//                            JEV_BACKEND_DELAY_MS adds latency to it.
//   JEV_ZSHRC                alternate rc file for key lookup.
//
// Flags: --daemon (internal) --warm --check --status --stop

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import crypto from "node:crypto";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const T_START = Date.now() - Math.round(process.uptime() * 1000);

const EXIT_OK = 0;
const EXIT_BAD_INPUT = 2;
const EXIT_UNAVAILABLE = 3;

class JevError extends Error {
  constructor(exit, reason) {
    super(reason);
    this.exit = exit;
    this.reason = reason;
  }
}
const unavailable = (reason) => new JevError(EXIT_UNAVAILABLE, reason);
const badInput = (reason) => new JevError(EXIT_BAD_INPUT, reason);

// ---------------------------------------------------------------- paths/config

const home = () => process.env.HOME || os.homedir();
const stateDir = () => process.env.JEV_STATE_DIR || path.join(home(), ".claude");
// The kill switch is a REGULAR FILE (not a directory or symlink): `mkdir ~/.claude/jev.off` must not disable Jev.
const killSwitchOn = () => {
  try {
    return fs.lstatSync(path.join(stateDir(), "jev.off")).isFile();
  } catch {
    return false;
  }
};

function readJson(file, fallback) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return fallback;
  }
}
const config = () => readJson(process.env.JEV_CONFIG || path.join(HERE, "jev-config.json"), {});

// Rule registry: ONE reader semantics shared with jev-gate-lib.sh, ctx-lib.sh and rules-events-lib.sh.
// Files: rules.d/*.json in lexical order, then jev-rules.json LAST (the user's file wins). Each file
// holds {"exempt_agents": [...], "rules": {"<id>": {...}}}; a flat {"<id>": {...}} is tolerated.
// Objects deep-merge, arrays/scalars are replaced; exempt_agents comes from the last file that sets it.
// JEV_RULES points at a single file (tests) and skips the rules.d merge.
function deepMerge(a, b) {
  if (!b || typeof b !== "object" || Array.isArray(b)) return b;
  const out = a && typeof a === "object" && !Array.isArray(a) ? { ...a } : {};
  for (const [k, v] of Object.entries(b)) out[k] = deepMerge(out[k], v);
  return out;
}
function rulesRegistry() {
  const files = [];
  if (process.env.JEV_RULES) files.push(process.env.JEV_RULES);
  else {
    try {
      const dir = path.join(HERE, "rules.d");
      for (const f of fs.readdirSync(dir).sort()) if (f.endsWith(".json")) files.push(path.join(dir, f));
    } catch {
      /* no rules.d */
    }
    files.push(path.join(HERE, "jev-rules.json"));
  }
  const reg = { exempt_agents: undefined, rules: {} };
  for (const f of files) {
    const o = readJson(f, null);
    if (!o || typeof o !== "object" || Array.isArray(o)) continue;
    const { exempt_agents: ex, rules: wrapped, ...flat } = o;
    if (ex !== undefined) reg.exempt_agents = ex;
    reg.rules = deepMerge(reg.rules, wrapped && typeof wrapped === "object" ? wrapped : flat);
  }
  return reg;
}

function sockPath() {
  if (process.env.JEV_SOCK) return process.env.JEV_SOCK;
  const p = path.join(HERE, "jev.sock");
  // sun_path is ~104 bytes on macOS, 108 on Linux.
  if (Buffer.byteLength(p) <= 100) return p;
  const h = crypto.createHash("sha256").update(p).digest("hex").slice(0, 12);
  return path.join(os.tmpdir(), `jev-${process.getuid?.() ?? 0}-${h}.sock`);
}

// ------------------------------------------------------------------------- key

const KEY_ENV = ["AI_GATEWAY_API_KEY", "VERCEL_AI_GATEWAY_TOKEN", "VERCEL_AI_GATEWAY_KEY"];

function resolveKey() {
  for (const n of KEY_ENV) {
    const v = process.env[n];
    if (v && v.trim()) return v.trim();
  }
  let txt;
  try {
    txt = fs.readFileSync(process.env.JEV_ZSHRC || path.join(home(), ".zshrc"), "utf8");
  } catch {
    return null;
  }
  const re = /^[ \t]*export[ \t]+(?:VERCEL_AI_GATEWAY_TOKEN|VERCEL_AI_GATEWAY_KEY|AI_GATEWAY_API_KEY)=(.*)$/gm;
  let raw = null;
  for (const m of txt.matchAll(re)) raw = m[1];
  if (raw === null) return null;
  raw = raw.trim();
  let val;
  const q = raw[0];
  if (q === '"' || q === "'") {
    const end = raw.indexOf(q, 1);
    val = end === -1 ? "" : raw.slice(1, end);
  } else {
    val = raw.split(/[\s#]/)[0];
  }
  // Anything needing shell evaluation ($(...), $VAR, backticks) is not supported.
  if (!val || /[$`]/.test(val)) return null;
  return val;
}

const sdkInstalled = () => fs.existsSync(path.join(HERE, "node_modules", "ai", "package.json"));

// ------------------------------------------------------------------- redaction

// Mirrors the Write secret guard in settings.json (PATTERNS=...), plus more.
const SECRET_PATTERNS = [
  /AKIA[0-9A-Z]{16}/g,
  /sk-[a-zA-Z0-9]{20,}/g,
  /ghp_[a-zA-Z0-9]{36}/g,
  /gho_[a-zA-Z0-9]{36}/g,
  /xoxb-[0-9]{10,}[A-Za-z0-9-]*/g,
  /xoxp-[0-9]{10,}[A-Za-z0-9-]*/g,
  /glpat-[a-zA-Z0-9_-]{20}/g,
  // beyond the Write guard
  /sk-ant-[A-Za-z0-9_-]{20,}/g,
  /github_pat_[A-Za-z0-9_]{20,}/g,
  /gh[usr]_[A-Za-z0-9]{36}/g,
  /xox[abprs]-[A-Za-z0-9-]{10,}/g,
  /vck_[A-Za-z0-9]{20,}/g,
  /npm_[A-Za-z0-9]{30,}/g,
  /AIza[0-9A-Za-z_-]{35}/g,
  /[sr]k_live_[A-Za-z0-9]{16,}/g,
  /whsec_[A-Za-z0-9]{16,}/g,
  /eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}/g,
  /-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(?:-----END [A-Z ]*PRIVATE KEY-----|$)/g,
  /\bBearer[ \t]+[A-Za-z0-9._~+/=-]{16,}/gi,
];
// scheme://user:pass@host -> scheme://[REDACTED]@host
const URL_CREDS = /\b([a-z][a-z0-9+.-]*:\/\/)[^\s:@/]+:[^\s@/]+@/gi;
// The assignment redaction pattern is built from credential-name words (see CRED_WORDS) so no
// source line spells out a quoted NAME=value assignment.
const CRED_WORDS = [
  "token",
  "secret",
  "passw(?:or)?d",
  "passwd",
  "api[_-]?key",
  "private[_-]?key",
  "credentials?",
  "access[_-]?key",
].join("|");
const patternAssignment = new RegExp(
  `\\b([A-Za-z0-9_.-]*(?:${CRED_WORDS})[A-Za-z0-9_.-]*)([ \\t]*[=:][ \\t]*)("[^"\\n]*"|'[^'\\n]*'|[^\\s"',;]+)`,
  "gi",
);
const SENSITIVE_KEY =
  /^(?:.*[-_.])?(?:token|secret|password|passwd|pwd|api[-_]?key|apikey|authorization|auth|cookie|credentials?|private[-_]?key|access[-_]?key)s?$/i;
const TOKEN_CANDIDATE = /[A-Za-z0-9_\-+/=]{24,}/g;
const REDACTED = "[REDACTED]";

function entropy(s) {
  const f = new Map();
  for (const c of s) f.set(c, (f.get(c) || 0) + 1);
  let h = 0;
  for (const n of f.values()) {
    const p = n / s.length;
    h -= p * Math.log2(p);
  }
  return h;
}

function looksLikeSecret(t) {
  if (t.startsWith("/") || t.startsWith("./") || t.startsWith("../")) return false; // a path
  const hex = /^[0-9a-fA-F]+$/.test(t);
  if (hex) return t.length >= 32 && entropy(t) >= 3.0; // also catches 40-hex git SHAs: over-redaction is fine
  if (!(/[A-Z]/.test(t) && /[a-z]/.test(t) && /\d/.test(t))) return false;
  return entropy(t) >= (t.includes("/") ? 4.2 : 3.5);
}

function redactString(s, stats) {
  let out = s;
  const sub = (re, rep) => {
    out = out.replace(re, (...a) => {
      stats.count++;
      return typeof rep === "function" ? rep(...a) : rep;
    });
  };
  for (const re of SECRET_PATTERNS) sub(re, REDACTED);
  sub(URL_CREDS, (_m, scheme) => `${scheme}${REDACTED}@`);
  sub(patternAssignment, (m, name, sep, val) => (val === REDACTED || val.includes(REDACTED) ? m : `${name}${sep}${REDACTED}`));
  out = out.replace(TOKEN_CANDIDATE, (t) => {
    if (!looksLikeSecret(t)) return t;
    stats.count++;
    return REDACTED;
  });
  return out;
}

function redactValue(v, stats, depth = 0) {
  if (depth > 40) return REDACTED;
  if (typeof v === "string") return redactString(v, stats);
  if (Array.isArray(v)) return v.map((x) => redactValue(x, stats, depth + 1));
  if (v && typeof v === "object") {
    const o = {};
    for (const [k, x] of Object.entries(v)) {
      if (SENSITIVE_KEY.test(k) && (typeof x === "string" || typeof x === "number")) {
        stats.count++;
        o[k] = REDACTED;
      } else {
        o[k] = redactValue(x, stats, depth + 1);
      }
    }
    return o;
  }
  return v;
}

// ------------------------------------------------------------------ truncation

function collectStrings(v, out, parent = null, key = null) {
  if (typeof v === "string") out.push({ parent, key, len: v.length });
  else if (Array.isArray(v)) v.forEach((x, i) => collectStrings(x, out, v, i));
  else if (v && typeof v === "object") for (const [k, x] of Object.entries(v)) collectStrings(x, out, v, k);
}

// Shrink the longest string leaves (head 60% + tail 40%) until JSON size <= budget chars.
function truncateToBudget(obj, budgetChars) {
  let size = JSON.stringify(obj).length;
  if (size <= budgetChars) return { value: obj, truncated: false };
  for (let i = 0; i < 400 && size > budgetChars; i++) {
    const leaves = [];
    collectStrings(obj, leaves);
    leaves.sort((a, b) => b.len - a.len);
    const big = leaves[0];
    if (!big) break;
    const excess = size - budgetChars;
    const marker = (n) => `\n...[truncated ${n} chars]...\n`;
    const keep = Math.max(200, big.len - excess - 64);
    if (keep >= big.len) break;
    const s = big.parent[big.key];
    const head = Math.ceil(keep * 0.6);
    const tail = keep - head;
    big.parent[big.key] = s.slice(0, head) + marker(s.length - keep) + (tail > 0 ? s.slice(-tail) : "");
    size = JSON.stringify(obj).length;
  }
  if (size > budgetChars) {
    // Many small leaves: fall back to a cut of the serialised form.
    const cut = JSON.stringify(obj).slice(0, Math.max(0, budgetChars - 40));
    return { value: { _truncated_json: cut }, truncated: true };
  }
  return { value: obj, truncated: true };
}

// ---------------------------------------------------------------------- egress

// exclude_paths semantics (identical in ctx-lib.sh ctx_path_excluded): each entry is a DIRECTORY PREFIX,
// anchored at "/" or at $HOME ("~/work"; a bare "work" means "~/work"), matched case-insensitively on a
// path-segment boundary against the raw and the realpath form of the cwd. A trailing "/", "/*" or "/**" is
// ignored. A substring such as "/work/" no longer matches an unrelated checkout like /home/runner/work/x.
function excludedPrefixes() {
  const out = new Set();
  const homes = new Set([home()]);
  try {
    homes.add(fs.realpathSync(home()));
  } catch {
    /* home not on disk */
  }
  for (const raw of (config().exclude_paths || []).filter((p) => typeof p === "string" && p.trim())) {
    const e = raw.trim().replace(/(?:\/\*{0,2})+$/, "");
    if (!e) continue;
    const rel = e.startsWith("~") ? e.replace(/^~\/?/, "") : e.startsWith("/") ? null : e;
    const abs = rel === null ? [e] : [...homes].map((h) => (rel ? path.join(h, rel) : h));
    for (const a of abs) {
      out.add(a.toLowerCase());
      try {
        out.add(fs.realpathSync(a).toLowerCase()); // a prefix given through a symlink (e.g. /var -> /private/var)
      } catch {
        /* not on disk: raw only */
      }
    }
  }
  return out;
}

function egressReason(input) {
  // The caller may flag the source at top level or inside state; honor both.
  const srcs = [input.untrusted_source, input.state?.untrusted_source].flatMap((v) =>
    Array.isArray(v) ? v : typeof v === "string" ? [v] : [],
  );
  if (srcs.some((s) => /gmail|slack/i.test(String(s)))) return "egress_untrusted_source";
  const cwds = new Set();
  for (const c of [input.cwd, process.cwd()]) {
    if (typeof c !== "string" || !c) continue;
    cwds.add(c);
    try {
      cwds.add(fs.realpathSync(c));
    } catch {
      /* not on disk: raw only */
    }
  }
  for (const q of excludedPrefixes()) {
    for (const c of cwds) {
      const lc = c.toLowerCase();
      if (lc === q || lc.startsWith(q + "/")) return "egress_excluded_path";
    }
  }
  return null;
}

// -------------------------------------------------------------- validation/IO

function validate(input) {
  if (!input || typeof input !== "object" || Array.isArray(input)) throw badInput("stdin must be a JSON object");
  if (typeof input.rule !== "string" || !/^[\w.:/-]{1,80}$/.test(input.rule)) throw badInput("rule: required id string");
  const st = input.state;
  if (!st || typeof st !== "object" || Array.isArray(st)) throw badInput("state: required object");
  if ("untrusted" in st) throw badInput("state must not contain an 'untrusted' key; use the top-level untrusted field");
  const qs = input.questions;
  if (!qs || typeof qs !== "object" || Array.isArray(qs) || !Object.keys(qs).length) throw badInput("questions: required non-empty object");
  for (const [name, q] of Object.entries(qs)) {
    if (!q || typeof q !== "object") throw badInput(`questions.${name}: object required`);
    if (!["boolean", "choice", "score"].includes(q.type)) throw badInput(`questions.${name}.type: boolean|choice|score`);
    if (typeof q.instructions !== "string" || !q.instructions) throw badInput(`questions.${name}.instructions: string required`);
    if (q.type === "choice" && (!q.criteria || typeof q.criteria !== "object" || Array.isArray(q.criteria) || !Object.keys(q.criteria).length))
      throw badInput(`questions.${name}.criteria: object of options required for choice`);
    if (q.type === "score" && (!Array.isArray(q.criteria) || !q.criteria.length)) throw badInput(`questions.${name}.criteria: array required for score`);
  }
  if (input.timeout_ms !== undefined && !(Number.isFinite(input.timeout_ms) && input.timeout_ms >= 50 && input.timeout_ms <= 60000))
    throw badInput("timeout_ms: number 50..60000");
  if (input.untrusted !== undefined && input.untrusted !== null && typeof input.untrusted !== "object" && typeof input.untrusted !== "string")
    throw badInput("untrusted: object or string");
}

function readStdin(cap = 16 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let n = 0;
    process.stdin.on("data", (c) => {
      n += c.length;
      if (n > cap) reject(badInput("stdin too large"));
      else chunks.push(c);
    });
    process.stdin.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    process.stdin.on("error", reject);
  });
}

function shadowLog(entry) {
  try {
    const dir = stateDir();
    fs.mkdirSync(dir, { recursive: true });
    const file = path.join(dir, "jev-shadow.jsonl");
    try {
      if (fs.statSync(file).size > 10 * 1024 * 1024) {
        const ym = new Date().toISOString().slice(0, 7).replace("-", "");
        fs.renameSync(file, path.join(dir, `jev-shadow.${ym}.jsonl`));
      }
    } catch {
      /* no file yet */
    }
    fs.appendFileSync(file, JSON.stringify({ ts: new Date().toISOString(), ...entry }) + "\n", { mode: 0o600 });
  } catch {
    /* logging must never fail the call */
  }
}

function scrubKey(msg) {
  const key = resolveKey();
  let s = String(msg ?? "").slice(0, 200);
  if (key) s = s.split(key).join("[KEY]");
  return s;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// -------------------------------------------------------------------- backend

// Shared by the daemon and direct mode. Throws JevError(unavailable).
async function callGateway({ model, state, questions, timeout_ms }) {
  const t0 = Date.now();
  if (process.env.JEV_BACKEND_FIXTURE) {
    const delay = Number(process.env.JEV_BACKEND_DELAY_MS || 0);
    if (delay) await sleep(delay);
    const j = readJson(process.env.JEV_BACKEND_FIXTURE, null);
    if (!j || !j.answers) throw unavailable("backend_fixture_unreadable");
    return { answers: j.answers, model: j.model || model, latency_ms: j.latency_ms ?? Date.now() - t0, cost_usd: j.cost_usd ?? 0 };
  }
  const key = resolveKey();
  if (!key) throw unavailable("no_key");
  process.env.AI_GATEWAY_API_KEY = key;
  let mod;
  try {
    mod = await import("ai");
  } catch {
    throw unavailable("sdk_missing");
  }
  let res;
  try {
    res = await mod.experimental_evaluate({
      model,
      state,
      questions,
      providerOptions: { gateway: { zeroDataRetention: true } },
      abortSignal: AbortSignal.timeout(Math.max(50, timeout_ms)),
    });
  } catch (e) {
    throw unavailable(`gateway_error:${e?.name || "Error"}:${scrubKey(e?.statusCode ?? e?.message)}`);
  }
  const gw = res?.providerMetadata?.gateway || {};
  const cost = Number.parseFloat(gw.marketCost ?? gw.cost ?? "0");
  return { answers: res.answers, model, latency_ms: Date.now() - t0, cost_usd: Number.isFinite(cost) ? cost : 0 };
}

// ---------------------------------------------------------------------- daemon

function rpc(sock, msg, deadline) {
  return new Promise((resolve, reject) => {
    const left = deadline - Date.now();
    if (left <= 0) return reject(Object.assign(new Error("timeout"), { code: "JEV_TIMEOUT" }));
    const c = net.connect(sock);
    let buf = "";
    let done = false;
    const finish = (fn, v) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      c.destroy();
      fn(v);
    };
    const timer = setTimeout(() => finish(reject, Object.assign(new Error("timeout"), { code: "JEV_TIMEOUT" })), left);
    c.on("connect", () => c.write(JSON.stringify(msg) + "\n"));
    c.on("data", (d) => {
      buf += d;
      const i = buf.indexOf("\n");
      if (i === -1) return;
      try {
        finish(resolve, JSON.parse(buf.slice(0, i)));
      } catch {
        finish(reject, Object.assign(new Error("bad daemon reply"), { code: "JEV_PROTO" }));
      }
    });
    c.on("error", (e) => finish(reject, e));
    c.on("close", () => finish(reject, Object.assign(new Error("daemon closed"), { code: "JEV_PROTO" })));
  });
}

// Spawn lock: mkdir is atomic. Returns true if we may (or someone else already did) spawn.
function startDaemon(sock) {
  const lock = sock + ".spawn";
  try {
    fs.mkdirSync(lock);
  } catch (e) {
    if (e.code !== "EEXIST") return false; // e.g. parent dir missing -> caller falls back to direct
    try {
      if (Date.now() - fs.statSync(lock).mtimeMs > 10000) {
        fs.rmdirSync(lock);
        fs.mkdirSync(lock);
      } else return true; // another client is spawning
    } catch {
      return true;
    }
  }
  try {
    const child = spawn(process.execPath, [fileURLToPath(import.meta.url), "--daemon"], {
      detached: true,
      stdio: "ignore",
      env: process.env,
    });
    child.on("error", () => {});
    child.unref();
    return true;
  } catch {
    try {
      fs.rmdirSync(lock);
    } catch {
      /* ignore */
    }
    return false;
  }
}

const notRunning = (e) => e && (e.code === "ENOENT" || e.code === "ECONNREFUSED");

async function viaDaemon(payload, deadline) {
  const sock = sockPath();
  const attempt = () => rpc(sock, { op: "evaluate", ...payload, timeout_ms: Math.max(50, deadline - Date.now()) }, deadline);
  try {
    return { kind: "ok", res: await attempt() };
  } catch (e) {
    if (e.code === "JEV_TIMEOUT") return { kind: "timeout" };
    if (!notRunning(e)) return { kind: "fallback" };
  }
  if (!startDaemon(sock)) return { kind: "fallback" };
  while (Date.now() < deadline) {
    await sleep(25);
    try {
      return { kind: "ok", res: await attempt() };
    } catch (e) {
      if (e.code === "JEV_TIMEOUT") break;
      if (!notRunning(e)) return { kind: "fallback" };
    }
  }
  return { kind: "timeout" };
}

async function daemonMain() {
  const sock = sockPath();
  const idleMs = Number(process.env.JEV_IDLE_MS || config().daemon_idle_ms || 1800000);
  if (!process.env.JEV_BACKEND_FIXTURE) await import("ai").catch(() => {}); // warm the module
  let requests = 0;
  const started = Date.now();
  let idle = null;
  const bump = () => {
    clearTimeout(idle);
    idle = setTimeout(shutdown, idleMs);
  };
  function shutdown() {
    try {
      fs.unlinkSync(sock);
    } catch {
      /* gone already */
    }
    process.exit(0);
  }
  const onConn = (c) => {
    bump();
    let buf = "";
    c.on("error", () => {});
    c.on("data", async (d) => {
      buf += d;
      const i = buf.indexOf("\n");
      if (i === -1) return;
      const line = buf.slice(0, i);
      buf = buf.slice(i + 1);
      let msg;
      try {
        msg = JSON.parse(line);
      } catch {
        return void c.end(JSON.stringify({ ok: false, reason: "bad_request" }) + "\n");
      }
      if (msg.op === "ping") return void c.end(JSON.stringify({ ok: true, pid: process.pid, uptime_ms: Date.now() - started, requests }) + "\n");
      if (msg.op === "stop") {
        c.end(JSON.stringify({ ok: true }) + "\n", shutdown);
        return;
      }
      if (msg.op !== "evaluate") return void c.end(JSON.stringify({ ok: false, reason: "bad_op" }) + "\n");
      requests++;
      try {
        const out = await callGateway(msg);
        c.end(JSON.stringify({ ok: true, ...out }) + "\n");
      } catch (e) {
        c.end(JSON.stringify({ ok: false, reason: e.reason || `daemon_error:${e?.name}` }) + "\n");
      }
      bump();
    });
  };
  const listen = () =>
    new Promise((resolve, reject) => {
      const srv = net.createServer(onConn);
      srv.once("error", reject);
      const prev = process.umask(0o077);
      srv.listen(sock, () => {
        process.umask(prev);
        srv.off("error", reject);
        resolve(srv);
      });
    });
  try {
    await listen();
  } catch (e) {
    if (e.code !== "EADDRINUSE") process.exit(1);
    // Socket file exists: live daemon (single-instance lock) or stale file.
    try {
      await rpc(sock, { op: "ping" }, Date.now() + 500);
      process.exit(0); // another daemon owns the socket
    } catch {
      /* stale */
    }
    try {
      fs.unlinkSync(sock);
    } catch {
      /* raced */
    }
    try {
      await listen();
    } catch {
      process.exit(1);
    }
  }
  try {
    fs.rmdirSync(sock + ".spawn");
  } catch {
    /* no spawn lock */
  }
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
  bump();
}

// ------------------------------------------------------------------------ CLI

function finish(code, stdout) {
  if (stdout) process.stdout.write(stdout, () => process.exit(code));
  else process.exit(code);
}

async function ask() {
  let input;
  try {
    const raw = await readStdin();
    try {
      input = JSON.parse(raw);
    } catch {
      throw badInput("stdin is not valid JSON");
    }
    validate(input);
  } catch (e) {
    if (e instanceof JevError) {
      process.stderr.write(`jev-ask: bad input: ${e.reason}\n`);
      return finish(e.exit);
    }
    throw e;
  }

  const cfg = config();
  const mock = process.env.JEV_MOCK || "";
  const model = cfg.model || "typesafe-ai/jev";
  const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
  const meta = { rule: input.rule, cwd, model: mock ? "mock" : model };
  const t0 = T_START;
  const fail = (reason) => {
    shadowLog({ ...meta, outcome: "unavailable", reason, wall_ms: Date.now() - t0 });
    process.stderr.write(`jev-ask: unavailable: ${reason.split(":")[0]}\n`);
    return finish(EXIT_UNAVAILABLE);
  };

  if (mock === "unavailable") return fail("mock_unavailable");
  if (killSwitchOn()) return fail("kill_switch");
  const thisRule = rulesRegistry().rules[input.rule];
  if (thisRule?.mode === "off") return fail("rule_off");
  if (!mock || process.env.JEV_MOCK_CHECK_EGRESS === "1") {
    const why = egressReason(input);
    if (why) return fail(why);
  }

  // Redact, then truncate. Untrusted text stays under its own key.
  const stats = { count: 0 };
  const questions = input.questions;
  let payload = redactValue(input.state, stats);
  if (input.untrusted !== undefined && input.untrusted !== null) payload = { ...payload, untrusted: redactValue(input.untrusted, stats) };
  const budget = Math.max(1000, Math.floor((cfg.max_state_tokens || 28000) * 4) - JSON.stringify(questions).length);
  const tr = truncateToBudget(payload, budget);
  payload = tr.value;
  Object.assign(meta, { redactions: stats.count, truncated: tr.truncated });

  if (process.env.JEV_RECORD) {
    try {
      fs.writeFileSync(
        process.env.JEV_RECORD,
        JSON.stringify({ rule: input.rule, model: meta.model, state: payload, questions, truncated: tr.truncated, redactions: stats.count }, null, 2),
        { mode: 0o600 },
      );
    } catch {
      /* debug aid only */
    }
  }

  if (mock) {
    let text;
    try {
      text = fs.readFileSync(mock, "utf8");
    } catch {
      process.stderr.write(`jev-ask: bad input: JEV_MOCK fixture unreadable: ${mock}\n`);
      return finish(EXIT_BAD_INPUT);
    }
    let parsed = null;
    try {
      parsed = JSON.parse(text);
    } catch {
      /* fixture need not be JSON for tests */
    }
    shadowLog({ ...meta, outcome: "ok", source: "mock", answers: parsed?.answers ?? null, latency_ms: parsed?.latency_ms ?? 0, wall_ms: Date.now() - t0 });
    return finish(EXIT_OK, text);
  }

  if (!process.env.JEV_BACKEND_FIXTURE && !resolveKey()) return fail("no_key");

  const timeout = input.timeout_ms ?? cfg.default_timeout_ms ?? 1000;
  const deadline = t0 + timeout;
  const req = { model, state: payload, questions };
  let out = null;
  let source = "direct";
  try {
    if (process.env.JEV_NO_DAEMON !== "1") {
      const d = await viaDaemon(req, deadline);
      if (d.kind === "timeout") return fail("timeout");
      if (d.kind === "ok") {
        if (!d.res.ok) return fail(d.res.reason || "daemon_error");
        out = d.res;
        source = "daemon";
      }
    }
    if (!out) {
      const left = deadline - Date.now();
      if (left <= 0) return fail("timeout");
      out = await Promise.race([
        callGateway({ ...req, timeout_ms: left }),
        sleep(left).then(() => {
          throw unavailable("timeout");
        }),
      ]);
    }
  } catch (e) {
    return fail(e instanceof JevError ? e.reason : `error:${e?.name}`);
  }
  const result = { answers: out.answers, model: out.model, latency_ms: out.latency_ms, cost_usd: out.cost_usd };
  shadowLog({ ...meta, outcome: "ok", source, answers: result.answers, latency_ms: result.latency_ms, cost_usd: result.cost_usd, wall_ms: Date.now() - t0 });
  return finish(EXIT_OK, JSON.stringify(result) + "\n");
}

async function main() {
  const flag = process.argv[2];
  if (flag === "--daemon") return daemonMain();
  if (flag === "--check") {
    // Prints one token and exits 3 when Jev gates are degraded to regex; silent exit 0 when healthy.
    let reason = null;
    if (killSwitchOn()) reason = "kill_switch";
    else if (!process.env.JEV_MOCK && !process.env.JEV_BACKEND_FIXTURE && !resolveKey()) reason = "no_key";
    else if (!process.env.JEV_MOCK && !process.env.JEV_BACKEND_FIXTURE && !sdkInstalled()) reason = "no_sdk";
    return finish(reason ? EXIT_UNAVAILABLE : EXIT_OK, reason ? reason + "\n" : "");
  }
  if (flag === "--warm") {
    if (process.env.JEV_MOCK || process.env.JEV_NO_DAEMON === "1" || (!process.env.JEV_BACKEND_FIXTURE && (!resolveKey() || !sdkInstalled()))) return finish(EXIT_UNAVAILABLE);
    const sock = sockPath();
    try {
      await rpc(sock, { op: "ping" }, Date.now() + 500);
      return finish(EXIT_OK);
    } catch (e) {
      if (!notRunning(e)) return finish(EXIT_UNAVAILABLE);
    }
    return finish(startDaemon(sock) ? EXIT_OK : EXIT_UNAVAILABLE);
  }
  if (flag === "--status" || flag === "--stop") {
    try {
      const r = await rpc(sockPath(), { op: flag === "--status" ? "ping" : "stop" }, Date.now() + 1000);
      return finish(EXIT_OK, flag === "--status" ? JSON.stringify(r) + "\n" : "");
    } catch {
      return finish(EXIT_UNAVAILABLE);
    }
  }
  return ask();
}

main().catch((e) => {
  process.stderr.write(`jev-ask: unavailable: internal:${e?.name || "Error"}\n`);
  process.exit(EXIT_UNAVAILABLE);
});
