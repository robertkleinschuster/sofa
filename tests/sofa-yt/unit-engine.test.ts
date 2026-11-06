// The browser engine (docs/youtube-engine.md) in headless Firefox, injected the way Sofa does it: the
// bundle from tools/build-yt-engine as a BiDi preload script with a channel. Checks the readiness
// event, health() and the API's answers off youtube.com. Offline: a file:// page, a fresh profile, no
// request to YouTube. Skipped without Firefox.
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
      await b.send('session.end', {}).catch(() => {});
    } finally { b.close(); }
  } finally {
    await ff.stop();
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
