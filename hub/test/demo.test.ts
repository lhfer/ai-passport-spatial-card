import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { describe, it, expect, vi } from 'vitest';
import { loadEnv } from '../src/config.ts';
import { createDemoApp } from '../src/demo.ts';

describe('public offline demo', () => {
  it('refreshes and celebrates without network scraping or opening a device', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'spatial-demo-test-'));
    const network = vi.spyOn(globalThis, 'fetch').mockRejectedValue(new Error('Network forbidden'));
    const app = createDemoApp({ ...loadEnv(), port: 0, dataDir: dir });
    const serial = vi.spyOn(app.serial, 'start');
    try {
      await app.start();
      expect(serial).not.toHaveBeenCalled();
      expect(app.notesStore.count).toBe(10);
      for (const note of app.notesStore.current.notes) {
        expect(note.url.startsWith('https://example.com/')).toBe(true);
        expect(app.covers.read(note.id)?.contentType).toBe('image/png');
      }
      const followers = app.store.current.followers;
      await app.scheduler.simulate(5);
      expect(app.store.current.followers).toBe(followers + 5);
      expect((await app.scheduler.runOnce('manual')).status).toBe('ok');
      expect(app.store.current.followers).toBe(followers + 5);
      expect(network).not.toHaveBeenCalled();
    } finally {
      await app.stop();
      vi.restoreAllMocks();
      fs.rmSync(dir, { recursive: true, force: true });
    }
  });
});
