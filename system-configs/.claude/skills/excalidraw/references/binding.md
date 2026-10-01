# Binding

Binding is where generated Excalidraw files fail most often. Read this before emitting any
labelled shape.

## Text inside a shape

**`"label": { "text": "..." }` is not a valid Excalidraw property.** It parses without error and
is silently ignored, so the file opens with beautiful, completely blank boxes. There is no
warning. If a generated diagram renders as empty shapes, this is why.

The real mechanism is a bidirectional pair of references. **Both halves are required.**

1. The container lists the text in `boundElements`.
2. The text points back via `containerId`.

```json
[
  {
    "id": "box1",
    "type": "rectangle",
    "x": 100,
    "y": 100,
    "width": 220,
    "height": 100,
    "boundElements": [{ "id": "box1_label", "type": "text" }],
    "strokeColor": "#7aa2f7",
    "backgroundColor": "#2b334c",
    "fillStyle": "solid",
    "strokeWidth": 2,
    "strokeStyle": "solid",
    "roughness": 1,
    "opacity": 100,
    "angle": 0,
    "seed": 1001,
    "groupIds": [],
    "frameId": null,
    "roundness": { "type": 3 },
    "link": null,
    "locked": false,
    "isDeleted": false
  },
  {
    "id": "box1_label",
    "type": "text",
    "x": 130,
    "y": 137,
    "width": 160,
    "height": 25,
    "containerId": "box1",
    "text": "Bound label",
    "originalText": "Bound label",
    "fontSize": 20,
    "fontFamily": 5,
    "lineHeight": 1.25,
    "textAlign": "center",
    "verticalAlign": "middle",
    "autoResize": true,
    "strokeColor": "#c0caf5",
    "backgroundColor": "transparent",
    "fillStyle": "solid",
    "strokeWidth": 2,
    "strokeStyle": "solid",
    "roughness": 1,
    "opacity": 100,
    "angle": 0,
    "seed": 1002,
    "groupIds": [],
    "frameId": null,
    "roundness": null,
    "boundElements": null,
    "link": null,
    "locked": false,
    "isDeleted": false
  }
]
```

Rules:

- Valid containers are `rectangle`, `ellipse`, `diamond`, and `arrow`. Nothing else.
- Use `textAlign: "center"` with `verticalAlign: "middle"` for centred labels.
- Position the text yourself. Compute `x = container.x + (container.width - textWidth) / 2` and
  `y = container.y + (container.height - textHeight) / 2`, where
  `textHeight = fontSize * lineHeight`.
- Excalidraw reserves `BOUND_TEXT_PADDING = 5` px inside the container. Keep text width at or
  below `container.width - 10`.
- One text element per container. A second `text` entry in `boundElements` is undefined
  behaviour.

## Arrow labels

Arrows are containers too. Same pattern: the arrow lists the text in `boundElements`, the text
sets `containerId` to the arrow id. Excalidraw sizes arrow labels against
`ARROW_LABEL_WIDTH_FRACTION = 0.7` of the arrow length, so long labels on short arrows wrap
badly. For sequence diagrams, a free-floating text element above the arrow is more predictable
than a bound label.

## Arrow-to-shape binding

Bound arrows follow their shapes when the shapes move. The binding schema has churned upstream,
which matters when you generate files rather than draw them.

Current `master` uses `FixedPointBinding`:

```json
{
  "elementId": "box1",
  "fixedPoint": [0.5, 1.0],
  "mode": "orbit"
}
```

`fixedPoint` is a `[horizontal, vertical]` ratio in `0.0–1.0` multiplied by the bound element's
width and height. `mode` is `inside`, `orbit`, or `skip`. Older files in the wild instead carry
`{ elementId, focus, gap }`.

**Recommendation for generated diagrams: leave `startBinding` and `endBinding` as `null` and
place arrows with explicit `points`.** Explicit points render identically on every Excalidraw
version, and a generated file is regenerated rather than dragged around. Both bundled goldens do
this. Reach for bindings only when the diagram is a starting point a human will edit by hand.

If you do bind, keep it consistent: an arrow with a non-null `startBinding` should also appear in
that shape's `boundElements` as `{ "id": "<arrowId>", "type": "arrow" }`. A one-sided reference
leaves the arrow detached on the next edit.
