import fs from 'node:fs';
import path from 'node:path';
import { createApp, type App } from './app.ts';
import { HUB_ROOT, REPO_ROOT, loadEnv, type HubEnv } from './config.ts';
import type { RecentNote } from './scraper/notes.ts';

/** Offline by construction: a synthetic scraper, local covers, a separate data directory, no serial. */
export function createDemoApp(env?: HubEnv): App {
  const demoEnv = env ?? loadEnv({
    PORT: process.env['PORT'] ?? '8788',
    HUB_DATA_DIR: process.env['HUB_DATA_DIR'] ?? path.join(HUB_ROOT, 'data', 'demo'),
  });
  const app = createApp({ ...demoEnv, noDevice: true }, {
    serial: false,
    demo: true,
    host: '127.0.0.1',
    scrape: async () => ({
      status: 'ok', followers: app.store.current.followers,
      likes: app.store.current.likes, notes: 10,
      url: 'https://example.com', layout: 'none',
    }),
  });
  const tools = path.join(REPO_ROOT, 'visionos', 'SpatialCard', 'Tools');
  const payload = JSON.parse(fs.readFileSync(path.join(tools, 'fake-notes.json'), 'utf8')) as {
    notes: { id: string; title: string; likes: number; pinned: boolean; coverURL: string; url: string }[];
  };
  fs.mkdirSync(app.paths.covers, { recursive: true });
  const notes: RecentNote[] = payload.notes.map((n, order) => {
    const coverPath = app.covers.pathFor(n.id);
    if (!coverPath) throw new Error('Invalid demo note ID');
    fs.copyFileSync(path.join(tools, path.basename(n.coverURL)), coverPath);
    return {
      id: n.id, title: n.title, likes: n.likes, pinned: n.pinned,
      hidden: false, type: 'normal', coverSrc: null, coverPath, url: n.url, order,
    };
  });
  app.notesStore.update(notes, 'demo');
  return app;
}
