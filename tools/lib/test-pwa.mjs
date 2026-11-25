// The browser half of tools/test-pwa: starts the dev instance, drives the PWA in a headless Firefox
// and checks Sofa's side (its log and database).

import { execFileSync, spawn } from 'node:child_process';
import { appendFileSync, existsSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { launchFirefox } from './marionette.mjs';

const E = process.env;
const LOG = join(E.SOFA_DATA, 'sofa.log'), FIFO = join(E.SOFA_DATA, 'dev.fifo'), DB = join(E.SOFA_DATA, 'sofa.db');
const BASE = `https://${E.SOFA_NAME}:${E.SOFA_PORT}`;
let failed = 0;
const ok = (m) => console.log(`  ok    ${m}`);
const bad = (m) => { console.log(`  FAIL  ${m}`); failed = 1; };
const check = async (m, f) => { try { const r = await f(); if (r === false) bad(m); else ok(m); } catch (e) { bad(`${m}: ${e.message}`); } };
const sql = (q) => execFileSync('/opt/local/bin/sqlite3', [DB, q]).toString().trim();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const log = () => (existsSync(LOG) ? readFileSync(LOG, 'utf8') : '');

async function waitLog(re, ms = 30_000, from = 0) {
  const deadline = Date.now() + ms;
  for (;;) {
    const m = log().slice(from).match(re);
    if (m) return m;
    if (Date.now() > deadline) throw new Error(`no ${re} in the log`);
    await sleep(200);
  }
}
async function waitSql(q, want, ms = 15_000) {
  const deadline = Date.now() + ms;
  for (;;) { const got = sql(q); if (got === want) return true; if (Date.now() > deadline) throw new Error(`${q}: ${got}, want ${want}`); await sleep(250); }
}
// screenshots for a look (optional: not every Firefox build can take them headless)
const shot = async (ff, name) => {
  if (!E.PWA_SHOTS) return;
  const out = join(E.PWA_SHOTS, `${name}.png`);
  try { writeFileSync(out, await ff.screenshot()); return; } catch (e) {
    if (!E.PWA_DISPLAY) { console.log(`  note  no screenshot ${name}: ${e.message}`); return; }
  }
  // the X display's picture (no window manager: the window sits at 0,0), cut to the window
  try {
    const { width, height } = await ff.send('WebDriver:GetWindowRect');
    const xwd = execFileSync('/opt/local/bin/xwd', ['-root', '-silent', '-display', E.PWA_DISPLAY], { maxBuffer: 64 << 20 });
    execFileSync('/opt/local/bin/ffmpeg', ['-v', 'error', '-y', '-f', 'xwd_pipe', '-i', '-', '-vf', `crop=${width}:${height}:0:0`, out], { input: xwd });
  } catch (e) { console.log(`  note  no screenshot ${name}: ${e.message}`); }
};

// The dev instance on the same data and port (a restart keeps the pairing)
let app = null;
async function startSofa(media) {
  const from = log().length;
  app = spawn(E.SOFA_BIN, ['--dev', '--instance', E.SOFA_INSTANCE], {
    stdio: 'ignore',
    env: { ...process.env, SOFA_DATA_DIR: E.SOFA_DATA, SOFA_ONLY_APPS: 'example', SOFA_WEB_PORT: E.SOFA_PORT, SOFA_WEB_CERT: E.SOFA_CERT,
      SOFA_WEB_KEY: E.SOFA_KEY, SOFA_WEB_LOOPBACK: '1', SOFA_WEB_ORIGINS: E.PWA_ORIGIN, SOFA_WEB_APP_URL: E.PWA_URL, SOFA_PROXY_LOOPBACK: '1',
      SOFA_AUDIO_OUT: 'null', ...media },
  });
  await waitLog(/fifo ready/, 30_000, from);
  await waitLog(/web: listening on port/, 30_000, from);
  return from;
}
async function stopSofa() {
  if (!app) return;
  const a = app; app = null;
  if (a.exitCode === null) {
    appendFileSync(FIFO, 'quit\n');
    await Promise.race([new Promise((r) => a.once('exit', r)), sleep(30_000)]);
    if (a.exitCode === null) a.kill();
  }
  const refused = log().match(/^[0-9: .-]+ store: .* -> .*$/m);
  if (refused) bad(`the database refused a statement: ${refused[0]}`);
}

const ff = await launchFirefox({
  binary: E.FIREFOX, profileDir: E.PROFILE, port: Number(E.MARIONETTE_PORT), display: E.PWA_DISPLAY || undefined,
  prefs: {
    'network.dns.localDomains': `sofa-test,${E.SOFA_NAME}`,   // the test names -> loopback
    'media.volume_scale': '0.0',                               // muted, always
    'media.autoplay.default': 0, 'media.autoplay.blocking_policy': 0,
    'browser.safebrowsing.malware.enabled': false, 'browser.safebrowsing.phishing.enabled': false,
  },
});
try {
  await ff.session();
  await ff.setWindow(390, 844);
  await startSofa({ SOFA_EXAMPLE_MEDIA: E.MEDIA_DASH_V, SOFA_EXAMPLE_AUDIO: E.MEDIA_DASH_A });

  console.log('==> 1 connect and pair');
  await ff.navigate(E.PWA_URL);
  await check('1: the connect screen', () => ff.until(`return !!document.querySelector('input.field')`, 20_000));
  // the short name: the PWA navigates to the plain connect route, which sends it back with the full name
  await ff.run(`const i = document.querySelector('input.field'); i.value = arguments[0]; i.form.requestSubmit();`, [`sofa-test:${E.SOFA_PORT}`]);
  await check('1: back with the full name, on the pairing screen', () => ff.until(`return document.querySelector('input.code') && JSON.parse(localStorage.getItem('sofa.connection')).host`, 20_000)
    .then((host) => host === `${E.SOFA_NAME}:${E.SOFA_PORT}` || Promise.reject(new Error(String(host)))));
  appendFileSync(FIFO, 'open web\n');
  const code = (await waitLog(/dev: web pairing code (\d{6})/))[1];
  await ff.run(`const c = document.querySelector('input.code'); c.value = arguments[0]; c.form.requestSubmit();`, [code]);
  await check('1: paired (a token, Home loads)', () => ff.until(`const e = document.querySelector('.form-error:not([hidden])'); if (e) return 'error: ' + e.textContent;
      return !!JSON.parse(localStorage.getItem('sofa.connection')).token && document.querySelectorAll('.tile').length > 0`, 30_000)
    .then((r) => r === true || Promise.reject(new Error(String(r)))));
  if (failed) {   // why: what a fetch from the page and a direct visit get
    const r = await ff.runAsync(`const done = arguments[arguments.length - 1]; fetch(arguments[0]).then(r => r.text()).then(done, e => done('fetch error: ' + e))`, [`${BASE}/api/hello`]);
    console.log(`        fetch from the page: ${r}`);
    throw new Error('pairing failed');
  }
  await check('1: the device is in the TV\'s list', async () => sql('select count(*) from web_devices') === '1');

  console.log('==> 2 pages');
  await check('2: Home has the app tile', () => ff.until(`return [...document.querySelectorAll('.tile .art')].some(a => /Beispiel|Example/i.test(a.getAttribute('aria-label') || a.textContent))`, 10_000));
  await shot(ff, 'phone-home');
  await ff.run(`document.querySelector('.app-link[data-app="example"]').click()`);
  await check('2: the app page with its items', () => ff.until(`return location.hash === '#/app/example' && document.querySelectorAll('.tile[data-kind="video"]').length > 1`, 30_000));
  await check('2: in the app\'s theme', async () => (await ff.run(`return document.documentElement.style.getPropertyValue('--bg')`)).startsWith('rgba('));
  await shot(ff, 'phone-app');

  console.log('==> 3 playback');
  // can this browser decode H.264 at all? (a plain file, straight from the media server)
  const h264 = await ff.runAsync(`const done = arguments[arguments.length - 1]; const v = document.createElement('video'); v.muted = true;
    v.onloadeddata = () => done(true); v.onerror = () => done(false); setTimeout(() => done(false), 15000); v.src = arguments[0];`, [E.MEDIA_H264]);
  await ff.run(`document.querySelector('.tile[data-kind="video"] .art').click()`);
  await check('3: the player opens', () => ff.until(`return !!document.querySelector('.player video')`, 10_000));
  await ff.run(`document.querySelector('.player video').muted = true`);
  if (h264) {
    await check('3: the DASH pair plays as HLS through hls.js', () => ff.until(`const v = document.querySelector('.player video'); return v && v.currentTime > 1 && document.querySelector('.player').dataset.engine === 'hls.js'`, 45_000));
  } else {
    // hls.js read the master playlist (through Sofa) and its codecs, which this Firefox can't decode
    await check('3: HLS master through Sofa; the browser is told the format is not playable here', () => ff.until(`const p = document.querySelector('.player');
      return p.dataset.engine === 'hls.js' && /manifestIncompatibleCodecs/.test(p.dataset.lastError || '') && /Videoformat/.test(document.querySelector('.player-status').textContent)`, 30_000));
    console.log('  skip  3: the DASH pair plays - this Firefox decodes no H.264 (test-web checks the relay byte for byte)');
  }
  await ff.run(`history.back()`);
  await check('3: closing removes the player', () => ff.until(`return !document.querySelector('.player')`, 10_000));
  await check('3: closing ends the stream in Sofa', () => waitLog(/web: stream [0-9a-f]{6} ended \(closed by the browser\)/));

  // the same instance (data, port, pairing) on a VP9 file, which every Firefox decodes
  await stopSofa();
  await startSofa({ SOFA_EXAMPLE_MEDIA: E.MEDIA_FILE });
  await ff.run(`location.reload()`);
  await check('3: still paired after Sofa restarted', () => ff.until(`return document.querySelectorAll('.tile[data-kind="video"]').length > 1`, 30_000));
  const before = sql('select count(*) from progress');
  await ff.until(`const a = document.querySelectorAll('.tile[data-kind="video"] .art')[1]; if (a) a.click(); return !!a`, 10_000);
  await ff.until(`return !!document.querySelector('.player video')`, 10_000);
  await ff.run(`document.querySelector('.player video').muted = true`);
  const played = await ff.until(`const v = document.querySelector('.player video'); const s = document.querySelector('.player-status');
      return (v && v.currentTime > 2.5 && 'playing') || (s && s.classList.contains('error') && 'error: ' + s.textContent)`, 45_000, 'video plays').catch((e) => e.message);
  if (played === 'playing') ok('3: a file plays (through the media proxy)'); else {
    bad(`3: a file plays: ${played}`);
    console.log('        ' + await ff.run(`const v = document.querySelector('.player video'); return JSON.stringify({ state: v && v.readyState, t: v && v.currentTime, err: v && v.error && v.error.message, src: v && v.currentSrc })`));
  }
  await shot(ff, 'phone-player');
  // past the store's 10 s (shorter is history without a position), then paused
  await ff.runAsync(`const done = arguments[arguments.length - 1]; const v = document.querySelector('.player video');
    v.addEventListener('seeked', () => done(true), { once: true }); v.currentTime = 20;`);
  await ff.run(`document.querySelector('.player video').pause()`);
  await check('3: the paused position is in the TV\'s history', () => waitSql('select count(*) from progress', String(Number(before) + 1)));
  await ff.run(`document.querySelector('.player-close').click()`);
  await check('3: ✕ closes the player and ends the stream', async () => { await ff.until(`return !document.querySelector('.player')`, 10_000); return waitLog(/ended \(closed by the browser\)[^]*ended \(closed by the browser\)/); });
  await check('3: the tile shows the progress', () => ff.until(`return !!document.querySelector('.tile[data-kind="video"] .progress')`, 10_000));

  console.log('==> 4 marks');
  await ff.run(`document.querySelector('.tile[data-kind="video"] .more').click()`);
  await check('4: the sheet opens from ⋯', () => ff.until(`return !!document.querySelector('.sheet .sheet-button')`, 5_000));
  await ff.run(`[...document.querySelectorAll('.sheet-button')].find(b => b.textContent === 'Später ansehen').click()`);
  await check('4: Später ansehen in the TV\'s database', () => waitSql('select count(*) from watch_later', '1'));
  await check('4: the tile knows (the sheet offers to remove it)', async () => {
    await ff.run(`document.querySelector('.tile[data-kind="video"] .more').click()`);
    await ff.until(`return !!document.querySelector('.sheet .sheet-button')`, 5_000);
    const labels = await ff.run(`return [...document.querySelectorAll('.sheet-button')].map(b => b.textContent)`);
    await ff.run(`document.querySelector('.sheet-button.cancel').click()`);
    return labels.some((l) => l.startsWith('Aus „Später ansehen“'));
  });

  console.log('==> 5 layouts');
  await ff.setWindow(1280, 800);
  await sleep(500);
  await check('5: desktop: no sideways page scroll', async () => (await ff.run(`return document.documentElement.scrollWidth <= innerWidth + 1`)) === true);
  await shot(ff, 'desktop-app');
  await ff.run(`document.querySelector('.app-link[data-app="home"]').click()`);
  await ff.until(`return location.hash === '#/' && document.querySelectorAll('.tile').length > 0`, 20_000);
  await shot(ff, 'desktop-home');
  await ff.setWindow(390, 844);
  await sleep(500);
  await check('5: phone: no sideways page scroll', async () => (await ff.run(`return document.documentElement.scrollWidth <= innerWidth + 1`)) === true);
} catch (e) {
  bad(`browser: ${e.message}`);
} finally {
  if (failed) {
    console.log('        player: ' + await ff.run(`const p = document.querySelector('.player'); return p ? JSON.stringify(Object.assign({}, p.dataset)) : 'closed'`).catch(() => '?'));
    console.log(log().split('\n').filter((l) => / web: /.test(l)).slice(-15).map((l) => `        ${l.slice(11, 220)}`).join('\n'));
  }
  await ff.quit();
  await stopSofa();
}
process.exit(failed);
