import fs from 'node:fs';
import http from 'node:http';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import WebSocket from 'ws';
import { createApp, type App } from '../src/app.ts';
import { loadEnv } from '../src/config.ts';
import { silentLogger } from '../src/log.ts';
import type { RecentNote } from '../src/scraper/notes.ts';
import type { ScrapeResult } from '../src/scraper/xhs.ts';

async function freePort(): Promise<number> {
  return new Promise((resolve) => {
    const s = net.createServer();
    s.listen(0, () => {
      const port = (s.address() as net.AddressInfo).port;
      s.close(() => resolve(port));
    });
  });
}

function connect(url: string): Promise<{ ws: WebSocket; messages: string[]; next: () => Promise<string> }> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(url);
    const messages: string[] = [];
    const waiters: ((m: string) => void)[] = [];
    let cursor = 0; // messages already handed out by next()
    ws.on('message', (data) => {
      const text = data.toString();
      messages.push(text);
      const w = waiters.shift();
      if (w) {
        cursor++;
        w(text);
      }
    });
    const next = () => {
      if (cursor < messages.length) return Promise.resolve(messages[cursor++]!);
      return new Promise<string>((r) => waiters.push(r));
    };
    ws.on('open', () => resolve({ ws, messages, next }));
    ws.on('error', reject);
  });
}

let dir: string;
let app: App;
let port: number;
let scrapeResults: ScrapeResult[];

/**
 * `freePort()` only proves the port was free a moment ago — other vitest workers open their own
 * ephemeral ports, so retry when one of them wins the race between the probe and `app.start()`.
 */
async function startOnFreePort(): Promise<void> {
  for (let attempt = 1; ; attempt++) {
    port = await freePort();
    const env = loadEnv({ PORT: String(port), HUB_DATA_DIR: dir });
    app = createApp(env, { serial: false, logger: silentLogger, scrape: async () => scrapeResults.shift() ?? { status: 'error', message: 'no fixture' } });
    try {
      await app.start();
      return;
    } catch (err) {
      await app.stop().catch(() => undefined);
      if ((err as NodeJS.ErrnoException).code !== 'EADDRINUSE' || attempt >= 5) throw err;
    }
  }
}

beforeEach(async () => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hub-web-'));
  scrapeResults = [];
  await startOnFreePort();
});
afterEach(async () => {
  await app.stop();
  fs.rmSync(dir, { recursive: true, force: true });
});

describe('web server', () => {
  it('serves the panel, state and health', async () => {
    const html = await (await fetch(`http://localhost:${port}/`)).text();
    expect(html).toContain('需要重新登录（运行 pnpm hub login）');
    expect(html).toContain('模拟新粉丝');
    expect(html).toContain('隐藏名片');
    expect(html).toContain('显示名片');
    const state = await (await fetch(`http://localhost:${port}/api/state`)).json();
    expect(state.stats.followers).toBe(app.card.stats.followers);
    expect(state.device.connected).toBe(false);
    expect(state.needsLogin).toBe(false);
    expect((await (await fetch(`http://localhost:${port}/api/health`)).json()).ok).toBe(true);
  });

  it('broadcasts stats then celebrate on /vp and state frames on /ui after a simulate', async () => {
    const vp = await connect(`ws://localhost:${port}/vp`);
    const ui = await connect(`ws://localhost:${port}/ui`);
    const first = JSON.parse(await ui.next());
    expect(first.t).toBe('state');
    expect(first.state.vpClients).toBe(1);

    const r = await fetch(`http://localhost:${port}/api/simulate`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ delta: 2 }) });
    expect(r.status).toBe(200);
    const stats = await vp.next();
    const celebrate = await vp.next();
    expect(stats.startsWith('{"t":"stats",')).toBe(true);
    expect(JSON.parse(stats)).toMatchObject({ t: 'stats', followers: app.card.stats.followers + 2, delta: 2 });
    expect(JSON.parse(celebrate)).toEqual({ t: 'celebrate', delta: 2, followers: app.card.stats.followers + 2 });
    expect(vp.messages).toHaveLength(2);

    // /ui gets a fresh state (coalesced) reflecting the new followers
    let latest = first;
    for (let i = 0; i < 20 && latest.state.stats.followers !== app.card.stats.followers + 2; i++) latest = JSON.parse(await ui.next());
    expect(latest.state.stats.followers).toBe(app.card.stats.followers + 2);
    expect(latest.state.stats.source).toBe('manual');

    // theme / cmd / celebrate endpoints broadcast the documented shapes
    await fetch(`http://localhost:${port}/api/theme`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ theme: 'data-nebula' }) });
    expect(JSON.parse(await vp.next())).toEqual({ t: 'set_theme', theme: 'data-nebula' });
    await fetch(`http://localhost:${port}/api/cmd`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ c: 'replay' }) });
    expect(JSON.parse(await vp.next())).toEqual({ t: 'cmd', c: 'replay' });
    const bad = await fetch(`http://localhost:${port}/api/cmd`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ c: 'warp' }) });
    expect(bad.status).toBe(400);
    vp.ws.close();
    ui.ws.close();
  });

  it('sends cmd hide / show on /vp (body spelled `c` or `cmd`) and rejects an unknown command', async () => {
    const vp = await connect(`ws://localhost:${port}/vp`);
    const post = (body: Record<string, unknown>) =>
      fetch(`http://localhost:${port}/api/cmd`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });

    const hide = await post({ cmd: 'hide' }); // the REST body may spell it `cmd`…
    expect(hide.status).toBe(200);
    expect(await hide.json()).toMatchObject({ ok: true, c: 'hide' });
    expect(JSON.parse(await vp.next())).toEqual({ t: 'cmd', c: 'hide' }); // …but on the wire it is always `c`

    const show = await post({ c: 'show' });
    expect(show.status).toBe(200);
    expect(JSON.parse(await vp.next())).toEqual({ t: 'cmd', c: 'show' });

    const bad = await post({ cmd: 'bogus' });
    expect(bad.status).toBe(400);
    expect((await bad.json()).ok).toBe(false);
    expect(vp.messages).toHaveLength(2); // the rejected command broadcast nothing
    vp.ws.close();
  });

  it('sends cmd perf with its switches on /vp (v4 B4 §3.5): the arg rides along, as given', async () => {
    const vp = await connect(`ws://localhost:${port}/vp`);
    const post = (body: Record<string, unknown>) =>
      fetch(`http://localhost:${port}/api/cmd`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });

    const off = await post({ c: 'perf', arg: 'cones=off gallery-glass=off' });
    expect(off.status).toBe(200);
    expect(await off.json()).toMatchObject({ ok: true, c: 'perf' });
    expect(JSON.parse(await vp.next())).toEqual({ t: 'cmd', c: 'perf', arg: 'cones=off gallery-glass=off' });

    const measure = await post({ cmd: 'perf' }); // no switches: the Vision Pro only opens a fresh [perf] window
    expect(measure.status).toBe(200);
    expect(JSON.parse(await vp.next())).toEqual({ t: 'cmd', c: 'perf' });

    const reset = await post({ c: 'perf', arg: 'reset' });
    expect(reset.status).toBe(200);
    expect(JSON.parse(await vp.next())).toEqual({ t: 'cmd', c: 'perf', arg: 'reset' });
    expect(vp.messages).toHaveLength(3);
    vp.ws.close();
  });

  it('destroys upgrades to unknown paths', async () => {
    await expect(connect(`ws://localhost:${port}/nope`)).rejects.toBeTruthy();
  });

  it('flags needsLogin after a login-wall scrape and clears it after a good one', async () => {
    scrapeResults.push({ status: 'needsLogin', url: 'u', message: 'wall' });
    const before = JSON.stringify(app.store.current);
    const r = await fetch(`http://localhost:${port}/api/scrape`, { method: 'POST' });
    expect(r.status).toBe(202);
    const body = await r.json();
    expect(body.ok).toBe(false);
    expect(body.run.status).toBe('needsLogin');
    const state = await (await fetch(`http://localhost:${port}/api/state`)).json();
    expect(state.needsLogin).toBe(true);
    expect(JSON.stringify(app.store.current)).toBe(before);

    scrapeResults.push({ status: 'ok', followers: app.card.stats.followers + 1, likes: null, notes: null, url: 'u', layout: 'number-first' });
    const ok = await fetch(`http://localhost:${port}/api/scrape`, { method: 'POST' });
    expect(ok.status).toBe(200);
    const after = await (await fetch(`http://localhost:${port}/api/state`)).json();
    expect(after.needsLogin).toBe(false);
    expect(after.stats.followers).toBe(app.card.stats.followers + 1);
    expect(after.stats.likes).toBe(app.card.stats.likes); // null from the scrape kept the previous value
  });
});

// ---------------------------------------------------------------------------------------------
// recent-notes fan-out: /api/notes, the cover proxy, the /vp hint frame and /api/strip
// ---------------------------------------------------------------------------------------------

const PNG = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(64, 7)]);
const A = '6a11111111111111111111a1';
const B = '6a22222222222222222222b2';

/** Stand-in for the Xiaohongshu CDN: serves one PNG and one HTML error page. */
async function cdn(): Promise<{ url: (p: string) => string; hits: number; close: () => Promise<void> }> {
  const state = { hits: 0 };
  const server = http.createServer((req, res) => {
    state.hits++;
    if ((req.url ?? '').startsWith('/png')) return void res.writeHead(200, { 'content-type': 'image/png' }).end(PNG);
    res.writeHead(200, { 'content-type': 'image/png' }).end('<html>请先登录</html>');
  });
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const port = (server.address() as net.AddressInfo).port;
  return {
    url: (p) => `http://127.0.0.1:${port}${p}`,
    get hits() {
      return state.hits;
    },
    close: () => new Promise<void>((r) => server.close(() => r())),
  };
}

const note = (id: string, coverSrc: string | null, over: Partial<RecentNote> = {}): RecentNote => ({
  id,
  title: `笔记 ${id.slice(0, 4)}`,
  likes: 168,
  pinned: false,
  hidden: false,
  type: 'normal',
  coverSrc,
  coverPath: null,
  url: `https://www.xiaohongshu.com/user/profile/6510000000000000000000ff/${id}?xsec_token=TEST`,
  order: 0,
  ...over,
});

describe('GET /api/notes', () => {
  it('is an empty list before the first scrape', async () => {
    const body = await (await fetch(`http://localhost:${port}/api/notes`)).json();
    expect(body).toMatchObject({ rev: 0, count: 0, notes: [] });
    const state = await (await fetch(`http://localhost:${port}/api/state`)).json();
    expect(state.recentNotes).toMatchObject({ rev: 0, count: 0 });
  });

  it('returns the documented shape with a relative cover URL and honours ?limit', async () => {
    app.scheduler.applyRecentNotes([note(A, 'http://cdn/a'), note(B, null, { pinned: true, type: 'video', likes: 0 })], 'test');
    const body = await (await fetch(`http://localhost:${port}/api/notes`)).json();
    expect(body).toMatchObject({ rev: 1, count: 2 });
    expect(body.updatedAt).toMatch(/^\d{4}-\d{2}-\d{2}T/);
    expect(body.notes[0]).toEqual({
      id: A,
      title: `笔记 ${A.slice(0, 4)}`,
      likes: 168,
      pinned: false,
      type: 'normal',
      coverURL: `/api/notes/${A}/cover`,
      url: `https://www.xiaohongshu.com/user/profile/6510000000000000000000ff/${A}?xsec_token=TEST`,
      publishedAt: null,
    });
    expect(body.notes[1]).toMatchObject({ pinned: true, type: 'video', likes: 0, coverURL: null }); // no source = no proxy URL
    expect((await (await fetch(`http://localhost:${port}/api/notes?limit=1`)).json()).notes).toHaveLength(1);
    expect((await (await fetch(`http://localhost:${port}/api/notes?limit=nope`)).json()).notes).toHaveLength(2);
    const state = await (await fetch(`http://localhost:${port}/api/state`)).json();
    expect(state.recentNotes).toMatchObject({ rev: 1, count: 2 });
  });

  it('hints /vp only when the revision moved', async () => {
    const vp = await connect(`ws://localhost:${port}/vp`);
    app.scheduler.applyRecentNotes([note(A, 'http://cdn/a')], 'test');
    expect(JSON.parse(await vp.next())).toEqual({ t: 'notes', rev: 1, count: 1 });
    app.scheduler.applyRecentNotes([note(A, 'http://cdn/a', { url: 'https://rotated?xsec_token=NEW' })], 'test');
    app.scheduler.applyRecentNotes([note(A, 'http://cdn/a', { likes: 999 })], 'test');
    expect(JSON.parse(await vp.next())).toEqual({ t: 'notes', rev: 2, count: 1 });
    expect(vp.messages).toHaveLength(2); // the unchanged list in between sent nothing
    vp.ws.close();
  });
});

describe('GET /api/notes/:id/cover', () => {
  it('proxies the cover once, then serves it from disk with cache headers and an ETag', async () => {
    const net = await cdn();
    try {
      app.scheduler.applyRecentNotes([note(A, net.url('/png'))], 'test');
      const r = await fetch(`http://localhost:${port}/api/notes/${A}/cover`);
      expect(r.status).toBe(200);
      expect(r.headers.get('content-type')).toBe('image/png');
      expect(r.headers.get('cache-control')).toBe('public, max-age=86400');
      const etag = r.headers.get('etag')!;
      expect(etag).toMatch(/^"[0-9a-f]{24}"$/);
      expect(Buffer.from(await r.arrayBuffer())).toEqual(PNG);

      const again = await fetch(`http://localhost:${port}/api/notes/${A}/cover`);
      expect(again.status).toBe(200);
      expect(net.hits).toBe(1); // second request came from disk
      const cached = await fetch(`http://localhost:${port}/api/notes/${A}/cover`, { headers: { 'if-none-match': etag } });
      expect(cached.status).toBe(304);
      expect(fs.existsSync(path.join(dir, 'covers', A))).toBe(true);
    } finally {
      await net.close();
    }
  });

  it('answers 502 when the upstream is not an image and does not re-fetch it', async () => {
    const net = await cdn();
    try {
      app.scheduler.applyRecentNotes([note(A, net.url('/login-wall'))], 'test');
      const r = await fetch(`http://localhost:${port}/api/notes/${A}/cover`);
      expect(r.status).toBe(502);
      expect(await r.json()).toMatchObject({ ok: false, error: 'not-image' });
      expect((await fetch(`http://localhost:${port}/api/notes/${A}/cover`)).status).toBe(502);
      expect(net.hits).toBe(1);
    } finally {
      await net.close();
    }
  });

  it('404s an unknown id, a note without a cover and every path-traversal attempt', async () => {
    app.scheduler.applyRecentNotes([note(A, null)], 'test');
    expect((await fetch(`http://localhost:${port}/api/notes/${B}/cover`)).status).toBe(404); // not in the list
    expect((await fetch(`http://localhost:${port}/api/notes/${A}/cover`)).status).toBe(404); // no coverSrc
    expect((await fetch(`http://localhost:${port}/api/notes/..%2F..%2Fstats.json/cover`)).status).toBe(404);
    expect((await fetch(`http://localhost:${port}/api/notes/${A}%2F..%2Fnotes.json/cover`)).status).toBe(404);
    expect(fs.existsSync(path.join(dir, 'stats.json.tmp'))).toBe(false);
  });
});

describe('POST /api/strip', () => {
  it('accepts a strip override and says the device is absent instead of crashing', async () => {
    const r = await fetch(`http://localhost:${port}/api/strip`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ text: '♥1825' }) });
    expect(r.status).toBe(200);
    expect(await r.json()).toMatchObject({ ok: true, text: '♥1825', connected: false, device: { ok: false, reason: 'disconnected' } });
  });

  it('accepts an empty body as "restore the follower count"', async () => {
    const r = await fetch(`http://localhost:${port}/api/strip`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}' });
    expect(await r.json()).toMatchObject({ ok: true, text: null });
  });

  it('rejects glyphs the strip font cannot draw', async () => {
    for (const text of ['笔记', '♥1,825', '♥182512345678', '', 7]) {
      const r = await fetch(`http://localhost:${port}/api/strip`, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ text }) });
      expect(r.status).toBe(400);
      expect((await r.json()).ok).toBe(false);
    }
  });
});
