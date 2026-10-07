/**
 * Entry point for the screen designs: `renderThemeSvg(id, ctx)` returns the 240×320 SVG for a theme.
 * The layout constants (`layout.ts`) drive both the drawing and the manifest regions.
 */
import { LAYOUTS, THEME_IDS, type ThemeId } from './layout.ts';
import { baseSvg } from './themes/base.ts';
import { dataNebulaSvg } from './themes/data-nebula.ts';
import { neonCitySvg } from './themes/neon-city.ts';
import type { ThemeContext } from './types.ts';

export type { ThemeContext } from './types.ts';
export * from './layout.ts';
export { hashSeed, rng, snap565, luma, estimateMeasurer, estimateWidth } from './svg-kit.ts';
export type { FontSet, TextMeasurer, MeasureOptions } from './svg-kit.ts';

const GENERATORS: Record<ThemeId, (ctx: ThemeContext) => string> = {
  base: baseSvg,
  'neon-city': neonCitySvg,
  'data-nebula': dataNebulaSvg,
};

export function renderThemeSvg(id: ThemeId, ctx: Omit<ThemeContext, 'layout'>): string {
  const layout = LAYOUTS[id];
  return GENERATORS[id]({ ...ctx, layout });
}

export { THEME_IDS };
