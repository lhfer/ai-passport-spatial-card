/**
 * data-nebula — 数据星云. The avatar is an off-centre ringed planet on the right; the tags are
 * labelled stars of a constellation in the top-left; layered nebula clouds, a dense star field
 * and faint hex telemetry fill the rest; name / handle / location in the lower third; flat strip.
 */
import { FRAME, px } from '../layout.ts';
import { esc, f, layoutRuns, pinGlyph, rng, runsMarkup, slotText, type Pt } from '../svg-kit.ts';
import { SVG_NS, type ThemeContext } from '../types.ts';

const W = FRAME.width;
const STRIP_Y = FRAME.height - FRAME.dynamicStripPx;

export function dataNebulaSvg(ctx: ThemeContext): string {
  const L = ctx.layout;
  const R = rng('data-nebula:stars:v4');
  const av = px.circle(L.avatar);
  const ringTilt = -24;

  // --- nebula clouds ------------------------------------------------------------------------
  const clouds = [
    { cx: 52, cy: 150, rx: 72, ry: 44, rot: -28, c: '#ff4fd0', o: 0.6 },
    { cx: 204, cy: 34, rx: 62, ry: 34, rot: 18, c: '#33d6ff', o: 0.55 },
    { cx: 18, cy: 44, rx: 50, ry: 30, rot: 40, c: '#8a5cff', o: 0.6 },
    { cx: 120, cy: 238, rx: 92, ry: 26, rot: -8, c: '#4d3cff', o: 0.55 },
    { cx: 216, cy: 190, rx: 44, ry: 30, rot: 62, c: '#ff7a5c', o: 0.45 },
    { cx: 96, cy: 100, rx: 34, ry: 20, rot: -60, c: '#7fffd4', o: 0.4 },
    { cx: 150, cy: 180, rx: 50, ry: 18, rot: 25, c: '#ff9de0', o: 0.4 },
  ];
  let nebula = '';
  clouds.forEach((c, i) => {
    nebula += `<ellipse cx="${c.cx}" cy="${c.cy}" rx="${c.rx}" ry="${c.ry}" transform="rotate(${c.rot} ${c.cx} ${c.cy})" fill="url(#cloud${i})" opacity="${c.o}"/>`;
  });
  const cloudDefs = clouds
    .map((c, i) => `<radialGradient id="cloud${i}" cx="0.5" cy="0.5" r="0.5"><stop offset="0" stop-color="${c.c}" stop-opacity="0.9"/><stop offset="0.55" stop-color="${c.c}" stop-opacity="0.35"/><stop offset="1" stop-color="${c.c}" stop-opacity="0"/></radialGradient>`)
    .join('');

  // --- stars --------------------------------------------------------------------------------
  let stars = '';
  const starColours = ['#ffffff', '#dbeeff', '#ffe7c4', '#cdbcff', '#a8f4ff'];
  for (let i = 0; i < 420; i++) {
    const x = R.range(2, W - 2);
    const y = R.range(2, STRIP_Y - 4);
    if (Math.hypot(x - av.cx, y - av.cy) < av.r + 5) continue;
    const kind = R.next();
    const c = R.pick(starColours);
    if (kind < 0.72) stars += `<circle cx="${f(x)}" cy="${f(y)}" r="${f(R.range(0.4, 0.9))}" fill="${c}" opacity="${f(R.range(0.3, 0.9))}"/>`;
    else if (kind < 0.95) stars += `<circle cx="${f(x)}" cy="${f(y)}" r="${f(R.range(1, 1.6))}" fill="${c}" opacity="${f(R.range(0.6, 1))}"/>`;
    else {
      const r = R.range(1.6, 2.6);
      stars += `<circle cx="${f(x)}" cy="${f(y)}" r="${f(r * 2.2)}" fill="${c}" opacity="0.35" filter="url(#starBlur)"/><circle cx="${f(x)}" cy="${f(y)}" r="${f(r)}" fill="${c}"/>`;
      const s = r * R.range(2.5, 4);
      stars += `<path d="M${f(x - s)} ${f(y)}L${f(x + s)} ${f(y)}M${f(x)} ${f(y - s)}L${f(x)} ${f(y + s)}" stroke="${c}" stroke-width="0.6" opacity="0.7"/>`;
    }
  }

  // --- hex telemetry + a signal trace (fine, non-repeating detail in the lower-left) ---------
  let hex = '';
  const hexChars = '0123456789ABCDEF';
  for (let row = 0; row < 9; row++) {
    const y = 118 + row * 7.2 + R.range(-1, 1);
    const x = 12 + R.range(0, 10);
    const len = R.int(5, 13);
    let s = '';
    for (let k = 0; k < len; k++) s += hexChars[R.int(0, 15)] + (k % 2 ? ' ' : '');
    hex += `<text x="${f(x)}" y="${f(y)}" font-family="${esc(ctx.fonts.mono)}" font-size="5.2" fill="#9fd8ff" opacity="${f(R.range(0.22, 0.5))}">${s.trim()}</text>`;
  }
  let trace = 'M 10 186';
  for (let x = 14; x <= 104; x += R.range(3, 8)) trace += ` L ${f(x)} ${f(186 - R.range(0, 1) ** 2 * 14)}`;
  hex += `<path d="${trace}" fill="none" stroke="#7fe8ff" stroke-width="0.7" stroke-opacity="0.55"/>`;

  // --- constellation with labelled stars (tags) ---------------------------------------------
  const nodes: Pt[] = [
    { x: 27, y: 38 },
    { x: 80, y: 28 },
    { x: 61, y: 60 },
    { x: 122, y: 58 },
  ];
  const rimAngle = Math.atan2(nodes[3]!.y - av.cy, nodes[3]!.x - av.cx);
  const rim: Pt = { x: av.cx + Math.cos(rimAngle) * (av.r + 3), y: av.cy + Math.sin(rimAngle) * (av.r + 3) };
  const edges: [Pt, Pt][] = [
    [nodes[0]!, nodes[2]!],
    [nodes[2]!, nodes[1]!],
    [nodes[1]!, nodes[3]!],
    [nodes[3]!, rim],
    [nodes[0]!, nodes[1]!],
  ];
  let constellation = '';
  for (const [a, b] of edges) constellation += `<line x1="${f(a.x)}" y1="${f(a.y)}" x2="${f(b.x)}" y2="${f(b.y)}" stroke="#bfe9ff" stroke-width="0.7" stroke-opacity="0.75"/>`;
  const labelColours = ['#7ff3ff', '#ff8ae6', '#ffe36e'];
  const fs = L.tags.fontSize;
  nodes.forEach((n, i) => {
    const c = labelColours[i % labelColours.length] ?? '#7ff3ff';
    constellation += `<circle cx="${f(n.x)}" cy="${f(n.y)}" r="4.5" fill="${c}" opacity="0.45" filter="url(#starBlur)"/>`;
    constellation += `<circle cx="${f(n.x)}" cy="${f(n.y)}" r="${i < 3 ? 2.1 : 1.5}" fill="#ffffff"/>`;
    constellation += `<circle cx="${f(n.x)}" cy="${f(n.y)}" r="${i < 3 ? 3.4 : 2.6}" fill="none" stroke="${c}" stroke-width="0.7"/>`;
    const tag = ctx.profile.tags[i];
    if (tag) {
      const line = layoutRuns(tag, ctx.fonts, fs, 600, ctx.measure);
      const tx = n.x + 7;
      const ty = n.y + fs * 0.38;
      constellation += runsMarkup(line, tx, ty, `fill="${c}" filter="url(#textGlow)" opacity="0.9"`);
      constellation += runsMarkup(line, tx, ty, 'fill="#ffffff"');
    }
  });

  // --- planet -------------------------------------------------------------------------------
  const ring = (rx: number, ry: number, width: number, opacity: number) =>
    `<ellipse cx="${f(av.cx)}" cy="${f(av.cy)}" rx="${f(rx)}" ry="${f(ry)}" transform="rotate(${ringTilt} ${f(av.cx)} ${f(av.cy)})" fill="none" stroke="url(#ringGrad)" stroke-width="${f(width)}" opacity="${opacity}"/>`;
  const rings = ring(av.r * 1.72, av.r * 0.5, 5.5, 0.95) + ring(av.r * 1.48, av.r * 0.42, 1.6, 0.85) + ring(av.r * 1.92, av.r * 0.56, 1, 0.6);
  const planet = `
    <circle cx="${f(av.cx)}" cy="${f(av.cy)}" r="${f(av.r + 12)}" fill="#7fe8ff" opacity="0.5" filter="url(#planetGlow)"/>
    <g>${rings}</g>
    <circle cx="${f(av.cx)}" cy="${f(av.cy)}" r="${f(av.r + 1.6)}" fill="#bff6ff"/>
    <image xlink:href="${ctx.avatarHref}" x="${f(av.cx - av.r)}" y="${f(av.cy - av.r)}" width="${f(av.r * 2)}" height="${f(av.r * 2)}" clip-path="url(#avatarClip)" preserveAspectRatio="xMidYMid slice"/>
    <circle cx="${f(av.cx)}" cy="${f(av.cy)}" r="${f(av.r)}" fill="url(#terminator)"/>
    <g clip-path="url(#ringFront)">${rings}</g>`;

  const orbit = `<path d="M ${f(av.cx - 96)} ${f(av.cy + 40)} A 100 100 0 0 1 ${f(av.cx + 20)} ${f(av.cy - 92)}" fill="none" stroke="#9fd8ff" stroke-width="0.6" stroke-opacity="0.35"/>`;

  // --- text --------------------------------------------------------------------------------
  const name = slotText(L.name, ctx.profile.name, ctx.fonts, ctx.measure, { fill: '#ffffff', glow: '#a56bff', glowFilterId: 'textGlow', latinFamily: ctx.fonts.display, latinScale: 1.12 });
  const handle = slotText(L.handle, ctx.profile.handle, ctx.fonts, ctx.measure, { fill: '#8ff3ff', shadow: '#05020c', shadowOpacity: 0.9 });
  let location = '';
  if (L.location && ctx.profile.location) {
    const lr = px.rect(L.location);
    const line = layoutRuns(ctx.profile.location, ctx.fonts, L.location.fontSize, L.location.weight, ctx.measure);
    const pinW = L.location.fontSize * 0.8;
    const x0 = lr.x + (lr.w - line.width - pinW - 3) / 2;
    const y = lr.y + lr.h / 2 + L.location.fontSize * 0.36;
    location = pinGlyph(x0 + pinW / 2, y + 1, L.location.fontSize * 1.05, '#ff8ae6');
    location += runsMarkup(line, x0 + pinW + 3.8, y + 1.2, 'fill="#05020c" opacity="0.9"');
    location += runsMarkup(line, x0 + pinW + 3, y, 'fill="#d9c8ff"');
  }

  return `<svg ${SVG_NS} width="${W}" height="${FRAME.height}" viewBox="0 0 ${W} ${FRAME.height}">
<defs>
  <clipPath id="avatarClip"><circle cx="${f(av.cx)}" cy="${f(av.cy)}" r="${f(av.r)}"/></clipPath>
  <clipPath id="ringFront"><rect x="-200" y="0" width="400" height="200" transform="translate(${f(av.cx)} ${f(av.cy)}) rotate(${ringTilt})"/></clipPath>
  <clipPath id="content"><rect x="0" y="0" width="${W}" height="${STRIP_Y}"/></clipPath>
  <filter id="starBlur" x="-100%" y="-100%" width="300%" height="300%"><feGaussianBlur stdDeviation="1.4"/></filter>
  <filter id="planetGlow" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="7"/></filter>
  <filter id="textGlow" x="-20%" y="-40%" width="140%" height="180%"><feGaussianBlur stdDeviation="2.4"/></filter>
  <filter id="cloudTex" x="0" y="0" width="100%" height="100%">
    <feTurbulence type="fractalNoise" baseFrequency="0.016 0.024" numOctaves="4" seed="5" stitchTiles="noStitch"/>
    <feColorMatrix type="matrix" values="0 0 0 0 0.8  0 0 0 0 0.4  0 0 0 0 1  0 0 0 2.4 -0.95"/>
  </filter>
  <filter id="wispTex" x="0" y="0" width="100%" height="100%">
    <feTurbulence type="turbulence" baseFrequency="0.045 0.02" numOctaves="3" seed="17" stitchTiles="noStitch"/>
    <feColorMatrix type="matrix" values="0 0 0 0 0.45  0 0 0 0 0.9  0 0 0 0 1  0 0 0 1.8 -0.5"/>
  </filter>
  <filter id="grain" x="0" y="0" width="100%" height="100%">
    <feTurbulence type="fractalNoise" baseFrequency="0.95" numOctaves="1" seed="41" stitchTiles="noStitch"/>
    <feColorMatrix type="matrix" values="0 0 0 0 0.9  0 0 0 0 0.85  0 0 0 0 1  0 0 0 0.5 0"/>
  </filter>
  <linearGradient id="spaceGrad" x1="0" y1="0" x2="0.6" y2="1"><stop offset="0" stop-color="#050214"/><stop offset="0.5" stop-color="#150a36"/><stop offset="1" stop-color="#0a0420"/></linearGradient>
  <linearGradient id="ringGrad" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#ffffff"/><stop offset="0.4" stop-color="#c9a6ff"/><stop offset="0.7" stop-color="#5ff3ff"/><stop offset="1" stop-color="#ff8ae6"/></linearGradient>
  <radialGradient id="terminator" cx="0.3" cy="0.28" r="0.95"><stop offset="0" stop-color="#ffffff" stop-opacity="0.16"/><stop offset="0.45" stop-color="#ffffff" stop-opacity="0"/><stop offset="0.8" stop-color="#05021a" stop-opacity="0.45"/><stop offset="1" stop-color="#05021a" stop-opacity="0.85"/></radialGradient>
  ${cloudDefs}
</defs>
<rect width="${W}" height="${FRAME.height}" fill="#050214"/>
<g clip-path="url(#content)">
  <rect width="${W}" height="${STRIP_Y}" fill="url(#spaceGrad)"/>
  ${nebula}
  <rect width="${W}" height="${STRIP_Y}" filter="url(#cloudTex)" opacity="0.7" style="mix-blend-mode:screen"/>
  <rect width="${W}" height="${STRIP_Y}" filter="url(#wispTex)" opacity="0.32" style="mix-blend-mode:screen"/>
  ${stars}
  ${orbit}
  ${hex}
  <rect width="${W}" height="${STRIP_Y}" filter="url(#grain)" opacity="0.12" style="mix-blend-mode:screen"/>
</g>
${constellation}
${planet}
${name}
${handle}
${location}
<rect x="0" y="${STRIP_Y}" width="${W}" height="${FRAME.dynamicStripPx}" fill="${L.stripColor}"/>
<title>${esc(ctx.profile.name)} — data-nebula</title>
</svg>`;
}
