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

  // a stored YouTube video's kind of tracks - VP9 in WebM, video and audio as two inputs: the segmenter
  // (docs/pwa.md §8) serves them as fMP4 HLS, copied where the browser decodes them, and a seek starts its
  // job there. This Firefox build decodes no audio in MP4 (MediaSource says so in the page), so the
  // "audio" input is the silent video's own file (no audio track: the stream has none); test-web checks
  // Opus and AAC with ffprobe.
  await stopSofa();
  await startSofa({ SOFA_EXAMPLE_MEDIA: E.MEDIA_WEBM_V, SOFA_EXAMPLE_AUDIO: E.MEDIA_WEBM_V });
  await ff.run(`location.reload()`);
  await ff.until(`return document.querySelectorAll('.tile[data-kind="video"]').length > 1`, 30_000);
  await ff.until(`if (document.querySelector('.player video')) return true; const a = document.querySelector('.tile[data-kind="video"] .art'); if (a) a.click(); return false`, 15_000);
  await ff.run(`document.querySelector('.player video').muted = true`);
  await check('3: VP9 tracks play through the segmenter, copied (hls.js)', () => ff.until(`const v = document.querySelector('.player video'); const p = document.querySelector('.player');
      const s = document.querySelector('.player-status');
      if (s && s.classList.contains('error')) return 'error: ' + s.textContent;
      return v.currentTime > 2.5 && p.dataset.engine === 'hls.js' && p.dataset.segmented === 'copy+none'`, 45_000)
    .then((r) => r === true || Promise.reject(new Error(String(r))))
    .catch(async (e) => { console.log('        the browser decodes: ' + await ff.run(`return document.querySelector('.player').dataset.formats`)); for (const l of log().split('\n').filter((x) => /transcode:|no segments|web: stream/.test(x)).slice(-6)) console.log(`        ${l}`); throw e; }));
  await ff.run(`document.querySelector('.player video').currentTime = 20`);
  await check('3: ... a seek plays on from there', () => ff.until(`const v = document.querySelector('.player video'); return v.currentTime > 21.5 && !v.paused`, 30_000));
  const ends = (log().match(/ended \(closed by the browser\)/g) || []).length;
  await ff.run(`history.back()`);
  await check('3: ... closing ends its stream', () => ff.until(`return !document.querySelector('.player')`, 10_000)
    .then(() => waitLog(new RegExp(`(ended \\(closed by the browser\\)[^]*){${ends + 1}}`))));

  // the same instance (data, port, pairing) on a VP9 file, which every Firefox decodes
  await stopSofa();
  await startSofa({ SOFA_EXAMPLE_MEDIA: E.MEDIA_FILE, SOFA_EXAMPLE_FILL: '0.3', SOFA_SOURCE_GAP: '1' });
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
  const ended = (log().match(/ended \(closed by the browser\)/g) || []).length;
  await check('3: ✕ closes the player and ends the stream', async () => { await ff.until(`return !document.querySelector('.player')`, 10_000); return waitLog(new RegExp(`(ended \\(closed by the browser\\)[^]*){${ended + 1}}`)); });
  await check('3: the tile shows the progress', () => ff.until(`return !!document.querySelector('.tile[data-kind="video"] .progress')`, 10_000));

  console.log('==> 4 marks');
  await ff.run(`document.querySelector('.tile[data-kind="video"] .more').click()`);
  await check('4: the sheet opens from ⋯', () => ff.until(`return !!document.querySelector('.sheet .sheet-button')`, 5_000));
  await ff.run(`[...document.querySelectorAll('.sheet-button')].find(b => b.textContent === 'Später ansehen').click()`);
  await check('4: Später ansehen in the TV\'s database', () => waitSql('select count(*) from watch_later', '1'));
  await check('4: the tile knows (the sheet offers to remove it)', async () => {
    // the answer updates the tiles, then says so (the database is written before it answers)
    await ff.until(`return /Später ansehen“ hinzugefügt/.test(document.getElementById('toast').textContent)`, 10_000);
    await ff.run(`document.querySelector('.tile[data-kind="video"] .more').click()`);
    await ff.until(`return !!document.querySelector('.sheet .sheet-button')`, 5_000);
    const labels = await ff.run(`return [...document.querySelectorAll('.sheet-button')].map(b => b.textContent)`);
    await ff.run(`document.querySelector('.sheet-button.cancel').click()`);
    return labels.some((l) => l.startsWith('Aus „Später ansehen“')) || Promise.reject(new Error(JSON.stringify(labels)));
  });

  console.log('==> 6 the TV');
  const tileOf = (id) => `.tile[data-id="${id}"]`;
  const sheetFor = async (id) => {
    await ff.run(`document.querySelector(arguments[0] + ' .more').click()`, [tileOf(id)]);
    await ff.until(`return !!document.querySelector('.sheet.open .sheet-button')`, 5_000);
  };
  const choose = (label) => ff.run(`const b = [...document.querySelectorAll('.sheet.open .sheet-button')].find(b => b.querySelector('.sheet-label') ? b.querySelector('.sheet-label').textContent === arguments[0] : b.textContent === arguments[0]);
    if (!b) throw new Error('no button ' + arguments[0] + ' in ' + [...document.querySelectorAll('.sheet.open .sheet-button')].map(b => b.textContent)); b.click();`, [label]);
  const barLabel = () => ff.run(`const b = document.querySelector('.tvbar'); return b && !b.hidden ? b.querySelector('.tvbar-label').textContent + ' | ' + b.querySelector('.tvbar-title').textContent : ''`);
  await sheetFor('example:3');
  await choose('Auf dem Fernseher abspielen');
  await check('6: sent from the sheet: the TV\'s player opens it', () => waitLog(/web: example:3 sent to the TV/).catch(async (e) => {
    throw new Error(`${e.message} (toast: ${await ff.run(`const t = document.getElementById('toast'); return t ? t.textContent : 'none'`)})`);
  }));
  await check('6: the bar shows it playing on the TV', () => ff.until(`const b = document.querySelector('.tvbar');
      return b && !b.hidden && /Läuft/.test(b.querySelector('.tvbar-label').textContent) && b.querySelector('.tvbar-title').textContent === 'Mandelbrot'`, 30_000));
  await check('6: the viewer hears it plays now', () => ff.until(`return /Läuft jetzt am Fernseher/.test(document.getElementById('toast').textContent)`, 30_000));
  await shot(ff, 'phone-tvbar');
  await ff.run(`document.querySelector('.tvbar .tvbar-button').click()`);
  await check('6: the bar pauses the TV', async () => { await waitLog(/web: TV pause/); return ff.until(`return /Pausiert/.test(document.querySelector('.tvbar-label').textContent)`, 15_000); });
  await ff.run(`document.querySelectorAll('.tvbar .tvbar-button')[1].click()`);
  await check('6: the bar stops it (the TV\'s player closes)', async () => { await waitLog(/player: closed example:3/); return ff.until(`return document.querySelector('.tvbar').hidden`, 15_000); });

  await sheetFor('example:1');
  await choose('Auf dem Fernseher abspielen');
  await waitLog(/web: example:1 sent to the TV/);
  await sheetFor('example:2');
  await choose('Auf dem Fernseher abspielen');
  await check('6: another video plays there: the sheet asks first, naming it', () => ff.until(`const h = document.querySelector('.sheet.open h2'); return !!h && h.textContent === 'Am Fernseher läuft gerade „Testbild“.'`, 15_000));
  await check('6: ... no toast over the question', () => ff.run(`const t = document.getElementById('toast'); const p = document.querySelector('.sheet.open .sheet-panel').getBoundingClientRect();
      if (!t || !t.classList.contains('show')) return true; const r = t.getBoundingClientRect(); return r.bottom <= p.top || r.top >= p.bottom;`));
  await choose('Stattdessen „Farbbalken“ abspielen');
  await check('6: ... and replaces it when asked', () => waitLog(/web: example:2 sent to the TV \(device [0-9a-f]+, replaced the player\)/));
  await check('6: the bar follows', () => ff.until(`return document.querySelector('.tvbar-title').textContent === 'Farbbalken'`, 20_000));

  await ff.run(`document.querySelectorAll('.tvbar .tvbar-button')[1].click()`);
  await ff.until(`return document.querySelector('.tvbar').hidden`, 15_000);
  // a playback in the browser moves to the TV where it is
  await ff.run(`document.querySelector(arguments[0] + ' .art').click()`, [tileOf('example:4')]);
  await ff.until(`return !!document.querySelector('.player video')`, 10_000);
  await ff.run(`document.querySelector('.player video').muted = true`);
  await ff.until(`const v = document.querySelector('.player video'); return v && v.currentTime > 4`, 45_000, 'video plays');
  const handed = await ff.run(`return document.querySelector('.player video').currentTime`);
  await ff.run(`document.querySelector('.player-tv').click()`);
  await check('6: handed over: the browser\'s player closes, its stream ends', async () => {
    await ff.until(`return !document.querySelector('.player')`, 10_000);
    return waitLog(/web: stream [0-9a-f]{6} ended \(closed by the browser\)[^]*web: example:4 sent to the TV/);
  });
  await check('6: the TV goes on where the browser was', () => ff.until(`const m = /Läuft · (\\d+):(\\d\\d) \\//.exec(document.querySelector('.tvbar-label').textContent);
      return !!m && document.querySelector('.tvbar-title').textContent === 'Leben' && Number(m[1]) * 60 + Number(m[2]) >= Math.floor(arguments[0]) - 1`, 30_000, 'TV position', [handed]));
  await ff.run(`document.querySelectorAll('.tvbar .tvbar-button')[1].click()`);
  await ff.until(`return document.querySelector('.tvbar').hidden`, 15_000);

  console.log('==> 7 downloads');
  await sheetFor('example:3');
  await choose('Herunterladen');
  await check('7: started (Sofa\'s message)', () => ff.until(`return /eruntergeladen/.test(document.getElementById('toast').textContent)`, 10_000));
  await check('7: the tile\'s chip follows it to "Offline"', () => ff.until(`const c = document.querySelector(arguments[0] + ' .chip'); return !!c && c.textContent === '↓ Offline'`, 30_000, 'chip', [tileOf('example:3')]));
  await check('7: done in the TV\'s database', () => waitSql(`select state from downloads where id='example:3'`, '2'));
  await sheetFor('example:3');
  await shot(ff, 'phone-sheet-download');
  await choose('Behalten');
  await check('7: Behalten (the TV\'s database, the tile\'s chip)', async () => {
    await waitSql(`select keep from downloads where id='example:3'`, '1');
    return ff.until(`const c = document.querySelector(arguments[0] + ' .chip'); return !!c && c.textContent === '↓ Behalten'`, 10_000, 'chip', [tileOf('example:3')]);
  });
  await sheetFor('example:3');
  await choose('Download löschen');
  await check('7: deleting a kept one asks first', () => ff.until(`const h = document.querySelector('.sheet.open h2'); return !!h && h.textContent === 'Download löschen?'`, 5_000));
  await choose('Ja, endgültig löschen');
  await check('7: deleted', () => waitSql(`select count(*) from downloads where id='example:3'`, '0'));
  await check('7: the chip goes', () => ff.until(`return !document.querySelector(arguments[0] + ' .chip')`, 10_000, 'chip', [tileOf('example:3')]));

  console.log('==> 9 the look holds (layout stability, states)');
  // a page's skeleton has the real boxes: the first tile does not move when the content arrives
  await ff.run(`location.hash = '#/'`);
  await ff.until(`return location.hash === '#/' && !document.querySelector('.skeleton') && document.querySelectorAll('.tile').length > 0`, 20_000);
  await check('9: the skeleton holds the tiles\' places (no jump when the page arrives)', async () => {
    const r = await ff.runAsync(`const done = arguments[arguments.length - 1]; const f = window.fetch;
      window.fetch = (...a) => new Promise((ok) => setTimeout(ok, 1500)).then(() => f(...a));
      const box = (e) => { if (!e) return null; const b = e.getBoundingClientRect(); return [b.left, b.top, b.width, b.height].map(Math.round).join(','); };
      document.querySelector('.app-link[data-app="example"]').click();
      setTimeout(() => { const sk = box(document.querySelector('.skeleton .tile .art'));
        const wait = () => { const t = document.querySelector('main .page:not(.skeleton) .tile[data-style="landscape"] .art');
          if (!t) { setTimeout(wait, 100); return; } window.fetch = f; done({ sk, real: box(t) }); };
        wait(); }, 300);`);
    return (r.sk && r.sk === r.real) || Promise.reject(new Error(JSON.stringify(r)));
  });
  await check('9: app tiles carry their text in the picture (none below, as on the TV)', async () => {
    await ff.run(`location.hash = '#/'`);
    await ff.until(`return document.querySelectorAll('.tile[data-style="app"]').length > 0 && !document.querySelector('.skeleton')`, 20_000);
    return ff.run(`return !document.querySelector('.tile[data-style="app"] .meta')`);
  });
  // iOS 26+ blurs the top of an installed web app unless a sticky/fixed box with an opaque
  // background and no backdrop-filter covers the top edge (WebKit fixedContainerEdges)
  await check('9: the header covers the top edge solidly (no iOS scroll-edge blur)', async () => {
    const r = await ff.run(`const h = document.getElementById('bar'), s = getComputedStyle(h), b = h.getBoundingClientRect();
      const c = document.createElement('canvas').getContext('2d'); c.fillStyle = s.backgroundColor; c.fillRect(0, 0, 1, 1);
      return { pos: s.position, top: Math.round(b.top), w: b.width / innerWidth, h: b.height, alpha: c.getImageData(0, 0, 1, 1).data[3],
        filter: s.backdropFilter || 'none' }`);
    return (['sticky', 'fixed'].includes(r.pos) && r.top === 0 && r.w >= 0.95 && r.h > 10 && r.alpha === 255 && r.filter === 'none')
      || Promise.reject(new Error(JSON.stringify(r)));
  });
  await check('9: the header\'s buttons keep their places on every page (search page included)', async () => {
    const where = `const b = document.querySelector('.settings-button').getBoundingClientRect(); return Math.round(b.left) + ',' + Math.round(b.top)`;
    const home = await ff.run(where);
    await ff.run(`location.hash = '#/search/example'`);
    await ff.until(`return !!document.querySelector('.search-field')`, 10_000);
    const search = await ff.run(where);
    return home === search || Promise.reject(new Error(`${home} -> ${search}`));
  });
  await check('9: every button is at least 44 px for a finger (header, tiles, sheet)', async () => {
    await ff.run(`location.hash = '#/app/example'`);
    await ff.until(`return document.querySelectorAll('.tile[data-kind="video"]').length > 1 && !document.querySelector('.skeleton')`, 20_000);
    await sheetFor('example:1');
    const small = await ff.run(`return [...document.querySelectorAll('#bar button, .tile .more, .sheet.open button')].filter((b) => b.offsetParent && getComputedStyle(b).visibility !== 'hidden')
      .map((b) => [b.className, b.getBoundingClientRect()]).filter(([, r]) => r.width < 44 || r.height < 44).map(([c, r]) => c + ' ' + Math.round(r.width) + 'x' + Math.round(r.height))`);
    await ff.run(`document.querySelector('.sheet.open .sheet-button.cancel').click()`);
    return small.length === 0 || Promise.reject(new Error(small.join('; ')));
  });
  // Sofa goes away: the content stays, a bar says so; a playback says so and offers to try again
  await stopSofa();
  await check('9: Sofa unreachable: "Keine Verbindung" over the content', () => ff.until(`const n = document.querySelector('.netbar');
      return !!n && !n.hidden && /Keine Verbindung/.test(n.textContent) && document.querySelectorAll('.tile').length > 0`, 30_000));
  await ff.run(`document.querySelector(arguments[0] + ' .art').click()`, [tileOf('example:2')]);
  await check('9: ... a playback says so and offers "Erneut versuchen"', () => ff.until(`const s = document.querySelector('.player-status.error');
      return !!s && /nicht erreichbar/.test(s.textContent) && [...s.querySelectorAll('button')].some((b) => b.offsetParent && b.textContent === 'Erneut versuchen')`, 30_000));
  await startSofa({ SOFA_EXAMPLE_MEDIA: E.MEDIA_FILE, SOFA_EXAMPLE_FILL: '0.3', SOFA_SOURCE_GAP: '1' });
  await ff.run(`[...document.querySelectorAll('.player-status button')].find((b) => b.textContent === 'Erneut versuchen').click()`);
  await check('9: ... and plays once Sofa is back', () => ff.until(`const v = document.querySelector('.player video'); if (v) v.muted = true; return !!v && v.currentTime > 1`, 45_000));
  await ff.run(`history.back()`);
  await ff.until(`return !document.querySelector('.player')`, 10_000);
  await check('9: ... the connection bar goes by itself', () => ff.until(`return document.querySelector('.netbar').hidden`, 45_000));
  // a reload during a playback: the page it was opened from, no dead Back step
  await ff.run(`document.querySelector(arguments[0] + ' .art').click()`, [tileOf('example:2')]);
  await ff.until(`return !!document.querySelector('.player video')`, 10_000);
  await ff.run(`location.reload()`);
  await check('9: reloaded during a playback: back on its page, no player entry left', () => ff.until(`return !document.querySelector('.player') && !(history.state && history.state.player)
      && document.querySelectorAll('.tile[data-kind="video"]').length > 1`, 30_000));

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

  console.log('==> 8 the TV\'s pairing link');
  // what the QR code on the TV's pairing screen says (docs/api.md): a browser that knows nothing of this TV
  // opens it, pair.html hands the fragment to the PWA, which connects and sends the code by itself
  await ff.run(`localStorage.clear()`);
  const from = log().length;
  appendFileSync(FIFO, 'open web\n');
  const linkCode = (await waitLog(/dev: web pairing code (\d{6})/, 30_000, from))[1];
  await ff.navigate(`${E.PWA_URL}pair#host=${E.SOFA_NAME}:${E.SOFA_PORT}&code=${linkCode}`);
  await check('8: paired from the link alone (a token, Home loads)', () => ff.until(`const e = document.querySelector('.form-error:not([hidden])'); if (e) return 'error: ' + e.textContent;
      const c = JSON.parse(localStorage.getItem('sofa.connection') || 'null');
      return !!c && !!c.token && c.host === arguments[0] && document.querySelectorAll('.tile').length > 0`, 30_000, 'paired', [`${E.SOFA_NAME}:${E.SOFA_PORT}`])
    .then((r) => r === true || Promise.reject(new Error(String(r)))));
  await check('8: the code is not left in the address', async () => !/code=/.test(await ff.run(`return location.href`)));
  await check('8: a second device in the TV\'s list, the PWA', async () => sql(`select count(*) || '|' || group_concat(distinct client_kind) from web_devices`) === '2|web');
  // removed on the TV: the pairing screen says why
  await stopSofa();
  sql('delete from web_devices');
  await startSofa({ SOFA_EXAMPLE_MEDIA: E.MEDIA_FILE });
  await ff.run(`location.reload()`);
  await check('8: a device removed on the TV is told why it has to pair again', () => ff.until(`const n = document.querySelector('.notice'); return !!n && /getrennt/.test(n.textContent) && !!document.querySelector('input.code')`, 30_000));
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
