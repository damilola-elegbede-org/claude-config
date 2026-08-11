---
name: excalidraw
description: >-
  Create Excalidraw diagrams (.excalidraw files) — flowcharts, architecture and system diagrams,
  sequence diagrams, state machines, network topologies, mind maps, and annotated sketches — with
  a themed palette and a render-and-look verification loop. Use when the user asks to draw,
  diagram, sketch, or visualise a system, flow, or architecture, or mentions Excalidraw by name.
  Not for database schemas or entity-relationship diagrams, which belong in a schema tool that
  emits real DDL.
argument-hint: "[subject] [--theme <theme-id>]"
metadata:
  category: workflow
---

# /excalidraw

## Usage

```bash
/excalidraw                                    # Diagram the thing under discussion
/excalidraw the checkout flow                  # Diagram a named subject
/excalidraw --theme github-light auth handoff  # Pick a theme explicitly
```

Supporting scripts, run from the skill directory:

```bash
node scripts/render.mjs <file> [-o out.png] [--dark] [--both] [--svg] [--scale N]
node scripts/check-theme.mjs [--theme <id> <file>]
```

## Description

Generates `.excalidraw` files, renders them to PNG, looks at the result, and fixes what is wrong
before handing anything over. Diagrams that are never rendered contain overlapping text and
arrows that cut through boxes; the author cannot see it, and neither can you without looking.

Eleven bundled themes carry the palette — eight dark, three light — modelled on well-known
editor themes. Colours are baked into the elements rather than left to Excalidraw's dark-mode
filter, so a Tokyo Night diagram is Tokyo Night on every build.

Use for flowcharts, architecture and system diagrams, sequence diagrams, state machines, network
topologies, mind maps, user flows, and annotated sketches.

## Behavior

### Workflow

1. **Choose a theme.** Default `tokyo-night`. Use `github-light` for docs, slides, or print.
   Full list in [references/themes.md](references/themes.md).
2. **Plan the layout first.** Assign every node to a tier and confirm no edge is same-row.
   Fixing this after emitting JSON means recomputing every coordinate.
3. **Emit JSON section by section** — one tier or one lane at a time. A single-pass emit of a
   large diagram exceeds the ~32,000 token output ceiling and truncates mid-element.
4. **Render and look**, then actually read the PNG. Check for text spilling past its container,
   arrows crossing shapes, overlapping nodes, uneven spacing, and unreadable contrast.
5. **Fix and re-render** until the image is right. This loop is not optional — it is the only
   thing separating this from emitting plausible JSON and hoping.
6. **Validate** with `check-theme.mjs` before handing over.

### Non-negotiables

**Bind labels bidirectionally.** `"label": { "text": "..." }` is not a real Excalidraw property.
It is silently ignored and the file opens with blank shapes. The container needs
`boundElements: [{ id, type: "text" }]` and the text needs `containerId` pointing back — both
halves, every time. This is the most common failure mode. See
[references/binding.md](references/binding.md).

**Leave arrows unbound.** Set `startBinding` and `endBinding` to `null` and place arrows with
explicit `points`. The binding schema has churned upstream (`focus`/`gap` became
`fixedPoint`/`mode`); explicit points render identically everywhere.

**Never embed bitmap images.** Excalidraw counter-filters them in dark mode and they come back
desaturated. Vector elements only.

**Never set `appState.theme: "dark"`.** The bundled themes bake their colours in. Excalidraw's
dark mode is an inversion filter, so asking it to invert an already-dark palette produces a light
diagram in wrong colours. See [references/themes.md](references/themes.md).

**No same-row arrows between non-adjacent nodes.** Promote a node to its own tier instead of
routing around obstructions.

### Choosing the form

| Intent                     | Form                                                             |
| -------------------------- | ---------------------------------------------------------------- |
| What calls what            | Layered architecture — tiers top to bottom, every edge cross-row |
| What happens in what order | Sequence — vertical lifelines, horizontal messages               |
| What states exist          | State machine — ellipses, labelled transitions                   |
| How a decision branches    | Flowchart — diamonds for branches, rectangles for steps          |
| What sits where            | Network topology — grouped by boundary, frames for zones         |
| Why something is as it is  | Annotated map — shapes plus `ink.muted` margin notes             |

Vary shape with meaning. Rectangles for services, diamonds for decisions, ellipses for external
actors. A page of identical rounded rectangles conveys nothing beyond its labels.

### Layout constants

Node `200 × 76`, column gap `40`, row pitch `180`, left gutter `80`. Title `28`, body `20`,
annotations `16`, tier labels `14` uppercase in `ink.muted`. Estimate text width as
`characters × fontSize × 0.55` and clamp bound labels to `container.width - 10`. Full table in
[references/layout.md](references/layout.md).

### Not this skill

Database schemas and entity-relationship diagrams. A picture of a schema drifts from the schema
within a week. Use a tool that emits real DDL or Prisma and generates the picture from it.

## Expected Output

```text
Wrote checkout-topology.excalidraw (24 elements, theme tokyo-night)
Rendered checkout-topology.png — reviewed, 2 fixes applied:
  - "Inventory service" label overflowed its container (widened node to 280)
  - Payments -> Orders DB crossed the Inventory node (moved to its own tier)
ok   checkout-topology.excalidraw conforms to theme tokyo-night

Open with: open checkout-topology.excalidraw
```

## Reference

- [references/element-schema.md](references/element-schema.md) — every element property,
  default, and enum. The upstream JSON-schema doc is incomplete; this is the reference.
- [references/binding.md](references/binding.md) — text and arrow binding.
- [references/themes.md](references/themes.md) — the dark-mode filter, baked themes, theme list.
- [references/layout.md](references/layout.md) — spacing, routing, composition.
- `goldens/` — worked examples with their rendered output. `architecture-layers` (Tokyo Night)
  and `request-sequence` (GitHub Light, with a `.dark.png` showing the filter).

## Notes

`render.mjs` shells out to `@moona3k/excalidraw-export` via `npx`, so the first run downloads it.
The exporter does not implement dark mode — `--dark` applies the real filter maths from
`scripts/dark-filter.mjs` to the colours first, then renders. Without that, "dark mode" output is
light-coloured shapes on a dark background, which looks fine in the render and wrong in the app.

Two other exporters were evaluated and are currently uninstallable: `excalirender` pins
`sharp@^0.35.3` and `@swiftlysingh/excalidraw-cli` pins `jsdom@^28.1.0`; neither version exists
on npm. Swapping exporters means editing `EXPORTER` in `render.mjs` and nothing else.

The exporter falls back to a system sans because Excalifont is not bundled with it, so rendered
text is close to but not identical to the browser. Estimate text width conservatively and prefer
widening a node over shrinking a font.
