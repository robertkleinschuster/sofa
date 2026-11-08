// The YouTube engine core: open/close sessions, read their media, subtitles, InnerTube for the app,
// suggestions, health. Runtime-neutral (no node, no DOM): the Firefox page (web/engine.ts,
// docs/youtube-engine.md) is a thin adapter over it, the tests drive it directly. Failures are
// EngineError with the status and JSON body Sofa gets (as an HTTP server would answer).
import { PlaybackSession } from './session.ts';
import type { PumpHandle, PumpRequest, ServeTarget, SessionConfig } from './session.ts';
import { LiveSession, codecShort } from './hls.ts';
import type { HlsConfig, PlaylistFetch } from './hls.ts';
import { describeFormats, pickVideo, pickAudio, audioTracks, subtitleTracks, DEFAULT_MAX_HEIGHT } from './formats.ts';
import type { DescribedFormat, SubtitleKind } from './formats.ts';
import { fetchVtt } from './subs.ts';
import { errorMessage, toError } from './errors.ts';
import { log } from './log.ts';
import { background } from './timers.ts';
import { ViewReporter } from './report.ts';
import type { PlayerState, ReportClient, ReportDeps } from './report.ts';
import type { Breaker } from './breaker.ts';
import type { PoTokenProvider } from './webpo.ts';
import type { AppEndpoint, EndscreenElement, HlsInfo, VodInfo, YouTube, YouTubeErrorFlags } from './youtube.ts';
import { APP_ENDPOINTS } from './youtube.ts';

const VIDEO_ID = /^[A-Za-z0-9_-]{11}$/;
export const SESSION_IDLE_MS = 10 * 60 * 1000;
export const MAX_SESSIONS = 4;
export const READ_MAX = 8 * 1024 * 1024;   // one read(); the caller reads on in a loop
const IN_USE_MS = 60000;   // read within this time = in use (mpv reconnects, pauses between reads)

/** What the engine uses of YouTube / the PO token minter / the breaker (tests pass fakes). */
export type EngineYouTube = Pick<YouTube, 'sessionState' | 'info' | 'refresh' | 'forget'> & Partial<Pick<YouTube, 'prune' | 'innertube'>>;
export type EnginePo = Pick<PoTokenProvider, 'state' | 'mintString'>;
export type EngineBreaker = Pick<Breaker, 'blockedUntil'>;

/** Pump factory for a session: real SABR or a fake. */
export type EngineStartPump = (info: VodInfo, formats: DescribedFormat[], opts: PumpRequest & { bg: boolean }) => PumpHandle;

export interface EngineOptions {
  youtube: EngineYouTube;
  po: EnginePo;
  breaker: EngineBreaker;
  startPump: EngineStartPump;
  /** Where the adapter serves `/s/<sid>/...` (the URLs in an open answer start with it). */
  base: () => string;
  sessionCfg?: Partial<SessionConfig>;
  idleMs?: number;
  maxSessions?: number;
  sweepMs?: number;
  fetchFn?: PlaylistFetch;
  liveCfg?: Partial<HlsConfig>;
  /** The fetch for requests the youtube.com page makes itself (suggestions, oEmbed): the page's own. */
  pageFetch?: typeof fetch;
  /** Resident memory in MB for health(), where the runtime can tell. */
  memoryMB?: () => number;
  /** A view's stats pings (lib/report.ts): the page's client facts and the transport. Absent: no reporting. */
  reporting?: Reporting;
}

export type Session = PlaybackSession | LiveSession;

/** What report() needs from the page: its client facts (once; null = not available) and the requests. */
export interface Reporting {
  client(): Promise<ReportClient | null>;
  deps: Omit<ReportDeps, 'media'>;
}

/** An engine failure: the status and body an adapter answers with. */
export class EngineError extends Error {
  readonly status: number;
  readonly body: { error: string } & Record<string, unknown>;
  constructor(status: number, body: { error: string } & Record<string, unknown>) {
    super(body.error);
    this.status = status;
    this.body = body;
  }
}

/** What open() is asked (adapters pass their raw parameters; the engine validates). */
export interface OpenRequest {
  v: string;
  bg?: boolean;
  maxHeight?: number;
  lang?: string;
  start?: number;
  /** default: prefetch unless bg */
  prefetch?: boolean;
  vcodec?: string;
  acodec?: string;
}

/** A subtitle track of an open answer. */
export interface SubsEntry {
  lang: string;
  url: string;
  kind: SubtitleKind;
  name: string;
}

/** How an open answer came about (cache, reuse, timing, breaker). */
export interface OpenMeta {
  cached: boolean;
  reused?: boolean;
  secs: number;
  blocked_until: number;
}

/** open of a VOD: the dash pair + choices (the media routes: SFYTEngine+Media.m). */
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
  /** Per local track (the URL's last part: video, audio, an audio key): its identity across sessions,
   * length and type - Sofa serves what its media store holds without asking the engine first. */
  tracks: Record<string, { id: string; total: number; mimeType: string }>;
}

/** open of a live / post-live DVR recording: one muxed HLS stream. */
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

/** open that failed (an answer, not an error, unless the video ID is invalid). */
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

/** One media track of a VOD session. */
interface MediaTrack {
  /** The track's identity across sessions: the same format of the same video is the same bytes
   * (Sofa's media store keys its disk copy by it - docs/media-store.md). */
  id: string;
  total: number;
  mimeType: string;
  /** Write bytes [start, end) to `to` as they arrive; resolves with the count written (short = premature end). */
  serve(start: number, end: number, to: ServeTarget): Promise<number>;
}

/** Bytes of a track read in one piece (the browser engine's read()). */
export interface MediaBytes {
  id: string;
  total: number;
  mimeType: string;
  bytes: Uint8Array;
}

export interface EngineHealth {
  ok: true;
  session: EngineYouTube['sessionState'];
  poToken: EnginePo['state'];
  sessions: number;
  blocked_until: number;
  rssMB?: number;
  bufferedMB: number;
  fetched: { videoSec: number; MB: number; sabrRuns: number };
}

export interface Engine {
  readonly sessions: Map<string, Session>;
  open(req: OpenRequest): Promise<OpenAnswer>;
  close(sid: string): boolean;
  /**
   * Bytes from `offset` of a track, like a stream read: what is buffered there now (up to maxBytes,
   * at most READ_MAX); only when nothing is, it waits for SABR's first piece. Waiting for the whole
   * range stalled the player: 1 MB of audio is a minute, more than SABR fetches ahead of the reader.
   */
  read(sid: string, key: string, offset: number, maxBytes: number): Promise<MediaBytes>;
  playlist(sid: string): Promise<string>;
  /** Segment n of a live session's playlist (its local URL `/s/<sid>/seg/<n>.<ext>`), fetched from googlevideo. */
  segment(sid: string, n: number): Promise<{ mimeType: string; bytes: Uint8Array }>;
  subtitles(sid: string, key: string): Promise<string>;
  status(sid: string): object;
  innertube(endpoint: string, body: unknown, opts: { bg: boolean }): Promise<object>;
  suggest(q: string): Promise<object>;
  /**
   * Whether a video is still online, as its oEmbed answer tells (the request a share preview makes;
   * no player request, so it is fine during a bot-check pause): the HTTP status - 200 public or
   * unlisted, 400/404 gone, anything else unknown (401/403 also covers private videos).
   */
  availability(v: string): Promise<number>;
  /**
   * A YouTube picture (thumbnail, avatar, banner) as the page loads it: the page's own fetch -
   * Firefox's connection, cache and Referer, CORS as youtube.com (both picture hosts allow it).
   * Only those hosts; not paused by the breaker (pictures are what every visit loads).
   */
  image(url: string): Promise<{ mimeType: string; bytes: Uint8Array }>;
  /**
   * The player's state for session `sid` (Sofa's player, docs/youtube-engine.md "Playback
   * reporting"): the view's stats pings follow from it like youtube.com's player sends them;
   * `closed` ends the view. false: not reported (no such VOD session, no tracking, no reporting).
   */
  report(sid: string, state: PlayerState | { state: 'closed' }): Promise<boolean>;
  /**
   * Playback of session `sid` starts at `ms` (the player's start point, resume included): media is
   * fetched from there right away - as youtube.com's player starts its stream at the resume time -
   * instead of once mpv has probed the file and seeked (seconds later). false: no such VOD session.
   */
  startsAt(sid: string, ms: number): boolean;
  health(): EngineHealth;
  shutdown(): void;
}

/** YouTube's picture hosts: i.ytimg.com (video thumbnails), yt3.ggpht.com and
 * yt3.googleusercontent.com (avatars, banners). */
const IMAGE_HOST = /^(i\d?\.ytimg\.com|yt\d\.ggpht\.com|yt\d\.googleusercontent\.com)$/;
const IMAGE_TIMEOUT_MS = 20000;
const MAX_IMAGE_BYTES = 8 * 1024 * 1024;   // one channel answer (base64) stays below Sofa's post limit

export function createEngine({ youtube, po, breaker, startPump, base, sessionCfg = {}, idleMs = SESSION_IDLE_MS, maxSessions = MAX_SESSIONS,
  sweepMs = 30000, fetchFn = fetch, liveCfg = {}, pageFetch = fetch, memoryMB, reporting }: EngineOptions): Engine {
  const sessions = new Map<string, Session>();
  const views = new Map<string, ViewReporter>();   // sid -> the view of Sofa's player on it
  let reportClient: Promise<ReportClient | null> | null = null;
  // the views' clock: their pings are due within a fraction of a second, so a 250-ms tick while there is a view
  let viewTicker: ReturnType<typeof setInterval> | null = null;
  const tickViews = (): void => {
    if (views.size && !viewTicker) viewTicker = background(setInterval(() => { for (const v of views.values()) v.tick(); }, 250));
    if (!views.size && viewTicker) { clearInterval(viewTicker); viewTicker = null; }
  };
  const fetchedTotal = { ms: 0, bytes: 0, runs: 0 }; // media pulled by closed sessions

  function sweep() {
    const now = Date.now();
    for (const s of sessions.values()) {
      if (s.closed) { forget(s); continue; }
      if (!s.activeReaders && now - s.lastActivity > idleMs) { s.close('idle'); forget(s); }
    }
  }
  const sweeper = background(setInterval(sweep, sweepMs));

  function forget(s: Session): void {
    endView(s.sid);
    if (!sessions.delete(s.sid)) return;
    fetchedTotal.ms += s.fetched.video.ms; fetchedTotal.bytes += s.fetched.video.bytes + s.fetched.audio.bytes;
    fetchedTotal.runs += s.runs || 0;
  }

  function fetchedNow() {
    const f = { ...fetchedTotal };
    for (const s of sessions.values()) { f.ms += s.fetched.video.ms; f.bytes += s.fetched.video.bytes + s.fetched.audio.bytes; f.runs += s.runs || 0; }
    return { videoSec: Math.round(f.ms / 1000), MB: +(f.bytes / 1048576).toFixed(1), sabrRuns: f.runs };
  }

  function endView(sid: string): void {
    const v = views.get(sid);
    if (!v) return;
    views.delete(sid);
    v.close();
    tickViews();
  }

  async function report(sid: string, st: PlayerState | { state: 'closed' }): Promise<boolean> {
    if (st.state === 'closed') { const had = views.has(sid); endView(sid); return had; }
    const s = sessions.get(sid);
    if (!reporting || !s || s.closed || s.kind !== 'sabr') return false;
    let v = views.get(sid);
    if (!v) {
      const tracking = (s.info as VodInfo).tracking;
      if (!tracking?.playback || !tracking.watchtime) return false;
      reportClient ??= reporting.client().catch((e: unknown) => { log('report: no client facts:', errorMessage(e)); return null; });
      const client = await reportClient;
      if (!client) { reportClient = null; return false; }   // asked again next time
      if (views.has(sid)) v = views.get(sid)!;   // another report got here first
      else {
        if (s.closed) return false;
        let last = { bytes: s.fetched.video.bytes + s.fetched.audio.bytes, at: Date.now() };
        v = new ViewReporter({ cpn: s.cpn, tracking, lenS: (s.video.fmt.durationMs || s.info.durationMs) / 1000, fmt: s.video.fmt.itag,
          afmt: s.audioFormats.get(s.mainAudioKey)?.itag ?? 0 }, client, {
          ...reporting.deps,
          media: () => {   // throughput since the last qoe ping
            const bytes = s.fetched.video.bytes + s.fetched.audio.bytes, at = Date.now();
            const m = { aheadS: s.bufferedAheadS(), bytes: bytes - last.bytes, seconds: (at - last.at) / 1000 };
            last = { bytes, at };
            return m;
          },
        });
        views.set(sid, v);
        tickViews();
      }
    }
    v.update(st);
    return true;
  }

  /** The open session `sid` (404 otherwise). */
  function session(sid: string): Session {
    const s = sessions.get(sid);
    if (!s || s.closed) throw new EngineError(404, { error: 'no such session (expired?)' });
    return s;
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

  function subsOf(s: Session, u: string): SubsEntry[] {
    return s.subs.map((t) => ({ lang: t.lang, url: `${u}/subs/${encodeURIComponent(t.key)}.vtt`, kind: t.kind, name: t.name }));
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
      subs: subsOf(s, u),
      endscreen: [],
      ...extra,
    };
  }

  /** Live / post-live DVR: choose the variant now (an unplayable manifest fails open, not mpv). */
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
      segmentUrl: (sid, n, ext) => `${base()}/s/${sid}/seg/${n}.${ext}`,
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

  /** The tracks' identities that exist now (an audio language's track may come into being later). */
  function trackInfos(s: PlaybackSession, keys: string[]): VodAnswer['tracks'] {
    const out: VodAnswer['tracks'] = {};
    for (const k of new Set(keys)) {
      try { const m = track(s.sid, k); out[k] = { id: m.id, total: m.total, mimeType: m.mimeType }; } catch { /* not (yet) there */ }
    }
    return out;
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
      subs: subsOf(s, u),
      endscreen: s.info.endscreen || [],
      published: s.info.published ?? null,
      tracks: trackInfos(s, ['video', 'audio', ...audios.map((t) => decodeURIComponent(t.url.split('/').pop()!))]),
      ...extra,
    };
  }

  async function open(q: OpenRequest): Promise<OpenAnswer> {
    const t0 = performance.now();
    const vid = q.v || '';
    if (!VIDEO_ID.test(vid)) throw new EngineError(400, { error: 'invalid video ID', bot: false, blocked_until: breaker.blockedUntil() } satisfies OpenFailure);
    const bg = !!q.bg;
    const maxHeight = Number(q.maxHeight) || DEFAULT_MAX_HEIGHT;
    const lang = (q.lang || 'de').slice(0, 12);
    const startSec = Math.max(0, Number(q.start) || 0);
    // codec preferences (downloads ask for avc1 + mp4a: an MP4 without re-encoding)
    const vcodec = ['avc1', 'vp9', 'av01'].includes(q.vcodec ?? '') ? q.vcodec! : null;
    const acodec = ['mp4a', 'opus'].includes(q.acodec ?? '') ? q.acodec! : null;
    const prefetch = q.prefetch ?? !bg;
    let info; let cached;
    try {
      ({ info, cached } = await youtube.info(vid, { bg }));
    } catch (thrown) {
      const e: Error & YouTubeErrorFlags = toError(thrown);
      if (e.upcoming) {
        return { id: vid, error: 'upcoming', live: true, upcoming: true, startTime: e.startTime || null, bot: false, blocked_until: breaker.blockedUntil() };
      }
      if (e.live) {
        log(`open ${vid}: ${e.message}`);
        return { id: vid, error: String(e.message).slice(0, 300), live: true, bot: false, blocked_until: breaker.blockedUntil() };
      }
      log(`open ${vid}${bg ? ' (bg)' : ''} failed: ${e.message}`);
      return { id: vid, error: String(e.message).slice(0, 300), bot: !!e.bot,
        ...(e.unanswered ? { unanswered: true as const } : {}), blocked_until: breaker.blockedUntil() };
    }
    if (info.kind === 'hls') return openLive(info, { vid, bg, maxHeight, lang, cached, t0 });
    // an existing healthy session for the same choice keeps its buffered media
    for (const s of sessions.values()) {
      if (s.kind !== 'hls' && !s.closed && !s.failed && s.info === info && s.maxHeight === maxHeight && s.lang === lang
          && s.vcodec === vcodec && s.acodec === acodec) {
        s.lastActivity = Date.now();
        if (prefetch && startSec) s.hint(startSec * 1000);
        return describeSession(s, { cached: true, reused: true, secs: +((performance.now() - t0) / 1000).toFixed(2), blocked_until: breaker.blockedUntil() });
      }
    }
    const formats = describeFormats(info.formats);
    const video = pickVideo(formats, maxHeight, vcodec);
    const audio = pickAudio(formats, acodec);
    if (!video || !audio) return { id: vid, error: 'no usable video/audio format', bot: false, blocked_until: breaker.blockedUntil() };
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
    return describeSession(s, { cached, secs: +((performance.now() - t0) / 1000).toFixed(2), blocked_until: breaker.blockedUntil() });
  }

  function track(sid: string, key: string): MediaTrack {
    const s = session(sid);
    if (s.kind === 'hls') throw new EngineError(404, { error: 'live session: use live.m3u8' });
    const t = s.track(key === 'audio' ? s.mainAudioKey : key);
    if (!t) throw new EngineError(404, { error: 'no such track' });
    if (s.failed) throw new EngineError(503, { error: s.failed.message });
    return {
      // video, format (itag, audio track, variants) and its version stamp: a re-encode changes lmt
      id: `yt:${s.info.id}:${t.fmt.key}:${t.fmt.sabr.lastModified}:${t.file.total}`,
      total: t.file.total,
      mimeType: (t.fmt.mimeType || 'application/octet-stream').split(';')[0]!,
      serve: (start, end, to) => s.serve(t, start, end, to),
    };
  }

  async function read(sid: string, key: string, offset: number, maxBytes: number): Promise<MediaBytes> {
    const t = track(sid, key);
    const start = Math.max(0, Math.floor(offset) || 0);
    if (start >= t.total) throw new EngineError(416, { error: `offset ${start} beyond ${t.total}` });
    const end = Math.min(t.total, start + Math.min(READ_MAX, Math.max(1, Math.floor(maxBytes) || READ_MAX)));
    const parts: Uint8Array[] = [];
    // serve() writes every buffered piece in one go and then awaits more: end the read at that point
    let stop: (() => void) | null = null;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const n = await t.serve(start, end, {
      write(c) {
        parts.push(c.slice());
        if (timer) clearTimeout(timer);
        timer = setTimeout(() => stop?.(), 0);
        return true;
      },
      on(ev, f) { if (ev === 'close') stop = f; },
      off(ev) { if (ev === 'close') stop = null; },
    });
    if (timer) clearTimeout(timer);
    const bytes = new Uint8Array(n);
    let at = 0;
    for (const p of parts) { bytes.set(p, at); at += p.length; }
    return { id: t.id, total: t.total, mimeType: t.mimeType, bytes };
  }

  async function playlist(sid: string): Promise<string> {
    const s = session(sid);
    if (s.kind !== 'hls') throw new EngineError(404, { error: 'not a live session' });
    if (s.failed) throw new EngineError(503, { error: s.failed.message });
    try {
      return await s.playlist();
    } catch (e) {
      // mpv retries a failed playlist reload; after MAX_FAILURES the session is failed (503)
      throw new EngineError(s.failed ? 503 : 502, { error: errorMessage(e) });
    }
  }

  async function segment(sid: string, n: number): Promise<{ mimeType: string; bytes: Uint8Array }> {
    const s = session(sid);
    if (s.kind !== 'hls') throw new EngineError(404, { error: 'not a live session' });
    if (s.failed) throw new EngineError(503, { error: s.failed.message });
    if (!s.segUrls.has(n)) throw new EngineError(404, { error: `no segment ${n}` });
    try {
      return await s.segment(n);
    } catch (e) {
      throw new EngineError(502, { error: errorMessage(e) });   // mpv's HLS demuxer retries / skips
    }
  }

  async function subtitles(sid: string, key: string): Promise<string> {
    const s = session(sid);
    const t = s.subs.find((x) => x.key === key);
    if (!t) throw new EngineError(404, { error: 'no such subtitle track' });
    let body = s.subCache.get(key);
    if (!body) {
      try {
        const poToken = await po.mintString(s.info.id).catch(() => null);
        body = await fetchVtt(t, { poToken, clientVersion: s.info.clientVersion });
        s.subCache.set(key, body);
      } catch (e) {
        log(`${s.tag}: subtitles ${key}: ${errorMessage(e)}`);
        throw new EngineError(502, { error: errorMessage(e) });
      }
    }
    s.lastActivity = Date.now();
    return body;
  }

  // InnerTube for the app (pages, feeds, watch page) in the engine's one session; the app caches
  async function innertube(endpoint: string, body: unknown, { bg }: { bg: boolean }): Promise<object> {
    if (!(APP_ENDPOINTS as readonly string[]).includes(endpoint) || !youtube.innertube) throw new EngineError(404, { error: 'unknown endpoint' });
    if (!body || typeof body !== 'object' || Array.isArray(body)) throw new EngineError(400, { error: 'body must be an object' });
    try {
      return (await youtube.innertube(endpoint as AppEndpoint, body as Record<string, unknown>, { bg })) as object;
    } catch (thrown) {
      const e = toError(thrown) as Error & { bot?: boolean };
      log(`yt ${endpoint}${bg ? ' (bg)' : ''} failed: ${e.message}`);
      throw new EngineError(e.bot ? 503 : 502, { error: e.message, bot: !!e.bot, blocked_until: breaker.blockedUntil() });
    }
  }

  // search suggestions - the request youtube.com's search box makes while typing
  async function suggest(q: string): Promise<object> {
    if (!q || q.length > 200) throw new EngineError(400, { error: 'q missing or too long' });
    const u = new URL('https://suggestqueries-clients6.youtube.com/complete/search');
    for (const [k, v] of Object.entries({ client: 'youtube', ds: 'yt', hl: 'de', gl: 'AT', oe: 'utf-8', xhr: 't', q })) u.searchParams.set(k, v);
    let r: Response;
    try {
      r = await pageFetch(u, { headers: { referer: 'https://www.youtube.com/' }, signal: AbortSignal.timeout(8000) });
    } catch (e) { throw new EngineError(502, { error: errorMessage(e) }); }
    if (!r.ok) throw new EngineError(502, { error: `suggestions: HTTP ${r.status}` });
    try { return (await r.json()) as object; } catch (e) { throw new EngineError(502, { error: errorMessage(e) }); }
  }

  async function availability(v: string): Promise<number> {
    if (!/^[\w-]{11}$/.test(v)) throw new EngineError(400, { error: 'not a video id' });
    const u = new URL('https://www.youtube.com/oembed');
    u.searchParams.set('format', 'json');
    u.searchParams.set('url', `https://www.youtube.com/watch?v=${v}`);
    try {
      return (await pageFetch(u, { signal: AbortSignal.timeout(10000) })).status;
    } catch (e) { throw new EngineError(502, { error: errorMessage(e) }); }
  }

  async function image(url: string): Promise<{ mimeType: string; bytes: Uint8Array }> {
    let u: URL;
    try { u = new URL(url); } catch { throw new EngineError(400, { error: 'not a URL' }); }
    if (u.protocol !== 'https:' || !IMAGE_HOST.test(u.hostname)) throw new EngineError(400, { error: `not a YouTube picture host: ${u.hostname}` });
    let r: Response;
    try {
      r = await pageFetch(u, { signal: AbortSignal.timeout(IMAGE_TIMEOUT_MS) });
    } catch (e) { throw new EngineError(502, { error: errorMessage(e) }); }
    if (!r.ok) throw new EngineError(r.status, { error: `picture: HTTP ${r.status}` });
    const bytes = new Uint8Array(await r.arrayBuffer());
    if (bytes.length > MAX_IMAGE_BYTES) throw new EngineError(502, { error: `picture too large (${bytes.length} bytes)` });
    return { mimeType: r.headers.get('content-type') ?? '', bytes };
  }

  return {
    sessions,
    open,
    close(sid) {
      const s = sessions.get(sid);
      if (s) { s.close('closed by client'); forget(s); }
      return !!s;
    },
    startsAt(sid, ms) {
      const s = sessions.get(sid);
      if (!s || s.closed || s.kind !== 'sabr' || !(ms >= 0)) return false;
      s.hint(ms);
      return true;
    },
    read,
    playlist,
    segment,
    subtitles,
    status: (sid) => session(sid).status(),
    report,
    innertube,
    suggest,
    availability,
    image,
    health: () => ({
      ok: true, session: youtube.sessionState, poToken: po.state, sessions: sessions.size,
      blocked_until: breaker.blockedUntil(), ...(memoryMB ? { rssMB: memoryMB() } : {}),
      bufferedMB: +([...sessions.values()].reduce((n, s) => n + s.bytes, 0) / 1048576).toFixed(1), fetched: fetchedNow(),
    }),
    shutdown() {
      clearInterval(sweeper);
      for (const sid of [...views.keys()]) endView(sid);
      for (const s of sessions.values()) s.close('shutdown');
      log('media pulled this run:', JSON.stringify(fetchedNow()));
      sessions.clear();
    },
  };
}
