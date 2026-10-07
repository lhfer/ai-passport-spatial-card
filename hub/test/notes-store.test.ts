import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { NotesStore } from '../src/notes-store.ts';
import type { RecentNote } from '../src/scraper/notes.ts';

let dir: string;
let file: string;

beforeEach(() => {
  dir = fs.mkdtempSync(path.join(os.tmpdir(), 'hub-notes-'));
  file = path.join(dir, 'notes.json');
});
afterEach(() => fs.rmSync(dir, { recursive: true, force: true }));

const note = (id: string, over: Partial<RecentNote> = {}): RecentNote => ({
  id,
  title: `笔记 ${id.slice(0, 4)}`,
  likes: 10,
  pinned: false,
  hidden: false,
  type: 'normal',
  coverSrc: `http://cdn.example/${id}?token=TEST`,
  coverPath: null,
  url: `https://www.xiaohongshu.com/user/profile/6510000000000000000000ff/${id}?xsec_token=TEST`,
  order: 0,
  ...over,
});

const A = '6a11111111111111111111a1';
const B = '6a22222222222222222222b2';

describe('NotesStore', () => {
  it('starts empty and persists the first list at rev 1', () => {
    const store = new NotesStore(file);
    expect(store.summary).toMatchObject({ rev: 0, count: 0 });
    const update = store.update([note(A), note(B)], 'scrape');
    expect(update).toMatchObject({ changed: true, rev: 1, count: 2 });
    const onDisk = JSON.parse(fs.readFileSync(file, 'utf8'));
    expect(onDisk).toMatchObject({ rev: 1, source: 'scrape' });
    expect(onDisk.notes).toHaveLength(2);
    expect(new NotesStore(file).summary).toMatchObject({ rev: 1, count: 2 });
  });

  it('does not bump rev when only the tokens and cover paths changed', () => {
    const store = new NotesStore(file);
    store.update([note(A), note(B)], 'scrape');
    const rotated = [note(A, { url: 'https://www.xiaohongshu.com/x?xsec_token=ROTATED', coverPath: '/tmp/cover-a' }), note(B, { coverSrc: 'http://cdn.example/other' })];
    const update = store.update(rotated, 'scrape');
    expect(update).toMatchObject({ changed: false, rev: 1 });
    // …but the refreshed token and the cover path are still persisted
    expect(JSON.parse(fs.readFileSync(file, 'utf8')).notes[0].coverPath).toBe('/tmp/cover-a');
  });

  it('bumps rev and updatedAt on a new like count, a new note and a removal', () => {
    let clock = Date.parse('2026-09-18T10:00:00.000Z');
    const store = new NotesStore(file, () => new Date(clock));
    store.update([note(A), note(B)], 'scrape');
    const first = store.summary.updatedAt;
    clock += 60_000;
    expect(store.update([note(A, { likes: 11 }), note(B)], 'scrape')).toMatchObject({ changed: true, rev: 2 });
    expect(store.summary.updatedAt).not.toBe(first);
    expect(store.update([note(A, { likes: 11 })], 'scrape')).toMatchObject({ changed: true, rev: 3, count: 1 });
    expect(store.update([note(A, { likes: 11 })], 'scrape')).toMatchObject({ changed: false, rev: 3 });
  });

  it('looks a note up by id and ignores unknown ones', () => {
    const store = new NotesStore(file);
    store.update([note(A)], 'scrape');
    expect(store.get(A)?.title).toContain('笔记');
    expect(store.get('nope')).toBeUndefined();
  });

  it('survives a corrupt file and drops entries with impossible ids', () => {
    fs.writeFileSync(file, '{ not json');
    expect(new NotesStore(file).summary).toMatchObject({ rev: 0, count: 0 });
    fs.writeFileSync(file, JSON.stringify({ rev: 7, updatedAt: 'x', source: 's', notes: [note(A), { id: '../../etc/passwd', title: 'x' }, { id: B }] }));
    const store = new NotesStore(file);
    expect(store.summary).toMatchObject({ rev: 7, count: 1 });
    expect(store.current.notes[0]!.id).toBe(A);
  });
});
