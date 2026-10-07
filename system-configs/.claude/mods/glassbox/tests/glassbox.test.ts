import type { On } from "claude-code";
import { describe, expect, mock, test } from "claude-code/testing";

import { bar, duration, responseItems } from "../hooks/register";

const plugin = "glassbox";
const scroll = { offset: 0, bodyRows: 40 };

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

const pane = (
  surface: "terminal" | "desktop",
  view: { agentId?: string } = {},
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
      placement: "dock",
      scroll,
      view,
    },
  }) as const;

// What a live session gives every plugin: a clock, and the engine's own
// drawing beneath a band that has nothing to show.
const engine = (on: On) => {
  mock.clock(on, { now: 1_000_000 });
  on("ui.render", () => ({ type: "Box", props: {}, children: [] }));
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
    expect(await ui.find({ text: "Never shown" })).toBeUndefined();
    expect(await ui.find({ text: /Idle/ })).toBeDefined();
  });

  for (const surface of ["terminal", "desktop"] as const) {
    test(`checklist drives the progress bar (${surface})`, async ($, on) => {
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
      expect(await ui.find({ text: /1\/2/ })).toBeDefined();
      expect(await ui.find({ text: /✓ Read the code/ })).toBeDefined();
      expect(await ui.find({ text: /◐ Writing tests/ })).toBeDefined();
    });
  }

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
      await strip.find({ text: /Read the code|steps|working|hide/ }),
    ).toBeUndefined();
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
    expect(await ui.find({ text: /0\/2/ })).toBeDefined();
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

  test("a subagent can be drilled into and back out of", async ($, on) => {
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
    expect(await ui.find({ text: /Explore auth code/ })).toBeDefined();
    expect(await ui.find({ text: /Explore · 0 calls/ })).toBeDefined();
    expect(await ui.find({ text: /Activity · main/ })).toBeDefined();

    await ui.press({ key: "agent-a1" });
    expect(
      await ui.find({ text: /Activity · Explore auth code/ }),
    ).toBeDefined();

    await ui.press({ key: "back" });
    expect(await ui.find({ text: /Activity · main/ })).toBeDefined();
  });

  test("← main wins over an open subagent transcript", async ($, on) => {
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

    // The person has a1's transcript open: the pane follows it.
    const ui = await $.ui.mount(pane("terminal", { agentId: "a1" }));
    expect(
      await ui.find({ text: /Activity · Explore auth code/ }),
    ).toBeDefined();

    await ui.press({ key: "back" });
    expect(await ui.find({ text: /Activity · main/ })).toBeDefined();
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

  test("the bar fills in proportion and never narrows below 4 cells", () => {
    expect(bar(1, 2, 8)).toBe("████░░░░");
    expect(bar(0, 0, 2)).toBe("░░░░");
  });

  test("durations read naturally", () => {
    expect(duration(4_000)).toBe("4s");
    expect(duration(64_000)).toBe("1m04s");
    expect(duration(3_900_000)).toBe("1h05m");
  });
});
