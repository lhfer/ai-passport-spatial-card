/**
 * `pnpm screens` — renders the three AI Passport theme screens from the SVG generators in
 * `assets/card/screens/` and writes every derived artefact:
 *
 *   firmware/ai-passport-card/assets/images/theme_<id>.c           LVGL 9 RGB565 (1x, 240×320)
 *   visionos/.../CardReference.arresourcegroup/passport-<id>.arreferenceimage/{Contents.json, passport-<id>-ref.png}
 *   visionos/.../Passport<Id>.imageset/{Contents.json, passport-<id>.png}   (2x, 480×640)
 *   visionos/SpatialCard/Resources/passport-manifest.json
 *   visionos/SpatialCard/Resources/card.json                        (copy of assets/card/card.json)
 *   assets/card/screens/preview/<id>@1x.png, <id>@2x.png            (review copies)
 *
 * Flags: --swap-bytes (big-endian RGB565 in the C arrays), --no-dither, --only <id>, --dump-svg
 * (writes the SVGs to hub/data/build/), --quiet.
 */
import fs from 'node:fs';
import path from 'node:path';
import { parseArgs } from 'node:util';
import { Resvg } from '@resvg/resvg-js';
import { FRAME, LAYOUTS, THEME_IDS, estimateWidth, renderThemeSvg, type MeasureOptions, type TextMeasurer, type ThemeId } from '../../assets/card/screens/index.ts';
import { avatarPath, loadCard, REPO_ROOT } from '../src/config.ts';
import {
  arReferenceContents,
  buildManifest,
  cardCopyPath,
  decodePng,
  encodePng,
  imagesetContents,
  manifestPath,
  stringifyCompact,
  themePaths,
  writeFileEnsuringDir,
} from './screens/catalog.ts';
import { resolveFonts } from './screens/fonts.ts';
import { emitLvglImageC, symbolForTheme } from './screens/lvgl.ts';
import { applyCornerMask, fillStrip, grayThumbnail, hexToRgb, luminanceStats, ncc, rgb565ToRaster, toRgb565, type Raster } from './screens/raster.ts';

const SIMILARITY_WARN = 0.6;

interface Options {
  swapBytes: boolean;
  dither: boolean;
  only: ThemeId[];
  dumpSvg: boolean;
  quiet: boolean;
  repoRoot: string;
}

function parseOptions(argv: string[]): Options {
  const { values } = parseArgs({
    args: argv,
    options: {
      'swap-bytes': { type: 'boolean', default: false },
      'no-dither': { type: 'boolean', default: false },
      only: { type: 'string', multiple: true },
      'dump-svg': { type: 'boolean', default: false },
      quiet: { type: 'boolean', default: false },
      'repo-root': { type: 'string' },
      help: { type: 'boolean', default: false },
    },
    allowPositionals: false,
  });
  if (values.help) {
    console.log('usage: pnpm screens [--swap-bytes] [--no-dither] [--only <theme>]... [--dump-svg] [--quiet]');
    process.exit(0);
  }
  const only = (values.only ?? []).map((id) => {
    if (!THEME_IDS.includes(id as ThemeId)) throw new Error(`unknown theme "${id}" (expected ${THEME_IDS.join(', ')})`);
    return id as ThemeId;
  });
  return {
    swapBytes: values['swap-bytes'] ?? false,
    dither: !(values['no-dither'] ?? false),
    only,
    dumpSvg: values['dump-svg'] ?? false,
    quiet: values.quiet ?? false,
    repoRoot: values['repo-root'] ? path.resolve(values['repo-root']) : REPO_ROOT,
  };
}

/**
 * Text measurer backed by resvg: lays out the run alone and reads its bounding box. The ink box
 * excludes side bearings, so the left bearing is added back on both sides as an advance estimate.
 */
export function makeMeasurer(fontFiles: string[]): TextMeasurer {
  const cache = new Map<string, number>();
  const esc = (t: string) => t.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;');
  return (text: string, opts: MeasureOptions): number => {
    const key = `${opts.family}|${opts.size}|${opts.weight}|${text}`;
    const hit = cache.get(key);
    if (hit !== undefined) return hit;
    const x0 = 20;
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="4000" height="400"><text x="${x0}" y="200" font-family="${esc(opts.family)}" font-size="${opts.size}" font-weight="${opts.weight}">${esc(text)}</text></svg>`;
    let width: number;
    try {
      const r = new Resvg(svg, { font: { loadSystemFonts: true, fontFiles, defaultFontFamily: 'PingFang SC' }, logLevel: 'off' });
      const box = r.getBBox() ?? r.innerBBox();
      if (box && box.width > 0) {
        const lsb = Math.max(0, box.x - x0);
        width = box.width + lsb * 2;
      } else width = estimateWidth(text, opts.size);
    } catch {
      width = estimateWidth(text, opts.size);
    }
    cache.set(key, width);
    return width;
  };
}

export interface RenderedTheme {
  id: ThemeId;
  svg: string;
  /** 1x RGB565 values (what the LCD shows). */
  lcd565: Uint16Array;
  /** 1x preview raster (565 expanded back to RGB). */
  lcdPreview: Raster;
  /** 2x reference raster (masked, strip flattened). */
  reference: Raster;
}

export function rasterise(svg: string, zoom: number, fontFiles: string[]): Raster {
  const resvg = new Resvg(svg, {
    fitTo: { mode: 'zoom', value: zoom },
    font: { loadSystemFonts: true, fontFiles, defaultFontFamily: 'PingFang SC' },
    logLevel: 'error',
    imageRendering: 0,
    shapeRendering: 2,
    textRendering: 2,
  });
  const out = resvg.render();
  // Go through PNG so we get straight (non-premultiplied) RGBA regardless of resvg internals.
  const img = decodePng(out.asPng());
  if (img.width !== FRAME.width * zoom || img.height !== FRAME.height * zoom) {
    throw new Error(`unexpected raster size ${img.width}x${img.height} for zoom ${zoom}`);
  }
  return img;
}

export function renderTheme(id: ThemeId, ctx: Parameters<typeof renderThemeSvg>[1], fontFiles: string[], dither: boolean): RenderedTheme {
  const layout = LAYOUTS[id];
  const strip = hexToRgb(layout.stripColor);
  const svg = renderThemeSvg(id, ctx);

  // 2x — AR reference: flatten the strip, then mask the corners (the corners sit inside the strip rows).
  const reference = rasterise(svg, 2, fontFiles);
  fillStrip(reference, FRAME.dynamicStripPx * 2, strip);
  applyCornerMask(reference, FRAME.cornerRadiusPx * 2);

  // 1x — LCD bitmap: quantise to RGB565 (dither outside the strip), exact strip colour, then mask.
  const lcd = rasterise(svg, 1, fontFiles);
  fillStrip(lcd, FRAME.dynamicStripPx, strip);
  const lcd565 = toRgb565(lcd, { dither, stripRows: FRAME.dynamicStripPx, stripColor: strip });
  const lcdPreview = applyCornerMask(rgb565ToRaster(lcd565, lcd.width, lcd.height), FRAME.cornerRadiusPx);
  // copy the masked corners back into the 565 data
  for (let p = 0; p < lcd565.length; p++) {
    const i = p * 4;
    if (lcdPreview.data[i] === 0 && lcdPreview.data[i + 1] === 0 && lcdPreview.data[i + 2] === 0) lcd565[p] = 0;
  }
  return { id, svg, lcd565, lcdPreview, reference };
}

function fmt(n: number, digits = 1): string {
  return n.toFixed(digits);
}

export async function main(argv = process.argv.slice(2)): Promise<void> {
  const opts = parseOptions(argv);
  const log = (...args: unknown[]) => {
    if (!opts.quiet) console.log(...args);
  };
  const started = Date.now();
  const cardFile = path.join(opts.repoRoot, 'assets', 'card', 'card.json');
  const card = loadCard(cardFile);
  const avatarFile = avatarPath(card, cardFile);
  const avatarHref = `data:image/png;base64,${fs.readFileSync(avatarFile).toString('base64')}`;
  const fontInfo = resolveFonts();
  for (const n of fontInfo.notes) log(`[fonts] ${n}`);

  const ids = opts.only.length ? opts.only : card.themes.map((t) => t.id);
  const ctx = {
    profile: {
      name: card.profile.name,
      handle: card.profile.handle,
      location: card.profile.location,
      tags: card.profile.tags,
    },
    avatarHref,
    fonts: fontInfo.fonts,
    measure: makeMeasurer(fontInfo.fontFiles),
  };

  const results: RenderedTheme[] = [];
  for (const id of ids) {
    const t0 = Date.now();
    const r = renderTheme(id, ctx, fontInfo.fontFiles, opts.dither);
    results.push(r);
    const p = themePaths(opts.repoRoot, id);
    const refPng = encodePng(r.reference);
    writeFileEnsuringDir(p.arReferencePng, refPng);
    writeFileEnsuringDir(p.arReferenceContents, arReferenceContents(id, card.device.activeAreaMm[0] / 1000));
    writeFileEnsuringDir(p.imagesetPng, refPng);
    writeFileEnsuringDir(p.imagesetContents, imagesetContents(id));
    writeFileEnsuringDir(p.preview2x, refPng);
    writeFileEnsuringDir(p.preview1x, encodePng(r.lcdPreview));
    writeFileEnsuringDir(
      p.lvglC,
      emitLvglImageC({ symbol: symbolForTheme(id), width: FRAME.width, height: FRAME.height, pixels: r.lcd565, swapBytes: opts.swapBytes }),
    );
    if (opts.dumpSvg) writeFileEnsuringDir(path.join(opts.repoRoot, 'hub', 'data', 'build', `${id}.svg`), r.svg);
    log(`[screens] ${id}: rendered in ${Date.now() - t0} ms → ${path.relative(opts.repoRoot, p.lvglC)}, ${path.relative(opts.repoRoot, p.arReferencePng)}, ${path.relative(opts.repoRoot, p.imagesetPng)}`);
  }

  // Manifest + card.json copy (always for all themes so the manifest stays complete).
  const manifest = buildManifest(card, new Date().toISOString());
  writeFileEnsuringDir(manifestPath(opts.repoRoot), `${stringifyCompact(manifest)}\n`);
  fs.copyFileSync(cardFile, cardCopyPath(opts.repoRoot));
  log(`[screens] wrote ${path.relative(opts.repoRoot, manifestPath(opts.repoRoot))} and ${path.relative(opts.repoRoot, cardCopyPath(opts.repoRoot))}`);

  // ---- report ---------------------------------------------------------------------------
  log('');
  log('theme         image   lum min  max   mean  stddev  flat%  dark%  bright%');
  const region1 = { excludeStripRows: FRAME.dynamicStripPx, cornerRadius: FRAME.cornerRadiusPx };
  const region2 = { excludeStripRows: FRAME.dynamicStripPx * 2, cornerRadius: FRAME.cornerRadiusPx * 2 };
  for (const r of results) {
    for (const [label, img, region] of [
      ['lcd@1x', r.lcdPreview, region1],
      ['ref@2x', r.reference, region2],
    ] as const) {
      const s = luminanceStats(img, region);
      log(
        `${r.id.padEnd(13)} ${label.padEnd(7)} ${fmt(s.min, 0).padStart(4)} ${fmt(s.max, 0).padStart(5)} ${fmt(s.mean).padStart(6)} ${fmt(s.stddev).padStart(7)} ${fmt(s.flatFraction * 100).padStart(6)} ${fmt(s.darkFraction * 100).padStart(6)} ${fmt(s.brightFraction * 100).padStart(8)}`,
      );
    }
  }
  log('(content region only: dynamic strip and masked corners excluded; flat = luminance gradient < 3/255)');
  if (results.length > 1) {
    log('');
    log('similarity (NCC of 32×32 grayscale thumbnails of the 2x references; warn > 0.6):');
    const thumbs = results.map((r) => grayThumbnail(r.reference, 32, region2));
    let warned = false;
    for (let i = 0; i < results.length; i++) {
      for (let j = i + 1; j < results.length; j++) {
        const c = ncc(thumbs[i]!, thumbs[j]!);
        const flag = c > SIMILARITY_WARN ? '  <-- WARNING: too similar for ARKit' : '';
        if (c > SIMILARITY_WARN) warned = true;
        log(`  ${results[i]!.id} vs ${results[j]!.id}: ${c.toFixed(3)}${flag}`);
      }
    }
    if (!warned) log('  all pairs below the similarity threshold');
  }
  log('');
  log('manifest regions (u, vTop normalised; circle r = fraction of width):');
  for (const t of manifest.themes) {
    if (!ids.includes(t.id)) continue;
    log(`  ${t.id}: ${JSON.stringify(t.regions)}`);
  }
  log('');
  log(`[screens] byte order: ${opts.swapBytes ? 'big-endian (--swap-bytes)' : 'little-endian RGB565'}; dithering ${opts.dither ? 'on' : 'off'}; done in ${Date.now() - started} ms`);
}

const isMain = process.argv[1] && path.resolve(process.argv[1]) === path.resolve(new URL(import.meta.url).pathname);
if (isMain) {
  main().catch((err) => {
    console.error(err);
    process.exit(1);
  });
}
