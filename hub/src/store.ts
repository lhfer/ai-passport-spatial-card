/**
 * Persistent follower statistics: `hub/data/stats.json` with the current sample and a bounded
 * history. `record()` diffs against the previous sample and reports what changed so the scheduler
 * can push to the device / celebrate. Seeds from card.json when the file does not exist.
 */
import fs from 'node:fs';
import path from 'node:path';

export interface StatsSample {
  followers: number;
  likes: number;
  notes: number;
  /** Unix seconds. */
  ts: number;
  /** `seed` | `scrape` | `manual` | `login` | ... */
  source: string;
}

export interface CurrentStats extends StatsSample {
  /** Follower net gain versus the previous sample (≥ 0). */
  delta: number;
}

export interface StatsFile {
  current: CurrentStats;
  history: CurrentStats[];
}

export interface RecordInput {
  followers: number;
  likes?: number | null | undefined;
  notes?: number | null | undefined;
  ts?: number | undefined;
  source: string;
}

export interface RecordEvents {
  statsChanged: boolean;
  followersDelta: number;
  previous: CurrentStats;
  current: CurrentStats;
}

export const HISTORY_LIMIT = 4000;

function isCount(v: unknown): v is number {
  return typeof v === 'number' && Number.isFinite(v) && v >= 0;
}

export function nowSeconds(): number {
  return Math.floor(Date.now() / 1000);
}

export class StatsStore {
  private data: StatsFile;

  constructor(
    readonly file: string,
    private readonly seed: StatsSample,
  ) {
    this.data = this.load();
  }

  get current(): CurrentStats {
    return this.data.current;
  }

  get history(): readonly CurrentStats[] {
    return this.data.history;
  }

  /** Last `n` history entries (oldest first). */
  recent(n: number): CurrentStats[] {
    return this.data.history.slice(-n);
  }

  private load(): StatsFile {
    try {
      const raw = JSON.parse(fs.readFileSync(this.file, 'utf8')) as Partial<StatsFile>;
      const c = raw.current;
      if (c && isCount(c.followers) && isCount(c.likes) && isCount(c.notes) && isCount(c.ts)) {
        const current: CurrentStats = {
          followers: c.followers,
          likes: c.likes,
          notes: c.notes,
          ts: c.ts,
          source: typeof c.source === 'string' ? c.source : 'unknown',
          delta: isCount(c.delta) ? c.delta : 0,
        };
        const history = Array.isArray(raw.history) ? raw.history.filter((h) => h && isCount(h.followers) && isCount(h.ts)) : [];
        return { current, history };
      }
    } catch {
      // missing or corrupt → seed
    }
    const current: CurrentStats = { ...this.seed, delta: 0 };
    return { current, history: [current] };
  }

  save(): void {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    const tmp = `${this.file}.tmp`;
    fs.writeFileSync(tmp, `${JSON.stringify(this.data, null, 2)}\n`);
    fs.renameSync(tmp, this.file);
  }

  /**
   * Records a new sample. Missing / null likes & notes keep the previous value (a scrape that only
   * managed to read followers must never overwrite good numbers with 0). Returns change events.
   */
  record(input: RecordInput): RecordEvents {
    if (!isCount(input.followers)) throw new Error(`invalid followers value: ${String(input.followers)}`);
    const previous = this.data.current;
    const current: CurrentStats = {
      followers: input.followers,
      likes: isCount(input.likes) ? input.likes : previous.likes,
      notes: isCount(input.notes) ? input.notes : previous.notes,
      ts: isCount(input.ts) ? input.ts : nowSeconds(),
      source: input.source,
      delta: Math.max(0, input.followers - previous.followers),
    };
    const statsChanged = current.followers !== previous.followers || current.likes !== previous.likes || current.notes !== previous.notes;
    this.data.current = current;
    this.data.history.push(current);
    if (this.data.history.length > HISTORY_LIMIT) this.data.history.splice(0, this.data.history.length - HISTORY_LIMIT);
    this.save();
    return { statsChanged, followersDelta: current.delta, previous, current };
  }

  /** Protocol `stats` fields for the current sample. */
  toStatsFields(): { followers: number; likes: number; notes: number; delta: number; ts: number } {
    const c = this.data.current;
    return { followers: c.followers, likes: c.likes, notes: c.notes, delta: c.delta, ts: c.ts };
  }
}

/** Seed sample from card.json's `stats` block. */
export function seedFromCard(stats: { followers: number; likes: number; notes: number; updatedAt: string; source?: string }): StatsSample {
  const parsed = Date.parse(stats.updatedAt);
  return {
    followers: stats.followers,
    likes: stats.likes,
    notes: stats.notes,
    ts: Number.isFinite(parsed) ? Math.floor(parsed / 1000) : 0,
    source: stats.source ?? 'seed',
  };
}
