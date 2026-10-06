import { atom, read, update } from "claude-code";
import type { EngineInterface, Register } from "claude-code";

import type { AgentRun, AgentState, FeedItem, FeedKind, Task } from "../types";

// glassbox: a live view of what Claude is doing. A band above the prompt
// (progress, current step, running agents, elapsed) and a sidebar pane
// (checklist, subagents you can drill into, activity feed).
//
// It only watches. Every recording hook passes the event on unchanged, and none
// records until a screen has drawn: a headless session (`claude -p`, the fleet)
// never draws, so there the hooks are a bare `next(e)`.

const PANE = "glassbox";
const FEED_MAX = 400;
// Activity rows the pane lists, newest on top; the person scrolls through them.
const ACTIVITY_MAX = 50;

const tasks = atom({ plugin: "glassbox", key: "tasks" } as const, [] as Task[]);
const agents = atom(
  { plugin: "glassbox", key: "agents" } as const,
  [] as AgentRun[],
);
const feed = atom(
  { plugin: "glassbox", key: "feed" } as const,
  [] as FeedItem[],
);
// The agent the pane is drilled into: an agent id, MAIN when the person chose
// the main loop, or null to follow whichever transcript is open. MAIN has to
// be its own value, or "← main" would fall straight back to the open
// transcript's agent.
const MAIN = "main";
const selected = atom(
  { plugin: "glassbox", key: "selected" } as const,
  null as string | null,
);
const turn = atom(
  { plugin: "glassbox", key: "turn" } as const,
  null as { startedAt: number; endedAt?: number; tools: number } | null,
);
const isBandHidden = atom(
  { plugin: "glassbox", key: "isBandHidden" } as const,
  false,
);
// Bumped once a second while a turn runs. Only glassbox's own drawings read
// it, so the clock redraws them and nothing else on screen.
const second = atom({ plugin: "glassbox", key: "second" } as const, 0);

type Block = { type: string; text?: string; thinking?: string };
type Args = Record<string, unknown>;
type Todo = { content: string; status: Task["status"]; activeForm?: string };

// Module state (restarts on reload, which is fine: it only gates and paces).
let hasScreen = false;
let hasAutoOpened = false;
let tick: { cancel: () => void } | null = null;

const str = (v: unknown) => (typeof v === "string" ? v : "");
const oneLine = (s: string) => s.replace(/\s+/g, " ").trim();
const clip = (s: string, n: number) =>
  s.length <= n ? s : `${s.slice(0, Math.max(0, n - 1))}…`;

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

// The one argument that says what a call is about, for the common tools.
export const gist = (tool: string, a: Args) => {
  const what =
    str(a.subject) ||
    str(a.description) ||
    str(a.command) ||
    str(a.file_path) ||
    str(a.pattern) ||
    str(a.query) ||
    str(a.url) ||
    str(a.skill) ||
    str(a.prompt);
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
    const text = oneLine(str(raw));
    return text ? [{ kind, text }] : [];
  });

const engineState: Record<string, AgentState> = {
  pending: "running",
  running: "running",
  waiting: "waiting",
  idle: "waiting",
  completed: "done",
  failed: "failed",
  killed: "killed",
};

const mark: Record<Task["status"], string> = {
  completed: "✓",
  in_progress: "◐",
  pending: "○",
};
const agentMark: Record<AgentState, string> = {
  running: "●",
  waiting: "◌",
  done: "✓",
  failed: "✗",
  killed: "✗",
};
const glyph: Record<FeedKind, string> = {
  tool: "▸",
  thinking: "∴",
  say: "›",
  agent: "◆",
};

async function push($: EngineInterface, item: Omit<FeedItem, "at">) {
  const at = await $.clock.now();
  await update($, feed, (list) => [...list, { ...item, at }].slice(-FEED_MAX));
}

// Opens the pane once per load, unasked, and only where it docks as a sidebar
// (the engine seats an unasked pane from 144 columns and holds it below that).
function autoOpen($: EngineInterface) {
  if (hasAutoOpened) return;
  hasAutoOpened = true;
  $.ui.open({ id: PANE, title: "glassbox" }).catch(() => {});
}

function startTick($: EngineInterface) {
  tick?.cancel();
  tick = $.clock.every(1000, () => {
    void update($, second, (n) => (n ?? 0) + 1);
  });
}

function stopTick() {
  tick?.cancel();
  tick = null;
}

async function reset($: EngineInterface) {
  stopTick();
  await update($, tasks, () => []);
  await update($, agents, () => []);
  await update($, feed, () => []);
  await update($, selected, () => null);
  await update($, turn, () => null);
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

// A watcher must never stand in the way: a hook that fails hands the event on
// as if it were not there (replay-safe when it had already called `next`).
const passThrough = <E, R>(_$: unknown, e: E, next: (e: E) => R) => next(e);

export const register: Register = (on) => {
  on("session.start", async ($, e, next) => {
    await $.command.register({
      name: "glassbox",
      description:
        "Open the glassbox pane: progress, checklist, subagents, activity",
    });
    return next(e);
  });

  on("session.end", async ($, e, next) => {
    if (e.reason === "clear") await reset($);
    return next(e);
  });

  on("command.run", { command: "glassbox" }, async ($) => {
    await update($, isBandHidden, () => false);
    await $.ui.open({ id: PANE, title: "glassbox" });
    return { text: "glassbox opened." };
  });

  on("prompt.submit", async ($, e, next) => {
    if (!hasScreen) return next(e);
    const startedAt = await $.clock.now();
    await update($, turn, () => ({ startedAt, tools: 0 }));
    startTick($);
    return next(e);
  }).catch(passThrough);

  on("turn.complete", async ($, e, next) => {
    if (!hasScreen) return next(e);
    const now = await $.clock.now();
    if (e.agentId) {
      await update($, agents, (list) =>
        list.map((a) =>
          a.id === e.agentId && a.status === "running"
            ? { ...a, status: "done", endedAt: now }
            : a,
        ),
      );
    } else {
      stopTick();
      await update($, turn, (t) => (t ? { ...t, endedAt: now } : t));
    }
    return next(e);
  });

  on("agent.spawn", async ($, e, next) => {
    const started = await next(e);
    if (!hasScreen || !("agentId" in started) || !started.agentId)
      return started;
    const startedAt = await $.clock.now();
    const run: AgentRun = {
      id: started.agentId,
      description: e.description,
      type: e.subagentType,
      status: "running",
      startedAt,
      tools: 0,
    };
    await update($, agents, (list) => [...list, run]);
    await push($, {
      agentId: e.parentAgentId,
      kind: "agent",
      text: `${e.subagentType}: ${e.description}`,
    });
    autoOpen($);
    return started;
  }).catch(passThrough);

  on("tool.call", async ($, e, next) => {
    if (!hasScreen) return next(e);
    const a = e as unknown as Args;
    const { tool, agentId } = e;

    // Shown as it starts, without holding the call up.
    void push($, { agentId, kind: "tool", text: gist(tool, a) });
    const ran = await next(e);

    if (agentId) {
      await update($, agents, (list) =>
        list.map((r) => (r.id === agentId ? { ...r, tools: r.tools + 1 } : r)),
      );
      return ran;
    }
    await update($, turn, (t) => (t ? { ...t, tools: t.tools + 1 } : t));
    if ("deny" in ran && ran.deny) return ran;
    if (ran.isError) return ran;

    // The checklist is the main loop's plan. Rows are namespaced by source so
    // TodoWrite and the task tools never overwrite each other.
    if (tool === "TodoWrite") {
      const todos = (a.todos as Todo[] | undefined) ?? [];
      await update($, tasks, (list) => [
        ...list.filter((t) => !t.id.startsWith("todo:")),
        ...todos.map((t, i) => ({
          id: `todo:${i + 1}`,
          subject: t.content,
          status: t.status,
          activeForm: t.activeForm,
        })),
      ]);
      if (todos.length) autoOpen($);
    } else if (tool === "TaskCreate") {
      const made = (
        ran.result as { task?: { id: string; subject: string } } | undefined
      )?.task;
      if (made) {
        const row: Task = {
          id: `task:${made.id}`,
          subject: made.subject,
          status: "pending",
          activeForm: str(a.activeForm) || undefined,
        };
        await update($, tasks, (list) => [...list, row]);
        autoOpen($);
      }
    } else if (tool === "TaskUpdate") {
      const id = `task:${str(a.taskId)}`;
      const status = str(a.status);
      await update($, tasks, (list) =>
        status === "deleted"
          ? list.filter((t) => t.id !== id)
          : list.map((t) =>
              t.id === id
                ? {
                    ...t,
                    subject: str(a.subject) || t.subject,
                    activeForm: str(a.activeForm) || t.activeForm,
                    status: (status || t.status) as Task["status"],
                  }
                : t,
            ),
      );
    }
    return ran;
  }).catch(passThrough);

  // Narration and reasoning: each response row, main loop and subagents alike.
  // Empty or redacted thinking (most of it, on current models) is left out.
  on("session.append", { door: "response" }, async ($, e, next) => {
    if (!hasScreen) return next(e);
    for (const item of responseItems(e.message.content as unknown as Block[])) {
      await push($, { agentId: e.agentId, ...item });
    }
    return next(e);
  }).catch(passThrough);

  on("ui.render", { component: "AbovePrompt" }, async ($, e, next) => {
    hasScreen = true;
    await read($, second);
    const list = await read($, tasks);
    const t = await read($, turn);
    const isWorking = e.props.isWorking;
    if (
      e.props.hasSurvey ||
      (await read($, isBandHidden)) ||
      (!isWorking && list.length === 0)
    ) {
      return next(e);
    }

    const { Box, Button, Text } = $.ui.resolve(e);
    const runs = await liveAgents($);
    const live = runs.filter((r) => r.status === "running").length;
    const done = list.filter((x) => x.status === "completed").length;
    const doing = list.find((x) => x.status === "in_progress");
    const now = await $.clock.now();
    const cells = Math.min(
      16,
      Math.max(4, Math.floor(e.props.bodyColumns / 6)),
    );
    const head = list.length
      ? `${bar(done, list.length, cells)} ${done}/${list.length}`
      : `${t?.tools ?? 0} steps`;
    const step = doing
      ? (doing.activeForm ?? doing.subject)
      : isWorking
        ? "working"
        : "idle";
    const tail = [
      step,
      live ? `${live} agent${live > 1 ? "s" : ""} running` : "",
      t ? duration((t.endedAt ?? now) - t.startedAt) : "",
    ]
      .filter(Boolean)
      .join(" · ");
    const room = Math.max(8, e.props.bodyColumns - head.length - 12);

    return (
      <Box>
        <Text color="cyan">{head} </Text>
        <Text dimColor>{clip(tail, room)} </Text>
        <Button
          key="hide"
          label="hide"
          onPress={() => update($, isBandHidden, () => true)}
        />
      </Box>
    );
  });

  on("ui.render", { component: "Pane", requestId: PANE }, async ($, e) => {
    hasScreen = true;
    await read($, second);
    const { Box, Text, Button } = $.ui.resolve(e);
    const width = Math.max(24, e.props.bodyColumns);
    const list = await read($, tasks);
    const runs = await liveAgents($);
    const items = await read($, feed);
    const t = await read($, turn);
    const now = await $.clock.now();
    const done = list.filter((x) => x.status === "completed").length;

    // Follow the agent picked here, else the agent whose transcript is open,
    // unless the person chose the main loop.
    const choice = await read($, selected);
    const pick =
      choice === MAIN ? null : (choice ?? e.props.view.agentId ?? null);
    const focus = pick ? runs.find((r) => r.id === pick) : undefined;
    const shown = items.filter((i) =>
      focus ? i.agentId === focus.id : !i.agentId,
    );
    return (
      <Box flexDirection="column">
        <Text bold>Progress</Text>
        {list.length ? (
          <Box>
            <Text color="cyan">{bar(done, list.length, width - 8)}</Text>
            <Text>{` ${done}/${list.length}`}</Text>
          </Box>
        ) : (
          <Text dimColor>
            {t
              ? `No checklist · ${t.tools} steps · ${duration((t.endedAt ?? now) - t.startedAt)}`
              : "Idle. Activity shows here once Claude starts working."}
          </Text>
        )}

        {list.length > 0 && (
          <Box flexDirection="column" marginTop={1}>
            <Text bold>Checklist</Text>
            {list.map((x) => (
              <Text
                dimColor={x.status === "completed"}
                color={x.status === "in_progress" ? "yellow" : undefined}
              >
                {`${mark[x.status]} ${clip(
                  x.status === "in_progress"
                    ? (x.activeForm ?? x.subject)
                    : x.subject,
                  width - 2,
                )}`}
              </Text>
            ))}
          </Box>
        )}

        {runs.length > 0 && (
          <Box flexDirection="column" marginTop={1}>
            <Text bold>Subagents</Text>
            {runs.map((r) => (
              <Box>
                <Button
                  key={`agent-${r.id}`}
                  label={`${agentMark[r.status]} ${clip(r.description, Math.max(8, width - 30))}`}
                  onPress={() =>
                    update($, selected, (cur) => (cur === r.id ? MAIN : r.id))
                  }
                />
                <Text dimColor>
                  {" "}
                  {r.type} · {r.tools} calls ·{" "}
                  {duration((r.endedAt ?? now) - r.startedAt)}
                </Text>
              </Box>
            ))}
          </Box>
        )}

        <Box flexDirection="column" marginTop={1}>
          <Box>
            <Text bold>
              {focus
                ? `Activity · ${clip(focus.description, width - 22)} `
                : "Activity · main"}
            </Text>
            {focus && (
              <Button
                key="back"
                label="← main"
                onPress={() => update($, selected, () => MAIN)}
              />
            )}
          </Box>
          {shown.length === 0 && <Text dimColor>Nothing yet.</Text>}
          {/* Newest first; the pane scrolls through the last ACTIVITY_MAX. */}
          {shown
            .slice(-ACTIVITY_MAX)
            .reverse()
            .map((i) => {
              const age = duration(now - i.at).padStart(6);
              return (
                <Text
                  dimColor={i.kind === "thinking"}
                  italic={i.kind === "thinking"}
                  color={i.kind === "agent" ? "magenta" : undefined}
                >
                  <Text dimColor>{age} </Text>
                  {glyph[i.kind]} {clip(i.text, width - 10)}
                </Text>
              );
            })}
        </Box>
      </Box>
    );
  });
};
