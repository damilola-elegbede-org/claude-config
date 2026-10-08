import { atom, read, update } from "claude-code";
import type { EngineInterface, Register } from "claude-code";

import type { Marks } from "../types";

// jevlight: a visual marker each time Jev acts. Jev is the set of settings
// (shell) hooks in settings.json; they run beneath every hooks module, so
// awaiting `next(e)` here returns what they decided. A pass leaves no mark.
//
// An action on a tool call is drawn as a sky-blue line under that call's row
// in the transcript (its result, or its group like "Read 3 files"), so it
// stays in the record; the marks are saved per session, so a resume draws them
// again. An action with no tool row (a held stop, a note on the prompt) is a
// plain transcript line: log lines cannot carry colour.
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
// A reason is shown whole and the transcript row wraps it; the cap only stops a runaway line.
const LINE_MAX = 1000;
// Calls whose marks are kept; older ones scroll out of view anyway.
const KEEP = 200;
// Sessions whose marks the store keeps, so a resume can draw them again.
const SESSIONS_KEPT = 20;

const marks = atom({ plugin: "jevlight", key: "marks" } as const, {} as Marks);
// The session the marks belong to, learned from any settings hook event.
const sid = atom(
  { plugin: "jevlight", key: "sid" } as const,
  null as string | null,
);

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
  // Each hook that added context is its own action.
  for (const c of r.additionalContext ?? []) {
    if (c.trim() !== "") lines.push(`noted ${where}${said(c)}`);
  }
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

// Saves this session's marks, keeping the newest SESSIONS_KEPT sessions.
const persist = async ($: EngineInterface) => {
  const session = await read($, sid);
  if (!session) return;
  await $.store.set(`marks:${session}`, await read($, marks));
  const kept = ((await $.store.get("sessions")) as string[] | undefined) ?? [];
  const sessions = [...kept.filter((s) => s !== session), session];
  for (const old of sessions.slice(0, -SESSIONS_KEPT)) {
    await $.store.delete(`marks:${old}`);
  }
  await $.store.set("sessions", sessions.slice(-SESSIONS_KEPT));
};

// Learns the session id; on a resume, draws its saved marks again.
const remember = async ($: EngineInterface, session: string) => {
  try {
    const previous = await read($, sid);
    if (previous === session) return;
    await update($, sid, () => session);
    const saved = (await $.store.get(`marks:${session}`)) as Marks | undefined;
    // Switching sessions drops the old session's marks (tool_use_ids could
    // coincide); the first id learned keeps marks drawn before it was known.
    if (previous) await update($, marks, () => saved ?? {});
    else if (saved) {
      await update($, marks, (all) => ({ ...saved, ...(all ?? {}) }));
    }
  } catch {
    // losing old marks never stops the session
  }
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
    if (id) {
      await update($, marks, (all) => addMarks(all ?? {}, id, lines));
      await persist($);
    } else {
      for (const line of lines) $.ui.log(line);
    }
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

  // PreToolUse carries no session id; the events around it teach `sid`.
  on("classic.PreToolUse", async ($, e, next) => {
    const r = await next(e);
    await mark($, e.tool, r, e.tool_use_id);
    return r;
  }).catch(keepJev);

  on("classic.PostToolUse", async ($, e, next) => {
    await remember($, e.session_id);
    const r = await next(e);
    await mark($, `${e.tool_name} output`, r, e.tool_use_id);
    return r;
  }).catch(keepJev);

  on("classic.PostToolUseFailure", async ($, e, next) => {
    await remember($, e.session_id);
    const r = await next(e);
    await mark($, `${e.tool_name} failure`, r, e.tool_use_id);
    return r;
  }).catch(keepJev);

  on("classic.UserPromptSubmit", async ($, e, next) => {
    await remember($, e.session_id);
    const r = await next(e);
    await mark($, "your prompt", r);
    return r;
  }).catch(keepJev);

  on("classic.Stop", async ($, e, next) => {
    await remember($, e.session_id);
    const r = await next(e);
    await mark($, "the stop", r);
    return r;
  }).catch(keepJev);

  on("classic.SessionStart", async ($, e, next) => {
    await remember($, e.session_id);
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

  // And under a group of calls ("Read 3 files"), folded or expanded.
  on("ui.render", { component: "ToolGroup" }, async ($, e, next) => {
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
