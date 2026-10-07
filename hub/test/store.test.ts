import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { seedFromCard, StatsStore } from '../src/store.ts';

const seed = seedFromCard({ followers: 4313, likes: 44000, notes: 0, updatedAt: '2026-09-18T00:00:00+08:00', source: 'seed' });
let dir: string;
let file: string;

beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hub-store-'));
  file = path.join(dir, 'stats.json');
});
afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

describe('StatsStore', () => {
  it('seeds from card.json when the file is missing', () => {
    const s = new StatsStore(file, seed);
    expect(s.current).toMatchObject({ followers: 4313, likes: 44000, notes: 0, delta: 0, source: 'seed' });
    expect(s.current.ts).toBe(Math.floor(Date.parse('2026-09-18T00:00:00+08:00') / 1000));
    expect(fs.existsSync(file)).toBe(false); // nothing written until a record
  });

  it('computes a non-negative delta and reports events', () => {
    const s = new StatsStore(file, seed);
    const up = s.record({ followers: 4318, likes: 44012, notes: 128, ts: 1758153600, source: 'scrape' });
    expect(up).toMatchObject({ statsChanged: true, followersDelta: 5 });
    expect(s.current).toMatchObject({ followers: 4318, likes: 44012, notes: 128, delta: 5, ts: 1758153600, source: 'scrape' });

    const down = s.record({ followers: 4316, source: 'scrape' });
    expect(down.followersDelta).toBe(0);
    expect(s.current.delta).toBe(0);
    expect(s.current.followers).toBe(4316);

    const same = s.record({ followers: 4316, source: 'scrape' });
    expect(same.statsChanged).toBe(false);
  });

  it('keeps previous likes/notes when a sample omits them (never overwrites with 0)', () => {
    const s = new StatsStore(file, seed);
    s.record({ followers: 4318, likes: 44012, notes: 128, source: 'scrape' });
    s.record({ followers: 4320, likes: null, notes: undefined, source: 'scrape' });
    expect(s.current).toMatchObject({ followers: 4320, likes: 44012, notes: 128, delta: 2 });
  });

  it('persists and reloads', () => {
    const s = new StatsStore(file, seed);
    s.record({ followers: 4400, source: 'manual' });
    const again = new StatsStore(file, seed);
    expect(again.current).toMatchObject({ followers: 4400, source: 'manual', delta: 87 });
    expect(again.history.length).toBe(2);
    expect(again.toStatsFields()).toEqual({ followers: 4400, likes: 44000, notes: 0, delta: 87, ts: again.current.ts });
  });

  it('falls back to the seed when the file is corrupt', () => {
    fs.writeFileSync(file, '{not json');
    const s = new StatsStore(file, seed);
    expect(s.current.followers).toBe(4313);
  });

  it('rejects invalid follower values', () => {
    const s = new StatsStore(file, seed);
    expect(() => s.record({ followers: Number.NaN, source: 'scrape' })).toThrow();
    expect(() => s.record({ followers: -1, source: 'scrape' })).toThrow();
  });
});
