import { describe, expect, it } from 'vitest';
import {
  DeviceToVpSchema,
  HubToDeviceSchema,
  VpToDeviceSchema,
  decode,
  decodeDeviceLine,
  decodeHubCommand,
  decodeVpBroadcast,
  encode,
  isStripText,
  nextId,
  ProtocolError,
  STRIP_GLYPHS,
} from '../src/protocol/index.ts';

// Fixtures are the literal example lines from docs/protocol.md.
const EXAMPLES = {
  hubHello: '{"t":"hello","id":"h1","hub":"spatial-hub/0.1","muteLogs":true}',
  deviceHello:
    '{"t":"hello","fw":"0.1.0","boot":7,"mode":"idle","theme":"base","stats":{"followers":4313,"likes":44000,"notes":128,"delta":0,"ts":1758150000},"battery":{"soc":88,"mv":4060},"ble":{"connected":false},"heap":181240}',
  ack: '{"t":"ack","id":"h1","ok":true}',
  stats: '{"t":"stats","id":"s1","followers":4318,"likes":44012,"notes":128,"delta":5,"ts":1758153600}',
  celebrate: '{"t":"celebrate","id":"c1","delta":5}',
  celebrateVp: '{"t":"celebrate","delta":5,"followers":4318}',
  strip: '{"t":"strip","id":"n7","text":"♥1825"}',
  stripRestore: '{"t":"strip","id":"n8"}',
  notesHint: '{"t":"notes","rev":3,"count":10}',
  setTheme: '{"t":"set_theme","id":"v9","theme":"neon-city"}',
  willChange: '{"t":"will_change","id":"w3","kind":"theme","theme":"neon-city","region":[0,0,240,320]}',
  changed: '{"t":"changed","id":"w3","theme":"neon-city"}',
  ackTheme: '{"t":"ack","id":"v9","ok":true,"theme":"neon-city"}',
};

describe('protocol encode', () => {
  it('emits exactly one JSON line with a trailing newline', () => {
    const line = encode({ t: 'ping', id: 'p1' });
    expect(line).toBe('{"t":"ping","id":"p1"}\n');
    expect(line.split('\n')).toHaveLength(2);
  });

  it('rejects lines over 512 bytes', () => {
    const big = { t: 'cmd', id: 'x', c: 'director', arg: 'a'.repeat(600) } as const;
    expect(() => encode(big)).toThrow(ProtocolError);
    try {
      encode(big);
    } catch (err) {
      expect((err as ProtocolError).code).toBe('too-long');
    }
  });

  it('accepts lines up to the limit (UTF-8 bytes, not characters)', () => {
    const arg = '中'.repeat(150); // 450 bytes
    const line = encode({ t: 'cmd', id: 'x', c: 'director', arg });
    expect(Buffer.byteLength(line)).toBeLessThanOrEqual(512);
  });
});

describe('protocol decode (device → hub)', () => {
  it('parses the device hello example', () => {
    const r = decodeDeviceLine(EXAMPLES.deviceHello);
    expect(r.ok).toBe(true);
    if (r.ok && r.msg.t === 'hello') {
      expect(r.msg.fw).toBe('0.1.0');
      expect(r.msg.stats?.followers).toBe(4313);
      expect(r.msg.ble?.connected).toBe(false);
    }
  });

  it('parses ack with optional theme', () => {
    const r = decodeDeviceLine(EXAMPLES.ackTheme);
    expect(r.ok && r.msg.t === 'ack' && r.msg.theme === 'neon-city').toBe(true);
  });

  it('parses button / ble / battery / log', () => {
    for (const line of [
      '{"t":"button","btn":"ok","ev":"long"}',
      '{"t":"ble","connected":true}',
      '{"t":"battery","soc":77,"mv":3990,"usb":true,"heap":170000}',
      '{"t":"log","lvl":"I","msg":"boot ok"}',
    ]) {
      expect(decodeDeviceLine(line).ok, line).toBe(true);
    }
  });

  it('reports non-JSON, non-object, unknown and invalid lines distinctly', () => {
    expect(decodeDeviceLine('I (123) boot: hello')).toMatchObject({ ok: false, code: 'json' });
    expect(decodeDeviceLine('[1,2]')).toMatchObject({ ok: false, code: 'shape' });
    expect(decodeDeviceLine('{"x":1}')).toMatchObject({ ok: false, code: 'shape' });
    expect(decodeDeviceLine('{"t":"warp","id":"1"}')).toMatchObject({ ok: false, code: 'unknown', t: 'warp' });
    expect(decodeDeviceLine('{"t":"button","btn":"left","ev":"click"}')).toMatchObject({ ok: false, code: 'invalid' });
  });

  it('tolerates CRLF and surrounding whitespace', () => {
    expect(decodeDeviceLine('  {"t":"ack","id":"1","ok":true}\r\n').ok).toBe(true);
  });
});

describe('protocol decode (hub → device)', () => {
  it('validates every command from protocol.md', () => {
    for (const line of [
      EXAMPLES.hubHello,
      EXAMPLES.stats,
      EXAMPLES.celebrate,
      EXAMPLES.setTheme,
      '{"t":"set_mode","id":"m1","mode":"ar"}',
      '{"t":"play_cue","id":"q1","cue":"tick"}',
      '{"t":"backlight","id":"b1","percent":40}',
      '{"t":"cmd","id":"d1","c":"replay"}',
      '{"t":"cmd","id":"d2","c":"director","arg":{"scene":2}}',
      '{"t":"cmd","id":"d3","c":"hide"}',
      '{"t":"cmd","id":"d4","c":"show"}',
      '{"t":"cmd","id":"d5","c":"perf","arg":"cones=off well=off material=plain"}',
      '{"t":"sleep","id":"z1"}',
      '{"t":"ping","id":"p1"}',
    ]) {
      expect(decodeHubCommand(line).ok, line).toBe(true);
    }
  });

  it('rejects out-of-range or missing fields', () => {
    expect(decodeHubCommand('{"t":"backlight","id":"b","percent":101}').ok).toBe(false);
    expect(decodeHubCommand('{"t":"stats","id":"s","followers":-1,"likes":0,"notes":0,"delta":0,"ts":0}').ok).toBe(false);
    expect(decodeHubCommand('{"t":"celebrate","delta":5}').ok).toBe(false); // missing id
    expect(decodeHubCommand('{"t":"set_theme","id":"x","theme":"mars"}').ok).toBe(false);
    expect(decodeHubCommand('{"t":"cmd","id":"d","c":"bogus"}').ok).toBe(false); // director commands are a closed set
  });

  it('accepts other world ids for set_theme (device maps them to base)', () => {
    expect(decodeHubCommand('{"t":"set_theme","id":"x","theme":"paper-valley"}').ok).toBe(true);
    expect(HubToDeviceSchema.safeParse({ t: 'set_theme', id: 'x', theme: 'code-sea' }).success).toBe(true);
  });
});

describe('protocol decode (BLE and WebSocket fixtures)', () => {
  it('validates device → Vision Pro messages', () => {
    for (const line of [EXAMPLES.willChange, EXAMPLES.changed, EXAMPLES.celebrateVp, EXAMPLES.deviceHello, '{"t":"battery","soc":80}', '{"t":"cmd","c":"replay"}', '{"t":"cmd","c":"hide"}']) {
      expect(decode(line, DeviceToVpSchema).ok, line).toBe(true);
    }
  });

  it('validates Vision Pro → device messages', () => {
    for (const line of [EXAMPLES.setTheme, '{"t":"set_mode","id":"a","mode":"ar"}', '{"t":"ack","id":"w3","ok":true}', '{"t":"ping","id":"p"}']) {
      expect(decode(line, VpToDeviceSchema).ok, line).toBe(true);
    }
  });

  it('validates WebSocket /vp broadcasts (no ids)', () => {
    for (const line of [
      '{"t":"stats","followers":4318,"likes":44012,"notes":128,"delta":5,"ts":1758153600}',
      EXAMPLES.celebrateVp,
      '{"t":"set_theme","theme":"neon-city"}',
      '{"t":"cmd","c":"replay"}',
      '{"t":"cmd","c":"hide"}',
      '{"t":"cmd","c":"show"}',
      '{"t":"cmd","c":"perf","arg":"worlds=on gallery-glass=off"}',
      '{"t":"cmd","c":"perf"}',
    ]) {
      expect(decodeVpBroadcast(line).ok, line).toBe(true);
    }
    expect(decodeVpBroadcast('{"t":"ping","id":"1"}').ok).toBe(false);
    // The command name is a closed set, and it lives in `c` — the Vision Pro decodes no other field.
    const bogus = decodeVpBroadcast('{"t":"cmd","c":"bogus"}');
    expect(bogus.ok).toBe(false);
    if (!bogus.ok) expect(bogus.code).toBe('invalid');
    expect(decodeVpBroadcast('{"t":"cmd","cmd":"hide"}').ok).toBe(false);
  });
});

describe('nextId', () => {
  it('produces short unique ids', () => {
    const a = nextId();
    const b = nextId();
    expect(a).not.toBe(b);
    expect(a.length).toBeLessThanOrEqual(12);
  });
});

describe('strip (hub → device, VP → device)', () => {
  it('accepts the documented override and the restore form on both links', () => {
    const hub = decodeHubCommand(EXAMPLES.strip);
    expect(hub.ok).toBe(true);
    if (hub.ok && hub.msg.t === 'strip') expect(hub.msg.text).toBe('♥1825');
    expect(decodeHubCommand(EXAMPLES.stripRestore).ok).toBe(true); // no text = back to the follower count
    expect(decode(EXAMPLES.strip, VpToDeviceSchema).ok).toBe(true);
    expect(encode({ t: 'strip', id: 'n7', text: '♥1825' })).toBe('{"t":"strip","id":"n7","text":"♥1825"}\n');
  });

  it('takes every glyph of the 19-glyph strip font, up to 12 code points', () => {
    for (const text of ['0123456789.+', '▲1.2万', '▼ 4k', '♥1825', '+168', '-7', '♥♥♥♥♥♥♥♥♥♥♥♥']) {
      expect(isStripText(text)).toBe(true);
      expect(decodeHubCommand(JSON.stringify({ t: 'strip', id: 'x', text })).ok).toBe(true);
    }
    expect(Array.from(STRIP_GLYPHS)).toHaveLength(19); // 17 v1 glyphs + space (0x20) + ♥ (0x2665)
  });

  it('rejects glyphs the font cannot draw and text that is too long or empty', () => {
    for (const text of ['笔记', '♥1,825', 'K1', '1825♡', '♥182512345678', '']) {
      expect(isStripText(text)).toBe(false);
    }
    expect(isStripText('♥18251234567')).toBe(true); // exactly 12 code points
    expect(isStripText('♥182512345678')).toBe(false); // 13 — one too many
    const bad = decodeHubCommand('{"t":"strip","id":"n7","text":"笔记"}');
    expect(bad.ok).toBe(false);
    if (!bad.ok) expect(bad.code).toBe('invalid');
  });
});

describe('notes hint frame (hub → Vision Pro)', () => {
  it('is a valid /vp broadcast carrying only rev and count', () => {
    const r = decodeVpBroadcast(EXAMPLES.notesHint);
    expect(r.ok).toBe(true);
    if (r.ok && r.msg.t === 'notes') expect(r.msg).toEqual({ t: 'notes', rev: 3, count: 10 });
    expect(decodeVpBroadcast('{"t":"notes","rev":-1,"count":10}').ok).toBe(false);
    expect(decodeVpBroadcast('{"t":"notes","rev":1}').ok).toBe(false);
  });
});
