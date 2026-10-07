import type { Change, Check, FeedKind, Task, TaskStatus, Verdict } from "../types";

// Pure data: everything here is testable without the engine.

type Args = Record<string, unknown>;
type Block = { type: string; text?: string; thinking?: string };

export const str = (v: unknown) => (typeof v === "string" ? v : "");
export const oneLine = (s: string) => s.replace(/\s+/g, " ").trim();
export const clip = (s: string, n: number) =>
  s.length <= n ? s : `${s.slice(0, Math.max(0, n - 1))}…`;
const isStatus = (v: unknown): v is TaskStatus =>
  v === "pending" || v === "in_progress" || v === "completed";

// ---------------------------------------------------------------- drawing

// Colours are Claude Code theme keys, never hex: they follow the person's
// light, dark or colour-blind theme, and this terminal rounds hex to 256
// colours. Clay orange (`claude`) marks what is live; green, amber and red
// carry status, as on any dashboard.
export const C = {
  live: "claude",
  ok: "success",
  warn: "warning",
  bad: "error",
  asked: "permission",
  text: "text",
  dim: "inactive",
  frame: "subtle",
} as const;

// A dashboard tone for a percentage used: green, then amber from 50, red from 80.
export const tone = (pct: number) =>
  pct >= 80 ? C.bad : pct >= 50 ? C.warn : C.ok;

const EIGHTHS = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"];

// A smooth meter: whole cells, then an eighth-cell edge, then the empty track.
export const meter = (pct: number, cells: number) => {
  const width = Math.max(4, cells);
  const exact = (Math.min(100, Math.max(0, pct)) / 100) * width;
  const whole = Math.floor(exact);
  const edge = EIGHTHS[Math.round((exact - whole) * 8)] ?? "";
  const on = "█".repeat(whole) + (whole < width ? edge : "");
  return { on, off: "░".repeat(Math.max(0, width - [...on].length)) };
};

// A progress bar of `cells` cells (never fewer than 4), filled in proportion.
export const bar = (done: number, total: number, cells: number) => {
  const width = Math.max(4, cells);
  const full = total === 0 ? 0 : Math.round((done / total) * width);
  return `${"█".repeat(full)}${"░".repeat(width - full)}`;
};

export const duration = (ms: number) => {
  const s = Math.max(0, Math.round(ms / 1000));
  if (s < 60) return `${s}s`;
  if (s < 3600)
    return `${Math.floor(s / 60)}m${String(s % 60).padStart(2, "0")}s`;
  return `${Math.floor(s / 3600)}h${String(Math.floor((s % 3600) / 60)).padStart(2, "0")}m`;
};

// A running timer, as a stopwatch reads: 0:42, 12:05, 1h04.
export const timer = (ms: number) => {
  const s = Math.max(0, Math.floor(ms / 1000));
  const m = Math.floor(s / 60);
  return m < 60
    ? `${m}:${String(s % 60).padStart(2, "0")}`
    : `${Math.floor(m / 60)}h${String(m % 60).padStart(2, "0")}`;
};

// Wall-clock time of day, HH:MM.
export const clockTime = (ms: number) => {
  const d = new Date(ms);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
};

export const kTokens = (n: number) =>
  n >= 1_000_000
    ? `${(n / 1_000_000).toFixed(1)}M`
    : n >= 1000
      ? `${Math.round(n / 1000)}k`
      : String(n);

// claude-opus-5-5[1m] → Opus 5.5; anything unrecognised is shown as given.
export const prettyModel = (id: string) => {
  const m = /claude-([a-z]+)-(\d+)(?:-(\d{1,2}))?(?![\d])/i.exec(id);
  if (!m) return id ? clip(id, 18) : "—";
  const name = m[1] ? m[1][0]?.toUpperCase() + m[1].slice(1) : "";
  return `${name} ${m[2]}${m[3] ? `.${m[3]}` : ""}`;
};

// ---------------------------------------------------------------- activity

// The one argument that says what a call is about, for the common tools.
export const gist = (tool: string, a: Args) => {
  const raw =
    str(a.subject) ||
    str(a.description) ||
    str(a.command) ||
    str(a.file_path) ||
    str(a.pattern) ||
    str(a.query) ||
    str(a.url) ||
    str(a.skill) ||
    str(a.prompt);
  const what = raw.startsWith("/") ? basename(raw) : raw;
  return oneLine(what ? `${tool} ${what}` : tool);
};

// The feed rows one model response yields: its narration and any thinking
// with visible text. Empty and redacted thinking (most of it, on current
// models) is left out rather than shown as noise.
export const responseItems = (blocks: readonly Block[]) =>
  blocks.flatMap((b) => {
    const kind: FeedKind = b.type === "thinking" ? "thinking" : "say";
    const raw =
      b.type === "thinking" ? b.thinking : b.type === "text" ? b.text : "";
    const text = plain(str(raw));
    return text ? [{ kind, text }] : [];
  });

// Narration as it reads, not as it was written: markdown marks, table rules
// and fences dropped, so a row is the words alone.
export const plain = (s: string) =>
  oneLine(
    s
      .replace(/```[\s\S]*?```/g, " ")
      .replace(/\*\*|__|`/g, "")
      .replace(/^\s*(#{1,6}|[-*+]|\d+\.|>|\|)\s+/gm, "")
      .replace(/\[([^\]]+)\]\([^)]+\)/g, "$1")
      .replace(/\s*\|\s*/g, " · ")
      .replace(/(^|\s)[-:]{3,}(?=\s|$)/g, " "),
  );

// ---------------------------------------------------------------- checklist

export const applyTodos = (list: Task[], todos: unknown): Task[] => [
  ...list.filter((t) => !t.id.startsWith("todo:")),
  ...(Array.isArray(todos) ? (todos as Args[]) : []).map((t, i) => ({
    id: `todo:${i + 1}`,
    subject: oneLine(str(t.content)),
    status: isStatus(t.status) ? t.status : ("pending" as const),
    activeForm: str(t.activeForm) || undefined,
  })),
];

export const addTask = (
  list: Task[],
  made: { id: string; subject: string },
  activeForm: unknown,
): Task[] => [
  ...list.filter((t) => t.id !== `task:${made.id}`),
  {
    id: `task:${made.id}`,
    subject: oneLine(made.subject),
    status: "pending",
    activeForm: str(activeForm) || undefined,
  },
];

export const updateTask = (list: Task[], a: Args): Task[] => {
  const id = `task:${str(a.taskId)}`;
  if (a.status === "deleted") return list.filter((t) => t.id !== id);
  return list.map((t) =>
    t.id === id
      ? {
          ...t,
          subject: str(a.subject) || t.subject,
          activeForm: str(a.activeForm) || t.activeForm,
          status: isStatus(a.status) ? a.status : t.status,
        }
      : t,
  );
};

// ---------------------------------------------------------------- gate

export const verdictOf = (decision: string): Verdict =>
  decision === "allow" ? "allowed" : decision === "deny" ? "denied" : "pending";

// An ask is settled by the call around it: it ran (asked, then approved) or
// it was refused.
export const settle = (checks: Check[], id: string, didRun: boolean) =>
  checks.map((c) =>
    c.id === id && c.verdict === "pending"
      ? { ...c, verdict: didRun ? ("asked" as const) : ("denied" as const) }
      : c,
  );

export const tally = (checks: Check[]) => {
  const n = { allowed: 0, asked: 0, pending: 0, denied: 0 };
  for (const c of checks) n[c.verdict] += 1;
  return n;
};

// ---------------------------------------------------------------- changes

export const EDIT_TOOLS = new Set(["Edit", "MultiEdit", "Write", "NotebookEdit"]);

const lines = (s: unknown) => (str(s) ? str(s).split("\n").length : 0);
const basename = (p: string) => p.split("/").filter(Boolean).pop() ?? p;

// Lines a successful edit added and removed, by its arguments. A Write that
// replaces a file counts its new lines only: the old ones are not in the call.
export const changeOf = (tool: string, a: Args): Change | null => {
  const file = str(a.file_path) || str(a.notebook_path);
  if (!file || !EDIT_TOOLS.has(tool)) return null;
  if (tool === "Write") return { file, added: lines(a.content), removed: 0 };
  if (tool === "NotebookEdit")
    return { file, added: lines(a.new_source), removed: 0 };
  const edits =
    tool === "MultiEdit" && Array.isArray(a.edits) ? (a.edits as Args[]) : [a];
  return edits.reduce<Change>(
    (sum, e) => ({
      file,
      added: sum.added + lines(e.new_string),
      removed: sum.removed + lines(e.old_string),
    }),
    { file, added: 0, removed: 0 },
  );
};

// Changes summed per file, the latest-touched file first.
export const addChange = (list: Change[], c: Change): Change[] => {
  const was = list.find((x) => x.file === c.file);
  const merged = was
    ? { file: c.file, added: was.added + c.added, removed: was.removed + c.removed }
    : c;
  return [merged, ...list.filter((x) => x.file !== c.file)];
};

export const shortFile = basename;
