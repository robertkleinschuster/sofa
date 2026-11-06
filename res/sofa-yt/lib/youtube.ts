// One consistent YouTube web-player identity: a persistent Innertube session (visitorData, user
// agent and player script cached in the state dir), WEB-client player requests with a video-bound
// PO token, and a per-video cache of the deciphered result so that reopening / seeking / restarting
// SABR never costs another player request while the URLs are valid.
//
// GOTCHA (spike): YouTube A/B-serves several player.js versions. The n-parameter of
// serverAbrStreamingUrl must be transformed with the SAME player whose signatureTimestamp went into
// the player request, otherwise SABR answers 403. Hence the player object is captured before the
// request and used for deciphering right after it; only the deciphered URL is cached.
import { LANG, LOCATION, TIMEZONE } from './identity.ts';
import type { Identity } from './identity.ts';
import fs from 'node:fs';
import path from 'node:path';
import type { ReloadPlaybackContext } from 'googlevideo/protos';
import type { ReloadResponse } from 'googlevideo/sabr-stream';
import type { Innertube, Player } from 'youtubei.js';
import { isBotCheck } from './breaker.ts';
import type { Breaker } from './breaker.ts';
import { errorMessage } from './errors.ts';
import { prepareManifestUrl, pathExpire } from './hls.ts';
import { isRecord, parseJson, record, records } from './json.ts';
import type { JsonObject } from './json.ts';
import { log } from './log.ts';
import { asPlayerResponse, rawText } from './ytraw.ts';
import type { RawCaptions, RawFormat, RawPlayerResponse } from './ytraw.ts';
import type { PoTokenProvider } from './webpo.ts';

/** The Innertube context client (user agent, visitor data, client version). */
type InnertubeClient = Innertube['session']['context']['client'];

/** One end screen tile Sofa can open. */
export interface EndscreenElement {
  style: string;
  videoId?: string;
  playlistId?: string | undefined;
  browseId?: string;
  title: string;
  left: number;
  top: number;
  width: number;
  aspectRatio: number;
  startMs: number;
  endMs: number;
  image?: string | null;   // undefined: the largest thumbnail has no URL
}

interface InfoBase {
  id: string;
  title: string;
  author: string;
  durationMs: number;
  expires: number;               // epoch seconds: the URLs are valid until then
  clientName: number;            // 1 = WEB
  clientVersion: string;
  playerId: string;
  captions: RawCaptions | null;
  endscreen: EndscreenElement[];
  fetchedAt: number;             // epoch seconds of the player request
  published?: number | null;     // epoch seconds of the publication (microformat, exact); absent in old cache files
}

/** Exact publication time (microformat publishDate/uploadDate, ISO 8601 with offset) in epoch seconds. */
export function publishedOf(raw: RawPlayerResponse | null | undefined): number | null {
  const mf = raw?.microformat?.playerMicroformatRenderer;
  const t = Date.parse(mf?.publishDate || mf?.uploadDate || '');
  return Number.isFinite(t) ? Math.floor(t / 1000) : null;
}

/** A VOD: SABR streaming URL (deciphered with the request's player) + the adaptive formats. */
export interface VodInfo extends InfoBase {
  kind?: undefined;
  sabrUrl: string;
  ustreamer: string;
  formats: RawFormat[];
}

/** A live / post-live DVR recording: the prepared HLS manifest URL. */
export interface HlsInfo extends InfoBase {
  kind: 'hls';
  live: boolean;
  postLiveDvr: boolean;
  hlsUrl: string;
}

/** What the per-video cache holds (also the JSON of `players/<id>.json`). */
export type VideoInfo = VodInfo | HlsInfo;

export type PlayerClass =
  | { kind: 'upcoming'; startTime: number | null }
  | { kind: 'offline' | 'live' | 'postlive' | 'vod' | 'error' };

/** The /player request body youtubei.js sends as is (parse: false = raw JSON back). */
interface PlayerRequest {
  videoId: string;
  racyCheckOk: boolean;
  contentCheckOk: boolean;
  playbackContext: {
    contentPlaybackContext: { vis: number; splay: boolean; lactMilliseconds: string; signatureTimestamp: number };
    reloadPlaybackContext?: ReloadPlaybackContext;
  };
  serviceIntegrityDimensions: { poToken: string };
  client: 'WEB';
  parse: false;
}

/** A cache file is used only when it is a complete info of the expected video. */
function isVideoInfo(x: unknown, videoId: string): x is VideoInfo {
  if (!isRecord(x) || x.id !== videoId || typeof x.expires !== 'number') return false;
  return x.kind === 'hls' ? typeof x.hlsUrl === 'string' : typeof x.sabrUrl === 'string' && Array.isArray(x.formats);
}

const SESSION_TIMEOUT_MS = 30000;
const PLAYER_TIMEOUT_MS = 20000;
const SESSION_MAX_AGE_MS = 6 * 3600 * 1000;   // pick up player.js rotations now and then
const REUSE_MARGIN_S = 15 * 60;                // a cached response must stay valid this long
const SESSION_RETRY_MIN_MS = 30 * 1000;
const SESSION_RETRY_MAX_MS = 10 * 60 * 1000;

const RELOAD_FRESH_S = 300;
const UPCOMING_CACHE_MS = 60 * 1000;   // an upcoming/offline answer is reused this long (no request storm)
const RELOAD_MAX = 2;
const RELOAD_WINDOW_S = 600;

/**
 * End screen of the video (the tiles creators place in the last 5-20 s), from the same player
 * response - no extra request. Positions are fractions of the video frame. Only targets Sofa can
 * open: videos, playlists, channels (no websites/merch).
 */
export function endscreenElements(raw: RawPlayerResponse | null | undefined): EndscreenElement[] {
  const els = raw?.endscreen?.endscreenRenderer?.elements || [];
  const out: EndscreenElement[] = [];
  for (const e of els) {
    const r = e.endscreenElementRenderer;
    if (!r) continue;
    const ep = r.endpoint || {};
    const target = ep.watchEndpoint?.videoId ? { videoId: ep.watchEndpoint.videoId, playlistId: ep.watchEndpoint.playlistId }
      : ep.browseEndpoint?.browseId ? { browseId: ep.browseEndpoint.browseId } : null;
    if (!target || !r.style || !['VIDEO', 'PLAYLIST', 'CHANNEL', 'SUBSCRIBE'].includes(r.style)) continue;
    const thumbs = r.image?.thumbnails || [];
    out.push({
      style: r.style, ...target,
      title: rawText(r.title) || '',
      left: Number(r.left) || 0, top: Number(r.top) || 0, width: Number(r.width) || 0, aspectRatio: Number(r.aspectRatio) || 0,
      startMs: Number(r.startMs) || 0, endMs: Number(r.endMs) || 0,
      image: thumbs.length ? thumbs[thumbs.length - 1]!.url : null,
    });
  }
  return out;
}

export interface YouTubeErrorFlags {
  bot?: boolean;
  /** YouTube did not answer (network, timeout, 5xx, no session/PO token) - not a refusal: asking
   *  again through another path (yt-dlp) would only be a second identity for the same video */
  unanswered?: boolean;
  live?: boolean;
  status?: string | null;
  upcoming?: boolean;
  startTime?: number | null;
}

export class YouTubeError extends Error {
  bot: boolean;
  unanswered: boolean;
  live: boolean;
  status: string | null;
  upcoming: boolean;
  startTime: number | null;

  constructor(message: string, { bot = false, unanswered = false, live = false, status = null, upcoming = false, startTime = null }: YouTubeErrorFlags = {}) {
    super(message);
    this.bot = bot;
    this.unanswered = unanswered;
    this.live = live;
    this.status = status;
    this.upcoming = upcoming;
    this.startTime = startTime;   // epoch seconds of a scheduled live/premiere, if known
  }
}

/**
 * What kind of playback a raw WEB player response describes:
 *   {kind:'upcoming', startTime}  scheduled live / premiere (videoDetails.isUpcoming, or
 *                                 LIVE_STREAM_OFFLINE with a scheduled start in the offline slate)
 *   {kind:'offline'}              LIVE_STREAM_OFFLINE without a schedule (broadcast paused/gone)
 *   {kind:'live'}                 running broadcast (videoDetails.isLive)
 *   {kind:'postlive'}             ended broadcast still served from the live chunks
 *                                 (videoDetails.isPostLiveDvr; formats lack index/init ranges)
 *   {kind:'vod'}                  everything else (status OK)
 *   {kind:'error'}                any other non-OK status (the caller reports the reason)
 */
export function classifyPlayer(raw: RawPlayerResponse | null | undefined): PlayerClass {
  const ps = raw?.playabilityStatus || {};
  const vd = raw?.videoDetails || {};
  const slate = ps.liveStreamability?.liveStreamabilityRenderer?.offlineSlate?.liveStreamOfflineSlateRenderer;
  let startTime = Number(slate?.scheduledStartTime) || null;
  if (!startTime) {
    const iso = raw?.microformat?.playerMicroformatRenderer?.liveBroadcastDetails?.startTimestamp;
    const t = iso ? Date.parse(iso) / 1000 : NaN;
    if (Number.isFinite(t) && t > Date.now() / 1000 - 3600) startTime = Math.floor(t);   // a future (or just missed) start only
  }
  if (vd.isUpcoming || (ps.status === 'LIVE_STREAM_OFFLINE' && (startTime || slate?.scheduledStartTime))) {
    return { kind: 'upcoming', startTime };
  }
  if (ps.status === 'LIVE_STREAM_OFFLINE') return { kind: 'offline' };
  if (ps.status !== 'OK') return { kind: 'error' };
  if (vd.isLive) return { kind: 'live' };
  if (vd.isPostLiveDvr) return { kind: 'postlive' };
  return { kind: 'vod' };
}

function withTimeout<T>(p: Promise<T>, ms: number, what: string): Promise<T> {
  let t: NodeJS.Timeout | undefined;
  return Promise.race([p, new Promise<never>((_, rej) => { t = setTimeout(() => rej(new Error(`${what} timed out`)), ms); })])
    .finally(() => clearTimeout(t));
}

/**
 * Optional hard cap on player requests (safety net against loops): at most `max` requests within
 * `windowS` seconds (windowS = 0: lifetime of the counter file). Persisted, survives restarts.
 */
interface BudgetEntry {
  at: string;      // ISO time of the request
  why: string;
}

export class PlayerBudget {
  file: string | null;
  max: number;
  windowS: number;
  mem: BudgetEntry[];

  constructor({ file = null, max = Infinity, windowS = 3600 }: { file?: string | null; max?: number; windowS?: number } = {}) {
    this.file = file; this.max = max; this.windowS = windowS; this.mem = [];
  }

  load(): BudgetEntry[] {
    if (!this.file) return this.mem;
    try {
      return records(parseJson(fs.readFileSync(this.file, 'utf8')))
        .filter((e): e is JsonObject & BudgetEntry => typeof e.at === 'string' && typeof e.why === 'string');
    } catch { return []; }
  }

  take(why: string): number {
    const now = Date.now();
    let b = this.load();
    if (this.windowS > 0) b = b.filter((e) => now - Date.parse(e.at) < this.windowS * 1000);
    if (b.length >= this.max) {
      throw new YouTubeError(`player-request budget exhausted (${b.length}/${this.max}) - refusing (${why})`);
    }
    b.push({ at: new Date(now).toISOString(), why });
    this.mem = b;
    if (this.file) {
      try { fs.writeFileSync(this.file, JSON.stringify(b, null, 1)); } catch (e) { log('budget: cannot write', errorMessage(e)); }
    }
    return b.length;
  }
}

/** What the app may call through innertube(): pages and the watch page - never `player` (that is this process' job, with a PO token). */
export const APP_ENDPOINTS = ['browse', 'next', 'search', 'navigation/resolve_url'] as const;
export type AppEndpoint = typeof APP_ENDPOINTS[number];

export interface YouTubeOptions {
  stateDir: string;
  identity: Identity;
  breaker: Pick<Breaker, 'blockedUntil' | 'note'>;
  po: Pick<PoTokenProvider, 'mintString'>;
  budget?: PlayerBudget;
}

export type SessionState = 'pending' | 'ready' | 'error';

export class YouTube {
  stateDir: string;
  identity: Identity;
  breaker: Pick<Breaker, 'blockedUntil' | 'note'>;
  po: Pick<PoTokenProvider, 'mintString'>;
  budget: PlayerBudget;
  playerDir: string;
  yt: Innertube | null;
  ytCreated: number;
  ytInflight: Promise<Innertube> | null;
  ytState: SessionState;
  ytRetryMs: number;
  ytNextTry: number;
  ytError: string | null;
  cache: Map<string, VideoInfo>;
  inflight: Map<string, Promise<VideoInfo>>;
  reloading: Map<string, Promise<VideoInfo>>;
  reloads: Map<string, number[]>;
  notYet: Map<string, { at: number; err: YouTubeError }>;

  constructor({ stateDir, identity, breaker, po, budget = new PlayerBudget() }: YouTubeOptions) {
    this.stateDir = stateDir;
    this.identity = identity;
    this.breaker = breaker;
    this.po = po;
    this.budget = budget;
    this.playerDir = path.join(stateDir, 'players');
    fs.mkdirSync(this.playerDir, { recursive: true });
    this.yt = null;
    this.ytCreated = 0;
    this.ytInflight = null;
    this.ytState = 'pending';
    this.ytRetryMs = SESSION_RETRY_MIN_MS;
    this.ytNextTry = 0;
    this.ytError = null;
    this.cache = new Map();     // videoId -> info
    this.inflight = new Map();  // videoId -> Promise<info>
    this.reloading = new Map(); // videoId -> Promise<info> (reloads requested by SABR)
    this.reloads = new Map();   // videoId -> [ms] recent reloads (rate limit)
    this.notYet = new Map();    // videoId -> {at, err}: recent upcoming/offline answers
    this.pruneDisk();
  }

  // ---- Innertube session ------------------------------------------------------------------

  async session(): Promise<Innertube> {
    if (this.yt && Date.now() - this.ytCreated < SESSION_MAX_AGE_MS) return this.yt;   // fresh
    if (!this.ytInflight) {
      if (!this.yt && Date.now() < this.ytNextTry) {
        throw new YouTubeError(`YouTube session unavailable (${this.ytError}); retry in ${Math.ceil((this.ytNextTry - Date.now()) / 1000)} s`, { unanswered: true });
      }
      this.ytInflight = (async () => {
        const t0 = performance.now();
        try {
          const { Innertube, UniversalCache, Platform, Log } = await import('youtubei.js');
          Log.setLevel(Log.Level.ERROR);
          // youtubei.js 18 ships no JS evaluator for node; the n/sig transforms need one.
          Platform.shim.eval = async (data) => new Function(data.output)() as Record<string, unknown> | undefined; // eslint-disable-line no-new-func
          const yt = await withTimeout(Innertube.create({
            cache: new UniversalCache(true, path.join(this.stateDir, 'ytjs-cache')), // visitorData + player.js
            retrieve_player: true,
            user_agent: this.identity.userAgent, // the one browser identity (identity.ts), also BotGuard's
            lang: LANG, location: LOCATION, timezone: TIMEZONE,
          }), SESSION_TIMEOUT_MS, 'Innertube session');
          if (!yt.session.player) throw new Error('no player script');
          this.yt = yt;
          this.ytCreated = Date.now();
          this.ytState = 'ready';
          this.ytRetryMs = SESSION_RETRY_MIN_MS;
          this.ytError = null;
          log(`session ready in ${(performance.now() - t0).toFixed(0)} ms: client=${yt.session.context.client.clientName}/${yt.session.context.client.clientVersion} `
            + `player=${yt.session.player.player_id} sts=${yt.session.player.signature_timestamp} `
            + `visitorData=${(yt.session.context.client.visitorData || '').slice(0, 12)}...`);
          return yt;
        } catch (e) {
          this.ytError = errorMessage(e);
          this.ytNextTry = Date.now() + this.ytRetryMs;
          this.ytRetryMs = Math.min(SESSION_RETRY_MAX_MS, this.ytRetryMs * 2);
          if (!this.yt) this.ytState = 'error';
          log('session setup failed:', errorMessage(e));
          if (this.yt) return this.yt; // keep using the old session
          throw new YouTubeError(`YouTube session unavailable: ${errorMessage(e)}`, { unanswered: true });
        } finally {
          this.ytInflight = null;
        }
      })();
    }
    return this.ytInflight;
  }

  warm(): void { this.session().catch(() => {}); }

  get sessionState(): SessionState { return this.ytState; }

  // ---- player requests --------------------------------------------------------------------

  /**
   * Info for `videoId`, from the cache when still valid for REUSE_MARGIN_S, else one player request.
   * `bg`: background request -> refused while the bot-check breaker is open.
   * Concurrent calls for the same video share one request.
   */
  async info(videoId: string, { bg = false }: { bg?: boolean } = {}): Promise<{ info: VideoInfo; cached: boolean }> {
    const c = this.cached(videoId);
    if (c) return { info: c, cached: true };
    const ny = this.notYet.get(videoId);
    if (ny && Date.now() - ny.at < UPCOMING_CACHE_MS) throw ny.err;
    const pending = this.inflight.get(videoId);
    if (pending) return { info: await pending, cached: false };
    if (bg) {
      const until = this.breaker.blockedUntil();
      if (until) throw new YouTubeError("Sign in to confirm you're not a bot (paused, no request sent)", { bot: true });
    }
    const p = this.request(videoId, null).finally(() => this.inflight.delete(videoId));
    this.inflight.set(videoId, p);
    return { info: await p, cached: false };
  }

  cached(videoId: string): VideoInfo | null {
    let c = this.cache.get(videoId) ?? null;
    if (!c) {
      try {
        const j = parseJson(fs.readFileSync(this.cacheFile(videoId), 'utf8'));
        if (isVideoInfo(j, videoId)) { c = j; this.cache.set(videoId, c); }
        else if (isRecord(j) && j.id === videoId) this.forget(videoId);   // unusable (as if expired)
      } catch { c = null; }
    }
    if (c && c.expires - Date.now() / 1000 > REUSE_MARGIN_S) return c;
    if (c) this.forget(videoId);
    return null;
  }

  forget(videoId: string): void {
    this.cache.delete(videoId);
    try { fs.unlinkSync(this.cacheFile(videoId)); } catch { /* not cached */ }
  }

  cacheFile(videoId: string): string { return path.join(this.playerDir, `${videoId}.json`); }

  pruneDisk(): void {
    const now = Date.now() / 1000;
    try {
      for (const f of fs.readdirSync(this.playerDir)) {
        const p = path.join(this.playerDir, f);
        try {
          const c = parseJson(fs.readFileSync(p, 'utf8'));
          if (!(Number(record(c).expires) > now)) fs.unlinkSync(p);
        } catch { try { fs.unlinkSync(p); } catch { /* gone */ } }
      }
    } catch { /* no dir */ }
  }

  /**
   * One player request (+ decipher with the same player). `reloadContext`: SABR asked for a reload
   * (RELOAD_PLAYER_RESPONSE / expired URL).
   */
  async request(videoId: string, reloadContext: ReloadPlaybackContext | null): Promise<VideoInfo> {
    const yt = await this.session();
    const player = yt.session.player; // pinned: sts in the request and decipher must match
    if (!player) throw new YouTubeError('no player script');   // session() refuses sessions without one
    let poToken: string;
    try {
      poToken = await this.po.mintString(videoId);
    } catch (e) {
      throw new YouTubeError(`PO token unavailable: ${errorMessage(e)}`, { unanswered: true });
    }
    const n = this.budget.take(reloadContext ? `reload ${videoId}` : `player ${videoId}`);
    const payload: PlayerRequest = {
      videoId, racyCheckOk: true, contentCheckOk: true,
      playbackContext: { contentPlaybackContext: { vis: 0, splay: false, lactMilliseconds: '-1',
        signatureTimestamp: player.signature_timestamp } },
      serviceIntegrityDimensions: { poToken },
      client: 'WEB',
      parse: false,
    };
    if (reloadContext) payload.playbackContext.reloadPlaybackContext = reloadContext;
    const t0 = performance.now();
    let raw: RawPlayerResponse;
    try {
      raw = asPlayerResponse((await withTimeout(yt.actions.execute('/player', payload), PLAYER_TIMEOUT_MS, 'player request')).data);
    } catch (e) {
      const bot = isBotCheck(errorMessage(e));
      if (bot) this.breaker.note(true);
      throw new YouTubeError(`player request failed: ${errorMessage(e)}`, { bot, unanswered: !bot });
    }
    const ms = performance.now() - t0;
    const ps = raw.playabilityStatus || {};
    const reason = [ps.reason, ps.errorScreen?.playerErrorMessageRenderer?.subreason?.simpleText,
      (ps.errorScreen?.playerErrorMessageRenderer?.subreason?.runs || []).map((r) => r.text).join('')]
      .filter(Boolean).join(' - ');
    log(`player request #${n} ${videoId}: ${ps.status || '?'}${reason ? ` (${reason})` : ''} in ${ms.toFixed(0)} ms`);
    const cls = classifyPlayer(raw);
    if (cls.kind === 'upcoming' || cls.kind === 'offline') {
      // a valid answer (not a bot check); scheduled lives/premieres are not playable yet
      this.breaker.note(false);
      const err = cls.kind === 'upcoming'
        ? new YouTubeError('upcoming', { live: true, upcoming: true, startTime: cls.startTime, status: ps.status })
        : new YouTubeError('offline', { live: true, status: ps.status });
      this.notYet.set(videoId, { at: Date.now(), err });
      throw err;
    }
    if (ps.status !== 'OK') {
      const bot = isBotCheck(reason) || (ps.status === 'LOGIN_REQUIRED' && /bot/i.test(reason));
      this.breaker.note(bot);
      throw new YouTubeError(reason || ps.status || 'unplayable', { bot, status: ps.status });
    }
    this.breaker.note(false);
    const vd = raw.videoDetails || {};
    const sd = raw.streamingData || {};
    if (cls.kind === 'live' || cls.kind === 'postlive') {
      return this.store(await this.liveInfo(videoId, raw, { player, poToken, client: yt.session.context.client, live: cls.kind === 'live' }));
    }
    if (!sd.serverAbrStreamingUrl) throw new YouTubeError('no SABR streaming URL in player response');
    const ustreamer = raw.playerConfig?.mediaCommonConfig?.mediaUstreamerRequestConfig?.videoPlaybackUstreamerConfig;
    if (!ustreamer) throw new YouTubeError('no ustreamer config in player response');
    let sabrUrl: string;
    try {
      sabrUrl = await withTimeout(player.decipher(sd.serverAbrStreamingUrl), 15000, 'decipher');
    } catch (e) {
      throw new YouTubeError(`decipher failed: ${errorMessage(e)}`);
    }
    const expireParam = Number(new URL(sabrUrl).searchParams.get('expire'));
    const info: VodInfo = {
      id: videoId,
      title: vd.title || '',
      author: vd.author || '',
      durationMs: Number(vd.lengthSeconds || 0) * 1000,
      expires: expireParam || Math.floor(Date.now() / 1000) + Number(sd.expiresInSeconds || 0),
      sabrUrl,
      ustreamer,
      clientName: 1, // WEB
      clientVersion: yt.session.context.client.clientVersion,
      playerId: player.player_id,
      formats: sd.adaptiveFormats || [],
      captions: raw.captions || null,
      endscreen: endscreenElements(raw),
      fetchedAt: Math.floor(Date.now() / 1000),
      published: publishedOf(raw),
    };
    return this.store(info);
  }

  store(info: VideoInfo): VideoInfo {
    this.cache.set(info.id, info);
    try { fs.writeFileSync(this.cacheFile(info.id), JSON.stringify(info)); } catch (e) { log('cannot cache player response:', errorMessage(e)); }
    return info;
  }

  /**
   * Live / post-live DVR: the HLS manifest of the same response, prepared like yt-dlp does it for
   * web clients - the n challenge in the URL path solved with the SAME player as the request,
   * the PO token appended as `/pot/<token>` (both propagate into every segment URL). Measured
   * 2026-11-05 (DW News, LuKwFajn37U): without the n transform every segment answers 403; with
   * it (with or without pot) segments play.
   */
  async liveInfo(videoId: string, raw: RawPlayerResponse,
    { player, poToken, client, live }: { player: Player; poToken: string; client: InnertubeClient; live: boolean }): Promise<HlsInfo> {
    const vd = raw.videoDetails || {};
    const sd = raw.streamingData || {};
    if (!sd.hlsManifestUrl) throw new YouTubeError(`${live ? 'live' : 'post-live'} without HLS manifest`, { live: true });
    let hlsUrl: string;
    try {
      hlsUrl = await withTimeout(prepareManifestUrl(sd.hlsManifestUrl, {
        poToken,
        solve: async (n: string) => new URL(await player.decipher(`https://rr1---sn-x.googlevideo.com/videoplayback?n=${encodeURIComponent(n)}`)).searchParams.get('n'),
      }), 15000, 'decipher');
    } catch (e) {
      throw new YouTubeError(`decipher failed: ${errorMessage(e)}`, { live: true });
    }
    return {
      id: videoId,
      kind: 'hls',
      live,
      postLiveDvr: !live,
      title: vd.title || '',
      author: vd.author || '',
      durationMs: live ? 0 : Number(vd.lengthSeconds || 0) * 1000,
      expires: pathExpire(hlsUrl) || Math.floor(Date.now() / 1000) + Number(sd.expiresInSeconds || 0),
      hlsUrl,
      clientName: 1,
      clientVersion: client.clientVersion,
      playerId: player.player_id,
      captions: live ? null : raw.captions || null,   // live captions are in-band (608) or none
      endscreen: [],
      fetchedAt: Math.floor(Date.now() / 1000),
      published: publishedOf(raw),
    };
  }

  /**
   * googlevideo onReloadPlayerResponse: fresh URL + ustreamer config (costs a player request).
   * Guarded like info() (review 2026-11-05: every pump of every session could reload on its own,
   * ignoring the breaker): concurrent reloads of a video share one request, a response fetched
   * in the last RELOAD_FRESH_S is reused, at most RELOAD_MAX per video per RELOAD_WINDOW_S, and
   * background sessions send nothing while the breaker is open.
   */
  async reload(videoId: string, reloadContext?: ReloadPlaybackContext | null, { bg = false }: { bg?: boolean } = {}): Promise<ReloadResponse> {
    const info = await this.refresh(videoId, reloadContext, { bg });
    if (info.kind === 'hls') throw new YouTubeError(`${videoId} turned into a live stream`, { live: true });   // SABR is VOD only
    return { serverAbrStreamingUrl: info.sabrUrl, videoPlaybackUstreamerConfig: info.ustreamer };
  }

  /** Fresh info with the guards of reload() (also used by live sessions to renew the manifest URL). */
  async refresh(videoId: string, reloadContext: ReloadPlaybackContext | null = null, { bg = false }: { bg?: boolean } = {}): Promise<VideoInfo> {
    const recent = this.cache.get(videoId);
    if (recent && Date.now() / 1000 - (recent.fetchedAt || 0) < RELOAD_FRESH_S) return recent;
    const pending = this.reloading.get(videoId);
    if (pending) return pending;
    if (bg && this.breaker.blockedUntil()) throw new YouTubeError("Sign in to confirm you're not a bot (paused, no reload sent)", { bot: true });
    const now = Date.now();
    const times = (this.reloads.get(videoId) || []).filter((t) => now - t < RELOAD_WINDOW_S * 1000);
    if (times.length >= RELOAD_MAX) throw new YouTubeError(`reload limit reached for ${videoId}`);
    times.push(now);
    this.reloads.set(videoId, times);
    const p = this.request(videoId, reloadContext || null).finally(() => this.reloading.delete(videoId));
    this.reloading.set(videoId, p);
    return p;
  }

  /** Memory bound for a process that runs for weeks: drop expired and least recently stored responses. */
  prune(max = 64): void {
    const now = Date.now() / 1000;
    for (const [id, c] of this.cache) if (c.expires <= now) this.cache.delete(id);
    while (this.cache.size > max) this.cache.delete(this.cache.keys().next().value!);
    for (const [id, ny] of this.notYet) if (Date.now() - ny.at >= UPCOMING_CACHE_MS) this.notYet.delete(id);
    for (const [id, times] of this.reloads) if (!times.some((t) => Date.now() - t < RELOAD_WINDOW_S * 1000)) this.reloads.delete(id);
  }

  // ---- InnerTube calls for the app -------------------------------------------------------------

  /**
   * One InnerTube call of the app (channel pages, feeds, search, watch page) in this session - the
   * same identity, visitor data and cookies as playback, instead of a second client of its own.
   * Raw JSON answer. `bg`: a background refresh, refused while the bot-check breaker is open.
   */
  async innertube(endpoint: AppEndpoint, body: Record<string, unknown>, { bg = false }: { bg?: boolean } = {}): Promise<unknown> {
    if (bg && this.breaker.blockedUntil()) throw new YouTubeError("Sign in to confirm you're not a bot (paused, nothing sent)", { bot: true });
    const yt = await this.session();
    const r = await withTimeout(yt.actions.execute(`/${endpoint}`, { ...body, parse: false }), PLAYER_TIMEOUT_MS, endpoint);
    return r.data;
  }

  /** Headers that make a plain fetch (captions) look like this session's web player. */
  async webHeaders(): Promise<Record<string, string>> {
    const yt = await this.session();
    const c = yt.session.context.client;
    return {
      ...this.identity.headers,
      origin: 'https://www.youtube.com',
      referer: 'https://www.youtube.com/',
      ...(c.visitorData ? { 'x-goog-visitor-id': c.visitorData } : {}),
    };
  }
}
