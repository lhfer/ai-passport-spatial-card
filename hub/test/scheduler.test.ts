import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { DeviceClient } from '../src/device/client.ts';
import { DeviceLink } from '../src/device/link.ts';
import { MockTransport } from '../src/device/transport.ts';
import { silentLogger, type Logger } from '../src/log.ts';
import type { HubToVp } from '../src/protocol/index.ts';
import { NotesStore } from '../src/notes-store.ts';
import { isQuietHour, msUntilQuietEnd, Scheduler } from '../src/scheduler.ts';
import type { RecentNote } from '../src/scraper/notes.ts';
import type { ScrapeResult } from '../src/scraper/xhs.ts';
import { StatsStore } from '../src/store.ts';

let dir: string;
beforeEach(() => (dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hub-sched-'))));
afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

const seed = { followers: 4313, likes: 44000, notes: 0, ts: 1, source: 'seed' };

function setup(results: ScrapeResult[], withDevice = false, withNotes = false) {
  const store = new StatsStore(path.join(dir, 'stats.json'), seed);
  const notesStore = withNotes ? new NotesStore(path.join(dir, 'notes.json')) : undefined;
  const client = new DeviceClient({ logger: silentLogger });
  const link = new DeviceLink(client, silentLogger);
  const deviceLines: Record<string, unknown>[] = [];
  let attach: Promise<void> = Promise.resolve();
  if (withDevice) {
    const { hub, device } = MockTransport.pair();
    device.onLine((line) => {
      const m = JSON.parse(line);
      deviceLines.push(m);
      device.send(`{"t":"ack","id":"${m.id}","ok":true}\n`);
    });
    attach = client.attach(hub);
  }
  const vp: HubToVp[] = [];
  let changes = 0;
  const scheduler = new Scheduler(
    { scrape: async () => results.shift() ?? { status: 'error', message: 'no more fixtures' }, store, notesStore, link, broadcastVp: (m) => vp.push(m), onChange: () => changes++ },
    { intervalMin: 45, jitterMin: 10, quietHours: { start: 2, end: 7 }, logger: silentLogger, random: () => 0.5 },
  );
  return { store, notesStore, client, link, scheduler, vp, deviceLines, attach, changes: () => changes };
}

describe('quiet hours', () => {
  it('detects the 02-07 window and wrap-around windows', () => {
    const q = { start: 2, end: 7 };
    expect(isQuietHour(new Date(2026, 8, 18, 3, 0), q)).toBe(true);
    expect(isQuietHour(new Date(2026, 8, 18, 7, 0), q)).toBe(false);
    expect(isQuietHour(new Date(2026, 8, 18, 1, 59), q)).toBe(false);
    expect(isQuietHour(new Date(2026, 8, 18, 23, 30), { start: 23, end: 6 })).toBe(true);
    expect(isQuietHour(new Date(2026, 8, 18, 5, 30), { start: 23, end: 6 })).toBe(true);
    expect(isQuietHour(new Date(2026, 8, 18, 12, 0), { start: 23, end: 6 })).toBe(false);
  });

  it('computes the time until the window ends', () => {
    expect(msUntilQuietEnd(new Date(2026, 8, 18, 3, 0), { start: 2, end: 7 })).toBe(4 * 3600_000);
    expect(msUntilQuietEnd(new Date(2026, 8, 18, 12, 0), { start: 2, end: 7 })).toBe(0);
    expect(msUntilQuietEnd(new Date(2026, 8, 18, 23, 30), { start: 23, end: 1 })).toBe(90 * 60_000);
  });
});

describe('Scheduler.computeNextDelayMs', () => {
  it('stays within interval ± jitter outside quiet hours', () => {
    const { scheduler } = setup([]);
    for (const r of [0, 0.25, 0.5, 0.99]) {
      const s = new Scheduler(
        { scrape: async () => ({ status: 'error', message: 'x' }), store: new StatsStore(path.join(dir, 's.json'), seed), link: scheduler['deps'].link, broadcastVp: () => {} },
        { intervalMin: 45, jitterMin: 10, quietHours: { start: 2, end: 7 }, logger: silentLogger, random: () => r },
      );
      const delayMin = s.computeNextDelayMs(new Date(2026, 8, 18, 12, 0)) / 60_000;
      expect(delayMin).toBeGreaterThanOrEqual(35);
      expect(delayMin).toBeLessThanOrEqual(55);
    }
  });

  it('pushes runs that would land in quiet hours past the window', () => {
    const { scheduler } = setup([]);
    const from = new Date(2026, 8, 18, 1, 40); // 01:40 + 45 min = 02:25 → quiet → after 07:00
    const delay = scheduler.computeNextDelayMs(from);
    const target = new Date(from.getTime() + delay);
    expect(target.getHours()).toBeGreaterThanOrEqual(7);
    expect(target.getHours()).toBeLessThan(8);
  });
});

describe('Scheduler.runOnce / simulate', () => {
  it('records a successful scrape and propagates stats + celebrate on growth', async () => {
    const { scheduler, store, vp, deviceLines, attach } = setup([{ status: 'ok', followers: 4318, likes: 44012, notes: 128, url: 'u', layout: 'number-first' }], true);
    await attach;
    const rec = await scheduler.runOnce('cli');
    expect(rec).toMatchObject({ status: 'ok', delta: 5, source: 'cli' });
    expect(store.current).toMatchObject({ followers: 4318, likes: 44012, notes: 128, delta: 5, source: 'scrape' });
    const types = deviceLines.map((m) => m['t']);
    expect(types).toEqual(['hello', 'stats', 'celebrate']);
    expect(deviceLines[1]).toMatchObject({ followers: 4318, delta: 5 });
    expect(deviceLines[2]).toMatchObject({ delta: 5 });
    expect(vp).toEqual([
      { t: 'stats', followers: 4318, likes: 44012, notes: 128, delta: 5, ts: store.current.ts },
      { t: 'celebrate', delta: 5, followers: 4318 },
    ]);
    expect(scheduler.state.needsLogin).toBe(false);
  });

  it('flags needsLogin without touching the stats', async () => {
    const { scheduler, store, vp } = setup([{ status: 'needsLogin', url: 'u', message: 'wall' }]);
    const before = JSON.stringify(store.current);
    const rec = await scheduler.runOnce('manual');
    expect(rec.status).toBe('needsLogin');
    expect(scheduler.state.needsLogin).toBe(true);
    expect(JSON.stringify(store.current)).toBe(before);
    expect(vp).toEqual([]);
    // a later good scrape clears the flag
    await scheduler.runOnce('manual'); // no fixture → error
    expect(scheduler.state.needsLogin).toBe(true);
  });

  it('simulate(+5) works without a device and celebrates', async () => {
    const { scheduler, store, vp } = setup([]);
    const events = await scheduler.simulate(5);
    expect(events).toMatchObject({ followersDelta: 5, statsChanged: true });
    expect(store.current).toMatchObject({ followers: 4318, delta: 5, source: 'manual' });
    expect(vp.map((m) => m.t)).toEqual(['stats', 'celebrate']);
  });

  it('does not celebrate when nothing changed', async () => {
    const { scheduler, vp } = setup([{ status: 'ok', followers: 4313, likes: 44000, notes: null, url: 'u', layout: 'number-first' }]);
    const rec = await scheduler.runOnce();
    expect(rec).toMatchObject({ status: 'ok', delta: 0 });
    expect(vp).toEqual([]);
  });

  it('refuses overlapping runs', async () => {
    let resolve!: (r: ScrapeResult) => void;
    const store = new StatsStore(path.join(dir, 'stats.json'), seed);
    const link = new DeviceLink(new DeviceClient({ logger: silentLogger }), silentLogger);
    const scheduler = new Scheduler(
      { scrape: () => new Promise<ScrapeResult>((r) => (resolve = r)), store, link, broadcastVp: () => {} },
      { intervalMin: 45, quietHours: { start: 2, end: 7 }, logger: silentLogger },
    );
    const first = scheduler.runOnce();
    const second = await scheduler.runOnce();
    expect(second.status).toBe('error');
    resolve({ status: 'ok', followers: 4400, likes: null, notes: null, url: 'u', layout: 'label-first' });
    expect((await first).status).toBe('ok');
  });
});

const note = (id: string, likes: number, over: Partial<RecentNote> = {}): RecentNote => ({
  id,
  title: `笔记 ${id.slice(0, 4)}`,
  likes,
  pinned: false,
  hidden: false,
  type: 'normal',
  coverSrc: `http://cdn.example/${id}`,
  coverPath: null,
  url: `https://www.xiaohongshu.com/user/profile/6510000000000000000000ff/${id}?xsec_token=TEST`,
  order: 0,
  ...over,
});

const A = '6a11111111111111111111a1';
const B = '6a22222222222222222222b2';

describe('Scheduler.applyRecentNotes', () => {
  it('stores the list and hints /vp once per revision', () => {
    const { scheduler, notesStore, vp } = setup([], false, true);
    expect(scheduler.applyRecentNotes([note(A, 1), note(B, 2)])).toMatchObject({ changed: true, rev: 1, count: 2 });
    expect(vp).toEqual([{ t: 'notes', rev: 1, count: 2 }]);
    expect(notesStore!.summary).toMatchObject({ rev: 1, count: 2 });

    // same list again (only the token rotated) → no rev, no hint
    expect(scheduler.applyRecentNotes([note(A, 1, { url: 'https://x/?xsec_token=ROTATED' }), note(B, 2)])).toMatchObject({ changed: false, rev: 1 });
    expect(vp).toHaveLength(1);

    expect(scheduler.applyRecentNotes([note(A, 9), note(B, 2)])).toMatchObject({ changed: true, rev: 2 });
    expect(vp).toEqual([
      { t: 'notes', rev: 1, count: 2 },
      { t: 'notes', rev: 2, count: 2 },
    ]);
  });

  it('is a no-op without a notes store', () => {
    const { scheduler, vp } = setup([]);
    expect(scheduler.applyRecentNotes([note(A, 1)])).toMatchObject({ changed: false });
    expect(vp).toEqual([]);
  });

  it('applies the notes a scrape brought along, after stats and celebrate', async () => {
    const { scheduler, notesStore, vp } = setup(
      [{ status: 'ok', followers: 4318, likes: 44012, notes: 128, url: 'u', layout: 'number-first', recentNotes: [note(A, 1)], notesSource: 'dom' }],
      false,
      true,
    );
    await scheduler.runOnce('cli');
    expect(notesStore!.summary).toMatchObject({ rev: 1, count: 1 });
    expect(vp.map((m) => m.t)).toEqual(['stats', 'celebrate', 'notes']);
  });

  it('leaves the stored notes alone when a scrape could not read the grid', async () => {
    const { scheduler, notesStore, vp } = setup([{ status: 'ok', followers: 4400, likes: null, notes: null, url: 'u', layout: 'number-first' }], false, true);
    notesStore!.update([note(A, 1)], 'seed');
    await scheduler.runOnce('cli');
    expect(notesStore!.summary).toMatchObject({ rev: 1, count: 1 });
    expect(vp.every((m) => m.t !== 'notes')).toBe(true);
  });
});

describe('Scheduler.resyncDevice', () => {
  it('re-pushes the hub stats when a device hello shows a different count (NVS reset after a flash)', async () => {
    const { scheduler, store, deviceLines, attach } = setup([{ status: 'ok', followers: 4401, likes: 45000, notes: 248, url: 'u', layout: 'number-first' }], true);
    await attach;
    await scheduler.runOnce('cli');
    expect(store.current.followers).toBe(4401);
    const before = deviceLines.length;
    // The device rebooted with the seed count on its LCD.
    const pushed = await scheduler.resyncDevice({ stats: { followers: 4313, likes: 44000, notes: 0 } });
    expect(pushed).toBe(true);
    expect(deviceLines.slice(before).map((m) => m['t'])).toEqual(['stats']);
    expect(deviceLines[before]).toMatchObject({ followers: 4401, likes: 45000, notes: 248 });
  });

  it('does nothing when the hello agrees with the hub, or carries no stats', async () => {
    const { scheduler, store, deviceLines, attach } = setup([], true);
    await attach;
    const before = deviceLines.length;
    expect(await scheduler.resyncDevice({ stats: { followers: store.current.followers, likes: store.current.likes, notes: store.current.notes } })).toBe(false);
    expect(await scheduler.resyncDevice({ stats: null })).toBe(false);
    expect(await scheduler.resyncDevice({})).toBe(false);
    expect(deviceLines.length).toBe(before);
  });
});

/**
 * The `ready` fallback. A device that answers the handshake but never sends a `hello` line (2026-09-22:
 * `hello acknowledged` without `(fw …)`, `/api/state` with no stats) used to keep a stale follower count
 * forever, because `resyncDevice` only ever ran on a hello.
 */
const READY_DELAY_MS = 20;
/** What the LCD is showing, always the seed count — the hub's own number is set per test. */
const DEVICE_HELLO =
  '{"t":"hello","fw":"0.2.1","boot":7,"mode":"idle","theme":"base","stats":{"followers":4313,"likes":44000,"notes":0,"delta":0,"ts":1758150000},"battery":{"soc":88,"mv":4060},"ble":{"connected":false},"heap":181240}\n';

/**
 * Wires a scheduler + client exactly like `createApp` does, behind a scripted firmware that either
 * answers a `hello` command with a `hello` line + `ack` (`sendsHello`) or with the `ack` alone.
 */
function readySetup(opts: { sendsHello: boolean | 'afterFirst'; hubFollowers?: number; delayMs?: number }) {
  const store = new StatsStore(path.join(dir, 'stats.json'), seed); // 4313 / 44000 / 0
  if (opts.hubFollowers !== undefined) store.record({ followers: opts.hubFollowers, likes: seed.likes, notes: seed.notes, ts: seed.ts + 1, source: 'test' });
  const client = new DeviceClient({ logger: silentLogger, ackTimeoutMs: 200 });
  const link = new DeviceLink(client, silentLogger);
  const logs: string[] = [];
  const logger: Logger = { ...silentLogger, info: (m) => logs.push(m), child: () => logger };
  const scheduler = new Scheduler(
    { scrape: async () => ({ status: 'error', message: 'no fixture' }), store, link, broadcastVp: () => {} },
    { intervalMin: 45, quietHours: { start: 2, end: 7 }, logger, readyResyncDelayMs: opts.delayMs ?? READY_DELAY_MS },
  );
  const { hub, device } = MockTransport.pair();
  const deviceLines: Record<string, unknown>[] = [];
  let helloCommands = 0;
  device.onLine((line) => {
    const m = JSON.parse(line) as Record<string, unknown>;
    deviceLines.push(m);
    // `afterFirst` is the round-3 failure itself: the handshake gets an ack only, a later ask is answered.
    if (m['t'] === 'hello' && (opts.sendsHello === true || (opts.sendsHello === 'afterFirst' && ++helloCommands > 1))) device.send(DEVICE_HELLO);
    device.send(`{"t":"ack","id":"${String(m['id'])}","ok":true}\n`);
  });
  // The production wiring from src/app.ts, in the same order.
  client.on('hello', (h) => void scheduler.resyncDevice(h));
  scheduler.watchDevice(client);
  return { store, client, scheduler, logs, deviceLines, attach: client.attach(hub) };
}

const settle = (ms = READY_DELAY_MS * 8) => new Promise((r) => setTimeout(r, ms));

describe('Scheduler ready fallback', () => {
  it('asks once more and pushes the hub stats when the device never sends a hello', async () => {
    const { client, logs, deviceLines, attach } = readySetup({ sendsHello: false, hubFollowers: 4401 });
    await attach;
    expect(client.state.ready).toBe(true);
    expect(client.state.stats).toBeUndefined(); // exactly what /api/state showed on 2026-09-22
    await settle();
    expect(deviceLines.map((m) => m['t'])).toEqual(['hello', 'hello', 'stats']);
    expect(deviceLines[2]).toMatchObject({ followers: 4401, likes: 44000, notes: 0 });
    expect(logs).toContain('device stats unknown after ready → asking again');
    expect(logs).toContain('device stats unknown after ready → re-pushing');
    client.detach();
  });

  it('stays quiet when the hello agrees with the hub', async () => {
    const { client, logs, deviceLines, attach } = readySetup({ sendsHello: true });
    await attach;
    expect(client.state.stats).toMatchObject({ followers: 4313 });
    await settle();
    expect(deviceLines.map((m) => m['t'])).toEqual(['hello']);
    expect(logs.some((l) => l.includes('after ready'))).toBe(false);
    client.detach();
  });

  it('pushes exactly once when the hello disagrees — the hello path, with the fallback standing down', async () => {
    const { client, logs, deviceLines, attach } = readySetup({ sendsHello: true, hubFollowers: 4401 });
    await attach;
    await settle();
    expect(deviceLines.map((m) => m['t'])).toEqual(['hello', 'stats']);
    expect(deviceLines[1]).toMatchObject({ followers: 4401 });
    expect(logs).toContain('device hello shows 4313 followers, hub has 4401 → re-pushing stats');
    expect(logs.some((l) => l.includes('after ready'))).toBe(false);
    client.detach();
  });

  it('pushes once when the re-asked hello finally arrives and disagrees', async () => {
    const { client, logs, deviceLines, attach } = readySetup({ sendsHello: 'afterFirst', hubFollowers: 4401 });
    await attach;
    expect(client.state.stats).toBeUndefined();
    await settle();
    expect(deviceLines.map((m) => m['t'])).toEqual(['hello', 'hello', 'stats']);
    expect(logs).toContain('device stats unknown after ready → asking again');
    expect(logs).toContain('device hello shows 4313 followers, hub has 4401 → re-pushing stats');
    expect(logs).not.toContain('device stats mismatch after ready → re-pushing'); // the fallback stood down
    client.detach();
  });

  it('stands down when a scrape already pushed inside the grace period', async () => {
    const { scheduler, client, deviceLines, logs, attach } = readySetup({ sendsHello: false, delayMs: 5000 });
    await attach;
    await scheduler.simulate(88); // the device is silent, but it *was* just told the new count
    expect(deviceLines.map((m) => m['t'])).toEqual(['hello', 'stats', 'celebrate']);
    expect(await scheduler.resyncAfterReady(client)).toBe('synced');
    expect(deviceLines.map((m) => m['t'])).toEqual(['hello', 'stats', 'celebrate']);
    expect(logs.some((l) => l.includes('after ready'))).toBe(false);
    client.detach();
  });

  it('does not trust what an earlier connection reported', async () => {
    const { client, scheduler, logs, deviceLines, attach } = readySetup({ sendsHello: true, delayMs: 5000 });
    await attach;
    expect(client.state.stats).toMatchObject({ followers: 4313 }); // agrees with the hub
    client.detach();
    // The device comes back and, like on 2026-09-22, answers the handshake without a `hello` line.
    const { hub, device } = MockTransport.pair();
    let helloCommands = 0;
    device.onLine((line) => {
      const m = JSON.parse(line) as Record<string, unknown>;
      deviceLines.push(m);
      if (m['t'] === 'hello' && ++helloCommands > 1) device.send(DEVICE_HELLO); // only the second ask answers
      device.send(`{"t":"ack","id":"${String(m['id'])}","ok":true}\n`);
    });
    await client.attach(hub);
    expect(client.state.stats).toMatchObject({ followers: 4313 }); // stale: nothing was reported this time
    expect(await scheduler.resyncAfterReady(client)).toBe('synced');
    expect(logs).toContain('device stats unknown after ready → asking again'); // asked instead of believing it
    expect(deviceLines.map((m) => m['t'])).toEqual(['hello', 'hello', 'hello']); // and no needless push
    client.detach();
  });
});
