/**
 * Note cover cache (`hub/data/covers/`), shared by the two ways a cover can arrive:
 *   - the scraper, right after a scrape, inside the logged-in Playwright session (sequential, jittered);
 *   - `GET /api/notes/:id/cover`, on demand, when the Vision Pro asks for one the scraper missed.
 *
 * Both go through {@link CoverStore.ensure}, so the rules live in one place: single-flight per id,
 * Referer + Chromium UA (the CDN 403s without them), 10 s timeout, 3 MB cap enforced while streaming,
 * magic-byte type sniffing (an HTML error page must never be served as an image) and a 10 minute
 * negative cache so a broken cover is not re-fetched on every frame.
 *
 * Files are stored **without an extension** under the note id: the type is sniffed on read, so the two
 * writers can never disagree about the file name.
 */
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { createLogger, type Logger } from './log.ts';
import { NOTE_ID_RE, type RecentNote } from './scraper/notes.ts';

export const MAX_COVER_BYTES = 3 * 1024 * 1024;
export const COVER_TIMEOUT_MS = 10_000;
export const NEGATIVE_TTL_MS = 10 * 60_000;
export const COVER_MAX_AGE_S = 86_400;
export const COVER_REFERER = 'https://www.xiaohongshu.com/';
export const COVER_USER_AGENT =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';

export interface CoverDownload {
  status: number;
  contentType: string | null;
  body: Buffer;
  /** Set when the transfer was cut off at the cap. */
  tooLarge?: boolean;
}

/** Pluggable transport so the scraper can reuse the Playwright session's cookies. */
export type CoverDownloader = (url: string, headers: Record<string, string>, signal: AbortSignal) => Promise<CoverDownload>;

export type CoverFailure = 'no-source' | 'bad-id' | 'negative' | 'http' | 'not-image' | 'too-large' | 'timeout' | 'error';

export type CoverResult =
  | { ok: true; id: string; file: string; bytes: number; contentType: string; from: 'disk' | 'network' }
  | { ok: false; id: string; reason: CoverFailure; status?: number; message?: string };

export interface CoverStoreOptions {
  dir: string;
  download?: CoverDownloader;
  referer?: string;
  userAgent?: string;
  timeoutMs?: number;
  maxBytes?: number;
  negativeTtlMs?: number;
  logger?: Logger;
  now?: () => number;
}

/** Image type from the first bytes; null for anything that is not an image we would serve. */
export function sniffImageType(buf: Buffer): string | null {
  if (buf.length < 12) return null;
  if (buf[0] === 0xff && buf[1] === 0xd8 && buf[2] === 0xff) return 'image/jpeg';
  if (buf[0] === 0x89 && buf.toString('latin1', 1, 4) === 'PNG') return 'image/png';
  if (buf.toString('latin1', 0, 3) === 'GIF') return 'image/gif';
  if (buf.toString('latin1', 0, 4) === 'RIFF' && buf.toString('latin1', 8, 12) === 'WEBP') return 'image/webp';
  if (buf.toString('latin1', 4, 8) === 'ftyp') {
    const brand = buf.toString('latin1', 8, 12);
    if (brand.startsWith('avif') || brand.startsWith('avis')) return 'image/avif';
    if (brand.startsWith('heic') || brand.startsWith('heix') || brand.startsWith('mif1')) return 'image/heic';
  }
  return null;
}

/** Streaming downloader over `fetch`; the cap is enforced chunk by chunk, not from Content-Length. */
export function createFetchDownloader(fetchImpl: typeof fetch = fetch, maxBytes = MAX_COVER_BYTES): CoverDownloader {
  return async (url, headers, signal) => {
    const res = await fetchImpl(url, { headers, signal, redirect: 'follow' });
    const contentType = res.headers.get('content-type');
    if (!res.ok || !res.body) {
      await res.body?.cancel().catch(() => undefined);
      return { status: res.status, contentType, body: Buffer.alloc(0) };
    }
    const reader = res.body.getReader();
    const chunks: Buffer[] = [];
    let total = 0;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel().catch(() => undefined);
        return { status: res.status, contentType, body: Buffer.alloc(0), tooLarge: true };
      }
      chunks.push(Buffer.from(value));
    }
    return { status: res.status, contentType, body: Buffer.concat(chunks) };
  };
}

export class CoverStore {
  private readonly log: Logger;
  private readonly download: CoverDownloader;
  private readonly inflight = new Map<string, Promise<CoverResult>>();
  private readonly negative = new Map<string, { until: number; reason: CoverFailure; status?: number }>();
  private readonly now: () => number;
  readonly dir: string;
  /** Upstream requests actually made (tests assert single-flight / negative cache with this). */
  downloads = 0;

  constructor(private readonly opts: CoverStoreOptions) {
    this.dir = opts.dir;
    this.log = opts.logger ?? createLogger('covers');
    this.download = opts.download ?? createFetchDownloader(fetch, opts.maxBytes ?? MAX_COVER_BYTES);
    this.now = opts.now ?? Date.now;
  }

  /** Absolute cache path, or null when the id could never be a note id (path traversal included). */
  pathFor(id: string): string | null {
    return NOTE_ID_RE.test(id) ? path.join(this.dir, id) : null;
  }

  has(id: string): boolean {
    const file = this.pathFor(id);
    return file !== null && fs.existsSync(file);
  }

  /** Reads a cached cover and sniffs its type; null when it is missing or not an image any more. */
  read(id: string): { body: Buffer; contentType: string; etag: string } | null {
    const file = this.pathFor(id);
    if (!file) return null;
    let body: Buffer;
    try {
      body = fs.readFileSync(file);
    } catch {
      return null;
    }
    const contentType = sniffImageType(body);
    if (!contentType) return null;
    return { body, contentType, etag: `"${createHash('sha1').update(body).digest('hex').slice(0, 24)}"` };
  }

  /** Marks an id as broken so the next request fails fast instead of hammering the CDN. */
  private fail(id: string, reason: CoverFailure, status?: number, message?: string): CoverResult {
    this.negative.set(id, status === undefined ? { until: this.now() + (this.opts.negativeTtlMs ?? NEGATIVE_TTL_MS), reason } : { until: this.now() + (this.opts.negativeTtlMs ?? NEGATIVE_TTL_MS), reason, status });
    const result: CoverResult = { ok: false, id, reason };
    if (status !== undefined) result.status = status;
    if (message !== undefined) result.message = message;
    return result;
  }

  /** Cached negative verdict for an id, if it has not expired. */
  negativeFor(id: string): { reason: CoverFailure; status?: number } | null {
    const entry = this.negative.get(id);
    if (!entry) return null;
    if (entry.until <= this.now()) {
      this.negative.delete(id);
      return null;
    }
    return entry.status === undefined ? { reason: entry.reason } : { reason: entry.reason, status: entry.status };
  }

  /** Test / restart hook. */
  clearNegative(id?: string): void {
    if (id) this.negative.delete(id);
    else this.negative.clear();
  }

  /**
   * Makes sure the cover for `id` is on disk. Returns from disk when it already is, otherwise fetches
   * it once (concurrent callers share the same request).
   */
  ensure(id: string, src: string | null | undefined, download?: CoverDownloader): Promise<CoverResult> {
    const file = this.pathFor(id);
    if (!file) return Promise.resolve({ ok: false, id, reason: 'bad-id' });
    const cached = this.read(id);
    if (cached) return Promise.resolve({ ok: true, id, file, bytes: cached.body.length, contentType: cached.contentType, from: 'disk' });
    const negative = this.negativeFor(id);
    if (negative) return Promise.resolve(negative.status === undefined ? { ok: false, id, reason: negative.reason } : { ok: false, id, reason: negative.reason, status: negative.status });
    if (!src) return Promise.resolve({ ok: false, id, reason: 'no-source' });
    const running = this.inflight.get(id);
    if (running) return running;
    const task = this.fetchCover(id, file, src, download).finally(() => this.inflight.delete(id));
    this.inflight.set(id, task);
    return task;
  }

  private async fetchCover(id: string, file: string, src: string, download?: CoverDownloader): Promise<CoverResult> {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), this.opts.timeoutMs ?? COVER_TIMEOUT_MS);
    this.downloads++;
    try {
      const headers = {
        referer: this.opts.referer ?? COVER_REFERER,
        'user-agent': this.opts.userAgent ?? COVER_USER_AGENT,
        accept: 'image/avif,image/webp,image/apng,image/*,*/*;q=0.8',
      };
      const res = await (download ?? this.download)(src, headers, controller.signal);
      if (res.tooLarge) return this.fail(id, 'too-large', res.status, `cover exceeds ${this.opts.maxBytes ?? MAX_COVER_BYTES} bytes`);
      if (res.status < 200 || res.status >= 300) return this.fail(id, 'http', res.status, `upstream ${res.status}`);
      if (res.body.length > (this.opts.maxBytes ?? MAX_COVER_BYTES)) return this.fail(id, 'too-large', res.status, 'cover exceeds the size cap');
      const contentType = sniffImageType(res.body);
      if (!contentType) return this.fail(id, 'not-image', res.status, `upstream sent ${res.contentType ?? 'unknown'} (${res.body.length} B)`);
      fs.mkdirSync(this.dir, { recursive: true });
      const tmp = `${file}.tmp`;
      fs.writeFileSync(tmp, res.body);
      fs.renameSync(tmp, file);
      this.log.info(`cover ${id} ${contentType} ${Math.round(res.body.length / 1024)} kB`);
      return { ok: true, id, file, bytes: res.body.length, contentType, from: 'network' };
    } catch (err) {
      const aborted = controller.signal.aborted || (err as Error).name === 'AbortError' || (err as Error).name === 'TimeoutError';
      return this.fail(id, aborted ? 'timeout' : 'error', undefined, (err as Error).message);
    } finally {
      clearTimeout(timer);
    }
  }
}

export interface FillCoversOptions {
  /** Downloads per run (default 10 — the fan only shows 10 cards). */
  max?: number;
  /** Jitter window between downloads, ms. */
  minDelayMs?: number;
  maxDelayMs?: number;
  random?: () => number;
  sleep?: (ms: number) => Promise<void>;
  /** Transport for this run — the scraper passes one backed by its logged-in Playwright session. */
  download?: CoverDownloader;
  logger?: Logger;
}

const wait = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

/**
 * Fills `coverPath` for a freshly scraped list: cached covers cost nothing, missing ones are fetched
 * sequentially with 300–800 ms of jitter (never in parallel — a burst of 10 identical requests from
 * one IP is exactly what gets a scraper blocked), at most `max` per run.
 */
export async function fillCovers(store: CoverStore, notes: RecentNote[], opts: FillCoversOptions = {}): Promise<{ downloaded: number; cached: number; failed: number }> {
  const log = opts.logger ?? createLogger('covers');
  const max = opts.max ?? 10;
  const minDelay = opts.minDelayMs ?? 300;
  const maxDelay = opts.maxDelayMs ?? 800;
  const random = opts.random ?? Math.random;
  const sleep = opts.sleep ?? wait;
  let downloaded = 0;
  let cached = 0;
  let failed = 0;
  for (const note of notes) {
    const file = store.pathFor(note.id);
    if (!file) continue;
    if (store.has(note.id)) {
      note.coverPath = file;
      cached++;
      continue;
    }
    if (downloaded >= max) continue;
    if (downloaded > 0) await sleep(Math.round(minDelay + random() * (maxDelay - minDelay)));
    const result = await store.ensure(note.id, note.coverSrc, opts.download);
    if (result.ok) {
      note.coverPath = result.file;
      downloaded++;
    } else {
      failed++;
      log.warn(`cover ${note.id} failed: ${result.reason}${result.status ? ` ${result.status}` : ''}`);
      if (result.reason === 'timeout' || result.reason === 'error') downloaded++; // count against the budget
    }
  }
  return { downloaded, cached, failed };
}
