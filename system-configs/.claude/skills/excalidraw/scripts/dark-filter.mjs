/**
 * Reimplementation of Excalidraw's dark-mode colour transform.
 *
 * Excalidraw does not store a separate dark palette. It renders dark mode by
 * applying `DARK_THEME_FILTER = "invert(93%) hue-rotate(180deg)"` — as a CSS
 * filter on the interactive canvas, and mathematically (applyDarkModeFilter)
 * to element colours on the static canvas.
 *
 * We replicate the maths so we can (a) preview what an authored-light palette
 * becomes in dark mode, and (b) check contrast in both modes without a browser.
 *
 * CSS filter functions operate in sRGB, so no linearisation is applied.
 */

const INVERT_AMOUNT = 0.93;

/** Parse #rgb / #rrggbb into [r,g,b] in 0..1. Returns null for non-hex. */
export function parseHex(color) {
  if (typeof color !== "string") return null;
  let hex = color.trim().toLowerCase();
  if (hex === "transparent") return null;
  if (!hex.startsWith("#")) return null;
  hex = hex.slice(1);
  if (hex.length === 3) hex = hex.split("").map((c) => c + c).join("");
  if (hex.length === 8) hex = hex.slice(0, 6); // drop alpha
  if (hex.length !== 6 || /[^0-9a-f]/.test(hex)) return null;
  return [
    parseInt(hex.slice(0, 2), 16) / 255,
    parseInt(hex.slice(2, 4), 16) / 255,
    parseInt(hex.slice(4, 6), 16) / 255,
  ];
}

export function toHex([r, g, b]) {
  const c = (v) =>
    Math.round(Math.min(1, Math.max(0, v)) * 255)
      .toString(16)
      .padStart(2, "0");
  return `#${c(r)}${c(g)}${c(b)}`;
}

/** CSS invert(amount): c' = amount*(1-c) + (1-amount)*c */
function invert(rgb, amount = INVERT_AMOUNT) {
  return rgb.map((c) => amount * (1 - c) + (1 - amount) * c);
}

/**
 * CSS hue-rotate(180deg) per the Filter Effects spec matrix.
 * At 180deg, cos = -1 and sin = 0, which collapses the general matrix to this.
 * Each row sums to 1.0, so greys are preserved exactly.
 */
function hueRotate180([r, g, b]) {
  return [
    -0.574 * r + 1.43 * g + 0.144 * b,
    0.426 * r + 0.43 * g + 0.144 * b,
    0.426 * r + 1.43 * g - 0.856 * b,
  ];
}

/**
 * Apply Excalidraw's dark-mode filter to a single colour string.
 * Non-hex values (notably "transparent") are returned unchanged.
 */
export function applyDarkModeFilter(color) {
  const rgb = parseHex(color);
  if (!rgb) return color;
  return toHex(hueRotate180(invert(rgb)));
}

/** Relative luminance per WCAG 2.1. */
export function luminance(rgb) {
  const [r, g, b] = rgb.map((c) =>
    c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4),
  );
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/** WCAG contrast ratio between two hex colours. Returns null if either is non-hex. */
export function contrastRatio(a, b) {
  const ca = parseHex(a);
  const cb = parseHex(b);
  if (!ca || !cb) return null;
  const la = luminance(ca);
  const lb = luminance(cb);
  const [hi, lo] = la > lb ? [la, lb] : [lb, la];
  return (hi + 0.05) / (lo + 0.05);
}

/**
 * Transform a whole Excalidraw scene into its dark-mode appearance.
 *
 * Returns a new scene where every colour has been run through the filter and
 * appState.theme is left as "light" — because the colours are already
 * transformed, letting the app invert them again would undo the effect.
 */
export function simulateDarkScene(scene) {
  const COLOR_KEYS = ["strokeColor", "backgroundColor"];
  const next = structuredClone(scene);

  next.elements = (next.elements ?? []).map((el) => {
    const out = { ...el };
    for (const key of COLOR_KEYS) {
      if (out[key] != null) out[key] = applyDarkModeFilter(out[key]);
    }
    return out;
  });

  next.appState = { ...(next.appState ?? {}) };
  next.appState.viewBackgroundColor = applyDarkModeFilter(
    next.appState.viewBackgroundColor ?? "#ffffff",
  );
  next.appState.theme = "light";

  return next;
}
