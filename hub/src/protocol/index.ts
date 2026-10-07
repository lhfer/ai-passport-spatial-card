/**
 * Framing helpers for the JSON-line protocol: one UTF-8 JSON object per line, `\n` terminated,
 * at most 512 bytes per line (docs/protocol.md).
 */
import { z } from 'zod';
import {
  DeviceToHubSchema,
  HubToDeviceSchema,
  HubToVpSchema,
  type AnyMessage,
  type DeviceToHub,
} from './schema.ts';

export * from './schema.ts';

export const MAX_LINE_BYTES = 512;

export class ProtocolError extends Error {
  constructor(
    message: string,
    readonly code: 'too-long' | 'json' | 'shape' | 'unknown' | 'invalid',
  ) {
    super(message);
    this.name = 'ProtocolError';
  }
}

/**
 * Serialises a message as one protocol line (including the trailing `\n`).
 * Throws {@link ProtocolError} when the line would exceed 512 bytes.
 */
export function encode(msg: AnyMessage | Record<string, unknown>): string {
  const line = `${JSON.stringify(msg)}\n`;
  const bytes = Buffer.byteLength(line, 'utf8');
  if (bytes > MAX_LINE_BYTES) {
    throw new ProtocolError(`message of ${bytes} bytes exceeds the ${MAX_LINE_BYTES}-byte line limit`, 'too-long');
  }
  return line;
}

export type DecodeResult<T> =
  | { ok: true; msg: T }
  | {
      ok: false;
      /** `json`: not JSON; `shape`: JSON but not an object with a string `t`; `unknown`: unknown `t`; `invalid`: known `t`, bad fields. */
      code: 'json' | 'shape' | 'unknown' | 'invalid';
      error: string;
      /** The parsed JSON object when it was at least an object (lets callers surface raw messages). */
      raw?: Record<string, unknown>;
      t?: string;
    };

function decodeWith<T>(line: string, schema: z.ZodType<T>, knownTypes: ReadonlySet<string>): DecodeResult<T> {
  const text = line.trim();
  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch (err) {
    return { ok: false, code: 'json', error: `not JSON: ${(err as Error).message}` };
  }
  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    return { ok: false, code: 'shape', error: 'line is not a JSON object' };
  }
  const raw = parsed as Record<string, unknown>;
  const t = raw['t'];
  if (typeof t !== 'string') {
    return { ok: false, code: 'shape', error: 'missing string field "t"', raw };
  }
  if (!knownTypes.has(t)) {
    return { ok: false, code: 'unknown', error: `unknown message type "${t}"`, raw, t };
  }
  const result = schema.safeParse(raw);
  if (!result.success) {
    return { ok: false, code: 'invalid', error: z.prettifyError(result.error), raw, t };
  }
  return { ok: true, msg: result.data };
}

const DEVICE_TO_HUB_TYPES = new Set(DeviceToHubSchema.options.map((o) => o.shape.t.value));
const HUB_TO_DEVICE_TYPES = new Set(HubToDeviceSchema.options.map((o) => o.shape.t.value));
const HUB_TO_VP_TYPES = new Set(HubToVpSchema.options.map((o) => o.shape.t.value));

/** Decodes a line received from the device over serial. */
export function decodeDeviceLine(line: string): DecodeResult<DeviceToHub> {
  return decodeWith(line, DeviceToHubSchema, DEVICE_TO_HUB_TYPES);
}

/** Decodes a line the hub is about to send to the device (used by the `send <json>` CLI). */
export function decodeHubCommand(line: string) {
  return decodeWith(line, HubToDeviceSchema, HUB_TO_DEVICE_TYPES);
}

/** Decodes a WebSocket `/vp` broadcast (used by tests and by the panel's own validation). */
export function decodeVpBroadcast(line: string) {
  return decodeWith(line, HubToVpSchema, HUB_TO_VP_TYPES);
}

/** Generic decoder: parses the line and validates it against the given union. */
export function decode<T>(line: string, schema: z.ZodDiscriminatedUnion<z.ZodObject[]> & z.ZodType<T>) {
  const types = new Set(schema.options.map((o) => (o.shape['t'] as z.ZodLiteral<string>).value));
  return decodeWith(line, schema, types);
}

let idCounter = 0;
const idPrefix = Math.random().toString(36).slice(2, 5);

/** Short unique command id (`<3 random chars><counter>`), unique per hub process. */
export function nextId(prefix = idPrefix): string {
  idCounter = (idCounter + 1) % 1_000_000;
  return `${prefix}${idCounter}`;
}
