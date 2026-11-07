// web/protocol.ts: every engine call passes the page's command check (a missing one was dropped
// unanswered, 2026-11-07: pictures and the lounge got no answer), an unknown one is answered with
// an error at once instead of being dropped, and dispatch runs the call by name. The WebSocket
// upload: JSON text without bytes, the binary container with them (the layout Sofa's
// SFYTChannelDecodeBinary reads, tests/units/websocket.m decodes the same bytes).
import test from 'node:test';
import assert from 'node:assert/strict';
import { METHODS, isCommand, unknownCommand, dispatch, encodeUpload, decodeUpload } from '../../res/sofa-yt/web/protocol.ts';
import type { SofaEngine } from '../../res/sofa-yt/web/engine.ts';

test('the calls Sofa makes pass the page\'s command check', () => {
  for (const m of ['image', 'loungeRequest', 'loungePoll', 'open', 'innertube', 'availability']) {
    assert.ok(isCommand({ id: 1, method: m, args: [] }), m);
    assert.equal(unknownCommand({ id: 1, method: m, args: [] }), null, `${m} is not unknown`);
  }
  assert.ok(!(METHODS as readonly string[]).includes('connect'), 'connect is the page\'s own');
});

test('an unknown call is answered with an error, never dropped', () => {
  assert.deepEqual(unknownCommand({ id: 7, method: 'nope', args: [] }), { id: 7, error: 'unknown engine call: nope' });
  assert.equal(unknownCommand({ method: 'nope' }), null, 'without an id there is nobody to answer');
  assert.equal(unknownCommand('x'), null);
});

test('dispatch runs the call by name and turns a throw into an error answer', async () => {
  const engine = { image: async (u: string) => ({ ok: true, value: u }), stop: () => { throw new Error('boom'); } } as unknown as SofaEngine;
  assert.deepEqual(await dispatch(engine, { id: 1, method: 'image', args: ['u'] }), { id: 1, value: { ok: true, value: 'u' } });
  assert.deepEqual(await dispatch(engine, { id: 2, method: 'stop', args: [] }), { id: 2, error: 'boom' });
});

test('upload without bytes: JSON text', () => {
  const up = { answers: [{ id: 1, value: { ok: true, value: 'x' } }], events: [{ type: 'log', line: 'hi' }] };
  const m = encodeUpload(up as never);
  assert.equal(typeof m, 'string');
  assert.deepEqual(decodeUpload(m), up);
});

test('upload with bytes: binary container, the exact layout Sofa decodes', () => {
  const up = { answers: [{ id: 3, value: { ok: true, value: { mimeType: 'image/jpeg', data: Uint8Array.from([1, 2, 3]) } } }],
    events: [{ type: 'lounge', id: 'p', data: Uint8Array.from([0xff]) }] };
  const m = encodeUpload(up as never) as Uint8Array;
  assert.ok(m instanceof Uint8Array);
  const json = '{"answers":[{"id":3,"value":{"ok":true,"value":{"mimeType":"image/jpeg","data":{"$blob":0}}}}],"events":[{"type":"lounge","id":"p","data":{"$blob":1}}]}';
  const want = Buffer.concat([Buffer.from([0, 0, 0, json.length]), Buffer.from(json), Buffer.from([0, 0, 0, 3, 1, 2, 3]), Buffer.from([0, 0, 0, 1, 0xff])]);
  assert.deepEqual(Buffer.from(m), want);
  assert.deepEqual(decodeUpload(m), up);
  assert.throws(() => decodeUpload(m.subarray(0, m.length - 1)), /truncated/);
});
