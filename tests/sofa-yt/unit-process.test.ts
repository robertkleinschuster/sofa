// The sidecar process contract: one readiness line on stdout, /health, breaker honoured for bg
// requests without any network access, exit when stdin closes (no orphans).
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';
import { DIR, get, json, nth, until, sleep } from './helpers.ts';
import type { OpenFailure } from '../../res/sofa-yt/lib/app.ts';

test('ready line, health, bg breaker, exit on stdin EOF', async () => {
  const state = fs.mkdtempSync(path.join(os.tmpdir(), 'sofa-yt-proc-'));
  const block = path.join(state, 'youtube-block.json');
  fs.writeFileSync(block, JSON.stringify({ until: Date.now() / 1000 + 600, backoff: 600 }));
  const env = { ...process.env };
  delete env.DYLD_INSERT_LIBRARIES;
  const child = spawn(process.env.SOFA_NODE || process.execPath,
    [path.join(DIR, 'main.ts'), '--port', '0', '--state', state, '--block-file', block, '--no-warm'],
    { env, stdio: ['pipe', 'pipe', 'pipe'] });
  let out = ''; let err = '';
  child.stdout.on('data', (d) => { out += d; });
  child.stderr.on('data', (d) => { err += d; });
  const exited = new Promise((r) => child.on('exit', (code) => r(code)));
  try {
    assert.ok(await until(() => out.includes('\n'), 10000), `ready line (stderr: ${err})`);
    const ready = json<{ ready: boolean; port: number }>(nth(out.split('\n'), 0));
    assert.equal(ready.ready, true);
    assert.ok(ready.port > 0);
    const base = `http://127.0.0.1:${ready.port}`;
    const h = json<{ ok: boolean; poToken: string; session: string; blocked_until: number }>((await get(`${base}/health`)).body);
    assert.equal(h.ok, true);
    assert.equal(h.poToken, 'pending');
    assert.equal(h.session, 'pending');
    assert.ok(h.blocked_until > Date.now() / 1000);
    // regression: kept-alive sockets stalled 2.5-27 s on 10.9 -> every response closes its connection
    for (let i = 0; i < 3; i++) {
      const t = Date.now();
      const r = await fetch(`${base}/health`);
      await r.json();
      assert.equal(r.headers.get('connection'), 'close');
      assert.ok(Date.now() - t < 1500, `request ${i} took ${Date.now() - t} ms`);
      await sleep(300);
    }
    const o = json<OpenFailure>((await get(`${base}/open?v=jNQXAC9IVRw&bg=1`)).body);
    assert.equal(o.bot, true);
    assert.match(o.error, /no request sent/);
    assert.ok(fs.existsSync(path.join(state, 'players')));
    assert.ok(!fs.existsSync(path.join(state, 'player-requests.json')), 'no player request was counted');
    assert.equal(out.trim().split('\n').length, 1, 'nothing but the readiness line on stdout');
    assert.match(err, /^sofa-yt: /m);
    child.stdin.end();
    const code = await Promise.race([exited, new Promise((r) => setTimeout(() => r('timeout'), 5000))]);
    assert.equal(code, 0, 'exits when stdin closes');
  } finally {
    if (child.exitCode === null) child.kill('SIGKILL');
    fs.rmSync(state, { recursive: true, force: true });
  }
});

test('--check loads every dependency', async () => {
  const env = { ...process.env };
  delete env.DYLD_INSERT_LIBRARIES;
  const child = spawn(process.env.SOFA_NODE || process.execPath, [path.join(DIR, 'main.ts'), '--check'], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  let err = '';
  child.stderr.on('data', (d) => { err += d; });
  const code = await new Promise((r) => child.on('exit', r));
  assert.equal(code, 0, err);
  assert.match(err, /check ok/);
});
