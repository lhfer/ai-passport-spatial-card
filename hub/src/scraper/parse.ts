/**
 * Pure text parsing for Xiaohongshu profile pages. Works on `document.body.innerText`, which on the
 * web profile reads like "39 关注 4344 粉丝 4.4万 获赞与收藏" (number before label) and on the creator
 * centre like "粉丝数 4313" (label before number). Both orders are handled by scoring the two
 * layouts. Zero / NaN are never returned as values.
 *
 * 笔记 (published notes) is deliberately NOT read by adjacency. On the web profile the bare 笔记 is a
 * tab label that carries no count, and the only "笔记・N" on the page belongs to the 收藏 sub-tab strip
 * ("笔记・31 专辑・0 文件・2" = collected notes / albums / files — `tabPublic.collectionNote`), which is
 * not the published-note count. Taking the number next to a bare 笔记 used to yield the like count of
 * the last note card in the feed (e.g. 1825). Published notes come only from 笔记数 (creator centre) or
 * an explicit "N 篇笔记"; when neither is present `notes` is null and the store keeps its last value.
 */

export interface ParsedStats {
  followers: number | null;
  likes: number | null;
  notes: number | null;
  /** 关注 — parsed explicitly so a following count can never be reported as followers or notes. */
  following: number | null;
  /** Which layout was detected. */
  layout: 'number-first' | 'label-first' | 'none';
}

const LABELS = ['关注', '粉丝数', '粉丝', '获赞与收藏', '获赞', '笔记数', '笔记'] as const;
type Label = (typeof LABELS)[number];

/**
 * Labels allowed to take their value from an adjacent number token. Bare 笔记 is excluded on purpose
 * (see the file header): it is a tab label, and the only number beside it belongs to another count.
 */
const ADJACENT_LABELS = new Set<Label>(['关注', '粉丝数', '粉丝', '获赞与收藏', '获赞', '笔记数']);

// Labels must not be glued to a preceding Han character ("新增粉丝" is not the followers label).
const TOKEN_RE = /(\d[\d,]*(?:\.\d+)?\s*[万亿wWkK]?)|(?<!\p{Script=Han})(获赞与收藏|粉丝数|笔记数|关注|粉丝|获赞|笔记)/gu;

const NUMBER = String.raw`\d[\d,]*(?:\.\d+)?\s*[万亿wWkK]?`;

/**
 * Notes-specific patterns: a count that can only be the published-note count. "笔记・N" / "笔记 · N"
 * is NOT here — on the web profile that strip is the 收藏 sub-tab (collected notes).
 */
const NOTES_PATTERNS = [
  new RegExp(String.raw`笔记数\s*[:：]?\s*(${NUMBER})`, 'u'),
  new RegExp(String.raw`(${NUMBER})\s*篇\s*笔记`, 'u'),
] as const;

/** "4.4万" → 44000, "1.2亿" → 120000000, "4,313" → 4313, "10w" → 100000; 0, NaN, garbage → null. */
export function parseCount(text: string): number | null {
  const m = /^\s*(\d[\d,]*(?:\.\d+)?)\s*([万亿wWkK])?\s*$/.exec(text);
  if (!m) return null;
  const base = Number(m[1]!.replace(/,/g, ''));
  if (!Number.isFinite(base)) return null;
  const unit = m[2]?.toLowerCase();
  const factor = unit === '万' || unit === 'w' ? 10_000 : unit === '亿' ? 100_000_000 : unit === 'k' ? 1000 : 1;
  const value = Math.round(base * factor);
  return value > 0 ? value : null;
}

interface Token {
  kind: 'number' | 'label';
  text: string;
}

function tokenise(text: string): Token[] {
  const tokens: Token[] = [];
  for (const m of text.matchAll(TOKEN_RE)) {
    if (m[1] !== undefined) tokens.push({ kind: 'number', text: m[1] });
    else if (m[2] !== undefined) tokens.push({ kind: 'label', text: m[2] });
  }
  return tokens;
}

function assign(tokens: Token[], direction: -1 | 1): Map<Label, number> {
  const out = new Map<Label, number>();
  tokens.forEach((tok, i) => {
    if (tok.kind !== 'label') return;
    const label = tok.text as Label;
    if (!ADJACENT_LABELS.has(label)) return; // bare 笔记 never takes an adjacent number
    if (out.has(label)) return; // first occurrence wins (the profile header comes before the note list)
    const neighbour = tokens[i + direction];
    if (!neighbour || neighbour.kind !== 'number') return;
    const value = parseCount(neighbour.text);
    if (value !== null) out.set(label, value);
  });
  return out;
}

/** Published-note count from an unambiguous notes pattern, or null when the page shows none. */
function notesFromPatterns(text: string): number | null {
  for (const re of NOTES_PATTERNS) {
    const m = re.exec(text);
    if (!m) continue;
    const value = parseCount(m[1]!);
    if (value !== null) return value;
  }
  return null;
}

export function parseProfileText(text: string): ParsedStats {
  const tokens = tokenise(text);
  const numberFirst = assign(tokens, -1);
  const labelFirst = assign(tokens, 1);
  const score = (m: Map<Label, number>) => ['粉丝', '粉丝数', '获赞与收藏', '获赞', '关注'].filter((l) => m.has(l as Label)).length;
  const sNumber = score(numberFirst);
  const sLabel = score(labelFirst);
  if (sNumber === 0 && sLabel === 0) return { followers: null, likes: null, notes: null, following: null, layout: 'none' };
  const chosen = sNumber >= sLabel ? numberFirst : labelFirst;
  const layout = sNumber >= sLabel ? 'number-first' : 'label-first';
  const followers = chosen.get('粉丝数') ?? chosen.get('粉丝') ?? null;
  const likes = chosen.get('获赞与收藏') ?? chosen.get('获赞') ?? null;
  const notes = chosen.get('笔记数') ?? notesFromPatterns(text);
  const following = chosen.get('关注') ?? null;
  return { followers, likes, notes, following, layout };
}

const LOGIN_HINTS = ['登录后查看', '扫码登录', '登录即可', '手机号登录', '请先登录', '立即登录', '登录发现更多精彩', '验证码登录', 'login'];

/** Heuristic login-wall detection: URL contains "login", or login copy is on the page and no followers count is. */
export function looksLikeLoginWall(text: string, url: string, parsed: ParsedStats = parseProfileText(text)): boolean {
  if (/login|passport/i.test(url)) return true;
  if (parsed.followers !== null) return false;
  const lower = text.toLowerCase();
  return LOGIN_HINTS.some((h) => lower.includes(h.toLowerCase()));
}
