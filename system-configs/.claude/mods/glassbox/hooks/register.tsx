import { atom, read, update } from "claude-code";
import type { EngineInterface, Register } from "claude-code";

import type {
  AgentRun,
  AgentState,
  Change,
  Check,
  FeedItem,
  FeedKind,
  Loop,
  Phase,
  Task,
} from "../types";
import {
  C,
  addChange,
  addTask,
  applyTodos,
  bar,
  changeOf,
  clip,
  clockTime,
  duration,
  gist,
  kTokens,
  meter,
  oneLine,
  prettyModel,
  responseItems,
  settle,
  shortFile,
  str,
  tally,
  timer,
  tone,
  updateTask,
  verdictOf,
} from "./model";

// glassbox: watch Claude work, in one pane beside the transcript. A box per
// concern (loop, context, plan, agents, gate, changes, activity); a box with
// nothing to show takes no room. It draws nothing in the transcript or in the
// status line, and opens only on /glassbox. Where a surface cannot dock a pane
// (a terminal not in fullscreen) the engine seats it above the prompt, and
// glassbox draws a shorter version there until it is closed. Where no surface
// draws a pane at all, /glassbox answers with the same boxes in text.
//
// It only watches. Every recording hook passes the event on unchanged, and none
// records until a screen has drawn, a remote client has attached or /glassbox
// was typed: a headless session (`claude -p`, the fleet) does none of these
// (its surface roster is empty), so there the hooks are a bare `next(e)`.

const PANE = "glassbox";
const PANE_COLUMNS = 52;
const FEED_MAX = 200;
// Activity rows the pane lists, newest on top; the person scrolls through them.
const ACTIVITY_MAX = 50;
const CHECKS_MAX = 60;
const PLAN_ROWS = 8;
// Seated above the prompt the pane shares the screen with the transcript, so
// it lists fewer rows and skips the context anatomy.
const INLINE_ACTIVITY_ROWS = 8;
const INLINE_PLAN_ROWS = 4;
const PHASES = ["prompt", "think", "tool", "result"];
const PLAN_TOOLS = new Set([
  "TaskCreate",
  "TaskUpdate",
  "TaskGet",
  "TaskList",
  "TodoWrite",
]);

const IDLE_LOOP: Loop = {
  model: "",
  phase: "idle",
  turnStartedAt: null,
  turnEndedAt: null,
  compactions: 0,
};

const tasks = atom({ plugin: "glassbox", key: "tasks" } as const, [] as Task[]);
const agents = atom(
  { plugin: "glassbox", key: "agents" } as const,
  [] as AgentRun[],
);
const feed = atom(
  { plugin: "glassbox", key: "feed" } as const,
  [] as FeedItem[],
);
const checks = atom(
  { plugin: "glassbox", key: "checks" } as const,
  [] as Check[],
);
const changes = atom(
  { plugin: "glassbox", key: "changes" } as const,
  [] as Change[],
);
const loop = atom({ plugin: "glassbox", key: "loop" } as const, IDLE_LOOP);

type Args = Record<string, unknown>;
type Block = { type: string; text?: string; thinking?: string };
type Usage = {
  input_tokens?: number;
  cache_read_input_tokens?: number;
  cache_creation_input_tokens?: number;
};

// Module state (restarts on reload, which is fine: it only gates and filters).
let hasScreen = false;
// The agent whose activity the pane shows: an agent id, MAIN for the main
// loop by choice, or null to follow the agent the transcript is viewing.
const MAIN = "main";
let focusId: string | null = null;
// A subagent's counts and ending, kept apart from its row: a fast agent can
// finish a step, a tool or its whole run before agent.spawn has added the
// row, and the spawn merges what arrived early. Each writer records here
// first and updates the row second, and the spawn reads here only after the
// row exists, so every value lands on one or the other.
type Early = {
  ctx: number;
  tools: number;
  end?: { status: AgentState; endedAt: number };
};
const counts = new Map<string, Early>();
const countsOf = (id: string): Early => counts.get(id) ?? { ctx: 0, tools: 0 };

const engineState: Record<string, AgentState> = {
  pending: "running",
  running: "running",
  waiting: "waiting",
  idle: "waiting",
  completed: "done",
  failed: "failed",
  killed: "killed",
};

const feedGlyph: Record<FeedKind, string> = {
  tool: "▸",
  thinking: "∴",
  say: "›",
  agent: "◆",
  deny: "✗",
};

async function push($: EngineInterface, item: Omit<FeedItem, "at">) {
  const at = await $.clock.now();
  await update($, feed, (list) => [...list, { ...item, at }].slice(-FEED_MAX));
}

const setPhase = ($: EngineInterface, phase: Phase) =>
  update($, loop, (l) => (l.phase === phase ? l : { ...l, phase }));

async function reset($: EngineInterface) {
  focusId = null;
  counts.clear();
  await update($, tasks, () => []);
  await update($, agents, () => []);
  await update($, feed, () => []);
  await update($, checks, () => []);
  await update($, changes, () => []);
  await update($, loop, (l): Loop => ({ ...IDLE_LOOP, model: l.model }));
}

// Agent status as the engine knows it (failed, killed, waiting), over our own
// record; an agent the engine has already dropped keeps what we last saw.
async function liveAgents($: EngineInterface) {
  const runs = await read($, agents);
  const listed = await $.agent.list().catch(() => []);
  const known = new Map(
    listed.map((a) => [a.id, engineState[a.status] ?? "running"]),
  );
  return runs.map((r) => {
    const status = known.get(r.id);
    return status && r.status !== status ? { ...r, status } : r;
  });
}

// The surfaces that show a mod's panes; elsewhere hooks run but nothing draws
// (code.claude.com/docs/en/plugins/mods/overview, "Where mods run").
const DRAWING_SURFACES = new Set(["terminal", "desktop"]);
const SNAPSHOT_ACTIVITY = 10;

// The pane's boxes as markdown, for a surface that draws no pane. A box with
// nothing to show is left out, as in the pane.
async function snapshot($: EngineInterface, wasRecording: boolean) {
  const [l, list, runs, items, gate, edits, now, usage] = await Promise.all([
    read($, loop),
    read($, tasks),
    liveAgents($),
    read($, feed),
    read($, checks),
    read($, changes),
    $.clock.now(),
    $.session.usage({ breakdown: "summary" }).catch(() => null),
  ]);
  const model = prettyModel(l.model || usage?.context.breakdown?.model || "");
  const timing =
    l.phase !== "idle" && l.turnStartedAt !== null
      ? `${l.phase} · ${timer(now - l.turnStartedAt)}`
      : l.turnStartedAt !== null && l.turnEndedAt !== null
        ? `idle · last turn ${duration(l.turnEndedAt - l.turnStartedAt)}`
        : "idle";
  const out = [`**glassbox** · ${[model, timing].filter(Boolean).join(" · ")}`];

  const ctx = usage?.context;
  if (ctx?.percent !== undefined && ctx.percent !== null) {
    const size =
      ctx.tokens !== undefined
        ? ` (${kTokens(ctx.tokens)}/${kTokens(ctx.window)})`
        : "";
    const fold = l.compactions > 0 ? ` · compacted ${l.compactions}×` : "";
    out.push(`**context** ${Math.round(ctx.percent)}%${size}${fold}`);
  }
  if (list.length > 0) {
    const done = list.filter((x) => x.status === "completed").length;
    out.push(`**plan** ${done}/${list.length}`);
    for (const x of list.slice(0, PLAN_ROWS)) {
      const text =
        x.status === "in_progress" ? (x.activeForm ?? x.subject) : x.subject;
      out.push(
        x.status === "completed"
          ? `- [x] ${text}`
          : x.status === "in_progress"
            ? `- [ ] **${text}**`
            : `- [ ] ${text}`,
      );
    }
    if (list.length > PLAN_ROWS) out.push(`- +${list.length - PLAN_ROWS} more`);
  }
  if (runs.length > 0) {
    out.push(`**agents** ${runs.length}`);
    for (const r of runs.slice(-6)) {
      const took = timer((r.endedAt ?? now) - r.startedAt);
      out.push(`- ${r.status} · ${r.description} · ${r.tools} tools · ${took}`);
    }
  }
  if (gate.length > 0) {
    const n = tally(gate);
    out.push(
      `**gate** ${n.allowed} allowed · ${n.asked} asked · ${n.pending} waiting · ${n.denied} denied`,
    );
  }
  if (edits.length > 0) {
    out.push(`**changes** ${edits.length} files`);
    for (const c of edits.slice(0, 6)) {
      const about = c.approx ? "~" : "";
      out.push(`- ${shortFile(c.file)} ${about}+${c.added} −${c.removed}`);
    }
  }
  const shown = items
    .filter((i) => !i.agentId)
    .slice(-SNAPSHOT_ACTIVITY)
    .reverse();
  if (shown.length > 0) {
    out.push("**activity**");
    for (const i of shown)
      out.push(`- ${clockTime(i.at)} ${feedGlyph[i.kind]} ${oneLine(i.text)}`);
  } else if (!wasRecording) {
    out.push(
      "Recording from now: run /glassbox again to see plan, agents and activity.",
    );
  }
  return out.join("\n");
}

// A watcher must never stand in the way: a hook that fails hands the event on
// as if it were not there (replay-safe when it had already called `next`).
const passThrough = <E, R>(_$: unknown, e: E, next: (e: E) => R) => next(e);

export const register: Register = (on) => {
  on("session.start", async ($, e, next) => {
    await $.command.register({
      name: "glassbox",
      description:
        "Open the glassbox pane: loop, context, plan, agents, permissions, changes, activity",
    });
    return next(e);
  });

  on("session.end", async ($, e, next) => {
    if (e.reason === "clear") await reset($);
    return next(e);
  });

  // Opens the pane and prints nothing where a surface draws one (the terminal,
  // the desktop app). Where nothing draws (the VS Code chat panel, a cloud
  // session, Remote Control from claude.ai or the phone) it answers with a
  // snapshot in text instead, as does
  // `/glassbox text` anywhere, and records from then on for the next one.
  on("command.run", { command: "glassbox" }, async ($, e) => {
    const surfaces = await $.session.surfaces();
    const draws = surfaces.some((s) => DRAWING_SURFACES.has(s));
    // The origin names how a command came, not which client typed it, and a
    // client that draws nothing (VS Code) need not join the roster. Typed at
    // the terminal, the person sees its pane. Any other origin opens the pane
    // only with the desktop app attached; Remote Control (claude.ai, the
    // phone) never, since its pane would open on the machine, out of sight.
    const kind = e.origin?.kind ?? "composer";
    const seen =
      kind === "composer" ||
      (kind !== "bridge" && surfaces.includes("desktop"));
    if (!draws || !seen || (e.args ?? "").trim() === "text") {
      const text = await snapshot($, hasScreen);
      hasScreen = true;
      return { text };
    }
    const opened = await $.ui.open({
      id: PANE,
      title: "glassbox",
      columns: PANE_COLUMNS,
    });
    if (!opened.isPlaced) $.ui.toast(`glassbox: ${opened.reason}`);
    return {};
  });

  on("prompt.submit", async ($, e, next) => {
    if (!hasScreen) return next(e);
    const now = await $.clock.now();
    await update(
      $,
      loop,
      (l): Loop => ({
        ...l,
        phase: "prompt",
        turnStartedAt: now,
        turnEndedAt: null,
      }),
    );
    return next(e);
  }).catch(passThrough);

  // One model request: the main loop is thinking; a subagent's context grows.
  on("turn.step", async function* ($, e, next) {
    if (!hasScreen) return yield* next(e);
    if (!e.agentId) {
      await update(
        $,
        loop,
        (l): Loop => ({ ...l, model: e.model, phase: "think" }),
      );
      return yield* next(e);
    }
    const result = yield* next(e);
    const u = (result.usage ?? {}) as Usage;
    const ctx =
      (u.input_tokens ?? 0) +
      (u.cache_read_input_tokens ?? 0) +
      (u.cache_creation_input_tokens ?? 0);
    const id = e.agentId;
    if (ctx > 0) {
      counts.set(id, { ...countsOf(id), ctx });
      await update($, agents, (list) =>
        list.map((r) => (r.id === id ? { ...r, ctx } : r)),
      );
    }
    return result;
  });

  on("turn.complete", async ($, e, next) => {
    if (!hasScreen) return next(e);
    const now = await $.clock.now();
    if (e.agentId) {
      const status: AgentState =
        e.reason === "answer"
          ? "done"
          : e.reason === "aborted"
            ? "killed"
            : "failed";
      const id = e.agentId;
      counts.set(id, { ...countsOf(id), end: { status, endedAt: now } });
      await update($, agents, (list) =>
        list.map((a) =>
          a.id === e.agentId && a.status === "running"
            ? { ...a, status, endedAt: now }
            : a,
        ),
      );
    } else {
      await update(
        $,
        loop,
        (l): Loop => ({ ...l, phase: "idle", turnEndedAt: now }),
      );
    }
    return next(e);
  });

  on("session.compact", async ($, e, next) => {
    const done = await next(e);
    if (hasScreen && !e.agentId && e.trigger !== "precompute")
      await update(
        $,
        loop,
        (l): Loop => ({ ...l, compactions: l.compactions + 1 }),
      );
    return done;
  });

  on("agent.spawn", async ($, e, next) => {
    const started = await next(e);
    if (!hasScreen || !("agentId" in started) || !started.agentId)
      return started;
    const run: AgentRun = {
      id: started.agentId,
      description: e.description,
      type: e.subagentType,
      status: "running",
      startedAt: await $.clock.now(),
      tools: 0,
      ctx: 0,
    };
    await update($, agents, (list) => [...list, run]);
    // Read after the row exists, so a count arriving now lands on one or other.
    const early = countsOf(run.id);
    counts.delete(run.id);
    if (early.ctx > 0 || early.tools > 0 || early.end)
      await update($, agents, (list) =>
        list.map((r) =>
          r.id === run.id
            ? {
                ...r,
                ctx: r.ctx || early.ctx,
                tools: Math.max(r.tools, early.tools),
                ...(early.end && r.status === "running" ? early.end : {}),
              }
            : r,
        ),
      );
    await push($, {
      agentId: e.parentAgentId,
      kind: "agent",
      text: `${e.subagentType}: ${e.description}`,
    });
    return started;
  }).catch(passThrough);

  // Every permission verdict; an ask is settled by the tool.call around it.
  on("tool.check", async ($, e, next) => {
    const verdict = await next(e);
    if (!hasScreen || !e.tool_use_id) return verdict;
    const check: Check = {
      id: e.tool_use_id,
      tool: e.tool,
      verdict: verdictOf(verdict.decision),
    };
    await update($, checks, (list) => [...list, check].slice(-CHECKS_MAX));
    return verdict;
  }).catch(passThrough);

  on("tool.call", async ($, e, next) => {
    if (!hasScreen) return next(e);
    const a = e as unknown as Args;
    const { tool, agentId } = e;

    // Shown as it starts, without holding the call up. The plan box shows the
    // main loop's checklist, so the feed leaves those calls out; a subagent's
    // stay, since the plan never shows them.
    const inPlan = PLAN_TOOLS.has(tool) && !agentId;
    if (!inPlan) void push($, { agentId, kind: "tool", text: gist(tool, a) });
    if (!agentId) await setPhase($, "tool");
    const ran = await next(e);
    const didRun = !("deny" in ran && ran.deny);
    await update($, checks, (list) => settle(list, e.tool_use_id, didRun));

    if (agentId) {
      counts.set(agentId, {
        ...countsOf(agentId),
        tools: countsOf(agentId).tools + 1,
      });
      await update($, agents, (list) =>
        list.map((r) => (r.id === agentId ? { ...r, tools: r.tools + 1 } : r)),
      );
    } else {
      await setPhase($, "result");
    }
    if (!didRun) {
      await push($, {
        agentId,
        kind: "deny",
        text: `denied · ${gist(tool, a)}`,
      });
      return ran;
    }
    if (ran.isError) {
      // A failed checklist call never reaches the plan, so the feed shows it.
      if (inPlan) await push($, { kind: "tool", text: gist(tool, a) });
      return ran;
    }

    const out = ran.result;
    const change = changeOf(
      tool,
      a,
      out && typeof out === "object" ? (out as Args) : {},
    );
    if (change) await update($, changes, (list) => addChange(list, change));

    // The checklist is the main loop's plan.
    if (agentId) return ran;
    if (tool === "TodoWrite") {
      await update($, tasks, (list) => applyTodos(list, a.todos));
    } else if (tool === "TaskCreate") {
      const made = (
        ran.result as { task?: { id: string; subject: string } } | undefined
      )?.task;
      if (made)
        await update($, tasks, (list) => addTask(list, made, a.activeForm));
    } else if (tool === "TaskUpdate") {
      await update($, tasks, (list) => updateTask(list, a));
    }
    return ran;
  }).catch(passThrough);

  // Narration and reasoning: each response row, main loop and subagents alike.
  on("session.append", { door: "response" }, async ($, e, next) => {
    if (!hasScreen) return next(e);
    for (const item of responseItems(e.message.content as unknown as Block[])) {
      await push($, { agentId: e.agentId, ...item });
    }
    return next(e);
  }).catch(passThrough);

  // The space above the prompt is only how glassbox learns a screen exists, so
  // it starts recording before its pane opens. It draws nothing there.
  on("ui.render", { component: "AbovePrompt" }, async (_$, e, next) => {
    hasScreen = true;
    return next(e);
  });

  // A remote client (desktop, the phone, VS Code) joining is a screen too: it
  // may never draw the space above the prompt before /glassbox is typed.
  on("session.attach", async (_$, e, next) => {
    hasScreen = true;
    return next(e);
  });

  on("ui.render", { component: "Pane", requestId: PANE }, async ($, e) => {
    hasScreen = true;
    const els = $.ui.resolve(e);
    const { Box, Text, Button } = els;

    // Seated above the prompt rather than docked beside the transcript.
    const compact = e.props.placement === "inline";
    const planMax = compact ? INLINE_PLAN_ROWS : PLAN_ROWS;

    const hasClient = "Client" in els;
    const W = Math.max(30, e.props.bodyColumns);
    const inner = W - 4;
    const [l, list, runs, items, gate, edits, now, usage] = await Promise.all([
      read($, loop),
      read($, tasks),
      liveAgents($),
      read($, feed),
      read($, checks),
      read($, changes),
      $.clock.now(),
      $.session.usage({ breakdown: "summary", columns: W }).catch(() => null),
    ]);
    const isWorking = l.phase !== "idle";

    // A rounded frame with its title set into the top edge.
    const frame = (
      key: string,
      title: string,
      extra: string,
      extraColor: string,
      rows: unknown[],
    ) => {
      const used = 3 + title.length + (extra ? extra.length + 1 : 0);
      return (
        <Box key={key} flexDirection="column" width={W}>
          <Text color={C.text}>
            <Text color={C.frame}>╭ </Text>
            <Text color={C.text} bold>
              {title}
            </Text>
            {extra ? <Text color={extraColor}>{` ${extra}`}</Text> : null}
            <Text
              color={C.frame}
            >{` ${"─".repeat(Math.max(1, W - used - 1))}╮`}</Text>
          </Text>
          {rows.map((row, i) => (
            <Box key={`${key}-${i}`}>
              <Text color={C.frame}>│ </Text>
              <Box width={inner}>{row as never}</Box>
              <Text color={C.frame}> │</Text>
            </Box>
          ))}
          <Text color={C.frame}>{`╰${"─".repeat(W - 2)}╯`}</Text>
        </Box>
      );
    };

    const ticker = (
      key: string,
      since: number,
      endAt: number | null,
      color: string,
      spin: boolean,
    ) =>
      hasClient ? (
        <els.Client
          key={key}
          module="./ticker.tsx"
          props={{ since, now, endAt, color, spin }}
        />
      ) : (
        <Text color={color}>{timer((endAt ?? now) - since)}</Text>
      );

    // ---- one top line: the loop on the left, the model and the turn's clock
    // on the right (the pane's tab already names glassbox), then a blank row.
    const model = prettyModel(l.model || usage?.context.breakdown?.model || "");
    const timing =
      isWorking && l.turnStartedAt !== null
        ? null
        : l.turnStartedAt !== null && l.turnEndedAt !== null
          ? `last ${duration(l.turnEndedAt - l.turnStartedAt)}`
          : "idle";
    const loopW = Math.max(
      12,
      W - `${model} · ${timing ?? "00:00"}`.length - 1,
    );
    const header = (
      <Box
        key="header"
        justifyContent="space-between"
        width={W}
        marginBottom={1}
      >
        {hasClient ? (
          <els.Client
            key="loop"
            module="./loop.tsx"
            width={loopW}
            height={1}
            props={{ phase: l.phase, phases: PHASES }}
          />
        ) : (
          <Text color={C.dim}>
            {PHASES.map((p) => (p === l.phase ? p.toUpperCase() : p)).join(
              " › ",
            )}
          </Text>
        )}
        <Box>
          <Text color={C.dim}>{`${model} · `}</Text>
          {timing === null && l.turnStartedAt !== null ? (
            ticker("turn", l.turnStartedAt, null, C.live, false)
          ) : (
            <Text color={C.dim}>{timing}</Text>
          )}
        </Box>
      </Box>
    );

    // ---- context: the window, what fills it (as /context counts), cost, limits
    const ctx = usage?.context;
    const pct = ctx?.percent ?? null;
    const bd = ctx?.breakdown;
    const contextRows: unknown[] = [];
    if (pct !== null) {
      const tail = ` ${Math.round(pct)}%`;
      const size =
        ctx?.tokens !== undefined
          ? ` ${kTokens(ctx.tokens)}/${kTokens(ctx.window)}`
          : "";
      const m = meter(pct, inner - tail.length - size.length - 4);
      contextRows.push(
        <Text color={C.text} wrap="truncate">
          <Text color={tone(pct)}>{m.on}</Text>
          <Text color={C.frame}>{m.off}</Text>
          <Text color={C.text} bold>
            {tail}
          </Text>
          <Text color={C.dim}>{size}</Text>
          {l.compactions > 0 ? (
            <Text color={C.warn}>{` ⟲${l.compactions}`}</Text>
          ) : null}
        </Text>,
      );
    } else {
      contextRows.push(<Text color={C.dim}>No reading yet.</Text>);
    }
    if (!compact && bd && bd.rawMaxTokens > 0) {
      // Anatomy: one strip, each category in the colour /context gives it.
      const used = bd.categories.filter(
        (c) => c.kind === "used" && c.tokens > 0,
      );
      const cells = used.map((c) => ({
        c,
        n: Math.max(1, Math.round((c.tokens / bd.rawMaxTokens) * inner)),
      }));
      const filled = cells.reduce((s, x) => s + x.n, 0);
      contextRows.push(
        <Text color={C.text} wrap="truncate">
          {cells.map((x) => (
            <Text color={x.c.color}>{"▆".repeat(x.n)}</Text>
          ))}
          <Text color={C.frame}>{"▁".repeat(Math.max(0, inner - filled))}</Text>
        </Text>,
      );
      contextRows.push(
        <Text color={C.text} wrap="truncate">
          {used
            .slice()
            .sort((a, b) => b.tokens - a.tokens)
            .map((c) => (
              <Text color={C.text}>
                <Text color={c.color}>■</Text>
                <Text
                  color={C.dim}
                >{` ${c.name.toLowerCase()} ${kTokens(c.tokens)}  `}</Text>
              </Text>
            ))}
        </Text>,
      );
    }
    if (usage && (usage.cost || usage.rateLimits.length > 0)) {
      contextRows.push(
        <Text color={C.text} wrap="truncate">
          {usage.cost ? (
            <Text
              color={C.text}
              bold
            >{`$${usage.cost.usd.toFixed(2)}   `}</Text>
          ) : null}
          {usage.rateLimits.slice(0, 2).map((r) => {
            const g = meter(r.percentUsed, 6);
            const label =
              r.kind === "five_hour"
                ? "5h"
                : r.kind === "seven_day"
                  ? "7d"
                  : r.kind;
            return (
              <Text color={C.text}>
                <Text color={C.dim}>{`${label} `}</Text>
                <Text color={tone(r.percentUsed)}>{g.on}</Text>
                <Text color={C.frame}>{g.off}</Text>
                <Text color={C.dim}>{` ${Math.round(r.percentUsed)}%   `}</Text>
              </Text>
            );
          })}
        </Text>,
      );
    }

    // ---- plan
    const done = list.filter((x) => x.status === "completed").length;
    const planRows: unknown[] = [];
    if (list.length > 0) {
      const allDone = done === list.length;
      planRows.push(
        <Text color={allDone ? C.ok : C.live}>
          {bar(done, list.length, inner)}
        </Text>,
      );
      for (const x of list.slice(0, planMax)) {
        const text =
          x.status === "in_progress" ? (x.activeForm ?? x.subject) : x.subject;
        planRows.push(
          x.status === "completed" ? (
            <Text color={C.text} wrap="truncate">
              <Text color={C.ok}>✓ </Text>
              <Text color={C.dim}>{clip(text, inner - 2)}</Text>
            </Text>
          ) : x.status === "in_progress" ? (
            <Text wrap="truncate" color={C.live} bold>
              {`◐ ${clip(text, inner - 2)}`}
            </Text>
          ) : (
            <Text
              color={C.text}
              wrap="truncate"
            >{`○ ${clip(text, inner - 2)}`}</Text>
          ),
        );
      }
      if (list.length > planMax)
        planRows.push(
          <Text color={C.dim}>{`+${list.length - planMax} more`}</Text>,
        );
    }

    // ---- agents
    const count = (...s: AgentState[]) =>
      runs.filter((r) => s.includes(r.status)).length;
    const running = count("running");
    const waiting = count("waiting");
    const failed = count("failed", "killed");
    // The title names what is true now: running, else every state that ended.
    const agentsTitle =
      running > 0
        ? `${running} running`
        : [
            waiting > 0 ? `${waiting} waiting` : "",
            count("done") > 0 ? `${count("done")} done` : "",
            failed > 0 ? `${failed} failed` : "",
          ]
            .filter(Boolean)
            .join(" · ");
    const agentsColor =
      running > 0 ? C.live : waiting > 0 ? C.warn : failed > 0 ? C.bad : C.dim;
    const agentRows = runs.slice(-6).map((r) => {
      const isLive = r.status === "running";
      const glyph = isLive
        ? "◐"
        : r.status === "done"
          ? "✓"
          : r.status === "waiting"
            ? "◌"
            : "✗";
      const color = isLive
        ? C.live
        : r.status === "done"
          ? C.ok
          : r.status === "waiting"
            ? C.warn
            : C.bad;
      const calls = `${r.tools} ${r.tools === 1 ? "tool" : "tools"} ·`;
      const meta = r.ctx > 0 ? `${kTokens(r.ctx)} ctx · ${calls}` : calls;
      return (
        <Box width={inner} justifyContent="space-between">
          <Box>
            <Text color={color} bold={isLive}>{`${glyph} `}</Text>
            <Button
              key={`agent-${r.id}`}
              plain
              label={clip(r.description, Math.max(8, inner - 22))}
              dimColor={!isLive && focusId !== r.id}
              onPress={() => {
                focusId = focusId === r.id ? MAIN : r.id;
                return update($, feed, (f) => [...f]);
              }}
            />
          </Box>
          <Box>
            <Text color={C.dim}>{`${meta} `}</Text>
            {ticker(
              `agent-clock-${r.id}`,
              r.startedAt,
              r.endedAt ?? (isLive ? null : now),
              isLive ? C.live : C.dim,
              isLive,
            )}
          </Box>
        </Box>
      );
    });

    // ---- gate: one cell per permission check
    const n = tally(gate);
    const cellColor = (c: Check) =>
      c.verdict === "allowed"
        ? C.ok
        : c.verdict === "asked"
          ? C.asked
          : c.verdict === "pending"
            ? C.warn
            : C.bad;
    const gateRows: unknown[] = gate.length
      ? [
          <Text color={C.text} wrap="truncate">
            {gate.slice(-inner).map((c) => (
              <Text color={cellColor(c)}>
                {c.verdict === "denied" ? "✗" : "■"}
              </Text>
            ))}
          </Text>,
          <Text color={C.text} wrap="truncate">
            <Text color={C.ok}>■</Text>
            <Text color={C.dim}>{` ${n.allowed} allowed  `}</Text>
            <Text color={C.asked}>■</Text>
            <Text color={C.dim}>{` ${n.asked} asked  `}</Text>
            {n.pending > 0 ? (
              <Text color={C.warn}>{`■ ${n.pending} waiting  `}</Text>
            ) : null}
            <Text
              color={n.denied > 0 ? C.bad : C.dim}
            >{`✗ ${n.denied} denied`}</Text>
          </Text>,
        ]
      : [];

    // ---- changes: lines added and removed per file, scaled to the largest
    const most = Math.max(1, ...edits.map((c) => c.added + c.removed));
    const scale = 10;
    const changeRows = edits.slice(0, 6).map((c) => {
      // Round the whole bar once, then split it, so the two never overflow.
      const cells = Math.round(((c.added + c.removed) / most) * scale);
      const plus = Math.min(cells, Math.round((c.added / most) * scale));
      const minus = cells - plus;
      // "~" marks an estimate: counted from the call, without the tool's diff.
      const about = c.approx ? "~" : "";
      const nums = `${about}+${c.added} −${c.removed}`;
      return (
        <Box width={inner} justifyContent="space-between">
          <Text color={C.text} wrap="truncate">
            {clip(shortFile(c.file), inner - scale - nums.length - 3)}
          </Text>
          <Text color={C.text}>
            <Text color={C.ok}>{"▮".repeat(plus)}</Text>
            <Text color={C.bad}>{"▮".repeat(minus)}</Text>
            <Text color={C.frame}>
              {"·".repeat(Math.max(0, scale - plus - minus))}
            </Text>
            <Text color={C.dim}>{` ${about}`}</Text>
            <Text color={C.ok}>{`+${c.added}`}</Text>
            <Text color={C.bad}>{` −${c.removed}`}</Text>
          </Text>
        </Box>
      );
    });
    if (edits.length > 6)
      changeRows.push(
        <Text color={C.dim}>{`+${edits.length - 6} more files`}</Text>,
      );
    const totalAdded = edits.reduce((s, c) => s + c.added, 0);
    const totalRemoved = edits.reduce((s, c) => s + c.removed, 0);

    // ---- activity: newest first, the last ACTIVITY_MAX; one agent when picked
    const viewed =
      focusId === MAIN ? null : (focusId ?? e.props.view?.agentId ?? null);
    const focus = viewed ? runs.find((r) => r.id === viewed) : undefined;
    const shown = items
      .filter((i) => (viewed ? i.agentId === viewed : !i.agentId))
      .slice(-(compact ? INLINE_ACTIVITY_ROWS : ACTIVITY_MAX))
      .reverse();
    const feedColor = (k: FeedKind) =>
      k === "deny"
        ? C.bad
        : k === "agent"
          ? C.live
          : k === "thinking"
            ? C.dim
            : C.text;
    const activityRows: unknown[] = shown.length
      ? shown.map((i) => (
          <Text color={C.text} wrap="truncate">
            <Text color={C.dim}>{`${clockTime(i.at)} `}</Text>
            <Text color={feedColor(i.kind)}>{`${feedGlyph[i.kind]} `}</Text>
            <Text color={feedColor(i.kind)} italic={i.kind === "thinking"}>
              {clip(i.text, inner - 8)}
            </Text>
          </Text>
        ))
      : [<Text color={C.dim}>Nothing yet.</Text>];
    if (focus)
      activityRows.unshift(
        <Button
          key="back"
          plain
          label="← main"
          onPress={() => {
            focusId = MAIN;
            return update($, feed, (f) => [...f]);
          }}
        />,
      );

    return (
      <Box flexDirection="column" width={W}>
        {header}
        {frame(
          "context",
          "context",
          pct !== null ? `${Math.round(pct)}%` : "",
          pct !== null ? tone(pct) : C.dim,
          contextRows,
        )}
        {list.length > 0
          ? frame(
              "plan",
              "plan",
              `${done}/${list.length}`,
              done === list.length ? C.ok : C.live,
              planRows,
            )
          : null}
        {runs.length > 0
          ? frame("agents", "agents", agentsTitle, agentsColor, agentRows)
          : null}
        {gate.length > 0
          ? frame(
              "gate",
              "gate",
              `${gate.length} checks`,
              n.denied > 0 ? C.bad : C.dim,
              gateRows,
            )
          : null}
        {edits.length > 0
          ? frame(
              "changes",
              "changes",
              `${edits.length} files ${edits.some((c) => c.approx) ? "~" : ""}+${totalAdded} −${totalRemoved}`,
              C.dim,
              changeRows,
            )
          : null}
        {frame(
          "activity",
          focus ? `activity · ${clip(focus.description, 20)}` : "activity",
          "",
          C.dim,
          activityRows,
        )}
      </Box>
    );
  });
};
