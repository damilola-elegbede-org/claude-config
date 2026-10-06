import { atom, read, update } from "claude-code";
import type { EngineInterface, Register } from "claude-code";

import type { Marks } from "../types";

// jevlight: a visual marker each time Jev acts. Jev is the set of settings
// (shell) hooks in settings.json; they run beneath every hooks module, so
// awaiting `next(e)` here returns what they decided. A pass leaves no mark.
//
// An action on a tool call is drawn as a sky-blue line under that call's row
// in the transcript (its result, or its folded group like "Read 3 files"), so
// it stays in the record. An action with no tool row (a held stop, a note on
// the prompt) is a plain transcript line: log lines cannot carry colour.
//
// It only watches: every hook returns the result it was handed, unchanged. It
// cannot tell which settings hook acted, so a non-Jev settings hook that acts
// (gate.sh) is marked as Jev too.

// The fields of a settings hook result that mean a hook acted.
export type Outcome = {
  deny?: string;
  ask?: string;
  updatedInput?: Record<string, unknown>;
  block?: string;
  preventContinuation?: true;
  stopReason?: string;
  additionalContext?: string[];
  updatedToolOutput?: unknown;
  updatedMCPToolOutput?: unknown;
};

export const SKY = "#87CEEB";
const LINE_MAX = 120;
// Calls whose marks are kept; older ones scroll out of view anyway.
const KEEP = 200;

const marks = atom({ plugin: "jevlight", key: "marks" } as const, {} as Marks);

export const firstLine = (text: string) => {
  const line =
    text
      .trim()
      .split("\n")
      .find((l) => l.trim() !== "") ?? "";
  return line.length > LINE_MAX ? `${line.slice(0, LINE_MAX - 1)}…` : line;
};

const said = (text: string) => (firstLine(text) ? `: ${firstLine(text)}` : "");

// What Jev did at one event, one line per action. `where` names the tool
// call or the moment (`Bash`, `Bash failure`, `your prompt`).
export const actionsOf = (where: string, r: Outcome | undefined): string[] => {
  if (!r) return [];
  const lines: string[] = [];
  if (r.deny !== undefined) lines.push(`blocked ${where}${said(r.deny)}`);
  else if (r.ask !== undefined)
    lines.push(`asked about ${where}${said(r.ask)}`);
  if (r.block !== undefined) lines.push(`held ${where}${said(r.block)}`);
  if (r.preventContinuation) {
    lines.push(`stopped the session${said(r.stopReason ?? "")}`);
  }
  const context = (r.additionalContext ?? []).filter((c) => c.trim() !== "");
  if (context.length > 0) lines.push(`noted ${where}${said(context[0] ?? "")}`);
  if (r.updatedInput !== undefined) lines.push(`rewrote ${where}'s input`);
  if (
    r.updatedToolOutput !== undefined ||
    r.updatedMCPToolOutput !== undefined
  ) {
    lines.push(`trimmed ${where}`);
  }
  return lines.map((l) => `⚡ Jev ${l}`);
};

// Adds lines to a call's marks, dropping the oldest calls past KEEP.
export const addMarks = (all: Marks, id: string, lines: string[]): Marks => {
  const next = { ...all, [id]: [...(all[id] ?? []), ...lines] };
  const ids = Object.keys(next);
  for (const old of ids.slice(0, Math.max(0, ids.length - KEEP))) {
    delete next[old];
  }
  return next;
};

// A marker must never break the hook chain: a failure to record it is dropped.
const mark = async (
  $: EngineInterface,
  where: string,
  r: unknown,
  id?: string,
) => {
  try {
    const lines = actionsOf(where, r as Outcome);
    if (lines.length === 0) return;
    if (id) await update($, marks, (all) => addMarks(all ?? {}, id, lines));
    else for (const line of lines) $.ui.log(line);
  } catch {
    // recording the marker failed; Jev's result still goes on below
  }
};

// If a hook here throws, hand on what Jev decided: next(e) replays the call
// that already ran, so nothing runs twice and a Jev block still stands.
const keepJev = <E, R>(_$: unknown, e: E, next: (e: E) => R) => next(e);

export const register: Register = (on) => {
  // 0.1.0 pinned a status line, which outlives a reload; clear it.
  on("session.start", async ($, e, next) => {
    $.ui.status(undefined);
    return next(e);
  });

  on("classic.PreToolUse", async ($, e, next) => {
    const r = await next(e);
    await mark($, e.tool, r, e.tool_use_id);
    return r;
  }).catch(keepJev);

  on("classic.PostToolUse", async ($, e, next) => {
    const r = await next(e);
    await mark($, `${e.tool_name} output`, r, e.tool_use_id);
    return r;
  }).catch(keepJev);

  on("classic.PostToolUseFailure", async ($, e, next) => {
    const r = await next(e);
    await mark($, `${e.tool_name} failure`, r, e.tool_use_id);
    return r;
  }).catch(keepJev);

  on("classic.UserPromptSubmit", async ($, e, next) => {
    const r = await next(e);
    await mark($, "your prompt", r);
    return r;
  }).catch(keepJev);

  on("classic.Stop", async ($, e, next) => {
    const r = await next(e);
    await mark($, "the stop", r);
    return r;
  }).catch(keepJev);

  on("classic.SessionStart", async ($, e, next) => {
    const r = await next(e);
    await mark($, "session start", r);
    return r;
  }).catch(keepJev);

  // The sky-blue lines under a call's result row.
  on("ui.render", { component: "ToolResult" }, async ($, e, next) => {
    const lines = (await read($, marks))[e.props.tool_use_id] ?? [];
    if (lines.length === 0) return next(e);
    const { Box, Text } = $.ui.resolve(e);
    return (
      <Box flexDirection="column">
        {await next(e)}
        {lines.map((l) => (
          <Text color={SKY}>{l}</Text>
        ))}
      </Box>
    );
  });

  // And under a folded group ("Read 3 files"), whose calls draw no result row.
  on("ui.render", { component: "ToolGroup" }, async ($, e, next) => {
    if (e.props.isExpanded) return next(e);
    const all = await read($, marks);
    const lines = e.props.calls.flatMap((c) =>
      c.tool_use_id ? (all[c.tool_use_id] ?? []) : [],
    );
    if (lines.length === 0) return next(e);
    const { Box, Text } = $.ui.resolve(e);
    return (
      <Box flexDirection="column">
        {await next(e)}
        {lines.map((l) => (
          <Text color={SKY}>{l}</Text>
        ))}
      </Box>
    );
  });
};
