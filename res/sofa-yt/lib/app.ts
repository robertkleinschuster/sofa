// HTTP adapter of the node sidecar over the engine core (engine.ts), 127.0.0.1 only. See
// docs/sofa-yt.md for the contract.
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
import { EngineError } from './engine.ts';
import type { Engine, OpenRequest } from './engine.ts';
import { toError } from './errors.ts';
import { log } from './log.ts';

const MAX_BODY = 64 * 1024;

export interface App {
  handler(req: http.IncomingMessage, res: http.ServerResponse): void;
}

function sendJson(res: http.ServerResponse, code: number, obj: object): void {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body), 'Cache-Control': 'no-store' });
  res.end(body);
}

function sendText(req: http.IncomingMessage, res: http.ServerResponse, type: string, body: string): void {
  res.writeHead(200, { 'Content-Type': type, 'Content-Length': Buffer.byteLength(body), 'Cache-Control': 'no-store' });
  res.end(req.method === 'HEAD' ? undefined : body);
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

/** The /open query as the engine's request (the engine validates the values). */
function openRequest(q: URLSearchParams): OpenRequest {
  return {
    v: q.get('v') || '', bg: q.get('bg') === '1', maxHeight: Number(q.get('maxHeight')) || undefined,
    lang: q.get('lang') || undefined, start: Number(q.get('start')) || 0,
    prefetch: q.has('prefetch') ? q.get('prefetch') === '1' : undefined,
    vcodec: q.get('vcodec') ?? undefined, acodec: q.get('acodec') ?? undefined,
  };
}

async function readJson(req: http.IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const c of req) {
    size += (c as Buffer).length;
    if (size > MAX_BODY) throw new EngineError(413, { error: 'body too large' });
    chunks.push(c as Buffer);
  }
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}'); } catch { throw new EngineError(400, { error: 'body is not JSON' }); }
}

export function createApp(engine: Engine): App {
  async function media(sid: string, key: string, req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
    const t = engine.track(sid, key);
    const r = parseRange(req.headers.range, t.total);
    if (r === 'bad') { res.writeHead(416, { 'Content-Range': `bytes */${t.total}` }); res.end(); return; }
    const { start, end } = r || { start: 0, end: t.total };
    const headers: http.OutgoingHttpHeaders = {
      'Content-Type': t.mimeType, 'Accept-Ranges': 'bytes', 'Content-Length': end - start, 'Cache-Control': 'no-store',
    };
    if (r) headers['Content-Range'] = `bytes ${start}-${end - 1}/${t.total}`;
    res.writeHead(r ? 206 : 200, headers);
    if (req.method === 'HEAD') { res.end(); return; }
    const n = await t.serve(start, end, res);
    if (start + n < end) res.destroy(); // premature end: make the client see it (and reconnect)
    else res.end();
  }

  async function handle(req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
    // No keep-alive: on OS X 10.9 node's server misses requests arriving on an idle kept-alive socket
    // until keepAliveTimeout closes it (measured: 2.5 s with the default timeout, 27.5 s with 30 s).
    // Every request gets its own connection (loopback, cheap).
    res.setHeader('Connection', 'close');
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    const q = url.searchParams;
    const parts = url.pathname.split('/').filter(Boolean).map(decodeURIComponent);
    if (parts[0] === 'yt' && req.method === 'POST') {
      return sendJson(res, 200, await engine.innertube(parts.slice(1).join('/'), await readJson(req), { bg: q.get('bg') === '1' }));
    }
    if (req.method !== 'GET' && req.method !== 'HEAD') return sendJson(res, 405, { error: 'method not allowed' });
    if (url.pathname === '/health') return sendJson(res, 200, engine.health());
    if (url.pathname === '/open') return sendJson(res, 200, await engine.open(openRequest(q)));
    if (url.pathname === '/suggest') return sendJson(res, 200, await engine.suggest(q.get('q') || ''));
    if (url.pathname === '/close') return sendJson(res, 200, { ok: true, closed: engine.close(q.get('sid') || '') });
    const [s, sid, what, sub] = parts;
    if (s === 's' && sid !== undefined && what !== undefined && parts.length <= 4) {
      if (parts.length === 3) {
        if (what === 'live.m3u8') return sendText(req, res, 'application/vnd.apple.mpegurl', await engine.playlist(sid));
        if (what === 'video' || what === 'audio') return media(sid, what, req, res);
        if (what === 'status') return sendJson(res, 200, engine.status(sid));
      } else if (sub !== undefined) {
        if (what === 'audio') return media(sid, sub, req, res);
        if (what === 'subs' && sub.endsWith('.vtt')) return sendText(req, res, 'text/vtt; charset=utf-8', await engine.subtitles(sid, sub.slice(0, -4)));
      }
    }
    return sendJson(res, 404, { error: 'not found' });
  }

  return {
    handler(req, res) {
      handle(req, res).catch((thrown: unknown) => {
        if (thrown instanceof EngineError) { if (!res.headersSent) sendJson(res, thrown.status, thrown.body); else res.destroy(); return; }
        const e = toError(thrown);
        log('request failed:', req.url, e.stack || e.message);
        if (!res.headersSent) sendJson(res, 500, { error: e.message }); else res.destroy();
      });
    },
  };
}
