// LIVE engine over the extension channel (opt-in: SOFA_YT_LIVE=1 SOFA_YT_FILES=live-extension.test.ts
// tools/test-sofa-yt) - the way Sofa runs it: Firefox started as a user starts it (no remote agent:
// YouTube refuses a browser under remote control, docs/youtube-engine.md), on a virtual display, the
// engine extension installed in the live dev profile, Sofa's role played by enginehost.ts. One page
// load, at most one player request, ~100 s of media; asserts SABR's stream protection accepts it.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { DIR, until } from './helpers.ts';
import { FIREFOX, XVFB, DISPLAY_PREFS, startXvfb, launchFirefox, writeProfile } from './firefox.ts';
import { EXTENSION_PREFS, installExtension, startEngineHost } from './enginehost.ts';
import type { VodAnswer } from '../../res/sofa-yt/lib/engine.ts';
import type { SessionStatus } from '../../res/sofa-yt/lib/session.ts';

const EXTENSION = process.env.SOFA_YT_EXTENSION || '';
const VID = process.env.SOFA_YT_LIVE_VIDEO || 'OzCYsIrrRyw';
const PROFILE = process.env.SOFA_YT_LIVE_PROFILE || path.resolve(DIR, '..', 'sofa-yt-live-firefox');
const SOFA_BLOCK = path.join(os.homedir(), 'Library', 'Caches', 'Sofa', 'youtube-block.json');   // read only
const MEDIA_MS = 100000;

type Reply<T> = { ok: true; value: T } | { ok: false; status: number; body: { error: string } };
const value = <T>(r: Reply<T>, what: string): T => { if (!r.ok) throw new Error(`${what}: ${r.status} ${r.body.error}`); return r.value; };

function sofaBlock(): { until: number; backoff: number } | null {
  try { return JSON.parse(fs.readFileSync(SOFA_BLOCK, 'utf8')) as { until: number; backoff: number }; } catch { return null; }
}

test('live: the engine through the extension (no remote control) passes stream protection', {
  skip: (!fs.existsSync(FIREFOX) && 'Firefox missing') || (!fs.existsSync(XVFB) && 'Xvfb missing (port xorg-server-xvfb)')
    || (!fs.existsSync(path.join(EXTENSION, 'manifest.json')) && 'extension not built (tools/build-yt-engine)')
    || ((sofaBlock()?.until ?? 0) > Date.now() / 1000 && 'Sofa\'s bot-check breaker is open'),
  timeout: 300000,
}, async () => {
  // progress as it happens (the test runner shows output only at the end): build/live-extension.log
  const logFile = path.resolve(DIR, '..', 'live-extension.log');
  fs.writeFileSync(logFile, '');
  const report = (k: string, v: unknown): void => {
    const line = `LIVE-EXT ${k}: ${typeof v === 'string' ? v : JSON.stringify(v)}\n`;
    process.stderr.write(line); fs.appendFileSync(logFile, line);
  };
  const host = await startEngineHost({ onEvent: (e) => { if (e.type === 'log') fs.appendFileSync(logFile, `${String(e.line)}\n`); } });
  const screen = await startXvfb();
  writeProfile(PROFILE, { 'intl.accept_languages': 'de-AT, de, en-US, en', ...DISPLAY_PREFS, ...EXTENSION_PREFS });
  installExtension(PROFILE, EXTENSION, host);
  const ff = await launchFirefox(PROFILE, { display: screen.display, remote: false, url: 'https://www.youtube.com/' });
  try {
    const isPage = (m: { type: string; url?: unknown }): boolean => m.type === 'ready' && /^https:\/\/www\.youtube\.com\//.test(String(m.url));
    assert.ok(await until(() => host.events.some(isPage), 60000, 200), `engine ready over the extension (events: ${JSON.stringify(host.events).slice(0, 300)})`);
    assert.ok(await until(async () => (await host.callWithin<{ onYouTube: boolean }>(5000, 'health')).onYouTube, 20000, 500), 'page with ytcfg');
    report('environment', await host.call('health'));

    value(await host.call<Reply<unknown>>('start', { base: 'http://127.0.0.1:9', block: sofaBlock(), maxPlayerRequests: 1, budgetWindowS: 3600,
      aheadLowS: 6, aheadHighS: 15, debug: true }), 'start');
    const t0 = Date.now();
    const o = value(await host.call<Reply<VodAnswer & { error?: string }>>('open', { v: VID, prefetch: true }), 'open');
    report('open', { ...o, audios: o.audios?.length, subs: o.subs?.length, endscreen: undefined });
    assert.equal(o.error, undefined, `open answered an error: ${o.error}`);

    let off = 0; let status: SessionStatus | null = null;
    const deadline = Date.now() + 200000;
    while (Date.now() < deadline) {
      const r = await host.call<Reply<{ total: number; data: string }>>('read', o.sid, 'video', off, 1 << 20);
      if (!r.ok) { report('read failed', r); break; }
      off += Buffer.from(r.value.data, 'base64').length;
      status = value(await host.call<Reply<SessionStatus>>('status', o.sid), 'status');
      const front = Math.max(0, ...status.pumps.map((p) => p.frontier.video ?? p.frontier[String(o.vitag)] ?? 0));
      if (front >= MEDIA_MS || off >= r.value.total) break;
    }
    report('read', `${(off / 1048576).toFixed(1)} MB in ${((Date.now() - t0) / 1000).toFixed(1)} s`);
    report('status', status);
    const logs = host.events.filter((m) => m.type === 'log').map((m) => String(m.line));
    report('engine log', logs.filter((l) => /protection|rejected|csp:|failed|player request|webpo/.test(l)));
    assert.deepEqual(logs.filter((l) => /csp:/.test(l)), [], 'no CSP violation');
    assert.ok(status, 'read at least once');
    assert.equal(status.failed, null, 'session did not fail');
    assert.doesNotMatch(status.pumps.map((p) => p.diag ?? '').join(' '), /sps=3/, 'stream protection rejected the PO token');
    assert.ok(off > 4 << 20, 'media arrived');
    await host.call('close', o.sid);
    await host.call('stop');
  } finally {
    await ff.stop();
    await screen.stop();
    await host.close();
  }
});
