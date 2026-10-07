/** Original, deterministic vector artwork for the public demo. No external images or fonts. */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const require = createRequire(new URL('../hub/package.json', import.meta.url));
const { Resvg } = require('@resvg/resvg-js');
const svg = (body, w = 540, h = 540) => `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">${body}</svg>`;
function write(relative, body, w = 540, h = 540) {
  const filename = path.join(root, relative);
  fs.mkdirSync(path.dirname(filename), { recursive: true });
  fs.writeFileSync(filename, new Resvg(svg(body, w, h)).render().asPng());
}
const defs = `<defs>
  <radialGradient id="sky" cx=".7" cy=".2" r="1"><stop stop-color="#384c68"/><stop offset="1" stop-color="#081322"/></radialGradient>
  <radialGradient id="planet" cx=".3" cy=".2" r=".9"><stop stop-color="#fcf4dc"/><stop offset=".5" stop-color="#c7d9df"/><stop offset="1" stop-color="#5c7b91"/></radialGradient>
  <linearGradient id="gold"><stop stop-color="#b07e39"/><stop offset=".45" stop-color="#fff4cd"/><stop offset="1" stop-color="#c58d42"/></linearGradient>
</defs>`;
const stars = Array.from({ length: 72 }, (_, i) => `<circle cx="${(i * 173 + 27) % 540}" cy="${(i * 97 + 19) % 540}" r="${i % 7 === 0 ? 2.2 : 1}" fill="#fae7b8" opacity="${.22 + (i % 5) * .12}"/>`).join('');
const background = `<rect width="540" height="540" rx="32" fill="url(#sky)"/>${stars}<path d="M-40 535Q230 300 580 470L580 580H-40" fill="#102639"/><path d="M-20 550Q340 365 570 495" fill="none" stroke="#7897a3" opacity=".3"/>`;
const figure = `<g transform="rotate(-24 270 274)"><ellipse cx="270" cy="277" rx="203" ry="65" fill="none" stroke="url(#gold)" stroke-width="14"/><circle cx="270" cy="264" r="114" fill="url(#planet)" stroke="#fcf1da" stroke-width="3"/><path d="M67 277A203 65 0 0 0 473 277" fill="none" stroke="url(#gold)" stroke-width="14"/></g>`;
const steam = `<path d="M82 152Q322 22 449 115" fill="none" stroke="#ecd5a2" stroke-width="2" opacity=".8"/><path d="M450 95L455 112L473 116L456 121L451 138L446 121L429 116L446 111Z" fill="#fff4d4"/>`;
const avatar = defs + background + figure + steam;
write('assets/card/avatar.png', avatar);
write('visionos/SpatialCard/Resources/Assets.xcassets/Avatar.imageset/avatar.png', avatar);
const layers = 'visionos/SpatialCard/Resources/v4/';
write(layers + 'v4-avatar-back.png', defs + background);
write(layers + 'v4-avatar-figure.png', defs + figure);
write(layers + 'v4-avatar-steam.png', steam);
write(layers + 'v4-avatar-shadow.png', '<ellipse cx="270" cy="300" rx="175" ry="82" fill="#050d20" opacity=".22"/>');
write(layers + 'v4-covermask-avatar.png', '<rect width="540" height="540" fill="black"/><circle cx="270" cy="264" r="114" fill="white"/>');
const labels = ['ORBIT', 'STARDUST', 'NEON', 'AFTERGLOW', 'WANDER', 'MAKE', 'POCKET', 'PAPER', 'HELLO', 'BEGIN'];
const palettes = [['#111d35','#dbbe7e'],['#13202c','#b5dfdd'],['#302341','#ecba8b'],['#21333d','#f2caa4'],['#183335','#d1d9a1']];
for (let i = 1; i <= 10; i++) {
  const [bg, accent] = palettes[(i - 1) % palettes.length];
  const waves = Array.from({ length: 12 }, (_, j) => `<path d="M-40 ${300 + j * 17}Q${125 + i * 9} ${50 + j * 22} 440 ${280 + j * 19}" fill="none" stroke="${accent}" stroke-width="${j === 4 ? 3 : 1}" opacity="${.2 + j * .05}"/>`).join('');
  const body = `<rect width="400" height="520" fill="${bg}"/><circle cx="${100 + i * 12}" cy="176" r="${57 + i * 2}" fill="${accent}" opacity=".85"/>${waves}<text x="28" y="49" font-family="sans-serif" font-size="12" letter-spacing="3" fill="${accent}">SPATIAL JOURNAL / ${String(i).padStart(2,'0')}</text><text x="26" y="475" font-family="sans-serif" font-size="37" letter-spacing="4" fill="#f9f1df">${labels[i-1]}</text><text x="28" y="500" font-family="sans-serif" font-size="10" letter-spacing="2" fill="${accent}">A LITTLE WORLD OF YOUR OWN</text>`;
  write(`visionos/SpatialCard/Tools/fake-cover-${i}.png`, body, 400, 520);
  const old = path.join(root, `visionos/SpatialCard/Tools/fake-cover-${i}.jpg`);
  if (fs.existsSync(old)) fs.unlinkSync(old);
  write(layers + `v4-covermask-fake-cover-${i}.png`, `<rect width="400" height="520" fill="black"/><circle cx="${100 + i * 12}" cy="176" r="${57 + i * 2}" fill="white"/>`, 400, 520);
}
// Keep the note payload paired with the generated PNG covers.
const notesPath = path.join(root, 'visionos/SpatialCard/Tools/fake-notes.json');
fs.writeFileSync(notesPath, fs.readFileSync(notesPath, 'utf8').replace(/fake-cover-(\d+)\.jpg/g, 'fake-cover-$1.png'));
console.log('Generated anonymous avatar layers, ten covers and masks. Run pnpm screens in hub/ next.');
