// The idle reload must not race an open, an existing session (including pause/download), or a
// page request. Exercise the public engine API with cached media metadata and no network.
import test from 'node:test';
import assert from 'node:assert/strict';
import { sofaEngine } from '../../res/sofa-yt/web/engine.ts';
import { fixtureInfo } from './helpers.ts';

test('page reload waits for pending work and sessions; new work waits once reload is accepted', async (t) => {
  const info = fixtureInfo('OzCYsIrrRyw');
  const values = new Map<string, string>([[`sofa-engine:players/${info.id}.json`, JSON.stringify(info)]]);
  let reloads = 0;
  let finishImage: (r: Response) => void = () => {};
  const globals: Record<string, unknown> = {
    location: { origin: 'https://www.youtube.com', reload: () => { reloads++; } },
    ytcfg: { get: () => ({ client: { clientName: 'WEB' } }) },
    localStorage: { get length() { return values.size; }, key: (i: number) => [...values.keys()][i] ?? null,
      getItem: (k: string) => values.get(k) ?? null, setItem: (k: string, v: string) => values.set(k, v), removeItem: (k: string) => values.delete(k) },
    fetch: () => new Promise<Response>((r) => { finishImage = r; }),
  };
  for (const [key, value] of Object.entries(globals)) {
    const old = Object.getOwnPropertyDescriptor(globalThis, key);
    Object.defineProperty(globalThis, key, { value, configurable: true, writable: true });
    t.after(() => { if (old) Object.defineProperty(globalThis, key, old); else Reflect.deleteProperty(globalThis, key); });
  }
  t.after(() => sofaEngine.stop());
  assert.equal(sofaEngine.refresh(), false, 'not running');
  assert.equal(sofaEngine.start({ base: 'http://127.0.0.1:9', block: null }).ok, true);
  assert.ok(sofaEngine.health().pageAgeS >= 0, 'document age available even after host handover');

  const opening = sofaEngine.open({ v: info.id, prefetch: false });
  assert.equal(sofaEngine.refresh(), false, 'open has not created its session yet');
  const opened = await opening;
  assert.ok(opened.ok && 'sid' in opened.value);
  assert.equal(sofaEngine.health().engine?.sessions, 1);
  assert.equal(sofaEngine.refresh(), false, 'existing session survives, including paused playback');
  sofaEngine.close(opened.value.sid);

  const image = sofaEngine.image('https://i.ytimg.com/vi/test/default.jpg');
  assert.equal(sofaEngine.refresh(), false, 'page request in flight');
  finishImage(new Response(Uint8Array.of(1, 2, 3), { headers: { 'Content-Type': 'image/jpeg' } }));
  assert.equal((await image).ok, true);
  assert.equal(sofaEngine.refresh(), true, 'idle now');
  assert.equal(sofaEngine.refresh(), false, 'one reload only');
  const late = await sofaEngine.open({ v: info.id, prefetch: false });
  assert.ok(!late.ok && late.status === 503, 'no session starts in the departing document');
  await new Promise((r) => setTimeout(r, 150));
  assert.equal(reloads, 1);
});

// 2026-11-23: a two-day-old document had its token refused for 11 minutes while a session stayed
// open (stalls at 60 s). A refused document is replaced even under sessions and calls in flight.
test('forced page reload goes ahead under a session and in-flight work, once', async (t) => {
  const info = fixtureInfo('OzCYsIrrRyw');
  const values = new Map<string, string>([[`sofa-engine:players/${info.id}.json`, JSON.stringify(info)]]);
  let reloads = 0;
  const globals: Record<string, unknown> = {
    location: { origin: 'https://www.youtube.com', reload: () => { reloads++; } },
    ytcfg: { get: () => ({ client: { clientName: 'WEB' } }) },
    localStorage: { get length() { return values.size; }, key: (i: number) => [...values.keys()][i] ?? null,
      getItem: (k: string) => values.get(k) ?? null, setItem: (k: string, v: string) => values.set(k, v), removeItem: (k: string) => values.delete(k) },
    fetch: () => new Promise<Response>(() => {}),   // a page request that never answers
  };
  for (const [key, value] of Object.entries(globals)) {
    const old = Object.getOwnPropertyDescriptor(globalThis, key);
    Object.defineProperty(globalThis, key, { value, configurable: true, writable: true });
    t.after(() => { if (old) Object.defineProperty(globalThis, key, old); else Reflect.deleteProperty(globalThis, key); });
  }
  t.after(() => sofaEngine.stop());
  assert.equal(sofaEngine.refresh(true), false, 'not running');
  assert.equal(sofaEngine.start({ base: 'http://127.0.0.1:9', block: null }).ok, true);
  const opened = await sofaEngine.open({ v: info.id, prefetch: false });
  assert.ok(opened.ok && 'sid' in opened.value);
  void sofaEngine.image('https://i.ytimg.com/vi/test/default.jpg');
  assert.equal(sofaEngine.refresh(), false, 'idle refresh still waits');
  assert.equal(sofaEngine.refresh(true), true, 'stale document: replaced anyway');
  assert.equal(sofaEngine.refresh(true), false, 'one reload only');
  await new Promise((r) => setTimeout(r, 150));
  assert.equal(reloads, 1);
});
