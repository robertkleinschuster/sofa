// Live streams and post-live DVR recordings: the WEB player response's HLS manifest, deciphered
// with the same player as the request (n in the URL *path*), PO token as `/pot/<token>` path segment
// (yt-dlp's recipe), served by the engine as ONE media playlist per session.
//
// Why HLS and not live SABR (research 2026-11-05, docs/sofa-yt.md "Lives"): googlevideo 5.0.1 can
// pull live SABR, but its segments are self-initializing fragments without byte positions or a
// content length - mpv would need a growing stream or a locally generated playlist. YouTube's own
// HLS manifest is exactly that playlist, muxed (one TS stream, audio included), and the variant
// playlists keep the deciphered n and the token in every segment URL. mpv fetches the segments
// directly from googlevideo; only the small playlists pass through here.
//
// The engine keeps the playlist alive: the variant playlist is fetched fresh on every mpv reload
// (with a 1 s micro cache), the manifest URL is renewed through the guarded player request path
// (YouTube#refresh: breaker, reload limit, budget) shortly before it expires or when YouTube
// rejects it, and the session fails after MAX_FAILURES consecutive failed fetches (Sofa then
// reopens it; one that fails again right away ends in a message). #EXT-X-ENDLIST from upstream = the broadcast ended
// (`ended` in /status: a real end, not an error).
import { randomHex } from './bytes.ts';
import { errorMessage } from './errors.ts';
import { log, debug } from './log.ts';
import type { SubtitleTrack } from './formats.ts';
import type { MediaCounters } from './session.ts';
import type { HlsInfo, VideoInfo } from './youtube.ts';

export interface HlsConfig {
  FETCH_TIMEOUT_MS: number;
  MICRO_CACHE_MS: number;
  RENEW_BEFORE_S: number;
  MAX_FAILURES: number;
  RENEW_RETRY_MS: number;
}

export const HLS_DEFAULTS: HlsConfig = {
  FETCH_TIMEOUT_MS: 10000,
  MICRO_CACHE_MS: 1000,       // mpv may ask twice in a row (reconnect): no second upstream fetch
  RENEW_BEFORE_S: 10 * 60,    // renew the manifest URL this long before its expire
  MAX_FAILURES: 3,            // consecutive failed playlist fetches -> session failed
  RENEW_RETRY_MS: 60000,      // a failed early renewal is retried after this long
};

/** The `n` challenge in a manifest URL path (`.../n/<value>/...`), or null. */
export function pathN(url: string): string | null {
  const m = /\/n\/([^/]+)\//.exec(new URL(url).pathname);
  return m ? m[1]! : null;
}

/**
 * The manifest URL as the player would request it: path `n` replaced by `solve(n)` (async, the
 * pinned player's n transform), the PO token appended as a path segment before `/file/index.m3u8`.
 * Throws when the n challenge could not be solved (googlevideo would answer 403 on every segment).
 */
export async function prepareManifestUrl(url: string,
  { solve, poToken }: { solve?: (n: string) => Promise<string | null>; poToken?: string } = {}): Promise<string> {
  const u = new URL(url);
  const n = pathN(url);
  if (n) {
    const solved = solve ? await solve(n) : null;
    if (!solved || solved === n) throw new Error('n challenge of the HLS manifest not solved');
    u.pathname = u.pathname.replace(`/n/${n}/`, `/n/${solved}/`);
  }
  if (poToken) {
    const m = /^(.+?)(\/(?:file|playlist)\/index\.m3u8)$/.exec(u.pathname);
    const p = m ? m[1]! : u.pathname;
    u.pathname = `${p.replace(/\/+$/, '')}/pot/${encodeURIComponent(poToken)}${m ? m[2]! : ''}`;
  }
  return u.toString();
}

/** `expire` of a path-style manifest URL (epoch seconds) or 0. */
export function pathExpire(url: string): number {
  try {
    const u = new URL(url);
    const m = /\/expire\/(\d+)(\/|$)/.exec(u.pathname);
    return m ? Number(m[1]) : Number(u.searchParams.get('expire')) || 0;
  } catch { return 0; }
}

function parseAttrs(s: string): Record<string, string> {
  const out: Record<string, string> = {};
  const re = /([A-Z0-9-]+)=("[^"]*"|[^,]*)/g;
  let m;
  while ((m = re.exec(s))) out[m[1]!] = m[2]!.startsWith('"') ? m[2]!.slice(1, -1) : m[2]!;
  return out;
}

/** One variant of a master playlist (absolute URL). itag null when the URL carries none. */
export interface Variant {
  url: string;
  bandwidth: number;
  width: number;
  height: number;
  fps: number;
  codecs: string;
  itag: number | null;
}

/** Variants of a master playlist: [{url, bandwidth, width, height, fps, codecs, itag}] (absolute URLs). */
export function parseMaster(text: string, base: string): Variant[] {
  const lines = String(text).split(/\r?\n/);
  const out: Variant[] = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;
    if (!line.startsWith('#EXT-X-STREAM-INF:')) continue;
    const a = parseAttrs(line.slice('#EXT-X-STREAM-INF:'.length));
    let j = i + 1;
    while (j < lines.length && (!lines[j]!.trim() || lines[j]!.startsWith('#'))) j++;
    if (j >= lines.length) break;
    const url = new URL(lines[j]!.trim(), base).toString();
    const [w, h] = (a.RESOLUTION || '').split('x').map(Number);
    const itag = Number((/\/itag\/(\d+)\//.exec(url) || [])[1]) || null;
    out.push({ url, bandwidth: Number(a.BANDWIDTH) || 0, width: w || 0, height: h || 0, fps: Math.round(Number(a['FRAME-RATE']) || 0), codecs: a.CODECS || '', itag });
    i = j;
  }
  return out;
}

/** Best variant within maxHeight (height, then fps, then bandwidth); the smallest one if none fits. */
export function pickVariant(variants: Variant[], maxHeight: number, preferItag: number | null = null): Variant | null {
  if (!variants.length) return null;
  if (preferItag) {
    const same = variants.find((v) => v.itag === preferItag);
    if (same) return same;
  }
  const rank = (a: Variant, b: Variant): number => (a.height - b.height) || (a.fps - b.fps) || (a.bandwidth - b.bandwidth);
  const fit = variants.filter((v) => v.height && v.height <= maxHeight).sort(rank);
  if (fit.length) return fit[fit.length - 1]!;
  return [...variants].sort(rank)[0]!;
}

/** A media playlist with every URI made absolute (it is served from 127.0.0.1). */
export function absolutize(text: string, base: string): string {
  return String(text).split(/\r?\n/).map((l) => {
    if (!l.trim()) return l;
    if (!l.startsWith('#')) return new URL(l.trim(), base).toString();
    // URI="..." attributes (EXT-X-MAP, EXT-X-KEY)
    return l.replace(/URI="([^"]+)"/g, (_m, u: string) => `URI="${new URL(u, base).toString()}"`);
  }).join('\n');
}

export const codecShort = (codecs: string | undefined): string | null => {
  const v = String(codecs).split(',').map((c) => c.trim()).find((c) => /^(avc1|vp09|av01|hvc1|hev1)/.test(c)) || '';
  return v.startsWith('vp09') ? 'vp9' : v.split('.')[0] || null;
};

class HttpError extends Error {
  status: number;
  constructor(status: number) { super(`HTTP ${status}`); this.status = status; }
}

/** /s/<sid>/status of a live session. */
export interface LiveStatus {
  sid: string;
  id: string;
  kind: 'hls';
  live: boolean;
  postLiveDvr: boolean;
  ended: boolean;
  failed: string | null;
  failures: number;
  renewals: number;
  playlistFetches: number;
  lastOkAgoMs: number | null;
  variant: Pick<Variant, 'itag' | 'height' | 'fps' | 'codecs'> | null;
  expires: number;
  idleMs: number;
}

/** The upstream fetch LiveSession needs (global fetch, or a fake in tests). */
export type PlaylistFetch = (url: string, init: { headers: Record<string, string>; signal: AbortSignal; redirect: 'follow' })
  => Promise<{ ok: boolean; status: number; url: string; text(): Promise<string> }>;

export interface LiveSessionOptions {
  info: HlsInfo;                                    // youtube.ts info with `hlsUrl`
  maxHeight: number;
  refresh: (why: string) => Promise<VideoInfo>;     // fresh info (guarded player request)
  fetchFn?: PlaylistFetch;
  headers?: () => Promise<Record<string, string>> | Record<string, string>;   // web-player headers for playlist fetches
  subs?: SubtitleTrack[];
  cfg?: Partial<HlsConfig>;
}

/**
 * One opened live/post-live stream. Shares the fields the engine uses for sessions of either kind
 * (sid, info, closed, failed, lastActivity, everRead, lastReadAt, activeReaders, fetched, runs,
 * bytes, subs, subCache, close(), status()).
 */
export class LiveSession {
  readonly kind: 'hls';
  sid: string;
  info: HlsInfo;
  maxHeight: number;
  lang: string | null;
  refreshInfo: (why: string) => Promise<VideoInfo>;
  fetchFn: PlaylistFetch;
  headers: () => Promise<Record<string, string>> | Record<string, string>;
  cfg: HlsConfig;
  subs: SubtitleTrack[];
  subCache: Map<string, string>;
  variant: Variant | null;
  variants: Variant[];
  closed: boolean;
  failed: Error | null;
  ended: boolean;
  failures: number;
  renewals: number;
  renewFailedAt: number;
  playlistFetches: number;
  lastOkAt: number;
  lastActivity: number;
  everRead: boolean;
  lastReadAt: number;
  activeReaders: number;
  fetched: MediaCounters;
  runs: number;
  bytes: number;
  cache: { at: number; body: string } | null;
  inflight: Promise<string> | null;

  constructor({ info, maxHeight, refresh, fetchFn = fetch, headers = () => ({}), subs = [], cfg = {} }: LiveSessionOptions) {
    this.kind = 'hls';
    this.sid = randomHex(8);
    this.info = info;
    this.maxHeight = maxHeight;
    this.lang = null;
    this.refreshInfo = refresh;
    this.fetchFn = fetchFn;
    this.headers = headers;
    this.cfg = { ...HLS_DEFAULTS, ...cfg };
    this.subs = subs;
    this.subCache = new Map();
    this.variant = null;        // chosen {url, itag, height, fps, codecs}
    this.variants = [];
    this.closed = false;
    this.failed = null;
    this.ended = false;
    this.failures = 0;
    this.renewals = 0;
    this.renewFailedAt = 0;
    this.playlistFetches = 0;
    this.lastOkAt = 0;
    this.lastActivity = Date.now();
    this.everRead = false;
    this.lastReadAt = 0;
    this.activeReaders = 0;      // playlist requests are short: never "in use" by an open response
    this.fetched = { video: { ms: 0, bytes: 0 }, audio: { ms: 0, bytes: 0 } }; // media goes mpv <-> googlevideo directly
    this.runs = 0;
    this.bytes = 0;
    this.cache = null;           // {at, body}
    this.inflight = null;        // shared upstream fetch of the variant playlist
  }

  get tag(): string { return `live ${this.sid.slice(0, 6)} ${this.info.id}`; }

  async fetchText(url: string): Promise<{ body: string; url: string }> {
    const headers = await this.headers();
    const r = await this.fetchFn(url, { headers, signal: AbortSignal.timeout(this.cfg.FETCH_TIMEOUT_MS), redirect: 'follow' });
    if (!r.ok) throw new HttpError(r.status);
    const body = await r.text();
    if (!body.startsWith('#EXTM3U')) throw new Error('not a playlist');
    return { body, url: r.url || url };
  }

  /** Master playlist -> variant choice (keeps the itag across renewals). Called by /open. */
  async choose(): Promise<Variant | null> {
    const { body, url } = await this.fetchText(this.info.hlsUrl);
    const variants = parseMaster(body, url);
    if (!variants.length) {
      // a media playlist served directly (no variants): play it as is
      this.variants = [];
      this.variant = { url: this.info.hlsUrl, bandwidth: 0, width: 0, height: 0, fps: 0, codecs: '', itag: null };
      return this.variant;
    }
    this.variants = variants;
    this.variant = pickVariant(variants, this.maxHeight, this.variant?.itag);
    return this.variant;
  }

  /** Fresh manifest URL (guarded player request), then the same variant again. */
  async renew(why: string): Promise<void> {
    this.renewals++;
    log(`${this.tag}: renewing the manifest URL (${why})`);
    const info = await this.refreshInfo(why);
    const hlsUrl = info?.kind === 'hls' ? info.hlsUrl : undefined;
    if (!hlsUrl) throw new Error('no HLS manifest after renewal');
    this.info.hlsUrl = hlsUrl;
    this.info.expires = info.expires;
    await this.choose();
  }

  /** The media playlist for mpv: upstream variant, absolute URIs. Self-heals expired/rejected URLs. */
  async playlist(): Promise<string> {
    if (this.failed) throw this.failed;
    this.lastActivity = Date.now();
    this.everRead = true;
    this.lastReadAt = Date.now();
    if (this.cache && Date.now() - this.cache.at < this.cfg.MICRO_CACHE_MS) return this.cache.body;
    if (!this.inflight) {
      this.inflight = this.fetchPlaylist().finally(() => { this.inflight = null; });
    }
    return this.inflight;
  }

  async fetchPlaylist(): Promise<string> {
    let renewed = false;
    try {
      if (!this.variant) await this.choose();
      const left = this.info.expires ? this.info.expires - Date.now() / 1000 : Infinity;
      if (left < this.cfg.RENEW_BEFORE_S && Date.now() - this.renewFailedAt > this.cfg.RENEW_RETRY_MS) {
        // best effort while the old URL still works: a refused renewal (limit, breaker) is retried
        // a minute later, not on every playlist reload
        try { await this.renew('URL expires soon'); renewed = true; } catch (e) {
          this.renewFailedAt = Date.now();
          log(`${this.tag}: renewal failed: ${errorMessage(e)}`);
          if (left <= 0) throw e;
        }
      }
      let res;
      try {
        res = await this.fetchText(this.variant!.url);   // choose() always sets a variant
      } catch (e) {
        // 403/404/410: URL rejected or expired -> one renewal (if not just done) and one more try
        if (renewed || !(e instanceof HttpError) || ![403, 404, 410].includes(e.status)) throw e;
        await this.renew(`variant playlist ${e.message}`); renewed = true;
        res = await this.fetchText(this.variant!.url);
      }
      this.playlistFetches++;
      this.failures = 0;
      this.lastOkAt = Date.now();
      const ended = /^#EXT-X-ENDLIST/m.test(res.body);
      if (ended && !this.ended && this.info.live) log(`${this.tag}: broadcast ended (EXT-X-ENDLIST)`);
      this.ended = ended;
      const body = absolutize(res.body, res.url);
      this.cache = { at: Date.now(), body };
      debug(`${this.tag}: playlist ok (${body.length} bytes${ended ? ', ended' : ''})`);
      return body;
    } catch (e) {
      this.failures++;
      log(`${this.tag}: playlist fetch failed (${this.failures}/${this.cfg.MAX_FAILURES}): ${errorMessage(e)}`);
      if (this.failures >= this.cfg.MAX_FAILURES) {
        this.failed = new Error(`live playlist unavailable: ${errorMessage(e)}`);
        log(`${this.tag}: giving up`);
      }
      throw e;
    }
  }

  close(why = 'closed'): void {
    if (this.closed) return;
    this.closed = true;
    this.cache = null;
    this.subCache.clear();
    log(`${this.tag}: closed (${why})`);
  }

  status(): LiveStatus {
    return {
      sid: this.sid, id: this.info.id, kind: 'hls', live: !!this.info.live, postLiveDvr: !!this.info.postLiveDvr,
      ended: this.ended, failed: this.failed?.message || null, failures: this.failures, renewals: this.renewals,
      playlistFetches: this.playlistFetches, lastOkAgoMs: this.lastOkAt ? Date.now() - this.lastOkAt : null,
      variant: this.variant && { itag: this.variant.itag, height: this.variant.height, fps: this.variant.fps, codecs: this.variant.codecs },
      expires: this.info.expires, idleMs: Date.now() - this.lastActivity,
    };
  }
}
