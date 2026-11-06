// LIVE baseline (opt-in: SOFA_YT_LIVE=1 SOFA_YT_FILES=live-player.test.ts tools/test-sofa-yt): YouTube's
// OWN web player in the engine's browser (headless Firefox, the live dev profile of live-engine) - no
// engine, nothing injected. It tells apart "the browser environment is refused" from "the engine
// differs from the real player": stream protection lets ~60 s through before it decides, so a player
// that keeps playing past MEDIA_S was accepted. One watch page load, YouTube's own requests; a fresh
// profile first answers the EU consent dialog the way a user does (a click on "Alle ablehnen").
// Measured 2026-11-06 (headless, remote agent running): the player stops at 60.0 s buffered with
// "Ein Fehler ist aufgetreten" - the environment, not the engine, is refused (docs/youtube-engine.md).
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DIR } from './helpers.ts';
import { FIREFOX, bidi, callIn, launchFirefox, writeProfile } from './firefox.ts';

const VID = process.env.SOFA_YT_LIVE_VIDEO || 'OzCYsIrrRyw';
const PROFILE = process.env.SOFA_YT_LIVE_PROFILE || path.resolve(DIR, '..', 'sofa-yt-live-firefox');
const SOFA_BLOCK = path.join(os.homedir(), 'Library', 'Caches', 'Sofa', 'youtube-block.json');   // read only
const MEDIA_S = 100;

function blocked(): boolean {
  try { return (JSON.parse(fs.readFileSync(SOFA_BLOCK, 'utf8')) as { until: number }).until > Date.now() / 1000; } catch { return false; }
}

interface PlayerState { t: number; paused: boolean; buffered: number; readyState: number; error: string; ended: boolean; ad: boolean; hidden: string; overlay: string }

test('live baseline: YouTube\'s own player plays past stream protection in this browser', {
  skip: (!fs.existsSync(FIREFOX) && 'Firefox missing') || (blocked() && 'Sofa\'s bot-check breaker is open'),
  timeout: 240000,
}, async () => {
  // autoplay allowed (a TV), muted output does not matter headless
  writeProfile(PROFILE, { 'intl.accept_languages': 'de-AT, de, en-US, en', 'media.autoplay.default': 0, 'media.autoplay.blocking_policy': 0 });
  const ff = await launchFirefox(PROFILE);
  const report = (k: string, v: unknown): void => { process.stderr.write(`LIVE-PLAYER ${k}: ${typeof v === 'string' ? v : JSON.stringify(v)}\n`); };
  try {
    const b = await bidi(ff.url);
    try {
      await b.send('session.new', { capabilities: {} });
      const tree = await b.send('browsingContext.getTree', {}) as { contexts: { context: string }[] };
      const context = tree.contexts[0]!.context;
      await b.send('browsingContext.navigate', { context, url: `https://www.youtube.com/watch?v=${VID}`, wait: 'complete' });
      const state = (): Promise<PlayerState> => callIn<PlayerState>(b, context, `() => {
        const v = document.querySelector('video');
        const err = document.querySelector('.ytp-error, yt-playability-error-supported-renderers');
        return { t: v ? v.currentTime : -1, paused: v ? v.paused : true, ended: v ? v.ended : false, readyState: v ? v.readyState : -1,
          buffered: v && v.buffered.length ? v.buffered.end(v.buffered.length - 1) : 0, error: err ? err.textContent.trim().slice(0, 200) : '',
          ad: !!document.querySelector('.ad-showing'), hidden: document.visibilityState,
          overlay: [...document.querySelectorAll('tp-yt-paper-dialog')].filter((e) => e.offsetParent).map((e) => e.textContent.trim().replace(/\\s+/g, ' ').slice(0, 120)).join(' | ') };
      }`);
      let s = await state();
      const deadline = Date.now() + 180000;
      let lastT = -1; let stuckSince = Date.now();
      while (Date.now() < deadline) {
        await new Promise((r) => setTimeout(r, 10000));
        s = await state();
        report('state', s);
        if (s.error || s.t >= MEDIA_S) break;
        if (s.overlay) {
          // the EU consent dialog: answered once, as a user does (a click on "Alle ablehnen")
          const buttons = await callIn<[string, number, number][]>(b, context, `() => [...document.querySelectorAll('tp-yt-paper-dialog button')]
            .filter((e) => e.offsetParent).map((e) => { const r = e.getBoundingClientRect(); return [e.textContent.trim(), Math.round(r.x + r.width / 2), Math.round(r.y + r.height / 2)]; })`);
          const reject = buttons.find(([t]) => t === 'Alle ablehnen');
          report('consent', reject ? 'Alle ablehnen' : buttons);
          if (reject) {
            await b.send('input.performActions', { context, actions: [{ type: 'pointer', id: 'mouse', actions: [
              { type: 'pointerMove', x: reject[1], y: reject[2], origin: 'viewport' }, { type: 'pointerDown', button: 0 }, { type: 'pointerUp', button: 0 }] }] });
            await new Promise((r) => setTimeout(r, 4000));
            const jar = await b.send('storage.getCookies', {}) as { cookies: { name: string }[] };
            report('cookies after consent', jar.cookies.map((c) => c.name));
          }
          continue;
        }
        if (s.paused && !s.ended && s.readyState > 0) {
          // as a user would: a click on the player (its own play/pause toggle)
          await b.send('input.performActions', { context, actions: [{ type: 'pointer', id: 'mouse', actions: [
            { type: 'pointerMove', x: 400, y: 300, origin: 'viewport' }, { type: 'pointerDown', button: 0 }, { type: 'pointerUp', button: 0 }] }] });
          report('clicked play', s.t);
        }
        if (s.t > lastT + 0.5) { lastT = s.t; stuckSince = Date.now(); } else if (Date.now() - stuckSince > 45000) break;   // no progress
      }
      assert.equal(s.error, '', 'no playability error');
      assert.ok(s.t >= MEDIA_S, `played past ${MEDIA_S} s (stopped at ${s.t.toFixed(1)} s, buffered to ${s.buffered.toFixed(1)} s)`);
      await b.send('session.end', {}).catch(() => {});
    } finally { b.close(); }
  } finally {
    await ff.stop();
  }
});
