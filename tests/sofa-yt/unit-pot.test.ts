// /pot: PO tokens for the yt-dlp fallback come from the sidecar's own minter (one BotGuard identity).
import test from 'node:test';
import assert from 'node:assert/strict';
import { fakeYouTube, json, startApp, get } from './helpers.ts';
import type { FakeStart } from './helpers.ts';

const breaker = { blockedUntil: () => 0, note() {} };
const noPump: FakeStart = () => { throw new Error('no SABR in /pot tests'); };

test('/pot mints a token for the given content binding', async () => {
  const bindings: string[] = [];
  const po = { state: 'ready' as const, async mintString(b: string) { bindings.push(b); return 'tok-' + b; } };
  const a = await startApp({ youtube: fakeYouTube({}), po, breaker, startPump: noPump });
  try {
    const r = await get(`${a.base}/pot?binding=${encodeURIComponent('CgtWaXNpdG9y%3D%3D')}`);
    assert.equal(r.status, 200);
    assert.equal(json<{ poToken: string }>(r.body).poToken, 'tok-CgtWaXNpdG9y%3D%3D');
    assert.deepEqual(bindings, ['CgtWaXNpdG9y%3D%3D']);
  } finally { await a.close(); }
});

test('/pot without a binding is refused; a broken minter answers 503 (yt-dlp then goes without)', async () => {
  const po = { state: 'error' as const, async mintString(): Promise<string> { throw new Error('BotGuard setup failed'); } };
  const a = await startApp({ youtube: fakeYouTube({}), po, breaker, startPump: noPump });
  try {
    assert.equal((await get(`${a.base}/pot`)).status, 400);
    const r = await get(`${a.base}/pot?binding=abc`);
    assert.equal(r.status, 503);
    assert.match(json<{ error: string }>(r.body).error, /BotGuard setup failed/);
  } finally { await a.close(); }
});
