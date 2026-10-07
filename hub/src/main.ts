/**
 * CLI: `hub start | login | scrape | send <json> | monitor`
 */
import { createApp } from './app.ts';
import { createDemoApp } from './demo.ts';
import { loadEnv } from './config.ts';
import { createLogger } from './log.ts';
import { decodeHubCommand, nextId } from './protocol/index.ts';
import { probeProfile } from './scraper/probe.ts';
import { loginInteractive } from './scraper/xhs.ts';
import { nowSeconds } from './store.ts';

const USAGE = `usage: pnpm hub <command>

  demo             offline panel with sample data; no account or hardware (PORT=8788)
  start            serial link + scrape scheduler + web panel (PORT=8787)
  login            open a headed browser to log in to Xiaohongshu once (profile in hub/data/profile)
  probe            load the profile page once and dump __INITIAL_STATE__ / note anchors / text to hub/data/probe
  scrape           scrape now, record stats + recent notes, push to the device if connected
  send <json>      send one protocol command to the device and print the ack, e.g. '{"t":"celebrate","delta":5}'
  monitor          print every line the device sends until Ctrl-C

env: PORT, SCRAPE_INTERVAL_MIN (45), QUIET_HOURS (02-07), HEADED=1, HUB_DATA_DIR, CARD_PATH,
     HUB_DEBUG=1 (verbose + dump the scraped page text to hub/data/failures/debug-<ts>.txt),
     HUB_NO_DEVICE=1 (never open the USB serial port — scrape / store only)`;

function onSignal(handler: () => Promise<void>): void {
  let stopping = false;
  const run = () => {
    if (stopping) return;
    stopping = true;
    void handler().finally(() => process.exit(0));
  };
  process.on('SIGINT', run);
  process.on('SIGTERM', run);
}

async function cmdDemo(): Promise<void> {
  const app = createDemoApp();
  await app.start();
  app.log.info('Offline demo: sample profile and covers; no scraper, login or serial connection.');
  onSignal(() => app.stop());
}

async function cmdStart(): Promise<void> {
  const env = loadEnv();
  const app = createApp(env, { serial: !env.noDevice });
  await app.start();
  if (env.noDevice) app.log.info('HUB_NO_DEVICE=1 — serial port untouched; panel + scheduler only');
  app.scheduler.start();
  app.log.info(`stats: followers=${app.store.current.followers} (source ${app.store.current.source}); scrape every ${env.scrapeIntervalMin} min ±10, quiet ${String(env.quietHours.start).padStart(2, '0')}-${String(env.quietHours.end).padStart(2, '0')}`);
  onSignal(async () => {
    app.log.info('shutting down');
    await app.stop();
  });
}

async function cmdLogin(): Promise<number> {
  const env = loadEnv();
  const app = createApp(env, { web: false, serial: false });
  const result = await loginInteractive({ userId: app.card.xhs.userId, profileDir: app.paths.profile, failuresDir: app.paths.failures, headed: true, logger: app.log.child('xhs') });
  if (result.status === 'ok') {
    const events = app.store.record({ followers: result.followers, likes: result.likes, notes: result.notes, ts: nowSeconds(), source: 'login' });
    app.log.info(`已保存：followers=${events.current.followers} likes=${events.current.likes} notes=${events.current.notes}（登录状态保存在 ${app.paths.profile}）`);
    return 0;
  }
  app.log.warn(`登录未完成：${result.status === 'needsLogin' ? result.message : result.message}`);
  return 2;
}

async function cmdProbe(): Promise<number> {
  const env = loadEnv();
  const app = createApp(env, { web: false, serial: false });
  const result = await probeProfile({ userId: app.card.xhs.userId, profileDir: app.paths.profile, outDir: app.paths.probe, headed: env.headed, logger: app.log.child('probe') });
  console.log(`status=${result.status} attempts=${result.attempts} url=${result.url}`);
  if (result.message) console.log(`message: ${result.message.split('\n')[0]}`);
  console.log(`anchors=${result.anchors.length} state=${result.initialState ? 'yes' : `no (${result.initialStateError ?? '-'})`} innerText=${result.innerText.length} chars`);
  console.log('--- __INITIAL_STATE__ array digest (depth ≤ 6) ---');
  for (const line of result.digest) console.log(line);
  console.log('--- first anchors ---');
  for (const a of result.anchors.slice(0, 3)) console.log(`${a.hrefAttr.slice(0, 70)} | img=${a.img ? 'yes' : 'no'} | ${a.section.replace(/\n/g, ' ⏎ ').slice(0, 120)}`);
  if (result.status === 'loginWall') console.log('login wall — not retrying; run: pnpm hub login');
  return result.status === 'ok' ? 0 : result.status === 'error' ? 1 : 2;
}

async function cmdScrape(): Promise<number> {
  const env = loadEnv();
  const app = createApp(env, { web: false, serial: !env.noDevice });
  await app.start();
  if (env.noDevice) app.log.info('HUB_NO_DEVICE=1 — serial port untouched; stats will be stored only');
  else if (!(await app.waitForDevice(3000))) app.log.info('device not connected — stats will be stored only');
  const rec = await app.scheduler.runOnce('cli');
  const c = app.store.current;
  const recent = app.notesStore.summary;
  if (rec.status === 'ok') app.log.info(`OK followers=${c.followers} likes=${c.likes} notes=${c.notes} delta=${rec.delta ?? 0}; recentNotes rev=${recent.rev} count=${recent.count} (${app.paths.notes})`);
  else if (rec.status === 'needsLogin') app.log.warn(`NEEDS LOGIN — ${rec.message ?? ''}; kept last values (followers=${c.followers}, source ${c.source}). Run: pnpm hub login`);
  else app.log.error(`ERROR — ${rec.message ?? 'unknown'}; kept last values (followers=${c.followers})`);
  await app.stop();
  return rec.status === 'ok' ? 0 : rec.status === 'needsLogin' ? 2 : 1;
}

async function cmdSend(json: string | undefined): Promise<number> {
  if (!json) {
    console.error('usage: pnpm hub send \'{"t":"celebrate","delta":5}\'');
    return 1;
  }
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(json) as Record<string, unknown>;
  } catch (err) {
    console.error(`not JSON: ${(err as Error).message}`);
    return 1;
  }
  if (typeof parsed['id'] !== 'string') parsed['id'] = nextId('cli');
  if (parsed['t'] === 'stats') {
    parsed['delta'] ??= 0;
    parsed['ts'] ??= nowSeconds();
  }
  const check = decodeHubCommand(JSON.stringify(parsed));
  if (!check.ok) {
    console.error(`invalid command: ${check.error}`);
    return 1;
  }
  const env = loadEnv();
  const app = createApp(env, { web: false });
  await app.start();
  if (!(await app.waitForDevice(5000))) {
    app.log.error('device not connected (no /dev/cu.usbmodem*). Plug the AI Passport in with a data cable.');
    await app.stop();
    return 3;
  }
  const { id: _id, ...cmd } = check.msg;
  const result = await app.link.raw(cmd as Parameters<typeof app.link.raw>[0]);
  console.log(JSON.stringify(result));
  await app.stop();
  return result.ok ? 0 : 1;
}

async function cmdMonitor(): Promise<void> {
  const env = loadEnv();
  const app = createApp(env, { web: false, logger: createLogger('hub') });
  app.client.on('raw', (line) => console.log(`< ${line.trim()}`));
  app.client.on('hello', (h) => console.log(`< hello ${JSON.stringify(h)}`));
  app.client.on('ack', (a) => console.log(`< ack ${JSON.stringify(a)}`));
  app.client.on('button', (b) => console.log(`< button ${b.btn} ${b.ev}`));
  app.client.on('battery', (b) => console.log(`< battery ${JSON.stringify(b)}`));
  app.client.on('ble', (b) => console.log(`< ble ${b.connected}`));
  await app.start();
  app.log.info('monitoring; Ctrl-C to stop');
  onSignal(() => app.stop());
}

async function main(): Promise<void> {
  const [cmd, ...rest] = process.argv.slice(2);
  switch (cmd) {
    case 'demo':
      return cmdDemo();
    case 'start':
      return cmdStart();
    case 'login':
      process.exitCode = await cmdLogin();
      return;
    case 'probe':
      process.exitCode = await cmdProbe();
      return;
    case 'scrape':
      process.exitCode = await cmdScrape();
      return;
    case 'send':
      process.exitCode = await cmdSend(rest.join(' ') || undefined);
      return;
    case 'monitor':
      return cmdMonitor();
    case undefined:
    case '-h':
    case '--help':
    case 'help':
      console.log(USAGE);
      return;
    default:
      console.error(`unknown command "${cmd}"\n\n${USAGE}`);
      process.exitCode = 1;
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
