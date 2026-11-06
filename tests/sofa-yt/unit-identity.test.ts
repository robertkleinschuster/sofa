// The one browser identity (lib/identity.ts) and the app's InnerTube route (POST /yt/<endpoint>).
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { identityFor, browserContext, majorFromVersionHistory, loadIdentity, loadVisitor, saveVisitor, CookieJar, browserFetch } from '../../res/sofa-yt/lib/identity.ts';
import { startApp, tempDir } from './helpers.ts';

test('user agent is a complete current Chrome with matching client hints', () => {
  const id = identityFor(142);
  assert.equal(id.userAgent, 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36');
  assert.match(id.headers['sec-ch-ua']!, /"Google Chrome";v="142"/);
  assert.equal(id.headers['sec-ch-ua-platform'], '"macOS"');
  assert.match(id.headers['accept-language']!, /^de-AT/);
});

test('InnerTube browser fields match the user agent', () => {
  assert.deepEqual(browserContext(identityFor(158)), { browserName: 'Chrome', browserVersion: '158.0.0.0' });
});

test('Chrome major from the version history, nonsense refused', () => {
  assert.equal(majorFromVersionHistory({ versions: [{ version: '142.0.7444.60' }] }), 142);
  assert.equal(majorFromVersionHistory({ versions: [] }), null);
  assert.equal(majorFromVersionHistory({ versions: [{ version: '7.1' }] }), null);
  assert.equal(majorFromVersionHistory(null), null);
});

test('loadIdentity: asks once a week, keeps the last known version when unreachable', async () => {
  const dir = tempDir('sofa-yt-identity-');
  let asked = 0;
  const ok = (async () => { asked++; return new Response(JSON.stringify({ versions: [{ version: '150.0.1.2' }] })); }) as typeof fetch;
  assert.equal((await loadIdentity(dir, ok)).chromeMajor, 150);
  assert.equal((await loadIdentity(dir, ok)).chromeMajor, 150);
  assert.equal(asked, 1, 'cached for a week');
  const file = path.join(dir, 'identity.json');
  fs.writeFileSync(file, JSON.stringify({ major: 151, at: 0 }));   // expired
  const down = (async () => { throw new Error('offline'); }) as typeof fetch;
  assert.equal((await loadIdentity(dir, down)).chromeMajor, 151);
});

test('visitor: kept across restarts, garbage ignored', () => {
  const dir = tempDir('sofa-yt-visitor-');
  assert.equal(loadVisitor(dir), undefined);
  saveVisitor(dir, 'CgtABC');
  assert.equal(loadVisitor(dir), 'CgtABC');
  saveVisitor(dir, '');
  assert.equal(loadVisitor(dir), 'CgtABC', 'an empty answer does not forget the visitor');
  fs.writeFileSync(path.join(dir, 'visitor.json'), '{"visitorData":5}');
  assert.equal(loadVisitor(dir), undefined);
});

test('cookie jar: keeps youtube.com cookies, honours expiry, persists', () => {
  const dir = tempDir('sofa-yt-jar-');
  const file = path.join(dir, 'cookies.json');
  const jar = new CookieJar(file);
  jar.store('www.youtube.com', ['YSC=abc; Domain=.youtube.com; Path=/; Secure; HttpOnly', 'VISITOR_INFO1_LIVE=v1; Max-Age=15552000; Path=/', 'GONE=x; Max-Age=0']);
  jar.store('www.example.com', ['OTHER=1']);
  assert.equal(jar.header('www.youtube.com'), 'YSC=abc; VISITOR_INFO1_LIVE=v1');
  assert.equal(jar.header('rr1---sn.googlevideo.com'), null, 'never sent beyond youtube.com');
  assert.equal(new CookieJar(file).header('youtube.com'), 'YSC=abc; VISITOR_INFO1_LIVE=v1', 'survives a restart');
  jar.store('www.youtube.com', ['YSC=; Max-Age=0']);
  assert.equal(jar.header('www.youtube.com'), 'VISITOR_INFO1_LIVE=v1');
});

test('browserFetch: identity headers and cookies to YouTube, nothing added elsewhere', async () => {
  const jar = new CookieJar(path.join(tempDir('sofa-yt-bf-'), 'c.json'));
  const seen: Request[] = [];
  const base = (async (r: Request) => {
    seen.push(r);
    return new Response('{}', { headers: r.url.includes('youtube.com') ? { 'set-cookie': 'YSC=s1; Path=/' } : {} });
  }) as unknown as typeof fetch;
  const f = browserFetch(identityFor(142), jar, base);
  await f('https://www.youtube.com/youtubei/v1/browse', { method: 'POST', body: '{}', headers: { 'user-agent': 'node', 'content-type': 'application/json' } });
  await f('https://www.youtube.com/youtubei/v1/next', { method: 'POST', body: '{}' });
  await f('https://example.org/x');
  assert.match(seen[0]!.headers.get('user-agent')!, /Chrome\/142/);
  assert.equal(seen[0]!.headers.get('content-type'), 'application/json', "caller's own headers stay");
  assert.equal(seen[0]!.headers.get('cookie'), null, 'no cookie before YouTube set one');
  assert.equal(seen[1]!.headers.get('cookie'), 'YSC=s1', 'sent back like a browser');
  assert.equal(seen[2]!.headers.get('user-agent'), null, 'other hosts untouched');
});

test('POST /yt/<endpoint>: app calls go through the session; player and unknown endpoints refused; bg respects the breaker', async () => {
  const calls: { endpoint: string; body: Record<string, unknown>; bg: boolean }[] = [];
  let blocked = 0;
  const t = await startApp({
    startPump: (() => { throw new Error('no pump'); }) as never,
    breaker: { blockedUntil: () => blocked },
    po: {},
    youtube: {
      info: async () => { throw new Error('no info'); },
      innertube: async (endpoint, body, { bg = false } = {}) => {
        if (bg && blocked) throw Object.assign(new Error('paused'), { bot: true });
        calls.push({ endpoint, body, bg });
        return { ok: endpoint };
      },
    },
  });
  try {
    const post = (p: string, body: unknown) => fetch(t.base + p, { method: 'POST', body: JSON.stringify(body) });
    let r = await post('/yt/browse', { browseId: 'UCx' });
    assert.equal(r.status, 200);
    assert.deepEqual(await r.json(), { ok: 'browse' });
    r = await post('/yt/navigation/resolve_url?bg=1', { url: 'https://www.youtube.com/@x' });
    assert.equal(r.status, 200);
    assert.deepEqual(calls.map((c) => [c.endpoint, c.bg]), [['browse', false], ['navigation/resolve_url', true]]);
    assert.equal((await post('/yt/player', { videoId: 'abcdefghijk' })).status, 404, 'player is the sidecar\'s own job');
    assert.equal((await post('/yt/browse', [1])).status, 400);
    blocked = Date.now() + 60000;
    r = await post('/yt/browse?bg=1', { browseId: 'UCx' });
    assert.equal(r.status, 503);
    assert.equal(((await r.json()) as { bot: boolean }).bot, true);
    assert.equal((await post('/yt/browse', { browseId: 'UCx' })).status, 200, 'what the viewer opens still loads');
  } finally { await t.close(); }
});

test('GET /suggest: the search box request, answer passed through', async () => {
  const asked: URL[] = [];
  const t = await startApp({
    startPump: (() => { throw new Error('no pump'); }) as never,
    breaker: { blockedUntil: () => 0 }, po: {},
    youtube: { info: async () => { throw new Error('no info'); } },
    suggestFetch: (async (u: URL) => { asked.push(new URL(u)); return new Response(JSON.stringify(['ter', [['terra x', 0]], {}])); }) as unknown as typeof fetch,
  });
  try {
    const r = await fetch(`${t.base}/suggest?q=ter`);
    assert.equal(r.status, 200);
    assert.deepEqual(await r.json(), ['ter', [['terra x', 0]], {}]);
    assert.equal(asked[0]!.hostname, 'suggestqueries-clients6.youtube.com');
    assert.equal(asked[0]!.searchParams.get('q'), 'ter');
    assert.equal(asked[0]!.searchParams.get('hl'), 'de');
    assert.equal((await fetch(`${t.base}/suggest`)).status, 400);
  } finally { await t.close(); }
});
