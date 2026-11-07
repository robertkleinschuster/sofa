// Sofa's side of the engine for the engine's tests: the routes Sofa serves to mpv/ffmpeg
// (src/Apps/YouTube/SFYTEngine+Media.m) over the engine core, with the same data path - media in
// engine.read() pieces, the first one telling size and type - plus the calls Sofa makes over the
// extension's channel as plain HTTP for test convenience. 127.0.0.1 only, Connection: close.
//   GET /open?v=<id>&bg=0|1&maxHeight=&lang=&start=&prefetch=0|1&vcodec=&acodec=   (open)
//   GET|HEAD /s/<sid>/video   /s/<sid>/audio   /s/<sid>/audio/<key>              (Range, 206)
//   GET /s/<sid>/live.m3u8   /s/<sid>/seg/<n>.<ext>   /s/<sid>/subs/<key>.vtt   /s/<sid>/status
//   GET /close?sid=   POST /yt/<endpoint>?bg=0|1   GET /suggest?q=   GET /health
import http from 'node:http';
import { EngineError } from '../../res/sofa-yt/lib/engine.ts';
import type { Engine, OpenRequest } from '../../res/sofa-yt/lib/engine.ts';

const PIECE = 1 << 20;   // bytes per engine read, as SFYTEngine+Media's kPiece

/** A single "bytes=" range against `total` (SFYTEngine+Media ParseRange). null = all, 'bad' = unsatisfiable. */
export function parseRange(header: string | undefined, total: number): { start: number; end: number } | 'bad' | null {
  if (!header) return null;
  const m = /^bytes=(\d*)-(\d*)$/.exec(String(header).trim());
  if (!m || (m[1] === '' && m[2] === '')) return null;   // unsupported syntax (multi-range ...): all
  let start: number; let end: number;
  if (m[1] === '') {   // suffix: the last N bytes
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

function openRequest(q: URLSearchParams): OpenRequest {
  return {
    v: q.get('v') || '', bg: q.get('bg') === '1', maxHeight: Number(q.get('maxHeight')) || undefined,
    lang: q.get('lang') || undefined, start: Number(q.get('start')) || 0,
    prefetch: q.has('prefetch') ? q.get('prefetch') === '1' : undefined,
    vcodec: q.get('vcodec') ?? undefined, acodec: q.get('acodec') ?? undefined,
  };
}

function sendJson(res: http.ServerResponse, code: number, obj: unknown): void {
  const body = JSON.stringify(obj);
  res.writeHead(code, { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) }).end(body);
}

function sendText(req: http.IncomingMessage, res: http.ServerResponse, type: string, body: string): void {
  res.writeHead(200, { 'Content-Type': type, 'Content-Length': Buffer.byteLength(body) });
  res.end(req.method === 'HEAD' ? undefined : body);
}

async function readJson(req: http.IncomingMessage): Promise<unknown> {
  const chunks: Buffer[] = [];
  for await (const c of req) chunks.push(c as Buffer);
  return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
}

/** Writes `buf`; resolves false when the reader went away. */
function write(res: http.ServerResponse, buf: Uint8Array): Promise<boolean> {
  if (res.destroyed) return Promise.resolve(false);
  return new Promise((ok) => {
    if (res.write(buf)) { ok(!res.destroyed); return; }
    const done = (v: boolean) => () => { res.off('drain', onDrain); res.off('close', onClose); ok(v); };
    const onDrain = done(true); const onClose = done(false);
    res.once('drain', onDrain); res.once('close', onClose);
  });
}

async function media(engine: Engine, sid: string, key: string, req: http.IncomingMessage, res: http.ServerResponse): Promise<void> {
  const range = req.headers.range;
  const m = /^bytes=(\d+)-(\d*)$/.exec(String(range ?? '').trim());
  const first = m ? Number(m[1]) : 0;   // a suffix range or none: the first read at 0 tells the total
  // never read past an explicit end: bytes beyond a header probe are a reader there for the engine
  const want = m?.[2] ? Math.max(1, Number(m[2]) + 1 - first) : PIECE;
  const head = req.method === 'HEAD';
  const r0 = await engine.read(sid, key, first, head ? 1 : Math.min(PIECE, want));
  const r = parseRange(range, r0.total);
  if (r === 'bad') { res.writeHead(416, { 'Content-Range': `bytes */${r0.total}`, 'Content-Length': 0 }).end(); return; }
  const { start, end } = r ?? { start: 0, end: r0.total };
  const headers: http.OutgoingHttpHeaders = { 'Content-Type': r0.mimeType, 'Accept-Ranges': 'bytes', 'Content-Length': end - start };
  if (r) headers['Content-Range'] = `bytes ${start}-${end - 1}/${r0.total}`;
  res.writeHead(r ? 206 : 200, headers);
  if (head) { res.end(); return; }
  let at = start;
  let piece: Uint8Array | null = start === first ? r0.bytes : null;
  try {
    while (at < end) {
      piece ??= (await engine.read(sid, key, at, Math.min(PIECE, end - at))).bytes;
      if (!piece.length) break;
      const out = piece.subarray(0, Math.min(piece.length, end - at));
      if (!await write(res, out)) return;
      at += out.length;
      piece = null;
    }
  } catch { /* a failed read: the reader sees the premature end and reconnects */ }
  if (at < end) res.destroy(); else res.end();
}

export interface MediaServer { port: number; base: string; close(): Promise<void> }

/** Serves `engine` on 127.0.0.1:<free port>; `base` is what the engine must put into its URLs. */
export async function serveEngine(engine: Engine, setBase: (base: string) => void = () => {}): Promise<MediaServer> {
  const handle = async (req: http.IncomingMessage, res: http.ServerResponse): Promise<void> => {
    res.setHeader('Connection', 'close');
    res.setHeader('Cache-Control', 'no-store');
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    const q = url.searchParams;
    const parts = url.pathname.split('/').filter(Boolean).map(decodeURIComponent);
    if (parts[0] === 'yt' && req.method === 'POST') {
      return sendJson(res, 200, await engine.innertube(parts.slice(1).join('/'), await readJson(req), { bg: q.get('bg') === '1' }));
    }
    if (url.pathname === '/health') return sendJson(res, 200, engine.health());
    if (url.pathname === '/open') return sendJson(res, 200, await engine.open(openRequest(q)));
    if (url.pathname === '/suggest') return sendJson(res, 200, await engine.suggest(q.get('q') || ''));
    if (url.pathname === '/close') return sendJson(res, 200, { ok: true, closed: engine.close(q.get('sid') || '') });
    const [s, sid, what, sub] = parts;
    if (s === 's' && sid !== undefined && what !== undefined && parts.length <= 4) {
      if (parts.length === 3) {
        if (what === 'live.m3u8') return sendText(req, res, 'application/vnd.apple.mpegurl', await engine.playlist(sid));
        if (what === 'video' || what === 'audio') return media(engine, sid, what, req, res);
        if (what === 'status') return sendJson(res, 200, engine.status(sid));
      } else if (sub !== undefined) {
        if (what === 'audio') return media(engine, sid, sub, req, res);
        if (what === 'seg') {
          const seg = await engine.segment(sid, parseInt(sub, 10));
          res.writeHead(200, { 'Content-Type': seg.mimeType, 'Content-Length': seg.bytes.length });
          res.end(req.method === 'HEAD' ? undefined : seg.bytes); return;
        }
        if (what === 'subs' && sub.endsWith('.vtt')) return sendText(req, res, 'text/vtt; charset=utf-8', await engine.subtitles(sid, sub.slice(0, -4)));
      }
    }
    sendJson(res, 404, { error: 'not found' });
  };
  const server = http.createServer((req, res) => {
    handle(req, res).catch((e: unknown) => {
      if (res.headersSent) { res.destroy(); return; }
      if (e instanceof EngineError) sendJson(res, e.status, e.body);
      else sendJson(res, 500, { error: e instanceof Error ? e.message : String(e) });
    });
  });
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const addr = server.address();
  const port = addr !== null && typeof addr === 'object' ? addr.port : 0;
  const base = `http://127.0.0.1:${port}`;
  setBase(base);
  return { port, base, async close() { server.closeAllConnections(); await new Promise((r) => server.close(r)); } };
}
