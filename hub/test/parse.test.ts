import { describe, expect, it } from 'vitest';
import { looksLikeLoginWall, parseCount, parseProfileText } from '../src/scraper/parse.ts';

// Realistic `document.body.innerText` excerpts.
const PROFILE_PAGE = `星际访客
小红书号：SpatialExplorer
IP属地：浙江
把创意带进空间 | 分享你的发现 | 做一点有趣的东西
12 关注 4313 粉丝 4.4万 获赞与收藏
关注
笔记
收藏
点赞
用 Claude Code 做了个空间名片
128 
2小时前`;

const PROFILE_PAGE_MULTILINE = `星际访客
12
关注
4313
粉丝
4.4万
获赞与收藏
笔记 收藏 点赞`;

const CREATOR_HOME = `创作者中心
数据概览
粉丝数 4,313
获赞与收藏 44,012
笔记数 128
近7天 新增粉丝 5`;

/**
 * Verbatim excerpt of the real page text (hub/data/failures/debug-2026-09-18T15-07-28-444Z.txt,
 * git-ignored), trimmed to the profile header and the feed tail that used to poison the notes count.
 * Counts here are public profile numbers. The tail is what made the old parser report notes=1825:
 * "1825" is the like count of the last note card, and the "笔记・31" right after it is the 收藏
 * sub-tab strip (collected notes / albums / files), not the published-note count.
 */
const REAL_PROFILE_2026_09_18 = `星际访客
小红书号：SpatialExplorer
IP属地：浙江
🌈 把创意带进空间
✨ 分享日常使用AI 工具 / 技巧..
🎮 itch 开发一些小游戏..
💬喜欢聊天，欢迎戳戳和私信
Hello, World
39
关注
4344
粉丝
4.4万
获赞与收藏
笔记
收藏
点赞
置顶
我已经不敢再让 Kimi k3 生成东西了！
星际访客
168
GPT-6来了，全网38个案例一次看完！
星际访客
5663
见证历史！3分钟搞懂 GPT-6 Astra
星际访客
1825
笔记・31
专辑・0
文件・2
你还没有收藏任何内容哦
你还没有赞过任何内容哦`;

const LOGIN_WALL = `小红书
登录后查看更多精彩内容
手机号登录
验证码登录
扫码登录
我已阅读并同意《用户协议》《隐私政策》`;

describe('parseCount', () => {
  it('handles plain, comma, 万, 亿 and w/k suffixes', () => {
    expect(parseCount('4313')).toBe(4313);
    expect(parseCount('4,313')).toBe(4313);
    expect(parseCount('4.4万')).toBe(44000);
    expect(parseCount('4.45 万')).toBe(44500);
    expect(parseCount('1.2亿')).toBe(120_000_000);
    expect(parseCount('10w')).toBe(100_000);
    expect(parseCount('3.5k')).toBe(3500);
  });

  it('never returns 0 or NaN', () => {
    expect(parseCount('0')).toBeNull();
    expect(parseCount('')).toBeNull();
    expect(parseCount('abc')).toBeNull();
    expect(parseCount('NaN')).toBeNull();
  });
});

describe('parseProfileText', () => {
  it('reads the web profile header (number before label)', () => {
    const r = parseProfileText(PROFILE_PAGE);
    expect(r.layout).toBe('number-first');
    expect(r.followers).toBe(4313);
    expect(r.likes).toBe(44000);
    // the tab strip "笔记" has no count → null, never 0
    expect(r.notes).toBeNull();
  });

  it('reads one-token-per-line innerText', () => {
    const r = parseProfileText(PROFILE_PAGE_MULTILINE);
    expect(r).toMatchObject({ followers: 4313, likes: 44000, notes: null, layout: 'number-first' });
  });

  it('reads the creator centre (label before number)', () => {
    const r = parseProfileText(CREATOR_HOME);
    expect(r).toMatchObject({ followers: 4313, likes: 44012, notes: 128, layout: 'label-first' });
  });

  it('does not confuse the 关注 count with followers', () => {
    expect(parseProfileText('99 关注 1 粉丝 2 获赞与收藏').followers).toBe(1);
    expect(parseProfileText('关注 99 粉丝 1 获赞与收藏 2').followers).toBe(1);
  });

  it('returns nulls on a login wall', () => {
    const r = parseProfileText(LOGIN_WALL);
    expect(r).toEqual({ followers: null, likes: null, notes: null, following: null, layout: 'none' });
  });
});

describe('parseProfileText — real profile dump (2026-09-18)', () => {
  it('reads the header counts of the real page', () => {
    const r = parseProfileText(REAL_PROFILE_2026_09_18);
    expect(r.layout).toBe('number-first');
    expect(r.followers).toBe(4344);
    expect(r.likes).toBe(44000); // "4.4万"
    expect(r.following).toBe(39); // 关注 is parsed explicitly so it can never stand in for another count
  });

  it('returns null for notes: the web profile shows no published-note count', () => {
    // The bare 笔记 is a tab label with no count; "笔记・31" belongs to the 收藏 sub-tab strip.
    // null (never 0) → StatsStore keeps the previous value.
    expect(parseProfileText(REAL_PROFILE_2026_09_18).notes).toBeNull();
  });

  it('never reports the feed like count (1825) or the 收藏 sub-tab count (31) as notes', () => {
    const r = parseProfileText(REAL_PROFILE_2026_09_18);
    expect(r.notes).not.toBe(1825);
    expect(r.notes).not.toBe(31);
    expect(r.notes).not.toBe(39); // nor the 关注 count
    expect(r.followers).toBe(4344);
  });

  it('reads an explicit "N 篇笔记" count when a page has one', () => {
    expect(parseProfileText(`${REAL_PROFILE_2026_09_18}\n共 248 篇笔记`).notes).toBe(248);
    expect(parseProfileText('39 关注 4344 粉丝 4.4万 获赞与收藏 248篇笔记').notes).toBe(248);
  });
});

describe('looksLikeLoginWall', () => {
  it('detects login URLs', () => {
    expect(looksLikeLoginWall(PROFILE_PAGE, 'https://www.xiaohongshu.com/login?redirect=...')).toBe(true);
  });

  it('detects login copy without counts', () => {
    expect(looksLikeLoginWall(LOGIN_WALL, 'https://www.xiaohongshu.com/user/profile/000000000000000000000001')).toBe(true);
  });

  it('is false when counts are readable even if the page mentions 登录', () => {
    expect(looksLikeLoginWall(`${PROFILE_PAGE}\n登录后查看更多`, 'https://www.xiaohongshu.com/user/profile/x')).toBe(false);
  });

  it('is false for a blank page without login hints (caller treats it as a timeout)', () => {
    expect(looksLikeLoginWall('', 'https://www.xiaohongshu.com/user/profile/x')).toBe(false);
  });
});
