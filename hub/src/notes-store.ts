/**
 * Persistent list of the 10 most recent notes: `hub/data/notes.json` = `{rev, updatedAt, source, notes}`.
 *
 * `rev` is the only thing the Vision Pro watches, so it must move **only when the list really changed**:
 * the comparison runs over {@link notesFingerprint} (id / title / likes / pinned / type), which leaves out
 * the rotating `xsec_token` in every url and the `coverPath` that appears once a cover is downloaded.
 * Without that, every scrape would bump `rev` and re-fan the cards for nothing.
 */
import fs from 'node:fs';
import path from 'node:path';
import { notesFingerprint, isNoteId, type RecentNote } from './scraper/notes.ts';

export interface NotesFile {
  /** Bumped on every real change; 0 means "never scraped". */
  rev: number;
  /** ISO timestamp of the last change (not of the last look). */
  updatedAt: string;
  /** `scrape` | `cli` | `seed` | ... */
  source: string;
  notes: RecentNote[];
}

export interface NotesUpdate {
  changed: boolean;
  rev: number;
  count: number;
  updatedAt: string;
}

const EMPTY: NotesFile = { rev: 0, updatedAt: new Date(0).toISOString(), source: 'none', notes: [] };

function sanitise(value: unknown): RecentNote[] {
  if (!Array.isArray(value)) return [];
  const out: RecentNote[] = [];
  for (const entry of value) {
    if (entry === null || typeof entry !== 'object') continue;
    const n = entry as Partial<RecentNote>;
    if (typeof n.id !== 'string' || !isNoteId(n.id) || typeof n.title !== 'string') continue;
    out.push({
      id: n.id,
      title: n.title,
      likes: typeof n.likes === 'number' && n.likes >= 0 ? n.likes : 0,
      pinned: n.pinned === true,
      hidden: false,
      type: n.type === 'video' ? 'video' : 'normal',
      coverSrc: typeof n.coverSrc === 'string' ? n.coverSrc : null,
      coverPath: typeof n.coverPath === 'string' ? n.coverPath : null,
      url: typeof n.url === 'string' ? n.url : '',
      order: typeof n.order === 'number' ? n.order : out.length,
    });
  }
  return out;
}

export class NotesStore {
  private data: NotesFile;

  constructor(
    readonly file: string,
    private readonly now: () => Date = () => new Date(),
  ) {
    this.data = this.load();
  }

  get current(): NotesFile {
    return this.data;
  }

  get rev(): number {
    return this.data.rev;
  }

  get count(): number {
    return this.data.notes.length;
  }

  get(id: string): RecentNote | undefined {
    return this.data.notes.find((n) => n.id === id);
  }

  /** `{rev, count, updatedAt}` — the panel state and the `/vp` hint frame both use exactly this. */
  get summary(): { rev: number; count: number; updatedAt: string } {
    return { rev: this.data.rev, count: this.data.notes.length, updatedAt: this.data.updatedAt };
  }

  private load(): NotesFile {
    try {
      const raw = JSON.parse(fs.readFileSync(this.file, 'utf8')) as Partial<NotesFile>;
      const notes = sanitise(raw.notes);
      return {
        rev: typeof raw.rev === 'number' && raw.rev >= 0 ? Math.floor(raw.rev) : 0,
        updatedAt: typeof raw.updatedAt === 'string' ? raw.updatedAt : EMPTY.updatedAt,
        source: typeof raw.source === 'string' ? raw.source : 'unknown',
        notes,
      };
    } catch {
      return { ...EMPTY, notes: [] };
    }
  }

  save(): void {
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    const tmp = `${this.file}.tmp`;
    fs.writeFileSync(tmp, `${JSON.stringify(this.data, null, 2)}\n`);
    fs.renameSync(tmp, this.file);
  }

  /**
   * Replaces the list. `rev` and `updatedAt` move only when the fingerprint changed; the file is still
   * rewritten either way so a refreshed token or a newly downloaded cover is not lost.
   */
  update(notes: RecentNote[], source: string): NotesUpdate {
    const changed = notesFingerprint(notes) !== notesFingerprint(this.data.notes);
    this.data = {
      rev: changed ? this.data.rev + 1 : this.data.rev,
      updatedAt: changed ? this.now().toISOString() : this.data.updatedAt,
      source,
      notes,
    };
    this.save();
    return { changed, rev: this.data.rev, count: notes.length, updatedAt: this.data.updatedAt };
  }
}
