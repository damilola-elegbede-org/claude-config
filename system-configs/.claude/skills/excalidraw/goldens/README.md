# Goldens

Worked examples, each committed as a `.excalidraw` source plus its rendered output. The pairing
is the point: the PNG shows the target, the JSON shows exactly how to reach it. A screenshot
alone cannot be reversed into coordinates or binding.

| File                             | Theme                  | Demonstrates                                                                                    |
| -------------------------------- | ---------------------- | ----------------------------------------------------------------------------------------------- |
| `architecture-layers.excalidraw` | `tokyo-night` (dark)   | Tiered layout, bidirectional label binding, cross-row-only routing, dashed secondary path       |
| `request-sequence.excalidraw`    | `github-light` (light) | Lifelines as headless dashed arrows, free-floating edge labels, solid request / dashed response |

`request-sequence.dark.png` is the same file rendered through Excalidraw's real dark-mode filter
(`invert(93%) hue-rotate(180deg)`), showing what a light-authored diagram becomes if viewed with
the app's dark theme on. There is no dark render of `architecture-layers` because it is already
baked dark — inverting it would produce a light diagram.

Regenerate the images after editing a source:

```bash
node ../scripts/render.mjs architecture-layers.excalidraw --scale 1
node ../scripts/render.mjs request-sequence.excalidraw --scale 1 --both
```

Check both still conform to their themes:

```bash
node ../scripts/check-theme.mjs --theme tokyo-night architecture-layers.excalidraw
node ../scripts/check-theme.mjs --theme github-light request-sequence.excalidraw
```

The `architecture-layers` generator asserts that no edge is same-row. That assertion exists
because the first draft of this golden routed `Checkout API → Payments` from the bottom of one
box to the top of its neighbour, slashing diagonally across the row. The render loop caught it;
reading the JSON would not have.
