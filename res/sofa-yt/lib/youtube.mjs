// One consistent YouTube web-player identity: a persistent Innertube session (visitorData, user
// agent and player script cached in the state dir), WEB-client player requests with a video-bound
// PO token, and a per-video cache of the deciphered result so that reopening / seeking / restarting
// SABR never costs another player request while the URLs are valid.
//
// GOTCHA (spike): YouTube A/B-serves several player.js versions. The n-parameter of
// serverAbrStreamingUrl must be transformed with the SAME player whose signatureTimestamp went into
// the player request, otherwise SABR answers 403. Hence the player object is captured before the
// request and used for deciphering right after it; only the deciphered URL is cached.
import fs from 'node:fs';
import path from 'node:path';
import { isBotCheck } from './breaker.mjs';
import { log } from './log.mjs';

const SESSION_TIMEOUT_MS = 30000;
const PLAYER_TIMEOUT_MS = 20000;
const SESSION_MAX_AGE_MS = 6 * 3600 * 1000;   // pick up player.js rotations now and then
const REUSE_MARGIN_S = 15 * 60;                // a cached response must stay valid this long
const SESSION_RETRY_MIN_MS = 30 * 1000;
const SESSION_RETRY_MAX_MS = 10 * 60 * 1000;

export class YouTubeError extends Error {
  constructor(message, { bot = false, live = false, status = null } = {}) {
    super(message);
    this.bot = bot;
    this.live = live;
    this.status = status;
  }
}

function withTimeout(p, ms, what) {
  let t;
  return Promise.race([p, new Promise((_, rej) => { t = setTimeout(() => rej(new Error(`${what} timed out`)), ms); })])
    .finally(() => clearTimeout(t));
}

/**
 * Optional hard cap on player requests (safety net against loops): at most `max` requests within
 * `windowS` seconds (windowS = 0: lifetime of the counter file). Persisted, survives restarts.
 */
export class PlayerBudget {
  constructor({ file = null, max = Infinity, windowS = 3600 } = {}) {
    this.file = file; this.max = max; this.windowS = windowS; this.mem = [];
  }

  load() {
    if (!this.file) return this.mem;
    try { return JSON.parse(fs.readFileSync(this.file, 'utf8')); } catch { return []; }
  }

  take(why) {
    const now = Date.now();
    let b = this.load();
    if (this.windowS > 0) b = b.filter((e) => now - Date.parse(e.at) < this.windowS * 1000);
    if (b.length >= this.max) {
      throw new YouTubeError(`player-request budget exhausted (${b.length}/${this.max}) - refusing (${why})`);
    }
    b.push({ at: new Date(now).toISOString(), why });
    this.mem = b;
    if (this.file) {
      try { fs.writeFileSync(this.file, JSON.stringify(b, null, 1)); } catch (e) { log('budget: cannot write', e.message); }
    }
    return b.length;
  }
}

export class YouTube {
  /**
   * @param {object} o
   * @param {string} o.stateDir
   * @param {import('./breaker.mjs').Breaker} o.breaker
   * @param {import('./webpo.mjs').PoTokenProvider} o.po
   * @param {PlayerBudget} [o.budget]
   */
  constructor({ stateDir, breaker, po, budget = new PlayerBudget() }) {
    this.stateDir = stateDir;
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
    this.pruneDisk();
  }

  // ---- Innertube session ------------------------------------------------------------------

  async session() {
    const fresh = this.yt && Date.now() - this.ytCreated < SESSION_MAX_AGE_MS;
    if (fresh) return this.yt;
    if (!this.ytInflight) {
      if (!this.yt && Date.now() < this.ytNextTry) {
        throw new YouTubeError(`YouTube session unavailable (${this.ytError}); retry in ${Math.ceil((this.ytNextTry - Date.now()) / 1000)} s`);
      }
      this.ytInflight = (async () => {
        const t0 = performance.now();
        try {
          const { Innertube, UniversalCache, Platform, Log } = await import('youtubei.js');
          const { USER_AGENT } = await import('bgutils-js/utils');
          Log.setLevel(Log.Level.ERROR);
          // youtubei.js 18 ships no JS evaluator for node; the n/sig transforms need one.
          Platform.shim.eval = async (data) => new Function(data.output)(); // eslint-disable-line no-new-func
          const yt = await withTimeout(Innertube.create({
            cache: new UniversalCache(true, path.join(this.stateDir, 'ytjs-cache')), // visitorData + player.js
            retrieve_player: true,
            user_agent: USER_AGENT, // same browser identity as the BotGuard/WebPO side
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
          this.ytError = e.message;
          this.ytNextTry = Date.now() + this.ytRetryMs;
          this.ytRetryMs = Math.min(SESSION_RETRY_MAX_MS, this.ytRetryMs * 2);
          if (!this.yt) this.ytState = 'error';
          log('session setup failed:', e.message);
          if (this.yt) return this.yt; // keep using the old session
          throw new YouTubeError(`YouTube session unavailable: ${e.message}`);
        } finally {
          this.ytInflight = null;
        }
      })();
    }
    return this.ytInflight;
  }

  warm() { this.session().catch(() => {}); }

  get sessionState() { return this.ytState; }

  // ---- player requests --------------------------------------------------------------------

  /**
   * Info for `videoId`, from the cache when still valid for REUSE_MARGIN_S, else one player request.
   * `bg`: background request -> refused while the bot-check breaker is open.
   * Concurrent calls for the same video share one request.
   */
  async info(videoId, { bg = false } = {}) {
    const c = this.cached(videoId);
    if (c) return { info: c, cached: true };
    if (this.inflight.has(videoId)) return { info: await this.inflight.get(videoId), cached: false };
    if (bg) {
      const until = this.breaker.blockedUntil();
      if (until) throw new YouTubeError("Sign in to confirm you're not a bot (paused, no request sent)", { bot: true });
    }
    const p = this.request(videoId, null).finally(() => this.inflight.delete(videoId));
    this.inflight.set(videoId, p);
    return { info: await p, cached: false };
  }

  cached(videoId) {
    let c = this.cache.get(videoId);
    if (!c) {
      try {
        c = JSON.parse(fs.readFileSync(this.cacheFile(videoId), 'utf8'));
        if (c && c.id === videoId) this.cache.set(videoId, c); else c = null;
      } catch { c = null; }
    }
    if (c && c.expires - Date.now() / 1000 > REUSE_MARGIN_S) return c;
    if (c) this.forget(videoId);
    return null;
  }

  forget(videoId) {
    this.cache.delete(videoId);
    try { fs.unlinkSync(this.cacheFile(videoId)); } catch { /* not cached */ }
  }

  cacheFile(videoId) { return path.join(this.playerDir, `${videoId}.json`); }

  pruneDisk() {
    const now = Date.now() / 1000;
    try {
      for (const f of fs.readdirSync(this.playerDir)) {
        const p = path.join(this.playerDir, f);
        try {
          const c = JSON.parse(fs.readFileSync(p, 'utf8'));
          if (!(c.expires > now)) fs.unlinkSync(p);
        } catch { try { fs.unlinkSync(p); } catch { /* gone */ } }
      }
    } catch { /* no dir */ }
  }

  /**
   * One player request (+ decipher with the same player). `reloadContext`: SABR asked for a reload
   * (RELOAD_PLAYER_RESPONSE / expired URL).
   */
  async request(videoId, reloadContext) {
    const yt = await this.session();
    const player = yt.session.player; // pinned: sts in the request and decipher must match
    let poToken;
    try {
      poToken = await this.po.mintString(videoId);
    } catch (e) {
      throw new YouTubeError(`PO token unavailable: ${e.message}`);
    }
    const n = this.budget.take(reloadContext ? `reload ${videoId}` : `player ${videoId}`);
    const payload = {
      videoId, racyCheckOk: true, contentCheckOk: true,
      playbackContext: { contentPlaybackContext: { vis: 0, splay: false, lactMilliseconds: '-1',
        signatureTimestamp: player.signature_timestamp } },
      serviceIntegrityDimensions: { poToken },
      client: 'WEB',
      parse: false,
    };
    if (reloadContext) payload.playbackContext.reloadPlaybackContext = reloadContext;
    const t0 = performance.now();
    let raw;
    try {
      raw = (await withTimeout(yt.actions.execute('/player', payload), PLAYER_TIMEOUT_MS, 'player request')).data;
    } catch (e) {
      const bot = isBotCheck(e.message);
      if (bot) this.breaker.note(true);
      throw new YouTubeError(`player request failed: ${e.message}`, { bot });
    }
    const ms = performance.now() - t0;
    const ps = raw?.playabilityStatus || {};
    const reason = [ps.reason, ps.errorScreen?.playerErrorMessageRenderer?.subreason?.simpleText,
      (ps.errorScreen?.playerErrorMessageRenderer?.subreason?.runs || []).map((r) => r.text).join('')]
      .filter(Boolean).join(' - ');
    log(`player request #${n} ${videoId}: ${ps.status || '?'}${reason ? ` (${reason})` : ''} in ${ms.toFixed(0)} ms`);
    if (ps.status !== 'OK') {
      const bot = isBotCheck(reason) || (ps.status === 'LOGIN_REQUIRED' && /bot/i.test(reason));
      this.breaker.note(bot);
      throw new YouTubeError(reason || ps.status || 'unplayable', { bot, status: ps.status });
    }
    this.breaker.note(false);
    const vd = raw.videoDetails || {};
    if (vd.isLive || vd.isUpcoming) {
      throw new YouTubeError(vd.isUpcoming ? 'upcoming' : 'live', { live: true });
    }
    const sd = raw.streamingData || {};
    if (!sd.serverAbrStreamingUrl) throw new YouTubeError('no SABR streaming URL in player response');
    const ustreamer = raw.playerConfig?.mediaCommonConfig?.mediaUstreamerRequestConfig?.videoPlaybackUstreamerConfig;
    if (!ustreamer) throw new YouTubeError('no ustreamer config in player response');
    let sabrUrl;
    try {
      sabrUrl = await withTimeout(player.decipher(sd.serverAbrStreamingUrl), 15000, 'decipher');
    } catch (e) {
      throw new YouTubeError(`decipher failed: ${e.message}`);
    }
    const expireParam = Number(new URL(sabrUrl).searchParams.get('expire'));
    const info = {
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
      fetchedAt: Math.floor(Date.now() / 1000),
    };
    this.cache.set(videoId, info);
    try { fs.writeFileSync(this.cacheFile(videoId), JSON.stringify(info)); } catch (e) { log('cannot cache player response:', e.message); }
    return info;
  }

  /** googlevideo onReloadPlayerResponse: fresh URL + ustreamer config (costs a player request). */
  async reload(videoId, reloadContext) {
    const info = await this.request(videoId, reloadContext || null);
    return { serverAbrStreamingUrl: info.sabrUrl, videoPlaybackUstreamerConfig: info.ustreamer };
  }

  /** Headers that make a plain fetch (captions) look like this session's web player. */
  async webHeaders() {
    const yt = await this.session();
    const c = yt.session.context.client;
    return {
      'user-agent': c.userAgent,
      'accept-language': 'en-US,en;q=0.9',
      origin: 'https://www.youtube.com',
      referer: 'https://www.youtube.com/',
      ...(c.visitorData ? { 'x-goog-visitor-id': c.visitorData } : {}),
    };
  }
}
