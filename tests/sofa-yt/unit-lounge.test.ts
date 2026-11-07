// lib/lounge.ts: the lounge's requests made by the youtube.com page - only www.youtube.com/api/lounge,
// bodies as bytes; the bind poll streams its chunks in order and ends once (status, or 0 + error when
// cut off or silent too long); a new poll ends the earlier one.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mod } from './helpers.ts';

const { createLounge } = await mod('lib/lounge.ts');

type Ev = { type: string; id: string; data?: Uint8Array; end?: boolean; status?: number; error?: string };
const text = (b: Uint8Array | undefined) => new TextDecoder().decode(b);
const API = 'https://www.youtube.com/api/lounge';

/** A response whose body is fed by hand: push(chunk), end(), fail(reason) - what an aborted fetch does to its body. */
function streamed(status = 200) {
  let ctl!: ReadableStreamDefaultController<Uint8Array>;
  const body = new ReadableStream<Uint8Array>({ start(c) { ctl = c; } });
  return {
    response: new Response(body, { status }),
    push: (s: string) => ctl.enqueue(new TextEncoder().encode(s)),
    end: () => ctl.close(),
    fail: (reason: unknown) => ctl.error(reason),
  };
}

const settle = (ms = 20) => new Promise((r) => setTimeout(r, ms));
const status = (p: Promise<unknown>) => p.then(() => 0, (e: { status?: number }) => e.status ?? -1);

test('lounge request: method, form body, status + bytes; only lounge URLs', async () => {
  const asked: { url: string; method?: string; type?: string; body?: unknown }[] = [];
  const fetchFn = (async (u: URL, init: RequestInit) => {
    asked.push({ url: String(u), method: init.method, type: (init.headers as Record<string, string>)['content-type'], body: init.body });
    return new Response('ÄBC', { status: 200 });
  }) as unknown as typeof fetch;
  const l = createLounge({ fetch: fetchFn, emit: () => {} });
  const r = await l.request('POST', `${API}/pairing/get_lounge_token_batch`, 'screen_ids=x');
  assert.equal(r.status, 200);
  assert.equal(text(r.data), 'ÄBC', 'bytes, UTF-8 intact');
  assert.deepEqual(asked[0], { url: `${API}/pairing/get_lounge_token_batch`, method: 'POST', type: 'application/x-www-form-urlencoded', body: 'screen_ids=x' });
  await l.request('GET', `${API}/pairing/generate_screen_id`, null);
  assert.equal(asked.at(1)?.type, undefined, 'GET without a body type');
  assert.equal(await status(l.request('GET', 'https://www.youtube.com/youtubei/v1/player', null)), 400);
  assert.equal(await status(l.request('GET', 'https://evil.example/api/lounge/x', null)), 400);
  assert.equal(await status(l.request('DELETE', `${API}/x`, null)), 400);
  assert.equal(asked.length, 2, 'refused requests are never sent');
});

test('lounge request: no answer = 502', async () => {
  const l = createLounge({ fetch: (async () => { throw new TypeError('NetworkError'); }) as unknown as typeof fetch, emit: () => {} });
  assert.equal(await status(l.request('GET', `${API}/pairing/generate_screen_id`, null)), 502);
});

test('lounge poll: chunks in order, then one end with the status', async () => {
  const events: Ev[] = [];
  const s = streamed();
  const l = createLounge({ fetch: (async () => s.response) as unknown as typeof fetch, emit: (e: Ev) => events.push(e) });
  l.poll('p1', `${API}/bc/bind?RID=rpc`);
  await settle();
  s.push('12\n[[1,["noop"]]]'); await settle();
  s.push('\n'); await settle();
  s.end(); await settle();
  assert.deepEqual(events.filter((e) => !e.end).map((e) => text(e.data!)), ['12\n[[1,["noop"]]]', '\n']);
  assert.deepEqual(events.at(-1), { type: 'lounge', id: 'p1', end: true, status: 200 });
  assert.equal(events.filter((e) => e.end).length, 1);
});

test('lounge poll: a non-200 status ends at once; silence ends it as cut off', async () => {
  const events: Ev[] = [];
  const l = createLounge({ fetch: (async () => new Response('Unknown SID', { status: 400 })) as unknown as typeof fetch, emit: (e: Ev) => events.push(e) });
  l.poll('p1', `${API}/bc/bind?RID=rpc`);
  await settle();
  assert.equal(events.at(-1)?.status, 400);

  const quiet: Ev[] = [];
  const s = streamed();
  const fetchFn = (async (_u: URL, init: RequestInit) => {
    init.signal?.addEventListener('abort', () => s.fail(init.signal?.reason));
    return s.response;
  }) as unknown as typeof fetch;
  const q = createLounge({ fetch: fetchFn, emit: (e: Ev) => quiet.push(e), silenceMs: 60 });
  q.poll('p2', `${API}/bc/bind?RID=rpc`);
  await settle(200);
  const end = quiet.find((e) => e.end);
  assert.ok(end, 'ended');
  assert.equal(end!.status, 0, 'cut off: not a normal end');
  assert.match(end!.error ?? '', /no bytes/);
});

test('lounge poll: a new poll ends the earlier one; refused URLs throw', async () => {
  const events: Ev[] = [];
  const first = streamed(), second = streamed();
  const responses = [first, second];
  const fetchFn = (async (_u: URL, init: RequestInit) => {
    const s = responses.shift()!;
    init.signal?.addEventListener('abort', () => s.fail(init.signal?.reason));
    return s.response;
  }) as unknown as typeof fetch;
  const l = createLounge({ fetch: fetchFn, emit: (e: Ev) => events.push(e) });
  l.poll('old', `${API}/bc/bind?RID=rpc`);
  await settle();
  l.poll('new', `${API}/bc/bind?RID=rpc`);
  await settle();
  const oldEnd = events.find((e) => e.id === 'old' && e.end);
  assert.ok(oldEnd && oldEnd.status === 0, 'the earlier poll ended (cut off)');
  second.push('x'); await settle();
  assert.equal(events.filter((e) => e.id === 'new' && !e.end).length, 1, 'the new one streams');
  l.stop(); await settle();
  assert.ok(events.find((e) => e.id === 'new' && e.end), 'stop ends it');
  assert.throws(() => l.poll('bad', 'https://www.youtube.com/watch?v=x'), (e: { status?: number }) => e.status === 400);
});
