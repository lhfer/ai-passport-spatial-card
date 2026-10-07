/**
 * Hub configuration: `assets/card/card.json` (schema 2, the single source of truth for profile,
 * stats seed, themes and device geometry) plus a handful of environment variables.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { z } from 'zod';

export const HUB_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const REPO_ROOT = path.resolve(HUB_ROOT, '..');
export const DEFAULT_CARD_PATH = path.join(REPO_ROOT, 'assets', 'card', 'card.json');

export const CardThemeSchema = z.object({
  id: z.enum(['base', 'neon-city', 'data-nebula']),
  label: z.string(),
  world: z.string().nullable(),
});

export const CardSchema = z
  .object({
    schema: z.literal(2),
    profile: z.object({
      name: z.string().min(1),
      handle: z.string().min(1),
      location: z.string().default(''),
      tags: z.array(z.string()).default([]),
      bullets: z.array(z.string()).default([]),
      avatar: z.string().default('avatar.png'),
    }),
    links: z.array(z.object({ label: z.string(), url: z.string() })).default([]),
    xhs: z.object({ userId: z.string().min(1) }),
    stats: z.object({
      followers: z.number().int().nonnegative(),
      likes: z.number().int().nonnegative(),
      notes: z.number().int().nonnegative(),
      updatedAt: z.string(),
      source: z.string().default('seed'),
    }),
    themes: z.array(CardThemeSchema).min(1),
    device: z.object({
      model: z.string().default('FoloToy AI Passport'),
      screenPx: z.tuple([z.number().int().positive(), z.number().int().positive()]),
      activeAreaMm: z.tuple([z.number().positive(), z.number().positive()]),
      thicknessMm: z.number().positive().optional(),
      cornerRadiusPx: z.number().int().nonnegative(),
      dynamicStripPx: z.number().int().nonnegative(),
    }),
  })
  .loose();

export type Card = z.infer<typeof CardSchema>;
export type CardTheme = z.infer<typeof CardThemeSchema>;

/** Loads and validates card.json. Throws with a readable message when the schema does not match. */
export function loadCard(cardPath: string = DEFAULT_CARD_PATH): Card {
  const text = fs.readFileSync(cardPath, 'utf8');
  const result = CardSchema.safeParse(JSON.parse(text));
  if (!result.success) {
    throw new Error(`${cardPath} does not match card schema 2:\n${z.prettifyError(result.error)}`);
  }
  return result.data;
}

/** Absolute path of the avatar referenced by card.json (relative to the card file). */
export function avatarPath(card: Card, cardPath: string = DEFAULT_CARD_PATH): string {
  return path.resolve(path.dirname(cardPath), card.profile.avatar);
}

export interface QuietHours {
  /** Start hour, inclusive (local time, 0-23). */
  start: number;
  /** End hour, exclusive (local time, 0-23). Ranges may wrap past midnight (e.g. 23-06). */
  end: number;
}

export interface HubEnv {
  port: number;
  scrapeIntervalMin: number;
  quietHours: QuietHours;
  headed: boolean;
  /** HUB_DEBUG=1: verbose logs and a page-text dump from the scraper. */
  debug: boolean;
  /** HUB_NO_DEVICE=1: never open the USB serial port (scrape / store only). */
  noDevice: boolean;
  dataDir: string;
  cardPath: string;
}

export function parseQuietHours(text: string | undefined, fallback: QuietHours = { start: 2, end: 7 }): QuietHours {
  if (!text) return fallback;
  const m = /^\s*(\d{1,2})\s*-\s*(\d{1,2})\s*$/.exec(text);
  if (!m) return fallback;
  const start = Number(m[1]);
  const end = Number(m[2]);
  if (start < 0 || start > 23 || end < 0 || end > 24) return fallback;
  return { start, end };
}

export function loadEnv(env: NodeJS.ProcessEnv = process.env): HubEnv {
  const port = Number(env['PORT'] ?? 8787);
  const scrapeIntervalMin = Number(env['SCRAPE_INTERVAL_MIN'] ?? 45);
  return {
    port: Number.isFinite(port) && port > 0 ? port : 8787,
    scrapeIntervalMin: Number.isFinite(scrapeIntervalMin) && scrapeIntervalMin > 0 ? scrapeIntervalMin : 45,
    quietHours: parseQuietHours(env['QUIET_HOURS']),
    headed: env['HEADED'] === '1' || env['HEADED'] === 'true',
    debug: env['HUB_DEBUG'] === '1' || env['HUB_DEBUG'] === 'true',
    noDevice: env['HUB_NO_DEVICE'] === '1' || env['HUB_NO_DEVICE'] === 'true',
    dataDir: env['HUB_DATA_DIR'] ? path.resolve(env['HUB_DATA_DIR']) : path.join(HUB_ROOT, 'data'),
    cardPath: env['CARD_PATH'] ? path.resolve(env['CARD_PATH']) : DEFAULT_CARD_PATH,
  };
}
