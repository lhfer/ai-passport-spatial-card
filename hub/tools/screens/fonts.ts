/**
 * Font discovery for resvg. Preference: Noto Sans CJK SC / Noto Sans SC (if installed under
 * ~/Library/Fonts or /Library/Fonts), else PingFang SC (macOS system font, lives under
 * /System/Library/AssetsV2 and is NOT found by resvg's system-font scan, so it is passed explicitly),
 * else Hiragino Sans GB.
 */
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import type { FontSet } from '../../../assets/card/screens/index.ts';

export interface ResolvedFonts {
  fonts: FontSet;
  /** Extra font files to hand to resvg (`font.fontFiles`). */
  fontFiles: string[];
  /** Which CJK family will actually be used. */
  cjkFamily: string;
  notes: string[];
}

function listDir(dir: string): string[] {
  try {
    return fs.readdirSync(dir).map((f) => path.join(dir, f));
  } catch {
    return [];
  }
}

function findPingFang(): string[] {
  const roots = ['/System/Library/AssetsV2'];
  const files: string[] = [];
  for (const root of roots) {
    for (const asset of listDir(root)) {
      if (!path.basename(asset).startsWith('com_apple_MobileAsset_Font')) continue;
      for (const bundle of listDir(asset)) {
        const candidate = path.join(bundle, 'AssetData', 'PingFang.ttc');
        if (fs.existsSync(candidate)) files.push(candidate);
      }
    }
  }
  if (fs.existsSync('/System/Library/Fonts/PingFang.ttc')) files.push('/System/Library/Fonts/PingFang.ttc');
  return files;
}

function findNoto(): { files: string[]; family: string } | null {
  const dirs = [path.join(os.homedir(), 'Library', 'Fonts'), '/Library/Fonts'];
  const found: string[] = [];
  let family = '';
  for (const dir of dirs) {
    for (const file of listDir(dir)) {
      const base = path.basename(file).toLowerCase();
      if (/notosanscjk(sc)?[-.]|noto sans cjk sc|notosanscjk-.*\.ttc/.test(base) || /^notosanscjk.*\.(otf|ttc)$/.test(base)) {
        found.push(file);
        family = 'Noto Sans CJK SC';
      } else if (/^notosanssc[-.]/.test(base) && !family) {
        found.push(file);
        family = 'Noto Sans SC';
      }
    }
  }
  return found.length ? { files: found, family } : null;
}

export function resolveFonts(): ResolvedFonts {
  const notes: string[] = [];
  const noto = findNoto();
  const pingfang = findPingFang();
  const fontFiles: string[] = [];
  let cjkFamily: string;
  if (noto) {
    cjkFamily = noto.family;
    fontFiles.push(...noto.files);
    notes.push(`CJK font: ${noto.family} (${noto.files.length} file(s))`);
  } else if (pingfang.length) {
    cjkFamily = 'PingFang SC';
    fontFiles.push(...pingfang);
    notes.push(`CJK font: PingFang SC (${pingfang[0]}); install Noto Sans CJK SC (brew install --cask font-noto-sans-cjk-sc) to prefer it`);
  } else if (fs.existsSync('/System/Library/Fonts/Hiragino Sans GB.ttc')) {
    cjkFamily = 'Hiragino Sans GB';
    notes.push('CJK font: Hiragino Sans GB (fallback)');
  } else {
    cjkFamily = 'sans-serif';
    notes.push('WARNING: no CJK font found; Chinese text will render with a fallback font');
  }
  const chain = [cjkFamily, 'PingFang SC', 'Hiragino Sans GB', 'Noto Sans CJK SC', 'sans-serif'].filter((v, i, a) => a.indexOf(v) === i);
  return {
    fonts: {
      cjk: chain.join(', '),
      latin: 'Avenir Next, Helvetica Neue, Arial, sans-serif',
      display: 'DIN Condensed, Avenir Next Condensed, Futura, Helvetica Neue, sans-serif',
      mono: 'Menlo, SF Mono, Courier New, monospace',
    },
    fontFiles,
    cjkFamily,
    notes,
  };
}
