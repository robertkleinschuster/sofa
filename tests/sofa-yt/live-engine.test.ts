// LIVE engine test (opt-in: SOFA_YT_LIVE=1 tools/test-sofa-yt). The browser engine on the real
// youtube.com in headless Firefox with a persistent dev profile (build/sofa-yt-live-firefox - never
// Sofa's own): one page load, at most one player request, ~100 s of media. Measures what step 4 of
// docs/youtube-engine.md needs: the page environment BotGuard sees, whether the engine's requests
// pass the page's CSP/CORS, and SABR's stream protection status (sps=1 accepted, 3 rejected).
// Sends nothing while Sofa's bot-check breaker (shared per IP) is open.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DIR, until } from './helpers.ts';
import { ENGINE, FIREFOX, bidi, callIn, engineMessages, injectEngine, launchFirefox, writeProfile } from './firefox.ts';
import type { VodAnswer } from '../../res/sofa-yt/lib/engine.ts';
import type { SessionStatus } from '../../res/sofa-yt/lib/session.ts';

const VID = process.env.SOFA_YT_LIVE_VIDEO || 'OzCYsIrrRyw';
const PROFILE = process.env.SOFA_YT_LIVE_PROFILE || path.resolve(DIR, '..', 'sofa-yt-live-firefox');
const SOFA_BLOCK = path.join(os.homedir(), 'Library', 'Caches', 'Sofa', 'youtube-block.json');   // read only
const MEDIA_MS = 100000;   // past the ~60 s SABR serves before it enforces stream protection

type Reply<T> = { ok: true; value: T } | { ok: false; status: number; body: { error: string } };
const value = <T>(r: Reply<T>, what: string): T => { if (!r.ok) throw new Error(`${what}: ${r.status} ${r.body.error}`); return r.value; };

function sofaBlock(): { until: number; backoff: number } | null {
  try { return JSON.parse(fs.readFileSync(SOFA_BLOCK, 'utf8')) as { until: number; backoff: number }; } catch { return null; }
}

test('live: the engine on youtube.com opens a video and SABR accepts its PO token', {
  skip: (!fs.existsSync(FIREFOX) && 'Firefox missing') || (!fs.existsSync(ENGINE) && 'engine bundle missing')
    || ((sofaBlock()?.until ?? 0) > Date.now() / 1000 && 'Sofa\'s bot-check breaker is open'),
  timeout: 240000,
}, async () => {
  writeProfile(PROFILE, { 'intl.accept_languages': 'de-AT, de, en-US, en' });
  const ff = await launchFirefox(PROFILE);
  const report = (k: string, v: unknown): void => { process.stderr.write(`LIVE-ENGINE ${k}: ${typeof v === 'string' ? v : JSON.stringify(v)}\n`); };
  try {
    const b = await bidi(ff.url);
    try {
      const context = await injectEngine(b, fs.readFileSync(ENGINE, 'utf8'));
      await b.send('session.subscribe', { events: ['log.entryAdded'] });   // the page's console (CSP, CORS errors)
      const nav = await b.send('browsingContext.navigate', { context, url: 'https://www.youtube.com/', wait: 'complete' }) as { url: string };
      report('landed on', nav.url);
      assert.ok(await until(async () => (await callIn<{ onYouTube: boolean }>(b, context, '() => sofaEngine.health()')).onYouTube, 20000, 250),
        `youtube.com page with ytcfg (landed on ${nav.url})`);
      report('page environment', await callIn(b, context, `() => ({
        webdriver: navigator.webdriver, languages: navigator.languages, platform: navigator.platform,
        cores: navigator.hardwareConcurrency, plugins: navigator.plugins.length,
        screen: [screen.width, screen.height, screen.colorDepth, devicePixelRatio], outer: [outerWidth, outerHeight],
        webgl: (() => { try { const g = document.createElement('canvas').getContext('webgl'); const d = g && g.getExtension('WEBGL_debug_renderer_info');
          return g ? [g.getParameter(d ? d.UNMASKED_VENDOR_WEBGL : g.VENDOR), g.getParameter(d ? d.UNMASKED_RENDERER_WEBGL : g.RENDERER)] : null; } catch (e) { return String(e); } })(),
        hl: ytcfg.get('HL'), gl: ytcfg.get('GL'), visitor: !!ytcfg.get('VISITOR_DATA'), client: ytcfg.get('INNERTUBE_CLIENT_VERSION'),
      })`));

      const block = sofaBlock();
      value(await callIn<Reply<{ userAgent: string }>>(b, context, `() => sofaEngine.start(${JSON.stringify({ base: 'http://127.0.0.1:9', block,
        maxPlayerRequests: 1, budgetWindowS: 3600, aheadLowS: 6, aheadHighS: 15, debug: true })})`), 'start');
      const t0 = Date.now();
      const open = await callIn<Reply<VodAnswer & { error?: string }>>(b, context, `() => sofaEngine.open({ v: '${VID}', prefetch: true })`);
      report('open', open.ok ? { ...open.value, audios: open.value.audios?.length, subs: open.value.subs?.length, endscreen: undefined } : open);
      const o = value(open, 'open');
      assert.equal(o.error, undefined, `open answered an error: ${o.error}`);
      report('open took', `${Date.now() - t0} ms`);

      // read the video track like a player: chunks in order until MEDIA_MS of media arrived
      let off = 0; let status: SessionStatus | null = null;
      const deadline = Date.now() + 150000;
      while (Date.now() < deadline) {
        const r = await callIn<Reply<{ total: number; data: string }>>(b, context, `() => sofaEngine.read('${o.sid}', 'video', ${off}, ${1 << 20})`);
        if (!r.ok) { report('read failed', r); break; }
        off += Buffer.from(r.value.data, 'base64').length;
        status = value(await callIn<Reply<SessionStatus>>(b, context, `() => sofaEngine.status('${o.sid}')`), 'status');
        const front = Math.max(0, ...status.pumps.map((p) => p.frontier.video ?? p.frontier[String(o.vitag)] ?? 0));
        if (front >= MEDIA_MS || off >= r.value.total) break;
      }
      report('read', `${(off / 1048576).toFixed(1)} MB in ${((Date.now() - t0) / 1000).toFixed(1)} s`);
      report('status', status);
      report('engine log', engineMessages(b).filter((m) => m.type === 'log').map((m) => m.line));
      report('console errors', b.events.filter((e) => e.method === 'log.entryAdded' && (e.params as { level?: string }).level === 'error')
        .map((e) => String((e.params as { text?: string }).text).slice(0, 300)).slice(0, 20));
      assert.deepEqual(engineMessages(b).filter((m) => m.type === 'log' && /csp:/.test(String(m.line))), [], 'no CSP violation (YouTube can see those)');
      assert.ok(status, 'read at least once');
      assert.equal(status.failed, null, 'session did not fail');
      const diags = status.pumps.map((p) => p.diag ?? '').join(' ');
      assert.doesNotMatch(diags, /sps=3/, 'stream protection rejected the PO token');
      assert.ok(off > 4 << 20, 'media arrived');
      await callIn(b, context, `() => sofaEngine.close('${o.sid}')`);
      await callIn(b, context, '() => sofaEngine.stop()');
      await b.send('session.end', {}).catch(() => {});
    } finally { b.close(); }
  } finally {
    await ff.stop();
  }
});
