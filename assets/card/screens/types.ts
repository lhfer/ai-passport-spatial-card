import type { ThemeLayout } from './layout.ts';
import type { FontSet, TextMeasurer } from './svg-kit.ts';

/** Inputs every theme generator receives (kept free of Node APIs so the generators are pure). */
export interface ThemeContext {
  profile: {
    name: string;
    handle: string;
    location: string;
    tags: string[];
  };
  /** `data:image/png;base64,...` of the avatar (square). */
  avatarHref: string;
  layout: ThemeLayout;
  fonts: FontSet;
  /** Text width measurer (resvg-backed in the pipeline, heuristic in tests). */
  measure: TextMeasurer;
}

/** Shared SVG prologue/epilogue. */
export const SVG_NS = 'xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"';
