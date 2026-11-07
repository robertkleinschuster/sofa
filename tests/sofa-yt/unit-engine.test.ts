// The browser engine (docs/youtube-engine.md) in headless Firefox, injected the way Sofa does it: the
// bundle from tools/build-yt-engine as a BiDi preload script with a channel. Checks the readiness
// event, health(), the API's answers off youtube.com and the consent dialog's report. Offline:
// file:// pages, a fresh profile, no request to YouTube. Skipped without Firefox.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { tempDir, until } from './helpers.ts';
import { ENGINE, FIREFOX, bidi, callIn, engineMessages, injectEngine, launchFirefox, writeProfile } from './firefox.ts';

test('the engine injects as a preload script, says ready over its channel, answers off youtube.com', {
  skip: (!fs.existsSync(FIREFOX) && 'Firefox missing') || (!fs.existsSync(ENGINE) && 'engine bundle missing (tools/build-yt-engine)'),
  timeout: 60000,
}, async () => {
  const dir = tempDir('sofa-yt-engine-');
  const profile = path.join(dir, 'profile');
  writeProfile(profile);
  fs.writeFileSync(path.join(dir, 'page.html'), '<!doctype html><title>page</title>');
  const ff = await launchFirefox(profile);
  try {
    const b = await bidi(ff.url);
    try {
      const context = await injectEngine(b, fs.readFileSync(ENGINE, 'utf8'));
      await b.send('browsingContext.navigate', { context, url: `file://${dir}/page.html`, wait: 'complete' });
      // one ready per document the preload runs in (a transient initial one has url ''): the page's counts
      const isPage = (m: { type: string; url?: unknown }): boolean => m.type === 'ready' && /page\.html$/.test(String(m.url));
      assert.ok(await until(() => engineMessages(b).some(isPage), 10000, 50), 'ready event of the page over the channel');
      assert.match(String(engineMessages(b).find(isPage)!.userAgent), /Firefox\/\d+/);

      const h = await callIn<{ libraries: boolean; userAgent: string; onYouTube: boolean; engine: unknown }>(b, context, '() => sofaEngine.health()');
      assert.equal(h.libraries, true, 'youtubei.js, googlevideo, BotGuard, WebPO, the engine core usable in the page');
      assert.match(h.userAgent, /Firefox\/\d+/);
      assert.deepEqual([h.onYouTube, h.engine], [false, null]);
      type Fail = { ok: false; status: number; body: { error: string } };
      const early = await callIn<Fail>(b, context, "() => sofaEngine.open({ v: 'OzCYsIrrRyw' })");
      assert.deepEqual([early.ok, early.status], [false, 503], 'not started: no request');
      const start = await callIn<Fail>(b, context, "() => sofaEngine.start({ base: 'http://127.0.0.1:1', block: null })");
      assert.deepEqual([start.ok, start.status], [false, 412], 'off youtube.com the engine does not start');
      assert.match(start.body.error, /not on a youtube\.com page/);

      // The consent dialog (consent.ts), as measured on youtube.com 2026-11-07: the accept button
      // is the renderer whose command is a saveConsentAction - labels swapped here, so the text
      // cannot be what decides. Covered: nothing reported; uncovered: its rect in screen pixels.
      fs.writeFileSync(path.join(dir, 'consent.html'), `<!doctype html><meta charset="utf-8"><body style="margin:0">
        <ytd-consent-bump-v2-lightbox><div class="eom-button-row">
          <ytd-button-renderer id="reject"><button>Alle akzeptieren</button></ytd-button-renderer>
          <ytd-button-renderer id="accept"><button style="margin:30px 0 0 50px;width:130px;height:40px">Alle ablehnen</button></ytd-button-renderer>
        </div></ytd-consent-bump-v2-lightbox>
        <div id="cover" style="position:fixed;inset:0"></div>
        <script>reject.data = { command: { disablePersonalizationAction: {} } }; accept.data = { command: { saveConsentAction: {} } };</script>`);
      await b.send('browsingContext.navigate', { context, url: `file://${dir}/consent.html`, wait: 'complete' });
      const consent = (): { type: string; [k: string]: unknown } | undefined => engineMessages(b).find((m) => m.type === 'consent');
      assert.equal(await until(() => !!consent(), 2500, 100), false, 'a covered button is not reported');
      const want = await callIn<number[]>(b, context, `() => {
        document.getElementById('cover').remove();
        const r = document.querySelector('#accept button').getBoundingClientRect(), s = devicePixelRatio;
        return [(mozInnerScreenX + r.x) * s, (mozInnerScreenY + r.y) * s, r.width * s, r.height * s].map(Math.round);
      }`);
      assert.ok(await until(() => !!consent(), 5000, 50), 'the accept button is reported once settled');
      const c = consent()!;
      assert.deepEqual([c.x, c.y, c.width, c.height], want, 'the accept button (saveConsentAction), in screen pixels');
      await b.send('session.end', {}).catch(() => {});
    } finally { b.close(); }
  } finally {
    await ff.stop();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test('extension: the relay background is persistent (an MV3 event page is stopped when idle)', () => {
  // 2026-11-07: as an MV3 event page Firefox stopped the background after 30 s without extension
  // events; the bridge's port closed and the engine page was cut off from Sofa for good
  const manifest = JSON.parse(fs.readFileSync(path.resolve(import.meta.dirname, '../../res/sofa-yt/web/extension/manifest.json'), 'utf8')) as
    { manifest_version: number; background: { persistent?: boolean } };
  assert.equal(manifest.manifest_version, 2);
  assert.equal(manifest.background.persistent, true);
});
