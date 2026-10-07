/**
 * Director's remote: Hono HTTP API + static panel, plus two WebSocket endpoints via `ws`:
 *   /ui — state pushes to the panel (`{"t":"state", ...}`)
 *   /vp — one-way broadcast of protocol messages (stats | celebrate | set_theme | cmd | notes) for the
 *         Vision Pro app (docs/protocol.md, "Hub → Vision Pro")
 *
 * It also serves the recent-notes fan-out: `GET /api/notes` (the list the scraper stored) and
 * `GET /api/notes/:id/cover` (a caching proxy — the CDN refuses requests without a Referer, and the
 * headset should not be talking to the CDN at all).
 */
import fs from 'node:fs';
import type { IncomingMessage, Server as HttpServer } from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { serve } from '@hono/node-server';
import { Hono } from 'hono';
import { WebSocketServer, type WebSocket } from 'ws';
import type { Card } from '../config.ts';
import { COVER_MAX_AGE_S, type CoverStore } from '../covers.ts';
import type { DeviceClient } from '../device/client.ts';
import { isTheme, type CmdArg, type DeviceLink } from '../device/link.ts';
import type { SerialManager } from '../device/serial.ts';
import { createLogger, type Logger } from '../log.ts';
import type { NotesStore } from '../notes-store.ts';
import { DirectorCommandSchema, encode, HubToVpSchema, isStripText, STRIP_GLYPHS, STRIP_MAX_CODEPOINTS, ThemeOrWorldSchema, type HubToVp } from '../protocol/index.ts';
import { NOTE_ID_RE } from '../scraper/notes.ts';
import type { Scheduler } from '../scheduler.ts';
import type { StatsStore } from '../store.ts';

export interface WebDeps {
  host?: string;
  demo?: boolean;
  port: number;
  card: Card;
  store: StatsStore;
  notesStore: NotesStore;
  covers: CoverStore;
  client: DeviceClient;
  link: DeviceLink;
  serial: SerialManager;
  scheduler: Scheduler;
  logger?: Logger;
}

export interface PanelState {
  demo: boolean;
  now: number;
  profile: { name: string; handle: string; location: string };
  themes: Card['themes'];
  stats: StatsStore['current'];
  history: { ts: number; followers: number }[];
  device: DeviceClient['state'];
  serial: SerialManager['state'];
  scheduler: Scheduler['state'];
  /** Recent-notes fan-out: what the Vision Pro would get from `GET /api/notes`. */
  recentNotes: { rev: number; count: number; updatedAt: string };
  needsLogin: boolean;
  vpClients: number;
  uiClients: number;
  host: string;
}

export interface WebServer {
  start(): Promise<void>;
  stop(): Promise<void>;
  broadcastVp(msg: HubToVp): void;
  broadcastState(): void;
  readonly url: string;
}

const HTML_PATH = path.join(path.dirname(fileURLToPath(import.meta.url)), 'index.html');

export function createWebServer(deps: WebDeps): WebServer {
  const log = deps.logger ?? createLogger('web');
  const uiSockets = new Set<WebSocket>();
  const vpSockets = new Set<WebSocket>();
  let server: HttpServer | null = null;
  let stateTimer: NodeJS.Timeout | null = null;

  const buildState = (): PanelState => ({
    demo: deps.demo === true,
    now: Date.now(),
    profile: { name: deps.card.profile.name, handle: deps.card.profile.handle, location: deps.card.profile.location },
    themes: deps.card.themes,
    stats: deps.store.current,
    history: deps.store.recent(240).map((h) => ({ ts: h.ts, followers: h.followers })),
    device: deps.client.state,
    serial: deps.serial.state,
    scheduler: deps.scheduler.state,
    recentNotes: deps.notesStore.summary,
    needsLogin: deps.scheduler.state.needsLogin,
    vpClients: vpSockets.size,
    uiClients: uiSockets.size,
    host: deps.demo ? 'localhost' : os.hostname(),
  });

  const sendState = (ws: WebSocket) => {
    if (ws.readyState === ws.OPEN) ws.send(JSON.stringify({ t: 'state', state: buildState() }));
  };

  const broadcastState = () => {
    if (stateTimer) return; // coalesce bursts
    stateTimer = setTimeout(() => {
      stateTimer = null;
      for (const ws of uiSockets) sendState(ws);
    }, 50);
  };

  const broadcastVp = (msg: HubToVp) => {
    const parsed = HubToVpSchema.safeParse(msg);
    if (!parsed.success) {
      log.warn(`refusing to broadcast invalid /vp message: ${JSON.stringify(msg)}`);
      return;
    }
    const line = encode(parsed.data).trim();
    for (const ws of vpSockets) if (ws.readyState === ws.OPEN) ws.send(line);
    log.info(`/vp ← ${line} (${vpSockets.size} client${vpSockets.size === 1 ? '' : 's'})`);
    broadcastState();
  };

  const app = new Hono();
  app.get('/', (c) => c.html(fs.readFileSync(HTML_PATH, 'utf8')));
  app.get('/api/state', (c) => c.json(buildState()));
  app.get('/api/health', (c) => c.json({ ok: true }));

  app.post('/api/scrape', async (c) => {
    const rec = await deps.scheduler.runOnce('manual');
    broadcastState();
    return c.json({ ok: rec.status === 'ok', run: rec, stats: deps.store.current }, rec.status === 'ok' ? 200 : 202);
  });

  app.post('/api/simulate', async (c) => {
    const body = (await c.req.json().catch(() => ({}))) as { delta?: unknown };
    const delta = Number(body.delta ?? 1);
    if (!Number.isFinite(delta) || delta < 0 || delta > 100_000) return c.json({ ok: false, error: 'delta must be 0..100000' }, 400);
    const events = await deps.scheduler.simulate(delta);
    broadcastState();
    return c.json({ ok: true, delta: events.followersDelta, stats: deps.store.current, device: deps.client.connected ? 'sent' : 'not connected' });
  });

  app.post('/api/celebrate', async (c) => {
    const body = (await c.req.json().catch(() => ({}))) as { delta?: unknown };
    const current = deps.store.current;
    const delta = Math.max(1, Math.round(Number(body.delta ?? (current.delta || 1))));
    const result = await deps.link.celebrate(delta);
    broadcastVp({ t: 'celebrate', delta, followers: current.followers });
    return c.json({ ok: true, delta, device: result });
  });

  app.post('/api/theme', async (c) => {
    const body = (await c.req.json().catch(() => ({}))) as { theme?: unknown };
    const theme = ThemeOrWorldSchema.safeParse(body.theme);
    if (!theme.success) return c.json({ ok: false, error: 'theme must be base | neon-city | data-nebula' }, 400);
    const result = await deps.link.setTheme(theme.data);
    broadcastVp({ t: 'set_theme', theme: theme.data });
    return c.json({ ok: true, theme: theme.data, device: result, deviceTheme: deps.client.state.theme ?? (isTheme(theme.data) ? theme.data : 'base') });
  });

  /**
   * Director command. On the wire the name lives in `c` — that is the field the Vision Pro decodes —
   * but the request body may spell it `c` or `cmd`. `hide` folds the desk card into the device,
   * `show` brings it back; the accepted names are exactly {@link DirectorCommandSchema}.
   */
  app.post('/api/cmd', async (c) => {
    const body = (await c.req.json().catch(() => ({}))) as { c?: unknown; cmd?: unknown; arg?: unknown };
    const parsed = DirectorCommandSchema.safeParse(body.c ?? body.cmd);
    if (!parsed.success) return c.json({ ok: false, error: `c must be ${DirectorCommandSchema.options.join(' | ')}` }, 400);
    const cmd = parsed.data;
    const arg = body.arg as CmdArg | undefined;
    const result = await deps.link.cmd(cmd, arg);
    broadcastVp(arg === undefined ? { t: 'cmd', c: cmd } : { t: 'cmd', c: cmd, arg });
    return c.json({ ok: true, c: cmd, device: result });
  });

  /**
   * The recent-notes list for the Vision Pro. `coverURL` is relative on purpose: the app already knows
   * the hub's origin from its WebSocket URL, and the covers must go through the proxy below.
   */
  app.get('/api/notes', (c) => {
    const raw = Number(c.req.query('limit') ?? 10);
    const limit = Number.isFinite(raw) ? Math.max(1, Math.min(10, Math.round(raw))) : 10;
    const file = deps.notesStore.current;
    const notes = file.notes.slice(0, limit).map((n) => ({
      id: n.id,
      title: n.title,
      likes: n.likes,
      pinned: n.pinned,
      type: n.type,
      coverURL: NOTE_ID_RE.test(n.id) && (n.coverPath || n.coverSrc) ? `/api/notes/${n.id}/cover` : null,
      url: n.url,
      publishedAt: null,
    }));
    return c.json({ rev: file.rev, updatedAt: file.updatedAt, count: notes.length, notes });
  });

  /**
   * Cover proxy: disk cache first, one upstream fetch per id otherwise (Referer + Chromium UA, 10 s,
   * 3 MB cap, magic-byte sniffing). A note id that is not in the current list is a 404 — which also
   * makes every path-traversal attempt a 404, since `..%2F..` is not a note id.
   */
  app.get('/api/notes/:id/cover', async (c) => {
    const id = c.req.param('id');
    const note = NOTE_ID_RE.test(id) ? deps.notesStore.get(id) : undefined;
    if (!note) return c.json({ ok: false, error: 'unknown note' }, 404);
    const result = await deps.covers.ensure(id, note.coverSrc);
    if (!result.ok) {
      const status = result.reason === 'no-source' ? 404 : 502;
      log.warn(`cover ${id} → ${status} (${result.reason}${result.status ? ` ${result.status}` : ''})`);
      return c.json({ ok: false, error: result.reason, upstream: result.status ?? null }, status);
    }
    const cover = deps.covers.read(id);
    if (!cover) return c.json({ ok: false, error: 'unreadable' }, 502);
    const headers = {
      'content-type': cover.contentType,
      'cache-control': `public, max-age=${COVER_MAX_AGE_S}`,
      etag: cover.etag,
    };
    if (c.req.header('if-none-match') === cover.etag) return c.body(null, 304, headers);
    const bytes = cover.body.buffer.slice(cover.body.byteOffset, cover.body.byteOffset + cover.body.byteLength) as ArrayBuffer;
    return c.body(bytes, 200, { ...headers, 'content-length': String(cover.body.length) });
  });

  /**
   * Bottom-strip override (`♥1825` while a note preview is open; no `text` restores the followers).
   * Validated here so an illegal glyph never reaches the device's 19-glyph strip font.
   */
  app.post('/api/strip', async (c) => {
    const body = (await c.req.json().catch(() => ({}))) as { text?: unknown };
    const text = body.text;
    if (text !== undefined && text !== null && (typeof text !== 'string' || !isStripText(text))) {
      return c.json({ ok: false, error: `text must be 1-${STRIP_MAX_CODEPOINTS} code points from "${STRIP_GLYPHS}"` }, 400);
    }
    const value = typeof text === 'string' ? text : undefined;
    const device = await deps.link.strip(value);
    return c.json({ ok: true, text: value ?? null, connected: deps.client.connected, device });
  });

  // Live backlight A/B for the headset rounds (2026-09-22: object tracking got 5x noisier with the AR level at 85):
  // `{"percent": 100}` sets this AR session's level on the device; the next BLE (re)connect re-applies the Kconfig default.
  app.post('/api/backlight', async (c) => {
    const body = (await c.req.json().catch(() => ({}))) as { percent?: unknown };
    const percent = body.percent;
    if (typeof percent !== 'number' || !Number.isFinite(percent) || percent < 0 || percent > 100) {
      return c.json({ ok: false, error: 'percent must be a number 0-100' }, 400);
    }
    const device = await deps.link.backlight(percent);
    return c.json({ ok: true, percent: Math.round(percent), connected: deps.client.connected, device });
  });

  app.notFound((c) => c.text('not found', 404));

  const url = `http://localhost:${deps.port}`;

  const start = () =>
    new Promise<void>((resolve, reject) => {
      // '::' = dual stack (IPv4 arrives v4-mapped). '0.0.0.0' was IPv4-only, and a headset that resolves the
      // `.local` name to the Mac's AAAA record then gets ECONNREFUSED ("无法连接服务器", round 2, 2026-09-22).
      const s = serve({ fetch: app.fetch, port: deps.port, hostname: deps.host ?? '::' }, (info) => {
        const lan = os.hostname().endsWith('.local') ? os.hostname() : `${os.hostname()}.local`;
        log.info(deps.host === '127.0.0.1' ? `offline panel at ${url} (this Mac only)` : `panel at ${url}  (phone on the same Wi-Fi: http://${lan}:${deps.port})  ws: /ui /vp`);
        // The headset dials a `.local` name, which Bonjour answers with A *and* AAAA records: printing the
        // bound address and the current host name makes an IPv4-only socket (or a renamed `…-2.local`
        // host after a Bonjour name clash) visible in the log instead of only in `netstat`.
        log.info(`bound ${info.address}:${info.port} (${info.family}) as ${os.hostname()}`);
        resolve();
      }) as HttpServer;
      server = s;
      s.on('error', (err: NodeJS.ErrnoException) => {
        if (err.code === 'EADDRINUSE') log.error(`port ${deps.port} is already in use — is another hub running? (PORT=... to change)`);
        reject(err);
      });
      const wssUi = new WebSocketServer({ noServer: true });
      const wssVp = new WebSocketServer({ noServer: true });
      wssUi.on('connection', (ws) => {
        uiSockets.add(ws);
        sendState(ws);
        ws.on('close', () => uiSockets.delete(ws));
        ws.on('error', (err) => {
          uiSockets.delete(ws);
          log.warn(`/ui socket error: ${err.message}`);
        });
        ws.on('message', () => sendState(ws)); // any message = "refresh"
      });
      wssVp.on('connection', (ws, req) => {
        vpSockets.add(ws);
        log.info(`/vp client connected from ${req.socket.remoteAddress ?? '?'} (${vpSockets.size} connected)`);
        ws.on('close', (code, reason) => {
          vpSockets.delete(ws);
          const why = reason?.length ? `code ${code}, ${reason.toString()}` : `code ${code}`;
          log.info(`/vp client disconnected (${why}; ${vpSockets.size} left)`);
          broadcastState();
        });
        ws.on('error', (err) => {
          vpSockets.delete(ws);
          log.warn(`/vp socket error: ${err.message}`);
        });
        broadcastState();
      });
      /**
       * Every upgrade is logged before it is answered. When the headset says 「无法连接服务器」 the first
       * question is whether its attempts reach this process at all — silence here means they never did
       * (name resolved elsewhere, wrong address family, firewall), a line here means they did.
       */
      s.on('upgrade', (req: IncomingMessage, socket, head) => {
        const pathname = new URL(req.url ?? '/', 'http://localhost').pathname;
        const from = req.socket.remoteAddress ?? '?';
        if (pathname === '/ui') {
          log.debug(`/ui upgrade from ${from}`);
          wssUi.handleUpgrade(req, socket, head, (ws) => wssUi.emit('connection', ws, req));
        } else if (pathname === '/vp') {
          log.info(`/vp upgrade from ${from}`);
          wssVp.handleUpgrade(req, socket, head, (ws) => wssVp.emit('connection', ws, req));
        } else {
          log.warn(`refused a WebSocket upgrade to ${pathname} from ${from} (only /ui and /vp exist)`);
          socket.destroy();
        }
      });
    });

  const stop = () =>
    new Promise<void>((resolve) => {
      for (const ws of [...uiSockets, ...vpSockets]) ws.close();
      uiSockets.clear();
      vpSockets.clear();
      if (!server) return resolve();
      server.close(() => resolve());
      server.closeAllConnections?.();
      server = null;
    });

  return { start, stop, broadcastVp, broadcastState, url };
}
