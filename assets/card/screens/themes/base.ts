/**
 * base — 名片. Large centred avatar floating over a crystal-facet field (Delaunay shards lit
 * from the top-right), name / handle / location / three tag pills underneath, flat strip.
 */
import { FRAME, px } from '../layout.ts';
import { delaunay, esc, f, jitteredPoints, layoutRuns, mix, pinGlyph, polygonPath, rng, roundedRect, runsMarkup, shade, slotText, type Pt } from '../svg-kit.ts';
import { SVG_NS, type ThemeContext } from '../types.ts';

const W = FRAME.width;
const STRIP_Y = FRAME.height - FRAME.dynamicStripPx;

export function baseSvg(ctx: ThemeContext): string {
  const L = ctx.layout;
  const R = rng('base:crystal:v4');
  const av = px.circle(L.avatar);
  const light: Pt = { x: 250, y: -30 };

  // --- crystal facets --------------------------------------------------------------------
  const pts = jitteredPoints(R, { x: -24, y: -24, w: W + 48, h: STRIP_Y + 30 }, 9, 11, 0.95);
  const ringN = 15;
  for (let i = 0; i < ringN; i++) {
    const a = (i / ringN) * Math.PI * 2 + R.range(-0.18, 0.18);
    const rr = av.r + 6 + R.range(0, 14);
    pts.push({ x: av.cx + Math.cos(a) * rr, y: av.cy + Math.sin(a) * rr });
  }
  const tris = delaunay(pts);
  let facets = '';
  for (const t of tris) {
    const cx = (t[0].x + t[1].x + t[2].x) / 3;
    const cy = (t[0].y + t[1].y + t[2].y) / 3;
    if (cy > STRIP_Y + 20) continue;
    const v = Math.max(0, Math.min(1, cy / STRIP_Y));
    const base = v < 0.5 ? mix('#0d2258', '#0a4f6b', v * 2) : mix('#0a4f6b', '#0b1a3c', (v - 0.5) * 2);
    const dl = Math.hypot(cx - light.x, cy - light.y);
    const da = Math.hypot(cx - av.cx, cy - av.cy);
    let tone = R.range(-0.5, 0.32) + 0.35 * Math.max(0, 1 - dl / 300) + 0.22 * Math.max(0, 1 - da / 120);
    if (R.chance(0.09)) tone = R.range(0.55, 0.92);
    if (R.chance(0.07)) tone = R.range(-0.85, -0.6);
    const fill = shade(base, Math.max(-0.9, Math.min(0.95, tone)));
    const stroke = shade(fill, 0.4);
    facets += `<path d="${polygonPath(t)}" fill="${fill}" stroke="${stroke}" stroke-width="0.5" stroke-opacity="0.7"/>`;
  }

  // --- light rays from the top-right corner (asymmetric) -----------------------------------
  let rays = '';
  for (let i = 0; i < 5; i++) {
    const a = R.range(Math.PI * 0.62, Math.PI * 0.95);
    const len = 420;
    const spread = R.range(0.012, 0.035);
    const p1 = { x: light.x + Math.cos(a - spread) * len, y: light.y + Math.sin(a - spread) * len };
    const p2 = { x: light.x + Math.cos(a + spread) * len, y: light.y + Math.sin(a + spread) * len };
    rays += `<path d="${polygonPath([light, p1, p2])}" fill="url(#rayGrad)" opacity="${f(R.range(0.16, 0.3))}"/>`;
  }

  // --- tag pills ---------------------------------------------------------------------------
  const tagColours = ['#5ee8ff', '#ff6fd8', '#ffd166'];
  const tr = px.rect(L.tags);
  const fs = L.tags.fontSize;
  const ph = L.tags.itemHeight;
  const gap = 7;
  const lines = ctx.profile.tags.map((t) => layoutRuns(t, ctx.fonts, fs, 500, ctx.measure));
  const widths = lines.map((l) => l.width + 26);
  const total = widths.reduce((a, b) => a + b, 0) + gap * (widths.length - 1);
  const scale = total > tr.w ? tr.w / total : 1;
  let x = tr.x + (tr.w - total * scale) / 2;
  const py = tr.y + (tr.h - ph) / 2;
  let pills = '';
  lines.forEach((line, i) => {
    const w = (widths[i] ?? 40) * scale;
    const c = tagColours[i % tagColours.length] ?? '#5ee8ff';
    pills += roundedRect(x, py, w, ph, ph / 2, `fill="#06122c" fill-opacity="0.78" stroke="${c}" stroke-width="1.1"`);
    pills += `<circle cx="${f(x + 9.5)}" cy="${f(py + ph / 2)}" r="2.3" fill="${c}"/>`;
    pills += runsMarkup(line, x + 16, py + ph / 2 + fs * 0.36, 'fill="#eef7ff"');
    x += w + gap * scale;
  });

  // --- avatar ------------------------------------------------------------------------------
  const avatar = `
    <circle cx="${f(av.cx)}" cy="${f(av.cy)}" r="${f(av.r + 9)}" fill="#7ff3ff" opacity="0.55" filter="url(#softGlow)"/>
    <circle cx="${f(av.cx)}" cy="${f(av.cy)}" r="${f(av.r + 3.2)}" fill="url(#ringGrad)"/>
    <circle cx="${f(av.cx)}" cy="${f(av.cy)}" r="${f(av.r + 0.8)}" fill="#08152e"/>
    <image xlink:href="${ctx.avatarHref}" x="${f(av.cx - av.r)}" y="${f(av.cy - av.r)}" width="${f(av.r * 2)}" height="${f(av.r * 2)}" clip-path="url(#avatarClip)" preserveAspectRatio="xMidYMid slice"/>
    <circle cx="${f(av.cx)}" cy="${f(av.cy)}" r="${f(av.r)}" fill="url(#avatarSheen)"/>`;

  // --- text --------------------------------------------------------------------------------
  const name = slotText(L.name, ctx.profile.name, ctx.fonts, ctx.measure, { fill: '#ffffff', shadow: '#03101f', shadowOpacity: 0.85, latinFamily: ctx.fonts.display, latinScale: 1.12 });
  const handle = slotText(L.handle, ctx.profile.handle, ctx.fonts, ctx.measure, { fill: '#9fe9ff', shadow: '#03101f', shadowOpacity: 0.8 });
  let location = '';
  if (L.location && ctx.profile.location) {
    const lr = px.rect(L.location);
    const line = layoutRuns(ctx.profile.location, ctx.fonts, L.location.fontSize, L.location.weight, ctx.measure);
    const pinW = L.location.fontSize * 0.8;
    const x0 = lr.x + (lr.w - line.width - pinW - 3) / 2;
    const y = lr.y + lr.h / 2 + L.location.fontSize * 0.36;
    location = pinGlyph(x0 + pinW / 2, y + 1, L.location.fontSize * 1.05, '#ffd166');
    location += runsMarkup(line, x0 + pinW + 3.8, y + 1.2, 'fill="#03101f" opacity="0.8"');
    location += runsMarkup(line, x0 + pinW + 3, y, 'fill="#dbe9ff"');
  }

  return `<svg ${SVG_NS} width="${W}" height="${FRAME.height}" viewBox="0 0 ${W} ${FRAME.height}">
<defs>
  <clipPath id="avatarClip"><circle cx="${f(av.cx)}" cy="${f(av.cy)}" r="${f(av.r)}"/></clipPath>
  <clipPath id="content"><rect x="0" y="0" width="${W}" height="${STRIP_Y}"/></clipPath>
  <filter id="softGlow" x="-40%" y="-40%" width="180%" height="180%"><feGaussianBlur stdDeviation="5"/></filter>
  <filter id="grain" x="0" y="0" width="100%" height="100%">
    <feTurbulence type="fractalNoise" baseFrequency="0.9" numOctaves="2" seed="11" stitchTiles="noStitch"/>
    <feColorMatrix type="matrix" values="0 0 0 0 0.85  0 0 0 0 0.95  0 0 0 0 1  0 0 0 0.55 0"/>
  </filter>
  <linearGradient id="rayGrad" x1="1" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#ffffff" stop-opacity="0.9"/><stop offset="1" stop-color="#8fe9ff" stop-opacity="0"/></linearGradient>
  <linearGradient id="ringGrad" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#ffffff"/><stop offset="0.5" stop-color="#5ee8ff"/><stop offset="1" stop-color="#ff6fd8"/></linearGradient>
  <radialGradient id="avatarSheen" cx="0.3" cy="0.22" r="0.85"><stop offset="0" stop-color="#ffffff" stop-opacity="0.22"/><stop offset="0.45" stop-color="#ffffff" stop-opacity="0"/><stop offset="1" stop-color="#001a3a" stop-opacity="0.35"/></radialGradient>
  <linearGradient id="bottomFade" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${L.stripColor}" stop-opacity="0"/><stop offset="1" stop-color="${L.stripColor}" stop-opacity="0.9"/></linearGradient>
</defs>
<rect width="${W}" height="${FRAME.height}" fill="#0b1a3c"/>
<g clip-path="url(#content)">
  ${facets}
  <rect width="${W}" height="${STRIP_Y}" filter="url(#grain)" opacity="0.16" style="mix-blend-mode:screen"/>
  ${rays}
  <rect x="0" y="${STRIP_Y - 36}" width="${W}" height="36" fill="url(#bottomFade)"/>
</g>
${avatar}
${name}
${handle}
${location}
${pills}
<rect x="0" y="${STRIP_Y - 1}" width="${W}" height="1" fill="#5ee8ff" opacity="0.55"/>
<rect x="0" y="${STRIP_Y}" width="${W}" height="${FRAME.dynamicStripPx}" fill="${L.stripColor}"/>
<title>${esc(ctx.profile.name)} — base</title>
</svg>`;
}
