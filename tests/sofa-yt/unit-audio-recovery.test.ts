// Missing audio must recover independently of a combined SABR run's video progress.
// Real track indices, deterministic time and pump callbacks; no network or running Sofa.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mod, fixtureInfo, fixtureInit, segmentTable, must, FakeRes } from './helpers.ts';
import type { PumpRequest, Reader, TrackKind } from '../../res/sofa-yt/lib/session.ts';

const { PlaybackSession } = await mod('lib/session.ts');
const { describeFormats, pickVideo, pickAudio } = await mod('lib/formats.ts');
const { parseIndex } = await mod('lib/mediaindex.ts');
const info = fixtureInfo('OzCYsIrrRyw');
const formats = describeFormats(info.formats);
const video = must(pickVideo(formats)), audio = must(pickAudio(formats));
const vi = fixtureInit(info.id, video.itag), ai = fixtureInit(info.id, audio.itag);
const vs = segmentTable(parseIndex(vi, video.mimeType), video.contentLength, info.durationMs);
const as = segmentTable(parseIndex(ai, audio.mimeType), audio.contentLength, info.durationMs);
const V = (n: number) => must(vs[n]);
const A = (n: number) => must(as[n]);

function scenario() {
  const calls: PumpRequest[] = [];
  let aborts = 0;
  const s = new PlaybackSession({ info, formats, video, audio, cfg: { AUDIO_STALL_MS: 8000 },
    startPump: (r) => { calls.push(r); return { abort() { aborts++; } }; } });
  const p = must(s.startPump(s.video, 0, Date.now()));
  const emit = (run: number, kind: TrackKind, n: number) => {
    const seg = kind === 'video' ? V(n) : A(n);
    must(calls[run]).onSegment(kind, { start: seg.start, buf: new Uint8Array(seg.length),
      startMs: seg.startMs, durationMs: seg.durationMs, init: false });
  };
  calls[0]!.onSegment('video', { start: 0, buf: vi, startMs: 0, durationMs: 0, init: true });
  calls[0]!.onSegment('audio', { start: 0, buf: ai, startMs: 0, durationMs: 0, init: true });
  for (let n = 0; n < 5; n++) emit(0, 'video', n);
  for (let n = 0; n < 2; n++) emit(0, 'audio', n);
  const vr: Reader = { pos: V(5).start, since: Date.now(), movedAt: Date.now() };
  const ar: Reader = { pos: A(2).start, since: Date.now(), movedAt: Date.now() };
  s.video.readers.add(vr); s.mainAudio.readers.add(ar);
  return { s, p, calls, emit, vr, ar, aborts: () => aborts };
}

test('missing audio starts one dedicated recovery while video advances, and serves the waiting bytes', async (t) => {
  let now = 100000;
  t.mock.method(Date, 'now', () => now);
  const { s, p, calls, emit, ar } = scenario();
  // An actual serve() reader, to check recovery reaches the HTTP consumer, not just the scheduler.
  s.mainAudio.readers.delete(ar);
  const res = new FakeRes();
  const read = s.serve(s.mainAudio, A(2).start, A(2).start + A(2).length, res);
  try {
    now += s.cfg.AUDIO_STALL_MS - 1;
    emit(0, 'video', 5); s.schedule();
    assert.equal(calls.length, 1, 'normal first-segment grace');
    now++;
    s.schedule();
    assert.equal(calls.length, 2, 'audio recovers before the 25 s HTTP deadline');
    assert.equal(calls[1]!.video, null, 'audio only');
    assert.equal(calls[1]!.startMs, A(2).startMs, 'starts at the missing segment');
    assert.equal(p.alive, true, 'video run kept');
    for (let i = 0; i < 6; i++) { now += 1000; s.schedule(); }
    assert.equal(calls.length, 2, 'same recovery retained, no pump storm');
    emit(1, 'audio', 2);
    assert.equal(await read, A(2).length, 'waiting HTTP read receives the missing bytes');
    assert.equal(res.bytes, A(2).length);
  } finally { res.emit('close'); s.close('test'); await read; }
});

test('fresh seek or language reader gets its own grace even when the video run is old', (t) => {
  let now = 100000; t.mock.method(Date, 'now', () => now);
  const { s, calls, ar, emit } = scenario();
  try {
    now += 12000; ar.since = ar.movedAt = now;
    emit(0, 'video', 5); s.schedule();
    assert.equal(calls.length, 1, 'new audio demand does not immediately duplicate the combined run');
    now += s.cfg.AUDIO_STALL_MS; s.schedule();
    assert.equal(calls.length, 2, 'recovers if the fresh request then stops progressing');
  } finally { s.close('test'); }
});

test('audio progress resets its grace; fresh video and duplicate audio do not', (t) => {
  let now = 100000; t.mock.method(Date, 'now', () => now);
  const { s, calls, ar, emit } = scenario();
  try {
    now += 7000; emit(0, 'audio', 2); ar.pos = A(3).start; ar.movedAt = now;
    now += 7000; emit(0, 'video', 5); emit(0, 'audio', 2); s.schedule();
    assert.equal(calls.length, 1, 'advancing audio grants grace');
    now += 1000; s.schedule();
    assert.equal(calls.length, 2, 'duplicate segment did not postpone recovery');
    assert.equal(calls[1]!.startMs, A(3).startMs);
  } finally { s.close('test'); }
});

test('a buffered audio reader does not start rescue, nor do hints or a disconnected reader', (t) => {
  let now = 100000; t.mock.method(Date, 'now', () => now);
  const { s, calls, ar, emit } = scenario();
  try {
    ar.pos = A(0).start;
    now += 12000; emit(0, 'video', 5); s.schedule();
    assert.equal(calls.length, 1, 'buffered audio waits on the combined run');
    s.mainAudio.readers.delete(ar);
    s.mainAudio.hint = { ms: A(2).startMs, until: now + 60000 };
    s.schedule();
    assert.equal(calls.length, 1, 'prefetch hint never triggers audio rescue');
    s.mainAudio.hint = null;
    s.mainAudio.lastPos = A(2).start; s.mainAudio.lastReadAt = now;
    s.schedule();
    assert.equal(calls.length, 1, 'lingering disconnected read never triggers rescue');
  } finally { s.close('test'); }
});

test('late original audio satisfies the reader and an unneeded rescue is stopped', (t) => {
  let now = 100000; t.mock.method(Date, 'now', () => now);
  const { s, calls, emit, ar, aborts } = scenario();
  try {
    now += 8000; emit(0, 'video', 5); s.schedule();
    assert.equal(calls.length, 2);
    emit(0, 'audio', 2);
    s.mainAudio.readers.delete(ar);
    now += s.cfg.GRACE_MS + 1; s.schedule();
    assert.equal(aborts(), 1, 'recovery stopped once nobody needs it');
    assert.equal(s.pumps.size, 1, 'video continues');
  } finally { s.close('test'); }
});

test('audio-only arrivals cannot mask a video stall and duplicates cannot mask either track', (t) => {
  let now = 100000; t.mock.method(Date, 'now', () => now);
  const { s, p, emit } = scenario();
  try {
    now += s.cfg.STALL_MS + 1;
    emit(0, 'audio', 2); emit(0, 'video', 4);
    s.schedule();
    assert.equal(p.alive, false, 'combined run with stuck video restarted despite fresh audio');
  } finally { s.close('test'); }
});

test('recovery honors start throttle, backoff and existing concurrency cap', (t) => {
  let now = 100000; t.mock.method(Date, 'now', () => now);
  const { s, calls, emit } = scenario();
  try {
    now += 8000; emit(0, 'video', 5);
    s.backoffUntil = now + 1000; s.schedule();
    assert.equal(calls.length, 1, 'no recovery into a backoff');
    now += 1000; s.starts = Array(s.cfg.START_BURST).fill(now); s.schedule();
    assert.equal(calls.length, 1, 'start rate limit retained');
    s.starts = []; s.schedule();
    assert.equal(calls.length, 2);
    assert.ok(s.pumps.size <= s.cfg.MAX_PUMPS);
    for (let i = 0; i < 10; i++) s.schedule();
    assert.equal(calls.length, 2, 'one recovery at a time');
  } finally { s.close('test'); }
});
