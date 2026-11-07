// Shared helpers for the sofa-yt tests: module loading from the assembled run dir (tools/test-sofa-yt),
// fixtures, a deterministic fake SABR pump and a fake YouTube client (no network anywhere).
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { serveEngine } from './mediaserver.ts';
import { EventEmitter } from 'node:events';
import { after } from 'node:test';
import type { Engine, EngineOptions, EngineYouTube } from '../../res/sofa-yt/lib/engine.ts';
import type { MediaIndex } from '../../res/sofa-yt/lib/mediaindex.ts';
import type { PumpEnd, PumpHandle, PumpRequest, TrackKind } from '../../res/sofa-yt/lib/session.ts';
import type { RawCaptions, RawFormat, RawVideoDetails } from '../../res/sofa-yt/lib/ytraw.ts';
import type { VideoInfo, VodInfo, YouTubeErrorFlags } from '../../res/sofa-yt/lib/youtube.ts';

const dir = process.env.SOFA_YT_DIR;
if (!dir) throw new Error('run via tools/test-sofa-yt (SOFA_YT_DIR unset)');
export const DIR: string = dir;

/** A fresh directory (state, cache) for one test case; all of them are removed when the test file is done. */
const tempDirs: string[] = [];
after(() => { for (const d of tempDirs) fs.rmSync(d, { recursive: true, force: true }); });
export function tempDir(prefix: string): string {
  const d = fs.mkdtempSync(path.join(os.tmpdir(), prefix));
  tempDirs.push(d);
  return d;
}
export const FIX = path.join(path.dirname(new URL(import.meta.url).pathname), 'fixtures');

/** googlevideo's protobuf codec for format xtags, as far as the tests use it. */
interface FormatXTagsCodec {
  FormatXTags: { encode(m: { xtags: { key: string; value: string }[] }): { finish(): Uint8Array } };
}

/**
 * The engine's modules, loaded at run time from res/sofa-yt (SOFA_YT_DIR, tools/test-sofa-yt);
 * the types come from the sources (type-only imports, erased at run time).
 */
interface Modules {
  'lib/engine.ts': typeof import('../../res/sofa-yt/lib/engine.ts');
  'lib/breaker.ts': typeof import('../../res/sofa-yt/lib/breaker.ts');
  'lib/bytes.ts': typeof import('../../res/sofa-yt/lib/bytes.ts');
  'lib/sabrpump.ts': typeof import('../../res/sofa-yt/lib/sabrpump.ts');
  'lib/lounge.ts': typeof import('../../res/sofa-yt/lib/lounge.ts');
  'lib/formats.ts': typeof import('../../res/sofa-yt/lib/formats.ts');
  'lib/hls.ts': typeof import('../../res/sofa-yt/lib/hls.ts');
  'lib/mediaindex.ts': typeof import('../../res/sofa-yt/lib/mediaindex.ts');
  'lib/session.ts': typeof import('../../res/sofa-yt/lib/session.ts');
  'lib/vfile.ts': typeof import('../../res/sofa-yt/lib/vfile.ts');
  'lib/youtube.ts': typeof import('../../res/sofa-yt/lib/youtube.ts');
  'node_modules/googlevideo/dist/src/exports/protos.js': FormatXTagsCodec;
}
export const mod = <K extends keyof Modules>(rel: K): Promise<Modules[K]> => import(path.join(DIR, rel)) as Promise<Modules[K]>;

/** The VOD fixtures: a player response trimmed to what the format choice reads. */
export interface PlayerFixture {
  videoDetails: RawVideoDetails;
  adaptiveFormats: RawFormat[];
  captions?: RawCaptions;
}

export function fixturePlayer(id: string): PlayerFixture {
  const p: unknown = JSON.parse(fs.readFileSync(path.join(FIX, `player-${id}.json`), 'utf8'));
  if (typeof p !== 'object' || p === null || !('adaptiveFormats' in p) || !Array.isArray(p.adaptiveFormats)) {
    throw new Error(`fixture player-${id}.json: no adaptiveFormats`);
  }
  return p as PlayerFixture;   // recorded from YouTube, trimmed by hand
}
export function fixtureInit(id: string, itag: number): Buffer {
  return fs.readFileSync(path.join(FIX, `${id}-${itag}.init`));
}

/** Player info as youtube.ts caches it, from a fixture (no URLs are ever contacted). */
export function fixtureInfo(id: string): VodInfo {
  const p = fixturePlayer(id);
  return {
    id, title: p.videoDetails.title ?? '', author: '', durationMs: Number(p.videoDetails.lengthSeconds) * 1000,
    expires: Math.floor(Date.now() / 1000) + 6 * 3600, sabrUrl: 'https://invalid.example/videoplayback?expire=1',
    ustreamer: 'AAAA', clientName: 1, clientVersion: '2.0', playerId: 'test', formats: p.adaptiveFormats,
    captions: p.captions ?? null, endscreen: [], fetchedAt: Math.floor(Date.now() / 1000),
  };
}

/** Deterministic content for synthetic media bytes: byte at absolute offset x. */
export const patternByte = (x: number): number => (x * 31 + 7) & 0xff;
export function patternBuf(start: number, len: number): Buffer {
  const b = Buffer.allocUnsafe(len);
  for (let i = 0; i < len; i++) b[i] = patternByte(start + i);
  return b;
}

/** Expected file content: real init bytes, synthetic pattern after them. */
export function expectedBytes(init: Buffer, start: number, end: number): Buffer {
  const b = patternBuf(start, end - start);
  for (let x = start; x < Math.min(end, init.length); x++) b[x - start] = init[x]!;
  return b;
}

/** A segment of a track: bytes [start, start + length), media [startMs, startMs + durationMs). */
export interface SegmentSpec {
  start: number;
  length: number;
  startMs: number;
  durationMs: number;
}

/**
 * Segment table of a track from its index (segments = clusters/subsegments, like SABR delivers them).
 */
export function segmentTable(index: MediaIndex | null, total: number, durationMs: number): SegmentSpec[] {
  if (!index) throw new Error('no index');
  return index.map((e, i) => {
    const next = index[i + 1];
    return { start: e.off, length: (next ? next.off : total) - e.off, startMs: e.ms, durationMs: (next ? next.ms : durationMs) - e.ms };
  });
}

/** Media of the fake pumps per format key: the init segment + the segment table. */
export type FakeMedia = Record<string, { init: Buffer; segs: SegmentSpec[] }>;

export interface PumpLog {
  starts: { video: string | null; audio: string; startMs: number; emitted: number }[];
  aborts: number;
  emitted: number;
  live: number;
}

/** The pump factory signature of createApp (info and formats are ignored by the fakes). */
export type FakeStart = (info: unknown, formats: unknown, o: PumpRequest) => PumpHandle;

/** A track a fake pump feeds: its media and position. */
function mediaOf(media: FakeMedia, key: string): { init: Buffer; segs: SegmentSpec[] } {
  const m = media[key];
  if (!m) throw new Error(`fake pump: no media for format ${key}`);
  return m;
}

/**
 * Fake pump factory. `media` maps format key -> {init, segs}. Emits the init segment and then the
 * segments from the one containing startMs, one every `intervalMs`, until aborted / end / failure.
 */
export function fakePumps(media: FakeMedia, { intervalMs = 2, fail = null, stall = false }: { intervalMs?: number; fail?: string | null; stall?: boolean } = {}):
  { start: FakeStart; log: PumpLog } {
  const log: PumpLog = { starts: [], aborts: 0, emitted: 0, live: 0 };
  const start: FakeStart = (_info, _formats, o) => {
    const rec = { video: o.video?.key || null, audio: o.audio.key, startMs: o.startMs, emitted: 0 };
    log.starts.push(rec);
    log.live++;
    let stopped = false;
    let timer: NodeJS.Timeout | undefined;
    const tracks: [TrackKind, { init: Buffer; segs: SegmentSpec[] }][] = [];
    if (o.video) tracks.push(['video', mediaOf(media, o.video.key)]);
    tracks.push(['audio', mediaOf(media, o.audio.key)]);
    const cursors = tracks.map(([kind, m]) => {
      let i = m.segs.findIndex((s) => s.startMs <= o.startMs && o.startMs < s.startMs + s.durationMs);
      if (i < 0) i = o.startMs <= 0 ? 0 : m.segs.length;
      return { kind, m, i, initSent: false };
    });
    const finish = (err: Error | null, how: PumpEnd): void => { if (stopped) return; stopped = true; log.live--; clearTimeout(timer); o.onEnd(err, how); };
    const step = (): void => {
      if (stopped) return;
      if (fail) return finish(new Error(fail), 'error');
      let any = false;
      for (const c of cursors) {
        if (!c.initSent) {
          c.initSent = true; any = true;
          o.onSegment(c.kind, { start: 0, buf: Buffer.from(c.m.init), startMs: 0, durationMs: 0, init: true });
        } else if (c.i < c.m.segs.length) {
          const s = c.m.segs[c.i++]!; any = true;
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
  };
  return { start, log };
}

/** An Error carrying the flags YouTube's errors have (what the app reads of a failure). */
export function ytError(message: string, flags: YouTubeErrorFlags): Error & YouTubeErrorFlags {
  return Object.assign(new Error(message), flags);
}

/** A fake YouTube client: what createApp uses, plus the counters tests read. */
export type FakeYouTube = EngineYouTube & { requests: number; cache: Map<string, VideoInfo> };

/** Fake YouTube client: serves fixture infos, counts "player requests". */
export function fakeYouTube(infos: Record<string, VideoInfo | 'live' | 'bot' | 'unanswered'>, { breaker }: { breaker?: { blockedUntil(): number; heldUntil(): number; note(bot: boolean): void } } = {}): FakeYouTube {
  const y: FakeYouTube = {
    requests: 0, sessionState: 'ready', cache: new Map(),
    async info(id, { bg = false } = {}) {
      const have = y.cache.get(id);
      if (have) return { info: have, cached: true };
      if (breaker && (bg ? breaker.blockedUntil() : breaker.heldUntil())) {   // as YouTube.info
        throw ytError("Sign in to confirm you're not a bot (paused, no request sent)", { bot: true });
      }
      y.requests++;
      const i = infos[id];
      if (!i) { const e = new Error('Video unavailable'); throw e; }
      if (i === 'live') throw ytError('live', { live: true });
      if (i === 'unanswered') throw ytError('player request failed: fetch failed', { unanswered: true });
      if (i === 'bot') { const e = ytError("Sign in to confirm you're not a bot", { bot: true }); breaker?.note(true); throw e; }
      y.cache.set(id, i);
      return { info: i, cached: false };
    },
    async refresh() { throw new Error('fakeYouTube: no refresh'); },
    forget() {},
  };
  return y;
}

/** A running engine behind the HTTP adapter on an ephemeral port. */
export interface TestApp {
  engine: Engine;
  port: number;
  base: string;
  close(): Promise<void>;
}

/** createApp options with test doubles: the fakes only need what the test exercises. */
export type TestAppOptions = Omit<EngineOptions, 'startPump' | 'po' | 'youtube' | 'base'> & {
  startPump: FakeStart;
  po: Partial<EngineOptions['po']>;
  youtube: Pick<EngineYouTube, 'info'> & Partial<EngineYouTube>;
};

const unused = (what: string) => (): never => { throw new Error(`test double: ${what} not expected`); };

/** Start createApp on an ephemeral port. */
export async function startApp(opts: TestAppOptions): Promise<TestApp> {
  const { createEngine } = await mod('lib/engine.ts');
  // the doubles carry what a test exercises; a member a test leaves out must never be reached
  const youtube: EngineYouTube = { sessionState: 'ready', refresh: unused('youtube.refresh'), forget: unused('youtube.forget'),
    ...opts.youtube };
  let port = 0;
  const engine = createEngine({ ...opts, youtube, po: { state: 'ready', mintString: unused('po.mintString'), ...opts.po },
    base: () => `http://127.0.0.1:${port}` });
  const server = await serveEngine(engine);   // Sofa's media routes (SFYTEngine+Media) for the tests
  port = server.port;
  return {
    engine, port, base: server.base,
    async close() { engine.shutdown(); await server.close(); },
  };
}

/** GET with an optional Range; returns {status, headers, body:Buffer}. Aborts after `timeoutMs`. */
export async function get(url: string, { range, timeoutMs = 10000, maxBytes = Infinity }: { range?: string; timeoutMs?: number; maxBytes?: number } = {}):
  Promise<{ status: number; headers: Headers; body: Buffer }> {
  const ac = new AbortController();
  const t = setTimeout(() => ac.abort(), timeoutMs);
  try {
    const r = await fetch(url, { headers: range ? { range } : {}, signal: ac.signal });
    const chunks: Buffer[] = []; let n = 0;
    if (!r.body) return { status: r.status, headers: r.headers, body: Buffer.alloc(0) };
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

export const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));

/** p, or 'timeout' after ms - the timer is cleared either way, so a settled p does not keep the
 *  test process alive (a bare race with sleep() held each run open for its full length). */
export async function within<T>(p: Promise<T>, ms: number): Promise<T | 'timeout'> {
  let t: NodeJS.Timeout | undefined;
  try { return await Promise.race([p, new Promise<'timeout'>((r) => { t = setTimeout(() => r('timeout'), ms); })]); }
  finally { clearTimeout(t); }
}

export async function until(fn: () => boolean | Promise<boolean>, timeoutMs = 5000, stepMs = 10): Promise<boolean> {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) { if (await fn()) return true; await sleep(stepMs); }
  return false;
}

/** Encode YouTube format xtags (protobuf FormatXTags, base64url) for synthetic formats. */
export async function xtags(tags: Record<string, string>): Promise<string> {
  const { FormatXTags } = await mod('node_modules/googlevideo/dist/src/exports/protos.js');
  return Buffer.from(FormatXTags.encode({ xtags: Object.entries(tags).map(([key, value]) => ({ key, value })) }).finish())
    .toString('base64').replace(/\+/g, '-').replace(/\//g, '_');
}

/** Minimal ServerResponse stand-in whose consumption the test controls (backpressure). */
export class FakeRes extends EventEmitter {
  bytes: number;
  limit: number;
  chunks: Buffer[];
  keep: boolean;
  blocked?: boolean;

  constructor() { super(); this.bytes = 0; this.limit = Infinity; this.chunks = []; this.keep = false; }
  write(buf: Buffer): boolean {
    this.bytes += buf.length;
    if (this.keep) this.chunks.push(buf);
    if (this.bytes >= this.limit) { this.blocked = true; return false; }
    return true;
  }
  /** Let the reader continue until `bytes` total were written. */
  allow(bytes: number): void { this.limit = bytes; if (this.blocked && this.bytes < bytes) { this.blocked = false; this.emit('drain'); } }
  destroy(): void { this.emit('close'); }
}

/** Element `i` of an array (negative: from the end); a missing one fails the test. */
export function nth<T>(a: readonly T[] | null | undefined, i: number): T {
  const v = a?.at(i);
  if (v === undefined) throw new Error(`no element ${i} (length ${a?.length ?? 'none'})`);
  return v;
}

/** The value, which the test expects to exist (null/undefined fails the test). */
export function must<T>(v: T | null | undefined, what = 'value'): T {
  if (v === null || v === undefined) throw new Error(`${what} missing`);
  return v;
}

/** A complete VOD info for tests that only care about some fields. */
export function vodInfo(over: Partial<VodInfo> & { id: string }): VodInfo {
  return { title: '', author: '', durationMs: 0, expires: Math.floor(Date.now() / 1000) + 3600, sabrUrl: 'https://invalid.example/sabr',
    ustreamer: 'u', clientName: 1, clientVersion: '2.0', playerId: 'test', formats: [], captions: null, endscreen: [],
    fetchedAt: 0, ...over };
}

/** A JSON body the test knows the shape of (the engine's own answers). */
export function json<T>(body: Buffer | string): T {
  return JSON.parse(body.toString()) as T;
}

/** A SessionFactory for tests that stub the Innertube session (or never need one). */
export const noSessions = {
  create: (): Promise<never> => Promise.reject(new Error('no Innertube session in this test')),
};
