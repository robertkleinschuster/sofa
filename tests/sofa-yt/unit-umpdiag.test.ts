// lib/umpdiag.ts: the debug description of a SABR answer (parts in order, pacing policies decoded,
// opaque values by size only), checked on UMP streams built with googlevideo's writer.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mod } from './helpers.ts';

const { describeUmp } = await mod('lib/umpdiag.ts');
const { NextRequestPolicy, StreamProtectionStatus, SabrContextUpdate } = await mod('node_modules/googlevideo/dist/src/exports/protos.js');
const { CompositeBuffer, UmpWriter } = await mod('node_modules/googlevideo/dist/src/exports/ump.js');

function ump(parts: [number, Uint8Array][]): Uint8Array {
  const buf = new CompositeBuffer();
  const w = new UmpWriter(buf);
  for (const [t, d] of parts) w.write(t, d);
  const n = buf.chunks.reduce((a, c) => a + c.length, 0), out = new Uint8Array(n);
  let o = 0;
  for (const c of buf.chunks) { out.set(c, o); o += c.length; }
  return out;
}

test('describeUmp: a media-less answer shows its backoff, protection status and context by size', async () => {
  const s = await describeUmp(ump([
    [52, Uint8Array.of(8, 1)],                                     // REQUEST_IDENTIFIER (no detail)
    [58, StreamProtectionStatus.encode({ status: 1 }).finish()],
    [57, SabrContextUpdate.encode({ type: 5, value: new Uint8Array(40) }).finish()],
    [35, NextRequestPolicy.encode({ backoffTimeMs: 4800, targetVideoReadaheadMs: 15000, playbackCookie: new Uint8Array(12) }).finish()],
  ]));
  assert.equal(s, 'REQUEST_IDENTIFIER, STREAM_PROTECTION_STATUS(status=1), SABR_CONTEXT_UPDATE(type=5 value=40B), '
    + 'NEXT_REQUEST_POLICY(targetVideoReadaheadMs=15000 backoffTimeMs=4800 playbackCookie=12B)');
});

test('describeUmp: runs of media parts collapse, unknown types keep their number', async () => {
  const media = new Uint8Array(100);
  const s = await describeUmp(ump([[20, media], [21, media], [21, media], [21, media], [22, media], [99, media]]));
  assert.equal(s, 'MEDIA_HEADER, MEDIA x3, MEDIA_END, PART_99');
});

test('describeUmp: an empty answer and an undecodable policy are named as such', async () => {
  assert.equal(await describeUmp(new Uint8Array(0)), 'empty');
  assert.equal(await describeUmp(ump([[35, Uint8Array.of(0xff, 0xff)]])), 'NEXT_REQUEST_POLICY(undecodable)');
});
