/**
 * Pure normalisation of the 10 most recent notes from a Xiaohongshu profile page.
 *
 * Three sources, merged by note id (shapes confirmed with `pnpm hub probe`):
 *   1. **DOM** (primary) — `a[href*="xsec_token"]`: two anchors per card (cover + title) whose href is
 *      `…/user/profile/<userId>/<noteId>?xsec_token=…`, plus the card's `<section>` innerText
 *      (`[置顶|仅自己可见|已违规]\n标题\n作者\n点赞`) and the cover `<img>`.
 *   2. **`__INITIAL_STATE__`** (secondary) — `user.notes._rawValue[0][]`, each
 *      `{id, xsecToken, noteCard:{displayTitle, type, cover:{urlPre}, interactInfo:{likedCount, sticky},
 *      corner?:{type:"private"|"illegal"}}}`: exact like counts, note type, the small `urlPre` cover and
 *      the pinned / hidden flags. The state carries every note (62 on the probed profile), the DOM only
 *      the hydrated grid (30), so the state also fills the tail.
 *   3. **innerText** (fallback, degraded) — author line anchored: title is the line above, the marker the
 *      line above that, the like count the line below. No ids exist in this mode, so `id = "t:" + sha1(title)`.
 *
 * Normalisation: dedupe by id, drop hidden notes, keep page order but move pinned notes to the back,
 * take 10. Everything here is pure: no I/O, no Playwright, no clock.
 */
import { createHash } from 'node:crypto';

export const NOTE_ID_RE = /^[0-9a-f]{24}$/;
/** Degraded ids (innerText only) are `t:<sha1(title)>`. */
export const DEGRADED_ID_RE = /^t:[0-9a-f]{40}$/;
export const RECENT_NOTES_LIMIT = 10;
export const TITLE_LIMIT = 80;
export const XHS_ORIGIN = 'https://www.xiaohongshu.com';

export type NoteType = 'normal' | 'video';
export type NotesSource = 'dom' | 'state' | 'text' | 'none';

/** Markers Xiaohongshu prints above a card title. */
export const PINNED_MARKER = '置顶';
export const HIDDEN_MARKERS = ['仅自己可见', '已违规', '审核中', '仅粉丝可见'] as const;

export interface RecentNote {
  /** 24 hex chars, or `t:<sha1>` in degraded mode. */
  id: string;
  /** ≤ 80 code points. */
  title: string;
  likes: number;
  pinned: boolean;
  hidden: boolean;
  type: NoteType;
  /** Upstream cover URL (state `cover.urlPre` when known, else the grid `<img>`); null in degraded mode. */
  coverSrc: string | null;
  /** Absolute path of the downloaded cover in `hub/data/covers`, null until it is fetched. */
  coverPath: string | null;
  /** Absolute note URL exactly as the DOM gives it (carries `xsec_token`). */
  url: string;
  /** Final position, 0-based. */
  order: number;
}

/** One `a[href*="xsec_token"]` as collected by the scraper / probe. */
export interface NoteAnchor {
  href: string;
  hrefAttr?: string;
  text?: string;
  img?: string | null;
  section?: string;
}

export interface NotesInput {
  userId: string;
  anchors?: NoteAnchor[] | undefined;
  /** Parsed `window.__INITIAL_STATE__` (Vue refs tolerated). */
  state?: unknown;
  /** Whole-page innerText, used only when DOM and state gave nothing. */
  innerText?: string | undefined;
  /** Author nickname, for innerText anchoring. */
  author?: string | undefined;
  limit?: number | undefined;
}

export interface NotesResult {
  notes: RecentNote[];
  source: NotesSource;
  /** How many notes each source contributed before the merge. */
  counts: { dom: number; state: number; text: number };
}

/** Partial note collected from one source before the merge. */
interface Draft {
  id: string;
  title?: string;
  likes?: number;
  pinned?: boolean;
  hidden?: boolean;
  type?: NoteType;
  coverSrc?: string | null;
  url?: string;
  order: number;
}

// ---------------------------------------------------------------------------------------------
// small helpers
// ---------------------------------------------------------------------------------------------

/** Truncates by code point (not UTF-16 unit) so an emoji is never cut in half. */
export function clampTitle(text: string, limit = TITLE_LIMIT): string {
  const chars = Array.from(text.trim().replace(/\s+/gu, ' '));
  return chars.length <= limit ? chars.join('') : chars.slice(0, limit).join('');
}

/**
 * Like counts as the grid prints them: "赞" (the bare label = no likes yet) → 0, "1.2万" → 12000,
 * "4,313" → 4313, "168" → 168. Anything unreadable → null so a caller can keep a better value.
 */
export function parseLikes(text: string | number | null | undefined): number | null {
  if (typeof text === 'number') return Number.isFinite(text) && text >= 0 ? Math.round(text) : null;
  if (typeof text !== 'string') return null;
  const t = text.trim();
  if (t === '' || t === '赞' || t === '点赞') return 0;
  const m = /^(\d[\d,]*(?:\.\d+)?)\s*([万亿wWkK])?$/u.exec(t);
  if (!m) return null;
  const base = Number(m[1]!.replace(/,/g, ''));
  if (!Number.isFinite(base)) return null;
  const unit = m[2]?.toLowerCase();
  const factor = unit === '万' || unit === 'w' ? 10_000 : unit === '亿' ? 100_000_000 : unit === 'k' ? 1000 : 1;
  return Math.max(0, Math.round(base * factor));
}

/** Degraded id for a title-only note. */
export function degradedId(title: string): string {
  return `t:${createHash('sha1').update(title).digest('hex')}`;
}

export function isNoteId(id: string): boolean {
  return NOTE_ID_RE.test(id) || DEGRADED_ID_RE.test(id);
}

/**
 * Note id from a profile href: `/user/profile/<userId>/<noteId>?xsec_token=…`. The author link on the
 * same card is `/user/profile/<userId>?channel_type=…` and must not be mistaken for a note, so the id
 * has to be the *last* of at least two 24-hex segments and different from the profile owner.
 */
export function noteIdFromHref(href: string, userId?: string): string | null {
  const path = href.split(/[?#]/)[0] ?? '';
  const hex = path.split('/').filter((s) => NOTE_ID_RE.test(s));
  const id = hex[hex.length - 1];
  if (!id || hex.length < 2) return null;
  if (userId && id === userId) return null;
  return id;
}

function noteUrl(userId: string, id: string, token: string | undefined, origin = XHS_ORIGIN): string {
  const query = token ? `?xsec_token=${token}&xsec_source=pc_user` : '';
  return `${origin}/user/profile/${userId}/${id}${query}`;
}

function markerOf(line: string | undefined): { pinned: boolean; hidden: boolean } | null {
  if (line === undefined) return null;
  const t = line.trim();
  if (t === PINNED_MARKER) return { pinned: true, hidden: false };
  if ((HIDDEN_MARKERS as readonly string[]).includes(t)) return { pinned: false, hidden: true };
  return null;
}

/** Unwraps a Vue `ref` / `shallowRef` (`{_rawValue, _value}`); returns the value unchanged otherwise. */
function unref(value: unknown): unknown {
  if (value === null || typeof value !== 'object' || Array.isArray(value)) return value;
  const obj = value as Record<string, unknown>;
  if ('_rawValue' in obj) return obj['_rawValue'] ?? obj['_value'];
  if ('_value' in obj) return obj['_value'];
  return value;
}

function asRecord(value: unknown): Record<string, unknown> | null {
  return value !== null && typeof value === 'object' && !Array.isArray(value) ? (value as Record<string, unknown>) : null;
}

function asString(value: unknown): string | undefined {
  return typeof value === 'string' && value !== '' ? value : undefined;
}

// ---------------------------------------------------------------------------------------------
// sources
// ---------------------------------------------------------------------------------------------

/** Notes from the grid DOM: id + token (href), cover img and the card's four innerText lines. */
export function notesFromAnchors(anchors: readonly NoteAnchor[], userId: string): Draft[] {
  const byId = new Map<string, Draft>();
  for (const a of anchors) {
    const href = a.href || a.hrefAttr || '';
    const id = noteIdFromHref(href, userId);
    if (!id) continue;
    const existing = byId.get(id);
    const draft: Draft = existing ?? { id, order: byId.size };
    const url = /^https?:/i.test(href) ? href : `${XHS_ORIGIN}${href.startsWith('/') ? '' : '/'}${href}`;
    draft.url ??= url;
    if (a.img) draft.coverSrc ??= a.img;
    const lines = (a.section ?? '').split('\n').map((l) => l.trim()).filter((l) => l !== '');
    if (lines.length >= 3) {
      // […marker], title, author, likes
      const likes = parseLikes(lines[lines.length - 1]);
      const title = lines[lines.length - 3];
      const marker = markerOf(lines[lines.length - 4]);
      if (title) draft.title ??= title;
      if (likes !== null) draft.likes ??= likes;
      if (marker) {
        draft.pinned = draft.pinned || marker.pinned;
        draft.hidden = draft.hidden || marker.hidden;
      }
    }
    if (!existing) byId.set(id, draft);
  }
  return [...byId.values()];
}

/** Notes from `__INITIAL_STATE__`: exact like counts, type, the small cover and the pinned / hidden flags. */
export function notesFromState(state: unknown, userId: string): Draft[] {
  const root = asRecord(state);
  if (!root) return [];
  const user = asRecord(unref(root['user']));
  const raw = unref(user?.['notes'] ?? root['notes']);
  if (!Array.isArray(raw)) return [];
  // `user.notes` is one array per profile tab; the published notes are the first non-empty one.
  const list = (raw.find((tab) => Array.isArray(tab) && tab.length > 0) ?? (asRecord(raw[0]) ? raw : [])) as unknown[];
  const drafts: Draft[] = [];
  const seen = new Set<string>();
  for (const [i, entry] of list.entries()) {
    const item = asRecord(entry);
    if (!item) continue;
    const card = asRecord(item['noteCard']) ?? {};
    const id = asString(item['id']) ?? asString(card['noteId']);
    if (!id || !NOTE_ID_RE.test(id) || seen.has(id)) continue;
    seen.add(id);
    const interact = asRecord(card['interactInfo']) ?? {};
    const corner = asRecord(card['corner']);
    const cover = asRecord(card['cover']) ?? {};
    const token = asString(item['xsecToken']) ?? asString(card['xsecToken']);
    const likes = parseLikes((interact['likedCount'] as string | number | undefined) ?? null);
    const index = typeof item['index'] === 'number' ? item['index'] : i;
    const type: NoteType = card['type'] === 'video' ? 'video' : 'normal';
    const draft: Draft = {
      id,
      order: index,
      type,
      pinned: interact['sticky'] === true,
      hidden: corner !== null && (corner['type'] === 'private' || corner['type'] === 'illegal' || typeof corner['content'] === 'string'),
      url: noteUrl(userId, id, token),
    };
    const title = asString(card['displayTitle']);
    if (title) draft.title = title;
    if (likes !== null) draft.likes = likes;
    const src = asString(cover['urlPre']) ?? asString(cover['urlDefault']);
    if (src) draft.coverSrc = src;
    drafts.push(draft);
  }
  return drafts.sort((a, b) => a.order - b.order);
}

/**
 * Degraded mode: the whole-page innerText, anchored on the author line. The grid prints
 * `[marker]\n<title>\n<author>\n<likes>` per card, so an author line gives the title above it, the
 * marker above that and the like count below. Ids do not exist here — `t:<sha1(title)>` stands in.
 */
export function notesFromText(innerText: string, author: string | undefined): Draft[] {
  if (!author) return [];
  const lines = innerText.split('\n').map((l) => l.trim());
  const drafts: Draft[] = [];
  const seen = new Set<string>();
  for (const [i, line] of lines.entries()) {
    if (line !== author.trim()) continue;
    const title = lines[i - 1];
    if (!title || title === author.trim()) continue;
    const likes = parseLikes(lines[i + 1]);
    if (likes === null) continue; // the header's author line has no count under it
    const marker = markerOf(lines[i - 2]);
    const id = degradedId(title);
    if (seen.has(id)) continue;
    seen.add(id);
    drafts.push({
      id,
      order: drafts.length,
      title,
      likes,
      pinned: marker?.pinned ?? false,
      hidden: marker?.hidden ?? false,
      type: 'normal',
      coverSrc: null,
    });
  }
  return drafts;
}

// ---------------------------------------------------------------------------------------------
// merge + normalisation
// ---------------------------------------------------------------------------------------------

function finish(draft: Draft, userId: string): RecentNote | null {
  if (!isNoteId(draft.id)) return null;
  const title = clampTitle(draft.title ?? '');
  return {
    id: draft.id,
    title,
    likes: draft.likes ?? 0,
    pinned: draft.pinned ?? false,
    hidden: draft.hidden ?? false,
    type: draft.type ?? 'normal',
    coverSrc: draft.coverSrc ?? null,
    coverPath: null,
    url: draft.url ?? (NOTE_ID_RE.test(draft.id) ? noteUrl(userId, draft.id, undefined) : ''),
    order: draft.order,
  };
}

/**
 * Merges the three sources and normalises: dedupe by id, drop hidden notes, keep page order but move
 * pinned notes behind the rest (the fan should open on what is new, not on what is stuck to the top),
 * then take the first {@link RECENT_NOTES_LIMIT}.
 */
export function mergeNotes(input: NotesInput): NotesResult {
  const limit = input.limit ?? RECENT_NOTES_LIMIT;
  const dom = input.anchors ? notesFromAnchors(input.anchors, input.userId) : [];
  const state = notesFromState(input.state, input.userId);
  const text = dom.length === 0 && state.length === 0 && input.innerText ? notesFromText(input.innerText, input.author) : [];

  const merged = new Map<string, Draft>();
  // DOM first: it defines the page order and holds a fresh xsec_token in the href.
  for (const d of dom) merged.set(d.id, { ...d, order: merged.size });
  for (const s of state) {
    const existing = merged.get(s.id);
    if (existing) {
      // The state is authoritative for the exact numbers and flags; the DOM for url / order.
      if (s.title !== undefined) existing.title = s.title;
      if (s.likes !== undefined) existing.likes = s.likes;
      if (s.type !== undefined) existing.type = s.type;
      if (s.coverSrc !== undefined && s.coverSrc !== null) existing.coverSrc = s.coverSrc;
      if (s.pinned !== undefined) existing.pinned = s.pinned;
      existing.hidden = (existing.hidden ?? false) || (s.hidden ?? false);
    } else {
      merged.set(s.id, { ...s, order: 10_000 + s.order }); // state-only tail, after everything the DOM showed
    }
  }
  for (const t of text) if (!merged.has(t.id)) merged.set(t.id, t);

  const notes = [...merged.values()]
    .map((d) => finish(d, input.userId))
    .filter((n): n is RecentNote => n !== null && !n.hidden)
    .sort((a, b) => a.order - b.order);
  // stable partition: unpinned in page order first, pinned behind them
  const ordered = [...notes.filter((n) => !n.pinned), ...notes.filter((n) => n.pinned)].slice(0, limit);
  ordered.forEach((n, i) => (n.order = i));

  const source: NotesSource = ordered.length === 0 ? 'none' : dom.length > 0 ? 'dom' : state.length > 0 ? 'state' : 'text';
  return { notes: ordered, source, counts: { dom: dom.length, state: state.length, text: text.length } };
}

/** The fields that decide whether the list "changed" — tokens, cover paths and order are excluded. */
export function notesFingerprint(notes: readonly RecentNote[]): string {
  return JSON.stringify(notes.map((n) => [n.id, n.title, n.likes, n.pinned, n.type]));
}
