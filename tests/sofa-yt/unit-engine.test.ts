// The browser engine (docs/youtube-engine.md) in headless Firefox, injected the way Sofa does it: the
// bundle from tools/build-yt-engine as a BiDi preload script with a channel. Checks the readiness
// event, health() and the API's answers off youtube.com. Offline: a file:// page, a fresh profile, no
// request to YouTube. Skipped without Firefox.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { tempDir, until, within } from './helpers.ts';

const FIREFOX = process.env.SOFA_FIREFOX || '/opt/local/bin/firefox';
const ENGINE = process.env.SOFA_YT_ENGINE || '';

type Json = Record<string, unknown>;

/** Minimal WebDriver BiDi client: commands by id, events collected. */
async function bidi(url: string): Promise<{ send: (method: string, params: object) => Promise<Json>; events: Json[]; close: () => void }> {
  const ws = new WebSocket(url);
  let id = 0;
  const events: Json[] = [];
  const waits = new Map<number, { ok: (r: Json) => void; bad: (e: Error) => void }>();
  ws.onmessage = (m) => {
    const j = JSON.parse(String(m.data)) as { id?: number; type?: string; error?: string; message?: string; result?: Json };
    if (j.type === 'event') { events.push(j as Json); return; }
    const w = j.id !== undefined ? waits.get(j.id) : undefined;
    if (!w) return;
    waits.delete(j.id!);
    if (j.type === 'error') w.bad(new Error(`${j.error}: ${j.message}`)); else w.ok(j.result ?? {});
  };
  await new Promise<void>((ok, bad) => { ws.onopen = () => ok(); ws.onerror = () => bad(new Error(`BiDi: cannot connect to ${url}`)); });
  return {
    send: (method, params) => new Promise((ok, bad) => { const i = ++id; waits.set(i, { ok, bad }); ws.send(JSON.stringify({ id: i, method, params })); }),
    events,
    close: () => ws.close(),
  };
}

test('the engine injects as a preload script, says ready over its channel, answers off youtube.com', {
  skip: (!fs.existsSync(FIREFOX) && 'Firefox missing') || (!fs.existsSync(ENGINE) && 'engine bundle missing (tools/build-yt-engine)'),
  timeout: 60000,
}, async () => {
  const dir = tempDir('sofa-yt-engine-');
  const profile = path.join(dir, 'profile');
  fs.mkdirSync(profile);   // must exist: a missing profile opens a modal dialog and hangs
  // no remote settings / updates / telemetry from the test profile
  fs.writeFileSync(path.join(profile, 'user.js'), ['services.settings.server", ""', 'app.update.enabled", false', 'toolkit.telemetry.enabled", false',
    'datareporting.policy.dataSubmissionEnabled", false'].map((p) => `user_pref("${p});\n`).join(''));
  fs.writeFileSync(path.join(dir, 'page.html'), '<!doctype html><title>page</title>');
  const env = { ...process.env };
  delete env.DYLD_INSERT_LIBRARIES;
  const ff = spawn(FIREFOX, ['--headless', '--no-remote', '--profile', profile, '--remote-debugging-port', '0', 'about:blank'], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  let err = '';
  ff.stderr.on('data', (d) => { err += d; });
  ff.stdout.on('data', (d) => { err += d; });
  const exited = new Promise((r) => ff.on('exit', r));
  try {
    assert.ok(await until(() => /WebDriver BiDi listening on (ws:\/\/\S+)/.test(err), 30000, 100), `BiDi port (${err.slice(-500)})`);
    const ws = /WebDriver BiDi listening on (ws:\/\/\S+)/.exec(err)![1]!;
    const b = await bidi(`${ws}/session`);
    try {
      await b.send('session.new', { capabilities: {} });
      await b.send('session.subscribe', { events: ['script.message'] });
      const tree = await b.send('browsingContext.getTree', {}) as { contexts: { context: string }[] };
      const context = tree.contexts[0]!.context;
      // as Sofa injects it: the bundle runs before the page's scripts and gets the channel
      await b.send('script.addPreloadScript', {
        functionDeclaration: `(post) => {\n${fs.readFileSync(ENGINE, 'utf8')}\n;globalThis.sofaEngine.connect(post);\n}`,
        arguments: [{ type: 'channel', value: { channel: 'sofa-engine' } }],
        contexts: [context],
      });
      await b.send('browsingContext.navigate', { context, url: `file://${dir}/page.html`, wait: 'complete' });
      const messages = (): { type: string; [k: string]: unknown }[] => b.events
        .filter((e) => e.method === 'script.message' && (e.params as Json).channel === 'sofa-engine')
        .map((e) => JSON.parse(String(((e.params as Json).data as Json).value)) as { type: string });
      // one ready per document the preload runs in (a transient initial one has url ''): the page's counts
      const isPage = (m: { type: string; url?: unknown }): boolean => m.type === 'ready' && /page\.html$/.test(String(m.url));
      assert.ok(await until(() => messages().some(isPage), 10000, 50), 'ready event of the page over the channel');
      const ready = messages().find(isPage)!;
      assert.match(String(ready.userAgent), /Firefox\/\d+/);

      const call = async <T>(fn: string): Promise<T> => {
        const r = await b.send('script.callFunction', { functionDeclaration: `async () => JSON.stringify(await (${fn})())`, target: { context }, awaitPromise: true }) as
          { type: string; result?: { value: string }; exceptionDetails?: { text: string } };
        if (r.type !== 'success') throw new Error(`callFunction: ${r.exceptionDetails?.text ?? r.type}`);
        return JSON.parse(r.result!.value) as T;
      };
      const h = await call<{ libraries: boolean; userAgent: string; onYouTube: boolean; engine: unknown }>('() => sofaEngine.health()');
      assert.equal(h.libraries, true, 'youtubei.js, googlevideo, BotGuard, WebPO, the engine core usable in the page');
      assert.match(h.userAgent, /Firefox\/\d+/);
      assert.deepEqual([h.onYouTube, h.engine], [false, null]);
      type Fail = { ok: false; status: number; body: { error: string } };
      const early = await call<Fail>("() => sofaEngine.open({ v: 'OzCYsIrrRyw' })");
      assert.deepEqual([early.ok, early.status], [false, 503], 'not started: no request');
      const start = await call<Fail>("() => sofaEngine.start({ base: 'http://127.0.0.1:1', block: null })");
      assert.deepEqual([start.ok, start.status], [false, 412], 'off youtube.com the engine does not start');
      assert.match(start.body.error, /not on a youtube\.com page/);
      await b.send('session.end', {}).catch(() => {});
    } finally { b.close(); }
  } finally {
    if (ff.exitCode === null) ff.kill('SIGTERM');
    await within(exited, 5000);
    if (ff.exitCode === null) ff.kill('SIGKILL');
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
