# Excalidraw element schema

Derived from `packages/element/src/types.ts` and `packages/common/src/constants.ts` on
`excalidraw/excalidraw@master`. The published JSON-schema doc stops at
`/* ...other element properties */`, so this file — not the upstream docs — is the reference.

## File envelope

```json
{
  "type": "excalidraw",
  "version": 2,
  "source": "https://excalidraw.com",
  "elements": [],
  "appState": { "viewBackgroundColor": "#ffffff", "gridSize": null },
  "files": {}
}
```

`version` is the _format_ version (currently `2`) and is unrelated to the per-element `version`
counter. `files` maps `fileId` to embedded image data; leave it `{}` — see the raster warning in
[themes.md](./themes.md).

## Base properties

Every element carries all of these.

| Property          | Type        | Default       | Notes                                                        |
| ----------------- | ----------- | ------------- | ------------------------------------------------------------ |
| `id`              | string      | —             | Any unique string. Human-readable ids make diffs reviewable. |
| `type`            | string      | —             | See element types below.                                     |
| `x`, `y`          | number      | —             | Scene coordinates of the top-left corner.                    |
| `width`, `height` | number      | —             | Bounding box.                                                |
| `angle`           | number      | `0`           | **Radians**, not degrees.                                    |
| `strokeColor`     | string      | `#1e1e1e`     | Hex.                                                         |
| `backgroundColor` | string      | `transparent` | Hex or `transparent`.                                        |
| `fillStyle`       | enum        | `solid`       | `hachure`, `cross-hatch`, `solid`, `zigzag`                  |
| `strokeWidth`     | number      | `2`           | `1` thin, `2` medium, `4` bold.                              |
| `strokeStyle`     | enum        | `solid`       | `solid`, `dashed`, `dotted`                                  |
| `roughness`       | number      | `1`           | `0` architect, `1` artist, `2` cartoonist.                   |
| `roundness`       | object/null | `null`        | `null` for sharp; `{"type": 3}` for rounded rectangles.      |
| `opacity`         | number      | `100`         | 0–100.                                                       |
| `seed`            | number      | —             | Seeds the roughjs shape. Fixed value = stable renders.       |
| `groupIds`        | string[]    | `[]`          | Deepest group first.                                         |
| `frameId`         | string/null | `null`        | Owning frame.                                                |
| `boundElements`   | array/null  | `null`        | `[{ "id", "type": "arrow" \| "text" }]`                      |
| `link`            | string/null | `null`        | Hyperlink.                                                   |
| `locked`          | boolean     | `false`       |                                                              |
| `isDeleted`       | boolean     | `false`       | Always emit `false`.                                         |

Omit `version`, `versionNonce`, `updated`, and `index`. They exist for collaboration
reconciliation and fractional ordering; Excalidraw's `restoreElements` fills them in on load.
Array order determines z-order for generated files.

### `roundness` values

`1` legacy, `2` proportional radius (linear elements and diamonds), `3` adaptive radius
(the current default for rectangles). Use `{"type": 3}` on rectangles and `null` on text.

## Element types

### rectangle, ellipse, diamond

Base properties only. These three are the valid _containers_ for bound text.

### text

| Property        | Type        | Notes                                                 |
| --------------- | ----------- | ----------------------------------------------------- |
| `text`          | string      | Rendered content.                                     |
| `originalText`  | string      | Pre-wrap source. Set equal to `text` unless wrapping. |
| `fontSize`      | number      | Default `20`.                                         |
| `fontFamily`    | number      | Numeric code — see below.                             |
| `textAlign`     | enum        | `left`, `center`, `right`                             |
| `verticalAlign` | enum        | `top`, `middle`, `bottom`                             |
| `containerId`   | string/null | Set when bound inside a shape.                        |
| `autoResize`    | boolean     | `true` fits width to text; `false` wraps to width.    |
| `lineHeight`    | number      | Unitless. `1.25` is the usual value.                  |

Font family codes: `1` Virgil, `2` Helvetica, `3` Cascadia, `5` Excalifont, `6` Nunito,
`7` Lilita One, `8` Comic Shanns, `9` Liberation Sans, `10` Assistant. `4` is unused. The
default is `5` (Excalifont).

### arrow, line

| Property         | Type        | Notes                                                           |
| ---------------- | ----------- | --------------------------------------------------------------- |
| `points`         | `[x, y][]`  | **Relative to the element's `x`/`y`.** First point is `[0, 0]`. |
| `startBinding`   | object/null | See [binding.md](./binding.md).                                 |
| `endBinding`     | object/null | See [binding.md](./binding.md).                                 |
| `startArrowhead` | string/null | `null` for a plain tail.                                        |
| `endArrowhead`   | string/null | `arrow` is the usual head.                                      |
| `elbowed`        | boolean     | Arrows only. `false` for straight/curved.                       |
| `polygon`        | boolean     | Lines only. Closes the shape.                                   |

Arrowheads: `arrow`, `bar`, `circle`, `circle_outline`, `triangle`, `triangle_outline`,
`diamond`, `diamond_outline`, plus the cardinality set (`cardinality_one`, `cardinality_many`,
`cardinality_one_or_many`, `cardinality_exactly_one`, `cardinality_zero_or_one`,
`cardinality_zero_or_many`). Legacy values `dot`, `crowfoot_one`, `crowfoot_many`,
`crowfoot_one_or_many` still parse.

Set `width`/`height` to the bounding box of `points`, otherwise selection and export bounds are
wrong even though the line draws correctly.

### frame

Adds `name: string | null`. Frames group elements; children reference the frame via `frameId`.
Excalidraw styles frames itself (`#bbb` stroke, transparent fill, 8px radius), so leave frame
colours alone.

### image

Adds `fileId`, `status`, `scale`, `crop`. **Avoid** — Excalidraw counter-filters bitmaps in dark
mode with `invert(100%) hue-rotate(180deg) saturate(1.25)`, which desaturates them. Use vector
elements.

## Minimum viable element

`restoreElements` backfills defaults, so this is enough to render a rounded box:

```json
{
  "id": "box1",
  "type": "rectangle",
  "x": 100,
  "y": 100,
  "width": 220,
  "height": 100,
  "angle": 0,
  "strokeColor": "#7aa2f7",
  "backgroundColor": "#2b334c",
  "fillStyle": "solid",
  "strokeWidth": 2,
  "strokeStyle": "solid",
  "roughness": 1,
  "opacity": 100,
  "seed": 12345,
  "groupIds": [],
  "frameId": null,
  "roundness": { "type": 3 },
  "boundElements": null,
  "link": null,
  "locked": false,
  "isDeleted": false
}
```
