import type { On } from "claude-code";
import { describe, expect, test } from "claude-code/testing";

import { actionsOf, firstLine, statusText } from "../hooks/register";

// The test's own hooks stand for the engine: they catch what jevlight shows.
const screen = (on: On) => {
  const toasts: string[] = [];
  const statuses: (string | undefined)[] = [];
  on("ui.toast", (_$, e) => {
    toasts.push(e.text);
    return { value: undefined };
  });
  on("ui.status", (_$, e) => {
    statuses.push(e.text);
    return { value: undefined };
  });
  return { toasts, statuses };
};

describe("jevlight", () => {
  test("a Jev deny before a tool call raises a toast and counts as blocked", async ($, on) => {
    const seen = screen(on);
    on("classic.PreToolUse", () => ({
      deny: "Jev: force-push to main is blocked",
    }));

    await $.tool.call({
      tool: "Bash",
      command: "git push --force origin main",
    });

    expect(seen.toasts).toEqual([
      "⚡ Jev blocked Bash: Jev: force-push to main is blocked",
    ]);
    expect(seen.statuses.at(-1)).toBe("⚡ Jev 1 blocked · 0 noted · 0 trimmed");
  });

  test("a pass leaves no mark", async ($, on) => {
    const seen = screen(on);
    on("classic.PreToolUse", () => ({}));
    on("classic.Stop", () => ({}));
    on("tool.call", () => ({ result: "ok" }));

    await $.tool.call({ tool: "Bash", command: "ls" });
    await $.classic.Stop({ stop_hook_active: false });

    expect(seen.toasts).toEqual([]);
    expect(seen.statuses).toEqual([]);
  });

  test("added context toasts its first line; counts add up across events", async ($, on) => {
    const seen = screen(on);
    on("classic.UserPromptSubmit", () => ({
      additionalContext: ["\nUse the verify skill before done.\nmore"],
    }));
    on("classic.Stop", () => ({
      block: "Executive style: line 1 needs a tag",
    }));

    await $.classic.UserPromptSubmit({ prompt: "ship it" });
    await $.classic.Stop({ stop_hook_active: false });

    expect(seen.toasts).toEqual([
      "⚡ Jev noted (UserPromptSubmit): Use the verify skill before done.",
      "⚡ Jev held the stop: Executive style: line 1 needs a tag",
    ]);
    expect(seen.statuses.at(-1)).toBe("⚡ Jev 1 blocked · 1 noted · 0 trimmed");
  });

  test("passes Jev's result on unchanged", async ($, on) => {
    screen(on);
    on("classic.Stop", () => ({ block: "keep going" }));

    await expect($.classic.Stop({ stop_hook_active: false })).resolves.toEqual({
      block: "keep going",
    });
  });

  test("a trim counts without a toast", () => {
    expect(
      actionsOf("PostToolUse", "Read", { updatedToolOutput: "short" }),
    ).toEqual([{ kind: "trimmed" }]);
  });

  test("long reasons are cut to one line", () => {
    expect(firstLine(`${"x".repeat(150)}\nsecond`)).toHaveLength(100);
    expect(statusText({ blocked: 2, noted: 5, trimmed: 14 })).toBe(
      "⚡ Jev 2 blocked · 5 noted · 14 trimmed",
    );
  });
});
