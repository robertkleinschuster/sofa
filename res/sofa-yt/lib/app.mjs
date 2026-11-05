// HTTP API of the sidecar (127.0.0.1 only). See docs/sofa-yt.md for the contract.
//   GET /health
//   GET /open?v=<id>&bg=0|1&maxHeight=1080&lang=de&start=<sec>&prefetch=0|1&vcodec=avc1|vp9|av01&acodec=mp4a|opus
//   GET|HEAD /s/<sid>/video   /s/<sid>/audio   /s/<sid>/audio/<key>    (Range, 206)
//   GET /s/<sid>/subs/<key>.vtt
//   GET /s/<sid>/status       (diagnostics)
//   GET /close?sid=<sid>
import { PlaybackSession } from './session.mjs';
import { describeFormats, pickVideo, pickAudio, audioTracks, subtitleTracks, DEFAULT_MAX_HEIGHT } from './formats.mjs';
import { fetchVtt } from './subs.mjs';
import { log } from './log.mjs';

const VIDEO_ID = /^[A-Za-z0-9_-]{11}$/;
export const SESSION_IDLE_MS = 10 * 60 * 1000;
export const MAX_SESSIONS = 4;

function sendJson(res, code, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body), 'Cache-Control': 'no-store' });
  res.end(body);
}

/** Parse a single-range "bytes=" header against `total`. null = whole file, 'bad' = unsatisfiable. */
export function parseRange(header, total) {
  if (!header) return null;
  const m = /^bytes=(\d*)-(\d*)$/.exec(String(header).trim());
  if (!m || (m[1] === '' && m[2] === '')) return null; // unsupported syntax: serve the whole file
  let start; let end;
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

/**
 * @param {object} o
 * @param {import('./youtube.mjs').YouTube} o.youtube
 * @param {import('./webpo.mjs').PoTokenProvider} o.po
 * @param {import('./breaker.mjs').Breaker} o.breaker
 * @param {(opts) => {abort}} o.startPump   factory(info, formats, opts) for real SABR or a fake
 * @param {object} [o.sessionCfg]
 */
const IN_USE_MS = 60000;   // read within this time = in use (mpv reconnects, pauses between reads)

export function createApp({ youtube, po, breaker, startPump, sessionCfg = {}, idleMs = SESSION_IDLE_MS, maxSessions = MAX_SESSIONS, sweepMs = 30000 }) {
  const sessions = new Map();
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

  function forget(s) {
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
  function inUse(s) { return s.activeReaders > 0 || (s.everRead && Date.now() - s.lastReadAt < IN_USE_MS); }
  function makeRoom() {
    sweep();
    youtube.prune?.();
    while (sessions.size >= maxSessions) {
      const idle = [...sessions.values()].filter((s) => s.failed || !inUse(s));
      if (!idle.length) { log(`session limit ${maxSessions} exceeded: all sessions in use`); return; }
      const rank = (s) => [s.failed ? 0 : 1, s.everRead ? 1 : 0, s.lastActivity];
      const victim = idle.sort((a, b) => { const x = rank(a), y = rank(b); for (let i = 0; i < 3; i++) if (x[i] !== y[i]) return x[i] - y[i]; return 0; })[0];
      victim.close('session limit');
      forget(victim);
    }
  }

  function describeSession(s, extra) {
    const u = `${base()}/s/${s.sid}`;
    const v = s.video.fmt;
    const a = s.audioFormats.get(s.mainAudioKey);
    const audios = s.audioList.map((t) => ({
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
      ...extra,
    };
  }

  async function open(q, res) {
    const t0 = performance.now();
    const vid = q.get('v') || '';
    if (!VIDEO_ID.test(vid)) return sendJson(res, 400, { error: 'invalid video ID', bot: false, blocked_until: breaker.blockedUntil() });
    const bg = q.get('bg') === '1';
    const maxHeight = Number(q.get('maxHeight')) || DEFAULT_MAX_HEIGHT;
    const lang = (q.get('lang') || 'de').slice(0, 12);
    const startSec = Math.max(0, Number(q.get('start')) || 0);
    // codec preferences (downloads ask for avc1 + mp4a: an MP4 without re-encoding)
    const vcodec = ['avc1', 'vp9', 'av01'].includes(q.get('vcodec')) ? q.get('vcodec') : null;
    const acodec = ['mp4a', 'opus'].includes(q.get('acodec')) ? q.get('acodec') : null;
    const prefetch = q.has('prefetch') ? q.get('prefetch') === '1' : !bg;
    let info; let cached;
    try {
      ({ info, cached } = await youtube.info(vid, { bg }));
    } catch (e) {
      if (e.live) return sendJson(res, 200, { id: vid, error: 'live', live: true, blocked_until: breaker.blockedUntil() });
      log(`open ${vid}${bg ? ' (bg)' : ''} failed: ${e.message}`);
      return sendJson(res, 200, { id: vid, error: String(e.message).slice(0, 300), bot: !!e.bot, blocked_until: breaker.blockedUntil() });
    }
    // an existing healthy session for the same choice keeps its buffered media
    for (const s of sessions.values()) {
      if (!s.closed && !s.failed && s.info === info && s.maxHeight === maxHeight && s.lang === lang
          && s.vcodec === vcodec && s.acodec === acodec) {
        s.lastActivity = Date.now();
        if (prefetch && startSec) s.hint(startSec * 1000);
        return sendJson(res, 200, describeSession(s, { cached: true, reused: true, secs: +((performance.now() - t0) / 1000).toFixed(2), blocked_until: breaker.blockedUntil() }));
      }
    }
    const formats = describeFormats(info.formats);
    const video = pickVideo(formats, maxHeight, vcodec);
    const audio = pickAudio(formats, acodec);
    if (!video || !audio) {
      return sendJson(res, 200, { id: vid, error: 'no usable video/audio format', bot: false, blocked_until: breaker.blockedUntil() });
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
    return sendJson(res, 200, describeSession(s, { cached, secs: +((performance.now() - t0) / 1000).toFixed(2), blocked_until: breaker.blockedUntil() }));
  }

  async function media(s, key, req, res) {
    const t = s.track(key);
    if (!t) return sendJson(res, 404, { error: 'no such track' });
    if (s.failed) return sendJson(res, 503, { error: s.failed.message });
    const total = t.file.total;
    const r = parseRange(req.headers.range, total);
    if (r === 'bad') { res.writeHead(416, { 'Content-Range': `bytes */${total}` }); return res.end(); }
    const { start, end } = r || { start: 0, end: total };
    const headers = {
      'Content-Type': (t.fmt.mimeType || 'application/octet-stream').split(';')[0],
      'Accept-Ranges': 'bytes',
      'Content-Length': end - start,
      'Cache-Control': 'no-store',
    };
    if (r) headers['Content-Range'] = `bytes ${start}-${end - 1}/${total}`;
    res.writeHead(r ? 206 : 200, headers);
    if (req.method === 'HEAD') return res.end();
    const n = await s.serve(t, start, end, res);
    if (start + n < end) res.destroy(); // premature end: make the client see it (and reconnect)
    else res.end();
  }

  async function subs(s, key, res) {
    const t = s.subs.find((x) => x.key === key);
    if (!t) return sendJson(res, 404, { error: 'no such subtitle track' });
    let body = s.subCache.get(key);
    if (!body) {
      try {
        const [headers, poToken] = await Promise.all([youtube.webHeaders(), po.mintString(s.info.id).catch(() => null)]);
        body = await fetchVtt(t, { headers, poToken, clientVersion: s.info.clientVersion });
        s.subCache.set(key, body);
      } catch (e) {
        log(`${s.tag}: subtitles ${key}: ${e.message}`);
        return sendJson(res, 502, { error: e.message });
      }
    }
    s.lastActivity = Date.now();
    res.writeHead(200, { 'Content-Type': 'text/vtt; charset=utf-8', 'Content-Length': Buffer.byteLength(body), 'Cache-Control': 'no-store' });
    res.end(body);
  }

  async function handle(req, res) {
    // No keep-alive: on OS X 10.9 node's server misses requests arriving on an idle kept-alive socket
    // until keepAliveTimeout closes it (measured: 2.5 s with the default timeout, 27.5 s with 30 s).
    // Every request gets its own connection (loopback, cheap).
    res.setHeader('Connection', 'close');
    const url = new URL(req.url, 'http://127.0.0.1');
    const parts = url.pathname.split('/').filter(Boolean).map(decodeURIComponent);
    if (req.method !== 'GET' && req.method !== 'HEAD') return sendJson(res, 405, { error: 'method not allowed' });
    if (url.pathname === '/health') {
      return sendJson(res, 200, { ok: true, session: youtube.sessionState, poToken: po.state, sessions: sessions.size,
        blocked_until: breaker.blockedUntil(), rssMB: Math.round(process.memoryUsage().rss / 1048576),
        bufferedMB: +([...sessions.values()].reduce((n, s) => n + s.bytes, 0) / 1048576).toFixed(1), fetched: fetchedNow() });
    }
    if (url.pathname === '/open') return open(url.searchParams, res);
    if (url.pathname === '/close') {
      const s = sessions.get(url.searchParams.get('sid') || '');
      if (s) { s.close('closed by client'); forget(s); }
      return sendJson(res, 200, { ok: true, closed: !!s });
    }
    if (parts[0] === 's' && parts.length >= 3) {
      const s = sessions.get(parts[1]);
      if (!s || s.closed) return sendJson(res, 404, { error: 'no such session (expired?)' });
      if (parts[2] === 'video' && parts.length === 3) return media(s, 'video', req, res);
      if (parts[2] === 'audio' && parts.length === 3) return media(s, s.mainAudioKey, req, res);
      if (parts[2] === 'audio' && parts.length === 4) return media(s, parts[3], req, res);
      if (parts[2] === 'subs' && parts.length === 4 && parts[3].endsWith('.vtt')) return subs(s, parts[3].slice(0, -4), res);
      if (parts[2] === 'status' && parts.length === 3) return sendJson(res, 200, s.status());
    }
    return sendJson(res, 404, { error: 'not found' });
  }

  return {
    sessions,
    setPort(p) { port = p; },
    handler(req, res) {
      handle(req, res).catch((e) => {
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
