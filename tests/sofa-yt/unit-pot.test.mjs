// /pot: PO tokens for the yt-dlp fallback come from the sidecar's own minter (one BotGuard identity).
import test from 'node:test';
import assert from 'node:assert/strict';
import { fakeYouTube, startApp, get } from './helpers.mjs';

const breaker = { blockedUntil: () => 0, note() {} };

test('/pot mints a token for the given content binding', async () => {
  const bindings = [];
  const po = { state: 'ready', async mintString(b) { bindings.push(b); return 'tok-' + b; } };
  const a = await startApp({ youtube: fakeYouTube({}), po, breaker, startPump: () => {} });
  try {
    const r = await get(`${a.base}/pot?binding=${encodeURIComponent('CgtWaXNpdG9y%3D%3D')}`);
    assert.equal(r.status, 200);
    assert.equal(JSON.parse(r.body).poToken, 'tok-CgtWaXNpdG9y%3D%3D');
    assert.deepEqual(bindings, ['CgtWaXNpdG9y%3D%3D']);
  } finally { await a.close(); }
});

test('/pot without a binding is refused; a broken minter answers 503 (yt-dlp then goes without)', async () => {
  const po = { state: 'failed', async mintString() { throw new Error('BotGuard setup failed'); } };
  const a = await startApp({ youtube: fakeYouTube({}), po, breaker, startPump: () => {} });
  try {
    assert.equal((await get(`${a.base}/pot`)).status, 400);
    const r = await get(`${a.base}/pot?binding=abc`);
    assert.equal(r.status, 503);
    assert.match(JSON.parse(r.body).error, /BotGuard setup failed/);
  } finally { await a.close(); }
});
