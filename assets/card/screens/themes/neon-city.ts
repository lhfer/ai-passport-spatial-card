/**
 * neon-city — 霓虹雨城. A rain-streaked night skyline dominates the top two thirds under a
 * clouded sky with a low moon and searchlights; the three tags hang as neon signs; the small
 * avatar sits bottom-left in a neon frame with the name / handle / location glowing to its
 * right; flat strip.
 */
import { FRAME, px } from '../layout.ts';
import { esc, f, layoutRuns, pinGlyph, rng, roundedRect, runsMarkup, shade, slotText } from '../svg-kit.ts';
import { SVG_NS, type ThemeContext } from '../types.ts';

const W = FRAME.width;
const STRIP_Y = FRAME.height - FRAME.dynamicStripPx;
const HORIZON = 200;

export function neonCitySvg(ctx: ThemeContext): string {
  const L = ctx.layout;
  const R = rng('neon-city:rain:v4');
  const av = px.circle(L.avatar);
  const palette = ['#ffd75e', '#5ff3ff', '#ff5fd2', '#ffb070', '#9bff7a'];

  // --- moon + searchlights (large asymmetric luminance structure in the sky) ---------------
  const moon = `<circle cx="188" cy="62" r="24" fill="url(#moonGrad)"/><circle cx="188" cy="62" r="34" fill="#ffe9b8" opacity="0.18" filter="url(#wideBlur)"/>`;
  let beams = '';
  for (const [bx, ang, len] of [
    [46, -68, 190],
    [58, -52, 170],
    [166, -112, 150],
  ] as const) {
    const a = (ang * Math.PI) / 180;
    const spread = 0.045;
    const p1 = { x: bx + Math.cos(a - spread) * len, y: HORIZON - 30 + Math.sin(a - spread) * len };
    const p2 = { x: bx + Math.cos(a + spread) * len, y: HORIZON - 30 + Math.sin(a + spread) * len };
    beams += `<path d="M${bx} ${HORIZON - 30}L${f(p1.x)} ${f(p1.y)}L${f(p2.x)} ${f(p2.y)}Z" fill="url(#beamGrad)" opacity="0.5"/>`;
  }

  // --- distant skyline (dim) ---------------------------------------------------------------
  let far = '';
  for (let x = -8; x < W + 8; ) {
    const w = R.int(10, 26);
    const h = R.int(30, 105);
    far += `<rect x="${x}" y="${HORIZON - h - 14}" width="${w}" height="${h + 14}" fill="${shade('#241448', R.range(-0.2, 0.25))}"/>`;
    const cols = Math.floor((w - 3) / 4);
    const rows = Math.floor((h - 4) / 5);
    for (let j = 0; j < rows; j++) for (let i = 0; i < cols; i++) if (R.chance(0.28)) far += `<rect x="${f(x + 2 + i * 4)}" y="${f(HORIZON - h - 12 + j * 5)}" width="2" height="2.6" fill="${shade(R.pick(palette), R.range(-0.5, -0.1))}" opacity="${f(R.range(0.35, 0.8))}"/>`;
    x += w + R.int(0, 3);
  }

  // --- near skyline -------------------------------------------------------------------------
  let near = '';
  let reflections = '';
  for (let x = -6; x < W + 6; ) {
    const w = R.int(14, 36);
    const h = R.int(48, 132);
    const top = HORIZON - h;
    const body = shade('#0b0716', R.range(-0.3, 0.35));
    near += `<rect x="${x}" y="${top}" width="${w}" height="${h}" fill="${body}" stroke="${shade(body, 0.35)}" stroke-width="0.6"/>`;
    if (R.chance(0.45)) near += `<rect x="${f(x + R.range(2, w - 4))}" y="${f(top - R.range(6, 18))}" width="1.2" height="${f(R.range(6, 18))}" fill="#3a2a5a"/>`;
    if (R.chance(0.3)) near += `<rect x="${f(x + 2)}" y="${f(top - 4)}" width="${f(w - 4)}" height="4" fill="${shade(body, 0.2)}"/>`;
    const cw = R.pick([4, 5, 6]);
    const ch = R.pick([4, 5, 6, 7]);
    const cols = Math.floor((w - 4) / cw);
    const rows = Math.floor((h - 6) / ch);
    const tint = R.pick(palette);
    const litP = R.range(0.35, 0.7);
    for (let j = 0; j < rows; j++) {
      for (let i = 0; i < cols; i++) {
        if (!R.chance(litP)) continue;
        const c = R.chance(0.75) ? tint : R.pick(palette);
        const jx = R.range(0, 0.8);
        near += `<rect x="${f(x + 2.5 + i * cw + jx)}" y="${f(top + 4 + j * ch)}" width="${f(cw - 2)}" height="${f(ch - 2.2)}" fill="${shade(c, R.range(-0.45, 0.25))}" opacity="${f(R.range(0.5, 1))}"/>`;
      }
    }
    if (R.chance(0.35)) {
      const c = R.pick(palette);
      const nx = x + (R.chance(0.5) ? 1 : w - 3);
      const nh = R.range(h * 0.3, h * 0.7);
      near += `<rect x="${f(nx)}" y="${f(top + 6)}" width="2.2" height="${f(nh)}" fill="${c}" filter="url(#neonBlur)" opacity="0.8"/><rect x="${f(nx + 0.4)}" y="${f(top + 6)}" width="1.4" height="${f(nh)}" fill="#ffffff" opacity="0.9"/>`;
      reflections += `<rect x="${f(nx - 2)}" y="${HORIZON}" width="6" height="${f(R.range(6, 13))}" fill="${c}" opacity="0.35" filter="url(#neonBlur)"/>`;
    }
    x += w + R.int(1, 5);
  }

  // --- rain -------------------------------------------------------------------------------
  let rain = '';
  const ang = (78 * Math.PI) / 180;
  for (let i = 0; i < 180; i++) {
    const x0 = R.range(-12, W + 12);
    const y0 = R.range(-12, STRIP_Y - 30);
    const len = R.range(7, 34);
    const x1 = x0 - Math.cos(ang) * len;
    const y1 = y0 + Math.sin(ang) * len;
    const c = R.chance(0.6) ? '#dff6ff' : R.chance(0.5) ? '#9be7ff' : '#ffc4f0';
    rain += `<line x1="${f(x0)}" y1="${f(y0)}" x2="${f(x1)}" y2="${f(y1)}" stroke="${c}" stroke-width="${f(R.range(0.45, 1.05))}" stroke-opacity="${f(R.range(0.1, 0.5))}" stroke-linecap="round"/>`;
  }

  // --- wet street ---------------------------------------------------------------------------
  let street = `<rect x="0" y="${HORIZON}" width="${W}" height="${STRIP_Y - HORIZON}" fill="url(#streetGrad)"/>`;
  for (let i = 0; i < 70; i++) {
    const y = R.range(HORIZON + 2, STRIP_Y - 4);
    const x0 = R.range(-5, W);
    const len = R.range(4, 26);
    street += `<line x1="${f(x0)}" y1="${f(y)}" x2="${f(x0 + len)}" y2="${f(y)}" stroke="${R.pick(['#8ad8ff', '#ff9be8', '#ffe28a'])}" stroke-width="${f(R.range(0.4, 0.9))}" stroke-opacity="${f(R.range(0.08, 0.35))}"/>`;
  }

  // --- neon signs (tags) --------------------------------------------------------------------
  const signColours = ['#ff5fd2', '#5ff3ff', '#ffe14a'];
  const anchors = [
    { x: 16, y: 26 },
    { x: 126, y: 44 },
    { x: 50, y: 66 },
  ];
  const fs = L.tags.fontSize;
  const sh = L.tags.itemHeight;
  let signs = '';
  ctx.profile.tags.forEach((tag, i) => {
    const a = anchors[i % anchors.length] ?? anchors[0]!;
    const c = signColours[i % signColours.length] ?? '#ff5fd2';
    const line = layoutRuns(tag, ctx.fonts, fs, 600, ctx.measure, ctx.fonts.display, 1.14);
    const w = line.width + 12;
    const ty = a.y + sh / 2 + fs * 0.36;
    signs += roundedRect(a.x, a.y, w, sh, 3, `fill="#0b0716" fill-opacity="0.55" stroke="${c}" stroke-width="1.6" filter="url(#neonBlur)" opacity="0.9"`);
    signs += roundedRect(a.x, a.y, w, sh, 3, `fill="none" stroke="${shade(c, 0.5)}" stroke-width="0.9"`);
    signs += runsMarkup(line, a.x + 6, ty, `fill="${c}" filter="url(#neonBlur)" opacity="0.95"`);
    signs += runsMarkup(line, a.x + 6, ty, 'fill="#ffffff"');
    signs += `<line x1="${f(a.x + w * 0.35)}" y1="${f(a.y)}" x2="${f(a.x + w * 0.3)}" y2="0" stroke="#4a3a70" stroke-width="0.6"/>`;
  });

  // --- avatar in a neon frame ---------------------------------------------------------------
  const fx = av.cx - av.r - 4;
  const fy = av.cy - av.r - 4;
  const fw = (av.r + 4) * 2;
  const avatar = `
    ${roundedRect(fx, fy, fw, fw, 7, `fill="#12081f" stroke="#ff5fd2" stroke-width="2.2" filter="url(#neonBlur)" opacity="0.95"`)}
    ${roundedRect(fx, fy, fw, fw, 7, `fill="none" stroke="#ffd6f4" stroke-width="0.9"`)}
    <circle cx="${f(av.cx)}" cy="${f(av.cy)}" r="${f(av.r + 1.5)}" fill="#5ff3ff" opacity="0.9"/>
    <image xlink:href="${ctx.avatarHref}" x="${f(av.cx - av.r)}" y="${f(av.cy - av.r)}" width="${f(av.r * 2)}" height="${f(av.r * 2)}" clip-path="url(#avatarClip)" preserveAspectRatio="xMidYMid slice"/>
    <circle cx="${f(av.cx)}" cy="${f(av.cy)}" r="${f(av.r)}" fill="url(#avatarSheen)"/>`;

  // --- text --------------------------------------------------------------------------------
  const name = slotText(L.name, ctx.profile.name, ctx.fonts, ctx.measure, { fill: '#fff0fb', glow: '#ff5fd2', glowFilterId: 'textGlow', latinFamily: ctx.fonts.display, latinScale: 1.16 });
  const handle = slotText(L.handle, ctx.profile.handle, ctx.fonts, ctx.measure, { fill: '#e6fdff', glow: '#5ff3ff', glowFilterId: 'textGlow' });
  let location = '';
  if (L.location && ctx.profile.location) {
    const lr = px.rect(L.location);
    const line = layoutRuns(ctx.profile.location, ctx.fonts, L.location.fontSize, L.location.weight, ctx.measure);
    const y = lr.y + lr.h / 2 + L.location.fontSize * 0.36;
    location = pinGlyph(lr.x + 4, y + 1, L.location.fontSize * 1.05, '#ffe14a');
    location += runsMarkup(line, lr.x + 10.8, y + 1.2, 'fill="#0b0716" opacity="0.9"');
    location += runsMarkup(line, lr.x + 10, y, 'fill="#ffe9a8"');
  }

  return `<svg ${SVG_NS} width="${W}" height="${FRAME.height}" viewBox="0 0 ${W} ${FRAME.height}">
<defs>
  <clipPath id="avatarClip"><circle cx="${f(av.cx)}" cy="${f(av.cy)}" r="${f(av.r)}"/></clipPath>
  <clipPath id="content"><rect x="0" y="0" width="${W}" height="${STRIP_Y}"/></clipPath>
  <clipPath id="sky"><rect x="0" y="0" width="${W}" height="${HORIZON}"/></clipPath>
  <filter id="neonBlur" x="-30%" y="-30%" width="160%" height="160%"><feGaussianBlur stdDeviation="1.6"/></filter>
  <filter id="wideBlur" x="-60%" y="-60%" width="220%" height="220%"><feGaussianBlur stdDeviation="9"/></filter>
  <filter id="textGlow" x="-20%" y="-40%" width="140%" height="180%"><feGaussianBlur stdDeviation="2.2"/></filter>
  <filter id="clouds" x="0" y="0" width="100%" height="100%">
    <feTurbulence type="fractalNoise" baseFrequency="0.014 0.03" numOctaves="4" seed="9" stitchTiles="noStitch"/>
    <feColorMatrix type="matrix" values="0 0 0 0 0.62  0 0 0 0 0.3  0 0 0 0 0.9  0 0 0 2.2 -0.9"/>
  </filter>
  <filter id="grain" x="0" y="0" width="100%" height="100%">
    <feTurbulence type="fractalNoise" baseFrequency="0.85" numOctaves="2" seed="23" stitchTiles="noStitch"/>
    <feColorMatrix type="matrix" values="0 0 0 0 1  0 0 0 0 0.8  0 0 0 0 1  0 0 0 0.5 0"/>
  </filter>
  <linearGradient id="skyGrad" x1="0" y1="0" x2="0.35" y2="1"><stop offset="0" stop-color="#0a0824"/><stop offset="0.55" stop-color="#2a1256"/><stop offset="1" stop-color="#4a1a5e"/></linearGradient>
  <linearGradient id="streetGrad" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#3a1a5a"/><stop offset="0.25" stop-color="#170c2c"/><stop offset="1" stop-color="${L.stripColor}"/></linearGradient>
  <linearGradient id="beamGrad" x1="0" y1="1" x2="0" y2="0"><stop offset="0" stop-color="#bfe8ff" stop-opacity="0.55"/><stop offset="1" stop-color="#bfe8ff" stop-opacity="0"/></linearGradient>
  <radialGradient id="moonGrad" cx="0.38" cy="0.35" r="0.7"><stop offset="0" stop-color="#fff6dc"/><stop offset="0.7" stop-color="#f1cf8f"/><stop offset="1" stop-color="#c9964f"/></radialGradient>
  <radialGradient id="cityGlow" cx="0.62" cy="1" r="0.75"><stop offset="0" stop-color="#ff5fd2" stop-opacity="0.55"/><stop offset="0.6" stop-color="#ff5fd2" stop-opacity="0.08"/><stop offset="1" stop-color="#ff5fd2" stop-opacity="0"/></radialGradient>
  <radialGradient id="avatarSheen" cx="0.3" cy="0.22" r="0.85"><stop offset="0" stop-color="#ffffff" stop-opacity="0.18"/><stop offset="0.5" stop-color="#ffffff" stop-opacity="0"/><stop offset="1" stop-color="#1a0030" stop-opacity="0.35"/></radialGradient>
</defs>
<rect width="${W}" height="${FRAME.height}" fill="#0a0824"/>
<g clip-path="url(#content)">
  <rect width="${W}" height="${HORIZON}" fill="url(#skyGrad)"/>
  <g clip-path="url(#sky)"><rect width="${W}" height="${HORIZON}" filter="url(#clouds)" opacity="0.85" style="mix-blend-mode:screen"/></g>
  ${moon}
  <rect width="${W}" height="${HORIZON}" fill="url(#cityGlow)"/>
  ${far}
  ${beams}
  ${near}
  ${street}
  ${reflections}
  ${rain}
  <rect width="${W}" height="${STRIP_Y}" filter="url(#grain)" opacity="0.14" style="mix-blend-mode:screen"/>
</g>
${signs}
${avatar}
${name}
${handle}
${location}
<rect x="0" y="${STRIP_Y}" width="${W}" height="${FRAME.dynamicStripPx}" fill="${L.stripColor}"/>
<title>${esc(ctx.profile.name)} — neon-city</title>
</svg>`;
}
