// Player reloads requested by SABR (review 2026-11-05): shared, reused, rate-limited, breaker-aware.
import test from 'node:test';
import assert from 'node:assert/strict';
import { mod, vodInfo, noSessions } from './helpers.ts';
import { MemoryStore } from '../../res/sofa-yt/lib/store.ts';
import type { VideoInfo } from '../../res/sofa-yt/lib/youtube.ts';

const { YouTube } = await mod('lib/youtube.ts');

/** YouTube whose player request is a counted stub (the guards around it are under test). */
class CountingYouTube extends YouTube {
  calls = 0;
  override async request(id: string): Promise<VideoInfo> {
    this.calls++;
    await new Promise((r) => setTimeout(r, 20));
    const info = vodInfo({ id, sabrUrl: `https://x/${this.calls}`, ustreamer: 'u', expires: Date.now() / 1000 + 3600, fetchedAt: 0 });
    this.cache.set(id, info);
    return info;
  }
}

function make({ blocked = 0, held = 0 } = {}): CountingYouTube {
  return new CountingYouTube({ store: new MemoryStore(), sessions: noSessions, breaker: { blockedUntil: () => blocked, heldUntil: () => held, note() {} },
    po: { mintString: () => Promise.reject(new Error('no PO token in reload tests')) } });
}

test('concurrent reloads of one video share a single player request', async () => {
  const yt = make();
  const r = await Promise.all([yt.reload('a'), yt.reload('a'), yt.reload('a')]);
  assert.equal(yt.calls, 1);
  assert.equal(r[0].serverAbrStreamingUrl, r[2].serverAbrStreamingUrl);
});

test('a response fetched in the last 5 min is reused', async () => {
  const yt = make();
  yt.cache.set('b', vodInfo({ id: 'b', sabrUrl: 'https://fresh', ustreamer: 'u', expires: Date.now() / 1000 + 3600, fetchedAt: Date.now() / 1000 - 60 }));
  const r = await yt.reload('b');
  assert.equal(yt.calls, 0);
  assert.equal(r.serverAbrStreamingUrl, 'https://fresh');
});

test('at most 2 reloads per video per 10 min', async () => {
  const yt = make();
  await yt.reload('c');
  await yt.reload('c');
  await assert.rejects(yt.reload('c'), /reload limit/);
  assert.equal(yt.calls, 2);
});

test('background sessions send no reload while the breaker is open; playback still may', async () => {
  const yt = make({ blocked: Date.now() / 1000 + 600 });
  await assert.rejects(yt.reload('d', null, { bg: true }), (e: { bot?: boolean }) => e.bot === true);
  assert.equal(yt.calls, 0);
  await yt.reload('d', null, { bg: false });
  assert.equal(yt.calls, 1);
});

test('right after a bot check even user playback sends nothing (retries from the phone)', async () => {
  const yt = make({ blocked: Date.now() / 1000 + 3600, held: Date.now() / 1000 + 180 });
  await assert.rejects(yt.info('a'), /not a bot \(paused, no request sent\)/);
  await assert.rejects(yt.refresh('a'), /paused, no reload sent/);
  assert.equal(yt.calls, 0);
  const later = make({ blocked: Date.now() / 1000 + 3600 });   // hold over, pause still on
  await later.info('a');
  assert.equal(later.calls, 1, 'user playback tries again');
  await assert.rejects(later.info('b', { bg: true }), /paused/);
  assert.equal(later.calls, 1, 'the background still waits');
});

test('a run\'s reload must bring a new SABR URL: the refused one coming back ends the run (no loop)', async () => {
  const { freshReloads } = await mod('lib/sabrpump.ts');
  const answers = ['https://rr1/new', 'https://rr1/new', 'https://rr1/newer'];
  const reload = freshReloads(async () => ({ serverAbrStreamingUrl: answers.shift()!, videoPlaybackUstreamerConfig: 'u' }), 'https://rr1/old');
  assert.equal((await reload()).serverAbrStreamingUrl, 'https://rr1/new', 'a fresh URL goes through');
  await assert.rejects(reload(), /refused SABR URL came back/, 'the same URL again: failed, not retried');
  assert.equal((await reload()).serverAbrStreamingUrl, 'https://rr1/newer');
  const stale = freshReloads(async () => ({ serverAbrStreamingUrl: 'https://rr1/old', videoPlaybackUstreamerConfig: 'u' }), 'https://rr1/old');
  await assert.rejects(stale(), /refused SABR URL/, 'a cached response with the run\'s own URL');
});
