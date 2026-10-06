import type { On } from "claude-code";
import { describe, expect, test } from "claude-code/testing";

import { actionsOf, firstLine, paint } from "../hooks/register";

// The test's own hook stands for the engine: it catches the transcript lines.
const feed = (on: On) => {
  const lines: string[] = [];
  on("ui.log", (_$, e) => {
    if (e.to === "transcript") lines.push(e.text);
    return { value: undefined };
  });
  return lines;
};

describe("jevlight", () => {
  test("a Jev deny before a tool call writes one sky-blue line", async ($, on) => {
    const lines = feed(on);
    on("classic.PreToolUse", () => ({
      deny: "Jev: force-push to main is blocked",
    }));

    await $.tool.call({
      tool: "Bash",
      command: "git push --force origin main",
    });

    expect(lines).toEqual([
      paint("⚡ Jev blocked Bash: Jev: force-push to main is blocked"),
    ]);
  });

  test("a pass leaves no line", async ($, on) => {
    const lines = feed(on);
    on("classic.PreToolUse", () => ({}));
    on("classic.Stop", () => ({}));
    on("tool.call", () => ({ result: "ok" }));

    await $.tool.call({ tool: "Bash", command: "ls" });
    await $.classic.Stop({ stop_hook_active: false });

    expect(lines).toEqual([]);
  });

  test("each action is its own line, in order", async ($, on) => {
    const lines = feed(on);
    on("classic.UserPromptSubmit", () => ({
      additionalContext: ["\nUse the verify skill before done.\nmore"],
    }));
    on("classic.Stop", () => ({
      block: "Executive style: line 1 needs a tag",
    }));

    await $.classic.UserPromptSubmit({ prompt: "ship it" });
    await $.classic.Stop({ stop_hook_active: false });

    expect(lines).toEqual([
      paint("⚡ Jev noted your prompt: Use the verify skill before done."),
      paint("⚡ Jev held the stop: Executive style: line 1 needs a tag"),
    ]);
  });

  test("passes Jev's result on unchanged", async ($, on) => {
    feed(on);
    on("classic.Stop", () => ({ block: "keep going" }));

    await expect($.classic.Stop({ stop_hook_active: false })).resolves.toEqual({
      block: "keep going",
    });
  });

  test("a trim is marked too", () => {
    expect(actionsOf("Read output", { updatedToolOutput: "short" })).toEqual([
      "⚡ Jev trimmed Read output",
    ]);
  });

  test("long reasons are cut to one line", () => {
    expect(firstLine(`${"x".repeat(150)}\nsecond`)).toHaveLength(120);
  });
});
