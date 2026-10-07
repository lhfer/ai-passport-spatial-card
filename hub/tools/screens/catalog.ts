/**
 * Output locations and JSON writers for the visionOS asset catalog and the passport manifest.
 */
import fs from 'node:fs';
import path from 'node:path';
import { PNG } from 'pngjs';
import { CIRCLE_RADIUS_UNIT, DYNAMIC_REGION_PX, FRAME, LAYOUTS, manifestRegions, pixelRegions, type ThemeId } from '../../../assets/card/screens/index.ts';
import type { Card } from '../../src/config.ts';
import type { Raster } from './raster.ts';

export function pascalCase(id: string): string {
  return id
    .split(/[^a-z0-9]+/i)
    .filter(Boolean)
    .map((s) => s.charAt(0).toUpperCase() + s.slice(1))
    .join('');
}

export interface ThemePaths {
  lvglC: string;
  arReferenceDir: string;
  arReferencePng: string;
  arReferenceContents: string;
  imagesetDir: string;
  imagesetPng: string;
  imagesetContents: string;
  preview1x: string;
  preview2x: string;
}

export function themePaths(repoRoot: string, id: ThemeId): ThemePaths {
  const xcassets = path.join(repoRoot, 'visionos', 'SpatialCard', 'Resources', 'Assets.xcassets');
  const arReferenceDir = path.join(xcassets, 'CardReference.arresourcegroup', `passport-${id}.arreferenceimage`);
  const imagesetDir = path.join(xcassets, `Passport${pascalCase(id)}.imageset`);
  const previewDir = path.join(repoRoot, 'assets', 'card', 'screens', 'preview');
  return {
    lvglC: path.join(repoRoot, 'firmware', 'ai-passport-card', 'assets', 'images', `theme_${id.replace(/-/g, '_')}.c`),
    arReferenceDir,
    arReferencePng: path.join(arReferenceDir, `passport-${id}-ref.png`),
    arReferenceContents: path.join(arReferenceDir, 'Contents.json'),
    imagesetDir,
    imagesetPng: path.join(imagesetDir, `passport-${id}.png`),
    imagesetContents: path.join(imagesetDir, 'Contents.json'),
    preview1x: path.join(previewDir, `${id}@1x.png`),
    preview2x: path.join(previewDir, `${id}@2x.png`),
  };
}

export function manifestPath(repoRoot: string): string {
  return path.join(repoRoot, 'visionos', 'SpatialCard', 'Resources', 'passport-manifest.json');
}

export function cardCopyPath(repoRoot: string): string {
  return path.join(repoRoot, 'visionos', 'SpatialCard', 'Resources', 'card.json');
}

/** Encodes a raster as an RGB (no alpha) PNG buffer. */
export function encodePng(img: Raster): Buffer {
  const png = new PNG({ width: img.width, height: img.height, colorType: 2 });
  png.data = Buffer.from(img.data.buffer, img.data.byteOffset, img.data.byteLength);
  return PNG.sync.write(png, { colorType: 2 });
}

export function decodePng(buf: Buffer): Raster {
  const png = PNG.sync.read(buf);
  return { width: png.width, height: png.height, data: new Uint8Array(png.data.buffer, png.data.byteOffset, png.data.byteLength) };
}

export function writeFileEnsuringDir(file: string, data: string | Uint8Array): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, data);
}

export function arReferenceContents(id: ThemeId, physicalWidthMeters: number): string {
  return `${JSON.stringify(
    {
      images: [{ filename: `passport-${id}-ref.png`, idiom: 'universal' }],
      info: { author: 'xcode', version: 1 },
      properties: { width: metres(physicalWidthMeters * 1000) },
    },
    null,
    2,
  )}\n`;
}

export function imagesetContents(id: ThemeId): string {
  return `${JSON.stringify(
    {
      images: [{ filename: `passport-${id}.png`, idiom: 'universal', scale: '2x' }],
      info: { author: 'xcode', version: 1 },
    },
    null,
    2,
  )}\n`;
}

export interface ManifestTheme {
  id: ThemeId;
  label: string;
  world: string | null;
  referenceImage: string;
  bitmap: string;
  stripColor: string;
  regions: ReturnType<typeof manifestRegions>;
  regionsPx: ReturnType<typeof pixelRegions>;
}

export interface Manifest {
  schema: 1;
  generatedBy: string;
  generatedAt: string;
  physicalWidthMeters: number;
  physicalHeightMeters: number;
  pixelSize: [number, number];
  referenceScale: number;
  cornerRadiusPx: number;
  dynamicRegion: { rect: [number, number, number, number] };
  coordinateSpace: { u: string; vTop: string; circleRadius: string };
  themes: ManifestTheme[];
}

/** Millimetres → metres rounded to 1 µm so JSON stays free of float noise (36.72 mm → 0.03672). */
export function metres(mm: number): number {
  return Number((mm / 1000).toFixed(6));
}

/**
 * JSON with 2-space indentation but arrays of primitives kept on one line
 * (`"circle": [0.5, 0.27, 0.2]`), matching the hand-written seed manifest.
 */
export function stringifyCompact(value: unknown, indent = 2, level = 0): string {
  const pad = ' '.repeat(indent * level);
  const padIn = ' '.repeat(indent * (level + 1));
  if (Array.isArray(value)) {
    if (value.every((v) => v === null || typeof v !== 'object')) return `[${value.map((v) => JSON.stringify(v)).join(', ')}]`;
    return `[\n${value.map((v) => padIn + stringifyCompact(v, indent, level + 1)).join(',\n')}\n${pad}]`;
  }
  if (value && typeof value === 'object') {
    const entries = Object.entries(value as Record<string, unknown>).filter(([, v]) => v !== undefined);
    if (!entries.length) return '{}';
    return `{\n${entries.map(([k, v]) => `${padIn}${JSON.stringify(k)}: ${stringifyCompact(v, indent, level + 1)}`).join(',\n')}\n${pad}}`;
  }
  return JSON.stringify(value);
}

export function buildManifest(card: Card, generatedAt: string, referenceScale = 2): Manifest {
  const [wMm, hMm] = card.device.activeAreaMm;
  const themes: ManifestTheme[] = card.themes.map((t) => {
    const layout = LAYOUTS[t.id];
    return {
      id: t.id,
      label: t.label,
      world: t.world,
      referenceImage: `passport-${t.id}`,
      bitmap: `Passport${pascalCase(t.id)}`,
      stripColor: layout.stripColor,
      regions: manifestRegions(layout),
      regionsPx: pixelRegions(layout),
    };
  });
  return {
    schema: 1,
    generatedBy: 'hub/tools/render-screens.ts',
    generatedAt,
    physicalWidthMeters: metres(wMm),
    physicalHeightMeters: metres(hMm),
    pixelSize: [card.device.screenPx[0], card.device.screenPx[1]],
    referenceScale,
    cornerRadiusPx: card.device.cornerRadiusPx,
    dynamicRegion: { rect: DYNAMIC_REGION_PX },
    coordinateSpace: {
      u: `x / ${FRAME.width} (0 = left)`,
      vTop: `y / ${FRAME.height} (0 = top)`,
      circleRadius: `fraction of ${CIRCLE_RADIUS_UNIT} (r * ${FRAME.width} = px)`,
    },
    themes,
  };
}
