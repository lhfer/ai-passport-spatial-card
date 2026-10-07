/**
 * USB serial transport for the AI Passport (ESP32-C3 USB Serial/JTAG, VID 303A) and a manager
 * that auto-detects the port, opens it safely and reconnects every 2 s.
 *
 * Safety: the port is opened with `hupcl: false` and DTR/RTS are then asserted (`true`) and never
 * driven low — the ESP32-C3 ROM interprets DTR/RTS transitions as reset / download-mode requests.
 */
import { ReadlineParser } from '@serialport/parser-readline';
import { SerialPort } from 'serialport';
import { createLogger, type Logger } from '../log.ts';
import type { DeviceClient } from './client.ts';
import type { Transport } from './transport.ts';

export const ESPRESSIF_VID = '303a';
export const DEFAULT_RECONNECT_MS = 2000;

export interface PortCandidate {
  path: string;
  vendorId?: string;
  productId?: string;
}

/** Normalises macOS `/dev/tty.*` entries to the non-blocking `/dev/cu.*` device. */
export function toCuPath(p: string): string {
  return p.replace(/^\/dev\/tty\./, '/dev/cu.');
}

/**
 * Picks the device port from a port list: Espressif VID on a usbmodem path first, any usbmodem
 * as a fallback (the USB Serial/JTAG peripheral is not always reported with a VID).
 */
export function pickDevicePort(ports: PortCandidate[], override?: string): string | null {
  if (override) return override;
  const usbmodem = ports.filter((p) => /usbmodem/i.test(p.path));
  const espressif = usbmodem.find((p) => (p.vendorId ?? '').toLowerCase() === ESPRESSIF_VID);
  const pick = espressif ?? usbmodem[0];
  return pick ? toCuPath(pick.path) : null;
}

export async function findDevicePort(override?: string): Promise<string | null> {
  const ports = await SerialPort.list();
  return pickDevicePort(
    ports.map((p) => {
      const c: PortCandidate = { path: p.path };
      if (p.vendorId) c.vendorId = p.vendorId;
      if (p.productId) c.productId = p.productId;
      return c;
    }),
    override,
  );
}

export class SerialTransport implements Transport {
  private lineHandlers: ((line: string) => void)[] = [];
  private closeHandlers: ((err?: Error) => void)[] = [];
  private _closed = false;

  private constructor(
    private readonly port: SerialPort,
    readonly description: string,
  ) {
    const parser = port.pipe(new ReadlineParser({ delimiter: '\n' }));
    parser.on('data', (line: string) => {
      for (const cb of this.lineHandlers) cb(line);
    });
    port.on('close', () => this.finish(undefined));
    port.on('error', (err: Error) => this.finish(err));
  }

  static async open(path: string): Promise<SerialTransport> {
    const port = new SerialPort({ path, baudRate: 115200, autoOpen: false, hupcl: false });
    await new Promise<void>((resolve, reject) => port.open((err) => (err ? reject(err) : resolve())));
    // Assert both lines once; never toggle them again (download-mode trap on ESP32-C3).
    await new Promise<void>((resolve, reject) => port.set({ dtr: true, rts: true }, (err) => (err ? reject(err) : resolve())));
    return new SerialTransport(port, path);
  }

  get closed(): boolean {
    return this._closed;
  }

  send(line: string): void {
    if (this._closed || !this.port.isOpen) throw new Error(`serial port ${this.description} is closed`);
    this.port.write(line);
  }

  onLine(cb: (line: string) => void): void {
    this.lineHandlers.push(cb);
  }

  onClose(cb: (err?: Error) => void): void {
    this.closeHandlers.push(cb);
  }

  private finish(err?: Error): void {
    if (this._closed) return;
    this._closed = true;
    for (const cb of this.closeHandlers) cb(err);
  }

  async close(): Promise<void> {
    if (this._closed) return;
    await new Promise<void>((resolve) => this.port.close(() => resolve()));
    this.finish(undefined);
  }
}

export interface SerialManagerOptions {
  reconnectMs?: number;
  /** Explicit port path (skips auto-detect). */
  port?: string;
  logger?: Logger;
}

export interface SerialManagerState {
  status: 'stopped' | 'searching' | 'connected';
  port?: string;
  lastError?: string;
}

/** Keeps a DeviceClient attached to the device: detect → open → hello, reconnecting on loss. */
export class SerialManager {
  private timer: NodeJS.Timeout | null = null;
  private running = false;
  private connecting = false;
  private _state: SerialManagerState = { status: 'stopped' };
  private readonly log: Logger;
  private readonly reconnectMs: number;
  private lastMissLog = 0;

  constructor(
    private readonly client: DeviceClient,
    private readonly opts: SerialManagerOptions = {},
  ) {
    this.log = opts.logger ?? createLogger('serial');
    this.reconnectMs = opts.reconnectMs ?? DEFAULT_RECONNECT_MS;
    client.on('disconnect', (err) => {
      if (!this.running) return;
      this.log.warn(`link lost${err ? `: ${err.message}` : ''}; reconnecting every ${this.reconnectMs} ms`);
      this._state = { status: 'searching', ...(err ? { lastError: err.message } : {}) };
      this.schedule();
    });
  }

  get state(): SerialManagerState {
    return this._state;
  }

  start(): void {
    if (this.running) return;
    this.running = true;
    this._state = { status: 'searching' };
    void this.tryConnect();
  }

  async stop(): Promise<void> {
    this.running = false;
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
    this.client.detach();
    this._state = { status: 'stopped' };
  }

  private schedule(): void {
    if (!this.running || this.timer) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      void this.tryConnect();
    }, this.reconnectMs);
  }

  /** One connection attempt; resolves true when the client is attached. */
  async tryConnect(): Promise<boolean> {
    if (!this.running || this.connecting || this.client.connected) return this.client.connected;
    this.connecting = true;
    try {
      const path = await findDevicePort(this.opts.port);
      if (!path) {
        const now = Date.now();
        if (now - this.lastMissLog > 30_000) {
          this.log.info('device not connected (no /dev/cu.usbmodem* port); waiting');
          this.lastMissLog = now;
        }
        this.schedule();
        return false;
      }
      this.log.info(`opening ${path}`);
      const transport = await SerialTransport.open(path);
      this._state = { status: 'connected', port: path };
      await this.client.attach(transport);
      return true;
    } catch (err) {
      const message = (err as Error).message;
      this._state = { status: 'searching', lastError: message };
      this.log.warn(`connect failed: ${message}${/Resource busy|EBUSY|locked/i.test(message) ? ' (port busy — close idf.py monitor / other terminals)' : ''}`);
      this.schedule();
      return false;
    } finally {
      this.connecting = false;
    }
  }
}
