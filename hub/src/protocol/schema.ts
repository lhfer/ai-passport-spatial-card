/**
 * Zod schemas for every message in docs/protocol.md (Spatial Card device protocol v1).
 *
 * All three links (USB serial, BLE NUS, WebSocket /vp) share the same JSON-line messages; the
 * discriminator is `t`. Messages that expect an answer carry a string `id` and get an `ack`.
 * The unions below are grouped by direction because a few types (`hello`, `celebrate`, `stats`)
 * have different fields depending on who sends them.
 */
import { z } from 'zod';

export const THEMES = ['base', 'neon-city', 'data-nebula'] as const;
export const ThemeSchema = z.enum(THEMES);
export type Theme = z.infer<typeof ThemeSchema>;

/** Other world ids are accepted on the wire; the device maps them to `base` (see protocol.md). */
export const ThemeOrWorldSchema = z.union([
  ThemeSchema,
  z.enum(['code-sea', 'deep-sea', 'paper-valley']),
]);
export type ThemeOrWorld = z.infer<typeof ThemeOrWorldSchema>;

export const ModeSchema = z.enum(['idle', 'ar']);
export const CueSchema = z.enum(['celebrate', 'tick', 'connect']);
/** Director commands. `hide`/`show` fold the desk card into the device and bring it back; the
 * Vision Pro reads them off the `c` field of a `cmd` frame, exactly like `replay` (docs/protocol.md).
 * `perf` (v4 B4 §3.5) switches the desk's layers live for a headset frame-rate A/B: its `arg` is one
 * string of `layer=on|off` words (`cones=off well=off`, `material=plain|blur|placeholder`, `reset`) and
 * it *sets* a state, so the copy that arrives over the device's BLE relay and the one over `/vp` agree. */
export const DirectorCommandSchema = z.enum(['replay', 'celebrate', 'theme', 'director', 'hide', 'show', 'perf']);
export type DirectorCommand = z.infer<typeof DirectorCommandSchema>;
export const ButtonSchema = z.enum(['up', 'down', 'ok']);
export const ButtonEventSchema = z.enum(['click', 'long']);
export const LogLevelSchema = z.enum(['E', 'W', 'I', 'D']);

const id = z.string().min(1).max(32);
const count = z.number().int().nonnegative();
/** Free-form director argument; must stay JSON-serialisable and small (≤512 B line). */
const cmdArg = z.union([z.string(), z.number(), z.boolean(), z.record(z.string(), z.unknown())]);

/** `stats` object, isomorphic on every link. `delta` = follower net gain since the previous sample (≥0). */
export const StatsFieldsSchema = z.object({
  followers: count,
  likes: count,
  notes: count,
  delta: count,
  ts: count,
});
export type StatsFields = z.infer<typeof StatsFieldsSchema>;

/**
 * Glyphs the device's bottom strip font can render. v1 had 17 (`0-9 . + - k 万 ▲ ▼`); the v2 font adds
 * space (0x20) and ♥ (0x2665) so `strip` can show a like count. No comma — same as
 * `stats_format_followers` on the device and `CardStats.compact` on the Vision Pro.
 */
export const STRIP_GLYPHS = '0123456789.+-k万▲▼♥ ';
export const STRIP_MAX_CODEPOINTS = 12;

/** True when `text` fits the bottom strip: 1–12 code points, all from {@link STRIP_GLYPHS}. */
export function isStripText(text: string): boolean {
  const chars = Array.from(text);
  return chars.length >= 1 && chars.length <= STRIP_MAX_CODEPOINTS && chars.every((c) => STRIP_GLYPHS.includes(c));
}

export const StripTextSchema = z.string().refine(isStripText, {
  message: `strip text must be 1-${STRIP_MAX_CODEPOINTS} code points from "${STRIP_GLYPHS}"`,
});

export const BatterySchema = z.object({ soc: z.number(), mv: z.number() }).loose();
export const BleStateSchema = z.object({ connected: z.boolean() }).loose();

// ---------------------------------------------------------------------------------------------
// Hub → Device (serial)
// ---------------------------------------------------------------------------------------------

export const HubHelloSchema = z.object({
  t: z.literal('hello'),
  id,
  hub: z.string(),
  muteLogs: z.boolean(),
});
export const StatsCommandSchema = z.object({ t: z.literal('stats'), id, ...StatsFieldsSchema.shape });
export const CelebrateCommandSchema = z.object({ t: z.literal('celebrate'), id, delta: count });
export const SetThemeCommandSchema = z.object({ t: z.literal('set_theme'), id, theme: ThemeOrWorldSchema });
export const SetModeCommandSchema = z.object({ t: z.literal('set_mode'), id, mode: ModeSchema });
export const PlayCueCommandSchema = z.object({ t: z.literal('play_cue'), id, cue: CueSchema });
export const BacklightCommandSchema = z.object({
  t: z.literal('backlight'),
  id,
  percent: z.number().int().min(0).max(100),
});
export const CmdCommandSchema = z.object({
  t: z.literal('cmd'),
  id,
  c: DirectorCommandSchema,
  arg: cmdArg.optional(),
});
/** Bottom-strip override; no `text` restores the follower count (docs/protocol.md, 底条覆盖). */
export const StripCommandSchema = z.object({ t: z.literal('strip'), id, text: StripTextSchema.optional() });
export const SleepCommandSchema = z.object({ t: z.literal('sleep'), id });
export const PingCommandSchema = z.object({ t: z.literal('ping'), id });

export const HubToDeviceSchema = z.discriminatedUnion('t', [
  HubHelloSchema,
  StatsCommandSchema,
  CelebrateCommandSchema,
  SetThemeCommandSchema,
  SetModeCommandSchema,
  PlayCueCommandSchema,
  BacklightCommandSchema,
  CmdCommandSchema,
  StripCommandSchema,
  SleepCommandSchema,
  PingCommandSchema,
]);
export type HubToDevice = z.infer<typeof HubToDeviceSchema>;
export type HubCommandType = HubToDevice['t'];

// ---------------------------------------------------------------------------------------------
// Device → Hub (serial)
// ---------------------------------------------------------------------------------------------

export const DeviceHelloSchema = z
  .object({
    t: z.literal('hello'),
    fw: z.string(),
    boot: z.number().int().optional(),
    mode: ModeSchema,
    theme: ThemeSchema,
    stats: StatsFieldsSchema.loose().optional(),
    battery: BatterySchema.optional(),
    ble: BleStateSchema.optional(),
    heap: z.number().int().optional(),
  })
  .loose();
export const AckSchema = z
  .object({
    t: z.literal('ack'),
    id,
    ok: z.boolean(),
    err: z.string().optional(),
    theme: z.string().optional(),
  })
  .loose();
export const ButtonMessageSchema = z.object({ t: z.literal('button'), btn: ButtonSchema, ev: ButtonEventSchema });
export const BleMessageSchema = z.object({ t: z.literal('ble'), connected: z.boolean() });
export const BatteryMessageSchema = z
  .object({
    t: z.literal('battery'),
    soc: z.number(),
    mv: z.number().optional(),
    usb: z.boolean().optional(),
    heap: z.number().int().optional(),
  })
  .loose();
export const LogMessageSchema = z.object({ t: z.literal('log'), lvl: LogLevelSchema, msg: z.string() });

export const DeviceToHubSchema = z.discriminatedUnion('t', [
  DeviceHelloSchema,
  AckSchema,
  ButtonMessageSchema,
  BleMessageSchema,
  BatteryMessageSchema,
  LogMessageSchema,
]);
export type DeviceToHub = z.infer<typeof DeviceToHubSchema>;
export type DeviceHello = z.infer<typeof DeviceHelloSchema>;
export type Ack = z.infer<typeof AckSchema>;
export type ButtonMessage = z.infer<typeof ButtonMessageSchema>;
export type BleMessage = z.infer<typeof BleMessageSchema>;
export type BatteryMessage = z.infer<typeof BatteryMessageSchema>;
export type LogMessage = z.infer<typeof LogMessageSchema>;

// ---------------------------------------------------------------------------------------------
// Device → Vision Pro (BLE TX) — the hub never sends these, but the types document the contract
// and the schemas let tests validate fixtures from protocol.md.
// ---------------------------------------------------------------------------------------------

export const WillChangeSchema = z.object({
  t: z.literal('will_change'),
  id,
  kind: z.enum(['theme', 'stat']),
  theme: ThemeSchema,
  region: z.tuple([z.number(), z.number(), z.number(), z.number()]),
});
export const ChangedSchema = z.object({ t: z.literal('changed'), id, theme: ThemeSchema });
export const StatsBroadcastSchema = z.object({ t: z.literal('stats'), ...StatsFieldsSchema.shape });
export const CelebrateBroadcastSchema = z.object({ t: z.literal('celebrate'), delta: count, followers: count });
export const CmdBroadcastSchema = z.object({ t: z.literal('cmd'), c: DirectorCommandSchema, arg: cmdArg.optional() });
export const VpBatterySchema = z.object({ t: z.literal('battery'), soc: z.number() }).loose();

export const DeviceToVpSchema = z.discriminatedUnion('t', [
  DeviceHelloSchema,
  ButtonMessageSchema,
  WillChangeSchema,
  ChangedSchema,
  StatsBroadcastSchema,
  CelebrateBroadcastSchema,
  CmdBroadcastSchema,
  VpBatterySchema,
  AckSchema,
]);
export type DeviceToVp = z.infer<typeof DeviceToVpSchema>;

// ---------------------------------------------------------------------------------------------
// Vision Pro → Device (BLE RX)
// ---------------------------------------------------------------------------------------------

export const VpAckSchema = z.object({ t: z.literal('ack'), id, ok: z.boolean() }).loose();

export const VpToDeviceSchema = z.discriminatedUnion('t', [
  SetModeCommandSchema,
  SetThemeCommandSchema,
  VpAckSchema,
  StatsCommandSchema,
  CelebrateCommandSchema,
  PlayCueCommandSchema,
  StripCommandSchema,
  PingCommandSchema,
]);
export type VpToDevice = z.infer<typeof VpToDeviceSchema>;

// ---------------------------------------------------------------------------------------------
// Hub → Vision Pro (WebSocket /vp, one-way broadcast, no ids)
// ---------------------------------------------------------------------------------------------

export const HubToVpSetThemeSchema = z.object({ t: z.literal('set_theme'), theme: ThemeOrWorldSchema });
/**
 * Recent-notes hint: sent only when the scraper produced a list the Vision Pro has not seen
 * (`rev` changed). It carries no note data — the app pulls `GET /api/notes` when `rev` moved.
 */
export const HubToVpNotesSchema = z.object({ t: z.literal('notes'), rev: count, count });

export const HubToVpSchema = z.discriminatedUnion('t', [
  StatsBroadcastSchema,
  CelebrateBroadcastSchema,
  HubToVpSetThemeSchema,
  CmdBroadcastSchema,
  HubToVpNotesSchema,
]);
export type HubToVp = z.infer<typeof HubToVpSchema>;

/** Every message shape on any link (for `encode`). */
export type AnyMessage = HubToDevice | DeviceToHub | DeviceToVp | VpToDevice | HubToVp;
