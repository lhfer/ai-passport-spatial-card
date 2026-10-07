/**
 * Pure raster helpers for the screen pipeline: rounded-corner mask, flat strip fill, RGB565
 * quantisation (with optional Floyd–Steinberg dithering), previews and tracking-quality metrics.
 * Images are plain RGBA byte buffers so everything is testable without resvg.
 */

export interface Raster {
  width: number;
  height: number;
  /** RGBA, row-major, 4 bytes per pixel. */
  data: Uint8Array;
}

export type Rgb = [number, number, number];

export function createRaster(width: number, height: number, fill: Rgb = [0, 0, 0]): Raster {
  const data = new Uint8Array(width * height * 4);
  for (let i = 0; i < data.length; i += 4) {
    data[i] = fill[0];
    data[i + 1] = fill[1];
    data[i + 2] = fill[2];
    data[i + 3] = 255;
  }
  return { width, height, data };
}

export function cloneRaster(img: Raster): Raster {
  return { width: img.width, height: img.height, data: new Uint8Array(img.data) };
}

export function hexToRgb(hex: string): Rgb {
  const n = parseInt(hex.replace('#', ''), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

/** True when pixel centre (x+0.5, y+0.5) lies inside the rounded rectangle [0,w]×[0,h] with corner radius r. */
export function insideRoundedRect(x: number, y: number, w: number, h: number, r: number): boolean {
  const px = x + 0.5;
  const py = y + 0.5;
  if (px < 0 || py < 0 || px > w || py > h) return false;
  const cx = px < r ? r : px > w - r ? w - r : px;
  const cy = py < r ? r : py > h - r ? h - r : py;
  if (cx === px && cy === py) return true;
  return (px - cx) ** 2 + (py - cy) ** 2 <= r * r;
}

/** Blackens every pixel outside the rounded rectangle, exactly like the device BSP on refresh. */
export function applyCornerMask(img: Raster, radius: number): Raster {
  const { width, height, data } = img;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      if (!insideRoundedRect(x, y, width, height, radius)) {
        const i = (y * width + x) * 4;
        data[i] = 0;
        data[i + 1] = 0;
        data[i + 2] = 0;
        data[i + 3] = 255;
      }
    }
  }
  return img;
}

/** Fills the bottom `rows` rows with a flat colour (the firmware draws the follower digits there). */
export function fillStrip(img: Raster, rows: number, rgb: Rgb): Raster {
  const { width, height, data } = img;
  for (let y = Math.max(0, height - rows); y < height; y++) {
    for (let x = 0; x < width; x++) {
      const i = (y * width + x) * 4;
      data[i] = rgb[0];
      data[i + 1] = rgb[1];
      data[i + 2] = rgb[2];
      data[i + 3] = 255;
    }
  }
  return img;
}

/** Packs an 8-bit RGB triple into RGB565. */
export function packRgb565(r: number, g: number, b: number): number {
  return ((r & 0xf8) << 8) | ((g & 0xfc) << 3) | (b >> 3);
}

/** Expands RGB565 back to 8-bit RGB (replicating the high bits so white stays white). */
export function unpackRgb565(v: number): Rgb {
  const r5 = (v >> 11) & 0x1f;
  const g6 = (v >> 5) & 0x3f;
  const b5 = v & 0x1f;
  return [(r5 << 3) | (r5 >> 2), (g6 << 2) | (g6 >> 4), (b5 << 3) | (b5 >> 2)];
}

export interface QuantiseOptions {
  /** Floyd–Steinberg error diffusion (default true). */
  dither?: boolean;
  /** Rows at the bottom that are excluded from dithering and written as an exact colour. */
  stripRows?: number;
  stripColor?: Rgb;
}

/**
 * Quantises an RGBA raster to RGB565 (one uint16 per pixel). With dithering, the quantisation
 * error is diffused Floyd–Steinberg style; the flat strip (if given) is written exactly and never
 * receives diffused error, so it stays perfectly flat.
 */
export function toRgb565(img: Raster, opts: QuantiseOptions = {}): Uint16Array {
  const { width, height, data } = img;
  const dither = opts.dither ?? true;
  const stripStart = opts.stripRows ? height - opts.stripRows : height;
  const out = new Uint16Array(width * height);
  const buf = new Float32Array(width * height * 3);
  for (let i = 0, j = 0; i < data.length; i += 4, j += 3) {
    buf[j] = data[i]!;
    buf[j + 1] = data[i + 1]!;
    buf[j + 2] = data[i + 2]!;
  }
  const clamp = (v: number) => (v < 0 ? 0 : v > 255 ? 255 : v);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const p = y * width + x;
      if (y >= stripStart && opts.stripColor) {
        out[p] = packRgb565(opts.stripColor[0], opts.stripColor[1], opts.stripColor[2]);
        continue;
      }
      const j = p * 3;
      const r = clamp(buf[j]!);
      const g = clamp(buf[j + 1]!);
      const b = clamp(buf[j + 2]!);
      const v = packRgb565(Math.round(r), Math.round(g), Math.round(b));
      out[p] = v;
      if (!dither) continue;
      const [qr, qg, qb] = unpackRgb565(v);
      const er = r - qr;
      const eg = g - qg;
      const eb = b - qb;
      const spread = (dx: number, dy: number, wgt: number) => {
        const nx = x + dx;
        const ny = y + dy;
        if (nx < 0 || nx >= width || ny >= stripStart) return;
        const k = (ny * width + nx) * 3;
        buf[k] = buf[k]! + er * wgt;
        buf[k + 1] = buf[k + 1]! + eg * wgt;
        buf[k + 2] = buf[k + 2]! + eb * wgt;
      };
      spread(1, 0, 7 / 16);
      spread(-1, 1, 3 / 16);
      spread(0, 1, 5 / 16);
      spread(1, 1, 1 / 16);
    }
  }
  return out;
}

/** RGB565 → RGBA raster (what the LCD actually shows; used for the 1x preview). */
export function rgb565ToRaster(values: Uint16Array, width: number, height: number): Raster {
  const img = createRaster(width, height);
  for (let p = 0; p < width * height; p++) {
    const [r, g, b] = unpackRgb565(values[p]!);
    img.data[p * 4] = r;
    img.data[p * 4 + 1] = g;
    img.data[p * 4 + 2] = b;
    img.data[p * 4 + 3] = 255;
  }
  return img;
}

/** Serialises RGB565 values as bytes, little-endian by default (`swapBytes` → big-endian). */
export function rgb565Bytes(values: Uint16Array, swapBytes = false): Uint8Array {
  const out = new Uint8Array(values.length * 2);
  for (let i = 0; i < values.length; i++) {
    const v = values[i]!;
    if (swapBytes) {
      out[i * 2] = v >> 8;
      out[i * 2 + 1] = v & 0xff;
    } else {
      out[i * 2] = v & 0xff;
      out[i * 2 + 1] = v >> 8;
    }
  }
  return out;
}

// ------------------------------------------------------------------------------------ metrics

export function luminance(r: number, g: number, b: number): number {
  return 0.299 * r + 0.587 * g + 0.114 * b;
}

/** Grayscale (0..255) image of a raster. */
export function toGray(img: Raster): Float32Array {
  const g = new Float32Array(img.width * img.height);
  for (let p = 0; p < g.length; p++) {
    const i = p * 4;
    g[p] = luminance(img.data[i]!, img.data[i + 1]!, img.data[i + 2]!);
  }
  return g;
}

export interface RegionOptions {
  /** Rows at the bottom to exclude (dynamic strip). */
  excludeStripRows?: number;
  /** Exclude pixels outside the rounded rectangle of this radius (masked corners). */
  cornerRadius?: number;
}

function regionMask(img: Raster, opts: RegionOptions): Uint8Array {
  const { width, height } = img;
  const m = new Uint8Array(width * height);
  const stripStart = opts.excludeStripRows ? height - opts.excludeStripRows : height;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const inside = y < stripStart && (opts.cornerRadius === undefined || insideRoundedRect(x, y, width, height, opts.cornerRadius));
      m[y * width + x] = inside ? 1 : 0;
    }
  }
  return m;
}

export interface LuminanceStats {
  min: number;
  max: number;
  mean: number;
  stddev: number;
  /** Fraction of the analysed pixels whose local gradient is below `flatThreshold`. */
  flatFraction: number;
  /** Fraction of the analysed pixels at or below 1/8 and at or above 7/8 of full scale (tails of the histogram). */
  darkFraction: number;
  brightFraction: number;
  /** Number of pixels analysed. */
  count: number;
}

/**
 * Luminance histogram spread and flatness over the content region (strip + masked corners
 * excluded when requested). A pixel is "flat" when |∂x| + |∂y| of luminance < threshold.
 */
export function luminanceStats(img: Raster, opts: RegionOptions = {}, flatThreshold = 3): LuminanceStats {
  const gray = toGray(img);
  const mask = regionMask(img, opts);
  const { width, height } = img;
  let min = 255;
  let max = 0;
  let sum = 0;
  let sum2 = 0;
  let n = 0;
  let flat = 0;
  let dark = 0;
  let bright = 0;
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) {
      const p = y * width + x;
      if (!mask[p]) continue;
      const v = gray[p]!;
      min = Math.min(min, v);
      max = Math.max(max, v);
      sum += v;
      sum2 += v * v;
      n++;
      if (v <= 32) dark++;
      if (v >= 223) bright++;
      const right = x + 1 < width && mask[p + 1] ? gray[p + 1]! : v;
      const down = y + 1 < height && mask[p + width] ? gray[p + width]! : v;
      if (Math.abs(right - v) + Math.abs(down - v) < flatThreshold) flat++;
    }
  }
  const mean = n ? sum / n : 0;
  const variance = n ? sum2 / n - mean * mean : 0;
  return {
    min,
    max,
    mean,
    stddev: Math.sqrt(Math.max(0, variance)),
    flatFraction: n ? flat / n : 1,
    darkFraction: n ? dark / n : 0,
    brightFraction: n ? bright / n : 0,
    count: n,
  };
}

/** Area-averaged grayscale thumbnail (size×size) of the content region for similarity checks. */
export function grayThumbnail(img: Raster, size = 32, opts: RegionOptions = {}): Float64Array {
  const gray = toGray(img);
  const mask = regionMask(img, opts);
  const { width, height } = img;
  const stripStart = opts.excludeStripRows ? height - opts.excludeStripRows : height;
  const out = new Float64Array(size * size);
  const cellW = width / size;
  const cellH = stripStart / size;
  for (let j = 0; j < size; j++) {
    for (let i = 0; i < size; i++) {
      let sum = 0;
      let n = 0;
      const x0 = Math.floor(i * cellW);
      const x1 = Math.max(x0 + 1, Math.floor((i + 1) * cellW));
      const y0 = Math.floor(j * cellH);
      const y1 = Math.max(y0 + 1, Math.floor((j + 1) * cellH));
      for (let y = y0; y < y1; y++) {
        for (let x = x0; x < x1; x++) {
          const p = y * width + x;
          if (!mask[p]) continue;
          sum += gray[p]!;
          n++;
        }
      }
      out[j * size + i] = n ? sum / n : 0;
    }
  }
  return out;
}

/** Normalised cross-correlation of two equally sized vectors (−1..1; 1 = identical up to gain/offset). */
export function ncc(a: ArrayLike<number>, b: ArrayLike<number>): number {
  const n = Math.min(a.length, b.length);
  let ma = 0;
  let mb = 0;
  for (let i = 0; i < n; i++) {
    ma += a[i]!;
    mb += b[i]!;
  }
  ma /= n;
  mb /= n;
  let num = 0;
  let da = 0;
  let db = 0;
  for (let i = 0; i < n; i++) {
    const x = a[i]! - ma;
    const y = b[i]! - mb;
    num += x * y;
    da += x * x;
    db += y * y;
  }
  const den = Math.sqrt(da * db);
  return den === 0 ? 0 : num / den;
}

/** Fraction of pixels in a rect that differ from the raster's flat strip colour (used by tests to assert "ink"). */
export function inkFraction(img: Raster, rect: { x: number; y: number; w: number; h: number }, background: Rgb, tolerance = 24): number {
  let ink = 0;
  let n = 0;
  for (let y = Math.max(0, Math.floor(rect.y)); y < Math.min(img.height, Math.ceil(rect.y + rect.h)); y++) {
    for (let x = Math.max(0, Math.floor(rect.x)); x < Math.min(img.width, Math.ceil(rect.x + rect.w)); x++) {
      const i = (y * img.width + x) * 4;
      const d = Math.abs(img.data[i]! - background[0]) + Math.abs(img.data[i + 1]! - background[1]) + Math.abs(img.data[i + 2]! - background[2]);
      if (d > tolerance) ink++;
      n++;
    }
  }
  return n ? ink / n : 0;
}

/** True when every pixel in the bottom `rows` rows equals `rgb`. */
export function isStripFlat(img: Raster, rows: number, rgb: Rgb): boolean {
  for (let y = img.height - rows; y < img.height; y++) {
    for (let x = 0; x < img.width; x++) {
      const i = (y * img.width + x) * 4;
      if (img.data[i] !== rgb[0] || img.data[i + 1] !== rgb[1] || img.data[i + 2] !== rgb[2]) {
        // masked corners are black by design
        if (img.data[i] === 0 && img.data[i + 1] === 0 && img.data[i + 2] === 0) continue;
        return false;
      }
    }
  }
  return true;
}
