/**
 * One-shot reconnaissance of the Xiaohongshu profile page (`pnpm hub probe`).
 *
 * The notes parser has three sources (DOM anchors, `window.__INITIAL_STATE__`, innerText) and the
 * shape of the first two is only knowable from the live page. This module loads the profile page
 * **once** with the persistent logged-in profile, waits for the note grid to hydrate, and dumps
 * everything the parser could possibly want into `hub/data/probe/` (git-ignored). It never writes
 * to the store and never touches the device.
 *
 * Gentle by construction: at most {@link ProbeOptions.maxAttempts} loads (default 2, the second only
 * when the first produced neither anchors nor a login wall), 500 ms polling with a 5 s budget, and
 * no scrolling / clicking. A login wall is reported, never retried.
 */
import fs from 'node:fs';
import path from 'node:path';
import { chromium, type BrowserContext } from 'playwright';
import { createLogger, type Logger } from '../log.ts';
import { collectPage, profileUrl, waitForNoteGrid, type Collected, type ProbeAnchor } from './page.ts';
import { looksLikeLoginWall, parseProfileText } from './parse.ts';

export type { ProbeAnchor } from './page.ts';

export interface ProbeOptions {
  userId: string;
  profileDir: string;
  /** Where the dumps land (`hub/data/probe`). */
  outDir: string;
  headed?: boolean;
  /** Poll budget for the note grid (default 5 s, 500 ms steps, stable twice). */
  gridTimeoutMs?: number;
  /** Page loads (default 2; the second one only when the first saw nothing at all). */
  maxAttempts?: number;
  logger?: Logger;
}

export interface ProbeResult {
  status: 'ok' | 'loginWall' | 'empty' | 'error';
  url: string;
  attempts: number;
  anchors: ProbeAnchor[];
  /** Parsed `window.__INITIAL_STATE__` with functions dropped, or null when unavailable. */
  initialState: unknown;
  initialStateError?: string;
  /** Array paths (depth ≤ 6) with their length and the key set of the first element. */
  digest: string[];
  innerText: string;
  files: Record<string, string>;
  message?: string;
}

const MAX_DIGEST_DEPTH = 6;
const MAX_DIGEST_LINES = 200;

function typeName(v: unknown): string {
  if (v === null) return 'null';
  if (Array.isArray(v)) return 'array';
  return typeof v;
}

/**
 * Array paths of a parsed `__INITIAL_STATE__` down to depth 6, each with its length and the key set
 * of its first element — enough to tell where the note list lives without dumping the whole tree.
 */
export function keyDigest(state: unknown, maxDepth = MAX_DIGEST_DEPTH, maxLines = MAX_DIGEST_LINES): string[] {
  const lines: string[] = [];
  const seen = new WeakSet<object>();
  const walk = (node: unknown, pathText: string, depth: number): void => {
    if (lines.length >= maxLines || depth > maxDepth || node === null || typeof node !== 'object') return;
    if (seen.has(node)) return;
    seen.add(node);
    if (Array.isArray(node)) {
      const first = node[0];
      const keys = first !== null && typeof first === 'object' && !Array.isArray(first) ? Object.keys(first as object) : null;
      lines.push(`${pathText || '$'}[${node.length}] first=${keys ? `{${keys.join(',')}}` : typeName(first)}`);
      walk(first, `${pathText}[0]`, depth + 1);
      return;
    }
    for (const [k, v] of Object.entries(node)) {
      if (v === null || typeof v !== 'object') continue;
      walk(v, pathText ? `${pathText}.${k}` : k, depth + 1);
    }
  };
  walk(state, '', 0);
  return lines;
}

function write(outDir: string, name: string, body: string, files: Record<string, string>, log: Logger): void {
  try {
    fs.mkdirSync(outDir, { recursive: true });
    const file = path.join(outDir, name);
    fs.writeFileSync(file, body);
    files[name.replace(/\.[^.]+$/, '').replace(/^\d{4}[^-]*-/, '')] = file;
    log.info(`wrote ${file} (${body.length} chars)`);
  } catch (err) {
    log.warn(`could not write ${name}: ${(err as Error).message}`);
  }
}

/**
 * Loads the profile page once and dumps `__INITIAL_STATE__`, the note anchors and innerText.
 * Never throws; a login wall or an empty grid comes back as a status, not an exception.
 */
export async function probeProfile(opts: ProbeOptions): Promise<ProbeResult> {
  const log = opts.logger ?? createLogger('probe');
  const url = profileUrl(opts.userId);
  const maxAttempts = Math.max(1, Math.min(2, opts.maxAttempts ?? 2));
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const files: Record<string, string> = {};
  let context: BrowserContext | undefined;
  try {
    fs.mkdirSync(opts.profileDir, { recursive: true });
    context = await chromium.launchPersistentContext(opts.profileDir, {
      headless: !opts.headed,
      viewport: { width: 1280, height: 900 },
      locale: 'zh-CN',
      timezoneId: 'Asia/Shanghai',
      args: ['--disable-blink-features=AutomationControlled'],
      ignoreDefaultArgs: ['--enable-automation'],
    });
    const page = context.pages()[0] ?? (await context.newPage());
    let attempts = 0;
    let found = 0;
    let navError: string | undefined;
    let collected: Collected = { anchors: [], stateText: null, stateError: null, innerText: '' };
    while (attempts < maxAttempts) {
      attempts++;
      log.info(`loading ${url} (attempt ${attempts}/${maxAttempts})`);
      try {
        await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30_000 });
        await page.waitForLoadState('networkidle', { timeout: 8_000 }).catch(() => undefined);
        found = await waitForNoteGrid(page, opts.gridTimeoutMs ?? 5_000, log);
        collected = await collectPage(page);
        navError = undefined;
      } catch (err) {
        navError = (err as Error).message;
        log.warn(`attempt ${attempts} failed: ${navError.split('\n')[0]}`);
        collected = await collectPage(page).catch(() => collected);
      }
      const wall = looksLikeLoginWall(collected.innerText, page.url());
      if (found > 0 || wall) break; // never loop on a login wall
    }
    const finalUrl = page.url();
    const wall = looksLikeLoginWall(collected.innerText, finalUrl);
    let initialState: unknown = null;
    let stateError = collected.stateError ?? undefined;
    if (collected.stateText) {
      try {
        initialState = JSON.parse(collected.stateText);
      } catch (err) {
        stateError = `__INITIAL_STATE__ is not JSON: ${(err as Error).message}`;
      }
    }
    const digest = keyDigest(initialState);
    write(opts.outDir, `${stamp}-state.json`, collected.stateText ?? `null\n// ${stateError ?? 'no state'}\n`, files, log);
    write(opts.outDir, `${stamp}-digest.txt`, `${finalUrl}\n\n${digest.join('\n')}\n`, files, log);
    write(opts.outDir, `${stamp}-anchors.json`, `${JSON.stringify(collected.anchors, null, 2)}\n`, files, log);
    write(opts.outDir, `${stamp}-text.txt`, `${finalUrl}\n\n${collected.innerText}\n`, files, log);
    const stats = parseProfileText(collected.innerText);
    const status: ProbeResult['status'] = wall ? 'loginWall' : collected.anchors.length > 0 ? 'ok' : navError ? 'error' : 'empty';
    const result: ProbeResult = {
      status,
      url: finalUrl,
      attempts,
      anchors: collected.anchors,
      initialState,
      digest,
      innerText: collected.innerText,
      files,
      message: navError ?? `anchors=${collected.anchors.length} state=${initialState ? 'yes' : 'no'} followers=${stats.followers ?? '-'} notes=${stats.notes ?? '-'}`,
    };
    if (stateError) result.initialStateError = stateError;
    return result;
  } catch (err) {
    return { status: 'error', url, attempts: 0, anchors: [], initialState: null, digest: [], innerText: '', files, message: (err as Error).message };
  } finally {
    await context?.close().catch(() => undefined);
  }
}
