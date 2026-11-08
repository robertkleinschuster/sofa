// Sparse virtual file: placement, lookups, contiguity, eviction, waiting.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mod, fixtureInit, must, nth, patternBuf, segmentTable, sleep } from './helpers.ts';

const { VirtualFile } = await mod('lib/vfile.ts');
const { parseIndex } = await mod('lib/mediaindex.ts');

const INIT = fixtureInit('OzCYsIrrRyw', 248);
const TOTAL = 302146481;
const DUR = 2133920;
const SEGS = segmentTable(parseIndex(INIT, 'video/webm'), TOTAL, DUR);
const mk = () => new VirtualFile({ total: TOTAL, durationMs: DUR, mimeType: 'video/webm; codecs="vp9"' });
const S = (i: number) => nth(SEGS, i);
const seg = (i: number) => ({ start: S(i).start, buf: patternBuf(S(i).start, S(i).length), startMs: S(i).startMs, durationMs: S(i).durationMs });

test('add: init parses the index; dup and overlap are rejected', () => {
  const f = mk();
  assert.equal(f.timeAt(TOTAL / 2), Math.floor(DUR / 2)); // proportional before the init arrived
  assert.equal(f.add({ start: 0, buf: INIT, init: true }), 'added');
  assert.equal(f.index?.length, 405);
  assert.equal(f.add(seg(3)), 'added');
  assert.equal(f.add(seg(3)), 'dup');
  assert.equal(f.add({ start: S(3).start + 10, buf: Buffer.alloc(20) }), 'overlap');
  assert.equal(f.add({ start: TOTAL - 5, buf: Buffer.alloc(20) }), 'overlap');
  assert.equal(f.add({ start: 5, buf: Buffer.alloc(5), init: true }), 'overlap');
  assert.equal(f.bytes, INIT.length + S(3).length);
});

test('lookups: entryAt, timeAt via index, sliceAt, contiguousFrom', () => {
  const f = mk();
  f.add({ start: 0, buf: INIT, init: true });
  for (const i of [10, 11, 12, 20]) f.add(seg(i));
  assert.equal(f.entryAt(S(11).start + 5)?.startMs, S(11).startMs);
  assert.ok(f.entryAt(S(13).start) === null);
  assert.equal(f.timeAt(100), 0);                          // inside init
  assert.equal(f.timeAt(S(100).start + 1), S(100).startMs); // not buffered: index
  const c = must(f.contiguousFrom(S(10).start + 1));
  assert.equal(c.end, S(12).start + S(12).length);
  assert.equal(c.endMs, S(12).startMs + S(12).durationMs);
  assert.equal(c.toEof, false);
  assert.ok(f.contiguousFrom(S(15).start) === null);
  const s = f.sliceAt(S(11).start + 3, S(11).start + 13);
  assert.deepEqual(s, patternBuf(S(11).start + 3, 10));
  assert.equal(f.offsetAtTime(S(50).startMs + 10), S(50).start);
  assert.equal(f.entryAtTime(S(20).startMs + 1)?.start, S(20).start);
});

test('known bytes: a WebM track\'s first Cluster ID right after the init region (mpv\'s header parse ends there)', () => {
  const f = mk();
  assert.equal(f.sliceAt(INIT.length, INIT.length + 4), null, 'nothing known before the init segment');
  f.add({ start: 0, buf: INIT, init: true });
  assert.equal(S(0).start, INIT.length, 'the fixture\'s Cues put the first cluster at the init end');
  assert.deepEqual([...must(f.sliceAt(INIT.length, INIT.length + 100))], [0x1f, 0x43, 0xb6, 0x75], 'the Cluster ID, nothing past it');
  assert.deepEqual([...must(f.sliceAt(INIT.length + 2, INIT.length + 100))], [0xb6, 0x75], 'from inside the ID');
  assert.equal(f.sliceAt(INIT.length + 4, INIT.length + 100), null, 'cluster content is not known');
  assert.equal(f.probeEnd, INIT.length + 4);
  assert.equal(f.bytes, INIT.length, 'known bytes are not buffered media (no eviction, no satisfied reads)');
  assert.ok(f.contiguousFrom(INIT.length) === null);
  const real = { ...seg(0), buf: Buffer.concat([Buffer.from([0x1f, 0x43, 0xb6, 0x75]), patternBuf(S(0).start + 4, S(0).length - 4)]) };
  assert.equal(f.add(real), 'added', 'the real first cluster takes over');
  assert.deepEqual(must(f.sliceAt(INIT.length, INIT.length + 8)), real.buf.subarray(0, 8));
  const mp4 = new VirtualFile({ total: 1e9, durationMs: DUR, mimeType: 'video/mp4' });
  mp4.add({ start: 0, buf: fixtureInit('OzCYsIrrRyw', 137), init: true });
  assert.equal(mp4.known, null, 'MP4: nothing known');
});

test('last segment reaches EOF', () => {
  const f = mk();
  f.add({ start: 0, buf: INIT, init: true });
  const last = SEGS.length - 1;
  f.add(seg(last));
  const c = must(f.contiguousFrom(S(last).start));
  assert.equal(c.toEof, true);
  assert.equal(c.end, TOTAL);
});

test('evict: behind the read position and by byte cap, never init', () => {
  const f = mk();
  f.add({ start: 0, buf: INIT, init: true });
  for (let i = 0; i < 40; i++) f.add(seg(i));
  const before = f.bytes;
  const freed = f.evict({ keepFromMs: S(20).startMs, readOff: S(25).start, maxBytes: 0 });
  assert.ok(freed > 0);
  assert.equal(f.bytes, before - freed);
  assert.ok(f.init);
  assert.ok(f.entryAt(S(18).start) === null, 'ended before keepFromMs: evicted');
  assert.ok(f.entryAt(S(19).start) !== null, 'ends exactly at keepFromMs: kept');
  assert.ok(f.entryAt(S(20).start) !== null);
  const cap = 8 << 20;
  f.evict({ keepFromMs: 0, readOff: S(25).start, maxBytes: cap });
  assert.ok(f.bytes <= cap, `${f.bytes} <= ${cap}`);
  assert.ok(f.entryAt(S(25).start), 'segment under the reader kept');
  assert.ok(f.init, 'init kept');
});

test('waitFor: resolves on arrival, rejects on timeout, failure and abort', async () => {
  const f = mk();
  f.add({ start: 0, buf: INIT, init: true });
  const p = f.waitFor(S(5).start + 7, 1000);
  setTimeout(() => f.add(seg(5)), 20);
  await p;
  await assert.rejects(f.waitFor(S(6).start, 30), /timeout/);
  const ac = new AbortController();
  const q = f.waitFor(S(6).start, 1000, ac.signal);
  ac.abort();
  await assert.rejects(q, /aborted/);
  const r = f.waitFor(S(7).start, 1000);
  await sleep(5);
  f.setFailed(new Error('SABR 403'));
  await assert.rejects(r, /SABR 403/);
  assert.equal(f.waiters.size, 0, 'no leaked waiters');
});
