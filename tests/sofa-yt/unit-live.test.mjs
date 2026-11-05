// Lives, post-live DVR and upcoming streams (docs/sofa-yt.md "Lives"). Fixtures: the WEB player
// response of a running 24/7 live (DW News, LuKwFajn37U, recorded 2026-11-05, trimmed, IPs and
// signatures replaced) plus its master and one variant playlist. Upcoming / offline / post-live
// responses are synthetic variations of it (field names as yt-dlp / youtubei.js read them).
// No network: playlist fetches go to a fake fetch.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { mod, FIX, fixturePlayer, startApp, sleep } from './helpers.mjs';

const hls = await mod('lib/hls.mjs');
const { YouTube, classifyPlayer } = await mod('lib/youtube.mjs');

const LIVE = 'LuKwFajn37U';
const rawLive = () => JSON.parse(fs.readFileSync(path.join(FIX, `player-${LIVE}-live.json`), 'utf8'));
const MASTER = fs.readFileSync(path.join(FIX, `${LIVE}-master.m3u8`), 'utf8');
const VARIANT = fs.readFileSync(path.join(FIX, `${LIVE}-variant.m3u8`), 'utf8');
const N_RAW = 'dBVzFUDqFqWSznjiZg';
const N_SOLVED = 'Y4kBFwVlETpG5g';   // recorded transform of player ef321720

function upcomingRaw(start = Math.floor(Date.now() / 1000) + 7200) {
  const r = rawLive();
  r.playabilityStatus = { status: 'LIVE_STREAM_OFFLINE', reason: 'This live event will begin in 2 hours.',
    liveStreamability: { liveStreamabilityRenderer: { videoId: LIVE, offlineSlate: { liveStreamOfflineSlateRenderer: { scheduledStartTime: String(start) } } } } };
  r.videoDetails = { ...r.videoDetails, isLive: false, isUpcoming: true };
  delete r.streamingData;
  return r;
}

// ---- pure helpers ---------------------------------------------------------------------------

test('classifyPlayer: live, post-live DVR, upcoming (slate and premiere), offline, VOD, error', () => {
  assert.equal(classifyPlayer(rawLive()).kind, 'live');
  const pl = rawLive(); pl.videoDetails = { ...pl.videoDetails, isLive: false, isPostLiveDvr: true, lengthSeconds: '5400' };
  assert.equal(classifyPlayer(pl).kind, 'postlive');
  const start = Math.floor(Date.now() / 1000) + 7200;
  assert.deepEqual(classifyPlayer(upcomingRaw(start)), { kind: 'upcoming', startTime: start });
  // premiere: status OK, isUpcoming, start time only in the microformat
  const prem = rawLive(); prem.videoDetails = { ...prem.videoDetails, isLive: false, isUpcoming: true };
  prem.microformat.playerMicroformatRenderer.liveBroadcastDetails = { isLiveNow: false, startTimestamp: new Date(start * 1000).toISOString() };
  assert.deepEqual(classifyPlayer(prem), { kind: 'upcoming', startTime: start });
  const off = rawLive(); off.playabilityStatus = { status: 'LIVE_STREAM_OFFLINE', reason: 'offline' }; off.videoDetails.isLive = false;
  off.microformat = {};
  assert.equal(classifyPlayer(off).kind, 'offline');
  assert.equal(classifyPlayer({ playabilityStatus: { status: 'OK' }, ...fixturePlayer('OzCYsIrrRyw') }).kind, 'vod');
  assert.equal(classifyPlayer({ playabilityStatus: { status: 'UNPLAYABLE' } }).kind, 'error');
});

test('prepareManifestUrl: solves the path n and adds the PO token before /file/index.m3u8', async () => {
  const u = rawLive().streamingData.hlsManifestUrl;
  assert.equal(hls.pathN(u), N_RAW);
  const out = await hls.prepareManifestUrl(u, { solve: async (n) => (n === N_RAW ? N_SOLVED : null), poToken: 'TOK-en_1' });
  assert.ok(out.includes(`/n/${N_SOLVED}/`) && !out.includes(N_RAW));
  assert.ok(out.endsWith('/pot/TOK-en_1/file/index.m3u8'), out.slice(-60));
  assert.equal(hls.pathExpire(out), 1793887394);
  await assert.rejects(hls.prepareManifestUrl(u, { solve: async (n) => n }), /not solved/);
  // no n in the path: untouched apart from the token
  assert.equal(await hls.prepareManifestUrl('https://m.example/api/x/file/index.m3u8', {}), 'https://m.example/api/x/file/index.m3u8');
});

test('parseMaster + pickVariant on the recorded master playlist', () => {
  const v = hls.parseMaster(MASTER, 'https://manifest.googlevideo.com/x/index.m3u8');
  assert.deepEqual(v.map((x) => x.itag), [91, 92, 93, 94, 300, 301]);
  assert.deepEqual(v.map((x) => x.height), [144, 240, 360, 480, 720, 1080]);
  assert.equal(hls.pickVariant(v, 1080).itag, 301);
  assert.equal(hls.pickVariant(v, 720).itag, 300);
  assert.equal(hls.pickVariant(v, 100).itag, 91);           // nothing fits: the smallest
  assert.equal(hls.pickVariant(v, 1080, 94).itag, 94);      // renewal keeps the chosen itag
  assert.equal(hls.codecShort(v[5].codecs), 'avc1');
  assert.ok(v.every((x) => x.url.startsWith('https://manifest.googlevideo.com/api/manifest/hls_playlist/')));
});

test('absolutize: relative segment and MAP URIs become absolute', () => {
  const t = '#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:5.0,\nseg/1.ts\n#EXTINF:5.0,\nhttps://other/2.ts\n';
  const out = hls.absolutize(t, 'https://h.example/a/b/index.m3u8');
  assert.match(out, /URI="https:\/\/h\.example\/a\/b\/init\.mp4"/);
  assert.match(out, /^https:\/\/h\.example\/a\/b\/seg\/1\.ts$/m);
  assert.match(out, /^https:\/\/other\/2\.ts$/m);
});

// ---- youtube.mjs: player request -> live info / upcoming ------------------------------------

function makeYouTube(raws) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sofa-yt-live-'));
  const notes = [];
  const yt = new YouTube({ stateDir: dir, breaker: { blockedUntil: () => 0, note: (b) => notes.push(b) }, po: { mintString: async () => 'POTOKEN' } });
  yt.requests = 0;
  const player = {
    player_id: 'ef321720', signature_timestamp: 20759,
    async decipher(url) { const u = new URL(url); if (u.searchParams.get('n') === N_RAW) u.searchParams.set('n', N_SOLVED); return u.toString(); },
  };
  yt.session = async () => ({
    session: { player, context: { client: { clientVersion: '2.20261030.02.00' } } },
    actions: { execute: async () => { yt.requests++; return { data: raws.shift() }; } },
  });
  yt.notes = notes;
  return yt;
}

test('a live player response becomes an HLS info (n solved with the request player, token in the path), cached', async () => {
  const yt = makeYouTube([rawLive()]);
  const { info, cached } = await yt.info(LIVE);
  assert.equal(cached, false);
  assert.equal(info.kind, 'hls');
  assert.equal(info.live, true);
  assert.equal(info.durationMs, 0);
  assert.ok(info.hlsUrl.includes(`/n/${N_SOLVED}/`) && info.hlsUrl.includes('/pot/POTOKEN/file/index.m3u8'));
  assert.equal(info.expires, 1793887394);
  assert.deepEqual(yt.notes, [false]);
  // reopening within the URL's lifetime costs no request
  assert.equal((await yt.info(LIVE)).cached, true);
  assert.equal(yt.requests, 1);
});

test('post-live DVR: HLS info with the recording duration, live=false', async () => {
  const r = rawLive(); r.videoDetails = { ...r.videoDetails, isLive: false, isPostLiveDvr: true, lengthSeconds: '5400' };
  const yt = makeYouTube([r]);
  const { info } = await yt.info(LIVE);
  assert.equal(info.kind, 'hls');
  assert.equal(info.live, false);
  assert.equal(info.postLiveDvr, true);
  assert.equal(info.durationMs, 5400000);
});

test('live without an HLS manifest: live error (Sofa falls back to yt-dlp)', async () => {
  const r = rawLive(); delete r.streamingData.hlsManifestUrl;
  const yt = makeYouTube([r]);
  await assert.rejects(yt.info(LIVE), (e) => e.live === true && !e.upcoming && /without HLS/.test(e.message));
});

test('upcoming: error with start time, no breaker hit, repeated opens within 60 s send nothing', async () => {
  const start = Math.floor(Date.now() / 1000) + 3600;
  const yt = makeYouTube([upcomingRaw(start), upcomingRaw(start)]);
  await assert.rejects(yt.info(LIVE), (e) => e.upcoming === true && e.live === true && e.startTime === start && e.message === 'upcoming');
  await assert.rejects(yt.info(LIVE), (e) => e.upcoming === true);
  assert.equal(yt.requests, 1);
  assert.deepEqual(yt.notes, [false]);
  assert.equal(yt.cached(LIVE), null);   // never cached on disk
});

// ---- app: /open + live.m3u8 proxy ---------------------------------------------------------------

function liveInfo(over = {}) {
  return { id: LIVE, kind: 'hls', live: true, postLiveDvr: false, title: 'DW News', durationMs: 0,
    expires: Math.floor(Date.now() / 1000) + 6 * 3600, hlsUrl: 'https://manifest.googlevideo.com/api/manifest/hls_variant/v1/file/index.m3u8',
    clientVersion: '2.0', captions: null, endscreen: [], fetchedAt: Math.floor(Date.now() / 1000), ...over };
}

/** Fake upstream: master + variant playlists, scripted failures. */
function fakeUpstream({ variant = VARIANT } = {}) {
  const f = { master: 0, variant: 0, failVariant: [], variantBody: variant, masterStatus: 200, lastHeaders: null };
  f.fetch = async (url, opts) => {
    f.lastHeaders = opts?.headers;
    const u = String(url);
    const mk = (status, body) => ({ ok: status < 300, status, url: u, text: async () => body });
    if (u.includes('/hls_variant/')) { f.master++; return f.masterStatus === 200 ? mk(200, MASTER) : mk(f.masterStatus, ''); }
    if (u.includes('/hls_playlist/')) {
      f.variant++;
      const st = f.failVariant.shift();
      if (st) return mk(st, 'nope');
      return mk(200, f.variantBody);
    }
    return mk(404, '');
  };
  return f;
}

function fakeYT(info, { refreshInfo } = {}) {
  const y = {
    requests: 0, refreshes: 0, forgotten: 0, sessionState: 'ready',
    async info() { y.requests++; return { info, cached: y.requests > 1 }; },
    async refresh() { y.refreshes++; if (!refreshInfo) throw new Error('reload limit reached'); return refreshInfo(); },
    forget() { y.forgotten++; },
    async webHeaders() { return { 'user-agent': 'UA-test' }; },
  };
  return y;
}

const breaker = { blockedUntil: () => 0, note() {} };
const j = async (url) => (await fetch(url)).json();

test('/open of a live: local HLS playlist URL, live flag, chosen variant; playlist proxied with absolute URLs', async () => {
  const up = fakeUpstream();
  const yt = fakeYT(liveInfo());
  const app = await startApp({ youtube: yt, po: {}, breaker, startPump: () => assert.fail('no SABR for lives'), fetchFn: up.fetch });
  try {
    const r = await j(`${app.base}/open?v=${LIVE}&maxHeight=720`);
    assert.equal(r.error, undefined, JSON.stringify(r));
    assert.equal(r.live, true);
    assert.equal(r.hls, `${app.base}/s/${r.sid}/live.m3u8`);
    assert.equal(r.video, undefined);   // not a DASH pair: Sofa opens `hls` directly
    assert.equal(r.height, 720); assert.equal(r.fps, 60); assert.equal(r.vitag, 300); assert.equal(r.vcodec, 'avc1'); assert.equal(r.acodec, 'mp4a');
    assert.equal(up.master, 1);
    const res = await fetch(r.hls);
    assert.equal(res.status, 200);
    assert.match(res.headers.get('content-type'), /mpegurl/);
    const body = await res.text();
    assert.ok(body.startsWith('#EXTM3U'));
    assert.equal(body.split('\n').filter((l) => l && !l.startsWith('#')).length, 6);
    assert.ok(body.split('\n').filter((l) => l && !l.startsWith('#')).every((l) => l.startsWith('https://')));
    assert.equal(up.lastHeaders['user-agent'], 'UA-test');   // the web identity's headers
    // micro cache: an immediate second read does not hit upstream again
    await fetch(r.hls).then((x) => x.text());
    assert.equal(up.variant, 1);
    const st = await j(`${app.base}/s/${r.sid}/status`);
    assert.equal(st.kind, 'hls'); assert.equal(st.ended, false); assert.equal(st.variant.itag, 300);
    // a second /open reuses the session
    const r2 = await j(`${app.base}/open?v=${LIVE}&maxHeight=720`);
    assert.equal(r2.sid, r.sid); assert.equal(r2.reused, true);
    // DASH routes do not exist for a live session
    assert.equal((await fetch(`${app.base}/s/${r.sid}/video`)).status, 404);
  } finally { await app.close(); }
});

test('rejected variant playlist (403): one guarded renewal, same itag, then served', async () => {
  const up = fakeUpstream();
  up.failVariant = [403];
  const info = liveInfo();
  const yt = fakeYT(info, { refreshInfo: () => ({ ...info, hlsUrl: info.hlsUrl.replace('/v1/', '/v2/'), expires: info.expires + 3600 }) });
  const app = await startApp({ youtube: yt, po: {}, breaker, startPump: () => {}, fetchFn: up.fetch });
  try {
    const r = await j(`${app.base}/open?v=${LIVE}&maxHeight=480`);
    const res = await fetch(r.hls);
    assert.equal(res.status, 200);
    await res.text();
    assert.equal(yt.refreshes, 1);
    assert.equal(up.master, 2);
    const st = await j(`${app.base}/s/${r.sid}/status`);
    assert.equal(st.renewals, 1); assert.equal(st.variant.itag, 94); assert.equal(st.failures, 0);
  } finally { await app.close(); }
});

test('URL about to expire: renewed before fetching the playlist', async () => {
  const up = fakeUpstream();
  const info = liveInfo({ expires: Math.floor(Date.now() / 1000) + 120 });
  const yt = fakeYT(info, { refreshInfo: () => ({ ...info, expires: Math.floor(Date.now() / 1000) + 6 * 3600 }) });
  const app = await startApp({ youtube: yt, po: {}, breaker, startPump: () => {}, fetchFn: up.fetch });
  try {
    const r = await j(`${app.base}/open?v=${LIVE}`);
    assert.equal((await fetch(r.hls)).status, 200);
    assert.equal(yt.refreshes, 1);
  } finally { await app.close(); }
});

test('a refused early renewal does not break a still valid URL and is not retried on every reload', async () => {
  const up = fakeUpstream();
  const yt = fakeYT(liveInfo({ expires: Math.floor(Date.now() / 1000) + 120 }));   // refresh throws (limit)
  const app = await startApp({ youtube: yt, po: {}, breaker, startPump: () => {}, fetchFn: up.fetch, liveCfg: { MICRO_CACHE_MS: 0 } });
  try {
    const r = await j(`${app.base}/open?v=${LIVE}`);
    for (let i = 0; i < 3; i++) assert.equal((await fetch(r.hls)).status, 200);
    assert.equal(yt.refreshes, 1);
  } finally { await app.close(); }
});

test('upstream keeps failing: 502 per failed reload, session failed (503) after 3, no request storm', async () => {
  const up = fakeUpstream();
  up.failVariant = [500, 500, 500, 500];
  const yt = fakeYT(liveInfo());
  const app = await startApp({ youtube: yt, po: {}, breaker, startPump: () => {}, fetchFn: up.fetch, liveCfg: { MICRO_CACHE_MS: 0 } });
  try {
    const r = await j(`${app.base}/open?v=${LIVE}`);
    assert.equal((await fetch(r.hls)).status, 502);
    assert.equal((await fetch(r.hls)).status, 502);
    assert.equal((await fetch(r.hls)).status, 503);
    assert.equal((await fetch(r.hls)).status, 503);
    assert.equal(up.variant, 3);
    assert.equal(yt.refreshes, 0);   // 5xx is no reason for a player request
  } finally { await app.close(); }
});

test('broadcast ended (EXT-X-ENDLIST) is reported in /status', async () => {
  const up = fakeUpstream({ variant: `${VARIANT.trimEnd()}\n#EXT-X-ENDLIST\n` });
  const app = await startApp({ youtube: fakeYT(liveInfo()), po: {}, breaker, startPump: () => {}, fetchFn: up.fetch });
  try {
    const r = await j(`${app.base}/open?v=${LIVE}`);
    assert.match(await (await fetch(r.hls)).text(), /#EXT-X-ENDLIST/);
    assert.equal((await j(`${app.base}/s/${r.sid}/status`)).ended, true);
  } finally { await app.close(); }
});

test('unusable manifest at /open: live error, cached URL forgotten, no session', async () => {
  const up = fakeUpstream();
  up.masterStatus = 403;
  const yt = fakeYT(liveInfo());
  const app = await startApp({ youtube: yt, po: {}, breaker, startPump: () => {}, fetchFn: up.fetch });
  try {
    await j(`${app.base}/open?v=${LIVE}`);            // first open: "player request"
    const r = await j(`${app.base}/open?v=${LIVE}`);  // second: from cache
    assert.equal(r.live, true); assert.match(r.error, /HLS manifest unavailable: HTTP 403/);
    assert.equal(yt.forgotten, 1);
    assert.equal(app.app.sessions.size, 0);
  } finally { await app.close(); }
});

test('post-live DVR opens as a seekable HLS recording (live=false, duration)', async () => {
  const up = fakeUpstream({ variant: `${VARIANT.trimEnd()}\n#EXT-X-ENDLIST\n` });
  const app = await startApp({ youtube: fakeYT(liveInfo({ live: false, postLiveDvr: true, durationMs: 5400000 })), po: {}, breaker, startPump: () => {}, fetchFn: up.fetch });
  try {
    const r = await j(`${app.base}/open?v=${LIVE}`);
    assert.equal(r.live, false); assert.equal(r.postLiveDvr, true); assert.equal(r.duration, 5400);
    assert.ok(r.hls);
  } finally { await app.close(); }
});

test('background opens (downloads) of lives are refused with live:true', async () => {
  const app = await startApp({ youtube: fakeYT(liveInfo()), po: {}, breaker, startPump: () => {}, fetchFn: fakeUpstream().fetch });
  try {
    const r = await j(`${app.base}/open?v=${LIVE}&bg=1`);
    assert.equal(r.live, true); assert.equal(r.error, 'live');
    assert.equal(app.app.sessions.size, 0);
  } finally { await app.close(); }
});

test('/open of an upcoming stream: error upcoming with the start time', async () => {
  const start = Math.floor(Date.now() / 1000) + 3600;
  const yt = { sessionState: 'ready', async info() { const e = new Error('upcoming'); e.live = true; e.upcoming = true; e.startTime = start; throw e; } };
  const app = await startApp({ youtube: yt, po: {}, breaker, startPump: () => {} });
  try {
    const r = await j(`${app.base}/open?v=${LIVE}`);
    assert.deepEqual({ error: r.error, live: r.live, upcoming: r.upcoming, startTime: r.startTime, bot: r.bot }, { error: 'upcoming', live: true, upcoming: true, startTime: start, bot: false });
  } finally { await app.close(); }
});

test('idle live sessions expire like VOD sessions', async () => {
  const app = await startApp({ youtube: fakeYT(liveInfo()), po: {}, breaker, startPump: () => {}, fetchFn: fakeUpstream().fetch, idleMs: 50, sweepMs: 20 });
  try {
    const r = await j(`${app.base}/open?v=${LIVE}`);
    assert.equal(app.app.sessions.size, 1);
    await sleep(150);
    assert.equal(app.app.sessions.size, 0);
    assert.equal((await fetch(`${app.base}/s/${r.sid}/live.m3u8`)).status, 404);
  } finally { await app.close(); }
});
