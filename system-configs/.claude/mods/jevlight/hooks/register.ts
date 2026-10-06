import type { EngineInterface, Register } from "claude-code";

// jevlight: a visual marker each time Jev acts. Jev is the set of settings
// (shell) hooks in settings.json; they run beneath every hooks module, so
// awaiting `next(e)` here returns what they decided. A pass leaves no mark.
// Each action is one sky-blue line in the transcript, in order with the rest
// of the session, so it is part of the record.
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

const LINE_MAX = 120;
// 256-colour 117, sky blue; reset after so nothing else is tinted.
const SKY = "\x1b[38;5;117m";
const RESET = "\x1b[0m";

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

export const paint = (line: string) => `${SKY}${line}${RESET}`;

// A marker must never break the hook chain: a failure to draw it is dropped.
const mark = ($: EngineInterface, where: string, r: unknown) => {
  try {
    for (const line of actionsOf(where, r as Outcome)) $.ui.log(paint(line));
  } catch {
    // drawing the marker failed; Jev's result still goes on below
  }
};

// If a hook here throws, hand on what Jev decided: next(e) replays the call
// that already ran, so nothing runs twice and a Jev block still stands.
const keepJev = <E, R>(_$: unknown, e: E, next: (e: E) => R) => next(e);

export const register: Register = (on) => {
  on("classic.PreToolUse", async ($, e, next) => {
    const r = await next(e);
    mark($, e.tool, r);
    return r;
  }).catch(keepJev);

  on("classic.PostToolUse", async ($, e, next) => {
    const r = await next(e);
    mark($, `${e.tool_name} output`, r);
    return r;
  }).catch(keepJev);

  on("classic.PostToolUseFailure", async ($, e, next) => {
    const r = await next(e);
    mark($, `${e.tool_name} failure`, r);
    return r;
  }).catch(keepJev);

  on("classic.UserPromptSubmit", async ($, e, next) => {
    const r = await next(e);
    mark($, "your prompt", r);
    return r;
  }).catch(keepJev);

  on("classic.Stop", async ($, e, next) => {
    const r = await next(e);
    mark($, "the stop", r);
    return r;
  }).catch(keepJev);

  on("classic.SessionStart", async ($, e, next) => {
    const r = await next(e);
    mark($, "session start", r);
    return r;
  }).catch(keepJev);
};
