#!/usr/bin/env node
/**
 * Render an .excalidraw file to PNG/SVG so the agent can look at its own output.
 *
 * This is deliberately a thin wrapper over one external exporter. Every
 * pure-computation exporter on npm is pre-1.0 and two of the three are
 * currently uninstallable (excalirender pins sharp@^0.35.3, and
 * @swiftlysingh/excalidraw-cli pins jsdom@^28.1.0 — neither version exists).
 * Keeping the dependency behind this file means swapping exporters, or moving
 * to a Playwright-based one, is a one-file change.
 *
 * Usage:
 *   node render.mjs <input.excalidraw> [-o out.png] [--dark] [--both]
 *                                      [--svg] [--scale N]
 *
 *   --dark   Render the diagram as it will appear under Excalidraw's dark
 *            theme. The exporter does NOT implement the dark filter, so we
 *            transform the colours ourselves first (see dark-filter.mjs).
 *   --both   Write <out>.png and <out>.dark.png in one pass.
 */

import { spawnSync } from "node:child_process";
import { readFileSync, writeFileSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, basename, extname, dirname } from "node:path";
import { fileURLToPath } from "node:url";

import { simulateDarkScene } from "./dark-filter.mjs";

const EXPORTER = process.env.EXCALIDRAW_EXPORTER ?? "@moona3k/excalidraw-export@0.2.1";

function parseArgs(argv) {
  const opts = { dark: false, both: false, svg: false, scale: null, output: null, input: null };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--dark") opts.dark = true;
    else if (a === "--both") opts.both = true;
    else if (a === "--svg") opts.svg = true;
    else if (a === "--scale") opts.scale = argv[++i];
    else if (a === "-o" || a === "--output") opts.output = argv[++i];
    else if (!a.startsWith("-")) opts.input = a;
  }
  return opts;
}

function defaultOutput(input, svg, dark) {
  const stem = basename(input, extname(input));
  const suffix = dark ? ".dark" : "";
  return join(dirname(input), `${stem}${suffix}.${svg ? "svg" : "png"}`);
}

function runExporter(inputPath, outputPath, opts) {
  const args = ["-y", EXPORTER, inputPath, "-o", outputPath];
  if (opts.svg) args.push("--svg");
  if (opts.scale) args.push("--scale", opts.scale);

  const res = spawnSync("npx", args, { encoding: "utf8" });
  if (res.error) throw new Error(`Failed to launch exporter: ${res.error.message}`);
  if (res.status !== 0) {
    throw new Error(
      `Exporter failed (exit ${res.status}).\n${res.stderr || res.stdout}`.trim(),
    );
  }
  return (res.stdout || "").trim();
}

function renderOne(scenePath, sceneJson, outputPath, opts, dark) {
  if (!dark) {
    runExporter(scenePath, outputPath, opts);
    return outputPath;
  }

  // Transform colours, then hand the exporter an ordinary light-theme scene.
  const tmp = mkdtempSync(join(tmpdir(), "excalidraw-render-"));
  try {
    const darkPath = join(tmp, "scene.excalidraw");
    writeFileSync(darkPath, JSON.stringify(simulateDarkScene(sceneJson)));
    runExporter(darkPath, outputPath, opts);
    return outputPath;
  } finally {
    rmSync(tmp, { recursive: true, force: true });
  }
}

function main() {
  const opts = parseArgs(process.argv.slice(2));

  if (!opts.input) {
    console.error("usage: render.mjs <input.excalidraw> [-o out] [--dark] [--both] [--svg] [--scale N]");
    process.exit(2);
  }

  let sceneJson;
  try {
    sceneJson = JSON.parse(readFileSync(opts.input, "utf8"));
  } catch (err) {
    console.error(`Cannot read ${opts.input}: ${err.message}`);
    process.exit(1);
  }

  const written = [];
  try {
    if (opts.both) {
      const light = opts.output ?? defaultOutput(opts.input, opts.svg, false);
      const darkName = light.replace(/(\.[^.]+)$/, ".dark$1");
      written.push(renderOne(opts.input, sceneJson, light, opts, false));
      written.push(renderOne(opts.input, sceneJson, darkName, opts, true));
    } else {
      const out = opts.output ?? defaultOutput(opts.input, opts.svg, opts.dark);
      written.push(renderOne(opts.input, sceneJson, out, opts, opts.dark));
    }
  } catch (err) {
    console.error(err.message);
    process.exit(1);
  }

  for (const path of written) console.log(path);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) main();
