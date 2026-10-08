import type { On } from "claude-code";
import { describe, expect, mock, test } from "claude-code/testing";

import {
  addChange,
  bar,
  changeOf,
  duration,
  meter,
  prettyModel,
  responseItems,
  settle,
  tally,
  timer,
  tone,
  updateTask,
  verdictOf,
} from "../hooks/model";

const plugin = "glassbox";
const scroll = { offset: 0, bodyRows: 60 };

const band = (isWorking = true) =>
  ({
    plugin,
    surface: "terminal",
    component: "AbovePrompt",
    props: {
      hasSurvey: false,
      isWorking,
      maxRows: 10,
      bodyColumns: 100,
      scroll,
      view: {},
    },
  }) as const;

const SURFACES = ["terminal", "desktop", "vscode", "mobile"] as const;

const pane = (
  surface: (typeof SURFACES)[number],
  view: { agentId?: string } = {},
  placement: "dock" | "inline" = "dock",
) =>
  ({
    plugin,
    surface,
    component: "Pane",
    requestId: "glassbox",
    props: {
      title: "glassbox",
      isFocused: false,
      bodyColumns: 60,
      placement,
      scroll,
      view,
    },
  }) as const;

// What a live session gives every plugin: a clock, and the engine's own
// drawing beneath a band that has nothing to show.
const engine = (on: On) => {
  mock.clock(on, { now: 1_000_000 });
  on("ui.render", () => ({ type: "Box", props: {}, children: [] }));
  on("ui.close", () => ({ value: undefined }));
  on("ui.toast", () => ({ value: undefined }));
};

describe("glassbox", () => {
  test("stays out of the way until a screen has drawn (headless)", async ($, on) => {
    engine(on);
    on("tool.call", () => ({
      result: { task: { id: "1", subject: "Never shown" } },
    }));

    await $.tool.call({
      tool: "TaskCreate",
      subject: "Never shown",
      description: "x",
    });

    const ui = await $.ui.mount(pane("terminal"));
    expect(await ui.find({ text: /Never shown/ })).toBeUndefined();
    expect(await ui.find({ text: /idle/ })).toBeDefined();
  });

  for (const surface of SURFACES) {
    test(`the checklist draws as the plan box (${surface})`, async ($, on) => {
      engine(on);
      let made = 0;
      on("tool.call", (_$, e) =>
        e.tool === "TaskCreate"
          ? {
              result: {
                task: { id: String(++made), subject: String(e.subject) },
              },
            }
          : { result: {} },
      );
      await $.ui.mount(band());

      await $.tool.call({
        tool: "TaskCreate",
        subject: "Read the code",
        description: "x",
      });
      await $.tool.call({
        tool: "TaskCreate",
        subject: "Write tests",
        description: "x",
        activeForm: "Writing tests",
      });
      await $.tool.call({
        tool: "TaskUpdate",
        taskId: "1",
        status: "completed",
      });
      await $.tool.call({
        tool: "TaskUpdate",
        taskId: "2",
        status: "in_progress",
      });

      const ui = await $.ui.mount(pane(surface));
      expect(await ui.find({ text: /plan 1\/2/ })).toBeDefined();
      expect(await ui.find({ text: /✓ Read the code/ })).toBeDefined();
      expect(await ui.find({ text: /◐ Writing tests/ })).toBeDefined();
    });
  }

  test("a box with nothing to show takes no room", async ($, on) => {
    engine(on);
    await $.ui.mount(band());
    const ui = await $.ui.mount(pane("terminal"));
    expect(await ui.find({ text: /╭ context/ })).toBeDefined();
    expect(await ui.find({ text: /╭ activity/ })).toBeDefined();
    for (const box of ["plan", "agents", "gate", "changes"]) {
      expect(await ui.find({ text: new RegExp(`╭ ${box}`) })).toBeUndefined();
    }
  });

  test("draws nothing above the prompt, even mid-turn with a checklist", async ($, on) => {
    engine(on);
    on("tool.call", () => ({
      result: { task: { id: "1", subject: "Read the code" } },
    }));
    await $.ui.mount(band());
    await $.tool.call({
      tool: "TaskCreate",
      subject: "Read the code",
      description: "x",
    });

    const strip = await $.ui.mount(band(true));
    expect(
      await strip.find({ text: /Read the code|plan|working|glassbox/ }),
    ).toBeUndefined();
  });

  for (const surface of SURFACES) {
    test(`seated above the prompt, the pane draws a shorter version (${surface})`, async ($, on) => {
      engine(on);
      on("tool.call", () => ({ result: {} }));
      await $.ui.mount(band());
      for (let i = 0; i < 12; i++) {
        await $.tool.call({ tool: "Read", file_path: `/repo/f${i}.ts` });
      }

      const ui = await $.ui.mount(pane(surface, {}, "inline"));
      expect(await ui.find({ text: /╭ context/ })).toBeDefined();
      expect(await ui.find({ text: /╭ activity/ })).toBeDefined();
      // Eight activity rows, newest first: the oldest four are left out.
      expect(await ui.find({ text: /f11\.ts/ })).toBeDefined();
      expect(await ui.find({ text: /f4\.ts/ })).toBeDefined();
      expect(await ui.find({ text: /f3\.ts/ })).toBeUndefined();
    });
  }

  test("a phone attaching starts the record before the pane opens", async ($, on) => {
    engine(on);
    on("session.attach", (_$, e) => ({ clientId: e.clientId }));
    on("tool.call", () => ({
      result: { task: { id: "1", subject: "Seen from the phone" } },
    }));

    await $.session.attach({ surface: "mobile", clientId: "mobile:default" });
    await $.tool.call({
      tool: "TaskCreate",
      subject: "Seen from the phone",
      description: "x",
    });

    const ui = await $.ui.mount(pane("mobile", {}, "inline"));
    expect(await ui.find({ text: /Seen from the phone/ })).toBeDefined();
  });

  for (const surface of ["terminal", "desktop"] as const) {
    test(`/glassbox opens the pane and prints nothing in the transcript (${surface})`, async ($, on) => {
      engine(on);
      on("session.surfaces", () => ({ value: [surface] }));
      let opened = 0;
      on("ui.open", () => {
        opened++;
        return { value: { isPlaced: true } };
      });
      const out = await $.command.run({ command: "glassbox" });
      expect(out.text).toBeUndefined();
      expect(opened).toBe(1);
    });
  }

  for (const [where, surfaces] of [
    ["the VS Code chat panel", ["vscode"]],
    ["a headless or cloud session", []],
  ] as const) {
    test(`where nothing draws (${where}), /glassbox answers in text and records from then`, async ($, on) => {
      engine(on);
      on("session.surfaces", () => ({ value: surfaces }));
      let opened = 0;
      on("ui.open", () => {
        opened++;
        return { value: { isPlaced: true } };
      });
      on("tool.call", () => ({
        result: { task: { id: "1", subject: "Shown in text" } },
      }));

      const first = await $.command.run({ command: "glassbox" });
      expect(first.text).toMatch(/\*\*glassbox\*\*/);
      expect(first.text).toMatch(/Recording from now/);

      await $.tool.call({
        tool: "TaskCreate",
        subject: "Shown in text",
        description: "x",
      });
      const second = await $.command.run({ command: "glassbox" });
      expect(second.text).toMatch(/\*\*plan\*\* 0\/1/);
      expect(second.text).toMatch(/- \[ \] Shown in text/);
      expect(second.text).not.toMatch(/Recording from now/);
      expect(opened).toBe(0);
    });
  }

  test("/glassbox from claude.ai or the phone (Remote Control) answers in text", async ($, on) => {
    engine(on);
    on("session.surfaces", () => ({ value: ["terminal", "mobile"] }));
    let opened = 0;
    on("ui.open", () => {
      opened++;
      return { value: { isPlaced: true } };
    });
    const out = await $.command.run({
      command: "glassbox",
      origin: { kind: "bridge" },
    } as never);
    expect(out.text).toMatch(/\*\*glassbox\*\*/);
    expect(opened).toBe(0);
  });

  test("/glassbox text answers in text even where the pane draws", async ($, on) => {
    engine(on);
    on("session.surfaces", () => ({ value: ["terminal"] }));
    let opened = 0;
    on("ui.open", () => {
      opened++;
      return { value: { isPlaced: true } };
    });
    await $.ui.mount(band());
    const out = await $.command.run({ command: "glassbox", args: "text" });
    expect(out.text).toMatch(/\*\*glassbox\*\*/);
    expect(opened).toBe(0);
  });

  test("TodoWrite and the task tools never overwrite each other", async ($, on) => {
    engine(on);
    on("tool.call", (_$, e) =>
      e.tool === "TaskCreate"
        ? { result: { task: { id: "1", subject: "From tasks" } } }
        : { result: {} },
    );
    await $.ui.mount(band());

    await $.tool.call({
      tool: "TaskCreate",
      subject: "From tasks",
      description: "x",
    });
    await $.tool.call({
      tool: "TodoWrite",
      todos: [
        { content: "From todos", status: "pending", activeForm: "Doing todos" },
      ],
    });

    const ui = await $.ui.mount(pane("terminal"));
    expect(await ui.find({ text: /From tasks/ })).toBeDefined();
    expect(await ui.find({ text: /From todos/ })).toBeDefined();
    expect(await ui.find({ text: /plan 0\/2/ })).toBeDefined();
    // The plan box shows these; the activity feed does not repeat them.
    expect(await ui.find({ text: /▸ (TaskCreate|TodoWrite)/ })).toBeUndefined();
  });

  test("text never falls back to the terminal's own foreground", async ($, on) => {
    engine(on);
    on("tool.call", () => ({ result: {} }));
    await $.ui.mount(band());
    await $.tool.call({
      tool: "Edit",
      file_path: "/a/b.ts",
      old_string: "a",
      new_string: "b",
    } as never);
    const ui = await $.ui.mount(pane("terminal"));
    const texts = await ui.findAll({ type: "Text" });
    expect(texts.filter((t) => t.props.color === undefined)).toEqual([]);
  });

  test("edits show in the changes box, summed per file", async ($, on) => {
    engine(on);
    // Core returns each edit's diff; unchanged context lines count for neither.
    const diffs = [
      [" keep", "-a", "+b", "+c"],
      ["-b", "-c", "+x", "+y", "+z"],
    ];
    let call = 0;
    on("tool.call", () => ({
      result: { structuredPatch: [{ lines: diffs[call++] }] },
    }));
    await $.ui.mount(band());

    await $.tool.call({
      tool: "Edit",
      file_path: "/repo/src/app.ts",
      old_string: "a",
      new_string: "b\nc",
    } as never);
    await $.tool.call({
      tool: "Write",
      file_path: "/repo/src/app.ts",
      content: "x\ny\nz",
    } as never);

    const ui = await $.ui.mount(pane("terminal"));
    expect(await ui.find({ text: /changes 1 files \+5 −3/ })).toBeDefined();
    expect(await ui.find({ text: /app\.ts/ })).toBeDefined();
  });

  test("checklist calls the plan cannot show stay in activity", async ($, on) => {
    engine(on);
    on("tool.call", (_$, e) =>
      (e as { tool: string }).tool === "TodoWrite"
        ? { isError: true, result: "bad todos" }
        : { result: {} },
    );
    await $.ui.mount(band());
    // A failed main-loop TodoWrite never reaches the plan.
    await $.tool.call({ tool: "TodoWrite", todos: "oops" } as never);
    // A subagent's checklist is not the plan.
    await $.tool.call({ tool: "TaskList", agentId: "a1" } as never);

    const main = await $.ui.mount(pane("terminal"));
    expect(await main.find({ text: /▸ TodoWrite/ })).toBeDefined();
    const sub = await $.ui.mount(pane("desktop", { agentId: "a1" }));
    expect(await sub.find({ text: /▸ TaskList/ })).toBeDefined();
  });

  test("the change bar never draws more than its ten cells", async ($, on) => {
    engine(on);
    const lines = [
      ...Array.from({ length: 11 }, () => "+n"),
      ...Array.from({ length: 9 }, () => "-o"),
    ];
    on("tool.call", () => ({ result: { structuredPatch: [{ lines }] } }));
    await $.ui.mount(band());
    await $.tool.call({
      tool: "Edit",
      file_path: "/repo/a.ts",
      old_string: "o",
      new_string: "n",
    } as never);

    const ui = await $.ui.mount(pane("terminal"));
    const row = await ui.find({ text: /▮.*\+11 −9/ });
    expect(row).toBeDefined();
    const bar = row!.text.match(/▮[▮·]*/)?.[0] ?? "";
    expect([...bar].length).toBe(10);
  });

  test("activity lists the newest first, the last 50 only", async ($, on) => {
    engine(on);
    on("tool.call", () => ({ result: {} }));
    await $.ui.mount(band());

    for (let n = 1; n <= 60; n++) {
      await $.tool.call({ tool: "Bash", command: `step ${n}` });
    }

    const ui = await $.ui.mount(pane("terminal"));
    const rows = await ui.findAll({ type: "Text", text: /▸ Bash step \d+$/ });
    const steps = rows
      .map((r) => r.text.match(/step (\d+)$/)?.[1])
      .filter((s) => s !== undefined)
      .map(Number);
    const unique = steps.filter((s, i) => steps.indexOf(s) === i);
    expect(unique).toEqual(Array.from({ length: 50 }, (_, i) => 60 - i));
  });

  test("a subagent's activity can be picked and put back", async ($, on) => {
    engine(on);
    on("agent.spawn", () => ({ model: "sonnet", agentId: "a1" }));
    await $.ui.mount(band());

    await $.agent.spawn({
      prompt: "look",
      description: "Explore auth code",
      subagentType: "Explore",
      tool_use_id: "toolu_1",
      provider: { plugin: "engine", tier: "core" },
      parentModel: "sonnet",
      background: false,
      fork: false,
    });

    const ui = await $.ui.mount(pane("terminal"));
    expect(await ui.find({ text: /agents 1 running/ })).toBeDefined();
    expect(await ui.find({ text: /Explore auth code/ })).toBeDefined();

    await ui.press({ key: "agent-a1" });
    expect(
      await ui.find({ text: /activity · Explore auth code/ }),
    ).toBeDefined();

    await ui.press({ key: "back" });
    expect(await ui.find({ text: /activity · Explore/ })).toBeUndefined();
  });

  test("back shows the main loop even while the transcript views an agent", async ($, on) => {
    engine(on);
    on("agent.spawn", () => ({ model: "sonnet", agentId: "a1" }));
    await $.ui.mount(band());
    await $.agent.spawn({
      prompt: "look",
      description: "Explore auth code",
      subagentType: "Explore",
      tool_use_id: "toolu_1",
      provider: { plugin: "engine", tier: "core" },
      parentModel: "sonnet",
      background: false,
      fork: false,
    });

    const ui = await $.ui.mount(pane("terminal", { agentId: "a1" }));
    expect(
      await ui.find({ text: /activity · Explore auth code/ }),
    ).toBeDefined();
    await ui.press({ key: "back" });
    expect(await ui.find({ text: /activity · Explore/ })).toBeUndefined();
  });

  test("a subagent's work before its row exists still counts", async ($, on) => {
    engine(on);
    on("tool.call", () => ({ result: {} }));
    // A fast agent runs a tool while agent.spawn is still waiting on core.
    on("agent.spawn", async () => {
      await $.tool.call({
        tool: "Bash",
        command: "ls",
        agentId: "a1",
      } as never);
      return { model: "sonnet", agentId: "a1" };
    });
    await $.ui.mount(band());
    await $.agent.spawn({
      prompt: "look",
      description: "Quick look",
      subagentType: "Explore",
      tool_use_id: "toolu_1",
      provider: { plugin: "engine", tier: "core" },
      parentModel: "sonnet",
      background: false,
      fork: false,
    });

    const ui = await $.ui.mount(pane("terminal"));
    expect(await ui.find({ text: /1 tool ·/ })).toBeDefined();
  });

  test("an agent that ends before its row exists does not stay running", async ($, on) => {
    engine(on);
    on("turn.complete", () => ({ text: "" }));
    // A fast agent finishes while agent.spawn is still waiting on core.
    on("agent.spawn", async () => {
      await $.turn.complete({
        answer: "",
        durationMs: 1,
        isAborted: false,
        turnId: "t",
        agentId: "a1",
        reason: "answer",
      });
      return { model: "sonnet", agentId: "a1" };
    });
    await $.ui.mount(band());
    await $.agent.spawn({
      prompt: "look",
      description: "Quick look",
      subagentType: "Explore",
      tool_use_id: "toolu_1",
      provider: { plugin: "engine", tier: "core" },
      parentModel: "sonnet",
      background: false,
      fork: false,
    });

    const ui = await $.ui.mount(pane("terminal"));
    expect(await ui.find({ text: /agents 1 done/ })).toBeDefined();
    expect(await ui.find({ text: /running/ })).toBeUndefined();
  });

  test("the agents title counts each ending, not only done", async ($, on) => {
    engine(on);
    let n = 0;
    on("agent.spawn", () => ({ model: "sonnet", agentId: `a${++n}` }));
    on("turn.complete", () => ({ text: "" }));
    await $.ui.mount(band());
    for (const description of ["One", "Two"])
      await $.agent.spawn({
        prompt: "look",
        description,
        subagentType: "Explore",
        tool_use_id: `toolu_${description}`,
        provider: { plugin: "engine", tier: "core" },
        parentModel: "sonnet",
        background: false,
        fork: false,
      });
    const ended = { answer: "", durationMs: 1, isAborted: false, turnId: "t" };
    await $.turn.complete({ ...ended, agentId: "a1", reason: "answer" });
    await $.turn.complete({ ...ended, agentId: "a2", reason: "error" });

    const ui = await $.ui.mount(pane("terminal"));
    expect(await ui.find({ text: /agents 1 done · 1 failed/ })).toBeDefined();
  });
});

describe("helpers", () => {
  test("empty and redacted thinking is left out of the feed", () => {
    expect(
      responseItems([
        { type: "thinking", thinking: "" },
        { type: "redacted_thinking" },
        { type: "thinking", thinking: "Check the  types\nfirst" },
        { type: "text", text: "Here is my plan" },
        { type: "tool_use" },
      ]),
    ).toEqual([
      { kind: "thinking", text: "Check the types first" },
      { kind: "say", text: "Here is my plan" },
    ]);
  });

  test("narration reads as words, without markdown marks", () => {
    expect(
      responseItems([
        {
          type: "text",
          text: "**ACTION · Run `/gb2`.**\n- see [docs](https://x.y)\n```sh\nls\n```",
        },
      ]),
    ).toEqual([{ kind: "say", text: "ACTION · Run /gb2. see docs" }]);
  });

  test("bars and meters fill in proportion and never narrow below 4 cells", () => {
    expect(bar(1, 2, 8)).toBe("████░░░░");
    expect(bar(0, 0, 2)).toBe("░░░░");
    expect(meter(50, 8)).toEqual({ on: "████", off: "░░░░" });
    expect(meter(100, 4)).toEqual({ on: "████", off: "" });
    expect(meter(56.25, 8).on).toBe("████▌");
    // an edge that rounds to a full eighth fills its cell
    expect(meter(99, 6)).toEqual({ on: "██████", off: "" });
    expect(meter(49.5, 4)).toEqual({ on: "██", off: "░░" });
  });

  test("tones read as a dashboard: green, amber from 50, red from 80", () => {
    expect([tone(10), tone(50), tone(79), tone(80)]).toEqual([
      "success",
      "warning",
      "warning",
      "error",
    ]);
  });

  test("a permission ask settles to asked or denied by the call around it", () => {
    const list = [
      { id: "a", tool: "Bash", verdict: verdictOf("ask") },
      { id: "b", tool: "Bash", verdict: verdictOf("ask") },
      { id: "c", tool: "Read", verdict: verdictOf("allow") },
    ];
    const done = settle(settle(list, "a", true), "b", false);
    expect(tally(done)).toEqual({
      allowed: 1,
      asked: 1,
      pending: 0,
      denied: 1,
    });
  });

  test("edits count the lines they add and remove", () => {
    // the tool's diff is exact: "a\nb" → "a\nc" is one line each way
    const edit = { file_path: "/x.ts", old_string: "a\nb", new_string: "a\nc" };
    expect(
      changeOf("Edit", edit, {
        structuredPatch: [{ lines: [" a", "-b", "+c"] }],
      }),
    ).toEqual({ file: "/x.ts", added: 1, removed: 1 });
    // without a diff, whole bodies are counted and marked approximate
    expect(
      changeOf("MultiEdit", {
        file_path: "/x.ts",
        edits: [
          { old_string: "a\nb", new_string: "c" },
          { old_string: "d", new_string: "e\nf\ng" },
        ],
      }),
    ).toEqual({ file: "/x.ts", added: 4, removed: 3, approx: true });
    expect(changeOf("Read", { file_path: "/x.ts" })).toBeNull();
    // a new file's final newline ends a line rather than adding one
    expect(
      changeOf(
        "Write",
        { file_path: "/x.ts", content: "a\nb\n" },
        { type: "create", structuredPatch: [] },
      ),
    ).toEqual({ file: "/x.ts", added: 2, removed: 0 });
    // notebook cells: a delete removes the old source, a replace swaps it
    const nb = { notebook_path: "/n.ipynb", new_source: "x\ny" };
    expect(
      changeOf("NotebookEdit", nb, { edit_mode: "delete", old_source: "a" }),
    ).toEqual({ file: "/n.ipynb", added: 0, removed: 1 });
    expect(
      changeOf("NotebookEdit", nb, { edit_mode: "replace", old_source: "a" }),
    ).toEqual({ file: "/n.ipynb", added: 2, removed: 1 });
    expect(changeOf("NotebookEdit", nb, { edit_mode: "insert" })).toEqual({
      file: "/n.ipynb",
      added: 2,
      removed: 0,
    });
    // a replace_all edit without a diff is a floor
    const all = changeOf("Edit", {
      file_path: "/x.ts",
      old_string: "a",
      new_string: "b",
      replace_all: true,
    });
    expect(all).toEqual({ file: "/x.ts", added: 1, removed: 1, approx: true });
    expect(
      addChange([{ file: "/x.ts", added: 1, removed: 0 }], all!)[0]?.approx,
    ).toBe(true);
    const list = addChange([{ file: "/y.ts", added: 1, removed: 0 }], {
      file: "/x.ts",
      added: 2,
      removed: 1,
    });
    expect(list.map((c) => c.file)).toEqual(["/x.ts", "/y.ts"]);
  });

  test("a deleted task leaves the plan", () => {
    const list = [{ id: "task:1", subject: "A", status: "pending" as const }];
    expect(updateTask(list, { taskId: "1", status: "deleted" })).toEqual([]);
  });

  test("times and models read naturally", () => {
    expect(duration(4_000)).toBe("4s");
    expect(duration(64_000)).toBe("1m04s");
    expect(duration(3_900_000)).toBe("1h05m");
    expect(timer(42_000)).toBe("0:42");
    expect(timer(3_840_000)).toBe("1h04");
    expect(prettyModel("claude-opus-5-5[1m]")).toBe("Opus 5.5");
    expect(prettyModel("")).toBe("—");
  });
});
