// Shared helpers for the sofa-yt tests: module loading from the assembled run dir (tools/test-sofa-yt),
// fixtures, a deterministic fake SABR pump and a fake YouTube client (no network anywhere).
import fs from 'node:fs';
import path from 'node:path';
import http from 'node:http';

export const DIR = process.env.SOFA_YT_DIR;
if (!DIR) throw new Error('run via tools/test-sofa-yt (SOFA_YT_DIR unset)');
export const FIX = path.join(path.dirname(new URL(import.meta.url).pathname), 'fixtures');
export const mod = (rel) => import(path.join(DIR, rel));

export function fixturePlayer(id) {
  return JSON.parse(fs.readFileSync(path.join(FIX, `player-${id}.json`), 'utf8'));
}
export function fixtureInit(id, itag) {
  return fs.readFileSync(path.join(FIX, `${id}-${itag}.init`));
}

/** Player info as youtube.mjs caches it, from a fixture (no URLs are ever contacted). */
export function fixtureInfo(id) {
  const p = fixturePlayer(id);
  return {
    id, title: p.videoDetails.title, durationMs: Number(p.videoDetails.lengthSeconds) * 1000,
    expires: Math.floor(Date.now() / 1000) + 6 * 3600, sabrUrl: 'https://invalid.example/videoplayback?expire=1',
    ustreamer: 'AAAA', clientName: 1, clientVersion: '2.0', formats: p.adaptiveFormats, captions: p.captions,
  };
}

/** Deterministic content for synthetic media bytes: byte at absolute offset x. */
export const patternByte = (x) => (x * 31 + 7) & 0xff;
export function patternBuf(start, len) {
  const b = Buffer.allocUnsafe(len);
  for (let i = 0; i < len; i++) b[i] = patternByte(start + i);
  return b;
}

/** Expected file content: real init bytes, synthetic pattern after them. */
export function expectedBytes(init, start, end) {
  const b = patternBuf(start, end - start);
  for (let x = start; x < Math.min(end, init.length); x++) b[x - start] = init[x];
  return b;
}

/**
 * Segment table of a track from its index (segments = clusters/subsegments, like SABR delivers them).
 */
export function segmentTable(index, total, durationMs) {
  return index.map((e, i) => {
    const next = index[i + 1];
    return { start: e.off, length: (next ? next.off : total) - e.off, startMs: e.ms, durationMs: (next ? next.ms : durationMs) - e.ms };
  });
}

/**
 * Fake pump factory. `media` maps format key -> {init, segs}. Emits the init segment and then the
 * segments from the one containing startMs, one every `intervalMs`, until aborted / end / failure.
 */
export function fakePumps(media, { intervalMs = 2, fail = null, stall = false } = {}) {
  const log = { starts: [], aborts: 0, emitted: 0, live: 0 };
  function start(_info, _formats, o) {
    const rec = { video: o.video?.key || null, audio: o.audio.key, startMs: o.startMs, emitted: 0 };
    log.starts.push(rec);
    log.live++;
    let stopped = false;
    let timer = null;
    const tracks = [o.video ? ['video', media[o.video.key]] : null, ['audio', media[o.audio.key]]].filter(Boolean);
    const cursors = tracks.map(([kind, m]) => {
      let i = m.segs.findIndex((s) => s.startMs <= o.startMs && o.startMs < s.startMs + s.durationMs);
      if (i < 0) i = o.startMs <= 0 ? 0 : m.segs.length;
      return { kind, m, i, initSent: false };
    });
    const finish = (err, how) => { if (stopped) return; stopped = true; log.live--; clearTimeout(timer); o.onEnd(err, how); };
    const step = () => {
      if (stopped) return;
      if (fail) return finish(new Error(fail), 'error');
      let any = false;
      for (const c of cursors) {
        if (!c.initSent) {
          c.initSent = true; any = true;
          o.onSegment(c.kind, { start: 0, buf: Buffer.from(c.m.init), startMs: 0, durationMs: 0, init: true });
        } else if (c.i < c.m.segs.length) {
          const s = c.m.segs[c.i++]; any = true;
          rec.emitted++; log.emitted++;
          o.onSegment(c.kind, { start: s.start, buf: patternBuf(s.start, s.length), startMs: s.startMs, durationMs: s.durationMs, init: false });
        }
        if (stopped) return;
      }
      if (!any) return finish(null, 'finished');
      timer = setTimeout(step, intervalMs);
    };
    if (!stall) timer = setTimeout(step, intervalMs); // stall: a run that never answers
    return { abort() { if (!stopped) { log.aborts++; finish(null, 'aborted'); } } };
  }
  return { start, log };
}

/** Fake YouTube client: serves fixture infos, counts "player requests". */
export function fakeYouTube(infos, { breaker } = {}) {
  const y = {
    requests: 0, sessionState: 'ready', cache: new Map(),
    async info(id, { bg = false } = {}) {
      if (y.cache.has(id)) return { info: y.cache.get(id), cached: true };
      if (bg && breaker?.blockedUntil()) {
        const e = new Error("Sign in to confirm you're not a bot (paused, no request sent)"); e.bot = true; throw e;
      }
      y.requests++;
      const i = infos[id];
      if (!i) { const e = new Error('Video unavailable'); throw e; }
      if (i === 'live') { const e = new Error('live'); e.live = true; throw e; }
      if (i === 'bot') { const e = new Error("Sign in to confirm you're not a bot"); e.bot = true; breaker?.note(true); throw e; }
      y.cache.set(id, i);
      return { info: i, cached: false };
    },
    async webHeaders() { return {}; },
  };
  return y;
}

/** Start createApp on an ephemeral port. */
export async function startApp(opts) {
  const { createApp } = await mod('lib/app.mjs');
  const app = createApp(opts);
  const server = http.createServer(app.handler);
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const port = server.address().port;
  app.setPort(port);
  return {
    app, port, base: `http://127.0.0.1:${port}`,
    async close() { app.shutdown(); server.closeAllConnections?.(); await new Promise((r) => server.close(r)); },
  };
}

/** GET with an optional Range; returns {status, headers, body:Buffer}. Aborts after `timeoutMs`. */
export async function get(url, { range, timeoutMs = 10000, maxBytes = Infinity } = {}) {
  const ac = new AbortController();
  const t = setTimeout(() => ac.abort(), timeoutMs);
  try {
    const r = await fetch(url, { headers: range ? { range } : {}, signal: ac.signal });
    const chunks = []; let n = 0;
    const reader = r.body.getReader();
    try {
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        chunks.push(Buffer.from(value)); n += value.length;
        if (n >= maxBytes) { ac.abort(); break; }
      }
    } catch (e) { if (n < maxBytes) throw e; }
    return { status: r.status, headers: r.headers, body: Buffer.concat(chunks) };
  } finally { clearTimeout(t); }
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export async function until(fn, timeoutMs = 5000, stepMs = 10) {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) { if (await fn()) return true; await sleep(stepMs); }
  return false;
}

/** Encode YouTube format xtags (protobuf FormatXTags, base64url) for synthetic formats. */
export async function xtags(tags) {
  const { FormatXTags } = await mod('node_modules/googlevideo/dist/src/exports/protos.js');
  return Buffer.from(FormatXTags.encode({ xtags: Object.entries(tags).map(([key, value]) => ({ key, value })) }).finish())
    .toString('base64').replace(/\+/g, '-').replace(/\//g, '_');
}

/** Minimal ServerResponse stand-in whose consumption the test controls (backpressure). */
import { EventEmitter } from 'node:events';
export class FakeRes extends EventEmitter {
  constructor() { super(); this.bytes = 0; this.limit = Infinity; this.chunks = []; this.keep = false; }
  write(buf) {
    this.bytes += buf.length;
    if (this.keep) this.chunks.push(buf);
    if (this.bytes >= this.limit) { this.blocked = true; return false; }
    return true;
  }
  /** Let the reader continue until `bytes` total were written. */
  allow(bytes) { this.limit = bytes; if (this.blocked && this.bytes < bytes) { this.blocked = false; this.emit('drain'); } }
  destroy() { this.emit('close'); }
}
