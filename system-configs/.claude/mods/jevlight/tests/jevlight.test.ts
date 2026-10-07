import type { On } from "claude-code";
import { describe, expect, test } from "claude-code/testing";

import { SKY, actionsOf, addMarks, firstLine } from "../hooks/register";

const plugin = "jevlight";

// The test's own hooks stand for the engine: its drawing of a row, and the
// plain transcript lines.
const engine = (on: On) => {
  const logged: string[] = [];
  on("ui.render", () => ({ type: "Box", props: {}, children: [] }));
  on("ui.log", (_$, e) => {
    if (e.to === "transcript") logged.push(e.text);
    return { value: undefined };
  });
  return logged;
};

// The store across sessions, held in memory for one test.
const memoryStore = (on: On) => {
  const data = new Map<string, unknown>();
  on("store.get", (_$, e) => ({ value: data.get(e.key) }));
  on("store.set", (_$, e) => {
    data.set(e.key, e.value);
    return { value: undefined };
  });
  on("store.delete", (_$, e) => {
    data.delete(e.key);
    return { value: undefined };
  });
  return data;
};

const result = (surface: "terminal" | "desktop", tool_use_id: string) =>
  ({
    plugin,
    surface,
    component: "ToolResult",
    requestId: tool_use_id,
    props: { tool_use_id, tool: "Bash", output: {}, isErrored: true },
  }) as const;

const group = (ids: string[], isExpanded = false) =>
  ({
    plugin,
    surface: "terminal",
    component: "ToolGroup",
    props: {
      calls: ids.map((id) => ({
        tool_use_id: id,
        tool: "Read",
        input: {},
        isRunning: false,
        isErrored: false,
        isInterrupted: false,
      })),
      isActive: false,
      isExpanded,
    },
  }) as const;

describe("jevlight", () => {
  for (const surface of ["terminal", "desktop"] as const) {
    test(`a Jev deny draws a sky-blue line under the call (${surface})`, async ($, on) => {
      engine(on);
      on("classic.PreToolUse", () => ({
        deny: "Jev: force-push to main is blocked",
      }));

      await $.tool.call({
        tool: "Bash",
        tool_use_id: "t1",
        command: "git push --force origin main",
      });

      const ui = await $.ui.mount(result(surface, "t1"));
      const line = await ui.find({ type: "Text", text: /⚡ Jev blocked Bash/ });
      expect(line?.props.color).toBe(SKY);
    });
  }

  test("a pass draws nothing", async ($, on) => {
    const logged = engine(on);
    on("classic.PreToolUse", () => ({}));
    on("classic.Stop", () => ({}));
    on("tool.call", () => ({ result: "ok" }));

    const ran = await $.tool.call({ tool: "Bash", command: "ls" });
    await $.classic.Stop({ stop_hook_active: false });

    const id = (ran as { tool_use_id?: string }).tool_use_id ?? "x";
    const ui = await $.ui.mount(result("terminal", id));
    expect(await ui.find({ text: /⚡ Jev/ })).toBeUndefined();
    expect(logged).toEqual([]);
  });

  test("an action with no tool row is a plain transcript line", async ($, on) => {
    const logged = engine(on);
    on("classic.Stop", () => ({
      block: "Executive style: line 1 needs a tag",
    }));

    await expect($.classic.Stop({ stop_hook_active: false })).resolves.toEqual({
      block: "Executive style: line 1 needs a tag",
    });
    expect(logged).toEqual([
      "⚡ Jev held the stop: Executive style: line 1 needs a tag",
    ]);
  });

  test("a folded group shows its calls' marks", async ($, on) => {
    engine(on);
    on("classic.PostToolUse", () => ({ updatedToolOutput: "short" }));
    await $.classic.PostToolUse({
      tool_name: "Read",
      tool_use_id: "r1",
      tool_input: {},
      tool_response: {},
      duration_ms: 1,
    });

    for (const isExpanded of [false, true]) {
      const ui = await $.ui.mount(group(["r1", "r2"], isExpanded));
      expect(
        (await ui.find({ type: "Text", text: /trimmed Read output/ }))?.props
          .color,
      ).toBe(SKY);
    }
  });

  test("every hook that added context gets its own line", () => {
    expect(
      actionsOf("Bash failure", {
        additionalContext: ["Retry bound hit", "", "Known papercut"],
      }),
    ).toEqual([
      "⚡ Jev noted Bash failure: Retry bound hit",
      "⚡ Jev noted Bash failure: Known papercut",
    ]);
  });

  test("marks are saved under the session", async ($, on) => {
    engine(on);
    const store = memoryStore(on);
    on("classic.PostToolUse", () => ({ updatedToolOutput: "short" }));
    await $.classic.PostToolUse({
      session_id: "s1",
      tool_name: "Read",
      tool_use_id: "r1",
      tool_input: {},
      tool_response: {},
      duration_ms: 1,
    });

    expect(store.get("marks:s1")).toEqual({
      r1: ["⚡ Jev trimmed Read output"],
    });
    expect(store.get("sessions")).toEqual(["s1"]);
  });

  test("a resumed session draws its saved marks again", async ($, on) => {
    engine(on);
    const store = memoryStore(on);
    store.set("marks:s2", { t9: ["⚡ Jev blocked Bash: saved earlier"] });
    on("classic.UserPromptSubmit", () => ({}));

    await $.classic.UserPromptSubmit({ session_id: "s2", prompt: "hi" });

    const ui = await $.ui.mount(result("terminal", "t9"));
    expect(
      (await ui.find({ type: "Text", text: /saved earlier/ }))?.props.color,
    ).toBe(SKY);
  });

  test("switching sessions drops the old session's marks", async ($, on) => {
    engine(on);
    memoryStore(on);
    on("classic.UserPromptSubmit", () => ({}));
    on("classic.PostToolUse", () => ({ updatedToolOutput: "short" }));
    await $.classic.PostToolUse({
      session_id: "s1",
      tool_name: "Read",
      tool_use_id: "dup",
      tool_input: {},
      tool_response: {},
      duration_ms: 1,
    });

    await $.classic.UserPromptSubmit({ session_id: "s2", prompt: "hi" });

    const ui = await $.ui.mount(result("terminal", "dup"));
    expect(await ui.find({ type: "Text", text: /trimmed Read/ })).toBeUndefined();
  });

  test("a trim is marked; old calls drop past the cap", () => {
    expect(actionsOf("Read output", { updatedToolOutput: "short" })).toEqual([
      "⚡ Jev trimmed Read output",
    ]);
    let all = {};
    for (let n = 0; n < 205; n++) all = addMarks(all, `id${n}`, ["x"]);
    expect(Object.keys(all)).toHaveLength(200);
    expect(Object.keys(all)[0]).toBe("id5");
  });

  test("long reasons are cut to one line", () => {
    expect(firstLine(`${"x".repeat(150)}\nsecond`)).toHaveLength(120);
  });
});
