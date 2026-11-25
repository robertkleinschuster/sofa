// lib/sabrpump.ts SabrContinuity: the runs of one playback are one SABR client, as youtube.com's
// player is (2026-11-25: every run's first answer was a CONTENT_ADS context + 4000 ms backoff, which
// the web player pays once per playback). Driven through the real googlevideo SabrStream (pinned
// version) against a stubbed fetch: what the next run's FIRST request carries.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mod, fixtureInfo, fixturePlayer, until } from './helpers.ts';
import type { AbrRequestView } from './helpers.ts';

const { startSabrPump, SabrContinuity } = await mod('lib/sabrpump.ts');
const F = await mod('lib/formats.ts');
const { NextRequestPolicy, SabrContextUpdate, VideoPlaybackAbrRequest } = await mod('node_modules/googlevideo/dist/src/exports/protos.js');
const { CompositeBuffer, UmpWriter } = await mod('node_modules/googlevideo/dist/src/exports/ump.js');

function ump(parts: [number, Uint8Array][]): Uint8Array<ArrayBuffer> {
  const buf = new CompositeBuffer();
  const w = new UmpWriter(buf);
  for (const [t, d] of parts) w.write(t, d);
  const n = buf.chunks.reduce((a, c) => a + c.length, 0), out = new Uint8Array(new ArrayBuffer(n));
  let o = 0;
  for (const c of buf.chunks) { out.set(c, o); o += c.length; }
  return out;
}

const CTX = Uint8Array.from({ length: 82 }, (_, i) => i);
const COOKIE = Uint8Array.of(9, 8, 7, 6);
// the server as observed: a request without the CONTENT_ADS context gets it, with a 4000 ms backoff;
// one carrying it gets no backoff (media is not needed here - only what the client sends)
interface Seen { rn: number; req: AbrRequestView }
const seen: Seen[] = [];
const realFetch = globalThis.fetch;
globalThis.fetch = (async (input: RequestInfo | URL, init?: RequestInit) => {
  const req = VideoPlaybackAbrRequest.decode(new Uint8Array(init?.body as ArrayBuffer));
  seen.push({ rn: Number(new URL(String(input)).searchParams.get('rn')), req });
  const has = req.streamerContext?.sabrContexts.some((c) => c.type === 5);
  const body = has
    ? ump([[35, NextRequestPolicy.encode({ playbackCookie: COOKIE }).finish()]])
    : ump([[57, SabrContextUpdate.encode({ type: 5, scope: 4, value: CTX, sendByDefault: true, writePolicy: 2 }).finish()],
      [35, NextRequestPolicy.encode({ backoffTimeMs: 4000 }).finish()]]);
  await new Promise((r) => setTimeout(r, 5));
  return new Response(body, { status: 200, headers: { 'content-type': 'application/vnd.yt-ump' } });
}) as typeof fetch;
test.after(() => { globalThis.fetch = realFetch; });

const info = fixtureInfo('OzCYsIrrRyw');
const formats = F.describeFormats(fixturePlayer('OzCYsIrrRyw').adaptiveFormats);
const video = F.pickVideo(formats), audio = F.pickAudio(formats);

/** One run until it sent `requests` requests (or, with backoff, its first only), then aborted. */
async function run(continuity: InstanceType<typeof SabrContinuity>, cpn: string, requests: number): Promise<Seen[]> {
  const from = seen.length;
  let ended = false;
  const h = startSabrPump({
    info, formats, cpn, video, audio: audio!, startMs: 60000, continuity,
    mintPoToken: async () => new Uint8Array(0), reload: () => Promise.reject(new Error('no reload in this test')),
    onSegment() {}, onEnd() { ended = true; },
  });
  assert.ok(await until(() => seen.length - from >= requests, 9000), `run sent ${seen.length - from} of ${requests} requests`);
  h.abort();
  await until(() => ended, 2000);
  await new Promise((r) => setTimeout(r, 20));   // googlevideo disposes after its loop ends
  return seen.slice(from);
}

test('the next run of a playback continues its SABR client: context, cookie, request number - no new backoff', { timeout: 30000 }, async () => {
  const c = new SabrContinuity();
  const first = await run(c, 'cpnA', 3);   // answer 1 orders the 4 s backoff, request 2 carries the context, answer 2 the cookie
  assert.ok(!first[0]!.req.streamerContext?.sabrContexts.length, 'a playback\'s first request has no context yet');
  assert.ok(first[1]!.req.streamerContext?.sabrContexts.some((x) => x.type === 5), 'request 2 sends the context back');
  const t0 = Date.now();
  const next = await run(c, 'cpnA', 1);
  const r = next[0]!.req.streamerContext!;
  assert.ok(r.sabrContexts.some((x) => x.type === 5 && Buffer.from(x.value!).equals(Buffer.from(CTX))), 'the next run\'s first request carries the context');
  assert.deepEqual(Array.from(r.playbackCookie ?? []), Array.from(COOKIE), 'and the playback cookie');
  assert.ok(next[0]!.rn > first[1]!.rn, `the request number goes on (${first[1]!.rn} -> ${next[0]!.rn})`);
  assert.ok(Date.now() - t0 < 2000, 'no backoff before it');
});

test('another playback, or a new SABR URL, starts as a new client', { timeout: 30000 }, async () => {
  const c = new SabrContinuity();
  await run(c, 'cpnB', 2);
  const other = await run(c, 'cpnC', 1);
  assert.ok(!other[0]!.req.streamerContext?.sabrContexts.length, 'other playback: no context');
  assert.equal(other[0]!.rn, 0);
  const url = info.sabrUrl;
  info.sabrUrl = 'https://invalid.example/videoplayback?expire=2';   // a reload brought a new URL
  try {
    const reloaded = await run(c, 'cpnB', 1);
    assert.ok(!reloaded[0]!.req.streamerContext?.sabrContexts.length, 'new URL: no context');
  } finally { info.sabrUrl = url; }
});
