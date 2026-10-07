/**
 * Scrape scheduler + event propagation. Runs a scrape every SCRAPE_INTERVAL_MIN ± 10 min
 * (never inside quiet hours), records the sample and, when followers went up, pushes
 * `stats` + `celebrate` to the device and broadcasts to Vision Pro over /vp.
 * `runOnce()` is shared by the CLI and the panel's 刷新 button; `simulate(delta)` by 模拟新粉丝.
 */
import { createLogger, type Logger } from './log.ts';
import type { QuietHours } from './config.ts';
import type { DeviceClient, DeviceState } from './device/client.ts';
import type { DeviceLink } from './device/link.ts';
import type { NotesStore } from './notes-store.ts';
import type { HubToVp, StatsFields } from './protocol/index.ts';
import type { RecentNote } from './scraper/notes.ts';
import type { ScrapeResult } from './scraper/xhs.ts';
import { nowSeconds, type RecordEvents, type RecordInput, type StatsStore } from './store.ts';

export interface RunRecord {
  startedAt: number;
  finishedAt: number;
  status: 'ok' | 'needsLogin' | 'error';
  message?: string;
  source: string;
  delta?: number;
}

export interface SchedulerState {
  running: boolean;
  busy: boolean;
  needsLogin: boolean;
  lastRun?: RunRecord;
  nextRunAt?: number;
  intervalMin: number;
  jitterMin: number;
  quietHours: QuietHours;
}

export interface SchedulerOptions {
  intervalMin: number;
  jitterMin?: number;
  quietHours: QuietHours;
  logger?: Logger;
  now?: () => Date;
  random?: () => number;
  /** Grace period between `ready` and the stats fallback (and between its re-hello and the push). */
  readyResyncDelayMs?: number;
}

/** How {@link Scheduler.resyncAfterReady} ended: the device agreed, was asked again, or got a push. */
export type ReadyResyncResult = 'synced' | 'pushed' | 'skipped';

export const DEFAULT_READY_RESYNC_MS = 2000;

export interface SchedulerDeps {
  scrape: () => Promise<ScrapeResult>;
  store: StatsStore;
  /** Optional: without it a scrape's `recentNotes` are simply dropped. */
  notesStore?: NotesStore | undefined;
  link: DeviceLink;
  broadcastVp: (msg: HubToVp) => void;
  /** Called whenever scheduler state or stats changed (the web server pushes to /ui). */
  onChange?: () => void;
}

export function isQuietHour(date: Date, q: QuietHours): boolean {
  const h = date.getHours();
  if (q.start === q.end) return false;
  return q.start < q.end ? h >= q.start && h < q.end : h >= q.start || h < q.end;
}

/** Milliseconds until quiet hours end (0 when not in quiet hours). */
export function msUntilQuietEnd(date: Date, q: QuietHours): number {
  if (!isQuietHour(date, q)) return 0;
  const end = new Date(date);
  end.setHours(q.end % 24, 0, 0, 0);
  if (end.getTime() <= date.getTime()) end.setDate(end.getDate() + 1);
  return end.getTime() - date.getTime();
}

export class Scheduler {
  private timer: NodeJS.Timeout | null = null;
  private _state: SchedulerState;
  private readonly log: Logger;
  private readonly now: () => Date;
  private readonly random: () => number;
  private readonly readyResyncDelayMs: number;
  /** Bumped on every device connection: everything the hub knows about the device is scoped to one. */
  private deviceGen = 0;
  /** The generation whose `hello` line arrived (device state from an older connection is stale). */
  private helloGen = -1;
  /** The generation whose stats the hub has (re-)pushed; set when a push starts, rolled back if it failed. */
  private syncedGen = -1;
  private readyTimer: NodeJS.Timeout | null = null;
  private unwatchDevice: (() => void) | null = null;

  constructor(
    private readonly deps: SchedulerDeps,
    opts: SchedulerOptions,
  ) {
    this.log = opts.logger ?? createLogger('scheduler');
    this.now = opts.now ?? (() => new Date());
    this.random = opts.random ?? Math.random;
    this.readyResyncDelayMs = opts.readyResyncDelayMs ?? DEFAULT_READY_RESYNC_MS;
    this._state = {
      running: false,
      busy: false,
      needsLogin: false,
      intervalMin: opts.intervalMin,
      jitterMin: opts.jitterMin ?? 10,
      quietHours: opts.quietHours,
    };
  }

  get state(): SchedulerState {
    return this._state;
  }

  private patch(p: Partial<SchedulerState>): void {
    this._state = { ...this._state, ...p };
    this.deps.onChange?.();
  }

  /** Delay for the next scheduled run: interval ± jitter, pushed past quiet hours. */
  computeNextDelayMs(from: Date = this.now()): number {
    const jitter = (this.random() * 2 - 1) * this._state.jitterMin;
    const minutes = Math.max(1, this._state.intervalMin + jitter);
    let delay = Math.round(minutes * 60_000);
    const target = new Date(from.getTime() + delay);
    const quiet = msUntilQuietEnd(target, this._state.quietHours);
    if (quiet > 0) delay += quiet + Math.round(this.random() * this._state.jitterMin * 60_000);
    return delay;
  }

  start(): void {
    if (this._state.running) return;
    this.patch({ running: true });
    this.scheduleNext();
  }

  stop(): void {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.unwatchDevice?.();
    this.patch({ running: false });
    this._state = { ...this._state };
    delete this._state.nextRunAt;
  }

  private scheduleNext(): void {
    if (!this._state.running) return;
    if (this.timer) clearTimeout(this.timer);
    const delay = this.computeNextDelayMs();
    const nextRunAt = Date.now() + delay;
    this.timer = setTimeout(() => {
      this.timer = null;
      void this.runOnce('scheduled').finally(() => this.scheduleNext());
    }, delay);
    this.timer.unref?.();
    this.patch({ nextRunAt });
    this.log.info(`next scrape in ${Math.round(delay / 60_000)} min (${new Date(nextRunAt).toLocaleTimeString('zh-CN', { hour12: false })})`);
  }

  /** Scrapes now (unless a run is in progress), records and propagates. */
  async runOnce(source: 'scheduled' | 'manual' | 'cli' = 'manual'): Promise<RunRecord> {
    if (this._state.busy) {
      const rec: RunRecord = { startedAt: Date.now(), finishedAt: Date.now(), status: 'error', message: '已有抓取在进行中', source };
      return rec;
    }
    const startedAt = Date.now();
    this.patch({ busy: true });
    let rec: RunRecord;
    try {
      const result = await this.deps.scrape();
      if (result.status === 'ok') {
        const events = await this.applySample({ followers: result.followers, likes: result.likes, notes: result.notes, ts: nowSeconds(), source: 'scrape' });
        if (result.recentNotes !== undefined) this.applyRecentNotes(result.recentNotes, result.notesSource ?? 'scrape');
        rec = { startedAt, finishedAt: Date.now(), status: 'ok', source, delta: events.followersDelta, message: `followers=${events.current.followers} (+${events.followersDelta})` };
        this.patch({ needsLogin: false, lastRun: rec });
      } else if (result.status === 'needsLogin') {
        rec = { startedAt, finishedAt: Date.now(), status: 'needsLogin', source, message: result.message };
        this.log.warn(`needsLogin: ${result.message}`);
        this.patch({ needsLogin: true, lastRun: rec });
      } else {
        rec = { startedAt, finishedAt: Date.now(), status: 'error', source, message: result.message };
        this.log.error(`scrape error: ${result.message}`);
        this.patch({ lastRun: rec });
      }
    } catch (err) {
      rec = { startedAt, finishedAt: Date.now(), status: 'error', source, message: (err as Error).message };
      this.patch({ lastRun: rec });
    } finally {
      this.patch({ busy: false });
    }
    return rec;
  }

  /** Manual "+N followers" from the panel: same propagation path as a real scrape. */
  /**
   * A device `hello` carries the count its LCD is showing. After a firmware flash (the merged image resets
   * NVS) that count falls back to the seed while the hub still holds the real one — and `applySample` only
   * pushes on a *change of the hub's own sample*, so nothing would ever correct the screen until the next real
   * follower. This re-pushes the hub's current stats whenever a hello disagrees with them.
   */
  async resyncDevice(hello: { stats?: { followers?: number; likes?: number; notes?: number } | null | undefined }): Promise<boolean> {
    const shown = hello.stats;
    if (!shown || typeof shown.followers !== 'number') return false;
    const cur = this.deps.store.current;
    const same = shown.followers === cur.followers && (shown.likes === undefined || shown.likes === cur.likes) && (shown.notes === undefined || shown.notes === cur.notes);
    if (same) return false;
    this.log.info(`device hello shows ${shown.followers} followers, hub has ${cur.followers} → re-pushing stats`);
    await this.pushStatsToDevice(this.deps.store.toStatsFields());
    return true;
  }

  // -----------------------------------------------------------------------------------------------
  // `ready` fallback
  //
  // `resyncDevice` above only ever runs on a device `hello`. On 2026-09-22 a hub restart got an `ack`
  // but no `hello` line back (`hello acknowledged by /dev/cu.usbmodem101` with no `(fw …)`, `/api/state`
  // with no fw/stats) — so the hub never learned what the LCD was showing and the screen kept the old
  // follower count all evening. This watches for that silence: 2 s after the handshake, a device that
  // has not reported its stats is asked for a `hello` once more, and if it still says nothing (or still
  // disagrees) the hub pushes its own numbers.
  // -----------------------------------------------------------------------------------------------

  /**
   * Subscribes to a device client and arms {@link resyncAfterReady} on every fresh handshake.
   * Returns (and remembers, so `stop()` calls it) a disposer.
   */
  watchDevice(client: DeviceClient): () => void {
    this.unwatchDevice?.();
    let connected = false;
    let ready = false;
    const onState = (s: DeviceState) => {
      if (s.connected && !connected) this.deviceGen++; // a new link: fw/stats from the old one are stale
      connected = s.connected;
      if (!s.connected || !s.ready) {
        if (ready) this.cancelReadyResync();
        ready = false;
        return;
      }
      if (!ready) {
        ready = true;
        this.armReadyResync(client);
      }
    };
    const onHello = () => (this.helloGen = this.deviceGen);
    client.on('state', onState);
    client.on('hello', onHello);
    const dispose = () => {
      client.off('state', onState);
      client.off('hello', onHello);
      this.cancelReadyResync();
      if (this.unwatchDevice === dispose) this.unwatchDevice = null;
    };
    this.unwatchDevice = dispose;
    return dispose;
  }

  private armReadyResync(client: DeviceClient): void {
    this.cancelReadyResync();
    const gen = this.deviceGen;
    this.readyTimer = setTimeout(() => {
      this.readyTimer = null;
      void this.resyncAfterReady(client, gen).catch((e) => this.log.warn(`stats fallback after ready failed: ${String(e)}`));
    }, this.readyResyncDelayMs);
    this.readyTimer.unref?.();
  }

  private cancelReadyResync(): void {
    if (this.readyTimer) clearTimeout(this.readyTimer);
    this.readyTimer = null;
  }

  /**
   * The fallback itself (armed by {@link watchDevice}, callable directly in tests): asks a silent device
   * for one more `hello` and pushes the hub's stats when the answer is still missing or still disagrees.
   * A push already made for this connection — by the `hello` path or by a scrape — makes it stand down,
   * so the device never gets the same correction twice.
   */
  async resyncAfterReady(client: DeviceClient, gen = this.deviceGen): Promise<ReadyResyncResult> {
    if (!client.connected || gen !== this.deviceGen) return 'skipped';
    if (this.syncedGen === gen) return 'synced';
    const shown = this.deviceStats(client, gen);
    if (shown && shown.followers === this.deps.store.current.followers) return 'synced';
    this.log.info(`device stats ${shown ? 'mismatch' : 'unknown'} after ready → asking again`);
    await this.askForHello(client);
    if (!client.connected || gen !== this.deviceGen) return 'skipped';
    if (this.syncedGen === gen) return 'synced'; // the answer arrived and the hello path handled it
    const after = this.deviceStats(client, gen);
    if (after && after.followers === this.deps.store.current.followers) return 'synced';
    this.log.info(`device stats ${after ? 'mismatch' : 'unknown'} after ready → re-pushing`);
    await this.pushStatsToDevice(this.deps.store.toStatsFields());
    return 'pushed';
  }

  /** What the device last reported *on this connection* (state from an earlier one does not count). */
  private deviceStats(client: DeviceClient, gen: number): DeviceState['stats'] {
    return this.helloGen === gen ? client.state.stats : undefined;
  }

  /** Re-asks for a `hello` and resolves on the device's answer, or after the same grace period. */
  private askForHello(client: DeviceClient): Promise<void> {
    return new Promise<void>((resolve) => {
      let done = false;
      const finish = () => {
        if (done) return;
        done = true;
        clearTimeout(timer);
        client.off('hello', onHello);
        resolve();
      };
      // A microtask later: the hub's own `hello` handler (app.ts → resyncDevice) has then already decided
      // whether this answer needs a push, whatever order the listeners were registered in.
      const onHello = () => queueMicrotask(finish);
      const timer = setTimeout(finish, this.readyResyncDelayMs);
      timer.unref?.();
      client.on('hello', onHello);
      client.requestHello().catch(() => undefined); // the ack is irrelevant; the `hello` line is the answer
    });
  }

  /**
   * Every stats push to the device goes through here: the generation is marked *before* the write so the
   * ready fallback stands down while a push is in flight, and rolled back when the device did not take it.
   *
   * `syncedGen` must keep being written **before the first `await`** — {@link askForHello} reads it on the
   * microtask right after the `hello` event, while the push it is deferring to is still in flight. Moving
   * the marker after the ack would silently bring the double push back.
   */
  private async pushStatsToDevice(fields: StatsFields): Promise<boolean> {
    const gen = this.deviceGen;
    const previous = this.syncedGen;
    this.syncedGen = gen;
    const result = await this.deps.link.pushStats(fields);
    if (!result.ok && this.syncedGen === gen) this.syncedGen = previous;
    return result.ok;
  }

  async simulate(delta: number, source = 'manual'): Promise<RecordEvents> {
    const cur = this.deps.store.current;
    const d = Math.max(0, Math.round(delta));
    return this.applySample({ followers: cur.followers + d, likes: cur.likes, notes: cur.notes, ts: nowSeconds(), source });
  }

  /**
   * Stores a freshly scraped note list. The `notes` hint frame goes out on `/vp` **only when the
   * revision moved** — the Vision Pro re-fans its cards on every hint, so a repeat would be visible.
   */
  applyRecentNotes(notes: RecentNote[], source = 'scrape'): { changed: boolean; rev: number; count: number } {
    const store = this.deps.notesStore;
    if (!store) return { changed: false, rev: 0, count: notes.length };
    const update = store.update(notes, source);
    if (update.changed) {
      this.log.info(`recent notes rev ${update.rev} (${update.count} notes) → /vp hint`);
      this.deps.broadcastVp({ t: 'notes', rev: update.rev, count: update.count });
    }
    this.deps.onChange?.();
    return { changed: update.changed, rev: update.rev, count: update.count };
  }

  /** Records a sample, pushes `stats` when anything changed and `celebrate` when followers rose. */
  async applySample(input: RecordInput): Promise<RecordEvents> {
    const events = this.deps.store.record(input);
    this.deps.onChange?.();
    const fields = this.deps.store.toStatsFields();
    if (events.statsChanged) {
      await this.pushStatsToDevice(fields);
      this.deps.broadcastVp({ t: 'stats', ...fields });
    } else {
      this.log.info(`no change (followers=${fields.followers}); device not updated`);
    }
    if (events.followersDelta > 0) {
      this.log.info(`followers +${events.followersDelta} → celebrate`);
      await this.deps.link.celebrate(events.followersDelta);
      this.deps.broadcastVp({ t: 'celebrate', delta: events.followersDelta, followers: fields.followers });
    }
    return events;
  }
}
