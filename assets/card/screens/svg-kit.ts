/**
 * Small, dependency-free helpers shared by the theme generators: deterministic PRNG, colour maths,
 * a Bowyer–Watson Delaunay triangulation (crystal facets), XML escaping and mixed CJK/Latin text runs.
 * Everything here is pure so the screens are reproducible byte-for-byte between runs.
 */
import type { TextSlot, RectRegion } from './layout.ts';
import { px } from './layout.ts';

// ------------------------------------------------------------------------------------ PRNG

/** FNV-1a 32-bit hash of a string → PRNG seed. */
export function hashSeed(text: string): number {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

export interface Rng {
  /** Uniform float in [0, 1). */
  next(): number;
  /** Uniform float in [min, max). */
  range(min: number, max: number): number;
  /** Uniform integer in [min, max]. */
  int(min: number, max: number): number;
  pick<T>(items: readonly T[]): T;
  chance(p: number): boolean;
}

/** mulberry32 — tiny, fast, deterministic. */
export function rng(seed: number | string): Rng {
  let a = (typeof seed === 'string' ? hashSeed(seed) : seed) >>> 0;
  const next = (): number => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
  return {
    next,
    range: (min, max) => min + (max - min) * next(),
    int: (min, max) => min + Math.floor(next() * (max - min + 1)),
    pick: (items) => items[Math.floor(next() * items.length)] as (typeof items)[number],
    chance: (p) => next() < p,
  };
}

// ---------------------------------------------------------------------------------- colours

export type Rgb = [number, number, number];

export function hexToRgb(hex: string): Rgb {
  const h = hex.replace('#', '');
  const full = h.length === 3 ? h.split('').map((c) => c + c).join('') : h;
  const n = parseInt(full, 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

export function rgbToHex([r, g, b]: Rgb): string {
  const c = (v: number) => Math.max(0, Math.min(255, Math.round(v))).toString(16).padStart(2, '0');
  return `#${c(r)}${c(g)}${c(b)}`;
}

/** Linear mix of two hex colours, t in [0,1]. */
export function mix(a: string, b: string, t: number): string {
  const [ar, ag, ab] = hexToRgb(a);
  const [br, bg, bb] = hexToRgb(b);
  return rgbToHex([ar + (br - ar) * t, ag + (bg - ag) * t, ab + (bb - ab) * t]);
}

/** Scales a colour towards white (t>0) or black (t<0). */
export function shade(hex: string, t: number): string {
  return t >= 0 ? mix(hex, '#ffffff', t) : mix(hex, '#000000', -t);
}

/** Rec.601 luma in 0..255. */
export function luma(hex: string): number {
  const [r, g, b] = hexToRgb(hex);
  return 0.299 * r + 0.587 * g + 0.114 * b;
}

/** HSL (h 0-360, s/l 0-1) → hex. */
export function hsl(h: number, s: number, l: number): string {
  const k = (n: number) => (n + h / 30) % 12;
  const a = s * Math.min(l, 1 - l);
  const f = (n: number) => l - a * Math.max(-1, Math.min(k(n) - 3, Math.min(9 - k(n), 1)));
  return rgbToHex([f(0) * 255, f(8) * 255, f(4) * 255]);
}

/** Snaps a colour onto the RGB565 grid so it survives quantisation unchanged (flat strip colours). */
export function snap565(hex: string): string {
  const [r, g, b] = hexToRgb(hex);
  return rgbToHex([r & 0xf8, g & 0xfc, b & 0xf8]);
}

// ------------------------------------------------------------------------------------- XML

export function esc(text: string): string {
  return text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

export const f = (n: number): string => (Math.round(n * 100) / 100).toString();

// ------------------------------------------------------------------------------ typography

export interface FontSet {
  /** CJK family chain, e.g. "PingFang SC, Hiragino Sans GB". */
  cjk: string;
  /** Latin text family (handles, tags). */
  latin: string;
  /** Display/condensed family for headline Latin runs and neon signs. */
  display: string;
  mono: string;
}

const CJK_RE = /[⺀-⿟　-ヿ㐀-䶿一-鿿豈-﫿＀-￯]/;

export interface MeasureOptions {
  family: string;
  size: number;
  weight: number;
}

/** Returns the advance width (px) of `text` set in the given font; injected by the renderer (resvg) or estimated in tests. */
export type TextMeasurer = (text: string, opts: MeasureOptions) => number;

/** Rough advance width estimate in em (CJK ≈ 1em, Latin ≈ 0.56em, space 0.3em). */
export function estimateWidth(text: string, fontSize: number, latinEm = 0.56): number {
  let w = 0;
  for (const ch of text) {
    if (ch === ' ') w += 0.3;
    else if (CJK_RE.test(ch)) w += 1.0;
    else if (/[A-Z]/.test(ch)) w += latinEm + 0.08;
    else if (/[il.,'!|]/.test(ch)) w += 0.3;
    else w += latinEm;
  }
  return w * fontSize;
}

/** Fallback measurer (no font access): the heuristic above, condensed families slightly narrower. */
export const estimateMeasurer: TextMeasurer = (text, { family, size }) => estimateWidth(text, size, /condensed/i.test(family) ? 0.42 : 0.56);

export interface Run {
  text: string;
  family: string;
  size: number;
  weight: number;
  /** Offset from the line start. */
  x: number;
  width: number;
}

export interface RunLine {
  runs: Run[];
  width: number;
}

/**
 * Splits mixed text into script runs (CJK → `fonts.cjk`, everything else → `latinFamily`) and lays
 * them out on one line using the measurer. resvg resolves a single font per `<text>` element, so
 * each run is later emitted as its own `<text>`; spaces become fixed 0.28 em gaps.
 */
export function layoutRuns(text: string, fonts: FontSet, size: number, weight: number, measure: TextMeasurer, latinFamily: string = fonts.latin, latinScale = 1): RunLine {
  const segs: { cjk: boolean; text: string }[] = [];
  for (const ch of text) {
    const cjk = CJK_RE.test(ch);
    const last = segs[segs.length - 1];
    if (last && (last.cjk === cjk || ch === ' ')) last.text += ch;
    else segs.push({ cjk, text: ch });
  }
  const gap = 0.28 * size;
  let x = 0;
  const runs: Run[] = [];
  for (const seg of segs) {
    const leading = seg.text.length - seg.text.trimStart().length;
    const trailing = seg.text.length - seg.text.trimEnd().length;
    const core = seg.text.trim();
    x += leading * gap;
    if (core) {
      const family = seg.cjk ? fonts.cjk : latinFamily;
      const fs = seg.cjk ? size : size * latinScale;
      const width = measure(core, { family, size: fs, weight });
      runs.push({ text: core, family, size: fs, weight, x, width });
      x += width;
    }
    x += trailing * gap;
  }
  return { runs, width: x };
}

/** One `<text>` per run, left edge at `x0`, common baseline. `attrs` are appended to every element. */
export function runsMarkup(line: RunLine, x0: number, baseline: number, attrs: string): string {
  return line.runs
    .map((r) => `<text x="${f(x0 + r.x)}" y="${f(baseline)}" font-family="${esc(r.family)}" font-size="${f(r.size)}" font-weight="${r.weight}" ${attrs}>${esc(r.text)}</text>`)
    .join('');
}

/** Baseline y for text visually centred in a slot (CJK + Latin mixed). */
export function slotBaseline(slot: TextSlot): number {
  const r = px.rect(slot);
  return r.y + r.h / 2 + slot.fontSize * 0.36;
}

/** Left edge x for a laid-out line inside a slot, honouring the slot's alignment. */
export function slotLineStart(slot: TextSlot, width: number): number {
  const r = px.rect(slot);
  return slot.align === 'start' ? r.x : slot.align === 'end' ? r.x + r.w - width : r.x + (r.w - width) / 2;
}

export interface TextStyle {
  fill: string;
  shadow?: string;
  shadowOpacity?: number;
  glow?: string;
  glowFilterId?: string;
  latinFamily?: string;
  latinScale?: number;
  opacity?: number;
}

/** Draws a slot's text: optional glow copy (needs a blur filter id), optional drop shadow copy, then the text. */
export function slotText(slot: TextSlot, text: string, fonts: FontSet, measure: TextMeasurer, style: TextStyle): string {
  const line = layoutRuns(text, fonts, slot.fontSize, slot.weight, measure, style.latinFamily ?? fonts.latin, style.latinScale ?? 1);
  const x0 = slotLineStart(slot, line.width);
  const y = slotBaseline(slot);
  let out = '';
  if (style.glow && style.glowFilterId) out += runsMarkup(line, x0, y, `fill="${style.glow}" filter="url(#${style.glowFilterId})" opacity="0.9"`);
  if (style.shadow) out += runsMarkup(line, x0 + 0.8, y + 1.2, `fill="${style.shadow}" opacity="${style.shadowOpacity ?? 0.7}"`);
  out += runsMarkup(line, x0, y, `fill="${style.fill}"${style.opacity !== undefined ? ` opacity="${style.opacity}"` : ''}`);
  return out;
}

// --------------------------------------------------------------------------------- geometry

export interface Pt {
  x: number;
  y: number;
}
export type Tri = [Pt, Pt, Pt];

/** Bowyer–Watson Delaunay triangulation. Fine for a few hundred points. */
export function delaunay(points: Pt[]): Tri[] {
  if (points.length < 3) return [];
  let minX = Infinity,
    minY = Infinity,
    maxX = -Infinity,
    maxY = -Infinity;
  for (const p of points) {
    minX = Math.min(minX, p.x);
    minY = Math.min(minY, p.y);
    maxX = Math.max(maxX, p.x);
    maxY = Math.max(maxY, p.y);
  }
  const dx = maxX - minX,
    dy = maxY - minY,
    dmax = Math.max(dx, dy) * 20;
  const midx = (minX + maxX) / 2,
    midy = (minY + maxY) / 2;
  const superTri: Tri = [
    { x: midx - dmax, y: midy - dmax },
    { x: midx, y: midy + dmax },
    { x: midx + dmax, y: midy - dmax },
  ];

  interface T {
    v: Tri;
    cx: number;
    cy: number;
    r2: number;
  }
  const circum = (v: Tri): T => {
    const [a, b, c] = v;
    const d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y));
    if (Math.abs(d) < 1e-12) return { v, cx: 0, cy: 0, r2: Infinity };
    const a2 = a.x * a.x + a.y * a.y,
      b2 = b.x * b.x + b.y * b.y,
      c2 = c.x * c.x + c.y * c.y;
    const cx = (a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d;
    const cy = (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d;
    return { v, cx, cy, r2: (a.x - cx) ** 2 + (a.y - cy) ** 2 };
  };

  let tris: T[] = [circum(superTri)];
  for (const p of points) {
    const bad: T[] = [];
    const good: T[] = [];
    for (const t of tris) {
      if ((p.x - t.cx) ** 2 + (p.y - t.cy) ** 2 < t.r2) bad.push(t);
      else good.push(t);
    }
    // Boundary edges of the polygonal hole = edges not shared by two bad triangles.
    const edges: [Pt, Pt][] = [];
    for (const t of bad) {
      for (let i = 0; i < 3; i++) {
        const e: [Pt, Pt] = [t.v[i] as Pt, t.v[(i + 1) % 3] as Pt];
        let shared = false;
        for (const o of bad) {
          if (o === t) continue;
          for (let j = 0; j < 3; j++) {
            const oa = o.v[j] as Pt,
              ob = o.v[(j + 1) % 3] as Pt;
            if ((oa === e[0] && ob === e[1]) || (oa === e[1] && ob === e[0])) shared = true;
          }
        }
        if (!shared) edges.push(e);
      }
    }
    tris = good;
    for (const [a, b] of edges) tris.push(circum([a, b, p]));
  }
  const sv = new Set<Pt>(superTri);
  return tris.filter((t) => !t.v.some((v) => sv.has(v))).map((t) => t.v);
}

/** Jittered-grid point cloud over a rect (spreads points evenly but never periodically). */
export function jitteredPoints(r: Rng, area: { x: number; y: number; w: number; h: number }, cols: number, rows: number, jitter = 0.9): Pt[] {
  const pts: Pt[] = [];
  const cw = area.w / cols,
    ch = area.h / rows;
  for (let j = 0; j < rows; j++) {
    for (let i = 0; i < cols; i++) {
      pts.push({
        x: area.x + (i + 0.5 + r.range(-jitter, jitter) * 0.5) * cw,
        y: area.y + (j + 0.5 + r.range(-jitter, jitter) * 0.5) * ch,
      });
    }
  }
  return pts;
}

export function polygonPath(pts: Pt[]): string {
  return `M${pts.map((p) => `${f(p.x)} ${f(p.y)}`).join('L')}Z`;
}

export function roundedRect(x: number, y: number, w: number, h: number, r: number, attrs: string): string {
  return `<rect x="${f(x)}" y="${f(y)}" width="${f(w)}" height="${f(h)}" rx="${f(r)}" ry="${f(r)}" ${attrs}/>`;
}

/** Map pin glyph (fill) scaled to `size` px tall with its tip at (x, yBottom). */
export function pinGlyph(x: number, yBottom: number, size: number, fill: string): string {
  const s = size / 12;
  return `<path transform="translate(${f(x - 4.5 * s)},${f(yBottom - 12 * s)}) scale(${f(s)})" fill="${fill}" d="M4.5 0C2 0 0 2 0 4.5c0 3.4 4.5 7.5 4.5 7.5S9 7.9 9 4.5C9 2 7 0 4.5 0zm0 6.3a1.8 1.8 0 1 1 0-3.6 1.8 1.8 0 0 1 0 3.6z"/>`;
}

export function rectOf(r: RectRegion) {
  return px.rect(r);
}
