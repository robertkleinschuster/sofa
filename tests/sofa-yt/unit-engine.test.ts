// The browser engine (docs/youtube-engine.md) loads in headless Firefox: the bundle from
// tools/build-yt-engine is injected into a local page over WebDriver BiDi and answers health().
// Offline: a file:// page, a fresh profile, no request to YouTube. Skipped without Firefox.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { tempDir, until, within } from './helpers.ts';

const FIREFOX = process.env.SOFA_FIREFOX || '/opt/local/bin/firefox';
const ENGINE = process.env.SOFA_YT_ENGINE || '';

/** Minimal WebDriver BiDi client: one command at a time is all the test needs. */
async function bidi(url: string): Promise<{ send: (method: string, params: object) => Promise<Record<string, unknown>>; close: () => void }> {
  const ws = new WebSocket(url);
  let id = 0;
  const waits = new Map<number, { ok: (r: Record<string, unknown>) => void; bad: (e: Error) => void }>();
  ws.onmessage = (m) => {
    const j = JSON.parse(String(m.data)) as { id?: number; type?: string; error?: string; message?: string; result?: Record<string, unknown> };
    const w = j.id !== undefined ? waits.get(j.id) : undefined;
    if (!w) return;
    waits.delete(j.id!);
    if (j.type === 'error') w.bad(new Error(`${j.error}: ${j.message}`)); else w.ok(j.result ?? {});
  };
  await new Promise<void>((ok, bad) => { ws.onopen = () => ok(); ws.onerror = () => bad(new Error(`BiDi: cannot connect to ${url}`)); });
  return {
    send: (method, params) => new Promise((ok, bad) => { const i = ++id; waits.set(i, { ok, bad }); ws.send(JSON.stringify({ id: i, method, params })); }),
    close: () => ws.close(),
  };
}

test('the engine bundle loads in headless Firefox and answers health()', {
  skip: (!fs.existsSync(FIREFOX) && 'Firefox missing') || (!fs.existsSync(ENGINE) && 'engine bundle missing (tools/build-yt-engine)'),
  timeout: 60000,
}, async () => {
  const dir = tempDir('sofa-yt-engine-');
  const profile = path.join(dir, 'profile');
  fs.mkdirSync(profile);   // must exist: a missing profile opens a modal dialog and hangs
  // no remote settings / updates / telemetry from the test profile
  fs.writeFileSync(path.join(profile, 'user.js'), ['services.settings.server", ""', 'app.update.enabled", false', 'toolkit.telemetry.enabled", false',
    'datareporting.policy.dataSubmissionEnabled", false'].map((p) => `user_pref("${p});\n`).join(''));
  fs.copyFileSync(ENGINE, path.join(dir, 'engine.js'));
  fs.writeFileSync(path.join(dir, 'page.html'), '<!doctype html><title>engine</title><script src="engine.js"></script>');
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
      const tree = await b.send('browsingContext.getTree', {}) as { contexts: { context: string }[] };
      const context = tree.contexts[0]!.context;
      await b.send('browsingContext.navigate', { context, url: `file://${dir}/page.html`, wait: 'complete' });
      const r = await b.send('script.evaluate', { expression: 'JSON.stringify(globalThis.sofaEngine.health())', target: { context }, awaitPromise: false }) as { result: { value: string } };
      const h = JSON.parse(r.result.value) as { libraries: boolean; userAgent: string };
      assert.equal(h.libraries, true, 'youtubei.js, googlevideo, BotGuard, WebPO usable in the page');
      assert.match(h.userAgent, /Firefox\/\d+/);
      await b.send('session.end', {}).catch(() => {});
    } finally { b.close(); }
  } finally {
    if (ff.exitCode === null) ff.kill('SIGTERM');
    await within(exited, 5000);
    if (ff.exitCode === null) ff.kill('SIGKILL');
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
