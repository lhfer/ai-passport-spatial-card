/**
 * Composition root: wires config → store → device (serial) → link → scheduler → web server.
 * Used by every CLI command; `web` / `serial` can be switched off for one-shot commands.
 */
import path from 'node:path';
import { avatarPath, loadCard, type Card, type HubEnv } from './config.ts';
import { DeviceClient } from './device/client.ts';
import { DeviceLink } from './device/link.ts';
import { SerialManager } from './device/serial.ts';
import { CoverStore } from './covers.ts';
import { createLogger, type Logger } from './log.ts';
import { NotesStore } from './notes-store.ts';
import type { HubToVp } from './protocol/index.ts';
import { Scheduler } from './scheduler.ts';
import { scrapeProfile, type ScrapeResult } from './scraper/xhs.ts';
import { seedFromCard, StatsStore } from './store.ts';
import { createWebServer, type WebServer } from './web/server.ts';

export interface AppOptions {
  host?: string;
  demo?: boolean;
  web?: boolean;
  serial?: boolean;
  /** Test hook: replaces the Playwright scraper. */
  scrape?: () => Promise<ScrapeResult>;
  logger?: Logger;
}

export interface App {
  env: HubEnv;
  card: Card;
  store: StatsStore;
  notesStore: NotesStore;
  covers: CoverStore;
  client: DeviceClient;
  link: DeviceLink;
  serial: SerialManager;
  scheduler: Scheduler;
  web: WebServer | null;
  log: Logger;
  paths: { stats: string; profile: string; failures: string; avatar: string; probe: string; notes: string; covers: string };
  start(): Promise<void>;
  stop(): Promise<void>;
  /** Resolves true when the device is connected within `ms` (false otherwise; never throws). */
  waitForDevice(ms: number): Promise<boolean>;
}

export function createApp(env: HubEnv, opts: AppOptions = {}): App {
  const log = opts.logger ?? createLogger('hub');
  const card = loadCard(env.cardPath);
  const paths = {
    stats: path.join(env.dataDir, 'stats.json'),
    profile: path.join(env.dataDir, 'profile'),
    failures: path.join(env.dataDir, 'failures'),
    avatar: avatarPath(card, env.cardPath),
    probe: path.join(env.dataDir, 'probe'),
    notes: path.join(env.dataDir, 'notes.json'),
    covers: path.join(env.dataDir, 'covers'),
  };
  const store = new StatsStore(paths.stats, seedFromCard(card.stats));
  const notesStore = new NotesStore(paths.notes);
  const covers = new CoverStore({ dir: paths.covers, logger: log.child('covers') });
  const client = new DeviceClient({ logger: log.child('device') });
  const link = new DeviceLink(client, log.child('link'));
  const serial = new SerialManager(client, { logger: log.child('serial') });
  let web: WebServer | null = null;
  const broadcastVp = (msg: HubToVp) => web?.broadcastVp(msg);
  const scheduler = new Scheduler(
    {
      scrape: opts.scrape ?? (() => scrapeProfile({ userId: card.xhs.userId, profileDir: paths.profile, failuresDir: paths.failures, headed: env.headed, dump: env.debug, covers, author: card.profile.name, logger: log.child('xhs') })),
      store,
      notesStore,
      link,
      broadcastVp,
      onChange: () => web?.broadcastState(),
    },
    { intervalMin: env.scrapeIntervalMin, quietHours: env.quietHours, logger: log.child('scheduler') },
  );
  if (opts.web !== false) web = createWebServer({ demo: opts.demo === true, ...(opts.host ? { host: opts.host } : {}), port: env.port, card, store, notesStore, covers, client, link, serial, scheduler, logger: log.child('web') });
  client.on('hello', (h) => void scheduler.resyncDevice(h).catch((e) => log.warn(`stats re-push after hello failed: ${String(e)}`)));
  // …and the other half of the same job: a device that answers the handshake but never sends a `hello`
  // line leaves the hub blind, so the scheduler asks again 2 s after `ready` and pushes if need be.
  scheduler.watchDevice(client);
  client.on('state', () => web?.broadcastState());
  client.on('button', (b) => log.info(`device button ${b.btn} ${b.ev}`));
  client.on('ble', (b) => log.info(`device BLE ${b.connected ? 'connected (AR mode)' : 'disconnected (idle mode)'}`));

  return {
    env,
    card,
    store,
    notesStore,
    covers,
    client,
    link,
    serial,
    scheduler,
    web,
    log,
    paths,
    async start() {
      if (opts.serial !== false) serial.start();
      if (web) await web.start();
    },
    async stop() {
      scheduler.stop();
      await serial.stop();
      if (web) await web.stop();
    },
    waitForDevice(ms: number) {
      return new Promise<boolean>((resolve) => {
        if (client.connected) return resolve(true);
        const timer = setTimeout(() => {
          client.off('connect', onConnect);
          resolve(false);
        }, ms);
        const onConnect = () => {
          clearTimeout(timer);
          resolve(true);
        };
        client.once('connect', onConnect);
      });
    },
  };
}
