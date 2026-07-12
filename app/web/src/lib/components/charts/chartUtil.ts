// Pure helpers for the hand-rolled inline-SVG charts (COMPUTE_VS_RENDER Phase 2).
// No dependencies, no DOM — geometry + tick + money-formatting math the chart
// components share. Money AXES scale by the raw numbers; TICKS are formatted here,
// data-point VALUES carry the exact money() `text` from the spec (never a bare
// float). See the dataviz skill for the mark/axis specs these encode.

/** Shared plot box (viewBox units; the <svg> scales to 100% width). */
export const LAYOUT = { W: 640, H: 240, mt: 16, mr: 18, mb: 34, ml: 62 };
export const plotW = LAYOUT.W - LAYOUT.ml - LAYOUT.mr;
export const plotH = LAYOUT.H - LAYOUT.mt - LAYOUT.mb;

/** The nice-number rounding at the heart of clean axis ticks (Heckbert). */
function niceNum(range: number, round: boolean): number {
  const exp = Math.floor(Math.log10(range || 1));
  const f = (range || 1) / Math.pow(10, exp);
  let nf: number;
  if (round) nf = f < 1.5 ? 1 : f < 3 ? 2 : f < 7 ? 5 : 10;
  else nf = f <= 1 ? 1 : f <= 2 ? 2 : f <= 5 ? 5 : 10;
  return nf * Math.pow(10, exp);
}

/** ~`maxTicks` clean, evenly-spaced tick values covering [min, max]. */
export function niceTicks(min: number, max: number, maxTicks = 5): number[] {
  if (!isFinite(min) || !isFinite(max) || min === max) {
    max = (min || 0) + 1;
    min = min || 0;
  }
  const range = niceNum(max - min, false);
  const step = niceNum(range / Math.max(1, maxTicks - 1), true) || 1;
  const lo = Math.floor(min / step) * step;
  const hi = Math.ceil(max / step) * step;
  const out: number[] = [];
  for (let v = lo; v <= hi + step * 0.5; v += step) out.push(Number(v.toFixed(6)));
  return out;
}

/** The currency symbol a money() string leads with (e.g. "$"), for tick labels.
 *  Derived from a sample so a non-USD money() format still labels ticks sensibly. */
export function currencySymbol(sample: string | undefined): string {
  if (!sample) return "$";
  const m = sample.replace(/^-/, "").match(/^[^0-9.,\s]+/);
  return m ? m[0] : "$";
}

/** Format an AXIS TICK value as compact currency (data points use their exact
 *  `text`). Clean magnitudes only ($0 / $1,000 / $2K / $1.2M) — never a raw float. */
export function moneyTick(n: number, sym = "$"): string {
  const sign = n < 0 ? "-" : "";
  const a = Math.abs(n);
  let s: string;
  if (a >= 1_000_000) s = (a / 1_000_000).toFixed(a % 1_000_000 === 0 ? 0 : 1) + "M";
  else if (a >= 10_000) s = (a / 1000).toFixed(a % 1000 === 0 ? 0 : 1) + "K";
  else s = a.toLocaleString("en-US");
  return sign + sym + s;
}

/** A value domain padded to clean tick bounds. Money spending includes 0 as the
 *  baseline; negatives (refunds/credits) extend the domain below it. */
export function moneyDomain(raw: number[]): { lo: number; hi: number; ticks: number[] } {
  const finite = raw.filter((v) => isFinite(v));
  const lo0 = Math.min(0, ...finite);
  const hi0 = Math.max(0, ...finite);
  const ticks = niceTicks(lo0, hi0 === lo0 ? lo0 + 1 : hi0);
  return { lo: ticks[0], hi: ticks[ticks.length - 1], ticks };
}

/** Show every x label when there's room, else a sparse subset (first, last, and a
 *  stride between) so labels never collide. */
export function labelStride(n: number, max = 8): number {
  return n <= max ? 1 : Math.ceil(n / max);
}

/** Pie/donut arc geometry for a SHARE-OF-WHOLE breakdown. Each slice's fraction is
 *  its value over the total of the (positive, finite) values — negatives/credits
 *  and non-finite values are treated as 0 so a share is always in [0, 1]. Angles
 *  are radians clockwise from 12 o'clock; `frac` is the share for the legend %. A
 *  zero total → all fracs 0 (the caller renders an empty state). */
export function pieArcs(raw: number[]): { a0: number; a1: number; frac: number }[] {
  const vals = raw.map((v) => (isFinite(v) && v > 0 ? v : 0));
  const total = vals.reduce((s, v) => s + v, 0);
  const out: { a0: number; a1: number; frac: number }[] = [];
  let acc = 0;
  const TAU = 2 * Math.PI;
  for (const v of vals) {
    const frac = total > 0 ? v / total : 0;
    const a0 = acc * TAU;
    acc += frac;
    out.push({ a0, a1: acc * TAU, frac });
  }
  return out;
}

/** A point on a circle of radius `r` about (cx, cy) at angle `ang` (radians,
 *  clockwise from 12 o'clock). */
function polar(cx: number, cy: number, r: number, ang: number): [number, number] {
  return [cx + r * Math.sin(ang), cy - r * Math.cos(ang)];
}

/** A donut-sector (annular wedge) path from angle `a0` to `a1`; `R` outer, `ri`
 *  inner radius (`ri = 0` → a solid pie wedge). A near-full sweep (a single slice
 *  at ~100%) is drawn as a closed ring via two arcs, since one SVG arc can't span a
 *  full circle. */
export function donutSector(
  cx: number,
  cy: number,
  R: number,
  ri: number,
  a0: number,
  a1: number,
): string {
  const TAU = 2 * Math.PI;
  const full = a1 - a0 >= TAU - 1e-6;
  if (full) {
    // Two 180° arcs for the outer ring, reversed for the inner cutout.
    const [ox, oy] = polar(cx, cy, R, 0);
    const [obx, oby] = polar(cx, cy, R, Math.PI);
    const [ix, iy] = polar(cx, cy, ri, 0);
    const [ibx, iby] = polar(cx, cy, ri, Math.PI);
    let d =
      `M${ox},${oy} A${R},${R} 0 1 1 ${obx},${oby} A${R},${R} 0 1 1 ${ox},${oy} Z`;
    if (ri > 0) {
      d += ` M${ix},${iy} A${ri},${ri} 0 1 0 ${ibx},${iby} A${ri},${ri} 0 1 0 ${ix},${iy} Z`;
    }
    return d;
  }
  const large = a1 - a0 > Math.PI ? 1 : 0;
  const [x0o, y0o] = polar(cx, cy, R, a0);
  const [x1o, y1o] = polar(cx, cy, R, a1);
  if (ri <= 0) {
    return `M${cx},${cy} L${x0o},${y0o} A${R},${R} 0 ${large} 1 ${x1o},${y1o} Z`;
  }
  const [x0i, y0i] = polar(cx, cy, ri, a0);
  const [x1i, y1i] = polar(cx, cy, ri, a1);
  return (
    `M${x0o},${y0o} A${R},${R} 0 ${large} 1 ${x1o},${y1o} ` +
    `L${x1i},${y1i} A${ri},${ri} 0 ${large} 0 ${x0i},${y0i} Z`
  );
}

/** A rounded-TOP, square-BOTTOM bar path (rounded data-end at the tip, anchored to
 *  the baseline — the dataviz bar mark spec). `y0` is the baseline, `y1` the tip. */
export function barPath(x: number, w: number, y0: number, y1: number, r = 4): string {
  const up = y1 <= y0; // normal (positive) bar grows upward
  const rr = Math.min(r, w / 2, Math.abs(y0 - y1));
  if (up) {
    return (
      `M${x},${y0} L${x},${y1 + rr} Q${x},${y1} ${x + rr},${y1} ` +
      `L${x + w - rr},${y1} Q${x + w},${y1} ${x + w},${y1 + rr} L${x + w},${y0} Z`
    );
  }
  // negative bar: rounded end at the bottom
  return (
    `M${x},${y0} L${x},${y1 - rr} Q${x},${y1} ${x + rr},${y1} ` +
    `L${x + w - rr},${y1} Q${x + w},${y1} ${x + w},${y1 - rr} L${x + w},${y0} Z`
  );
}
