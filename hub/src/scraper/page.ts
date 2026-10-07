/**
 * Browser-side primitives shared by the probe (`pnpm hub probe`) and the scraper (`pnpm hub scrape`):
 * the profile URLs, the one-round-trip page collector and the note-grid wait.
 *
 * The collector is a **string**, not a closure: `tsx`/esbuild rewrites named function expressions with a
 * `__name()` helper that does not exist in the page, so a transpiled closure handed to `page.evaluate`
 * dies with "ReferenceError: __name is not defined".
 */
import type { Page } from 'playwright';
import type { Logger } from '../log.ts';
import type { NoteAnchor } from './notes.ts';

export function profileUrl(userId: string): string {
  return `https://www.xiaohongshu.com/user/profile/${userId}`;
}
export const CREATOR_HOME_URL = 'https://creator.xiaohongshu.com/creator/home';

/** One `a[href*="xsec_token"]` plus the innerText of the card it lives in. */
export type ProbeAnchor = NoteAnchor & { href: string; hrefAttr: string; text: string; img: string | null; section: string };

export interface Collected {
  anchors: ProbeAnchor[];
  /** `window.__INITIAL_STATE__` as JSON (functions dropped, cycles cut), or null. */
  stateText: string | null;
  stateError: string | null;
  innerText: string;
}

/**
 * Browser-side collector, kept as a **string** on purpose: `tsx`/esbuild rewrites named function
 * expressions with a `__name()` helper that does not exist in the page, so a transpiled closure
 * passed to `page.evaluate` dies with "ReferenceError: __name is not defined".
 */
export const COLLECT_SCRIPT = `(function () {
  function pickImg(root) {
    if (!root) return null;
    var img = root.querySelector('img');
    if (!img) return null;
    var src = img.getAttribute('src') || img.getAttribute('data-src') || '';
    if (src) return src;
    var srcset = img.getAttribute('srcset') || '';
    if (!srcset) return null;
    var first = srcset.split(',')[0] || '';
    return first.trim().split(' ')[0] || null;
  }
  var anchors = Array.prototype.slice.call(document.querySelectorAll('a[href*="xsec_token"]')).map(function (a) {
    var card = a.closest('section') || a.parentElement;
    return {
      href: a.href,
      hrefAttr: a.getAttribute('href') || '',
      text: (a.innerText || '').trim().slice(0, 300),
      img: pickImg(a) || pickImg(card),
      section: ((card && card.innerText) || '').trim().slice(0, 400)
    };
  });
  var stateText = null;
  var stateError = null;
  var budget = { n: 0 };
  function safe(v, ancestors, depth) {
    if (v === null) return null;
    var t = typeof v;
    if (t === 'function' || t === 'symbol' || t === 'undefined') return undefined;
    if (t === 'bigint') return String(v);
    if (t !== 'object') return v;
    if (depth > 14) return '[depth]';
    // Only ANCESTORS count as circular: a WeakSet of everything seen would turn shared
    // subtrees (Vue keeps _rawValue and _value on the same array) into '[circular]'.
    if (ancestors.indexOf(v) !== -1) return '[circular]';
    if (budget.n++ > 400000) return '[truncated]';
    ancestors.push(v);
    var out;
    try {
      if (Array.isArray(v)) {
        out = [];
        for (var i = 0; i < v.length && i < 2000; i++) out.push(safe(v[i], ancestors, depth + 1));
      } else {
        out = {};
        var keys = Object.keys(v);
        for (var j = 0; j < keys.length; j++) {
          var k = keys[j];
          if (k === 'dep' || k.indexOf('__v_') === 0) continue; // Vue reactivity internals
          var child = safe(v[k], ancestors, depth + 1);
          if (child !== undefined) out[k] = child;
        }
      }
    } catch (err2) {
      out = '[error:' + String(err2 && err2.message ? err2.message : err2) + ']';
    }
    ancestors.pop();
    return out;
  }
  try {
    var raw = window.__INITIAL_STATE__;
    if (raw === undefined) stateError = 'window.__INITIAL_STATE__ is undefined';
    else stateText = JSON.stringify(safe(raw, [], 0));
  } catch (err) {
    stateError = String(err && err.message ? err.message : err);
  }
  return { anchors: anchors, stateText: stateText, stateError: stateError, innerText: (document.body && document.body.innerText) || '' };
})()`;

/** Everything the page can tell us, collected in one round trip. */
export async function collectPage(page: Page): Promise<Collected> {
  return page.evaluate(COLLECT_SCRIPT) as Promise<Collected>;
}

/** Count of hydrated note links; used to decide when the grid stopped growing. */
export async function anchorCount(page: Page): Promise<number> {
  return (page.evaluate('document.querySelectorAll(\'a[href*="xsec_token"]\').length') as Promise<number>).catch(() => 0);
}

/** Polls the note grid until the anchor count repeats (hydrated) or the budget runs out. */
export async function waitForNoteGrid(page: Page, budgetMs: number, log: Logger): Promise<number> {
  const deadline = Date.now() + budgetMs;
  let previous = -1;
  let count = await anchorCount(page);
  while (Date.now() < deadline) {
    if (count > 0 && count === previous) return count;
    await page.waitForTimeout(500);
    previous = count;
    count = await anchorCount(page);
  }
  log.warn(`note grid never settled (last count ${count})`);
  return count;
}

