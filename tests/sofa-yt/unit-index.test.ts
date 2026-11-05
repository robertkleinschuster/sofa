// Byte offset -> media time: WebM Cues and MP4 sidx from real SABR init segments.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mod, fixtureInit, must, nth } from './helpers.ts';
import type { SegmentSpec } from './helpers.ts';

const { parseIndex, indexLookup } = await mod('lib/mediaindex.ts');

test('WebM Cues (itag 248, real init segment incl. index)', () => {
  const ix = must(parseIndex(fixtureInit('OzCYsIrrRyw', 248), 'video/webm; codecs="vp9"'));
  assert.equal(ix.length, 405);
  // offsets verified against cluster IDs in the spike's byte-identical SABR output
  assert.deepEqual(ix.slice(0, 3), [{ off: 7481, ms: 0 }, { off: 595246, ms: 6000 }, { off: 1412671, ms: 12000 }]);
  assert.equal(nth(ix, -1).ms, 2130000);
  assert.ok(nth(ix, -1).off < 302146481);
});

test('WebM Cues audio (itag 251)', () => {
  const ix = must(parseIndex(fixtureInit('OzCYsIrrRyw', 251), 'audio/webm; codecs="opus"'));
  assert.equal(ix.length, 214);
  assert.deepEqual(ix.slice(0, 2), [{ off: 3994, ms: 0 }, { off: 196899, ms: 10001 }]);
});

test('MP4 sidx (avc1 137, aac 140, short video 133)', () => {
  const v = must(parseIndex(fixtureInit('OzCYsIrrRyw', 137), 'video/mp4; codecs="avc1.640028"'));
  assert.equal(v.length, 405);
  assert.deepEqual(v.slice(0, 2), [{ off: 5634, ms: 0 }, { off: 765528, ms: 6000 }]);
  const a = must(parseIndex(fixtureInit('OzCYsIrrRyw', 140), 'audio/mp4; codecs="mp4a.40.2"'));
  assert.equal(a.length, 214);
  assert.equal(nth(a, 0).off, 3323);
  const s = parseIndex(fixtureInit('jNQXAC9IVRw', 133), 'video/mp4');
  assert.deepEqual(s, [{ off: 807, ms: 0 }, { off: 124098, ms: 5400 }, { off: 256607, ms: 11200 }]);
});

test('truncated / foreign data yields null, never throws', () => {
  const init = fixtureInit('OzCYsIrrRyw', 248);
  assert.equal(parseIndex(init.subarray(0, 300), 'video/webm'), null);
  assert.equal(parseIndex(Buffer.alloc(64), 'video/mp4'), null);
  assert.equal(parseIndex(Buffer.from('garbage'), 'video/webm'), null);
});

test('indexLookup: greatest entry <= offset', () => {
  const ix = [{ off: 100, ms: 0 }, { off: 500, ms: 5000 }, { off: 900, ms: 10000 }];
  assert.equal(indexLookup(ix, 50), null);
  assert.equal(indexLookup(ix, 100)?.ms, 0);
  assert.equal(indexLookup(ix, 899)?.ms, 5000);
  assert.equal(indexLookup(ix, 10 ** 9)?.ms, 10000);
});

test('real SABR segments (recorded MediaHeaders) coincide with the Cues of the init segment', async () => {
  const fs = await import('node:fs');
  const { FIX } = await import('./helpers.ts');
  const rec = JSON.parse(fs.readFileSync(`${FIX}/OzCYsIrrRyw-sabr-segments.json`, 'utf8')) as Record<'video' | 'audio', SegmentSpec[]>;
  for (const [kind, itag] of [['video', 248], ['audio', 251]] as const) {
    const ix = must(parseIndex(fixtureInit('OzCYsIrrRyw', itag), 'x/webm'));
    assert.ok(rec[kind].length > 5);
    for (const s of rec[kind]) {
      const i = ix.findIndex((e) => e.off === s.start);
      assert.ok(i >= 0, `${kind} segment at ${s.start} starts on a cue`);
      const cue = nth(ix, i), next = ix[i + 1];
      assert.equal(cue.ms, s.startMs, 'same start time');
      if (next) {
        assert.equal(next.off - cue.off, s.length, 'segment = cue span');
        assert.equal(next.ms - cue.ms, s.durationMs);
      }
    }
  }
});
