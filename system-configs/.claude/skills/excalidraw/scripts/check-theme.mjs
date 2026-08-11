#!/usr/bin/env node
/**
 * Validate the bundled themes, and optionally a diagram's colours against one.
 *
 * Run with no arguments to check every theme in ../themes:
 *   node check-theme.mjs
 *
 * Pass a diagram to confirm it only uses colours from a theme:
 *   node check-theme.mjs --theme tokyo-night diagram.excalidraw
 *
 * Checks performed on each theme:
 *   - required keys present, all colours are 6-digit hex
 *   - six categorical surfaces, slots unique and in the canonical order
 *   - text-on-fill contrast clears WCAG AA (4.5)
 *   - stroke-on-canvas contrast clears 3.0 (non-text UI minimum)
 *   - the recorded `contrast` value matches a recomputation
 */

import { readdirSync, readFileSync, existsSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import { contrastRatio, parseHex } from "./dark-filter.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const THEMES_DIR = join(HERE, "..", "themes");

const AA_TEXT = 4.5;
const AA_NON_TEXT = 3.0;
const SLOT_ORDER = ["blue", "green", "amber", "red", "violet", "teal"];

const isHex = (v) => typeof v === "string" && /^#[0-9a-fA-F]{6}$/.test(v);

function checkTheme(theme, file) {
  const errors = [];
  const warnings = [];
  const err = (m) => errors.push(`${file}: ${m}`);
  const warn = (m) => warnings.push(`${file}: ${m}`);

  for (const key of ["id", "name", "mode", "authored", "canvas", "ink", "surfaces", "defaults"]) {
    if (theme[key] == null) err(`missing required key "${key}"`);
  }
  if (errors.length) return { errors, warnings };

  if (!["dark", "light"].includes(theme.mode)) err(`mode must be dark|light, got "${theme.mode}"`);
  if (theme.authored !== "baked") err(`authored must be "baked", got "${theme.authored}"`);

  for (const [group, keys] of [
    ["canvas", ["background", "panel"]],
    ["ink", ["primary", "muted", "connector"]],
  ]) {
    for (const k of keys) {
      if (!isHex(theme[group]?.[k])) err(`${group}.${k} is not 6-digit hex: ${theme[group]?.[k]}`);
    }
  }

  if (!Array.isArray(theme.surfaces) || theme.surfaces.length !== 6) {
    err(`expected 6 surfaces, got ${theme.surfaces?.length}`);
    return { errors, warnings };
  }

  const slots = theme.surfaces.map((s) => s.slot);
  if (slots.join(",") !== SLOT_ORDER.join(",")) {
    err(`surface slots must be exactly ${SLOT_ORDER.join(",")} in order, got ${slots.join(",")}`);
  }

  for (const s of theme.surfaces) {
    for (const k of ["fill", "stroke", "text"]) {
      if (!isHex(s[k])) err(`surface "${s.slot}".${k} is not 6-digit hex: ${s[k]}`);
    }
    if (!isHex(s.fill) || !isHex(s.text)) continue;

    const actual = contrastRatio(s.text, s.fill);
    if (actual < AA_TEXT) {
      err(`surface "${s.slot}" text on fill is ${actual.toFixed(2)}, below AA ${AA_TEXT}`);
    }
    if (typeof s.contrast === "number" && Math.abs(actual - s.contrast) > 0.05) {
      err(`surface "${s.slot}" records contrast ${s.contrast} but recomputes to ${actual.toFixed(2)}`);
    }

    const onCanvas = contrastRatio(s.stroke, theme.canvas.background);
    if (onCanvas != null && onCanvas < AA_NON_TEXT) {
      warn(`surface "${s.slot}" stroke on canvas is ${onCanvas.toFixed(2)}, below ${AA_NON_TEXT}`);
    }
  }

  const connectorContrast = contrastRatio(theme.ink.connector, theme.canvas.background);
  if (connectorContrast != null && connectorContrast < AA_NON_TEXT) {
    warn(`ink.connector on canvas is ${connectorContrast.toFixed(2)}, below ${AA_NON_TEXT}`);
  }

  const bodyContrast = contrastRatio(theme.ink.primary, theme.canvas.background);
  if (bodyContrast != null && bodyContrast < AA_TEXT) {
    err(`ink.primary on canvas is ${bodyContrast.toFixed(2)}, below AA ${AA_TEXT}`);
  }

  return { errors, warnings };
}

function themeColorSet(theme) {
  const set = new Set(["transparent"]);
  set.add(theme.canvas.background.toLowerCase());
  set.add(theme.canvas.panel.toLowerCase());
  for (const v of Object.values(theme.ink)) set.add(v.toLowerCase());
  for (const s of theme.surfaces) {
    set.add(s.fill.toLowerCase());
    set.add(s.stroke.toLowerCase());
    set.add(s.text.toLowerCase());
  }
  return set;
}

function checkDiagram(diagramPath, theme) {
  const scene = JSON.parse(readFileSync(diagramPath, "utf8"));
  const allowed = themeColorSet(theme);
  const offenders = new Map();

  for (const el of scene.elements ?? []) {
    for (const key of ["strokeColor", "backgroundColor"]) {
      const v = el[key];
      if (v == null) continue;
      const norm = String(v).toLowerCase();
      if (!allowed.has(norm) && parseHex(norm) != null) {
        const entry = offenders.get(norm) ?? [];
        entry.push(`${el.type}#${el.id}.${key}`);
        offenders.set(norm, entry);
      }
    }
  }

  const bg = scene.appState?.viewBackgroundColor?.toLowerCase();
  const errors = [];
  if (bg && bg !== theme.canvas.background.toLowerCase()) {
    errors.push(
      `appState.viewBackgroundColor is ${bg}, theme expects ${theme.canvas.background}`,
    );
  }
  if (scene.appState?.theme === "dark") {
    errors.push(
      'appState.theme is "dark"; baked themes must stay "light" or Excalidraw will invert them',
    );
  }
  for (const [color, where] of offenders) {
    errors.push(`off-theme colour ${color} used by ${where.slice(0, 3).join(", ")}${where.length > 3 ? ` (+${where.length - 3} more)` : ""}`);
  }
  return errors;
}

function main() {
  const argv = process.argv.slice(2);
  let themeId = null;
  let diagram = null;
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--theme") themeId = argv[++i];
    else if (!argv[i].startsWith("-")) diagram = argv[i];
  }

  const files = readdirSync(THEMES_DIR).filter((f) => f.endsWith(".json") && !f.startsWith("_"));
  if (!files.length) {
    console.error(`No themes found in ${THEMES_DIR}`);
    process.exit(1);
  }

  let failed = false;
  const loaded = new Map();

  for (const file of files.sort()) {
    let theme;
    try {
      theme = JSON.parse(readFileSync(join(THEMES_DIR, file), "utf8"));
    } catch (e) {
      console.error(`FAIL ${file}: invalid JSON — ${e.message}`);
      failed = true;
      continue;
    }
    loaded.set(theme.id, theme);

    const { errors, warnings } = checkTheme(theme, file);
    for (const w of warnings) console.warn(`WARN ${w}`);
    if (errors.length) {
      failed = true;
      for (const e of errors) console.error(`FAIL ${e}`);
    } else {
      const worst = Math.min(...theme.surfaces.map((s) => contrastRatio(s.text, s.fill)));
      console.log(`ok   ${theme.id.padEnd(20)} ${theme.mode.padEnd(6)} worst text contrast ${worst.toFixed(2)}`);
    }
  }

  if (diagram) {
    if (!themeId) {
      console.error("--theme <id> is required when checking a diagram");
      process.exit(2);
    }
    const theme = loaded.get(themeId);
    if (!theme) {
      console.error(`Unknown theme "${themeId}". Available: ${[...loaded.keys()].join(", ")}`);
      process.exit(2);
    }
    if (!existsSync(diagram)) {
      console.error(`No such diagram: ${diagram}`);
      process.exit(2);
    }
    const errors = checkDiagram(diagram, theme);
    if (errors.length) {
      failed = true;
      for (const e of errors) console.error(`FAIL ${diagram}: ${e}`);
    } else {
      console.log(`ok   ${diagram} conforms to theme ${themeId}`);
    }
  }

  process.exit(failed ? 1 : 0);
}

main();
