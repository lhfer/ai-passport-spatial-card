import fs from 'node:fs';
import path from 'node:path';
import { describe, expect, it } from 'vitest';
import { estimateMeasurer, FRAME, LAYOUTS, manifestRegions, pixelRegions, renderThemeSvg, THEME_IDS } from '../../assets/card/screens/index.ts';
import { loadCard, REPO_ROOT } from '../src/config.ts';
import { buildManifest, stringifyCompact } from '../tools/screens/catalog.ts';
import { resolveFonts } from '../tools/screens/fonts.ts';
import { emitLvglImageC, symbolForTheme } from '../tools/screens/lvgl.ts';
import {
  applyCornerMask,
  createRaster,
  fillStrip,
  grayThumbnail,
  hexToRgb,
  inkFraction,
  insideRoundedRect,
  isStripFlat,
  luminanceStats,
  ncc,
  packRgb565,
  rgb565Bytes,
  rgb565ToRaster,
  toRgb565,
  unpackRgb565,
} from '../tools/screens/raster.ts';
import { makeMeasurer, renderTheme } from '../tools/render-screens.ts';

describe('RGB565 conversion', () => {
  it('packs and unpacks primaries and white exactly', () => {
    expect(packRgb565(255, 255, 255)).toBe(0xffff);
    expect(packRgb565(255, 0, 0)).toBe(0xf800);
    expect(packRgb565(0, 255, 0)).toBe(0x07e0);
    expect(packRgb565(0, 0, 255)).toBe(0x001f);
    expect(unpackRgb565(0xffff)).toEqual([255, 255, 255]);
    expect(unpackRgb565(0x0000)).toEqual([0, 0, 0]);
  });

  it('writes little-endian by default and big-endian with swapBytes', () => {
    const v = new Uint16Array([0x1234, 0xabcd]);
    expect(Array.from(rgb565Bytes(v))).toEqual([0x34, 0x12, 0xcd, 0xab]);
    expect(Array.from(rgb565Bytes(v, true))).toEqual([0x12, 0x34, 0xab, 0xcd]);
  });

  it('keeps the strip exact even with dithering', () => {
    const img = createRaster(40, 20, [200, 100, 50]);
    const strip = hexToRgb('#081020');
    fillStrip(img, 5, strip);
    const q = toRgb565(img, { dither: true, stripRows: 5, stripColor: strip });
    const back = rgb565ToRaster(q, 40, 20);
    // the LCD shows the 565 value of the strip colour (blue 32 → 5-bit 4 → 33 when expanded)
    const strip565 = unpackRgb565(packRgb565(strip[0], strip[1], strip[2]));
    expect(isStripFlat(back, 5, strip565)).toBe(true);
    for (let p = 40 * 15; p < 40 * 20; p++) expect(q[p]).toBe(packRgb565(strip[0], strip[1], strip[2]));
    // dithered area: quantisation error spreads → some neighbouring values differ, all near the source
    let differing = 0;
    for (let p = 0; p < 40 * 15; p++) if (q[p] !== q[0]) differing++;
    expect(differing).toBeGreaterThan(0);
  });
});

describe('rounded-corner mask', () => {
  it('blackens only pixels outside the rounded rectangle', () => {
    expect(insideRoundedRect(0, 0, 240, 320, 30)).toBe(false);
    expect(insideRoundedRect(30, 30, 240, 320, 30)).toBe(true);
    expect(insideRoundedRect(120, 160, 240, 320, 30)).toBe(true);
    expect(insideRoundedRect(239, 319, 240, 320, 30)).toBe(false);
    expect(insideRoundedRect(120, 0, 240, 320, 30)).toBe(true);
    const img = createRaster(240, 320, [255, 255, 255]);
    applyCornerMask(img, 30);
    expect(Array.from(img.data.subarray(0, 3))).toEqual([0, 0, 0]);
    const centre = (160 * 240 + 120) * 4;
    expect(Array.from(img.data.subarray(centre, centre + 3))).toEqual([255, 255, 255]);
    const edgeMid = (160 * 240 + 0) * 4;
    expect(Array.from(img.data.subarray(edgeMid, edgeMid + 3))).toEqual([255, 255, 255]);
  });
});

describe('metrics', () => {
  it('ncc is 1 for identical, -1 for inverted, ~0 for unrelated', () => {
    const a = Float64Array.from({ length: 64 }, (_, i) => (i * 37) % 11);
    const b = a.map((v) => 20 - v);
    expect(ncc(a, a)).toBeCloseTo(1, 6);
    expect(ncc(a, b)).toBeCloseTo(-1, 6);
  });

  it('flat image has flatFraction 1 and zero stddev', () => {
    const img = createRaster(64, 64, [100, 100, 100]);
    const s = luminanceStats(img);
    expect(s.flatFraction).toBe(1);
    expect(s.stddev).toBeCloseTo(0, 6);
    expect(grayThumbnail(img, 4).every((v) => Math.abs(v - 100) < 0.01)).toBe(true);
  });
});

describe('LVGL emitter', () => {
  it('matches the placeholder file layout exactly', () => {
    const px = new Uint16Array(4 * 2).fill(0x1234);
    const c = emitLvglImageC({ symbol: 'theme_test', width: 4, height: 2, pixels: px });
    const lines = c.split('\n');
    expect(lines[1]).toBe('#include "lvgl.h"');
    expect(lines[3]).toBe('static const uint8_t theme_test_map[] __attribute__((aligned(4))) = {');
    expect(lines[4]).toBe('  0x34,0x12,0x34,0x12,0x34,0x12,0x34,0x12,0x34,0x12,0x34,0x12,0x34,0x12,0x34,0x12,');
    expect(c).toContain('const lv_image_dsc_t theme_test = {');
    expect(c).toContain('.header.magic = LV_IMAGE_HEADER_MAGIC,');
    expect(c).toContain('.header.cf = LV_COLOR_FORMAT_RGB565,');
    expect(c).toContain('.header.w = 4,');
    expect(c).toContain('.header.h = 2,');
    expect(c).toContain('.header.stride = 8,');
    expect(c).toContain('.data_size = 16,');
    expect(c).toContain('.data = theme_test_map,');
    expect(symbolForTheme('neon-city')).toBe('theme_neon_city');
  });

  it('emits 32 bytes per line for a full 240x320 frame', () => {
    const px = new Uint16Array(240 * 320);
    const c = emitLvglImageC({ symbol: 'theme_base', width: 240, height: 320, pixels: px });
    const dataLines = c.split('\n').filter((l) => l.startsWith('  0x'));
    expect(dataLines.length).toBe((240 * 320 * 2) / 32);
    expect(c).toContain('.data_size = 153600,');
    expect(c).toContain('.header.stride = 480,');
  });

  it('honours --swap-bytes', () => {
    const c = emitLvglImageC({ symbol: 't', width: 1, height: 1, pixels: new Uint16Array([0xf800]), swapBytes: true });
    expect(c).toContain('  0xf8,0x00,');
    expect(c).toContain('big-endian');
  });
});

describe('layout → manifest regions', () => {
  it('every region is normalised inside the frame and followers is the bottom strip', () => {
    for (const id of THEME_IDS) {
      const regions = manifestRegions(LAYOUTS[id]);
      for (const [key, r] of Object.entries(regions)) {
        if ('circle' in r) {
          const [u, v, rad] = r.circle;
          expect(u - rad, `${id}.${key}`).toBeGreaterThanOrEqual(0);
          expect(u + rad, `${id}.${key}`).toBeLessThanOrEqual(1);
          expect(v, `${id}.${key}`).toBeGreaterThan(0);
          expect(v + (rad * FRAME.width) / FRAME.height, `${id}.${key} above strip`).toBeLessThanOrEqual(1 - FRAME.dynamicStripPx / FRAME.height);
        } else {
          const [u0, v0, u1, v1] = r.rect;
          expect(u0).toBeGreaterThanOrEqual(0);
          expect(v0).toBeGreaterThanOrEqual(0);
          expect(u1).toBeLessThanOrEqual(1);
          expect(v1).toBeLessThanOrEqual(1);
          expect(u1).toBeGreaterThan(u0);
          expect(v1).toBeGreaterThan(v0);
          if (key !== 'followers') expect(v1, `${id}.${key} must stay above the dynamic strip`).toBeLessThanOrEqual(1 - FRAME.dynamicStripPx / FRAME.height + 1e-9);
        }
      }
      expect(regions['followers']).toEqual({ rect: [0, 0.85, 1, 1] });
      expect(pixelRegions(LAYOUTS[id])['followers']).toEqual({ rect: [0, 272, 240, 320] });
    }
  });

  it('the three themes place the avatar differently (Xcode similar-image guard)', () => {
    const c = THEME_IDS.map((id) => LAYOUTS[id].avatar);
    for (let i = 0; i < c.length; i++)
      for (let j = i + 1; j < c.length; j++) {
        const dPx = Math.hypot((c[i]!.cx - c[j]!.cx) * FRAME.width, (c[i]!.cy - c[j]!.cy) * FRAME.height);
        expect(dPx, `${THEME_IDS[i]} vs ${THEME_IDS[j]} centre distance px`).toBeGreaterThan(40);
      }
  });

  it('buildManifest reflects card.json geometry and the layout regions', () => {
    const card = loadCard();
    const m = buildManifest(card, '2026-01-01T00:00:00.000Z');
    expect(m.physicalWidthMeters).toBeCloseTo(card.device.activeAreaMm[0] / 1000, 9);
    expect(String(m.physicalWidthMeters)).toBe('0.03672'); // no float noise in the JSON
    expect(m.physicalHeightMeters).toBeCloseTo(card.device.activeAreaMm[1] / 1000, 9);
    expect(m.pixelSize).toEqual([240, 320]);
    expect(m.dynamicRegion).toEqual({ rect: [0, 272, 240, 48] });
    expect(m.themes.map((t) => t.id)).toEqual(card.themes.map((t) => t.id));
    for (const t of m.themes) {
      expect(t.regions).toEqual(manifestRegions(LAYOUTS[t.id]));
      expect(t.referenceImage).toBe(`passport-${t.id}`);
      expect(t.bitmap).toBe(`Passport${t.id === 'base' ? 'Base' : t.id === 'neon-city' ? 'NeonCity' : 'DataNebula'}`);
    }
    const json = stringifyCompact(m);
    expect(json).toContain('"circle": [0.5, 0.2688, 0.2]');
    expect(JSON.parse(json)).toEqual(m);
  });

  it('the checked-in manifest matches the layout module (regenerate with pnpm screens if this fails)', () => {
    const file = path.join(REPO_ROOT, 'visionos', 'SpatialCard', 'Resources', 'passport-manifest.json');
    if (!fs.existsSync(file)) return;
    const m = JSON.parse(fs.readFileSync(file, 'utf8')) as ReturnType<typeof buildManifest>;
    if (m.generatedBy !== 'hub/tools/render-screens.ts') return; // seed manifest not yet regenerated
    for (const t of m.themes) expect(t.regions, t.id).toEqual(manifestRegions(LAYOUTS[t.id]));
  });
});

describe('theme SVG generators', () => {
  const card = loadCard();
  const ctx = {
    profile: { name: card.profile.name, handle: card.profile.handle, location: card.profile.location, tags: card.profile.tags },
    avatarHref: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==',
    fonts: { cjk: 'PingFang SC', latin: 'Helvetica Neue', display: 'DIN Condensed', mono: 'Menlo' },
    measure: estimateMeasurer,
  };

  it('are deterministic and embed the profile text', () => {
    for (const id of THEME_IDS) {
      const a = renderThemeSvg(id, ctx);
      const b = renderThemeSvg(id, ctx);
      expect(a).toBe(b);
      expect(a).toContain(card.profile.handle);
      // mixed-script strings are emitted as one <text> per script run, so check each run
      for (const tag of card.profile.tags) for (const part of tag.split(' ')) expect(a, `${id} tag ${tag}`).toContain(part);
      for (const part of card.profile.name.split(' ')) expect(a).toContain(part);
      expect(a.startsWith('<svg')).toBe(true);
      expect(a).not.toContain('NaN');
      expect(a).not.toContain('undefined');
    }
  });
});

const fontsAvailable = resolveFonts().fontFiles.length > 0;

describe.skipIf(!fontsAvailable)('full render (resvg)', () => {
  const card = loadCard();
  const fontInfo = resolveFonts();
  const avatarHref = `data:image/png;base64,${fs.readFileSync(path.join(REPO_ROOT, 'assets', 'card', 'avatar.png')).toString('base64')}`;
  const ctx = {
    profile: { name: card.profile.name, handle: card.profile.handle, location: card.profile.location, tags: card.profile.tags },
    avatarHref,
    fonts: fontInfo.fonts,
    measure: makeMeasurer(fontInfo.fontFiles),
  };

  it('renders base with ink in every region, a flat strip and black corners at both scales', () => {
    const r = renderTheme('base', ctx, fontInfo.fontFiles, true);
    const layout = LAYOUTS.base;
    const strip = hexToRgb(layout.stripColor);
    expect(r.reference.width).toBe(480);
    expect(r.reference.height).toBe(640);
    expect(r.lcdPreview.width).toBe(240);
    expect(isStripFlat(r.reference, 96, strip)).toBe(true);
    expect(isStripFlat(r.lcdPreview, 48, unpackRgb565(packRgb565(strip[0], strip[1], strip[2])))).toBe(true);
    for (let p = 240 * 272 + 30; p < 240 * 320; p += 37) if (r.lcd565[p] !== 0) expect(r.lcd565[p]).toBe(packRgb565(strip[0], strip[1], strip[2]));
    expect(Array.from(r.reference.data.subarray(0, 3))).toEqual([0, 0, 0]);
    expect(r.lcd565[0]).toBe(0);
    const regions = pixelRegions(layout);
    for (const [key, reg] of Object.entries(regions)) {
      if (key === 'followers') continue;
      const rect = 'rect' in reg ? { x: reg.rect[0], y: reg.rect[1], w: reg.rect[2] - reg.rect[0], h: reg.rect[3] - reg.rect[1] } : { x: reg.circle[0] - reg.circle[2], y: reg.circle[1] - reg.circle[2], w: reg.circle[2] * 2, h: reg.circle[2] * 2 };
      // text is drawn on a busy background, so compare against a colour that is never the text colour
      const ink = inkFraction(r.lcdPreview, rect, [255, 255, 255], 60);
      expect(ink, `${key} region should contain non-white background + ink`).toBeGreaterThan(0.05);
    }
    // 1x is a real 565 image: every pixel round-trips through pack/unpack
    for (let p = 0; p < 200; p++) {
      const i = p * 97 * 4;
      const [rr, gg, bb] = unpackRgb565(r.lcd565[p * 97]!);
      expect([r.lcdPreview.data[i], r.lcdPreview.data[i + 1], r.lcdPreview.data[i + 2]]).toEqual([rr, gg, bb]);
    }
    const stats = luminanceStats(r.reference, { excludeStripRows: 96, cornerRadius: 60 });
    expect(stats.stddev).toBeGreaterThan(40);
    expect(stats.max - stats.min).toBeGreaterThan(200);
  });
});
