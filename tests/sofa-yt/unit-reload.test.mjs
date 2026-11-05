// Player reloads requested by SABR (review 2026-11-05): shared, reused, rate-limited, breaker-aware.
import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { mod } from './helpers.mjs';

const { YouTube } = await mod('lib/youtube.mjs');

function make({ blocked = 0 } = {}) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'sofa-yt-reload-'));
  const yt = new YouTube({ stateDir: dir, breaker: { blockedUntil: () => blocked }, po: {} });
  yt.calls = 0;
  yt.request = async (id) => {
    yt.calls++;
    await new Promise((r) => setTimeout(r, 20));
    const info = { id, sabrUrl: `https://x/${yt.calls}`, ustreamer: 'u', expires: Date.now() / 1000 + 3600, fetchedAt: 0 };
    yt.cache.set(id, info);
    return info;
  };
  return yt;
}

test('concurrent reloads of one video share a single player request', async () => {
  const yt = make();
  const r = await Promise.all([yt.reload('a'), yt.reload('a'), yt.reload('a')]);
  assert.equal(yt.calls, 1);
  assert.equal(r[0].serverAbrStreamingUrl, r[2].serverAbrStreamingUrl);
});

test('a response fetched in the last 5 min is reused', async () => {
  const yt = make();
  yt.cache.set('b', { id: 'b', sabrUrl: 'https://fresh', ustreamer: 'u', expires: Date.now() / 1000 + 3600, fetchedAt: Date.now() / 1000 - 60 });
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
  await assert.rejects(yt.reload('d', null, { bg: true }), (e) => e.bot === true);
  assert.equal(yt.calls, 0);
  await yt.reload('d', null, { bg: false });
  assert.equal(yt.calls, 1);
});
