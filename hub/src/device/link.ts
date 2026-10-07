/**
 * High-level device commands. Every method builds the protocol message from docs/protocol.md,
 * awaits the ack and returns a {@link LinkResult}; nothing here throws when the device is
 * absent — the hub keeps working (and says so in the log) without hardware.
 */
import { createLogger, type Logger } from '../log.ts';
import { isStripText, type Ack, type DirectorCommand, type StatsFields, type Theme, type ThemeOrWorld } from '../protocol/index.ts';
import { DeviceDisconnectedError, DeviceTimeoutError, type DeviceClient } from './client.ts';

export type LinkResult = { ok: true; ack: Ack } | { ok: false; reason: 'disconnected' | 'timeout' | 'nack' | 'error'; err: string };

export type Cue = 'celebrate' | 'tick' | 'connect';
/** Single source of truth: {@link DirectorCommandSchema} in src/protocol/schema.ts. */
export type { DirectorCommand };
export type CmdArg = string | number | boolean | Record<string, unknown>;

export class DeviceLink {
  private readonly log: Logger;

  constructor(
    readonly client: DeviceClient,
    logger?: Logger,
  ) {
    this.log = logger ?? createLogger('link');
  }

  get connected(): boolean {
    return this.client.connected;
  }

  private async run(cmd: Parameters<DeviceClient['request']>[0], label: string): Promise<LinkResult> {
    if (!this.client.connected) {
      this.log.info(`device not connected — skipped ${label}`);
      return { ok: false, reason: 'disconnected', err: 'device not connected' };
    }
    try {
      const ack = await this.client.request(cmd);
      if (!ack.ok) {
        this.log.warn(`${label} rejected by device: ${ack.err ?? 'unknown'}`);
        return { ok: false, reason: 'nack', err: ack.err ?? 'rejected' };
      }
      this.log.info(`${label} ok${ack.theme ? ` (theme ${ack.theme})` : ''}`);
      return { ok: true, ack };
    } catch (err) {
      if (err instanceof DeviceTimeoutError) {
        this.log.warn(`${label}: ${err.message}`);
        return { ok: false, reason: 'timeout', err: err.message };
      }
      if (err instanceof DeviceDisconnectedError) {
        this.log.info(`device not connected — ${label} dropped`);
        return { ok: false, reason: 'disconnected', err: err.message };
      }
      this.log.error(`${label} failed: ${(err as Error).message}`);
      return { ok: false, reason: 'error', err: (err as Error).message };
    }
  }

  /** `stats{followers,likes,notes,delta,ts}` — after every scrape / simulation. */
  pushStats(sample: StatsFields): Promise<LinkResult> {
    return this.run({ t: 'stats', ...sample }, `stats ${sample.followers} (+${sample.delta})`);
  }

  /** `celebrate{delta}` — sent right after `stats` when followers went up. */
  celebrate(delta: number): Promise<LinkResult> {
    return this.run({ t: 'celebrate', delta }, `celebrate +${delta}`);
  }

  setTheme(theme: ThemeOrWorld): Promise<LinkResult> {
    return this.run({ t: 'set_theme', theme }, `set_theme ${theme}`);
  }

  setMode(mode: 'idle' | 'ar'): Promise<LinkResult> {
    return this.run({ t: 'set_mode', mode }, `set_mode ${mode}`);
  }

  playCue(cue: Cue): Promise<LinkResult> {
    return this.run({ t: 'play_cue', cue }, `play_cue ${cue}`);
  }

  backlight(percent: number): Promise<LinkResult> {
    return this.run({ t: 'backlight', percent: Math.max(0, Math.min(100, Math.round(percent))) }, `backlight ${percent}%`);
  }

  /**
   * `strip{text?}` — overrides the bottom strip (e.g. `♥1825` while a note preview is open);
   * without `text` the device goes back to showing the follower count. Invalid glyphs are rejected
   * here so the device never has to answer `ack err:"glyph"`.
   */
  strip(text?: string): Promise<LinkResult> {
    if (text !== undefined && !isStripText(text)) {
      this.log.warn(`strip refused: "${text}" is not 1-12 strip glyphs`);
      return Promise.resolve({ ok: false, reason: 'error', err: 'text must be 1-12 code points from the strip glyph set' });
    }
    return this.run(text === undefined ? { t: 'strip' } : { t: 'strip', text }, `strip ${text ?? '(restore followers)'}`);
  }

  /** Director command; the device forwards it verbatim to the Vision Pro over BLE. */
  cmd(c: DirectorCommand, arg?: CmdArg): Promise<LinkResult> {
    return this.run(arg === undefined ? { t: 'cmd', c } : { t: 'cmd', c, arg }, `cmd ${c}${arg !== undefined ? ` ${JSON.stringify(arg)}` : ''}`);
  }

  ping(): Promise<LinkResult> {
    return this.run({ t: 'ping' }, 'ping');
  }

  sleep(): Promise<LinkResult> {
    return this.run({ t: 'sleep' }, 'sleep');
  }

  /** Sends an arbitrary validated command (CLI `send <json>`). */
  raw(cmd: Parameters<DeviceClient['request']>[0]): Promise<LinkResult> {
    return this.run(cmd, cmd.t);
  }
}

export function isTheme(value: string): value is Theme {
  return value === 'base' || value === 'neon-city' || value === 'data-nebula';
}
