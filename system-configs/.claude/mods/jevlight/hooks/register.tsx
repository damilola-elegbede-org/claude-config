import { atom, read, update } from "claude-code";
import type { EngineInterface, Register } from "claude-code";

import type { Marks } from "../types";

// jevlight: a visual marker each time Jev acts. Jev is the set of settings
// (shell) hooks in settings.json; they run beneath every hooks module, so
// awaiting `next(e)` here returns what they decided. A pass leaves no mark.
//
// v2 draws EVERY action in sky blue, in three places:
//   1. a tool call's action (deny, ask, note, rewrite, trim) is a line under
//      that call's row (ToolResult / ToolGroup), keyed by tool_use_id;
//   2. a prompt's action (UserPromptSubmit note or hold) is a line under the
//      user's own message row (UserMessage), keyed by the prompt text;
//   3. a stop's action (held stop, note) is a line under the reply it judged
//      (AssistantMessage), keyed by the reply text;
// and a session-level action (SessionStart context) is a plain log row (the
// record) plus a sky-blue band above the prompt until the next prompt.
// If a coloured row is never drawn (a -p host, a text that does not match), a
// plain log line says it after FALLBACK_MS, so no action is ever silent.
//
// It only watches: every hook returns the result it was handed, unchanged. It
// cannot tell which settings hook acted, so a non-Jev settings hook that acts
// (gate.sh) is marked as Jev too. A hook that answers only `systemMessage` or
// plain stdout is invisible here (the folded result has no such field); the
// engine itself draws a systemMessage as a "<Event> says: ..." notice.

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
// How long an anchored line waits for its coloured row before a plain log line says it.
export const FALLBACK_MS = 2500;

const marks = atom({ plugin: "jevlight", key: "marks" } as const, {} as Marks);
// Lines anchored to a row that has no tool_use_id: "u:<hash>" under a prompt, "a:<hash>" under a reply.
const notes = atom({ plugin: "jevlight", key: "notes" } as const, {} as Marks);
// Session-level lines drawn in the band above the prompt until the next prompt.
const band = atom({ plugin: "jevlight", key: "band" } as const, [] as string[]);
// The session the marks belong to, learned from any settings hook event.
const sid = atom(
  { plugin: "jevlight", key: "sid" } as const,
  null as string | null,
);

// Anchors whose coloured row was drawn at least once (read by the fallback timer).
const drawn = new Set<string>();

export const firstLine = (text: string) => {
  const line =
    text
      .trim()
      .split("\n")
      .find((l) => l.trim() !== "") ?? "";
  return line.length > LINE_MAX ? `${line.slice(0, LINE_MAX - 1)}…` : line;
};

// The engine prefixes a hook's reason with "PreToolUse:Bash hook error: ", and an
// exit-2 inline guard adds its whole script in brackets before its stderr.
export const unprefix = (text: string) => {
  let t = text.replace(/^[A-Za-z]+(:\S+)? hook error: /, "");
  if (t.startsWith("[")) {
    const k = t.lastIndexOf("]: ");
    if (k > 0) t = t.slice(k + 3);
  }
  return t;
};

// Who acted. Everything is Jev by default (D wants every action flashed); only the inline git guards'
// "BLOCKED: ..." / "WARNING: ..." wording marks a settings hook that is not Jev.
export const who = (text: string) =>
  /^(BLOCKED|WARNING):/.test(unprefix(text).trim()) ? "Hook" : "Jev";

// The line a reader needs: a reason that is only a header ("... violations:")
// is followed by its first bullet, since the bullet says what was wrong.
export const gist = (text: string) => {
  const lines = unprefix(text.trim())
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l !== "");
  const head = lines[0] ?? "";
  const next = lines[1]?.replace(/^[-*•]\s*/, "");
  const joined = /[:)]$/.test(head) && next ? `${head} ${next}` : head;
  return joined.length > LINE_MAX
    ? `${joined.slice(0, LINE_MAX - 1)}…`
    : joined;
};

const said = (text: string) => (gist(text) ? `: ${gist(text)}` : "");

// What Jev did at one event, one line per action. `where` names the tool
// call or the moment (`Bash`, `Bash failure`, `your prompt`).
export const actionsOf = (where: string, r: Outcome | undefined): string[] => {
  if (!r) return [];
  const lines: string[] = [];
  const add = (text: string | undefined, line: string) =>
    // U+FE0F asks for emoji presentation; without it a programming font draws its own outline glyph.
    lines.push(`⚡️ ${text === undefined ? "Jev" : who(text)} ${line}`);
  if (r.deny !== undefined) add(r.deny, `blocked ${where}${said(r.deny)}`);
  else if (r.ask !== undefined)
    add(r.ask, `asked about ${where}${said(r.ask)}`);
  if (r.block !== undefined) add(r.block, `held ${where}${said(r.block)}`);
  if (r.preventContinuation) {
    add(r.stopReason, `stopped the session${said(r.stopReason ?? "")}`);
  }
  // Each hook that added context is its own action.
  for (const c of r.additionalContext ?? []) {
    if (c.trim() !== "") add(c, `noted ${where}${said(c)}`);
  }
  if (r.updatedInput !== undefined) add(undefined, `rewrote ${where}'s input`);
  if (
    r.updatedToolOutput !== undefined ||
    r.updatedMCPToolOutput !== undefined
  ) {
    add(undefined, `trimmed ${where}`);
  }
  return lines;
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

// A key for a row with no tool_use_id: the kind and a hash of its whitespace-normalised text.
export const anchorKey = (kind: "u" | "a", text: string) => {
  const s = text.replace(/\s+/g, " ").trim();
  let h = 5381;
  for (let i = 0; i < s.length; i++) h = ((h * 33) ^ s.charCodeAt(i)) >>> 0;
  return `${kind}:${h.toString(36)}:${s.length}`;
};

// Saves this session's marks and notes, keeping the newest SESSIONS_KEPT sessions.
const persist = async ($: EngineInterface) => {
  const session = await read($, sid);
  if (!session) return;
  await $.store.set(`marks:${session}`, await read($, marks));
  await $.store.set(`notes:${session}`, await read($, notes));
  const kept = ((await $.store.get("sessions")) as string[] | undefined) ?? [];
  const sessions = [...kept.filter((s) => s !== session), session];
  for (const old of sessions.slice(0, -SESSIONS_KEPT)) {
    await $.store.delete(`marks:${old}`);
    await $.store.delete(`notes:${old}`);
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
    const savedNotes = (await $.store.get(`notes:${session}`)) as
      | Marks
      | undefined;
    // Switching sessions drops the old session's marks (tool_use_ids could
    // coincide); the first id learned keeps marks drawn before it was known.
    if (previous) {
      await update($, marks, () => saved ?? {});
      await update($, notes, () => savedNotes ?? {});
      await update($, band, () => []);
    } else {
      if (saved) {
        await update($, marks, (all) => ({ ...saved, ...(all ?? {}) }));
      }
      if (savedNotes) {
        await update($, notes, (all) => ({ ...savedNotes, ...(all ?? {}) }));
      }
    }
  } catch {
    // losing old marks never stops the session
  }
};

// Asks the engine to draw the rows again now that a line exists for one.
const redraw = ($: EngineInterface) => {
  try {
    $.ui.invalidate("ui.render");
  } catch {
    // a host that cannot redraw shows the line at the next natural draw
  }
};

type Where = { id?: string; anchor?: string; session?: boolean };

// A marker must never break the hook chain: a failure to record it is dropped.
const mark = async (
  $: EngineInterface,
  where: string,
  r: unknown,
  at: Where = {},
) => {
  try {
    const lines = actionsOf(where, r as Outcome);
    if (lines.length === 0) return;
    if (at.id) {
      await update($, marks, (all) => addMarks(all ?? {}, at.id!, lines));
      await persist($);
    } else if (at.anchor && !(await read($, notes))[at.anchor]) {
      // A row is found by its text alone, so only a text's first occurrence is anchored; a repeat
      // ("continue" twice) falls through to a plain line where it happened, never under the first.
      const key = at.anchor;
      drawn.delete(key);
      await update($, notes, (all) => addMarks(all ?? {}, key, lines));
      await persist($);
      // No coloured row drawn in time (a -p host, a text that does not match): say it plainly.
      const say = () => {
        if (!drawn.has(key)) for (const line of lines) $.ui.log(line);
      };
      try {
        $.clock.after(FALLBACK_MS, say);
      } catch {
        // a host with no engine clock (the test kit): the host's own timer
        setTimeout(say, FALLBACK_MS);
      }
      redraw($);
    } else {
      // The record: a plain row. For a session-level action, also a band above the prompt.
      for (const line of lines) $.ui.log(line);
      if (at.session) {
        await update($, band, (all) => [...(all ?? []), ...lines].slice(-5));
        redraw($);
      }
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
    await mark($, e.tool, r, { id: e.tool_use_id });
    return r;
  }).catch(keepJev);

  on("classic.PostToolUse", async ($, e, next) => {
    await remember($, e.session_id);
    const r = await next(e);
    await mark($, `${e.tool_name} output`, r, { id: e.tool_use_id });
    return r;
  }).catch(keepJev);

  on("classic.PostToolUseFailure", async ($, e, next) => {
    await remember($, e.session_id);
    const r = await next(e);
    await mark($, `${e.tool_name} failure`, r, { id: e.tool_use_id });
    return r;
  }).catch(keepJev);

  on("classic.UserPromptSubmit", async ($, e, next) => {
    await remember($, e.session_id);
    // A new prompt ends the session-level band.
    await update($, band, () => []);
    const r = await next(e);
    await mark($, "your prompt", r, { anchor: anchorKey("u", e.prompt ?? "") });
    return r;
  }).catch(keepJev);

  on("classic.Stop", async ($, e, next) => {
    await remember($, e.session_id);
    const r = await next(e);
    const reply = e.last_assistant_message ?? "";
    await mark(
      $,
      "the stop",
      r,
      reply.trim() ? { anchor: anchorKey("a", reply) } : {},
    );
    return r;
  }).catch(keepJev);

  on("classic.SessionStart", async ($, e, next) => {
    await remember($, e.session_id);
    const r = await next(e);
    await mark($, "session start", r, { session: true });
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

  // Under the user's own message: what Jev did with that prompt.
  on("ui.render", { component: "UserMessage" }, async ($, e, next) => {
    const key = anchorKey("u", e.props.text);
    const lines = (await read($, notes))[key] ?? [];
    if (lines.length === 0) return next(e);
    drawn.add(key);
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

  // Under the reply Jev judged at the stop (a hold, a note).
  on("ui.render", { component: "AssistantMessage" }, async ($, e, next) => {
    const key = anchorKey("a", e.props.text);
    const lines = (await read($, notes))[key] ?? [];
    if (lines.length === 0) return next(e);
    drawn.add(key);
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

  // The band above the prompt: session-level actions until the next prompt.
  on("ui.render", { component: "AbovePrompt" }, async ($, e, next) => {
    const lines = await read($, band);
    if (lines.length === 0 || e.props.hasSurvey) return next(e);
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
