import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { CoverStore, fillCovers, sniffImageType } from '../src/covers.ts';
import { silentLogger } from '../src/log.ts';
import type { RecentNote } from '../src/scraper/notes.ts';

const PNG = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(64, 7)]);
const JPEG = Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xe0]), Buffer.alloc(64, 3)]);
const WEBP = Buffer.concat([Buffer.from('RIFF'), Buffer.alloc(4), Buffer.from('WEBP'), Buffer.alloc(32)]);

const A = '6a11111111111111111111a1';
const B = '6a22222222222222222222b2';

interface Upstream {
  url: (p: string) => string;
  hits: { url: string; referer?: string | undefined; ua?: string | undefined }[];
  close: () => Promise<void>;
  /** Blocks the next `/slow` response until released. */
  release: () => void;
}

async function upstream(): Promise<Upstream> {
  const hits: Upstream['hits'] = [];
  let unblock: () => void = () => {};
  const gate = new Promise<void>((r) => (unblock = r));
  const server = http.createServer(async (req, res) => {
    hits.push({ url: req.url ?? '', referer: req.headers.referer, ua: req.headers['user-agent'] });
    const url = req.url ?? '';
    if (url.startsWith('/png')) return void res.writeHead(200, { 'content-type': 'image/png' }).end(PNG);
    if (url.startsWith('/jpeg')) return void res.writeHead(200, { 'content-type': 'application/octet-stream' }).end(JPEG);
    if (url.startsWith('/webp')) return void res.writeHead(200, { 'content-type': 'image/webp' }).end(WEBP);
    if (url.startsWith('/html')) return void res.writeHead(200, { 'content-type': 'image/png' }).end('<html>请登录</html>');
    if (url.startsWith('/403')) return void res.writeHead(403).end('no');
    if (url.startsWith('/huge')) {
      res.writeHead(200, { 'content-type': 'image/png' });
      res.write(PNG);
      for (let i = 0; i < 40; i++) res.write(Buffer.alloc(100 * 1024, 1)); // 4 MB
      return void res.end();
    }
    if (url.startsWith('/slow')) {
      await gate;
      return void res.writeHead(200, { 'content-type': 'image/png' }).end(PNG);
    }
    res.writeHead(404).end();
  });
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const port = (server.address() as { port: number }).port;
  return {
    url: (p) => `http://127.0.0.1:${port}${p}`,
    hits,
    release: () => unblock(),
    close: () => new Promise<void>((r) => server.close(() => r())),
  };
}

let dir: string;
let net: Upstream;

beforeEach(async () => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hub-covers-'));
  net = await upstream();
});
afterEach(async () => {
  await net.close();
  fs.rmSync(dir, { recursive: true, force: true });
});

const store = (over: Partial<ConstructorParameters<typeof CoverStore>[0]> = {}) =>
  new CoverStore({ dir: path.join(dir, 'covers'), logger: silentLogger, ...over });

describe('sniffImageType', () => {
  it('knows the formats the CDN serves and rejects everything else', () => {
    expect(sniffImageType(PNG)).toBe('image/png');
    expect(sniffImageType(JPEG)).toBe('image/jpeg');
    expect(sniffImageType(WEBP)).toBe('image/webp');
    expect(sniffImageType(Buffer.from('<html>请先登录</html>'))).toBeNull();
    expect(sniffImageType(Buffer.alloc(3))).toBeNull();
  });
});

describe('CoverStore.ensure', () => {
  it('downloads with Referer + Chromium UA and caches to disk under the note id', async () => {
    const s = store();
    const result = await s.ensure(A, net.url('/png'));
    expect(result).toMatchObject({ ok: true, from: 'network', contentType: 'image/png' });
    expect(net.hits[0]!.referer).toBe('https://www.xiaohongshu.com/');
    expect(net.hits[0]!.ua).toContain('Chrome/');
    expect(fs.existsSync(path.join(dir, 'covers', A))).toBe(true);
    expect(s.read(A)).toMatchObject({ contentType: 'image/png' });
    expect(s.read(A)!.etag).toMatch(/^"[0-9a-f]{24}"$/);
  });

  it('serves the second request from disk without touching the upstream', async () => {
    const s = store();
    await s.ensure(A, net.url('/png'));
    const again = await s.ensure(A, net.url('/png'));
    expect(again).toMatchObject({ ok: true, from: 'disk' });
    expect(net.hits).toHaveLength(1);
    expect(s.downloads).toBe(1);
  });

  it('sniffs the real type when the CDN lies about content-type', async () => {
    expect(await store().ensure(A, net.url('/jpeg'))).toMatchObject({ ok: true, contentType: 'image/jpeg' });
  });

  it('single-flights concurrent requests for the same id', async () => {
    const s = store();
    const both = Promise.all([s.ensure(A, net.url('/slow')), s.ensure(A, net.url('/slow'))]);
    net.release();
    const [first, second] = await both;
    expect(first).toMatchObject({ ok: true });
    expect(second).toMatchObject({ ok: true });
    expect(net.hits).toHaveLength(1);
  });

  it('refuses a non-image and negative-caches it for 10 minutes', async () => {
    let clock = 1_000_000;
    const s = store({ now: () => clock });
    expect(await s.ensure(A, net.url('/html'))).toMatchObject({ ok: false, reason: 'not-image' });
    expect(await s.ensure(A, net.url('/html'))).toMatchObject({ ok: false, reason: 'not-image' });
    expect(net.hits).toHaveLength(1); // the second call never left the process
    clock += 10 * 60_000 + 1;
    expect(await s.ensure(A, net.url('/html'))).toMatchObject({ ok: false, reason: 'not-image' });
    expect(net.hits).toHaveLength(2); // …until the negative entry expired
  });

  it('stops at the 3 MB cap while streaming', async () => {
    const s = store();
    expect(await s.ensure(A, net.url('/huge'))).toMatchObject({ ok: false, reason: 'too-large' });
    expect(fs.existsSync(path.join(dir, 'covers', A))).toBe(false);
  });

  it('reports upstream errors with their status and does not retry them', async () => {
    const s = store();
    expect(await s.ensure(A, net.url('/403'))).toMatchObject({ ok: false, reason: 'http', status: 403 });
    expect(await s.ensure(A, net.url('/403'))).toMatchObject({ ok: false, reason: 'http', status: 403 });
    expect(net.hits).toHaveLength(1);
  });

  it('times out instead of hanging', async () => {
    const s = store({ timeoutMs: 40 });
    const result = await s.ensure(A, net.url('/slow'));
    expect(result).toMatchObject({ ok: false, reason: 'timeout' });
    net.release();
  });

  it('refuses ids that are not note ids (path traversal included)', async () => {
    const s = store();
    expect(s.pathFor('../../stats.json')).toBeNull();
    expect(s.pathFor('..%2F..%2Fstats.json')).toBeNull();
    expect(s.pathFor('t:0123456789abcdef0123456789abcdef01234567')).toBeNull();
    expect(await s.ensure('../../stats.json', net.url('/png'))).toMatchObject({ ok: false, reason: 'bad-id' });
    expect(s.read('../../stats.json')).toBeNull();
    expect(net.hits).toHaveLength(0);
  });

  it('reports a missing source instead of fetching nothing', async () => {
    expect(await store().ensure(A, null)).toMatchObject({ ok: false, reason: 'no-source' });
  });
});

describe('fillCovers', () => {
  const note = (id: string, src: string | null): RecentNote => ({
    id,
    title: 't',
    likes: 0,
    pinned: false,
    hidden: false,
    type: 'normal',
    coverSrc: src,
    coverPath: null,
    url: '',
    order: 0,
  });

  it('downloads sequentially with jitter, sets coverPath and skips what is cached', async () => {
    const s = store();
    const delays: number[] = [];
    const notes = [note(A, net.url('/png')), note(B, net.url('/webp'))];
    const first = await fillCovers(s, notes, { sleep: async (ms) => void delays.push(ms), random: () => 0.5, logger: silentLogger });
    expect(first).toMatchObject({ downloaded: 2, cached: 0, failed: 0 });
    expect(delays).toEqual([550]); // one gap between two downloads, 300–800 ms
    expect(notes[0]!.coverPath).toBe(path.join(dir, 'covers', A));

    const again = [note(A, net.url('/png')), note(B, net.url('/webp'))];
    expect(await fillCovers(s, again, { logger: silentLogger })).toMatchObject({ downloaded: 0, cached: 2 });
    expect(net.hits).toHaveLength(2);
  });

  it('never downloads more than the per-run budget', async () => {
    const s = store();
    const ids = ['6a00000000000000000000a0', '6a00000000000000000000a1', '6a00000000000000000000a2'];
    const notes = ids.map((id) => note(id, net.url('/png')));
    expect(await fillCovers(s, notes, { max: 2, sleep: async () => {}, logger: silentLogger })).toMatchObject({ downloaded: 2 });
    expect(net.hits).toHaveLength(2);
    expect(notes[2]!.coverPath).toBeNull();
  });

  it('keeps going when one cover fails', async () => {
    const s = store();
    const notes = [note(A, net.url('/403')), note(B, net.url('/png'))];
    expect(await fillCovers(s, notes, { sleep: async () => {}, logger: silentLogger })).toMatchObject({ downloaded: 1, failed: 1 });
    expect(notes[1]!.coverPath).not.toBeNull();
  });
});
