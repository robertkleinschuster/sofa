// Playback sessions over HTTP with a deterministic fake SABR pump (no network):
// Range semantics, seek -> SABR restart without player request, pacing, eviction, language switch,
// failure handling, expiry, breaker.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {
  mod, fixtureInit, fixtureInfo, segmentTable, expectedBytes, fakePumps, fakeYouTube, startApp, get, sleep, until,
  xtags, FakeRes,
} from './helpers.mjs';

const { parseIndex } = await mod('lib/mediaindex.mjs');
const { PlaybackSession } = await mod('lib/session.mjs');
const { describeFormats, pickVideo, pickAudio, audioTracks } = await mod('lib/formats.mjs');
const { Breaker } = await mod('lib/breaker.mjs');

const ID = 'OzCYsIrrRyw';
const VINIT = fixtureInit(ID, 248);
const AINIT = fixtureInit(ID, 251);
const base = fixtureInfo(ID);
const v248 = base.formats.find((f) => f.itag === 248);
const a251 = base.formats.find((f) => f.itag === 251 && !f.xtags);
const VSEGS = segmentTable(parseIndex(VINIT, 'video/webm'), Number(v248.contentLength), base.durationMs);
const ASEGS = segmentTable(parseIndex(AINIT, 'audio/webm'), Number(a251.contentLength), base.durationMs);

// two audio languages: German original (main) and a French dub, same media bytes
const info = {
  ...base,
  formats: [
    ...base.formats.filter((f) => !f.mimeType.startsWith('audio/')), // multi-language responses tag every audio format
    { ...a251, xtags: await xtags({ acont: 'original', lang: 'de' }), audioTrack: { id: 'de.4', displayName: 'Deutsch original', audioIsDefault: true } },
    { ...a251, xtags: await xtags({ acont: 'dubbed', lang: 'fr' }), audioTrack: { id: 'fr.3', displayName: 'French', audioIsDefault: false } },
  ],
};
const MEDIA = {
  248: { init: VINIT, segs: VSEGS },
  '251-de.4': { init: AINIT, segs: ASEGS },
  '251-fr.3': { init: AINIT, segs: ASEGS },
};
const CFG = {
  LOW_MS: 12000, HIGH_MS: 30000, KEEP_BEHIND_MS: 6000, COVER_SLACK_MS: 12000, GRACE_MS: 100, LINGER_MS: 300,
  HINT_TTL_MS: 2000, WAIT_MS: 1500, TICK_MS: 30, HIGH_BYTES: { video: 1 << 30, audio: 1 << 30 },
  MAX_BYTES: { video: 64 << 20, audio: 8 << 20 },
};

async function setup({ fail = null, stall = false, cfg = {}, infos = { [ID]: info }, breaker = new Breaker(null), appOpts = {} } = {}) {
  const pumps = fakePumps(MEDIA, { fail, stall });
  const youtube = fakeYouTube(infos, { breaker });
  const po = { state: 'ready', mintString: async () => 'tok' };
  const app = await startApp({ youtube, po, breaker, startPump: pumps.start, sessionCfg: { ...CFG, ...cfg }, ...appOpts });
  return { pumps, youtube, app, breaker };
}

const openJson = async (app, q) => (await get(`${app.base}/open?${q}`)).body.toString();

test('/open: dash-shaped answer with local URLs; reopen reuses the session, no second player request', async () => {
  const { app, youtube } = await setup();
  try {
    const r = JSON.parse(await openJson(app, `v=${ID}&prefetch=0`));
    assert.equal(r.id, ID);
    assert.equal(r.live, false);
    assert.equal(r.duration, 2134);
    assert.equal(r.height, 1080);
    assert.equal(r.vcodec, 'vp9');
    assert.equal(r.acodec, 'opus');
    assert.equal(r.alang, 'de');
    assert.equal(r.vitag, 248);
    assert.match(r.video, new RegExp(`^${app.base}/s/[0-9a-f]{16}/video$`));
    assert.equal(r.audio, `${app.base}/s/${r.sid}/audio/251-de.4`);
    assert.deepEqual(r.audios.map((a) => [a.lang, a.original, a.dubbed]), [['de', true, false], ['fr', false, true]]);
    assert.equal(r.audios[0].url, r.audio, 'original track URL == main audio URL');
    assert.deepEqual(r.subs.map((s) => [s.lang, s.kind]), [['de', 'auto']]);
    assert.match(r.subs[0].url, /\/subs\/a-de\.vtt$/);
    assert.equal(r.cached, false);
    const again = JSON.parse(await openJson(app, `v=${ID}`));
    assert.equal(again.sid, r.sid);
    assert.equal(again.cached, true);
    assert.equal(youtube.requests, 1);
    const head = await fetch(r.video, { method: 'HEAD' });
    assert.equal(head.status, 200);
    assert.equal(head.headers.get('content-length'), String(v248.contentLength));
    assert.equal(head.headers.get('accept-ranges'), 'bytes');
    assert.equal((await get(`${app.base}/s/${r.sid}/video`, { range: `bytes=${v248.contentLength}-` })).status, 416);
    assert.equal((await get(`${app.base}/s/nope/video`)).status, 404);
    assert.equal(JSON.parse(await openJson(app, 'v=bad')).error, 'invalid video ID');
  } finally { await app.close(); }
});

test('sequential read from 0 and a seek: correct bytes at the right offsets, seek restarts SABR (no player request)', async () => {
  const { app, youtube, pumps } = await setup();
  try {
    const r = JSON.parse(await openJson(app, `v=${ID}&prefetch=0`));
    const a = await get(r.video, { range: 'bytes=0-2999999' });
    assert.equal(a.status, 206);
    assert.equal(a.headers.get('content-range'), `bytes 0-2999999/${v248.contentLength}`);
    assert.ok(a.body.equals(expectedBytes(VINIT, 0, 3000000)), 'prefix bytes identical (init + segments)');
    assert.equal(pumps.log.starts[0].startMs, 0);
    assert.equal(pumps.log.starts[0].video, '248');
    assert.equal(pumps.log.starts[0].audio, '251-de.4');
    const seekOff = VSEGS[100].start + 12345;
    const b = await get(r.video, { range: `bytes=${seekOff}-${seekOff + 999999}` });
    assert.equal(b.status, 206);
    assert.ok(b.body.equals(expectedBytes(VINIT, seekOff, seekOff + 1000000)), 'seek bytes identical');
    assert.ok(pumps.log.starts.some((s) => s.startMs === VSEGS[100].startMs && s.video === '248'), 'SABR restarted at the cue time');
    // audio follows the seek through the video pump (no separate audio-only run needed)
    const aOff = ASEGS.find((s) => s.startMs >= VSEGS[100].startMs).start;
    const c = await get(r.audio, { range: `bytes=${aOff}-${aOff + 99999}` });
    assert.ok(c.body.equals(expectedBytes(AINIT, aOff, aOff + 100000)));
    assert.equal(youtube.requests, 1, 'seeking never costs a player request');
    // suffix range (some demuxers probe the end): served from the restarted tail
    const t = await get(r.video, { range: 'bytes=-1000' });
    assert.equal(t.status, 206);
    assert.ok(t.body.equals(expectedBytes(VINIT, v248.contentLength - 1000, v248.contentLength)));
  } finally { await app.close(); }
});

test('pacing: pull pauses ~HIGH ahead of a stalled reader, resumes below LOW; memory behind is evicted', async () => {
  const pumps = fakePumps(MEDIA);
  const formats = describeFormats(info.formats);
  const s = new PlaybackSession({ info, formats, video: pickVideo(formats), audio: pickAudio(formats),
    audioChoices: audioTracks(formats).map((t) => t.format), startPump: (o) => pumps.start(info, formats, o), cfg: CFG });
  const res = new FakeRes();
  res.limit = VSEGS[3].start; // consumer stalls (mpv paused / cache full) at ~18 s
  const done = s.serve(s.video, 0, s.video.file.total, res);
  try {
    assert.ok(await until(() => res.blocked && pumps.log.live === 0, 5000), 'pump stopped while the reader is stalled');
    const readerMs = s.video.file.timeAt(res.bytes);
    const ahead = s.video.file.contiguousFrom(res.bytes).endMs - readerMs;
    assert.ok(ahead >= CFG.HIGH_MS, `buffered ahead ${ahead} >= HIGH`);
    assert.ok(ahead <= CFG.HIGH_MS + 3 * 6000, `buffered ahead ${ahead} bounded`);
    const emitted = pumps.log.emitted;
    await sleep(300);
    assert.equal(pumps.log.emitted, emitted, 'no pulling while paused');
    const starts = pumps.log.starts.length;
    // reader consumes until less than LOW is left -> a new run starts at the end of the buffer
    const endMs = s.video.file.contiguousFrom(res.bytes).endMs;
    const target = VSEGS.find((x) => x.startMs >= endMs - CFG.LOW_MS + 2000);
    res.allow(target.start + 10);
    assert.ok(await until(() => pumps.log.starts.length > starts, 3000), 'pull resumed');
    const resumed = pumps.log.starts.at(-1);
    assert.equal(resumed.startMs, endMs, 'resumed exactly at the buffered end');
    // eviction: nothing far behind the reader is held
    await until(() => res.blocked && pumps.log.live === 0, 5000);
    const rMs = s.video.file.timeAt(res.bytes);
    for (const e of s.video.file.entries) {
      if (!e.init) assert.ok(e.endMs >= rMs - CFG.KEEP_BEHIND_MS, `entry ${e.startMs}-${e.endMs} evicted (reader at ${rMs})`);
    }
    assert.ok(s.video.file.init, 'init kept');
  } finally {
    s.close('test');
    res.destroy();
    await done;
  }
});

test('language switch: another audio track is fed by an audio-only SABR run', async () => {
  const { app, pumps } = await setup();
  try {
    const r = JSON.parse(await openJson(app, `v=${ID}&prefetch=0`));
    await get(r.video, { range: 'bytes=0-999999' });
    const fr = r.audios.find((a) => a.lang === 'fr');
    const off = ASEGS[30].start;
    const b = await get(fr.url, { range: `bytes=${off}-${off + 199999}` });
    assert.equal(b.status, 206);
    assert.ok(b.body.equals(expectedBytes(AINIT, off, off + 200000)));
    assert.ok(pumps.log.starts.some((x) => x.video === null && x.audio === '251-fr.3' && x.startMs === ASEGS[30].startMs));
    // the next video run carries the language read most recently
    const vo = VSEGS[200].start;
    await get(r.video, { range: `bytes=${vo}-${vo + 99999}` });
    assert.equal(pumps.log.starts.at(-1).audio, '251-fr.3');
  } finally { await app.close(); }
});

test('SABR failures: bounded attempts, then 503 instead of retrying against YouTube', async () => {
  const { app, pumps } = await setup({ fail: 'Server returned 403' });
  try {
    const r = JSON.parse(await openJson(app, `v=${ID}&prefetch=0`));
    const a = await get(r.video, { range: 'bytes=0-' }).catch((e) => ({ error: e }));
    assert.ok(a.error || a.body.length < 1000, 'response ended early');
    assert.ok(await until(async () => (await get(r.video, { range: 'bytes=0-' }).catch(() => ({ status: 0 }))).status === 503, 15000));
    const n = pumps.log.starts.length;
    assert.ok(n <= 3, `at most MAX_FAILURES runs (${n})`);
    await sleep(300);
    assert.equal(pumps.log.starts.length, n, 'no further attempts');
    const st = JSON.parse((await get(`${app.base}/s/${r.sid}/status`)).body);
    assert.match(st.failed, /403/);
    // a failed session is not reused: a new /open creates a fresh one (cached player response)
    const r2 = JSON.parse(await openJson(app, `v=${ID}&prefetch=0`));
    assert.notEqual(r2.sid, r.sid);
  } finally { await app.close(); }
});

test('seek storm: pump starts are rate limited', async () => {
  const { app, pumps } = await setup({ cfg: { START_BURST: 5, WAIT_MS: 200 } });
  try {
    const r = JSON.parse(await openJson(app, `v=${ID}&prefetch=0`));
    await get(r.video, { range: 'bytes=0-99999' });
    await Promise.all(Array.from({ length: 15 }, (_, i) => {
      const off = VSEGS[20 + i * 20].start;
      return get(r.video, { range: `bytes=${off}-${off + 9999}` }).catch(() => null);
    }));
    assert.ok(pumps.log.starts.length <= 5, `starts ${pumps.log.starts.length} <= burst`);
    assert.ok(pumps.log.live <= 3, 'concurrent runs capped');
  } finally { await app.close(); }
});

test('prefetch hint: /open starts pulling at the resume position before mpv connects', async () => {
  const { app, pumps } = await setup();
  try {
    const r = JSON.parse(await openJson(app, `v=${ID}&start=600`));
    assert.ok(await until(() => pumps.log.starts.length > 0));
    assert.equal(pumps.log.starts[0].startMs, 600000);
    // header read is served from the hinted run (every run begins with the init segment)
    const h = await get(r.video, { range: `bytes=0-${VINIT.length - 1}` });
    assert.ok(h.body.equals(VINIT));
    assert.equal(pumps.log.starts.length, 1, 'no extra run for the header');
    const off = VSEGS.find((x) => x.startMs <= 600000 && 600000 < x.startMs + x.durationMs).start;
    const b = await get(r.video, { range: `bytes=${off}-${off + 99999}` });
    assert.ok(b.body.equals(expectedBytes(VINIT, off, off + 100000)));
    assert.equal(pumps.log.starts.length, 1, 'resume position served by the prefetch run');
  } finally { await app.close(); }
});

test('idle sessions expire; /close frees a session', async () => {
  const { app, pumps } = await setup({ appOpts: { idleMs: 150, sweepMs: 50 } });
  try {
    const r = JSON.parse(await openJson(app, `v=${ID}&prefetch=0`));
    await get(r.video, { range: 'bytes=0-99999' });
    assert.ok(await until(async () => (await get(`${app.base}/s/${r.sid}/status`)).status === 404, 3000), 'expired');
    assert.ok(await until(() => pumps.log.live === 0, 2000), 'its pumps were stopped');
    const r2 = JSON.parse(await openJson(app, `v=${ID}&prefetch=0`));
    assert.equal(JSON.parse((await get(`${app.base}/close?sid=${r2.sid}`)).body).closed, true);
    assert.equal((await get(r2.video)).status, 404);
  } finally { await app.close(); }
});

test('breaker: bg=1 sends nothing while blocked; bot answers open it; live is refused', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sofa-yt-test-'));
  const file = path.join(dir, 'youtube-block.json');
  const breaker = new Breaker(file);
  const { app, youtube } = await setup({ breaker, infos: { [ID]: info, jNQXAC9IVRw: 'bot', aaaaaaaaaaa: 'live' } });
  try {
    const bot = JSON.parse(await openJson(app, 'v=jNQXAC9IVRw'));
    assert.equal(bot.bot, true);
    assert.ok(bot.blocked_until > Date.now() / 1000 + 200, 'breaker opened (5 min)');
    assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')).backoff, 300, 'same file format as ytresolver.py');
    const before = youtube.requests;
    const bg = JSON.parse(await openJson(app, `v=${ID}&bg=1`));
    assert.equal(bg.bot, true);
    assert.equal(youtube.requests, before, 'no request while blocked');
    const fg = JSON.parse(await openJson(app, `v=${ID}`));
    assert.ok(fg.sid, 'user playback still tries');
    const live = JSON.parse(await openJson(app, 'v=aaaaaaaaaaa'));
    assert.deepEqual([live.error, live.live], ['live', true]);
    breaker.note(false);
    assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')), { until: 0, backoff: 0 });
  } finally { await app.close(); fs.rmSync(dir, { recursive: true, force: true }); }
});

test('resume hint survives mpv probing the first cluster, is consumed at the resume position', async () => {
  const formats = describeFormats(info.formats);
  const s = new PlaybackSession({ info, formats, video: pickVideo(formats), audio: pickAudio(formats),
    startPump: () => ({ abort() {} }), cfg: CFG });
  try {
    s.video.file.add({ start: 0, buf: VINIT, init: true });
    s.hint(60000);
    const probe = { pos: VSEGS[0].start + 100 };
    s.video.readers.add(probe);
    assert.ok(s.video.demands(Date.now()).some((d) => d.off === null && d.ms === 60000), 'probe at 0 keeps the hint');
    s.video.readers.delete(probe);
    s.video.readers.add({ pos: VSEGS[10].start + 5 }); // 60 s
    s.video.demands(Date.now());
    assert.equal(s.video.hint, null, 'consumed by the reader at the resume position');
  } finally { s.close('test'); }
});

test('stalled SABR runs are restarted by the watchdog, then the session fails', async () => {
  const { app, pumps } = await setup({ stall: true, cfg: { STALL_MS: 200, WAIT_MS: 400 } });
  try {
    const r = JSON.parse(await openJson(app, `v=${ID}&prefetch=0`));
    assert.ok(await until(async () => (await get(r.video, { range: 'bytes=0-' }).catch(() => ({ status: 0 }))).status === 503, 15000));
    assert.equal(pumps.log.starts.length, 3, 'three attempts, no more');
    assert.equal(pumps.log.live, 0, 'stalled runs were aborted');
  } finally { await app.close(); }
});

test('session limit: a session in use is never evicted, a never-read preload goes first', async () => {
  const { app } = await setup({ appOpts: { maxSessions: 2 } });
  try {
    const a = JSON.parse(await openJson(app, `v=${ID}&prefetch=0&maxHeight=1080`));
    assert.equal((await get(a.video, { range: 'bytes=0-999' })).status, 206);   // A is being played
    const b = JSON.parse(await openJson(app, `v=${ID}&prefetch=0&maxHeight=720`));   // preload, never read
    const c = JSON.parse(await openJson(app, `v=${ID}&prefetch=0&maxHeight=480`));
    assert.notEqual(c.sid, a.sid);
    assert.equal((await get(a.video, { range: 'bytes=0-999' })).status, 206, 'playing session survives');
    assert.equal((await get(b.video, { range: 'bytes=0-999' }).catch(() => ({ status: 0 }))).status, 404, 'preload evicted');
  } finally { await app.close(); }
});
