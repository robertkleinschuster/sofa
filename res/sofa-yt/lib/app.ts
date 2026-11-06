// HTTP API of the sidecar (127.0.0.1 only). See docs/sofa-yt.md for the contract.
//   GET /health
//   GET /open?v=<id>&bg=0|1&maxHeight=1080&lang=de&start=<sec>&prefetch=0|1&vcodec=avc1|vp9|av01&acodec=mp4a|opus
//   GET|HEAD /s/<sid>/video   /s/<sid>/audio   /s/<sid>/audio/<key>    (Range, 206)
//   GET /s/<sid>/live.m3u8    (lives / post-live DVR: the proxied HLS media playlist)
//   GET /s/<sid>/subs/<key>.vtt
//   GET /s/<sid>/status       (diagnostics)
//   GET /close?sid=<sid>
//   POST /yt/<endpoint>?bg=0|1   (browse, next, search, navigation/resolve_url: InnerTube for the app)
//   GET /suggest?q=<prefix>     (search suggestions, as the web page's search box asks)
import type http from 'node:http';
import { PlaybackSession } from './session.ts';
import type { PumpHandle, PumpRequest, SessionConfig } from './session.ts';
import { LiveSession, codecShort } from './hls.ts';
import type { HlsConfig, PlaylistFetch } from './hls.ts';
import { describeFormats, pickVideo, pickAudio, audioTracks, subtitleTracks, DEFAULT_MAX_HEIGHT } from './formats.ts';
import type { DescribedFormat, SubtitleKind } from './formats.ts';
import { fetchVtt } from './subs.ts';
import { errorMessage, toError } from './errors.ts';
import { log } from './log.ts';
import type { Breaker } from './breaker.ts';
import type { PoTokenProvider } from './webpo.ts';
import type { AppEndpoint, EndscreenElement, HlsInfo, VodInfo, YouTube, YouTubeErrorFlags } from './youtube.ts';
import { APP_ENDPOINTS } from './youtube.ts';

const VIDEO_ID = /^[A-Za-z0-9_-]{11}$/;
export const SESSION_IDLE_MS = 10 * 60 * 1000;
export const MAX_SESSIONS = 4;

/** What the app uses of YouTube / the PO token minter / the breaker (tests pass fakes). */
export type AppYouTube = Pick<YouTube, 'sessionState' | 'info' | 'refresh' | 'forget' | 'webHeaders'> & Partial<Pick<YouTube, 'prune' | 'innertube'>>;
export type AppPo = Pick<PoTokenProvider, 'state' | 'mintString'>;
export type AppBreaker = Pick<Breaker, 'blockedUntil'>;

/** Pump factory for a session: real SABR (main.ts) or a fake. */
export type AppStartPump = (info: VodInfo, formats: DescribedFormat[], opts: PumpRequest & { bg: boolean }) => PumpHandle;

export interface AppOptions {
  youtube: AppYouTube;
  po: AppPo;
  breaker: AppBreaker;
  startPump: AppStartPump;
  sessionCfg?: Partial<SessionConfig>;
  idleMs?: number;
  maxSessions?: number;
  sweepMs?: number;
  fetchFn?: PlaylistFetch;
  liveCfg?: Partial<HlsConfig>;
  suggestFetch?: typeof fetch;   // default: the process-wide (identity) fetch
}

export type Session = PlaybackSession | LiveSession;

export interface App {
  sessions: Map<string, Session>;
  setPort(p: number): void;
  handler(req: http.IncomingMessage, res: http.ServerResponse): void;
  shutdown(): void;
}

/** A subtitle track of an /open answer (local URL). */
export interface SubsEntry {
  lang: string;
  url: string;
  kind: SubtitleKind;
  name: string;
}

/** How an /open answer came about (cache, reuse, timing, breaker). */
export interface OpenMeta {
  cached: boolean;
  reused?: boolean;
  secs: number;
  blocked_until: number;
}

/** /open of a VOD: the dash pair + choices (docs/sofa-yt.md "HTTP API"). */
export interface VodAnswer extends OpenMeta {
  id: string;
  sid: string;
  title: string;
  duration: number;
  live: false;
  expires: number;
  formats: number;
  video: string;
  audio: string;
  height: number;
  fps: number;
  vcodec: string;
  acodec: string;
  alang: string | null;
  vitag: number;
  aitag: number;
  audios: { lang: string; url: string; original: boolean; dubbed: boolean; described: boolean; name: string | null; itag: number; acodec: string }[];
  subs: SubsEntry[];
  endscreen: EndscreenElement[];
  published: number | null;   // epoch seconds of the publication (exact, from the microformat)
}

/** /open of a live / post-live DVR recording: one muxed HLS stream. */
export interface LiveAnswer extends OpenMeta {
  id: string;
  sid: string;
  title: string;
  duration: number;
  live: boolean;
  postLiveDvr: boolean;
  expires: number;
  hls: string;
  height: number;
  fps: number;
  vcodec: string | null;
  acodec: 'mp4a' | null;
  vitag: number | null;
  audios: [];
  subs: SubsEntry[];
  endscreen: [];
}

/** /open that failed (HTTP 200 unless the video ID is invalid). */
export interface OpenFailure {
  id?: string;
  error: string;
  bot: boolean;
  unanswered?: true;   // YouTube did not answer (YouTubeErrorFlags.unanswered): no other path should ask instead
  blocked_until: number;
  live?: true;
  upcoming?: true;
  startTime?: number | null;
}

export type OpenAnswer = VodAnswer | LiveAnswer | OpenFailure;

function sendJson(res: http.ServerResponse, code: number, obj: object): void {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body), 'Cache-Control': 'no-store' });
  res.end(body);
}

/** An /open answer (typed, so every path answers the documented shape). */
function sendOpen(res: http.ServerResponse, code: number, answer: OpenAnswer): void {
  sendJson(res, code, answer);
}

/** Parse a single-range "bytes=" header against `total`. null = whole file, 'bad' = unsatisfiable. */
export function parseRange(header: string | undefined, total: number): { start: number; end: number } | 'bad' | null {
  if (!header) return null;
  const m = /^bytes=(\d*)-(\d*)$/.exec(String(header).trim());
  if (!m || (m[1] === '' && m[2] === '')) return null; // unsupported syntax: serve the whole file
  let start: number; let end: number;
  if (m[1] === '') { // suffix: last N bytes
    const n = Number(m[2]);
    if (!n) return 'bad';
    start = Math.max(0, total - n); end = total;
  } else {
    start = Number(m[1]);
    end = m[2] === '' ? total : Math.min(total, Number(m[2]) + 1);
  }
  if (start >= total || end <= start) return 'bad';
  return { start, end };
}

const IN_USE_MS = 60000;   // read within this time = in use (mpv reconnects, pauses between reads)

export function createApp({ youtube, po, breaker, startPump, sessionCfg = {}, idleMs = SESSION_IDLE_MS, maxSessions = MAX_SESSIONS, sweepMs = 30000,
  fetchFn = fetch, liveCfg = {}, suggestFetch = fetch }: AppOptions): App {
  const sessions = new Map<string, Session>();
  let port = 0;
  const fetchedTotal = { ms: 0, bytes: 0, runs: 0 }; // media pulled by closed sessions

  const base = () => `http://127.0.0.1:${port}`;

  function sweep() {
    const now = Date.now();
    for (const s of sessions.values()) {
      if (s.closed) { forget(s); continue; }
      if (!s.activeReaders && now - s.lastActivity > idleMs) { s.close('idle'); forget(s); }
    }
  }
  const sweeper = setInterval(sweep, sweepMs);
  sweeper.unref?.();

  function forget(s: Session): void {
    if (!sessions.delete(s.sid)) return;
    fetchedTotal.ms += s.fetched.video.ms; fetchedTotal.bytes += s.fetched.video.bytes + s.fetched.audio.bytes;
    fetchedTotal.runs += s.runs || 0;
  }

  function fetchedNow() {
    const f = { ...fetchedTotal };
    for (const s of sessions.values()) { f.ms += s.fetched.video.ms; f.bytes += s.fetched.video.bytes + s.fetched.audio.bytes; f.runs += s.runs || 0; }
    return { videoSec: Math.round(f.ms / 1000), MB: +(f.bytes / 1048576).toFixed(1), sabrRuns: f.runs };
  }

  // A session in use is never evicted (review 2026-11-05: a playing session with a reader that was
  // just reconnecting got closed for a preload, mpv saw 404). Victims: failed, then never read
  // (preloads), then the least recently used idle one; if all are in use the limit is exceeded.
  function inUse(s: Session): boolean { return s.activeReaders > 0 || (!!s.everRead && Date.now() - (s.lastReadAt ?? 0) < IN_USE_MS); }
  function makeRoom() {
    sweep();
    youtube.prune?.();
    while (sessions.size >= maxSessions) {
      const idle = [...sessions.values()].filter((s) => s.failed || !inUse(s));
      if (!idle.length) { log(`session limit ${maxSessions} exceeded: all sessions in use`); return; }
      const rank = (s: Session): number[] => [s.failed ? 0 : 1, s.everRead ? 1 : 0, s.lastActivity];
      const victim = idle.sort((a, b) => { const x = rank(a), y = rank(b); for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i]! - y[i]!; return 0; })[0]!;
      victim.close('session limit');
      forget(victim);
    }
  }

  function describeLive(s: LiveSession, extra: OpenMeta): LiveAnswer {
    const u = `${base()}/s/${s.sid}`;
    const v: Partial<NonNullable<LiveSession['variant']>> = s.variant || {};
    return {
      id: s.info.id, sid: s.sid, title: s.info.title, duration: Math.round((s.info.durationMs || 0) / 1000),
      live: !!s.info.live, postLiveDvr: !!s.info.postLiveDvr, expires: s.info.expires,
      hls: `${u}/live.m3u8`,
      height: v.height || 0, fps: v.fps || 0, vcodec: codecShort(v.codecs), acodec: /mp4a/.test(v.codecs || '') ? 'mp4a' : null,
      vitag: v.itag || null, audios: [],
      subs: s.subs.map((t) => ({ lang: t.lang, url: `${u}/subs/${encodeURIComponent(t.key)}.vtt`, kind: t.kind, name: t.name })),
      endscreen: [],
      ...extra,
    };
  }

  /** Live / post-live DVR: choose the variant now (an unplayable manifest fails /open, not mpv). */
  async function openLive(info: HlsInfo, { vid, bg, maxHeight, lang, cached, t0 }:
    { vid: string; bg: boolean; maxHeight: number; lang: string; cached: boolean; t0: number }): Promise<LiveAnswer | OpenFailure> {
    const extra = (): OpenMeta => ({ cached, secs: +((performance.now() - t0) / 1000).toFixed(2), blocked_until: breaker.blockedUntil() });
    if (bg) {
      // lives are not downloaded or preloaded (a live never ends; post-live DVR chunks expire)
      return { id: vid, error: info.live ? 'live' : 'post-live', live: true, bot: false, blocked_until: breaker.blockedUntil() };
    }
    for (const s of sessions.values()) {
      if (s.kind === 'hls' && !s.closed && !s.failed && s.info === info && s.maxHeight === maxHeight && s.lang === lang) {
        s.lastActivity = Date.now();
        return describeLive(s, { ...extra(), cached: true, reused: true });
      }
    }
    makeRoom();
    const s = new LiveSession({
      info, maxHeight, fetchFn, cfg: liveCfg,
      headers: () => youtube.webHeaders(),
      refresh: (_why) => youtube.refresh(info.id, null, { bg }),
      subs: info.captions ? subtitleTracks(info.captions, lang) : [],
    });
    s.lang = lang;
    try {
      await s.choose();
    } catch (e) {
      log(`open ${vid}: HLS manifest unusable: ${errorMessage(e)}`);
      // a cached URL may have been revoked: forget it so the next open asks afresh
      if (cached) youtube.forget(vid);
      return { id: vid, error: `HLS manifest unavailable: ${errorMessage(e)}`, live: true, bot: false, blocked_until: breaker.blockedUntil() };
    }
    sessions.set(s.sid, s);
    const v = s.variant!;   // choose() succeeded
    log(`open ${vid}: ${info.live ? 'live' : 'post-live DVR'} HLS ${v.itag || '?'} ${v.height}p${v.fps} (${s.variants.length} variants), ${cached ? 'cached' : 'player request'} -> ${s.sid.slice(0, 6)}`);
    return describeLive(s, extra());
  }

  function describeSession(s: PlaybackSession, extra: OpenMeta): VodAnswer {
    const u = `${base()}/s/${s.sid}`;
    const v = s.video.fmt;
    const a = s.audioFormats.get(s.mainAudioKey)!;   // registered by the constructor
    const audios = (s.audioList || []).map((t) => ({
      lang: t.lang, url: `${u}/audio/${encodeURIComponent(t.format.key)}`, original: t.original, dubbed: t.dubbed,
      described: t.described, name: t.name, itag: t.format.itag, acodec: t.format.codec,
    }));
    return {
      id: s.info.id, sid: s.sid, title: s.info.title, duration: Math.round(s.info.durationMs / 1000), live: false,
      expires: s.info.expires, formats: s.formats.length,
      video: `${u}/video`, audio: `${u}/audio/${encodeURIComponent(a.key)}`,
      height: v.height, fps: v.fps, vcodec: v.codec, acodec: a.codec, alang: a.lang || null,
      vitag: v.itag, aitag: a.itag,
      audios,
      subs: s.subs.map((t) => ({ lang: t.lang, url: `${u}/subs/${encodeURIComponent(t.key)}.vtt`, kind: t.kind, name: t.name })),
      endscreen: s.info.endscreen || [],
      published: s.info.published ?? null,
      ...extra,
    };
  }

  async function open(q: URLSearchParams, res: http.ServerResponse): Promise<void> {
    const t0 = performance.now();
    const vid = q.get('v') || '';
    if (!VIDEO_ID.test(vid)) return sendOpen(res, 400, { error: 'invalid video ID', bot: false, blocked_until: breaker.blockedUntil() });
    const bg = q.get('bg') === '1';
    const maxHeight = Number(q.get('maxHeight')) || DEFAULT_MAX_HEIGHT;
    const lang = (q.get('lang') || 'de').slice(0, 12);
    const startSec = Math.max(0, Number(q.get('start')) || 0);
    // codec preferences (downloads ask for avc1 + mp4a: an MP4 without re-encoding)
    const vq = q.get('vcodec') ?? '', aq = q.get('acodec') ?? '';
    const vcodec = ['avc1', 'vp9', 'av01'].includes(vq) ? vq : null;
    const acodec = ['mp4a', 'opus'].includes(aq) ? aq : null;
    const prefetch = q.has('prefetch') ? q.get('prefetch') === '1' : !bg;
    let info; let cached;
    try {
      ({ info, cached } = await youtube.info(vid, { bg }));
    } catch (thrown) {
      const e: Error & YouTubeErrorFlags = toError(thrown);
      if (e.upcoming) {
        return sendOpen(res, 200, { id: vid, error: 'upcoming', live: true, upcoming: true, startTime: e.startTime || null, bot: false, blocked_until: breaker.blockedUntil() });
      }
      if (e.live) {
        log(`open ${vid}: ${e.message}`);
        return sendOpen(res, 200, { id: vid, error: String(e.message).slice(0, 300), live: true, bot: false, blocked_until: breaker.blockedUntil() });
      }
      log(`open ${vid}${bg ? ' (bg)' : ''} failed: ${e.message}`);
      return sendOpen(res, 200, { id: vid, error: String(e.message).slice(0, 300), bot: !!e.bot,
        ...(e.unanswered ? { unanswered: true as const } : {}), blocked_until: breaker.blockedUntil() });
    }
    if (info.kind === 'hls') return sendOpen(res, 200, await openLive(info, { vid, bg, maxHeight, lang, cached, t0 }));
    // an existing healthy session for the same choice keeps its buffered media
    for (const s of sessions.values()) {
      if (s.kind !== 'hls' && !s.closed && !s.failed && s.info === info && s.maxHeight === maxHeight && s.lang === lang
          && s.vcodec === vcodec && s.acodec === acodec) {
        s.lastActivity = Date.now();
        if (prefetch && startSec) s.hint(startSec * 1000);
        return sendOpen(res, 200, describeSession(s, { cached: true, reused: true, secs: +((performance.now() - t0) / 1000).toFixed(2), blocked_until: breaker.blockedUntil() }));
      }
    }
    const formats = describeFormats(info.formats);
    const video = pickVideo(formats, maxHeight, vcodec);
    const audio = pickAudio(formats, acodec);
    if (!video || !audio) {
      return sendOpen(res, 200, { id: vid, error: 'no usable video/audio format', bot: false, blocked_until: breaker.blockedUntil() });
    }
    const list = audioTracks(formats);
    makeRoom();
    const s = new PlaybackSession({
      info, formats, video, audio, audioChoices: list.map((t) => t.format), subs: subtitleTracks(info.captions, lang),
      startPump: (opts) => startPump(info, formats, { ...opts, bg }), cfg: sessionCfg,
    });
    s.audioList = list;
    s.maxHeight = maxHeight;
    s.lang = lang;
    s.vcodec = vcodec; s.acodec = acodec;
    sessions.set(s.sid, s);
    if (prefetch) s.hint(startSec * 1000);
    log(`open ${vid}${bg ? ' (bg)' : ''}: ${video.itag} ${video.codec} ${video.height}p${video.fps} + ${audio.key} ${audio.codec} ${audio.lang || '?'}`
      + `${list.length ? `, ${list.length} languages` : ''}, ${s.subs.length} subs${info.endscreen?.length ? `, ${info.endscreen.length} end screen tiles` : ''}, ${cached ? 'cached' : 'player request'} -> ${s.sid.slice(0, 6)}`);
    return sendOpen(res, 200, describeSession(s, { cached, secs: +((performance.now() - t0) / 1000).toFixed(2), blocked_until: breaker.blockedUntil() }));
  }

  async function livePlaylist(s: Session, req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
    if (s.kind !== 'hls') return sendJson(res, 404, { error: 'not a live session' });
    if (s.failed) return sendJson(res, 503, { error: s.failed.message });
    let body: string;
    try {
      body = await s.playlist();
    } catch (e) {
      // mpv retries a failed playlist reload; after MAX_FAILURES the session is failed (503)
      return sendJson(res, s.failed ? 503 : 502, { error: errorMessage(e) });
    }
    res.writeHead(200, { 'Content-Type': 'application/vnd.apple.mpegurl', 'Content-Length': Buffer.byteLength(body), 'Cache-Control': 'no-store' });
    if (req.method === 'HEAD') { res.end(); return; }
    res.end(body);
  }

  async function media(s: Session, key: string, req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
    if (s.kind === 'hls') return sendJson(res, 404, { error: 'live session: use live.m3u8' });
    const t = s.track(key);
    if (!t) return sendJson(res, 404, { error: 'no such track' });
    if (s.failed) return sendJson(res, 503, { error: s.failed.message });
    const total = t.file.total;
    const r = parseRange(req.headers.range, total);
    if (r === 'bad') { res.writeHead(416, { 'Content-Range': `bytes */${total}` }); res.end(); return; }
    const { start, end } = r || { start: 0, end: total };
    const headers: http.OutgoingHttpHeaders = {
      'Content-Type': (t.fmt.mimeType || 'application/octet-stream').split(';')[0],
      'Accept-Ranges': 'bytes',
      'Content-Length': end - start,
      'Cache-Control': 'no-store',
    };
    if (r) headers['Content-Range'] = `bytes ${start}-${end - 1}/${total}`;
    res.writeHead(r ? 206 : 200, headers);
    if (req.method === 'HEAD') { res.end(); return; }
    const n = await s.serve(t, start, end, res);
    if (start + n < end) res.destroy(); // premature end: make the client see it (and reconnect)
    else res.end();
  }

  async function subs(s: Session, key: string, res: http.ServerResponse): Promise<void> {
    const t = s.subs.find((x) => x.key === key);
    if (!t) return sendJson(res, 404, { error: 'no such subtitle track' });
    let body = s.subCache.get(key);
    if (!body) {
      try {
        const [headers, poToken] = await Promise.all([youtube.webHeaders(), po.mintString(s.info.id).catch(() => null)]);
        body = await fetchVtt(t, { headers, poToken, clientVersion: s.info.clientVersion });
        s.subCache.set(key, body);
      } catch (e) {
        log(`${s.tag}: subtitles ${key}: ${errorMessage(e)}`);
        return sendJson(res, 502, { error: errorMessage(e) });
      }
    }
    s.lastActivity = Date.now();
    res.writeHead(200, { 'Content-Type': 'text/vtt; charset=utf-8', 'Content-Length': Buffer.byteLength(body), 'Cache-Control': 'no-store' });
    res.end(body);
  }

  // InnerTube for the app (pages, feeds, watch page) in this process' one session; the app caches
  async function appCall(endpoint: string, bg: boolean, req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
    if (!(APP_ENDPOINTS as readonly string[]).includes(endpoint) || !youtube.innertube) return sendJson(res, 404, { error: 'unknown endpoint' });
    const chunks: Buffer[] = [];
    let size = 0;
    for await (const c of req) { size += (c as Buffer).length; if (size > 64 * 1024) return sendJson(res, 413, { error: 'body too large' }); chunks.push(c as Buffer); }
    let body: unknown;
    try { body = JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'); } catch { return sendJson(res, 400, { error: 'body is not JSON' }); }
    if (!body || typeof body !== 'object' || Array.isArray(body)) return sendJson(res, 400, { error: 'body must be an object' });
    try {
      return sendJson(res, 200, (await youtube.innertube(endpoint as AppEndpoint, body as Record<string, unknown>, { bg })) as object);
    } catch (thrown) {
      const e = toError(thrown) as Error & { bot?: boolean };
      log(`yt ${endpoint}${bg ? ' (bg)' : ''} failed: ${e.message}`);
      return sendJson(res, e.bot ? 503 : 502, { error: e.message, bot: !!e.bot, blocked_until: breaker.blockedUntil() });
    }
  }

  // search suggestions in the browser identity (the process-wide fetch, identity.ts) - the request
  // youtube.com's search box makes while typing
  async function suggest(q: string, res: http.ServerResponse): Promise<void> {
    if (!q || q.length > 200) return sendJson(res, 400, { error: 'q missing or too long' });
    const u = new URL('https://suggestqueries-clients6.youtube.com/complete/search');
    for (const [k, v] of Object.entries({ client: 'youtube', ds: 'yt', hl: 'de', gl: 'AT', oe: 'utf-8', xhr: 't', q })) u.searchParams.set(k, v);
    try {
      const r = await suggestFetch(u, { headers: { referer: 'https://www.youtube.com/' }, signal: AbortSignal.timeout(8000) });
      if (!r.ok) return sendJson(res, 502, { error: `suggestions: HTTP ${r.status}` });
      return sendJson(res, 200, (await r.json()) as object);
    } catch (e) { return sendJson(res, 502, { error: errorMessage(e) }); }
  }

  async function handle(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
    // No keep-alive: on OS X 10.9 node's server misses requests arriving on an idle kept-alive socket
    // until keepAliveTimeout closes it (measured: 2.5 s with the default timeout, 27.5 s with 30 s).
    // Every request gets its own connection (loopback, cheap).
    res.setHeader('Connection', 'close');
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    const parts = url.pathname.split('/').filter(Boolean).map(decodeURIComponent);
    if (parts[0] === 'yt' && req.method === 'POST') return appCall(parts.slice(1).join('/'), url.searchParams.get('bg') === '1', req, res);
    if (req.method !== 'GET' && req.method !== 'HEAD') return sendJson(res, 405, { error: 'method not allowed' });
    if (url.pathname === '/health') {
      return sendJson(res, 200, { ok: true, session: youtube.sessionState, poToken: po.state, sessions: sessions.size,
        blocked_until: breaker.blockedUntil(), rssMB: Math.round(process.memoryUsage().rss / 1048576),
        bufferedMB: +([...sessions.values()].reduce((n, s) => n + s.bytes, 0) / 1048576).toFixed(1), fetched: fetchedNow() });
    }
    if (url.pathname === '/open') return open(url.searchParams, res);
    if (url.pathname === '/suggest') return suggest(url.searchParams.get('q') || '', res);
    if (url.pathname === '/close') {
      const s = sessions.get(url.searchParams.get('sid') || '');
      if (s) { s.close('closed by client'); forget(s); }
      return sendJson(res, 200, { ok: true, closed: !!s });
    }
    if (parts[0] === 's' && parts.length >= 3) {
      const s = sessions.get(parts[1]!);
      if (!s || s.closed) return sendJson(res, 404, { error: 'no such session (expired?)' });
      if (parts[2] === 'live.m3u8' && parts.length === 3) return livePlaylist(s, req, res);
      if (parts[2] === 'video' && parts.length === 3) return media(s, 'video', req, res);
      if (parts[2] === 'audio' && parts.length === 3) return media(s, s.kind === 'hls' ? 'audio' : s.mainAudioKey, req, res);   // media() refuses live sessions
      const sub = parts[3];
      if (parts[2] === 'audio' && parts.length === 4 && sub !== undefined) return media(s, sub, req, res);
      if (parts[2] === 'subs' && parts.length === 4 && sub?.endsWith('.vtt')) return subs(s, sub.slice(0, -4), res);
      if (parts[2] === 'status' && parts.length === 3) return sendJson(res, 200, s.status());
    }
    return sendJson(res, 404, { error: 'not found' });
  }

  return {
    sessions,
    setPort(p) { port = p; },
    handler(req, res) {
      handle(req, res).catch((thrown: unknown) => {
        const e = toError(thrown);
        log('request failed:', req.url, e.stack || e.message);
        if (!res.headersSent) sendJson(res, 500, { error: e.message }); else res.destroy();
      });
    },
    shutdown() {
      clearInterval(sweeper);
      for (const s of sessions.values()) s.close('shutdown');
      log('media pulled this run:', JSON.stringify(fetchedNow()));
      sessions.clear();
    },
  };
}
