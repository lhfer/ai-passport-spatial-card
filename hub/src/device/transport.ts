/**
 * Line transport abstraction over the device link (USB serial in production, an in-memory pair
 * in tests). Lines are complete protocol lines including the trailing `\n`.
 */

export interface Transport {
  readonly description: string;
  readonly closed: boolean;
  /** Writes one protocol line. Throws when the transport is closed. */
  send(line: string): void;
  onLine(cb: (line: string) => void): void;
  onClose(cb: (err?: Error) => void): void;
  close(): Promise<void>;
}

/**
 * In-memory transport pair: what one end sends, the other receives on the next macrotask.
 * `pair()` returns the hub end and the device end so a fake firmware can be scripted in tests.
 */
export class MockTransport implements Transport {
  private peer: MockTransport | null = null;
  private lineHandlers: ((line: string) => void)[] = [];
  private closeHandlers: ((err?: Error) => void)[] = [];
  private _closed = false;
  /** Every line this end has sent (tests inspect it). */
  readonly sent: string[] = [];

  constructor(readonly description = 'mock') {}

  static pair(): { hub: MockTransport; device: MockTransport } {
    const hub = new MockTransport('mock-hub');
    const device = new MockTransport('mock-device');
    hub.peer = device;
    device.peer = hub;
    return { hub, device };
  }

  get closed(): boolean {
    return this._closed;
  }

  send(line: string): void {
    if (this._closed) throw new Error('transport closed');
    this.sent.push(line);
    const peer = this.peer;
    if (!peer || peer._closed) return;
    setImmediate(() => peer.deliver(line));
  }

  /** Injects a line as if it arrived from the wire (may contain several `\n`-separated lines). */
  deliver(chunk: string): void {
    if (this._closed) return;
    for (const line of chunk.split('\n')) {
      if (!line.trim()) continue;
      for (const cb of this.lineHandlers) cb(line);
    }
  }

  onLine(cb: (line: string) => void): void {
    this.lineHandlers.push(cb);
  }

  onClose(cb: (err?: Error) => void): void {
    this.closeHandlers.push(cb);
  }

  async close(err?: Error): Promise<void> {
    if (this._closed) return;
    this._closed = true;
    for (const cb of this.closeHandlers) cb(err);
    const peer = this.peer;
    if (peer && !peer._closed) await peer.close();
  }
}
