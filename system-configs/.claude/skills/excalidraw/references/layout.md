# Layout

Excalidraw has no auto-layout. Every coordinate in a generated file is one you computed, so
layout is arithmetic, not judgement. These constants keep diagrams consistent.

## Spacing scale

| Token           | Value | Use                                                             |
| --------------- | ----- | --------------------------------------------------------------- |
| Node width      | `200` | Standard box. `280` when labels exceed ~18 characters.          |
| Node height     | `76`  | Single-line label. `104` for two lines.                         |
| Column gap      | `40`  | Horizontal gap between sibling nodes.                           |
| Row gap         | `104` | Vertical gap between tiers — enough for an arrow plus its head. |
| Row pitch       | `180` | Node height plus row gap. Use as the `y` step between tiers.    |
| Gutter          | `80`  | Left margin for tier labels and titles.                         |
| Title size      | `28`  | Diagram title.                                                  |
| Tier label size | `14`  | Uppercase, `ink.muted`.                                         |
| Body size       | `20`  | Node labels.                                                    |
| Annotation size | `16`  | Edge labels and notes.                                          |

## Text width

The exporter falls back to a system sans because Excalifont is not bundled with it, so text
measures slightly differently in the render than in the browser. Estimate conservatively:

```text
width ≈ characters × fontSize × 0.55
```

Then clamp bound label width to `container.width - 10` (Excalidraw reserves
`BOUND_TEXT_PADDING = 5` on each side). Over-estimating is safe; under-estimating pushes text
past the container edge.

If a label does not fit at `0.55`, widen the node rather than shrinking the font. Mixed font
sizes across sibling nodes read as accidental.

## Arrow routing

The single most common layout defect in generated diagrams is an arrow drawn from the bottom of
one node to the top of another **when both sit in the same row**. It slashes diagonally across
the neighbours between them.

Rules:

- Cross-row edge: exit bottom-centre, enter top-centre.
- Same-row edge: exit right-centre, enter left-centre — and only when the two nodes are adjacent.
- A same-row edge between non-adjacent nodes means the layout is wrong. Promote one node to its
  own row instead of routing around the obstruction.

The bundled `architecture-layers` golden puts the gateway in its own tier for exactly this
reason: it makes every edge cross-row by construction. Asserting on it is cheap:

```javascript
if (from.y === to.y)
  throw new Error("same-row edge would route through neighbours");
```

## Composition

- **Tiers over grids.** A grid of identical cards carries no information. If a diagram has
  layers, show the layers.
- **One idea per row.** A row should answer one question: what talks to the edge, what stores
  state.
- **Left gutter for structure.** Tier labels live at `x = 80` in `ink.muted`, uppercase, small.
  They orient the reader without competing with the nodes.
- **Vary the shape when the meaning varies.** Rectangles for services, diamonds for decisions,
  ellipses for external actors. Uniform shapes make everything look like the same kind of thing.
- **Dashed for the secondary path.** Async writes, retries, and fallbacks read as dashed; the
  happy path stays solid.

## Sequence diagrams

- Lane pitch `300`, actor box `180 × 64` at `y = 110`.
- Lifelines are dashed arrows with `endArrowhead: null`, from the bottom of the actor box down.
- Message pitch `80` vertically. Labels sit `26` above their arrow.
- Stop the lifelines shortly after the last message. Trailing empty lifeline is dead space.
- Responses dashed, requests solid.

## Canvas budget

Keep a diagram under roughly `1600 × 1200`. Past that, viewers zoom out until labels are
unreadable. Split into multiple diagrams instead — one per concern — rather than growing one.

Build the JSON one section at a time. A single-pass emit of a comprehensive diagram will exceed
the ~32,000 token output ceiling and truncate mid-element, producing invalid JSON.
