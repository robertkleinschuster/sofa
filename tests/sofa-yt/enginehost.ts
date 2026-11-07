// Sofa's side of the engine channel, for tests (docs/youtube-engine.md "Channel"; Sofa's own is
// ObjC, SFYTChannel): a loopback server the extension's background holds a WebSocket to - commands
// out as text, answers and events in (text, or protocol.ts' binary container) - plus installing the
// extension into a Firefox profile. A minimal RFC 6455 server: node has a WebSocket client, no server.
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import type { Duplex } from 'node:stream';
import { createHash, randomBytes } from 'node:crypto';
import { decodeUpload } from '../../res/sofa-yt/web/protocol.ts';
import type { Command, Method } from '../../res/sofa-yt/web/protocol.ts';

export const EXTENSION_ID = 'youtube-engine@sofa';

export interface EngineHost {
  port: number;
  token: string;
  /** engine events in arrival order */
  events: { type: string; [k: string]: unknown }[];
  /** One engine call; rejects after `timeoutMs` without an answer (a page that went away). */
  call<T>(method: Method, ...args: unknown[]): Promise<T>;
  callWithin<T>(timeoutMs: number, method: Method, ...args: unknown[]): Promise<T>;
  close(): Promise<void>;
}

const CALL_TIMEOUT_MS = 120000;   // read() waits for SABR like a player; longer means the page is gone

/** One unmasked server frame. */
function frame(op: number, payload: Buffer): Buffer {
  const n = payload.length;
  const head = n < 126 ? Buffer.from([0x80 | op, n])
    : n <= 0xffff ? Buffer.from([0x80 | op, 126, n >> 8, n & 0xff])
      : Buffer.concat([Buffer.from([0x80 | op, 127]), (() => { const b = Buffer.alloc(8); b.writeBigUInt64BE(BigInt(n)); return b; })()]);
  return Buffer.concat([head, payload]);
}

/** Client frames -> messages (joined fragments; pings answered, close ends). */
function readFrames(socket: Duplex, message: (binary: boolean, payload: Buffer) => void): void {
  let buf = Buffer.alloc(0);
  let parts: Buffer[] = [];
  let binary = false;
  socket.on('data', (d: Buffer) => {
    buf = Buffer.concat([buf, d]);
    for (;;) {
      if (buf.length < 2) return;
      const fin = (buf[0]! & 0x80) !== 0, op = buf[0]! & 0x0f;
      let len = buf[1]! & 0x7f, at = 2;
      if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); at = 4; }
      else if (len === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); at = 10; }
      if (buf.length < at + 4 + len) return;
      const key = buf.subarray(at, at + 4);
      const payload = Buffer.from(buf.subarray(at + 4, at + 4 + len));
      for (let i = 0; i < payload.length; i++) payload[i]! ^= key[i & 3]!;
      buf = buf.subarray(at + 4 + len);
      if (op === 8) { socket.end(frame(8, Buffer.alloc(0))); return; }
      if (op === 9) { socket.write(frame(10, payload)); continue; }
      if (op === 10) continue;
      if (op !== 0) { binary = op === 2; parts = []; }
      parts.push(payload);
      if (fin) message(binary, Buffer.concat(parts));
    }
  });
}

export async function startEngineHost({ onEvent }: { onEvent?: (e: EngineHost['events'][number]) => void } = {}): Promise<EngineHost> {
  const token = randomBytes(16).toString('hex');
  const queue: Command[] = [];
  const waiting = new Map<number, { ok: (v: unknown) => void; bad: (e: Error) => void }>();
  const events: EngineHost['events'] = [];
  let peer: Duplex | null = null;
  let nextId = 1;

  const flush = (): void => {
    if (!peer || !queue.length) return;
    peer.write(frame(1, Buffer.from(JSON.stringify(queue.splice(0)))));
  };
  const received = (binary: boolean, payload: Buffer): void => {
    const up = decodeUpload(binary ? new Uint8Array(payload) : payload.toString('utf8'));
    for (const e of up.events) { const ev = e as EngineHost['events'][number]; events.push(ev); onEvent?.(ev); }
    for (const a of up.answers) {
      const w = waiting.get(a.id);
      if (!w) continue;
      waiting.delete(a.id);
      if ('error' in a) w.bad(new Error(a.error)); else w.ok(a.value);
    }
  };

  const server = http.createServer((_req, res) => { res.writeHead(404).end(); });
  server.on('upgrade', (req, socket) => {
    const url = new URL(req.url ?? '/', 'http://127.0.0.1');
    const key = req.headers['sec-websocket-key'];
    if (url.searchParams.get('token') !== token || url.pathname !== '/engine/ws' || typeof key !== 'string') {
      socket.end('HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n');
      return;
    }
    const accept = createHash('sha1').update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
    peer?.end();   // the newest connection is the extension's
    peer = socket;
    socket.on('close', () => { if (peer === socket) peer = null; });
    socket.on('error', () => socket.destroy());
    readFrames(socket, received);
    flush();
  });
  function callWithin<T>(timeoutMs: number, method: Method, ...args: unknown[]): Promise<T> {
    const id = nextId++;
    return new Promise<T>((ok, bad) => {
      const timer = setTimeout(() => {
        waiting.delete(id);
        const i = queue.findIndex((c) => c.id === id);
        if (i >= 0) queue.splice(i, 1);
        bad(new Error(`engine: no answer to ${method} within ${timeoutMs} ms`));
      }, timeoutMs);
      waiting.set(id, { ok: (v) => { clearTimeout(timer); (ok as (v: unknown) => void)(v); }, bad: (e) => { clearTimeout(timer); bad(e); } });
      queue.push({ id, method, args });
      flush();
    });
  }
  await new Promise<void>((r) => server.listen(0, '127.0.0.1', r));
  const addr = server.address();
  const port = addr !== null && typeof addr === 'object' ? addr.port : 0;
  return {
    port, token, events,
    call: <T>(method: Method, ...args: unknown[]): Promise<T> => callWithin<T>(CALL_TIMEOUT_MS, method, ...args),
    callWithin,
    async close() { peer?.destroy(); server.closeAllConnections(); await new Promise((r) => server.close(r)); },
  };
}

/**
 * Install the built extension (build/sofa-yt-web/extension) unpacked into `profile`, configured for
 * `host`: a copy with config.json, referenced by a proxy file in the profile's extensions directory.
 */
export function installExtension(profile: string, built: string, host: Pick<EngineHost, 'port' | 'token'>): string {
  const dir = path.join(profile, '..', `${path.basename(profile)}-extension`);
  fs.rmSync(dir, { recursive: true, force: true });
  fs.cpSync(built, dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'config.json'), JSON.stringify({ port: host.port, token: host.token }));
  fs.mkdirSync(path.join(profile, 'extensions'), { recursive: true });
  fs.writeFileSync(path.join(profile, 'extensions', EXTENSION_ID), dir);
  return dir;
}

/** Prefs a profile with Sofa's unsigned, sideloaded extension needs (Firefox ESR honours them). */
export const EXTENSION_PREFS = { 'xpinstall.signatures.required': false, 'extensions.autoDisableScopes': 0, 'extensions.enabledScopes': 15 };
