// web/protocol.ts: every engine call passes the page's command check (a missing one was dropped
// unanswered, 2026-11-07: pictures and the lounge got no answer), an unknown one is answered with
// an error at once instead of being dropped, and dispatch runs the call by name.
import test from 'node:test';
import assert from 'node:assert/strict';
import { METHODS, isCommand, unknownCommand, dispatch } from '../../res/sofa-yt/web/protocol.ts';
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
