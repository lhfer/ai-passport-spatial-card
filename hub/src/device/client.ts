/**
 * Device client: JSON-line framing over a {@link Transport}, `hello` handshake, ack matching
 * by id with a timeout, and typed events (`hello`, `battery`, `button`, `ble`, `log`, `raw`).
 * Transport-agnostic so the same code runs over USB serial and the in-memory mock.
 */
import { EventEmitter } from 'node:events';
import { createLogger, type Logger } from '../log.ts';
import { decodeDeviceLine, encode, nextId, type Ack, type BatteryMessage, type BleMessage, type ButtonMessage, type DeviceHello, type HubToDevice, type LogMessage } from '../protocol/index.ts';
import type { Transport } from './transport.ts';

export const HUB_NAME = 'spatial-hub/0.1';
export const DEFAULT_ACK_TIMEOUT_MS = 2000;

export class DeviceDisconnectedError extends Error {
  constructor() {
    super('device not connected');
    this.name = 'DeviceDisconnectedError';
  }
}

export class DeviceTimeoutError extends Error {
  constructor(readonly id: string, readonly type: string) {
    super(`no ack for ${type} (id ${id}) within timeout`);
    this.name = 'DeviceTimeoutError';
  }
}

export interface DeviceState {
  connected: boolean;
  /** `hello` acknowledged by the device. */
  ready: boolean;
  transport?: string;
  fw?: string;
  boot?: number;
  mode?: 'idle' | 'ar';
  theme?: string;
  battery?: { soc: number; mv?: number; usb?: boolean };
  bleConnected?: boolean;
  heap?: number;
  /** Unix ms of the last line received. */
  lastSeen?: number;
  stats?: { followers: number; likes: number; notes: number; delta: number; ts: number };
}

export interface DeviceClientEvents {
  hello: [DeviceHello];
  ack: [Ack];
  button: [ButtonMessage];
  ble: [BleMessage];
  battery: [BatteryMessage];
  log: [LogMessage];
  /** A line that was not a valid protocol message (boot logs before muteLogs, unknown types). */
  raw: [string];
  connect: [string];
  disconnect: [Error | undefined];
  state: [DeviceState];
}

type DistributiveOmit<T, K extends PropertyKey> = T extends unknown ? Omit<T, K> : never;
/** Any hub → device command without its id (assigned by the client). */
export type Command = DistributiveOmit<HubToDevice, 'id'>;

interface Pending {
  id: string;
  type: string;
  resolve: (ack: Ack) => void;
  reject: (err: Error) => void;
  timer: NodeJS.Timeout;
}

export interface DeviceClientOptions {
  ackTimeoutMs?: number;
  hubName?: string;
  logger?: Logger;
  /** Hello retries before giving up on `ready` (the link stays usable). */
  helloRetries?: number;
}

export class DeviceClient extends EventEmitter<DeviceClientEvents> {
  private transport: Transport | null = null;
  private pending = new Map<string, Pending>();
  private _state: DeviceState = { connected: false, ready: false };
  private readonly ackTimeoutMs: number;
  private readonly hubName: string;
  private readonly helloRetries: number;
  private readonly log: Logger;

  constructor(opts: DeviceClientOptions = {}) {
    super();
    this.ackTimeoutMs = opts.ackTimeoutMs ?? DEFAULT_ACK_TIMEOUT_MS;
    this.hubName = opts.hubName ?? HUB_NAME;
    this.helloRetries = opts.helloRetries ?? 3;
    this.log = opts.logger ?? createLogger('device');
  }

  get state(): DeviceState {
    return this._state;
  }

  get connected(): boolean {
    return this._state.connected && this.transport !== null && !this.transport.closed;
  }

  private setState(patch: Partial<DeviceState>): void {
    this._state = { ...this._state, ...patch };
    this.emit('state', this._state);
  }

  /** Binds a transport, sends `hello` and resolves once the handshake completed (or gave up). */
  async attach(transport: Transport): Promise<void> {
    if (this.transport) this.detach();
    this.transport = transport;
    transport.onLine((line) => this.handleLine(line));
    transport.onClose((err) => this.handleClose(err));
    this.setState({ connected: true, ready: false, transport: transport.description });
    this.emit('connect', transport.description);
    for (let attempt = 1; attempt <= this.helloRetries; attempt++) {
      try {
        const ack = await this.request({ t: 'hello', hub: this.hubName, muteLogs: true });
        if (ack.ok) {
          this.setState({ ready: true });
          this.log.info(`hello acknowledged by ${transport.description}${this._state.fw ? ` (fw ${this._state.fw})` : ''}`);
          return;
        }
        this.log.warn(`hello rejected: ${ack.err ?? 'unknown error'}`);
        return;
      } catch (err) {
        if (!this.connected) return;
        this.log.warn(`hello attempt ${attempt}/${this.helloRetries} failed: ${(err as Error).message}`);
      }
    }
    this.log.warn('device did not acknowledge hello; keeping the link open');
  }

  detach(): void {
    const t = this.transport;
    this.transport = null;
    this.failPending(new DeviceDisconnectedError());
    if (t && !t.closed) void t.close();
    if (this._state.connected) {
      this.setState({ connected: false, ready: false });
      this.emit('disconnect', undefined);
    }
  }

  private handleClose(err?: Error): void {
    this.transport = null;
    this.failPending(new DeviceDisconnectedError());
    this.setState({ connected: false, ready: false });
    this.emit('disconnect', err);
  }

  private failPending(err: Error): void {
    for (const p of this.pending.values()) {
      clearTimeout(p.timer);
      p.reject(err);
    }
    this.pending.clear();
  }

  /** Sends a command (id assigned here) and resolves with its ack. */
  request(cmd: Command): Promise<Ack> {
    const transport = this.transport;
    if (!transport || transport.closed || !this._state.connected) return Promise.reject(new DeviceDisconnectedError());
    const id = nextId();
    const msg = { ...cmd, id } as HubToDevice;
    let line: string;
    try {
      line = encode(msg);
    } catch (err) {
      return Promise.reject(err as Error);
    }
    return new Promise<Ack>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new DeviceTimeoutError(id, cmd.t));
      }, this.ackTimeoutMs);
      this.pending.set(id, { id, type: cmd.t, resolve, reject, timer });
      try {
        transport.send(line);
        this.log.debug(`→ ${line.trim()}`);
      } catch (err) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(err as Error);
      }
    });
  }

  /**
   * Re-sends the `hello` handshake command. The device answers with its own `hello` line *and* an ack
   * (docs/protocol.md: 设备回 `hello` + `ack`), so this is how the hub asks a device that never sent one —
   * or whose line was lost in the pre-`muteLogs` boot chatter — to report `fw` / `stats` again.
   */
  requestHello(): Promise<Ack> {
    return this.request({ t: 'hello', hub: this.hubName, muteLogs: true });
  }

  /** Sends a raw (already validated) message without waiting for an ack. */
  sendRaw(msg: HubToDevice | Record<string, unknown>): void {
    const transport = this.transport;
    if (!transport || transport.closed) throw new DeviceDisconnectedError();
    transport.send(encode(msg));
  }

  private handleLine(line: string): void {
    this.setState({ lastSeen: Date.now() });
    const r = decodeDeviceLine(line);
    if (!r.ok) {
      if (r.code === 'invalid' && r.t === 'ack' && r.raw && typeof r.raw['id'] === 'string') {
        // Lenient: an ack with odd extra fields still settles the request.
        this.settle({ t: 'ack', id: r.raw['id'], ok: r.raw['ok'] === true, ...(typeof r.raw['err'] === 'string' ? { err: r.raw['err'] } : {}) });
        return;
      }
      // A `hello` that does not fit the schema is the one dropped line the hub really misses (no fw, no
      // stats, and the LCD keeps whatever it had) — say so out loud instead of hiding it behind HUB_DEBUG.
      if (r.t === 'hello') this.log.warn(`dropped a malformed device hello (${r.code}): ${line.trim()}`);
      else this.log.debug(`raw line (${r.code}): ${line.trim()}`);
      this.emit('raw', line);
      return;
    }
    const msg = r.msg;
    switch (msg.t) {
      case 'ack':
        this.settle(msg);
        break;
      case 'hello': {
        const patch: Partial<DeviceState> = { fw: msg.fw, mode: msg.mode, theme: msg.theme };
        if (msg.boot !== undefined) patch.boot = msg.boot;
        if (msg.heap !== undefined) patch.heap = msg.heap;
        if (msg.battery) patch.battery = { soc: msg.battery.soc, mv: msg.battery.mv };
        if (msg.ble) patch.bleConnected = msg.ble.connected;
        if (msg.stats) patch.stats = { followers: msg.stats.followers, likes: msg.stats.likes, notes: msg.stats.notes, delta: msg.stats.delta, ts: msg.stats.ts };
        this.setState(patch);
        this.emit('hello', msg);
        break;
      }
      case 'battery': {
        const battery: DeviceState['battery'] = { soc: msg.soc };
        if (msg.mv !== undefined) battery.mv = msg.mv;
        if (msg.usb !== undefined) battery.usb = msg.usb;
        const patch: Partial<DeviceState> = { battery };
        if (msg.heap !== undefined) patch.heap = msg.heap;
        this.setState(patch);
        this.emit('battery', msg);
        break;
      }
      case 'ble':
        this.setState({ bleConnected: msg.connected, mode: msg.connected ? 'ar' : 'idle' });
        this.emit('ble', msg);
        break;
      case 'button':
        this.emit('button', msg);
        break;
      case 'log':
        this.log.info(`[fw:${msg.lvl}] ${msg.msg}`);
        this.emit('log', msg);
        break;
    }
  }

  private settle(ack: Ack): void {
    const p = this.pending.get(ack.id);
    if (!p) {
      this.log.debug(`unmatched ack ${JSON.stringify(ack)}`);
      this.emit('ack', ack);
      return;
    }
    clearTimeout(p.timer);
    this.pending.delete(ack.id);
    if (ack.theme && (p.type === 'set_theme' || p.type === 'hello')) this.setState({ theme: ack.theme });
    this.emit('ack', ack);
    p.resolve(ack);
  }
}
