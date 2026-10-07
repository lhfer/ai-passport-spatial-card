/**
 * Shared screen layout for the three AI Passport themes.
 *
 * Every element that the SVG generators draw AND every region that `passport-manifest.json`
 * publishes comes from these constants, so the visionOS app's per-pixel classification (avatar /
 * name / handle / location / tags / followers) matches the drawn screens exactly.
 *
 * Coordinate convention (identical to the seed manifest):
 *   - `u`    = x / 240 (0 = left edge, 1 = right edge)
 *   - `vTop` = y / 320 (0 = top edge, 1 = bottom edge)
 *   - circle radius `r` is a fraction of the WIDTH (r * 240 = pixels), see `CIRCLE_RADIUS_UNIT`
 * The manifest additionally carries the same regions in 1x pixels (`regionsPx`).
 */

export type ThemeId = 'base' | 'neon-city' | 'data-nebula';

/** Logical frame of the LCD in 1x pixels. */
export const FRAME = {
  width: 240,
  height: 320,
  /** BSP blackens everything outside this rounded rectangle when it refreshes the panel. */
  cornerRadiusPx: 30,
  /** Bottom strip the firmware redraws at runtime (follower digits); must be flat in the bitmaps. */
  dynamicStripPx: 48,
} as const;

export const CIRCLE_RADIUS_UNIT = 'width' as const;

export interface CircleRegion {
  /** Centre, normalised u. */
  cx: number;
  /** Centre, normalised vTop. */
  cy: number;
  /** Radius as a fraction of the frame width. */
  r: number;
}

export interface RectRegion {
  u0: number;
  v0: number;
  u1: number;
  v1: number;
}

export type TextAlign = 'start' | 'middle' | 'end';

export interface TextSlot extends RectRegion {
  /** Font size in 1x pixels. */
  fontSize: number;
  align: TextAlign;
  weight: number;
}

export interface TagsSlot extends RectRegion {
  /** Height of one tag pill / label in 1x px. */
  itemHeight: number;
  fontSize: number;
}

export interface ThemeLayout {
  id: ThemeId;
  /** Flat background colour of the dynamic strip (must sit on the RGB565 grid: R,B % 8 == 0, G % 4 == 0). */
  stripColor: string;
  avatar: CircleRegion;
  name: TextSlot;
  handle: TextSlot;
  location?: TextSlot;
  tags: TagsSlot;
  followers: RectRegion;
}

const W = FRAME.width;
const H = FRAME.height;

/** Helper: rect from 1x pixel coordinates. */
function rectPx(x0: number, y0: number, x1: number, y1: number): RectRegion {
  return { u0: x0 / W, v0: y0 / H, u1: x1 / W, v1: y1 / H };
}

function circlePx(cx: number, cy: number, r: number): CircleRegion {
  return { cx: cx / W, cy: cy / H, r: r / W };
}

function textPx(x0: number, y0: number, x1: number, y1: number, fontSize: number, align: TextAlign, weight = 400): TextSlot {
  return { ...rectPx(x0, y0, x1, y1), fontSize, align, weight };
}

/** The follower strip is the same on every theme: the bottom `dynamicStripPx` rows. */
export const FOLLOWERS_REGION: RectRegion = rectPx(0, H - FRAME.dynamicStripPx, W, H);

/** Dynamic region in 1x pixels as [x, y, w, h] (manifest `dynamicRegion.rect`). */
export const DYNAMIC_REGION_PX: [number, number, number, number] = [0, H - FRAME.dynamicStripPx, W, FRAME.dynamicStripPx];

/**
 * base — 名片: large centred avatar over a crystal-facet field; name / handle / location / tags
 * stacked underneath.
 */
export const BASE_LAYOUT: ThemeLayout = {
  id: 'base',
  stripColor: '#081020',
  avatar: circlePx(120, 86, 48),
  name: textPx(14, 150, 226, 178, 24, 'middle', 600),
  handle: textPx(14, 181, 226, 197, 12.5, 'middle', 500),
  location: textPx(14, 199, 226, 213, 11, 'middle', 400),
  tags: { ...rectPx(12, 222, 228, 246), itemHeight: 20, fontSize: 10.5 },
  followers: FOLLOWERS_REGION,
};

/**
 * neon-city — 霓虹雨城: rain-streaked skyline dominates; tags are neon signs at the top; the
 * small avatar sits bottom-left inside a neon frame with name / handle / location to its right.
 */
export const NEON_CITY_LAYOUT: ThemeLayout = {
  id: 'neon-city',
  stripColor: '#100818',
  avatar: circlePx(58, 232, 30),
  name: textPx(96, 208, 232, 232, 20, 'start', 600),
  handle: textPx(96, 236, 232, 252, 11.5, 'start', 500),
  location: textPx(96, 254, 232, 268, 9.5, 'start', 400),
  tags: { ...rectPx(12, 22, 228, 84), itemHeight: 18, fontSize: 11 },
  followers: FOLLOWERS_REGION,
};

/**
 * data-nebula — 数据星云: avatar is an off-centre ringed planet on the right; tags are labelled
 * stars of a constellation top-left; name / handle / location in the lower third.
 */
export const DATA_NEBULA_LAYOUT: ThemeLayout = {
  id: 'data-nebula',
  stripColor: '#080410',
  avatar: circlePx(158, 110, 40),
  name: textPx(14, 196, 226, 224, 23, 'middle', 600),
  handle: textPx(14, 226, 226, 242, 12, 'middle', 500),
  location: textPx(14, 244, 226, 258, 10.5, 'middle', 400),
  tags: { ...rectPx(12, 20, 150, 70), itemHeight: 14, fontSize: 10 },
  followers: FOLLOWERS_REGION,
};

export const LAYOUTS: Record<ThemeId, ThemeLayout> = {
  base: BASE_LAYOUT,
  'neon-city': NEON_CITY_LAYOUT,
  'data-nebula': DATA_NEBULA_LAYOUT,
};

export const THEME_IDS: readonly ThemeId[] = ['base', 'neon-city', 'data-nebula'];

/** Manifest-shaped regions for a layout: `{ avatar: { circle: [u, vTop, r] }, name: { rect: [...] }, ... }`. */
export type ManifestRegion = { circle: [number, number, number] } | { rect: [number, number, number, number] };

export function manifestRegions(layout: ThemeLayout): Record<string, ManifestRegion> {
  const r4 = (n: number) => Math.round(n * 10000) / 10000;
  const rect = (r: RectRegion): ManifestRegion => ({ rect: [r4(r.u0), r4(r.v0), r4(r.u1), r4(r.v1)] });
  const regions: Record<string, ManifestRegion> = {
    avatar: { circle: [r4(layout.avatar.cx), r4(layout.avatar.cy), r4(layout.avatar.r)] },
    name: rect(layout.name),
    handle: rect(layout.handle),
  };
  if (layout.location) regions['location'] = rect(layout.location);
  regions['tags'] = rect(layout.tags);
  regions['followers'] = rect(layout.followers);
  return regions;
}

export type PixelRegion = { circle: [number, number, number] } | { rect: [number, number, number, number] };

/** Same regions in 1x pixel space (unambiguous fallback for consumers). */
export function pixelRegions(layout: ThemeLayout): Record<string, PixelRegion> {
  const rect = (r: RectRegion): PixelRegion => ({
    rect: [Math.round(r.u0 * W), Math.round(r.v0 * H), Math.round(r.u1 * W), Math.round(r.v1 * H)],
  });
  const regions: Record<string, PixelRegion> = {
    avatar: { circle: [Math.round(layout.avatar.cx * W), Math.round(layout.avatar.cy * H), Math.round(layout.avatar.r * W)] },
    name: rect(layout.name),
    handle: rect(layout.handle),
  };
  if (layout.location) regions['location'] = rect(layout.location);
  regions['tags'] = rect(layout.tags);
  regions['followers'] = rect(layout.followers);
  return regions;
}

/** Pixel-space helpers used by the SVG generators (1x logical px). */
export const px = {
  x: (u: number) => u * W,
  y: (v: number) => v * H,
  r: (r: number) => r * W,
  rect: (r: RectRegion) => ({ x: r.u0 * W, y: r.v0 * H, w: (r.u1 - r.u0) * W, h: (r.v1 - r.v0) * H }),
  circle: (c: CircleRegion) => ({ cx: c.cx * W, cy: c.cy * H, r: c.r * W }),
};
