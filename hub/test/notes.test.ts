import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';
import {
  clampTitle,
  degradedId,
  mergeNotes,
  NOTE_ID_RE,
  noteIdFromHref,
  notesFingerprint,
  notesFromAnchors,
  notesFromState,
  notesFromText,
  parseLikes,
  type NoteAnchor,
  type RecentNote,
} from '../src/scraper/notes.ts';

const FIXTURES = path.join(path.dirname(fileURLToPath(import.meta.url)), 'fixtures');
const read = (name: string) => fs.readFileSync(path.join(FIXTURES, name), 'utf8');
const anchors = JSON.parse(read('notes-anchors.json')) as NoteAnchor[];
const state = JSON.parse(read('notes-state.json')) as unknown;
const innerText = read('notes-text.txt');
const USER = '6510000000000000000000ff';
const AUTHOR = '测试作者';

const PINNED = '6a11111111111111111111a1';
const POPULAR = '6a22222222222222222222b2';
const HIDDEN = '6a33333333333333333333c3';
const FRESH = '6a44444444444444444444d4';
const STATE_ONLY = '6a55555555555555555555e5';

describe('parseLikes', () => {
  it('reads the counts the grid prints', () => {
    expect(parseLikes('168')).toBe(168);
    expect(parseLikes('1.2万')).toBe(12_000);
    expect(parseLikes('4,313')).toBe(4313);
    expect(parseLikes('1.5亿')).toBe(150_000_000);
    expect(parseLikes(1825)).toBe(1825);
  });
  it('treats the bare 赞 label as zero and rejects garbage', () => {
    expect(parseLikes('赞')).toBe(0);
    expect(parseLikes('点赞')).toBe(0);
    expect(parseLikes('')).toBe(0);
    expect(parseLikes('星际访客')).toBeNull();
    expect(parseLikes(undefined)).toBeNull();
  });
});

describe('noteIdFromHref', () => {
  it('takes the note id, not the profile id', () => {
    expect(noteIdFromHref(`https://www.xiaohongshu.com/user/profile/${USER}/${PINNED}?xsec_token=TEST`, USER)).toBe(PINNED);
    expect(noteIdFromHref(`/user/profile/${USER}/${PINNED}?xsec_token=TEST`, USER)).toBe(PINNED);
  });
  it('rejects the author link on the same card', () => {
    expect(noteIdFromHref(`https://www.xiaohongshu.com/user/profile/${USER}?channel_type=web_profile_page&xsec_token=TEST`, USER)).toBeNull();
    expect(noteIdFromHref('https://www.xiaohongshu.com/explore?xsec_token=TEST', USER)).toBeNull();
  });
});

describe('clampTitle', () => {
  it('clamps to 80 code points without splitting an emoji', () => {
    const long = `${'字'.repeat(79)}🌈尾巴`;
    const out = clampTitle(long);
    expect(Array.from(out)).toHaveLength(80);
    expect(out.endsWith('🌈')).toBe(true);
    expect(clampTitle('  两   个   空格  ')).toBe('两 个 空格');
  });
});

describe('per-source extraction', () => {
  it('DOM: one draft per note, author anchors skipped, markers and counts from the card text', () => {
    const drafts = notesFromAnchors(anchors, USER);
    expect(drafts.map((d) => d.id)).toEqual([PINNED, POPULAR, HIDDEN, FRESH]);
    expect(drafts[0]).toMatchObject({ pinned: true, likes: 168, title: '固定在最前面的一条笔记' });
    expect(drafts[1]).toMatchObject({ likes: 12_000 });
    expect(drafts[2]).toMatchObject({ hidden: true });
    expect(drafts[3]).toMatchObject({ likes: 0 }); // "赞"
    expect(drafts[0]!.url).toContain('xsec_token=TEST');
  });

  it('state: exact counts, type, urlPre cover, sticky / corner flags, index order', () => {
    const drafts = notesFromState(state, USER);
    expect(drafts.map((d) => d.id)).toEqual([PINNED, POPULAR, HIDDEN, FRESH, STATE_ONLY]);
    expect(drafts[0]).toMatchObject({ type: 'video', pinned: true, likes: 168 });
    expect(drafts[2]).toMatchObject({ hidden: true });
    expect(drafts[0]!.coverSrc).toContain('webp_prv_1');
    expect(drafts[0]!.url).toContain(`/user/profile/${USER}/${PINNED}`);
  });

  it('state: tolerates a plain array and an unknown shape', () => {
    expect(notesFromState({ notes: [[{ id: PINNED, noteCard: { displayTitle: 'x', interactInfo: { likedCount: '3' } } }]] }, USER)).toHaveLength(1);
    expect(notesFromState({ user: {} }, USER)).toEqual([]);
    expect(notesFromState(null, USER)).toEqual([]);
  });

  it('innerText: author-anchored title / marker / likes, sha1 ids', () => {
    const drafts = notesFromText(innerText, AUTHOR);
    expect(drafts).toHaveLength(4);
    expect(drafts[0]).toMatchObject({ title: '固定在最前面的一条笔记', pinned: true, likes: 168 });
    expect(drafts[1]).toMatchObject({ likes: 12_000 });
    expect(drafts[2]).toMatchObject({ hidden: true });
    expect(drafts[3]).toMatchObject({ likes: 0 });
    expect(drafts[0]!.id).toBe(degradedId('固定在最前面的一条笔记'));
    expect(notesFromText(innerText, undefined)).toEqual([]);
  });
});

describe('mergeNotes', () => {
  it('merges all three sources, drops hidden, moves pinned to the back', () => {
    const { notes, source, counts } = mergeNotes({ userId: USER, anchors, state, innerText, author: AUTHOR });
    expect(source).toBe('dom');
    expect(counts).toEqual({ dom: 4, state: 5, text: 0 }); // innerText is only consulted when both fail
    expect(notes.map((n) => n.id)).toEqual([POPULAR, FRESH, STATE_ONLY, PINNED]);
    expect(notes.every((n) => !n.hidden)).toBe(true);
    expect(notes.map((n) => n.order)).toEqual([0, 1, 2, 3]);
    expect(notes.every((n) => NOTE_ID_RE.test(n.id))).toBe(true);
  });

  it('takes the exact count and type from the state but keeps the DOM url', () => {
    const domOnly = mergeNotes({ userId: USER, anchors });
    const merged = mergeNotes({ userId: USER, anchors, state });
    expect(domOnly.notes.find((n) => n.id === PINNED)!.type).toBe('normal'); // DOM cannot tell
    const pinned = merged.notes.find((n) => n.id === PINNED)!;
    expect(pinned.type).toBe('video');
    expect(pinned.coverSrc).toContain('webp_prv_1'); // the smaller state cover wins
    expect(pinned.url).toBe(anchors[0]!.href); // …but the href (and its token) is the DOM's
  });

  it('dedupes the two anchors of one card and ignores unusable entries', () => {
    const dupes: NoteAnchor[] = [...anchors, ...anchors, { href: 'https://www.xiaohongshu.com/explore?xsec_token=TEST' }];
    expect(mergeNotes({ userId: USER, anchors: dupes }).notes).toHaveLength(4 - 1); // minus the hidden one
  });

  it('falls back to innerText when there is no DOM and no state', () => {
    const { notes, source } = mergeNotes({ userId: USER, innerText, author: AUTHOR });
    expect(source).toBe('text');
    expect(notes).toHaveLength(3); // hidden dropped
    expect(notes[0]!.id.startsWith('t:')).toBe(true);
    expect(notes[0]!.coverSrc).toBeNull();
    expect(notes.at(-1)).toMatchObject({ pinned: true }); // pinned still moves to the back
  });

  it('returns nothing (not a crash) when every source is empty', () => {
    expect(mergeNotes({ userId: USER })).toMatchObject({ notes: [], source: 'none' });
    expect(mergeNotes({ userId: USER, anchors: [], state: {}, innerText: '' }).notes).toEqual([]);
  });

  it('takes 10 and lets a pinned note fall off when there are more recent ones', () => {
    const many: NoteAnchor[] = [];
    for (let i = 0; i < 12; i++) {
      const id = `6a${String(i).padStart(2, '0')}0000000000000000000${i.toString(16)}`.slice(0, 24);
      many.push({ href: `https://www.xiaohongshu.com/user/profile/${USER}/${id}?xsec_token=TEST`, section: `第 ${i} 条\n${AUTHOR}\n${i}` });
    }
    many.push({ href: `https://www.xiaohongshu.com/user/profile/${USER}/${PINNED}?xsec_token=TEST`, section: `置顶\n固定的一条\n${AUTHOR}\n168` });
    const { notes } = mergeNotes({ userId: USER, anchors: many });
    expect(notes).toHaveLength(10);
    expect(notes.some((n) => n.id === PINNED)).toBe(false);
    expect(notes.every((n) => !n.pinned)).toBe(true);
  });

  it('honours an explicit limit', () => {
    expect(mergeNotes({ userId: USER, anchors, state, limit: 2 }).notes).toHaveLength(2);
  });
});

describe('notesFingerprint', () => {
  const base = mergeNotes({ userId: USER, anchors, state }).notes;
  it('ignores rotating tokens and cover paths', () => {
    const rotated: RecentNote[] = base.map((n) => ({ ...n, url: n.url.replace('TEST', 'ROTATED'), coverSrc: `${n.coverSrc}?v=2`, coverPath: '/tmp/x' }));
    expect(notesFingerprint(rotated)).toBe(notesFingerprint(base));
  });
  it('notices a new like count, a new title and a new note', () => {
    expect(notesFingerprint(base.map((n, i) => (i === 0 ? { ...n, likes: n.likes + 1 } : n)))).not.toBe(notesFingerprint(base));
    expect(notesFingerprint(base.map((n, i) => (i === 0 ? { ...n, title: '改了标题' } : n)))).not.toBe(notesFingerprint(base));
    expect(notesFingerprint(base.slice(1))).not.toBe(notesFingerprint(base));
  });
});
