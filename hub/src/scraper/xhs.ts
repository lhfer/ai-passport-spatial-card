/**
 * Xiaohongshu profile scraper (Playwright Chromium with a persistent profile in hub/data/profile).
 *
 * Strategy: open the profile page, wait for network idle, then poll `document.body.innerText`
 * (up to 15 s) and parse the counts; fall back to the creator centre. A login wall (URL contains
 * "login", login copy without counts, or nothing readable within the timeout) yields
 * `{ status: "needsLogin" }` and a screenshot + innerText dump under hub/data/failures/.
 * Nothing here ever reports 0 / NaN as a value — the store keeps the last good numbers.
 *
 * The same page visit also yields the 10 most recent notes (see `notes.ts`) and, with a
 * {@link CoverStore}, their covers — downloaded inside this session so the CDN sees the same
 * cookies, Referer and UA as the page load. **The notes are strictly a bonus**: any failure there is
 * logged and swallowed, the follower stats are returned regardless.
 */
import fs from 'node:fs';
import path from 'node:path';
import { chromium, type BrowserContext, type Page } from 'playwright';
import { fillCovers, type CoverDownloader, type CoverStore } from '../covers.ts';
import { createLogger, type Logger } from '../log.ts';
import { mergeNotes, type NotesSource, type RecentNote } from './notes.ts';
import { collectPage, CREATOR_HOME_URL, profileUrl, waitForNoteGrid } from './page.ts';
import { looksLikeLoginWall, parseProfileText, type ParsedStats } from './parse.ts';

export { CREATOR_HOME_URL, profileUrl } from './page.ts';

export type ScrapeResult =
  | {
      status: 'ok';
      followers: number;
      likes: number | null;
      notes: number | null;
      url: string;
      layout: ParsedStats['layout'];
      /** The 10 most recent notes, when the grid was readable. Absent = "do not touch the notes store". */
      recentNotes?: RecentNote[];
      notesSource?: NotesSource;
    }
  | { status: 'needsLogin'; url: string; failure?: string; message: string }
  | { status: 'error'; message: string; failure?: string };

export interface ScraperOptions {
  userId: string;
  profileDir: string;
  failuresDir: string;
  headed: boolean;
  /** Poll budget per URL after the page settled (default 15 s). */
  timeoutMs?: number;
  /** HUB_DEBUG=1: dump the exact innerText the parser consumed to `failuresDir/debug-<ts>.txt`. */
  dump?: boolean;
  /** Cover cache; without it the notes come back with `coverPath: null` and nothing is downloaded. */
  covers?: CoverStore | undefined;
  /** Author nickname, for the innerText fallback's line anchoring. */
  author?: string | undefined;
  /** Set false to skip the note grid entirely (stats only). */
  notes?: boolean;
  /** Note-grid hydration budget (default 5 s, polled every 500 ms until the count repeats). */
  gridTimeoutMs?: number;
  logger?: Logger;
}

/** Cover transport backed by the logged-in Playwright session (same cookies as the page load). */
export function playwrightDownloader(context: BrowserContext): CoverDownloader {
  return async (url, headers) => {
    const res = await context.request.get(url, { headers, timeout: 10_000, maxRedirects: 3, failOnStatusCode: false });
    return { status: res.status(), contentType: res.headers()['content-type'] ?? null, body: Buffer.from(await res.body()) };
  };
}

async function launch(opts: ScraperOptions): Promise<BrowserContext> {
  fs.mkdirSync(opts.profileDir, { recursive: true });
  return chromium.launchPersistentContext(opts.profileDir, {
    headless: !opts.headed,
    viewport: { width: 1280, height: 900 },
    locale: 'zh-CN',
    timezoneId: 'Asia/Shanghai',
    args: ['--disable-blink-features=AutomationControlled'],
    ignoreDefaultArgs: ['--enable-automation'],
  });
}

async function bodyText(page: Page): Promise<string> {
  try {
    return await page.evaluate(() => document.body?.innerText ?? '');
  } catch {
    return '';
  }
}

async function saveFailure(page: Page, text: string, dir: string, tag: string, log: Logger): Promise<string | undefined> {
  try {
    fs.mkdirSync(dir, { recursive: true });
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    const base = path.join(dir, `${stamp}-${tag}`);
    await page.screenshot({ path: `${base}.png`, fullPage: false }).catch(() => undefined);
    fs.writeFileSync(`${base}.txt`, `${page.url()}\n\n${text}`);
    log.warn(`saved failure artefacts: ${base}.{png,txt}`);
    return base;
  } catch (err) {
    log.warn(`could not save failure artefacts: ${(err as Error).message}`);
    return undefined;
  }
}

/**
 * Debug dump of the page text the parser actually consumed (HUB_DEBUG=1). Written next to the
 * failure artefacts, which are git-ignored. Never throws — a dump failure must not fail a scrape.
 */
function saveDump(dir: string, url: string, text: string, parsed: ParsedStats, log: Logger): string | undefined {
  try {
    fs.mkdirSync(dir, { recursive: true });
    const stamp = new Date().toISOString().replace(/[:.]/g, '-');
    const file = path.join(dir, `debug-${stamp}.txt`);
    fs.writeFileSync(file, `${url}\n\n${JSON.stringify(parsed)}\n\n${text}\n`);
    log.info(`HUB_DEBUG: dumped page text to ${file}`);
    return file;
  } catch (err) {
    log.warn(`could not write debug dump: ${(err as Error).message}`);
    return undefined;
  }
}

interface Attempt {
  parsed: ParsedStats;
  text: string;
  loginWall: boolean;
  url: string;
}

/** Loads one URL and polls its text until counts appear, a login wall is detected, or the budget runs out. */
async function attempt(page: Page, url: string, timeoutMs: number, log: Logger): Promise<Attempt> {
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 30_000 });
  await page.waitForLoadState('networkidle', { timeout: 8_000 }).catch(() => undefined);
  const deadline = Date.now() + timeoutMs;
  let text = '';
  let parsed = parseProfileText('');
  while (Date.now() < deadline) {
    text = await bodyText(page);
    parsed = parseProfileText(text);
    if (parsed.followers !== null) return { parsed, text, loginWall: false, url: page.url() };
    if (/login|passport/i.test(page.url())) {
      log.warn(`redirected to ${page.url()}`);
      return { parsed, text, loginWall: true, url: page.url() };
    }
    await page.waitForTimeout(500);
  }
  return { parsed, text, loginWall: looksLikeLoginWall(text, page.url(), parsed), url: page.url() };
}

/**
 * The 10 most recent notes from the profile page that is already loaded. Never throws: the note grid
 * is a bonus on top of the follower stats, and a layout change must not cost us the numbers.
 */
async function collectRecentNotes(page: Page, context: BrowserContext, opts: ScraperOptions, log: Logger): Promise<{ notes: RecentNote[]; source: NotesSource } | null> {
  try {
    // `attempt()` returns as soon as the header parses; the grid below it may still be hydrating.
    const found = await waitForNoteGrid(page, opts.gridTimeoutMs ?? 5_000, log);
    const collected = await collectPage(page);
    let state: unknown = null;
    if (collected.stateText) {
      try {
        state = JSON.parse(collected.stateText);
      } catch (err) {
        log.warn(`__INITIAL_STATE__ unreadable: ${(err as Error).message}`);
      }
    }
    const merged = mergeNotes({
      userId: opts.userId,
      anchors: collected.anchors,
      state,
      innerText: collected.innerText,
      author: opts.author,
    });
    log.info(`notes: ${merged.notes.length} (grid anchors ${found}, dom ${merged.counts.dom} / state ${merged.counts.state} / text ${merged.counts.text}, source ${merged.source})`);
    if (merged.notes.length === 0) return null;
    if (opts.covers) {
      const filled = await fillCovers(opts.covers, merged.notes, { download: playwrightDownloader(context), logger: log });
      log.info(`covers: ${filled.downloaded} downloaded, ${filled.cached} cached, ${filled.failed} failed`);
    }
    return { notes: merged.notes, source: merged.source };
  } catch (err) {
    log.warn(`recent notes skipped: ${(err as Error).message.split('\n')[0]}`);
    return null;
  }
}

/** Scheduled / manual scrape. Headless unless `headed` (HEADED=1). */
export async function scrapeProfile(opts: ScraperOptions): Promise<ScrapeResult> {
  const log = opts.logger ?? createLogger('xhs');
  const timeoutMs = opts.timeoutMs ?? 15_000;
  let context: BrowserContext | undefined;
  try {
    context = await launch(opts);
    const page = context.pages()[0] ?? (await context.newPage());
    const urls = [profileUrl(opts.userId), CREATOR_HOME_URL];
    let lastAttempt: Attempt | undefined;
    for (const [i, url] of urls.entries()) {
      log.info(`loading ${url}`);
      const a = await attempt(page, url, timeoutMs, log);
      lastAttempt = a;
      if (a.parsed.followers !== null) {
        if (opts.dump) saveDump(opts.failuresDir, a.url, a.text, a.parsed, log);
        log.info(`parsed followers=${a.parsed.followers} likes=${a.parsed.likes ?? '-'} notes=${a.parsed.notes ?? '-'} following=${a.parsed.following ?? '-'} (${a.parsed.layout})`);
        const result: ScrapeResult = { status: 'ok', followers: a.parsed.followers, likes: a.parsed.likes, notes: a.parsed.notes, url: a.url, layout: a.parsed.layout };
        // Only the profile page has a note grid; the creator centre fallback (i > 0) has none.
        const recent = i === 0 && opts.notes !== false ? await collectRecentNotes(page, context, opts, log) : null;
        if (recent) {
          result.recentNotes = recent.notes;
          result.notesSource = recent.source;
        }
        return result;
      }
      log.warn(`${a.loginWall ? 'login wall' : 'no counts'} on ${a.url}${i < urls.length - 1 ? '; trying fallback' : ''}`);
      await saveFailure(page, a.text, opts.failuresDir, a.loginWall ? 'login' : 'nomatch', log);
    }
    const url = lastAttempt?.url ?? urls[0]!;
    return { status: 'needsLogin', url, message: lastAttempt?.loginWall ? '登录墙：需要重新登录（运行 pnpm hub login）' : '页面没有可读的粉丝数（可能未登录或页面为空），请运行 pnpm hub login' };
  } catch (err) {
    const message = (err as Error).message;
    log.error(`scrape failed: ${message}`);
    return { status: 'error', message };
  } finally {
    await context?.close().catch(() => undefined);
  }
}

export interface LoginOptions extends ScraperOptions {
  /** Give up after this long (default 10 min). */
  maxWaitMs?: number;
}

/**
 * Interactive login: opens a HEADED browser on the profile page and resolves when the counts
 * become readable (logged in) or when the user closes the window.
 */
export async function loginInteractive(opts: LoginOptions): Promise<ScrapeResult> {
  const log = opts.logger ?? createLogger('xhs');
  const maxWaitMs = opts.maxWaitMs ?? 10 * 60_000;
  let context: BrowserContext | undefined;
  try {
    context = await launch({ ...opts, headed: true });
    const page = context.pages()[0] ?? (await context.newPage());
    let closed = false;
    context.on('close', () => (closed = true));
    page.on('close', () => (closed = true));
    await page.goto(profileUrl(opts.userId), { waitUntil: 'domcontentloaded', timeout: 30_000 }).catch((err: Error) => log.warn(err.message));
    log.info('请在弹出的浏览器里登录小红书（扫码或手机号）。识别到粉丝数后会自动结束；关闭窗口也会结束。');
    const deadline = Date.now() + maxWaitMs;
    while (!closed && Date.now() < deadline) {
      const text = await bodyText(page);
      const parsed = parseProfileText(text);
      if (parsed.followers !== null) {
        log.info(`登录成功：followers=${parsed.followers} likes=${parsed.likes ?? '-'} notes=${parsed.notes ?? '-'}`);
        return { status: 'ok', followers: parsed.followers, likes: parsed.likes, notes: parsed.notes, url: page.url(), layout: parsed.layout };
      }
      await page.waitForTimeout(2000).catch(() => (closed = true));
    }
    return { status: 'needsLogin', url: profileUrl(opts.userId), message: closed ? '浏览器已关闭，未识别到粉丝数' : '等待登录超时' };
  } catch (err) {
    return { status: 'error', message: (err as Error).message };
  } finally {
    await context?.close().catch(() => undefined);
  }
}
