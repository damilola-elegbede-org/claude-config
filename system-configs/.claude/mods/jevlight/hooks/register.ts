import { atom, read, update } from "claude-code";
import type { EngineInterface, Register } from "claude-code";

import type { Counts } from "../types";

// jevlight: a visual marker each time Jev acts. Jev is the set of settings
// (shell) hooks in settings.json; they run beneath every hooks module, so
// awaiting `next(e)` here returns what they decided. A pass leaves no mark. A
// block, an ask or added context raises a toast; a trimmed tool output only
// bumps the count in the status line, since trims come with most large reads.
//
// It only watches: every hook returns the result it was handed, unchanged. It
// cannot tell which settings hook acted, so a non-Jev settings hook that acts
// (gate.sh) is counted as Jev too.

const ZERO: Counts = { blocked: 0, noted: 0, trimmed: 0 };
const counts = atom({ plugin: "jevlight", key: "counts" } as const, ZERO);

export type Action = { kind: keyof Counts; toast?: string };

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

const TOAST_MAX = 100;

export const firstLine = (text: string) => {
  const line =
    text
      .trim()
      .split("\n")
      .find((l) => l.trim() !== "") ?? "";
  return line.length > TOAST_MAX ? `${line.slice(0, TOAST_MAX - 1)}…` : line;
};

const said = (text: string) => (firstLine(text) ? `: ${firstLine(text)}` : "");

// What Jev did at one event, most important first. `where` is the tool name
// for tool events, the event name otherwise.
export const actionsOf = (
  event: string,
  where: string,
  r: Outcome | undefined,
): Action[] => {
  if (!r) return [];
  const acts: Action[] = [];
  if (r.deny !== undefined) {
    acts.push({
      kind: "blocked",
      toast: `⚡ Jev blocked ${where}${said(r.deny)}`,
    });
  } else if (r.ask !== undefined) {
    acts.push({
      kind: "blocked",
      toast: `⚡ Jev asked about ${where}${said(r.ask)}`,
    });
  }
  if (r.block !== undefined) {
    acts.push({
      kind: "blocked",
      toast: `⚡ Jev held ${where}${said(r.block)}`,
    });
  }
  if (r.preventContinuation) {
    acts.push({
      kind: "blocked",
      toast: `⚡ Jev stopped the session${said(r.stopReason ?? "")}`,
    });
  }
  const context = (r.additionalContext ?? []).filter((c) => c.trim() !== "");
  if (context.length > 0) {
    acts.push({
      kind: "noted",
      toast: `⚡ Jev noted (${event})${said(context[0] ?? "")}`,
    });
  }
  if (r.updatedInput !== undefined) {
    acts.push({ kind: "noted", toast: `⚡ Jev rewrote ${where}'s input` });
  }
  if (
    r.updatedToolOutput !== undefined ||
    r.updatedMCPToolOutput !== undefined
  ) {
    acts.push({ kind: "trimmed" });
  }
  return acts;
};

export const statusText = (c: Counts) =>
  `⚡ Jev ${c.blocked} blocked · ${c.noted} noted · ${c.trimmed} trimmed`;

const record = async ($: EngineInterface, acts: Action[]) => {
  if (acts.length === 0) return;
  await update($, counts, (c) => {
    const next = { ...ZERO, ...c };
    for (const a of acts) next[a.kind] += 1;
    return next;
  });
  $.ui.status(statusText(await read($, counts)));
  const toast = acts.find((a) => a.toast)?.toast;
  if (toast) $.ui.toast(toast);
};

// A marker must never break the hook chain: a failure to draw it is dropped.
const mark = ($: EngineInterface, event: string, where: string, r: unknown) =>
  record($, actionsOf(event, where, r as Outcome)).catch(() => undefined);

// If a hook here throws, hand on what Jev decided: next(e) replays the call
// that already ran, so nothing runs twice and a Jev block still stands.
const keepJev = <E, R>(_$: unknown, e: E, next: (e: E) => R) => next(e);

export const register: Register = (on) => {
  // A reload or resume keeps the counts; put the status line back.
  on("session.start", async ($, e, next) => {
    const result = await next(e);
    const c = await read($, counts);
    if (c.blocked + c.noted + c.trimmed > 0) $.ui.status(statusText(c));
    return result;
  });

  on("classic.PreToolUse", async ($, e, next) => {
    const r = await next(e);
    await mark($, "PreToolUse", e.tool, r);
    return r;
  }).catch(keepJev);

  on("classic.PostToolUse", async ($, e, next) => {
    const r = await next(e);
    await mark($, "PostToolUse", e.tool_name, r);
    return r;
  }).catch(keepJev);

  on("classic.PostToolUseFailure", async ($, e, next) => {
    const r = await next(e);
    await mark($, "PostToolUseFailure", e.tool_name, r);
    return r;
  }).catch(keepJev);

  on("classic.UserPromptSubmit", async ($, e, next) => {
    const r = await next(e);
    await mark($, "UserPromptSubmit", "your prompt", r);
    return r;
  }).catch(keepJev);

  on("classic.Stop", async ($, e, next) => {
    const r = await next(e);
    await mark($, "Stop", "the stop", r);
    return r;
  }).catch(keepJev);

  on("classic.SessionStart", async ($, e, next) => {
    const r = await next(e);
    await mark($, "SessionStart", "session start", r);
    return r;
  }).catch(keepJev);
};
