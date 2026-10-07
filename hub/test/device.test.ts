import { describe, expect, it } from 'vitest';
import { DeviceClient, DeviceDisconnectedError, DeviceTimeoutError } from '../src/device/client.ts';
import { DeviceLink } from '../src/device/link.ts';
import { pickDevicePort, toCuPath } from '../src/device/serial.ts';
import { MockTransport } from '../src/device/transport.ts';
import { silentLogger } from '../src/log.ts';
import { decodeHubCommand } from '../src/protocol/index.ts';

/** Minimal scripted firmware living on the device end of a mock pair. */
function fakeDevice(device: MockTransport, opts: { ignore?: string[]; ackDelayMs?: number } = {}) {
  const received: Record<string, unknown>[] = [];
  device.onLine((line) => {
    const r = decodeHubCommand(line);
    if (!r.ok) {
      received.push({ t: '?', line });
      return;
    }
    const msg = r.msg;
    received.push(msg);
    if (opts.ignore?.includes(msg.t)) return;
    const reply = () => {
      if (msg.t === 'hello') {
        device.send(
          '{"t":"hello","fw":"0.1.0","boot":7,"mode":"idle","theme":"base","stats":{"followers":4313,"likes":44000,"notes":128,"delta":0,"ts":1758150000},"battery":{"soc":88,"mv":4060},"ble":{"connected":false},"heap":181240}\n',
        );
      }
      const extra = msg.t === 'set_theme' ? `,"theme":"${msg.theme === 'paper-valley' ? 'base' : msg.theme}"` : '';
      device.send(`{"t":"ack","id":"${msg.id}","ok":true${extra}}\n`);
    };
    if (opts.ackDelayMs) setTimeout(reply, opts.ackDelayMs);
    else reply();
  });
  return { received };
}

const tick = () => new Promise((r) => setImmediate(r));

describe('DeviceClient over the mock transport', () => {
  it('performs the hello handshake and mirrors device state', async () => {
    const { hub, device } = MockTransport.pair();
    const fw = fakeDevice(device);
    const client = new DeviceClient({ logger: silentLogger });
    const hellos: string[] = [];
    client.on('hello', (h) => hellos.push(h.fw));
    await client.attach(hub);
    expect(client.state).toMatchObject({ connected: true, ready: true, fw: '0.1.0', mode: 'idle', theme: 'base', bleConnected: false, heap: 181240 });
    expect(client.state.stats?.followers).toBe(4313);
    expect(hellos).toEqual(['0.1.0']);
    const sentHello = JSON.parse(hub.sent[0]!);
    expect(sentHello).toMatchObject({ t: 'hello', hub: 'spatial-hub/0.1', muteLogs: true });
    expect(typeof sentHello.id).toBe('string');
    expect(fw.received[0]).toMatchObject({ t: 'hello' });
    client.detach();
  });

  it('matches acks by id even when they arrive out of order', async () => {
    const { hub, device } = MockTransport.pair();
    const client = new DeviceClient({ logger: silentLogger, helloRetries: 1, ackTimeoutMs: 500 });
    // custom firmware: answer hello immediately, answer other commands in reverse order
    const queue: string[] = [];
    device.onLine((line) => {
      const msg = JSON.parse(line);
      if (msg.t === 'hello') {
        device.send(`{"t":"ack","id":"${msg.id}","ok":true}\n`);
        return;
      }
      queue.push(msg.id);
      if (queue.length === 2) {
        for (const id of queue.reverse()) device.send(`{"t":"ack","id":"${id}","ok":${id.endsWith('3') ? 'false' : 'true'},"err":"nope"}\n`);
      }
    });
    await client.attach(hub);
    const a = client.request({ t: 'ping' });
    const b = client.request({ t: 'ping' });
    const [ackA, ackB] = await Promise.all([a, b]);
    const idA = JSON.parse(hub.sent[1]!).id;
    const idB = JSON.parse(hub.sent[2]!).id;
    expect(ackA.id).toBe(idA);
    expect(ackB.id).toBe(idB);
    client.detach();
  });

  it('times out when the device never acks', async () => {
    const { hub, device } = MockTransport.pair();
    fakeDevice(device, { ignore: ['sleep'] });
    const client = new DeviceClient({ logger: silentLogger, ackTimeoutMs: 60 });
    await client.attach(hub);
    const started = Date.now();
    await expect(client.request({ t: 'sleep' })).rejects.toBeInstanceOf(DeviceTimeoutError);
    expect(Date.now() - started).toBeGreaterThanOrEqual(50);
    // the link is still usable afterwards
    await expect(client.request({ t: 'ping' })).resolves.toMatchObject({ ok: true });
    client.detach();
  });

  it('keeps the link open when hello is never acknowledged', async () => {
    const { hub, device } = MockTransport.pair();
    fakeDevice(device, { ignore: ['hello'] });
    const client = new DeviceClient({ logger: silentLogger, ackTimeoutMs: 20, helloRetries: 2 });
    await client.attach(hub);
    expect(client.state).toMatchObject({ connected: true, ready: false });
    expect(hub.sent.length).toBe(2); // two hello attempts
    client.detach();
  });

  it('surfaces log, button, battery and ble events and tolerates junk lines', async () => {
    const { hub, device } = MockTransport.pair();
    fakeDevice(device);
    const lines: string[] = [];
    const logger = { ...silentLogger, info: (m: string) => lines.push(m), child: () => logger };
    const client = new DeviceClient({ logger });
    const events: string[] = [];
    client.on('button', (b) => events.push(`button:${b.btn}:${b.ev}`));
    client.on('battery', (b) => events.push(`battery:${b.soc}`));
    client.on('ble', (b) => events.push(`ble:${b.connected}`));
    client.on('raw', (l) => events.push(`raw:${l.trim()}`));
    await client.attach(hub);
    device.send('I (1234) boot: not json at all\n');
    device.send('{"t":"log","lvl":"W","msg":"heap low"}\n');
    device.send('{"t":"button","btn":"ok","ev":"long"}\n{"t":"battery","soc":77,"mv":3990,"usb":true,"heap":170000}\n');
    device.send('{"t":"ble","connected":true}\n');
    device.send('{"t":"warp","x":1}\n');
    await tick();
    await tick();
    expect(events).toEqual(['raw:I (1234) boot: not json at all', 'button:ok:long', 'battery:77', 'ble:true', 'raw:{"t":"warp","x":1}']);
    expect(lines.some((l) => l.includes('[fw:W] heap low'))).toBe(true);
    expect(client.state).toMatchObject({ battery: { soc: 77, mv: 3990, usb: true }, heap: 170000, bleConnected: true, mode: 'ar' });
    client.detach();
  });

  it('rejects pending requests and reports disconnect when the transport closes', async () => {
    const { hub, device } = MockTransport.pair();
    fakeDevice(device, { ignore: ['ping'] });
    const client = new DeviceClient({ logger: silentLogger, ackTimeoutMs: 1000 });
    let disconnected = false;
    client.on('disconnect', () => (disconnected = true));
    await client.attach(hub);
    const pending = client.request({ t: 'ping' });
    await device.close();
    await expect(pending).rejects.toBeInstanceOf(DeviceDisconnectedError);
    expect(disconnected).toBe(true);
    expect(client.connected).toBe(false);
    await expect(client.request({ t: 'ping' })).rejects.toBeInstanceOf(DeviceDisconnectedError);
  });

  it('never sends a line over 512 bytes', async () => {
    const { hub, device } = MockTransport.pair();
    fakeDevice(device);
    const client = new DeviceClient({ logger: silentLogger });
    await client.attach(hub);
    await expect(client.request({ t: 'cmd', c: 'director', arg: 'x'.repeat(600) })).rejects.toThrow(/512/);
    client.detach();
  });
});

describe('DeviceLink', () => {
  it('builds protocol messages and reports acks', async () => {
    const { hub, device } = MockTransport.pair();
    const fw = fakeDevice(device);
    const client = new DeviceClient({ logger: silentLogger });
    const link = new DeviceLink(client, silentLogger);
    await client.attach(hub);
    expect(await link.pushStats({ followers: 4318, likes: 44012, notes: 128, delta: 5, ts: 1758153600 })).toMatchObject({ ok: true });
    expect(await link.celebrate(5)).toMatchObject({ ok: true });
    expect(await link.setTheme('neon-city')).toMatchObject({ ok: true, ack: { theme: 'neon-city' } });
    expect(client.state.theme).toBe('neon-city');
    expect(await link.playCue('tick')).toMatchObject({ ok: true });
    expect(await link.cmd('replay')).toMatchObject({ ok: true });
    expect(await link.cmd('director', { scene: 2 })).toMatchObject({ ok: true });
    expect(await link.setMode('ar')).toMatchObject({ ok: true });
    expect(await link.backlight(150)).toMatchObject({ ok: true });
    const types = fw.received.map((m) => m['t']);
    expect(types).toEqual(['hello', 'stats', 'celebrate', 'set_theme', 'play_cue', 'cmd', 'cmd', 'set_mode', 'backlight']);
    expect(fw.received[1]).toMatchObject({ followers: 4318, likes: 44012, notes: 128, delta: 5, ts: 1758153600 });
    expect(fw.received[8]).toMatchObject({ percent: 100 });
    client.detach();
  });

  it('does not throw without a device', async () => {
    const client = new DeviceClient({ logger: silentLogger });
    const link = new DeviceLink(client, silentLogger);
    expect(await link.pushStats({ followers: 1, likes: 1, notes: 1, delta: 0, ts: 1 })).toEqual({ ok: false, reason: 'disconnected', err: 'device not connected' });
    expect(await link.celebrate(3)).toMatchObject({ ok: false, reason: 'disconnected' });
  });
});

describe('serial port selection', () => {
  it('prefers the Espressif VID on a usbmodem path and maps tty → cu', () => {
    const ports = [
      { path: '/dev/tty.Bluetooth-Incoming-Port' },
      { path: '/dev/tty.usbmodem2101', vendorId: '1a86' },
      { path: '/dev/tty.usbmodem101', vendorId: '303A', productId: '1001' },
    ];
    expect(pickDevicePort(ports)).toBe('/dev/cu.usbmodem101');
    expect(pickDevicePort(ports.slice(0, 2))).toBe('/dev/cu.usbmodem2101');
    expect(pickDevicePort(ports.slice(0, 1))).toBeNull();
    expect(pickDevicePort([], '/dev/cu.custom')).toBe('/dev/cu.custom');
    expect(toCuPath('/dev/cu.usbmodem1')).toBe('/dev/cu.usbmodem1');
  });
});
