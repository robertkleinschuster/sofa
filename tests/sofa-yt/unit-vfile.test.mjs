// Sparse virtual file: placement, lookups, contiguity, eviction, waiting.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mod, fixtureInit, patternBuf, segmentTable, sleep } from './helpers.mjs';

const { VirtualFile } = await mod('lib/vfile.mjs');
const { parseIndex } = await mod('lib/mediaindex.mjs');

const INIT = fixtureInit('OzCYsIrrRyw', 248);
const TOTAL = 302146481;
const DUR = 2133920;
const SEGS = segmentTable(parseIndex(INIT, 'video/webm'), TOTAL, DUR);
const mk = () => new VirtualFile({ total: TOTAL, durationMs: DUR, mimeType: 'video/webm; codecs="vp9"' });
const seg = (i) => ({ start: SEGS[i].start, buf: patternBuf(SEGS[i].start, SEGS[i].length), startMs: SEGS[i].startMs, durationMs: SEGS[i].durationMs });

test('add: init parses the index; dup and overlap are rejected', () => {
  const f = mk();
  assert.equal(f.timeAt(TOTAL / 2), Math.floor(DUR / 2)); // proportional before the init arrived
  assert.equal(f.add({ start: 0, buf: INIT, init: true }), 'added');
  assert.equal(f.index.length, 405);
  assert.equal(f.add(seg(3)), 'added');
  assert.equal(f.add(seg(3)), 'dup');
  assert.equal(f.add({ start: SEGS[3].start + 10, buf: Buffer.alloc(20) }), 'overlap');
  assert.equal(f.add({ start: TOTAL - 5, buf: Buffer.alloc(20) }), 'overlap');
  assert.equal(f.add({ start: 5, buf: Buffer.alloc(5), init: true }), 'overlap');
  assert.equal(f.bytes, INIT.length + SEGS[3].length);
});

test('lookups: entryAt, timeAt via index, sliceAt, contiguousFrom', () => {
  const f = mk();
  f.add({ start: 0, buf: INIT, init: true });
  for (const i of [10, 11, 12, 20]) f.add(seg(i));
  assert.equal(f.entryAt(SEGS[11].start + 5).startMs, SEGS[11].startMs);
  assert.ok(f.entryAt(SEGS[13].start) === null);
  assert.equal(f.timeAt(100), 0);                          // inside init
  assert.equal(f.timeAt(SEGS[100].start + 1), SEGS[100].startMs); // not buffered: index
  const c = f.contiguousFrom(SEGS[10].start + 1);
  assert.equal(c.end, SEGS[12].start + SEGS[12].length);
  assert.equal(c.endMs, SEGS[12].startMs + SEGS[12].durationMs);
  assert.equal(c.toEof, false);
  assert.ok(f.contiguousFrom(SEGS[15].start) === null);
  const s = f.sliceAt(SEGS[11].start + 3, SEGS[11].start + 13);
  assert.deepEqual(s, patternBuf(SEGS[11].start + 3, 10));
  assert.equal(f.offsetAtTime(SEGS[50].startMs + 10), SEGS[50].start);
  assert.equal(f.entryAtTime(SEGS[20].startMs + 1).start, SEGS[20].start);
});

test('last segment reaches EOF', () => {
  const f = mk();
  f.add({ start: 0, buf: INIT, init: true });
  const last = SEGS.length - 1;
  f.add(seg(last));
  const c = f.contiguousFrom(SEGS[last].start);
  assert.equal(c.toEof, true);
  assert.equal(c.end, TOTAL);
});

test('evict: behind the read position and by byte cap, never init', () => {
  const f = mk();
  f.add({ start: 0, buf: INIT, init: true });
  for (let i = 0; i < 40; i++) f.add(seg(i));
  const before = f.bytes;
  const freed = f.evict({ keepFromMs: SEGS[20].startMs, readOff: SEGS[25].start, maxBytes: 0 });
  assert.ok(freed > 0);
  assert.equal(f.bytes, before - freed);
  assert.ok(f.init);
  assert.ok(f.entryAt(SEGS[18].start) === null, 'ended before keepFromMs: evicted');
  assert.ok(f.entryAt(SEGS[19].start) !== null, 'ends exactly at keepFromMs: kept');
  assert.ok(f.entryAt(SEGS[20].start) !== null);
  const cap = 8 << 20;
  f.evict({ keepFromMs: 0, readOff: SEGS[25].start, maxBytes: cap });
  assert.ok(f.bytes <= cap, `${f.bytes} <= ${cap}`);
  assert.ok(f.entryAt(SEGS[25].start), 'segment under the reader kept');
  assert.ok(f.init, 'init kept');
});

test('waitFor: resolves on arrival, rejects on timeout, failure and abort', async () => {
  const f = mk();
  f.add({ start: 0, buf: INIT, init: true });
  const p = f.waitFor(SEGS[5].start + 7, 1000);
  setTimeout(() => f.add(seg(5)), 20);
  await p;
  await assert.rejects(f.waitFor(SEGS[6].start, 30), /timeout/);
  const ac = new AbortController();
  const q = f.waitFor(SEGS[6].start, 1000, ac.signal);
  ac.abort();
  await assert.rejects(q, /aborted/);
  const r = f.waitFor(SEGS[7].start, 1000);
  await sleep(5);
  f.setFailed(new Error('SABR 403'));
  await assert.rejects(r, /SABR 403/);
  assert.equal(f.waiters.size, 0, 'no leaked waiters');
});
